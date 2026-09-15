import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app_controller.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/config.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/device_client.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/protocol.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/transport.dart';

class RecordingTransport extends MockHidTransport {
  RecordingTransport({super.configVersion, super.capabilities, super.legacy});
  final writeLengths = <int>[];
  int? readVersion;
  @override
  Future<void> send(Uint8List bytes) async {
    final packet = Packet.decode(bytes);
    if (packet.command == Command.write) {
      writeLengths.add(packet.payload.length);
    }
    await super.send(bytes);
    if (packet.command == Command.read && readVersion != null) {
      replies.removeLast();
      replies.add(
        Packet(
          Command.read,
          packet.sequence,
          payload: config.encode(version: readVersion!),
        ).encode(),
      );
    }
  }
}

TouchpadConfig pointDraft(TouchpadConfig current) => current.copyWith(
  points: [
    for (final position in PointPosition.values)
      PointConfig(
        enabled: true,
        action: PointAction.values[9 + position.index],
        radius: position.index + 6,
        step: position.index + 3,
        repeatWhileHeld: true,
        allowPointToEdge: position.index.isEven,
      ),
  ],
);

void main() {
  test(
    'Every point conversion mask round trips independently of sleep and repeat',
    () {
      for (final sleep in [false, true]) {
        for (var mask = 0; mask < 16; mask++) {
          final config = TouchpadConfig(
            sleepEnabled: sleep,
            points: [
              for (var i = 0; i < 4; i++)
                PointConfig(
                  allowPointToEdge: mask & (1 << i) != 0,
                  repeatWhileHeld: i.isOdd,
                ),
            ],
          );
          final bytes = config.encode(version: 2);
          expect(bytes[6], (mask << 1) | (sleep ? 1 : 0));
          expect(bytes[7], 0xa0);
          final readback = TouchpadConfig.decode(bytes, version: 2);
          expect(readback.pointToEdgeMask, mask);
          expect(readback.sleepEnabled, sleep);
          expect(readback.same(config), isTrue);
          if (mask != 0) {
            expect(
              readback.same(
                config.copyWith(
                  points: [
                    for (final p in config.points)
                      p.copyWith(allowPointToEdge: false),
                  ],
                ),
              ),
              isFalse,
            );
          }
        }
      }
    },
  );

  test(
    'Point conversion previews do not leak through supported point saves',
    () async {
      final mock = MockHidTransport(
        capabilities: Capability.points | Capability.edges,
      );
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      c.update(
        c.draft.copyWith(
          points: [
            const PointConfig(allowPointToEdge: true),
            ...c.draft.points.skip(1),
          ],
        ),
      );
      expect(c.canApply, isFalse);
      c.update(
        c.draft.copyWith(
          points: [
            c.draft.points[0].copyWith(radius: 10),
            ...c.draft.points.skip(1),
          ],
        ),
      );
      await c.apply();
      expect(c.error, isNull);
      expect(c.current!.points[0].radius, 10);
      expect(c.current!.pointToEdgeMask, 0);
      expect(c.draft.pointToEdgeMask, 1);
      expect(c.unsupportedChanges, isTrue);
      expect(c.canApply, isFalse);
      mock.config = mock.config.copyWith(
        points: [
          mock.config.points[0].copyWith(allowPointToEdge: true),
          ...mock.config.points.skip(1),
        ],
      );
      await expectLater(c.client.readConfig(), throwsFormatException);
    },
  );

  test('Fixed v2 bytes include points without shifting v1 edges', () {
    final fixtures = jsonDecode(
      File('test/fixtures/protocol_vectors.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    Uint8List vector(String name) => Uint8List.fromList(
      (fixtures[name] as String)
          .split(' ')
          .map((v) => int.parse(v, radix: 16))
          .toList(),
    );
    final config = TouchpadConfig(
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
      points: const [
        PointConfig(
          enabled: true,
          action: PointAction.volumeUp,
          allowPointToEdge: true,
        ),
        PointConfig(
          enabled: true,
          action: PointAction.volumeUp,
          radius: 10,
          step: 3,
          repeatWhileHeld: true,
        ),
        PointConfig(
          enabled: true,
          action: PointAction.arrowUp,
          allowPointToEdge: true,
          radius: 15,
          step: 4,
        ),
        PointConfig(
          enabled: true,
          action: PointAction.arrowRight,
          radius: 1,
          step: 10,
          repeatWhileHeld: true,
        ),
      ],
    );
    expect(
      Packet(Command.write, 8, payload: config.encode(version: 2)).encode(),
      vector('point_write_request'),
    );
    final readback = TouchpadConfig.decode(
      Packet.decode(vector('point_read_response')).payload,
      version: 2,
    );
    expect(readback.same(config), isTrue);
    final legacyReadback = TouchpadConfig.decode(
      Packet.decode(vector('legacy_point_read_response')).payload,
      version: 2,
    );
    expect(legacyReadback.same(config), isTrue);
    expect(readback.repeatMask, 5);
    expect(readback.pointRepeatMask, 10);
    expect(readback.pointToEdgeMask, 5);
    final info = DeviceInfo.decode(
      Packet.decode(vector('point_info_response')).payload,
    );
    expect(info.configVersion, 2);
    expect(info.capabilities, Capability.all);
    expect(
      config.encode(version: 2).sublist(12, 32),
      config
          .copyWith(points: List.filled(4, const PointConfig()))
          .encode()
          .sublist(12),
    );
    expect(() => config.encode(), throwsFormatException);
  });

  test('Legacy point reversal becomes the concrete binding and writes reserved zero', () {
    for (final pair in [
      (PointAction.off, PointAction.off),
      (PointAction.brightnessUp, PointAction.brightnessDown),
      (PointAction.volumeUp, PointAction.volumeDown),
      (PointAction.wheelUp, PointAction.wheelDown),
      (PointAction.wheelRight, PointAction.wheelLeft),
      (PointAction.arrowUp, PointAction.arrowDown),
      (PointAction.arrowRight, PointAction.arrowLeft),
    ]) {
      for (final action in [pair.$1, pair.$2]) {
        final oldBytes = TouchpadConfig(
          points: [
            PointConfig(enabled: action != PointAction.off, action: action),
            const PointConfig(),
            const PointConfig(),
            const PointConfig(),
          ],
        ).encode(version: 2)..[34] = 1;
        final decoded = TouchpadConfig.decode(oldBytes, version: 2);
        final expected = action == pair.$1 ? pair.$2 : pair.$1;
        expect(decoded.points[0].action, expected);
        expect(decoded.encode(version: 2)[33], expected.index);
        expect(decoded.encode(version: 2)[34], 0);
      }
    }
  });

  test(
    'Quarter circles use short-side radius, include boundary and clip outside',
    () {
      const p = PointConfig(radius: 10);
      // Landscape and portrait are already-rotated logical surfaces.
      for (final size in [(200.0, 100.0), (100.0, 200.0)]) {
        expect(p.radiusFor(size.$1, size.$2), 10);
        for (final position in PointPosition.values) {
          final cx = position.centerX(size.$1), cy = position.centerY(size.$2);
          final sx = position.index.isOdd ? -1 : 1;
          final sy = position.index >= 2 ? -1 : 1;
          bool hit(double dx, double dy) => p.contains(
            position,
            cx + dx * sx,
            cy + dy * sy,
            size.$1,
            size.$2,
          );
          expect(hit(0, 0), isTrue);
          expect(hit(6, 8), isTrue);
          expect(hit(10, 0), isTrue);
          expect(hit(0, 10), isTrue);
          expect(hit(8, 8), isFalse); // Inside the square, outside the circle.
          expect(hit(10.01, 0), isFalse);
          expect(hit(-1, 0), isFalse);
          expect(hit(0, -1), isFalse);
          expect(
            p.contains(position, size.$1 / 2, size.$2 / 2, size.$1, size.$2),
            isFalse,
          );
        }
      }
    },
  );

  test('V2 validates booleans, flags, point records, lengths and versions', () {
    for (final radius in [1, 16, 30]) {
      final config = TouchpadConfig(
        points: List.filled(4, PointConfig(radius: radius)),
      );
      expect(config.validationError, isNull);
      expect(
        TouchpadConfig.decode(
          config.encode(version: 2),
          version: 2,
        ).same(config),
        isTrue,
      );
    }
    for (final change in [
      (6, 32),
      (32, 2),
      (33, 13),
      (34, 2),
      (35, 0),
      (35, 31),
      (36, 0),
      (36, 11),
    ]) {
      final bytes = TouchpadConfig().encode(version: 2)
        ..[change.$1] = change.$2;
      expect(
        () => TouchpadConfig.decode(bytes, version: 2),
        throwsFormatException,
      );
    }
    for (final length in [0, 31, 32, 51, 53]) {
      expect(
        () => TouchpadConfig.decode(Uint8List(length), version: 2),
        throwsFormatException,
      );
    }
    expect(
      () => TouchpadConfig.decode(TouchpadConfig().encode(version: 2)),
      throwsFormatException,
    );
    expect(() => TouchpadConfig().encode(version: 3), throwsFormatException);
    expect(
      () => TouchpadConfig.decode(Uint8List(52), version: 3),
      throwsFormatException,
    );
    expect(TouchpadConfig(points: []).validationError, isNotNull);
    expect(
      TouchpadConfig(points: List.filled(4, const PointConfig(enabled: true)))
          .validationError,
      isNotNull,
    );
    for (var mask = 0; mask < 16; mask++) {
      final c = TouchpadConfig(
        points: [
          for (var n = 0; n < 4; n++)
            PointConfig(repeatWhileHeld: mask & (1 << n) != 0),
        ],
      );
      final bytes = c.encode(version: 2);
      expect(bytes[7], mask << 4);
      expect(TouchpadConfig.decode(bytes, version: 2).same(c), isTrue);
    }
  });

  test(
    'Handshake selects write layout and independently gates point capabilities',
    () async {
      for (final version in [1, 2]) {
        for (final mask in [
          Capability.v1,
          Capability.all,
          Capability.points,
          Capability.pointToEdge,
          Capability.edges | Capability.pointToEdge,
          Capability.points | Capability.pointToEdge,
          Capability.edges | Capability.points,
        ]) {
          final mock = RecordingTransport(
            configVersion: version,
            capabilities: mask,
          );
          final client = DeviceClient(mock);
          try {
            final current = await client.connect('demo');
            final draft = pointDraft(current);
            final result = await client.apply(draft, current);
            final pointsSupported =
                version == 2 && mask & Capability.points != 0;
            final conversionSupported =
                version == 2 &&
                mask & Capability.points != 0 &&
                mask & Capability.edges != 0 &&
                mask & Capability.pointToEdge != 0;
            expect(result.config!.points[0].enabled, pointsSupported);
            expect(result.config!.pointRepeatMask, pointsSupported ? 15 : 0);
            expect(result.config!.pointToEdgeMask, conversionSupported ? 5 : 0);
            expect(mock.writeLengths, [version == 1 ? 32 : 52]);
            expect(result.config!.edges.every((e) => !e.enabled), isTrue);
          } finally {
            await client.close();
          }
        }
      }
    },
  );

  test('Readback rejects unadvertised point fields and wrong layout', () async {
    for (final config in [
      TouchpadConfig(
        points: List.filled(4, const PointConfig(allowPointToEdge: true)),
      ),
      TouchpadConfig(points: List.filled(4, const PointConfig(radius: 6))),
      TouchpadConfig(
        points: List.filled(4, const PointConfig(repeatWhileHeld: true)),
      ),
    ]) {
      final mock = MockHidTransport(capabilities: Capability.v1)
        ..config = config;
      final client = DeviceClient(mock);
      await expectLater(client.connect('demo'), throwsFormatException);
      await client.close();
    }
    for (final version in [1, 2]) {
      final mock = RecordingTransport(configVersion: version)
        ..readVersion = 3 - version;
      final client = DeviceClient(mock);
      await expectLater(client.connect('demo'), throwsFormatException);
      await client.close();
    }
  });

  test('Unsupported point edits remain drafts during supported saves and reconnect', () async {
    for (final legacy in [false, true]) {
      final mock = RecordingTransport(configVersion: 1, legacy: legacy);
      final c = AppController(transport: mock);
      try {
        await c.scan();
        c.update(pointDraft(c.draft));
        expect(c.canApply, isFalse);
        expect(c.unsupportedChanges, isTrue);
        await c.apply();
        expect(mock.writes, 0);
        c.update(c.draft.copyWith(intensity: 75));
        await c.apply();
        expect(c.error, isNull);
        expect(c.current!.intensity, 75);
        expect(c.current!.points.every((p) => p.isDefault), isTrue);
        expect(c.draft.points[0].radius, 6);
        expect(c.draft.pointToEdgeMask, 5);
        await c.connect(c.devices.first);
        expect(c.draft.points[3].action, PointAction.arrowLeft);
        expect(c.unsupportedChanges, isTrue);
        if (!legacy) expect(mock.writeLengths, [32]);
      } finally {
        c.dispose();
      }
    }
  });

  test(
    'Point writes detect ignored or failed storage and verify after reconnect',
    () async {
      final mock = MockHidTransport();
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      c.update(pointDraft(c.draft));
      mock.ignoreWrites = true;
      await c.apply();
      expect(c.error, contains('读回值与提交值不一致'));
      expect(c.draft.pointToEdgeMask, 5);
      expect(c.current!.pointToEdgeMask, 0);
      mock.ignoreWrites = false;
      mock.writeStatus = Status.storage;
      await c.apply();
      expect(c.error, contains('保存失败'));
      expect(c.draft.points[3].enabled, isTrue);
      mock.writeStatus = Status.reconnect;
      await c.apply();
      expect(c.connected, isFalse);
      expect(c.current, isNull);
      await c.scan();
      expect(c.error, isNull);
      expect(c.connected, isTrue);
      expect(c.current!.same(c.draft), isTrue);
      expect(c.message, contains('读回校验通过'));
    },
  );
}
