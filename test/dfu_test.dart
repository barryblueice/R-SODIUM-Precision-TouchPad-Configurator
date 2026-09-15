import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app_controller.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/transport.dart';

class DfuTransport extends MockHidTransport {
  List<HidDevice> attached = const [
    HidDevice(id: 'A', name: 'Touchpad A', dfuPath: 'path-A'),
    HidDevice(id: 'B', name: 'Touchpad B', dfuPath: 'path-B'),
  ];
  bool scanFails = false, openFails = false;
  HidException? sendError;
  Completer<void>? sending;
  final targets = <String>[];
  int opens = 0;
  @override
  Future<List<HidDevice>> enumerate() async {
    if (scanFails) throw const HidException('io', '扫描失败');
    return [...attached];
  }

  @override
  Future<void> open(String id) async {
    opens++;
    if (openFails) throw const HidException('no_generic', '配置接口不可用');
    await super.open(id);
  }

  @override
  Future<void> enterDfu(HidDevice device) async {
    targets.add(device.id);
    await sending?.future;
    if (sendError != null) throw sendError!;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppController> connect(DfuTransport t) async {
    final c = AppController(transport: t);
    addTearDown(c.dispose);
    await c.scan();
    return c;
  }

  test('DFU requires an allowlisted device and an explicit interface path', () {
    for (final pid in [0x072A, 0x072B, 0x072C, 0x072D]) {
      final d = HidDevice.fromMap({
        'id': 'A',
        'name': 'Touchpad',
        'vendorId': 0x0D00,
        'productId': pid,
        'dfuPath': 'path-A',
      });
      expect(d.supportsDfu, isTrue);
      expect(
        d.usbId,
        '0D00:${pid.toRadixString(16).padLeft(4, '0').toUpperCase()}',
      );
    }
    expect(const HidDevice(id: 'A', name: 'A').supportsDfu, isFalse);
    expect(
      const HidDevice(
        id: 'A',
        name: 'A',
        vendorId: 1,
        dfuPath: 'path-A',
      ).supportsDfu,
      isFalse,
    );
    expect(
      const HidDevice(
        id: 'A',
        name: 'A',
        productId: 0x072E,
        dfuPath: 'path-A',
      ).supportsDfu,
      isFalse,
    );
    expect(
      HidDevice.fromMap({'id': 'A', 'name': 'A', 'dfuPath': 'path-A'})
          .supportsDfu,
      isFalse,
    );
  });

  test(
    'Windows DFU uses a dedicated method with the exact target, no RSTP send',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(WindowsHidTransport.channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          WindowsHidTransport.channel,
          null,
        ),
      );
      final t = WindowsHidTransport();
      await t.enterDfu(const HidDevice(id: 'B', name: 'B', dfuPath: 'path-B'));
      expect(calls.single.method, 'enterDfu');
      expect(calls.single.arguments, {'id': 'B', 'path': 'path-B'});
      await expectLater(
        t.enterDfu(const HidDevice(id: 'A', name: 'A')),
        throwsA(isA<HidException>()),
      );
      expect(calls.length, 1);
      messenger.setMockMethodCallHandler(WindowsHidTransport.channel, (
        _,
      ) async {
        throw PlatformException(code: 'short_write', message: '12/65 bytes');
      });
      await expectLater(
        t.enterDfu(const HidDevice(id: 'B', name: 'B', dfuPath: 'path-B')),
        throwsA(
          isA<HidException>().having((e) => e.code, 'code', 'short_write'),
        ),
      );
    },
  );

  test('Selected device only; duplicate sends, switching and saves are blocked while sending', () async {
    final t = DfuTransport()..sending = Completer<void>();
    final c = await connect(t);
    await c.connect(c.devices.last);
    c.update(c.draft.copyWith(intensity: 77));
    final pending = c.enterDfu();
    expect(c.busy, isTrue);
    expect(c.canEnterDfu, isFalse);
    expect(c.canApply, isFalse);
    await c.enterDfu();
    await c.connect(c.devices.first);
    await c.scan();
    await c.apply();
    expect(c.selected!.id, 'B');
    t.sending!.complete();
    await pending;
    expect(t.targets, ['B']);
    expect(t.writes, 0);
    expect(c.connected, isFalse);
    expect(c.current, isNull);
    expect(c.draft.intensity, 77);
    expect(c.canEnterDfu, isFalse);
    final opens = t.opens;
    await c.scan();
    expect(t.opens, opens); // Do not reconnect during DFU transition.
    t.attached = [];
    await c.scan();
    t.attached = const [HidDevice(id: 'B', name: 'B', dfuPath: 'path-B')];
    await c.scan();
    expect(c.connected, isTrue);
    expect(c.draft.intensity, 77);
    expect(c.canEnterDfu, isTrue);
  });

  test('Unplugging or a changed interface before sending never retargets another device', () async {
    final t = DfuTransport();
    final c = await connect(t);
    t.attached = [t.attached.last];
    await c.enterDfu();
    expect(t.targets, isEmpty);
    expect(c.connected, isFalse);
    expect(c.error, contains('目标设备已断开'));
    expect(c.canEnterDfu, isFalse);
    await c.scan();
    expect(c.selected!.id, 'B');
    t.attached = const [HidDevice(id: 'B', name: 'B', dfuPath: 'new-path')];
    await c.enterDfu();
    expect(t.targets, isEmpty);
  });

  test('Failed enumeration blocks DFU until a successful scan', () async {
    final t = DfuTransport();
    final c = await connect(t);
    t.scanFails = true;
    await c.enterDfu();
    expect(c.discoveryError, contains('扫描失败'));
    expect(c.canEnterDfu, isFalse);
    expect(t.targets, isEmpty);
    t.scanFails = false;
    await c.scan();
    expect(c.canEnterDfu, isTrue);
  });

  for (final code in [
    'access_denied',
    'short_write',
    'timeout',
    'disconnected',
  ]) {
    test(
      'DFU $code reports failure without retrying or losing the draft',
      () async {
        final t = DfuTransport()..sendError = HidException(code, '发送失败');
        final c = await connect(t);
        c.update(c.draft.copyWith(intensity: 81));
        await c.enterDfu();
        expect(t.targets, ['A']);
        expect(c.error, contains(code));
        expect(c.dfuMessage, contains('未确认发送成功'));
        expect(c.busy, isFalse);
        expect(c.draft.intensity, 81);
        expect(t.writes, 0);
      },
    );
  }

  test('DFU works without a configuration connection, including the other product IDs', () async {
    final t = DfuTransport()..openFails = true;
    final c = await connect(t);
    expect(c.connected, isFalse);
    expect(c.canEnterDfu, isTrue);
    await c.enterDfu();
    expect(t.targets, ['A']);
    for (final pid in [0x072A, 0x072B, 0x072D]) {
      t.attached = [
        HidDevice(id: '$pid', name: 'DFU', productId: pid, dfuPath: 'dfu-$pid'),
      ];
      await c.scan();
      expect(c.canEnterDfu, isTrue);
      await c.enterDfu();
      expect(t.targets.last, '$pid');
    }
  });

  const receiver = HidDevice(
    id: 'R',
    name: 'Receiver',
    productId: 0x072D,
    dfuPath: 'receiver-path',
  );
  const touchpad = HidDevice(
    id: 'T',
    name: 'Touchpad',
    dfuPath: 'touchpad-path',
  );

  test(
    'Receiver DFU preserves the separately connected touchpad and its draft',
    () async {
      final t = DfuTransport()..attached = [touchpad, receiver];
      final c = await connect(t);
      await c.connect(touchpad);
      c.update(c.draft.copyWith(intensity: 84));
      final before = c.current;
      expect(receiver.isReceiver, isTrue);
      expect(touchpad.isReceiver, isFalse);
      await c.enterDfu(receiver);
      expect(t.targets, ['R']);
      expect(c.selected!.id, 'T');
      expect(c.connected, isTrue);
      expect(t.opened, isTrue);
      expect(c.current, same(before));
      expect(c.draft.intensity, 84);
      expect(c.canEnterDfuFor(receiver), isFalse);
      expect(c.canEnterDfuFor(touchpad), isTrue);
      await c.scan();
      expect(c.canEnterDfuFor(receiver), isFalse);
      await c.enterDfu(touchpad);
      expect(t.targets, ['R', 'T']);
      expect(c.canEnterDfuFor(receiver), isFalse);
      expect(c.canEnterDfuFor(touchpad), isFalse);
    },
  );

  test(
    'Unplugged receiver cannot redirect DFU to a connected touchpad',
    () async {
      final t = DfuTransport()..attached = [touchpad, receiver];
      final c = await connect(t);
      await c.connect(touchpad);
      t.attached = [touchpad];
      await c.enterDfu(receiver);
      expect(t.targets, isEmpty);
      expect(c.usbConnected(receiver), isFalse);
      expect(c.canEnterDfuFor(receiver), isFalse);
      expect(c.connected, isTrue);
      expect(t.opened, isTrue);
      expect(c.canEnterDfuFor(touchpad), isTrue);
    },
  );

  testWidgets(
    'Touchpad and receiver each show connection status beside their own DFU button',
    (tester) async {
      tester.view.physicalSize = const Size(800, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final t = DfuTransport()..attached = [];
      final c = await connect(t);
      await tester.pumpWidget(TouchpadApp(controller: c));
      await tester.tap(find.widgetWithText(ListTile, '设备信息'));
      await tester.pumpAndSettle();
      final receiverButton = find.descendant(
        of: find.byKey(const ValueKey('dfu-receiver')),
        matching: find.byType(FilledButton),
      );
      final touchpadButton = find.descendant(
        of: find.byKey(const ValueKey('dfu-touchpad')),
        matching: find.byType(FilledButton),
      );
      expect(find.text('触摸板 · 未连接'), findsOneWidget);
      expect(find.text('接收器 · 未连接'), findsOneWidget);
      expect(tester.widget<FilledButton>(receiverButton).onPressed, isNull);
      expect(tester.widget<FilledButton>(touchpadButton).onPressed, isNull);
      t.attached = [receiver];
      await c.scan();
      await tester.pumpAndSettle();
      expect(c.connected, isFalse); // Receiver has no configurator protocol.
      expect(find.text('接收器 · 已连接'), findsOneWidget);
      expect(find.text('接收器 1'), findsOneWidget);
      expect(tester.widget<FilledButton>(receiverButton).onPressed, isNotNull);
      expect(tester.widget<FilledButton>(touchpadButton).onPressed, isNull);
      t.attached = [touchpad, receiver];
      await c.scan();
      await c.connect(touchpad);
      await tester.pumpAndSettle();
      expect(find.text('触摸板 · 已连接'), findsOneWidget);
      await tester.ensureVisible(receiverButton);
      await tester.tap(receiverButton);
      await tester.pumpAndSettle();
      expect(t.targets, ['R']);
      expect(tester.widget<FilledButton>(receiverButton).onPressed, isNull);
      expect(tester.widget<FilledButton>(touchpadButton).onPressed, isNotNull);
      expect(c.connected, isTrue);
      t.attached = [touchpad];
      await c.scan();
      await tester.pumpAndSettle();
      expect(find.text('接收器 · 未连接'), findsOneWidget);
      expect(tester.widget<FilledButton>(receiverButton).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  test('Disposing during preflight cancels the command', () async {
    final t = DfuTransport();
    final c = AppController(transport: t);
    await c.scan();
    final sending = c.enterDfu();
    c.dispose();
    await sending;
    expect(t.targets, isEmpty);
  });

  testWidgets(
    'DFU-only device remains identifiable without configuration support',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final t = DfuTransport()
        ..attached = const [
          HidDevice(
            id: 'A',
            name: 'DFU touchpad',
            serial: 'DFU-SERIAL',
            productId: 0x072B,
            dfuPath: 'path-A',
          ),
        ];
      final c = await connect(t);
      await tester.pumpWidget(TouchpadApp(controller: c));
      await tester.tap(find.widgetWithText(ListTile, '设备信息'));
      await tester.pumpAndSettle();
      expect(c.connected, isFalse);
      expect(find.text('DFU touchpad'), findsOneWidget);
      expect(find.text('DFU-SERIAL'), findsOneWidget);
      expect(find.text('0D00:072B'), findsOneWidget);
      final button = find.descendant(
        of: find.byKey(const ValueKey('dfu-touchpad')),
        matching: find.byType(FilledButton),
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      t.attached = [];
      await c.scan();
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Device information DFU entry is scrollable, retains drafts and simulates disconnection',
    (tester) async {
      tester.view.physicalSize = const Size(800, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final t = MockHidTransport();
      final c = AppController(transport: t);
      addTearDown(c.dispose);
      await c.scan();
      c.update(c.draft.copyWith(intensity: 83));
      await tester.pumpWidget(TouchpadApp(controller: c));
      await tester.tap(find.widgetWithText(ListTile, '设备信息'));
      await tester.pumpAndSettle();
      final button = find.descendant(
        of: find.byKey(const ValueKey('dfu-touchpad')),
        matching: find.byType(FilledButton),
      );
      await tester.ensureVisible(button);
      expect(find.text('尚未保存的设置会保留在配置器中。'), findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(t.dfuRequests, 1);
      expect(t.writes, 0);
      expect(c.draft.intensity, 83);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.text('已模拟发送 DFU 命令，演示设备已断开。'), findsWidgets);
      await c.scan();
      t.present = true;
      await c.scan();
      await tester.pumpAndSettle();
      expect(c.connected, isTrue);
      expect(c.draft.intensity, 83);
      expect(tester.takeException(), isNull);
    },
  );
}
