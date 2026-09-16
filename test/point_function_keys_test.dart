import 'package:flutter_test/flutter_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app_controller.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/config.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/device_client.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/transport.dart';

void main() {
  test('Function key IDs and point records follow the firmware contract', () {
    const actions = [
      PointAction.mute,
      PointAction.playPause,
      PointAction.previousTrack,
      PointAction.nextTrack,
      PointAction.mediaStop,
      PointAction.escape,
      PointAction.enter,
      PointAction.tab,
      PointAction.space,
      PointAction.backspace,
      PointAction.delete,
      PointAction.insert,
      PointAction.home,
      PointAction.end,
      PointAction.pageUp,
      PointAction.pageDown,
      PointAction.printScreen,
      PointAction.f1,
      PointAction.f2,
      PointAction.f3,
      PointAction.f4,
      PointAction.f5,
      PointAction.f6,
      PointAction.f7,
      PointAction.f8,
      PointAction.f9,
      PointAction.f10,
      PointAction.f11,
      PointAction.f12,
      PointAction.copy,
      PointAction.paste,
      PointAction.cut,
      PointAction.undo,
      PointAction.redo,
      PointAction.selectAll,
    ];
    expect(pointActionNames.length, PointAction.values.length);
    for (final version in [2, 3]) {
      for (var n = 0; n < actions.length; n++) {
        final config = TouchpadConfig(
          points: List.filled(
            4,
            PointConfig(enabled: true, action: actions[n]),
          ),
        );
        final bytes = config.encode(version: version);
        expect(bytes.length, 52);
        for (var p = 0; p < 4; p++) {
          final offset = 32 + p * (version == 2 ? 5 : 4);
          expect(
            bytes.sublist(offset, offset + (version == 2 ? 5 : 4)),
            version == 2 ? [1, 13 + n, 0, 5, 2] : [1, 13 + n, 5, 2],
          );
        }
        expect(
          TouchpadConfig.decode(bytes, version: version).same(config),
          isTrue,
        );
        if (version == 2) {
          bytes[34] = 1;
          expect(
            () => TouchpadConfig.decode(bytes, version: 2),
            throwsFormatException,
          );
        }
      }
      for (final invalid in [48, 255]) {
        final bytes = TouchpadConfig().encode(version: version)..[33] = invalid;
        expect(
          () => TouchpadConfig.decode(bytes, version: version),
          throwsFormatException,
        );
      }
    }
  });

  test('Function key capability requires v2 or v3 and base points only', () {
    expect(Capability.pointFunctionKeys, 0x800);
    expect(Capability.negotiated(0xfff, 1), 0xff);
    expect(Capability.negotiated(0xfff, 2), 0xbff);
    expect(Capability.negotiated(0xfff, 3), 0xfff);
    for (final version in [2, 3]) {
      expect(Capability.negotiated(0x800, version), 0);
      expect(Capability.negotiated(0x900, version), 0x900);
    }
  });

  test(
    'Old firmware preserves the whole point while other edits save',
    () async {
      for (final version in [2, 3]) {
        final mock =
            MockHidTransport(configVersion: version, capabilities: 0x7ff)
              ..config = TouchpadConfig(
                points: const [
                  PointConfig(action: PointAction.volumeDown),
                  PointConfig(),
                  PointConfig(),
                  PointConfig(),
                ],
              );
        final c = AppController(transport: mock);
        try {
          await c.scan();
          final original = c.current!;
          c.update(
            c.draft.copyWith(
              points: [
                const PointConfig(
                  enabled: true,
                  action: PointAction.copy,
                  radius: 15,
                  step: 4,
                  repeatWhileHeld: true,
                  allowPointToEdge: true,
                ),
                ...c.draft.points.skip(1),
              ],
            ),
          );
          expect(c.canApply, isFalse);
          expect(c.unsupportedChanges, isTrue);
          c.update(
            c.draft.copyWith(
              rotation: 1,
              points: [
                c.draft.points[0],
                const PointConfig(enabled: true, action: PointAction.arrowUp),
                ...c.draft.points.skip(2),
              ],
            ),
          );
          await c.apply();
          expect(c.error, isNull);
          expect(c.current!.rotation, 1);
          expect(c.current!.points[0].bytes, original.points[0].bytes);
          expect(c.current!.pointRepeatMask, 0);
          expect(c.current!.pointToEdgeMask, 0);
          expect(c.current!.points[1].action, PointAction.arrowUp);
          expect(c.draft.points[0].action, PointAction.copy);
          expect(c.unsupportedChanges, isTrue);
          await c.connect(c.devices.first);
          expect(c.draft.points[0].action, PointAction.copy);
          expect(c.canApply, isFalse);
        } finally {
          c.dispose();
        }
      }
    },
  );

  test(
    'New firmware saves every function key and reads it after reconnect',
    () async {
      for (final version in [2, 3]) {
        final client = DeviceClient(
          MockHidTransport(configVersion: version, capabilities: 0x900),
        );
        try {
          var current = await client.connect('demo');
          for (final action in PointAction.values.where(
            (a) => a.isFunctionKey,
          )) {
            final desired = current.copyWith(
              points: List.filled(
                4,
                PointConfig(
                  enabled: true,
                  action: action,
                  repeatWhileHeld: true,
                ),
              ),
            );
            final result = await client.apply(desired, current);
            expect(result.config!.same(desired), isTrue);
            current = result.config!;
          }
          await client.close();
          expect((await client.connect('demo')).same(current), isTrue);
        } finally {
          await client.close();
        }
      }
    },
  );

  test(
    'Readback rejects unadvertised function keys even on disabled points',
    () async {
      for (final version in [2, 3]) {
        for (final enabled in [false, true]) {
          final mock =
              MockHidTransport(configVersion: version, capabilities: 0x7ff)
                ..config = TouchpadConfig(
                  points: List.filled(
                    4,
                    PointConfig(enabled: enabled, action: PointAction.mute),
                  ),
                );
          final client = DeviceClient(mock);
          try {
            await expectLater(client.connect('demo'), throwsFormatException);
          } finally {
            await client.close();
          }
        }
      }
    },
  );
}
