import 'dart:typed_data';

import 'config.dart';
import 'protocol.dart';
import 'transport.dart';

class ApplyResult {
  const ApplyResult(this.config, this.message, {this.reconnect = false});
  final TouchpadConfig? config;
  final String message;
  final bool reconnect;
}

class DeviceClient {
  DeviceClient(this.transport);
  final HidTransport transport;
  bool modern = false;
  int configVersion = 1;
  int capabilities = 0, known = 0;
  String firmware = '未读取';
  String note = '';
  int _sequence = 0;
  bool _requestActive = false;
  int _generation = 0;

  Future<void> close() async {
    _generation++;
    await transport.close();
  }

  Future<Packet> request(
    int command, {
    Uint8List? payload,
    bool retry = true,
  }) async {
    if (_requestActive) throw StateError('只允许一个未完成请求');
    _requestActive = true;
    final generation = _generation;
    try {
      final attempts = retry && command != Command.write ? 2 : 1;
      for (var attempt = 0; attempt < attempts; attempt++) {
        _sequence = _sequence % 65535 + 1;
        final seq = _sequence;
        try {
          await transport.send(Packet(command, seq, payload: payload).encode());
          final elapsed = Stopwatch()..start();
          while (elapsed.elapsedMilliseconds < 1500) {
            final remaining = 1500 - elapsed.elapsedMilliseconds;
            if (remaining <= 0) break;
            final raw = await transport.read(remaining);
            if (_generation != generation) {
              throw const HidException('disconnected', '连接已变更，丢弃旧响应');
            }
            final reply = Packet.decode(raw);
            if (reply.sequence != seq || reply.command != command) continue;
            if (reply.status != Status.ok &&
                !(command == Command.write &&
                    reply.status == Status.reconnect)) {
              throw ProtocolException(
                Status.labels[reply.status],
                reply.status,
              );
            }
            return reply;
          }
          throw const HidException('timeout', '等待匹配的 HID 响应超时');
        } on HidException catch (e) {
          if (e.code != 'timeout' || attempt + 1 == attempts) rethrow;
        }
      }
      throw StateError('不可达');
    } finally {
      _requestActive = false;
    }
  }

  Future<TouchpadConfig> connect(String id) async {
    modern = false;
    configVersion = 1;
    capabilities = known = 0;
    firmware = '未读取';
    note = '';
    await transport.open(id);
    Packet? response;
    try {
      response = await request(Command.info);
    } on HidException catch (e) {
      if (!['timeout', 'no_generic', 'unsupported'].contains(e.code)) rethrow;
      note = 'RSTP 握手不可用，使用旧 Feature 接口。';
    } on ProtocolException catch (e) {
      if (e.status != Status.unsupported) rethrow;
      note = '设备未支持 RSTP，使用旧 Feature 接口。';
    }
    if (response != null) {
      final info = DeviceInfo.decode(response.payload);
      modern = true;
      configVersion = info.configVersion;
      capabilities = Capability.negotiated(info.capabilities, configVersion);
      firmware = info.firmware;
    }
    return readConfig();
  }

  Future<TouchpadConfig> readConfig() async {
    if (modern) {
      final config = TouchpadConfig.decode(
        (await request(Command.read)).payload,
        version: configVersion,
      );
      if ((capabilities & Capability.edgeArrowKeys == 0 &&
              config.edges.any((e) => e.action.isArrowKey)) ||
          (capabilities & Capability.edgeRepeat == 0 &&
              config.repeatMask != 0)) {
        throw const FormatException('边缘扩展配置与固件能力不一致');
      }
      if ((capabilities & Capability.points == 0 &&
              config.points.any((p) => !p.isDefault)) ||
          (capabilities & Capability.pointToEdge == 0 &&
              config.pointToEdgeMask != 0)) {
        throw const FormatException('单点配置与固件能力不一致');
      }
      known = capabilities;
      return config;
    }
    var config = TouchpadConfig();
    known = 0;
    final errors = <String>[];
    for (final id in [0x40, 0x41]) {
      try {
        final v = await transport.getFeature(id);
        if (id == 0x40) {
          if (v < 1 || v > 3) throw const FormatException('按压档位超出范围');
          config = config.copyWith(pressLevel: v);
          known |= Capability.pressLevel;
        } else {
          if (v < 0 || v > 100) throw const FormatException('触觉强度超出范围');
          config = config.copyWith(intensity: v);
          known |= Capability.intensity;
        }
      } catch (e) {
        errors.add('0x${id.toRadixString(16)}: $e');
      }
    }
    capabilities = known;
    note =
        '旧 Feature 接口；读回只确认当前值，不代表断电保存已验证。${errors.isEmpty ? '' : '\n${errors.join('\n')}'}';
    if (known == 0) throw HidException('unavailable', '已找到设备，但设置无法读取。\n$note');
    return config;
  }

  Future<ApplyResult> apply(
    TouchpadConfig desired,
    TouchpadConfig current,
  ) async {
    final target = current.merge(desired, capabilities);
    final error = target.validationError;
    if (error != null) throw FormatException(error);
    if (modern) {
      var timedOut = false;
      try {
        final response = await request(
          Command.write,
          payload: target.encode(version: configVersion),
          retry: false,
        );
        if (response.payload.isNotEmpty) {
          throw const FormatException('写入响应负载必须为空');
        }
        if (response.status == Status.reconnect) {
          return const ApplyResult(
            null,
            '已保存，等待设备重新枚举；重连后验证。',
            reconnect: true,
          );
        }
      } on HidException catch (e) {
        if (e.code != 'timeout') rethrow;
        timedOut = true;
      }
      final readback = await readConfig();
      if (!target.same(readback)) throw ProtocolException('读回值与提交值不一致，未确认应用成功');
      return ApplyResult(
        readback,
        timedOut ? '写入响应超时；读回值一致，当前值已确认，持久化状态未确认。' : '设备已确认保存，读回校验通过。',
      );
    }
    for (final entry in [
      (0x40, Capability.pressLevel, target.pressLevel, current.pressLevel),
      (0x41, Capability.intensity, target.intensity, current.intensity),
    ]) {
      if (capabilities & entry.$2 != 0 && entry.$3 != entry.$4) {
        await transport.setFeature(entry.$1, entry.$3);
        final value = await transport.getFeature(entry.$1);
        if (value != entry.$3) {
          throw ProtocolException(
            'Feature 0x${entry.$1.toRadixString(16)} 读回不一致；固件可能拒绝了写入',
          );
        }
      }
    }
    final previousMask = capabilities;
    final readback = await readConfig();
    if (known != previousMask || !target.same(readback, previousMask)) {
      throw ProtocolException('旧接口读回不完整或不一致，未确认应用成功');
    }
    return ApplyResult(readback, '当前值读回一致；旧接口不提供持久化确认。');
  }
}
