import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app_controller.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/transport.dart';

import 'windows_accessibility.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows accessibility survives edge navigation and scrolling', (
    tester,
  ) async {
    enableWindowsAccessibility();
    final c = AppController(transport: MockHidTransport());
    await c.scan();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    Future<void> settle() => tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    try {
      await tester.pumpWidget(TouchpadApp(controller: c));
      await settle();
      expect(ui.PlatformDispatcher.instance.semanticsEnabled, isTrue);
      await mouse.addPointer(location: const Offset(10, 10));
      debugPrint('ACCESSIBILITY_INITIALIZED');
      for (var cycle = 0; cycle < 3; cycle++) {
        for (final title in ['方向与休眠', '边缘滑动', '触觉与按压']) {
          final nav = tester.getCenter(find.widgetWithText(ListTile, title));
          await mouse.moveTo(nav);
          await mouse.down(nav);
          await mouse.up();
          await settle();
          debugPrint('ACCESSIBILITY_PAGE $cycle $title');
          if (title != '边缘滑动') continue;
          for (final icon in [Icons.swap_vert, Icons.swap_horiz]) {
            await mouse.moveTo(tester.getCenter(find.byIcon(icon).first));
            await tester.pump(const Duration(milliseconds: 600));
          }
          debugPrint('ACCESSIBILITY_TOOLTIPS $cycle');
          final scroll = tester.state<ScrollableState>(
            find.byType(Scrollable).first,
          );
          final position = tester.getCenter(
            find.byType(SingleChildScrollView).first,
          );
          binding.handlePointerEventForSource(
            PointerScrollEvent(
              position: position,
              scrollDelta: const Offset(0, 240),
            ),
            source: TestBindingEventSource.test,
          );
          await settle();
          expect(scroll.position.pixels, greaterThan(0));
          debugPrint('ACCESSIBILITY_WHEEL $cycle');
          final trackpad = await tester.createGesture(
            kind: PointerDeviceKind.trackpad,
          );
          final before = scroll.position.pixels;
          await trackpad.panZoomStart(position);
          await trackpad.panZoomUpdate(position, pan: const Offset(0, 100));
          await tester.pump(const Duration(milliseconds: 16));
          await trackpad.panZoomUpdate(position, pan: const Offset(0, 240));
          await trackpad.panZoomEnd();
          await settle();
          expect(scroll.position.pixels, lessThan(before));
          debugPrint('ACCESSIBILITY_TRACKPAD $cycle');
          expect(tester.takeException(), isNull);
        }
      }
      debugPrint('ACCESSIBILITY_SCENARIO_COMPLETED');
    } finally {
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      await settle();
      c.dispose();
    }
  });
}
