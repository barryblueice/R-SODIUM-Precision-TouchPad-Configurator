import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app_controller.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/config.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/device_client.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/protocol.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/transport.dart';

void main() {
  test(
    'V3 fits a packet and preserves both threshold groups and all points',
    () {
      final config = TouchpadConfig(
        light: 90,
        medium: 120,
        strong: 255,
        wirelessLight: 1,
        wirelessMedium: 50,
        wirelessStrong: 100,
        points: [
          for (var i = 0; i < 4; i++)
            PointConfig(
              enabled: true,
              action: PointAction.values[2 + i],
              radius: 4 + i,
              step: 1 + i,
              allowPointToEdge: i.isEven,
              repeatWhileHeld: i.isOdd,
            ),
        ],
      );
      final bytes = config.encode(version: 3);
      expect(bytes.length, 52);
      expect(bytes.sublist(2, 5), [90, 120, 255]);
      expect(bytes.sublist(32), [
        1,
        2,
        4,
        1,
        1,
        3,
        5,
        2,
        1,
        4,
        6,
        3,
        1,
        5,
        7,
        4,
        1,
        50,
        100,
        0,
      ]);
      final packet = Packet(Command.write, 1, payload: bytes).encode();
      expect(packet.length, 64);
      expect(
        TouchpadConfig.decode(
          Packet.decode(packet).payload,
          version: 3,
        ).same(config),
        isTrue,
      );
      for (final version in [1, 2]) {
        expect(() => config.encode(version: version), throwsFormatException);
      }
      for (final change in [
        (48, 0),
        (49, 101),
        (50, 101),
        (51, 1),
        (32, 2),
        (33, 13),
      ]) {
        final invalid = Uint8List.fromList(bytes)..[change.$1] = change.$2;
        expect(
          () => TouchpadConfig.decode(invalid, version: 3),
          throwsFormatException,
        );
      }
    },
  );

  test('Wireless validation is independent and includes equal endpoints', () {
    for (final config in [
      TouchpadConfig(wirelessLight: 0),
      TouchpadConfig(wirelessLight: 81),
      TouchpadConfig(wirelessMedium: 101),
      TouchpadConfig(wirelessStrong: 79),
      TouchpadConfig(wirelessStrong: 101),
    ]) {
      expect(config.validationError, contains('无线'));
      expect(() => config.encode(version: 3), throwsFormatException);
    }
    for (final value in [1, 100]) {
      expect(
        TouchpadConfig(
          wirelessLight: value,
          wirelessMedium: value,
          wirelessStrong: value,
        ).validationError,
        isNull,
      );
    }
  });

  test(
    'Wireless requires v3 and its own capability; old saves preserve drafts',
    () async {
      for (final version in [1, 2, 3]) {
        for (final advertised in [
          Capability.all,
          Capability.all & ~Capability.wirelessThresholds,
        ]) {
          final mock = MockHidTransport(
            configVersion: version,
            capabilities: advertised,
          );
          final c = AppController(transport: mock);
          try {
            await c.scan();
            final supported =
                version == 3 && advertised & Capability.wirelessThresholds != 0;
            expect(c.supports(Capability.wirelessThresholds), supported);
            c.update(
              c.draft.copyWith(
                wirelessLight: 30,
                wirelessMedium: 50,
                wirelessStrong: 70,
              ),
            );
            expect(c.canApply, supported);
            c.update(c.draft.copyWith(light: 90));
            await c.apply();
            expect(c.error, isNull);
            expect(c.current!.light, 90);
            expect(c.current!.wirelessLight, supported ? 30 : 60);
            expect(c.draft.wirelessLight, 30);
            expect(c.unsupportedChanges, !supported);
            await c.connect(c.devices.first);
            expect(c.draft.wirelessStrong, 70);
            expect(c.current!.strong, 130);
          } finally {
            c.dispose();
          }
        }
      }
    },
  );

  test(
    'Invalid wireless values block writes; readback detects ignored saves',
    () async {
      final mock = MockHidTransport();
      final c = AppController(transport: mock, isWindows11: true);
      addTearDown(c.dispose);
      await c.scan();
      c.update(c.draft.copyWith(wirelessStrong: 101));
      expect(c.canApply, isFalse);
      await c.apply();
      expect(mock.writes, 0);
      c.update(c.draft.copyWith(wirelessLight: 30, wirelessStrong: 90));
      mock.ignoreWrites = true;
      await c.apply();
      expect(c.error, contains('读回值与提交值不一致'));
      mock.ignoreWrites = false;
      mock.writeStatus = Status.reconnect;
      await c.apply();
      await c.scan();
      expect(c.error, isNull);
      expect(c.current!.wirelessLight, 30);
      expect(c.current!.wirelessStrong, 90);
      expect(c.current!.light, 80);
      expect(c.canApply, isFalse);
    },
  );

  test(
    'Readback rejects wireless values without advertised capability',
    () async {
      final mock = MockHidTransport(capabilities: Capability.v2)
        ..config = TouchpadConfig(wirelessLight: 30);
      final client = DeviceClient(mock);
      await expectLater(client.connect('demo'), throwsFormatException);
      await client.close();
    },
  );

  testWidgets(
    'Separate threshold editors enforce the wireless limit and save independently',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = AppController(transport: MockHidTransport(), isWindows11: true);
      addTearDown(c.dispose);
      await c.scan();
      await tester.pumpWidget(TouchpadApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.text('有线连接三档阈值'), findsOneWidget);
      expect(find.text('无线连接三档阈值'), findsOneWidget);
      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      final wireless = field('无线重档阈值');
      await tester.ensureVisible(wireless);
      await tester.enterText(wireless, '101');
      await tester.pumpAndSettle();
      expect(find.text('超出范围'), findsOneWidget);
      expect(c.canApply, isFalse);
      await tester.enterText(wireless, '90');
      await tester.pumpAndSettle();
      expect(c.canApply, isTrue);
      await c.apply();
      await tester.pumpAndSettle();
      expect(c.current!.wirelessStrong, 90);
      expect(c.current!.strong, 130);
      expect(tester.takeException(), isNull);
    },
  );
}
