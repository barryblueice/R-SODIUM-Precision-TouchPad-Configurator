import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app_controller.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/transport.dart';

void main() {
  testWidgets(
    'Offscreen edge sliders keep distinct overlay traversal anchors',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final semantics = tester.ensureSemantics();
      final c = AppController(transport: MockHidTransport(legacy: true));
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      try {
        await c.scan();
        await tester.pumpWidget(TouchpadApp(controller: c));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, '方向与休眠'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, '边缘滑动'));
        await tester.pumpAndSettle();
        final anchors = find.descendant(
          of: find.byType(Slider),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Semantics &&
                w.properties.traversalParentIdentifier != null,
          ),
        );
        expect(anchors, findsNWidgets(2));
        final ids = <int>{};
        for (var i = 0; i < 2; i++) {
          final anchor = anchors.at(i);
          final identifier = tester
              .widget<Semantics>(anchor)
              .properties
              .traversalParentIdentifier;
          final node = tester.getSemantics(anchor);
          expect(node.traversalParentIdentifier, same(identifier));
          expect(
            ids.add(node.id),
            isTrue,
            reason: 'Each slider overlay needs its own traversal parent',
          );
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        semantics.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
  Future<AppController> show(
    WidgetTester tester, {
    bool connected = false,
    bool legacy = false,
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController(transport: MockHidTransport(legacy: legacy));
    addTearDown(c.dispose);
    if (connected) {
      await c.scan();
      await c.connect(c.devices.first);
    }
    await tester.pumpWidget(TouchpadApp(controller: c));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('Disconnected page disables settings and the device selector', (
    tester,
  ) async {
    await show(tester);
    expect(find.textContaining('未连接触摸板。接入 USB'), findsOneWidget);
    expect(find.textContaining('演示模式 ·'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存到演示设备'),
    );
    expect(button.onPressed, isNull);
    expect(tester.widget<Slider>(find.byType(Slider).first).onChanged, isNull);
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .onChanged,
      isNull,
    );
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.enabled, isFalse);
    }
    expect(find.text('R-SODIUM'), findsNothing);
    expect(find.text('TOUCHPAD / CONFIGURATION'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Modern haptics edit and apply read back actual device values', (
    tester,
  ) async {
    final c = await show(tester, connected: true);
    await tester.tap(find.text('触觉与按压').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('75'));
    await tester.pumpAndSettle();
    expect(c.draft.intensity, 75);
    expect(c.current!.intensity, 63);
    await tester.tap(find.text('保存到演示设备'));
    await tester.pumpAndSettle();
    expect(c.current!.intensity, 75);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Legacy unsupported controls are editable with no write button', (
    tester,
  ) async {
    final c = await show(tester, connected: true, legacy: true);
    await tester.tap(find.text('方向与休眠').first);
    await tester.pumpAndSettle();
    expect(find.text('固件暂不支持'), findsNWidgets(2));
    await tester.tap(find.text('纵向翻转'));
    await tester.pumpAndSettle();
    expect(c.draft.rotation, 3);
    expect(c.canApply, isFalse);
    expect(find.textContaining('设备当前值：未读取'), findsWidgets);
  });
  testWidgets('Edge editor selects independent edges and reverses mappings', (
    tester,
  ) async {
    final c = await show(tester, connected: true, size: const Size(1280, 1100));
    await tester.tap(find.text('边缘滑动').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('启用此边缘'));
    await tester.tap(find.text('启用此边缘'));
    await tester.pumpAndSettle();
    expect(c.draft.edges[2].enabled, isTrue);
    await tester.ensureVisible(find.text('反转滑动方向'));
    await tester.tap(find.text('反转滑动方向'));
    await tester.pumpAndSettle();
    expect(c.draft.edges[2].reversed, isTrue);
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, '上边缘'));
    await tester.tap(find.widgetWithText(ChoiceChip, '上边缘'));
    await tester.pumpAndSettle();
    expect(find.text('上边缘设置'), findsOneWidget);
    expect(c.draft.edges[0].enabled, isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Compact window navigates every page without overflow', (
    tester,
  ) async {
    await show(tester, connected: true, size: const Size(800, 720));
    for (final icon in [
      Icons.vibration_rounded,
      Icons.screen_rotation_alt_rounded,
      Icons.swipe_rounded,
      Icons.usb_rounded,
    ]) {
      await tester.tap(find.byIcon(icon).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('Failed apply shows error and keeps draft visible', (
    tester,
  ) async {
    final c = await show(tester, connected: true);
    (c.transport as MockHidTransport).ignoreWrites = true;
    await tester.tap(find.text('触觉与按压').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('75'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存到演示设备'));
    await tester.pumpAndSettle();
    expect(find.textContaining('读回值与提交值不一致'), findsOneWidget);
    expect(c.draft.intensity, 75);
    expect(c.current!.intensity, 63);
  });

  testWidgets('Pages isolate scrolling and edge buttons retain accessibility', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await show(tester, connected: true, size: const Size(800, 720));
      final oldScroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      oldScroll.position.jumpTo(oldScroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.tap(find.text('边缘滑动').first);
      await tester.pumpAndSettle();
      final edgeScroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(identical(oldScroll, edgeScroll), isFalse);
      expect(edgeScroll.position.pixels, 0);
      expect(find.text('自定义三档阈值'), findsNothing);

      final ids = <int>{};
      for (final name in ['上边缘', '下边缘', '左边缘', '右边缘']) {
        final button = find.descendant(
          of: find.byTooltip('$name：关闭'),
          matching: find.byType(IconButton),
        );
        final node = tester.getSemantics(button);
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        expect(ids.add(node.id), isTrue);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text('$name设置'), findsOneWidget);
      }
      await tester.tap(find.text('触觉与按压').first);
      await tester.pumpAndSettle();
      expect(find.byType(TouchpadDiagram), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
