import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app_controller.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/config.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/device_client.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/protocol.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/transport.dart';

class DelayedHapticsTransport extends MockHidTransport {
  Completer<void>? pendingRead;

  @override
  Future<Uint8List> read(int timeoutMs) async {
    await pendingRead?.future;
    return super.read(timeoutMs);
  }
}

Uint8List documentedVector(String name) {
  final doc = File('FIRMWARE.md').readAsStringSync();
  final marker = doc.indexOf('<!-- vector: $name -->');
  expect(marker, greaterThanOrEqualTo(0));
  final start = doc.indexOf('```text', marker) + 7;
  final end = doc.indexOf('```', start);
  return Uint8List.fromList(
    doc
        .substring(start, end)
        .trim()
        .split(RegExp(r'\s+'))
        .map((v) => int.parse(v, radix: 16))
        .toList(),
  );
}

void main() {
  test('V5 documented bytes and both independent switches round trip', () {
    final defaults = TouchpadConfig(autoSwitchConnection: true);
    expect(defaults.customGestureHaptics, isTrue);
    expect(defaults.encode(version: 5), documentedVector('v5_enabled'));
    final info = DeviceInfo.decode(documentedVector('v5_info'));
    expect(info.configVersion, 5);
    expect(info.capabilities, Capability.all);
    for (final auto in [false, true]) {
      for (final haptics in [false, true]) {
        final config = defaults.copyWith(
          autoSwitchConnection: auto,
          customGestureHaptics: haptics,
          wirelessLight: 25,
          points: List.filled(
            4,
            const PointConfig(
              enabled: true,
              action: PointAction.copy,
              allowPointToEdge: true,
              repeatWhileHeld: true,
            ),
          ),
        );
        final bytes = config.encode(version: 5);
        expect(bytes.length, 52);
        expect(bytes[51], (auto ? 1 : 0) | (haptics ? 2 : 0));
        final packet = Packet(Command.write, 1, payload: bytes).encode();
        expect(packet.length, 64);
        expect(
          TouchpadConfig.decode(
            Packet.decode(packet).payload,
            version: 5,
          ).same(config),
          isTrue,
        );
        final opposite = config.copyWith(customGestureHaptics: !haptics);
        expect(config.same(opposite), isFalse);
        expect(config.same(opposite, Capability.v4), isTrue);
      }
    }
    expect(
      defaults.encode(version: 5).take(51),
      defaults.encode(version: 4).take(51),
    );
    for (final value in [4, 128, 255]) {
      final bytes = defaults.encode(version: 5)..[51] = value;
      expect(
        () => TouchpadConfig.decode(bytes, version: 5),
        throwsFormatException,
      );
    }
    expect(
      () => TouchpadConfig.decode(Uint8List(51), version: 5),
      throwsFormatException,
    );
  });

  test(
    'Older versions keep compatibility defaults and reject disabled encoding',
    () {
      for (final version in [1, 2, 3, 4]) {
        final defaults = TouchpadConfig();
        expect(
          TouchpadConfig.decode(
            defaults.encode(version: version),
            version: version,
          ).customGestureHaptics,
          isTrue,
        );
        expect(
          () => defaults
              .copyWith(customGestureHaptics: false)
              .encode(version: version),
          throwsFormatException,
        );
        expect(
          Capability.negotiated(Capability.all, version) &
              Capability.customGestureHaptics,
          0,
        );
      }
      expect(
        Capability.negotiated(Capability.customGestureHaptics, 5),
        Capability.customGestureHaptics,
      );
      expect(Capability.negotiated(0xffffffff, 5), 0x3fff);
    },
  );

  test(
    'Windows 11 saves false, reconnects, refreshes, and enables again',
    () async {
      final mock = MockHidTransport(
        capabilities: Capability.customGestureHaptics,
      );
      final c = AppController(transport: mock, isWindows11: true);
      addTearDown(c.dispose);
      await c.scan();
      expect(c.draft.customGestureHaptics, isTrue);
      expect(c.canApply, isFalse);
      c.update(c.draft.copyWith(customGestureHaptics: false));
      expect(c.canApply, isTrue);
      await c.apply();
      expect(c.error, isNull);
      expect(mock.config.customGestureHaptics, isFalse);
      await c.connect(c.devices.first);
      await c.refresh();
      expect(c.draft.customGestureHaptics, isFalse);
      expect(c.canApply, isFalse);
      c.update(c.draft.copyWith(customGestureHaptics: true));
      await c.apply();
      expect(c.error, isNull);
      expect(mock.config.customGestureHaptics, isTrue);
      expect(mock.writes, 2);
    },
  );

  test(
    'Unsupported previews survive other saves without changing device values',
    () async {
      for (final mock in [
        MockHidTransport(legacy: true),
        for (final version in [1, 2, 3, 4])
          MockHidTransport(configVersion: version),
        MockHidTransport(capabilities: Capability.v4),
      ]) {
        final c = AppController(transport: mock, isWindows11: false);
        addTearDown(c.dispose);
        await c.scan();
        c.update(c.draft.copyWith(customGestureHaptics: false));
        expect(c.canApply, isFalse);
        await c.apply();
        expect(mock.writes, 0);
        c.update(c.draft.copyWith(intensity: 70));
        await c.apply();
        expect(c.error, isNull);
        expect(mock.config.intensity, 70);
        expect(mock.config.customGestureHaptics, isTrue);
        await c.connect(c.devices.first);
        expect(c.current!.customGestureHaptics, isTrue);
        expect(c.draft.customGestureHaptics, isFalse);
        expect(c.unsupportedChanges, isTrue);
      }
    },
  );

  test('Unadvertised disabled readback is rejected', () async {
    final mock = MockHidTransport(capabilities: Capability.v4)
      ..config = TouchpadConfig(customGestureHaptics: false);
    final client = DeviceClient(mock);
    addTearDown(client.close);
    await expectLater(client.connect('demo'), throwsFormatException);
    expect(client.known, 0);
  });

  test('Failed writes and mismatched readback retain the draft', () async {
    for (final storageFailure in [false, true]) {
      final mock = MockHidTransport()
        ..ignoreWrites = !storageFailure
        ..writeStatus = storageFailure ? Status.storage : Status.ok;
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      c.update(c.draft.copyWith(customGestureHaptics: false));
      await c.apply();
      expect(c.error, contains(storageFailure ? '保存失败' : '读回值与提交值不一致'));
      expect(c.current!.customGestureHaptics, isTrue);
      expect(c.draft.customGestureHaptics, isFalse);
      expect(mock.writes, 1);
    }
  });

  test(
    'Reconnect checks gesture feedback before confirming the saved config',
    () async {
      for (final ignore in [false, true]) {
        final mock = MockHidTransport()
          ..writeStatus = Status.reconnect
          ..ignoreWrites = ignore;
        final c = AppController(transport: mock);
        addTearDown(c.dispose);
        await c.scan();
        c.update(c.draft.copyWith(customGestureHaptics: false));
        await c.apply();
        expect(c.connected, isFalse);
        await c.scan();
        expect(c.connected, isTrue);
        if (ignore) {
          expect(c.error, contains('重连后读回不一致'));
        } else {
          expect(c.error, isNull);
          expect(c.current!.customGestureHaptics, isFalse);
        }
      }
    },
  );

  testWidgets(
    'Other settings toggles gesture feedback and disables it while busy',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final mock = DelayedHapticsTransport();
      final c = AppController(transport: mock, isWindows11: true);
      addTearDown(c.dispose);
      await c.scan();
      await tester.pumpWidget(TouchpadApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '设备设置'));
      await tester.pumpAndSettle();
      expect(find.text('其他设置'), findsOneWidget);
      final toggle = find.widgetWithText(SwitchListTile, '触发自定义手势时开启振动反馈');
      await tester.ensureVisible(toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(c.canApply, isTrue);
      mock.pendingRead = Completer<void>();
      final saving = c.apply();
      await tester.pump();
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
      mock.pendingRead!.complete();
      await saving;
      mock.pendingRead = null;
      await tester.pumpAndSettle();
      expect(c.error, isNull);
      expect(mock.config.customGestureHaptics, isFalse);
      expect(mock.config.autoSwitchConnection, isTrue);
      mock.present = false;
      await c.scan();
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Old firmware shows an explicit gesture feedback preview notice',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final mock = MockHidTransport(configVersion: 4);
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      await tester.pumpWidget(TouchpadApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '设备设置'));
      await tester.pumpAndSettle();
      expect(find.text('当前设备不支持自定义手势振动反馈配置，此设置仅保留为预览，不会写入设备。'), findsOneWidget);
      final toggle = find.widgetWithText(SwitchListTile, '触发自定义手势时开启振动反馈');
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(c.draft.customGestureHaptics, isFalse);
      expect(c.canApply, isFalse);
      expect(mock.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
