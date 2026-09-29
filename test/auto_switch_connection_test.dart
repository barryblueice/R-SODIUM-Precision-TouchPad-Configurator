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

class DelayedSwitchReadTransport extends MockHidTransport {
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
  test('Published v4 vectors match wire bytes and retain the v3 prefix', () {
    final enabled = TouchpadConfig(autoSwitchConnection: true);
    final bytes = enabled.encode(version: 4);
    expect(bytes, documentedVector('v4_enabled'));
    expect(bytes.length, 52);
    expect(bytes.take(51), TouchpadConfig().encode(version: 3).take(51));
    final packet = Packet(Command.write, 42, payload: bytes).encode();
    expect(packet.length, 64);
    expect(packet[4], 1);
    expect(packet[63], 1);
    expect(
      TouchpadConfig.decode(
        Packet.decode(packet).payload,
        version: 4,
      ).same(enabled),
      isTrue,
    );
    final disabled = enabled.copyWith(autoSwitchConnection: false);
    expect(disabled.encode(version: 4)[51], 0);
    expect(
      TouchpadConfig.decode(
        disabled.encode(version: 4),
        version: 4,
      ).same(disabled),
      isTrue,
    );
    expect(enabled.same(disabled), isFalse);
    expect(enabled.same(disabled, Capability.v3), isTrue);
    final info = DeviceInfo.decode(documentedVector('v4_info'));
    expect(info.configVersion, 4);
    expect(info.capabilities, 0x1fff);
    expect(info.firmware, '1.0.0');
  });

  test(
    'V4 preserves non-default thresholds, point flags and edge settings',
    () {
      final config = TouchpadConfig(
        autoSwitchConnection: true,
        wirelessLight: 20,
        wirelessMedium: 40,
        wirelessStrong: 60,
        edges: List.filled(
          4,
          const EdgeConfig(
            enabled: true,
            action: EdgeAction.verticalArrowKeys,
            reversed: true,
            repeatWhileHeld: true,
          ),
        ),
        points: List.filled(
          4,
          const PointConfig(
            enabled: true,
            action: PointAction.copy,
            radius: 12,
            step: 3,
            allowPointToEdge: true,
            repeatWhileHeld: true,
          ),
        ),
      );
      expect(
        TouchpadConfig.decode(
          config.encode(version: 4),
          version: 4,
        ).same(config),
        isTrue,
      );
    },
  );

  test(
    'Older layouts stay strict and cannot silently discard an enabled switch',
    () {
      for (final version in [1, 2, 3]) {
        final config = TouchpadConfig();
        final bytes = config.encode(version: version);
        expect(bytes.length, version == 1 ? 32 : 52);
        expect(
          TouchpadConfig.decode(bytes, version: version).autoSwitchConnection,
          isFalse,
        );
        expect(
          () => config
              .copyWith(autoSwitchConnection: true)
              .encode(version: version),
          throwsFormatException,
        );
      }
      final v3 = TouchpadConfig().encode(version: 3)..[51] = 1;
      expect(
        () => TouchpadConfig.decode(v3, version: 3),
        throwsFormatException,
      );
      for (final value in [2, 128, 255]) {
        final invalid = TouchpadConfig().encode(version: 4)..[51] = value;
        expect(
          () => TouchpadConfig.decode(invalid, version: 4),
          throwsFormatException,
        );
      }
      expect(
        () => TouchpadConfig.decode(Uint8List(51), version: 4),
        throwsFormatException,
      );
      expect(() => TouchpadConfig().encode(version: 6), throwsFormatException);
      final unknown = documentedVector('v4_info')..[10] = 6;
      expect(() => DeviceInfo.decode(unknown), throwsFormatException);
    },
  );

  test('Capability requires v4 and is independent of wireless thresholds', () {
    for (final version in [1, 2, 3, 4]) {
      expect(Capability.negotiated(0x1000, version), version == 4 ? 0x1000 : 0);
    }
    expect(Capability.negotiated(0xffffffff, 1), 0x0ff);
    expect(Capability.negotiated(0xffffffff, 2), 0xbff);
    expect(Capability.negotiated(0xffffffff, 3), 0xfff);
    expect(Capability.negotiated(0xffffffff, 4), 0x1fff);
  });

  test(
    'Supported defaults enable the switch; saved false is never overwritten',
    () async {
      final mock = MockHidTransport(
        capabilities: Capability.autoSwitchConnection,
        configVersion: 4,
      );
      final c = AppController(transport: mock, isWindows11: true);
      addTearDown(c.dispose);
      await c.scan();
      expect(c.client.configVersion, 4);
      expect(c.draft.autoSwitchConnection, isTrue);
      expect(c.canApply, isFalse);
      c.update(c.draft.copyWith(autoSwitchConnection: false));
      expect(c.canApply, isTrue);
      await c.apply();
      expect(c.error, isNull);
      expect(mock.config.autoSwitchConnection, isFalse);
      await c.connect(c.devices.first);
      expect(c.draft.autoSwitchConnection, isFalse);
      expect(c.canApply, isFalse);
      c.update(c.draft.copyWith(autoSwitchConnection: true));
      await c.apply();
      expect(c.error, isNull);
      expect(c.current!.autoSwitchConnection, isTrue);
      expect(mock.writes, 2);
    },
  );

  test(
    'Unsupported devices preserve preview across other saves and reconnects',
    () async {
      for (final mock in [
        MockHidTransport(legacy: true),
        for (final version in [1, 2, 3])
          MockHidTransport(configVersion: version),
        MockHidTransport(capabilities: Capability.v3),
      ]) {
        final c = AppController(transport: mock, isWindows11: false);
        addTearDown(c.dispose);
        await c.scan();
        expect(c.current!.autoSwitchConnection, isFalse);
        c.update(c.draft.copyWith(autoSwitchConnection: true));
        expect(c.canApply, isFalse);
        await c.apply();
        expect(mock.writes, 0);
        c.update(c.draft.copyWith(intensity: 70));
        await c.apply();
        expect(c.error, isNull);
        expect(mock.config.autoSwitchConnection, isFalse);
        expect(mock.config.intensity, 70);
        expect(c.draft.autoSwitchConnection, isTrue);
        expect(c.unsupportedChanges, isTrue);
        await c.connect(c.devices.first);
        expect(c.draft.autoSwitchConnection, isTrue);
        expect(c.current!.autoSwitchConnection, isFalse);
      }
    },
  );

  test('Unadvertised enabled readback is rejected', () async {
    final mock = MockHidTransport(capabilities: Capability.v3)
      ..config = TouchpadConfig(autoSwitchConnection: true);
    final client = DeviceClient(mock);
    addTearDown(client.close);
    await expectLater(client.connect('demo'), throwsFormatException);
    expect(client.known, 0);
  });

  test(
    'Ignored writes and storage failure retain the draft without success',
    () async {
      for (final storageFailure in [false, true]) {
        final mock = MockHidTransport()
          ..ignoreWrites = !storageFailure
          ..writeStatus = storageFailure ? Status.storage : Status.ok;
        final c = AppController(transport: mock);
        addTearDown(c.dispose);
        await c.scan();
        c.update(c.draft.copyWith(autoSwitchConnection: false));
        await c.apply();
        expect(c.error, contains(storageFailure ? '保存失败' : '读回值与提交值不一致'));
        expect(c.current!.autoSwitchConnection, isTrue);
        expect(c.draft.autoSwitchConnection, isFalse);
        expect(c.canApply, isTrue);
        expect(mock.writes, 1);
      }
    },
  );

  test(
    'Timed-out writes are not retried and do not claim persistence',
    () async {
      final mock = MockHidTransport()..dropWriteReply = true;
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      c.update(c.draft.copyWith(autoSwitchConnection: false));
      await c.apply();
      expect(c.error, isNull);
      expect(c.current!.autoSwitchConnection, isFalse);
      expect(c.message, contains('持久化状态未确认'));
      expect(mock.writes, 1);
    },
  );

  test(
    'Reconnect verifies the switch value before reporting success',
    () async {
      for (final ignore in [false, true]) {
        final mock = MockHidTransport()
          ..writeStatus = Status.reconnect
          ..ignoreWrites = ignore;
        final c = AppController(transport: mock);
        addTearDown(c.dispose);
        await c.scan();
        c.update(c.draft.copyWith(autoSwitchConnection: false));
        await c.apply();
        expect(c.connected, isFalse);
        await c.scan();
        expect(c.connected, isTrue);
        if (ignore) {
          expect(c.error, contains('重连后读回不一致'));
        } else {
          expect(c.error, isNull);
          expect(c.message, contains('读回校验通过'));
          expect(c.current!.autoSwitchConnection, isFalse);
        }
      }
    },
  );

  testWidgets(
    'Windows 11 switch reads, saves, refreshes and disables while busy',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final mock = DelayedSwitchReadTransport();
      final c = AppController(transport: mock, isWindows11: true);
      addTearDown(c.dispose);
      await c.scan();
      await tester.pumpWidget(TouchpadApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '设备设置'));
      await tester.pumpAndSettle();
      final toggle = find.widgetWithText(
        SwitchListTile,
        '当有线连接断开时，自动切换到2.4G / 蓝牙无线连接',
      );
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
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(c.canApply, isFalse);
      mock.config = mock.config.copyWith(autoSwitchConnection: true);
      await c.refresh();
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      mock.present = false;
      await c.scan();
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Unsupported switch explicitly shows preview and does not write',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final mock = MockHidTransport(configVersion: 3);
      final c = AppController(transport: mock, isWindows11: true);
      addTearDown(c.dispose);
      await c.scan();
      await tester.pumpWidget(TouchpadApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '设备设置'));
      await tester.pumpAndSettle();
      expect(find.text('当前设备不支持自动切换配置，此设置仅保留为预览，不会写入设备。'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(SwitchListTile, '当有线连接断开时，自动切换到2.4G / 蓝牙无线连接'),
      );
      await tester.pumpAndSettle();
      expect(c.draft.autoSwitchConnection, isTrue);
      expect(c.canApply, isFalse);
      expect(mock.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
