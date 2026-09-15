import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'config.dart';
import 'host_platform.dart';
import 'protocol.dart';

class HidDevice {
  const HidDevice({
    required this.id,
    required this.name,
    this.serial = '',
    this.collections = 0,
    this.details = '',
    this.vendorId = 0x0D00,
    this.productId = 0x072C,
    this.dfuPath = '',
  });
  final String id, name, serial, details;
  final int collections;
  final int vendorId, productId;
  final String dfuPath;
  bool get isReceiver => vendorId == 0x0D00 && productId == 0x072D;
  String get kindLabel => isReceiver ? '接收器' : '触摸板';
  bool get supportsDfu =>
      vendorId == 0x0D00 &&
      productId >= 0x072A &&
      productId <= 0x072D &&
      dfuPath.isNotEmpty;
  String get usbId =>
      '${vendorId.toRadixString(16).padLeft(4, '0')}:${productId.toRadixString(16).padLeft(4, '0')}'
          .toUpperCase();
  factory HidDevice.fromMap(Map<Object?, Object?> m) => HidDevice(
    id: m['id'] as String,
    name: m['name'] as String,
    serial: m['serial'] as String? ?? '',
    collections: m['collections'] as int? ?? 0,
    details: m['details'] as String? ?? '',
    vendorId: m['vendorId'] as int? ?? 0,
    productId: m['productId'] as int? ?? 0,
    dfuPath: m['dfuPath'] as String? ?? '',
  );
}

class HidException implements Exception {
  const HidException(this.code, this.message);
  final String code, message;
  @override
  String toString() => '$message [$code]';
}

abstract class HidTransport {
  bool get isDemo => false;
  bool get runsOnWindows11 => false;
  Future<List<HidDevice>> enumerate();
  Future<void> open(String id);
  Future<void> close();
  Future<void> send(Uint8List packet);
  Future<Uint8List> read(int timeoutMs);
  Future<int> getFeature(int reportId);
  Future<void> setFeature(int reportId, int value);
  Future<void> enterDfu(HidDevice device) async {
    throw const HidException('unsupported', '当前连接不支持进入 DFU 模式');
  }
}

class WindowsHidTransport extends HidTransport {
  @override
  bool get runsOnWindows11 => isWindows11Host;
  static const channel = MethodChannel('technology.rsodium/hid');
  Future<T?> _call<T>(String method, [Map<String, Object>? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw HidException(e.code, e.message ?? 'HID 操作失败');
    } on MissingPluginException {
      throw const HidException('platform', '真实 HID 连接仅支持 Windows 桌面版');
    }
  }

  @override
  Future<List<HidDevice>> enumerate() async =>
      (await _call<List<Object?>>('enumerate') ?? [])
          .map((e) => HidDevice.fromMap(e! as Map<Object?, Object?>))
          .toList();
  @override
  Future<void> open(String id) => _call<void>('open', {'id': id});
  @override
  Future<void> close() => _call<void>('close');
  @override
  Future<void> send(Uint8List packet) =>
      _call<void>('send', {'packet': packet});
  @override
  Future<Uint8List> read(int timeoutMs) async =>
      (await _call<Uint8List>('read', {'timeoutMs': timeoutMs}))!;
  @override
  Future<int> getFeature(int reportId) async =>
      (await _call<int>('getFeature', {'reportId': reportId}))!;
  @override
  Future<void> setFeature(int reportId, int value) =>
      _call<void>('setFeature', {'reportId': reportId, 'value': value});
  @override
  Future<void> enterDfu(HidDevice device) async {
    if (!device.supportsDfu) {
      throw const HidException('unsupported', '设备没有可用的 DFU 接口');
    }
    await _call<void>('enterDfu', {'id': device.id, 'path': device.dfuPath});
  }
}

// In-memory firmware emulator; no OS input or physical HID writes.
class MockHidTransport extends HidTransport {
  MockHidTransport({
    this.legacy = false,
    this.capabilities = Capability.all,
    this.configVersion = 3,
  });
  final bool legacy;
  final int capabilities;
  final int configVersion;
  bool present = true, opened = false;
  bool dropWriteReply = false, ignoreWrites = false;
  int writeStatus = Status.ok;
  int writes = 0;
  int dfuRequests = 0;
  TouchpadConfig config = TouchpadConfig();
  final Queue<Uint8List> replies = Queue();
  @override
  bool get isDemo => true;
  @override
  Future<List<HidDevice>> enumerate() async => present
      ? [
          HidDevice(
            id: legacy ? 'demo-legacy' : 'demo-v$configVersion',
            name: 'R-SODIUM 演示触摸板',
            serial: 'DEMO-0001',
            collections: 3,
            details: '内存模拟设备，不连接硬件',
            dfuPath: 'demo-dfu',
          ),
        ]
      : [];
  @override
  Future<void> open(String id) async {
    if (!present) throw const HidException('disconnected', '演示设备已断开');
    opened = true;
    replies.clear();
  }

  @override
  Future<void> close() async {
    opened = false;
    replies.clear();
  }

  @override
  Future<void> enterDfu(HidDevice device) async {
    final targets = await enumerate();
    if (!targets.any(
      (d) => d.id == device.id && d.dfuPath == device.dfuPath && d.supportsDfu,
    )) {
      throw const HidException('disconnected', '目标演示设备已断开');
    }
    dfuRequests++;
    present = false;
    await close();
  }

  void check() {
    if (!opened || !present) throw const HidException('disconnected', '设备已断开');
  }

  @override
  Future<void> send(Uint8List packet) async {
    check();
    if (legacy) return;
    final p = Packet.decode(packet);
    var status = Status.ok;
    var payload = Uint8List(0);
    if (p.command == Command.info) {
      payload = Uint8List(12);
      final d = ByteData.sublistView(payload);
      d.setUint32(0, capabilities, Endian.little);
      d.setUint16(4, 1, Endian.little);
      payload[10] = configVersion;
    } else if (p.command == Command.read) {
      payload = config.encode(version: configVersion);
    } else {
      writes++;
      status = writeStatus;
      final incoming = TouchpadConfig.decode(p.payload, version: configVersion);
      final supported = Capability.negotiated(capabilities, configVersion);
      if (!config.merge(incoming, supported).same(incoming)) {
        status = Status.unsupported;
      }
      if ((status == Status.ok || status == Status.reconnect) &&
          !ignoreWrites) {
        config = incoming;
      }
      if (dropWriteReply) {
        dropWriteReply = false;
        return;
      }
    }
    replies.add(
      Packet(p.command, p.sequence, status: status, payload: payload).encode(),
    );
  }

  @override
  Future<Uint8List> read(int timeoutMs) async {
    check();
    if (replies.isEmpty) throw const HidException('timeout', '等待 HID 响应超时');
    return replies.removeFirst();
  }

  @override
  Future<int> getFeature(int reportId) async {
    check();
    return switch (reportId) {
      0x40 => config.pressLevel,
      0x41 => config.intensity,
      _ => throw const HidException('unsupported', '报告不存在'),
    };
  }

  @override
  Future<void> setFeature(int reportId, int value) async {
    check();
    writes++;
    if (writeStatus != 0) throw const HidException('io', '模拟 Feature 写入失败');
    if (!ignoreWrites) {
      config = reportId == 0x40
          ? config.copyWith(pressLevel: value)
          : config.copyWith(intensity: value);
    }
  }
}
