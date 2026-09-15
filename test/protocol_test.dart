import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/config.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/protocol.dart';

void main() {
  final fixtures =
      (jsonDecode(
        File('test/fixtures/protocol_vectors.json').readAsStringSync(),
      ) as Map<String, dynamic>).map(
        (k, v) => MapEntry(
          k,
          Uint8List.fromList(
            (v as String)
                .split(' ')
                .map((s) => int.parse(s, radix: 16))
                .toList(),
          ),
        ),
      );
  test('Documentation examples exactly match fixed vectors', () {
    final doc = File('docs/hid-protocol.md').readAsStringSync();
    for (final entry in fixtures.entries) {
      final start = doc.indexOf('<!-- vector: ${entry.key} -->');
      expect(start, greaterThanOrEqualTo(0));
      final codeStart = doc.indexOf('```text', start) + 7;
      final codeEnd = doc.indexOf('```', codeStart);
      final bytes = doc
          .substring(codeStart, codeEnd)
          .trim()
          .split(RegExp(r'\s+'))
          .map((v) => int.parse(v, radix: 16))
          .toList();
      expect(bytes, entry.value, reason: entry.key);
    }
  });
  test('Published byte vectors match request and configuration encoders', () {
    expect(Packet(Command.info, 1).encode(), fixtures['info_request']);
    expect(Packet(Command.read, 2).encode(), fixtures['read_request']);
    expect(
      Packet(Command.read, 2, payload: TouchpadConfig().encode()).encode(),
      fixtures['read_response'],
    );
    expect(
      Packet(
        Command.write,
        3,
        payload: TouchpadConfig(intensity: 75).encode(),
      ).encode(),
      fixtures['write_request'],
    );
    expect(Packet(Command.write, 3).encode(), fixtures['write_response']);
    expect(
      Packet(Command.write, 3, status: Status.reconnect).encode(),
      fixtures['reconnect_response'],
    );
    for (final bytes in fixtures.values) {
      expect(bytes.length, 64);
      expect(Packet.decode(bytes).encode(), bytes);
    }
    final info = DeviceInfo.decode(
      Packet.decode(fixtures['info_response']!).payload,
    );
    expect(info.capabilities, 0x3f);
    expect(info.firmware, '1.0.0');
    final extendedInfo = DeviceInfo.decode(
      Packet.decode(fixtures['extended_info_response']!).payload,
    );
    expect(extendedInfo.capabilities, Capability.v1);
    expect(extendedInfo.firmware, '1.1.0');
    final extendedConfig = TouchpadConfig(
      edges: const [
        EdgeConfig(
          enabled: true,
          action: EdgeAction.horizontalArrowKeys,
          repeatWhileHeld: true,
        ),
        EdgeConfig(),
        EdgeConfig(
          enabled: true,
          action: EdgeAction.verticalArrowKeys,
          reversed: true,
          repeatWhileHeld: true,
        ),
        EdgeConfig(),
      ],
    );
    expect(
      Packet(Command.write, 5, payload: extendedConfig.encode()).encode(),
      fixtures['edge_extensions_write_request'],
    );
    expect(
      Packet(Command.read, 6, payload: extendedConfig.encode()).encode(),
      fixtures['edge_extensions_read_response'],
    );
  });
  test('64 firmware bytes are distinct from 65 Windows bytes', () {
    final report = Uint8List.fromList([0, ...fixtures['info_request']!]);
    expect(() => Packet.decode(report), throwsFormatException);
    expect(
      Packet.decode(Uint8List.sublistView(report, 1)).command,
      Command.info,
    );
    expect(() => Packet.decode(Uint8List(63)), throwsFormatException);
  });
  test('Little endian sequence supports high bytes', () {
    final bytes = Packet(Command.read, 0xAB12).encode();
    expect(bytes.sublist(6, 8), [0x12, 0xAB]);
    expect(Packet.decode(bytes).sequence, 0xAB12);
  });
  test('Malformed packet and unsupported version are rejected', () {
    for (final position in [0, 5, 6, 8, 10, 63]) {
      final bytes = Uint8List.fromList(fixtures['info_request']!);
      bytes[position] = position == 6 ? 0 : 255;
      expect(
        () => Packet.decode(bytes),
        throwsFormatException,
        reason: 'byte $position',
      );
    }
    final version = Uint8List.fromList(fixtures['info_request']!)..[4] = 2;
    expect(() => Packet.decode(version), throwsA(isA<ProtocolException>()));
    expect(() => Packet(Command.read, 0).encode(), throwsFormatException);
    expect(
      () => Packet(Command.read, 1, payload: Uint8List(53)).encode(),
      throwsFormatException,
    );
  });
  test('Pressure thresholds and timing constraints reject invalid data', () {
    for (final config in [
      TouchpadConfig(light: 0),
      TouchpadConfig(light: 101),
      TouchpadConfig(strong: 99),
      TouchpadConfig(strong: 256),
      TouchpadConfig(intensity: 101),
      TouchpadConfig(pressLevel: 0),
      TouchpadConfig(rotation: 4),
      TouchpadConfig(sleepMs: 999),
      TouchpadConfig(sleepMs: 1500),
      TouchpadConfig(sleepMs: 3600001),
    ]) {
      expect(() => config.encode(), throwsFormatException);
    }
    expect(
      TouchpadConfig(light: 1, medium: 1, strong: 255).validationError,
      isNull,
    );
  });
  test(
    'Configuration decoder rejects invalid enum, bool, reserved and length',
    () {
      for (final change in [
        (6, 2),
        (7, 16),
        (12, 2),
        (13, 7),
        (14, 2),
        (15, 31),
        (20, 31),
        (25, 16),
        (30, 16),
        (16, 0),
      ]) {
        final bytes = TouchpadConfig().encode()..[change.$1] = change.$2;
        expect(() => TouchpadConfig.decode(bytes), throwsFormatException);
      }
      expect(() => TouchpadConfig.decode(Uint8List(31)), throwsFormatException);
      final info = Packet.decode(fixtures['info_response']!).payload..[10] = 3;
      expect(() => DeviceInfo.decode(info), throwsFormatException);
    },
  );
  test('Unsupported groups retain device values in full writes', () {
    final device = TouchpadConfig(rotation: 2);
    final draft = TouchpadConfig(intensity: 70, light: 200, rotation: 1);
    final target = device.merge(draft, Capability.intensity);
    expect(target.intensity, 70);
    expect(target.light, 80);
    expect(target.rotation, 2);
    expect(target.validationError, isNull);
  });
  test('All four edge mappings, direction inversion and coordinate axes', () {
    final e = EdgeConfig(enabled: true, action: EdgeAction.volume);
    expect(e.direction(EdgeSide.left), '向上 增加音量 · 向下 降低音量');
    expect(
      e.copyWith(reversed: true).direction(EdgeSide.top),
      '向左 增加音量 · 向右 降低音量',
    );
    final config = TouchpadConfig(
      edges: [
        for (var i = 0; i < 4; i++)
          EdgeConfig(
            enabled: true,
            action: EdgeAction.values[i + 1],
            reversed: i.isOdd,
            width: i < 2 ? 30 : 15,
            step: i + 2,
          ),
      ],
    );
    expect(TouchpadConfig.decode(config.encode()).same(config), isTrue);
    expect(config.encode()[15], 30);
    expect(config.encode()[20], 30);
    expect(config.encode()[25], 15);
    expect(config.encode()[30], 15);
    expect(
      e.copyWith(action: EdgeAction.horizontalWheel).direction(EdgeSide.bottom),
      '向右 向右滚动 · 向左 向左滚动',
    );
  });
  test('Arrow actions and independent repeat bits retain 32-byte layout', () {
    for (var mask = 0; mask < 16; mask++) {
      final config = TouchpadConfig(
        edges: [
          for (final side in EdgeSide.values)
            EdgeConfig(
              enabled: true,
              action: side.index.isEven
                  ? EdgeAction.verticalArrowKeys
                  : EdgeAction.horizontalArrowKeys,
              reversed: side.index.isOdd,
              repeatWhileHeld: mask & (1 << side.index) != 0,
            ),
        ],
      );
      final bytes = config.encode();
      expect(bytes.length, 32);
      expect(bytes[7], mask);
      expect([bytes[13], bytes[18], bytes[23], bytes[28]], [5, 6, 5, 6]);
      expect(TouchpadConfig.decode(bytes).same(config), isTrue);
    }
    for (final side in EdgeSide.values) {
      final positive = side.index < 2 ? '向右' : '向上';
      final negative = side.index < 2 ? '向左' : '向下';
      for (final reversed in [false, true]) {
        final a = reversed ? negative : positive;
        final b = reversed ? positive : negative;
        final edge = EdgeConfig(
          enabled: true,
          action: EdgeAction.verticalArrowKeys,
          reversed: reversed,
        );
        expect(edge.direction(side), '$a 按 ↑ · $b 按 ↓');
        expect(
          edge.copyWith(action: EdgeAction.horizontalArrowKeys).direction(side),
          '$a 按 → · $b 按 ←',
        );
      }
    }
  });
}
