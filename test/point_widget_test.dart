import 'dart:ui' show SemanticsAction;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app_controller.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/config.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/transport.dart';

void main() {
  Future<AppController> show(
    WidgetTester tester, {
    bool legacy = false,
    bool connected = true,
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController(transport: MockHidTransport(legacy: legacy));
    addTearDown(c.dispose);
    if (connected) await c.scan();
    await tester.pumpWidget(TouchpadApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '单点手势'));
    await tester.pumpAndSettle();
    return c;
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Four point editors retain independent actions, radii and edge selection',
    (tester) async {
      final c = await show(tester);
      expect(find.byType(PointDiagram), findsOneWidget);
      expect(find.byType(TouchpadDiagram), findsNothing);
      expect(find.text('请先选择焦点区域'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButtonFormField<PointAction>>(
              find.byType(DropdownButtonFormField<PointAction>),
            )
            .onChanged,
        isNull,
      );
      final actions = [
        PointAction.volumeDown,
        PointAction.brightnessUp,
        PointAction.arrowLeft,
        PointAction.wheelDown,
      ];
      final radii = <int>[];
      for (final position in PointPosition.values) {
        await tapVisible(
          tester,
          find.widgetWithText(ChoiceChip, pointNames[position.index]),
        );
        await tapVisible(tester, find.text('启用此焦点'));
        await tapVisible(
          tester,
          find.byType(DropdownButtonFormField<PointAction>),
        );
        await tester.tap(
          find.text(pointActionNames[actions[position.index].index]).last,
        );
        await tester.pumpAndSettle();
        expect(find.text('反转动作方向'), findsNothing);
        await tapVisible(
          tester,
          find.widgetWithText(SwitchListTile, '手指不抬起继续动作'),
        );
        final slider = find.byType(Slider).first;
        await tester.ensureVisible(slider);
        final rect = tester.getRect(slider);
        await tester.tapAt(
          Offset(
            rect.left + rect.width * (.45 + position.index * .1),
            rect.center.dy,
          ),
        );
        await tester.pumpAndSettle();
        final p = c.draft.points[position.index];
        radii.add(p.radius);
        expect(p.enabled, isTrue);
        expect(p.action, actions[position.index]);
        expect(p.description, pointActionNames[actions[position.index].index]);
        expect(p.repeatWhileHeld, isTrue);
        expect(p.radius, greaterThan(5));
      }
      expect(radii.toSet().length, 4);
      final pointsBefore = c.draft.points;
      await tester.tap(find.widgetWithText(ListTile, '边缘手势'));
      await tester.pumpAndSettle();
      expect(find.byType(PointDiagram), findsNothing);
      expect(find.byType(TouchpadDiagram), findsOneWidget);
      expect(find.text('区域半径'), findsNothing);
      await tapVisible(tester, find.widgetWithText(ChoiceChip, '左边缘'));
      expect(find.text('反转滑动方向'), findsOneWidget);
      await tapVisible(tester, find.text('启用此边缘'));
      expect(c.draft.edges[2].enabled, isTrue);
      expect(c.draft.points, orderedEquals(pointsBefore));
      await tester.tap(find.widgetWithText(ListTile, '单点手势'));
      await tester.pumpAndSettle();
      expect(find.text('右下点设置'), findsOneWidget);
      expect(
        tester.widget<PointDiagram>(find.byType(PointDiagram)).selected,
        PointPosition.bottomRight,
      );
      await tapVisible(tester, find.text('允许点转为滑动时继续沿用边缘解析'));
      expect(c.draft.pointToEdgeMask, 8);
      await tapVisible(tester, find.widgetWithText(ChoiceChip, '左上点'));
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, '允许点转为滑动时继续沿用边缘解析'),
            )
            .value,
        isFalse,
      );
      await tapVisible(tester, find.text('允许点转为滑动时继续沿用边缘解析'));
      expect(c.draft.pointToEdgeMask, 9);
      await tapVisible(tester, find.widgetWithText(ChoiceChip, '右下点'));
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, '允许点转为滑动时继续沿用边缘解析'),
            )
            .value,
        isTrue,
      );
      await tapVisible(tester, find.text('允许点转为滑动时继续沿用边缘解析'));
      expect(c.draft.pointToEdgeMask, 1);
      await tester.tap(find.text('保存到演示设备'));
      await tester.pumpAndSettle();
      expect(c.current!.same(c.draft), isTrue);
      expect(c.current!.pointRepeatMask, 15);
      expect(c.current!.pointToEdgeMask, 1);
      await tester.tap(find.byTooltip('重新读取设备'));
      await tester.pumpAndSettle();
      expect(c.draft.pointToEdgeMask, 1);
      await tester.tap(find.widgetWithText(ListTile, '边缘手势'));
      await tester.pumpAndSettle();
      expect(find.text('左边缘设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Point conversion requires selection; legacy changes stay previews',
    (tester) async {
      final c = await show(tester, legacy: true);
      expect(c.draft.pointToEdgeMask, 0);
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, '允许点转为滑动时继续沿用边缘解析'),
            )
            .onChanged,
        isNull,
      );
      await tapVisible(tester, find.widgetWithText(ChoiceChip, '左上点'));
      await tapVisible(tester, find.text('启用此焦点'));
      await tapVisible(tester, find.text('允许点转为滑动时继续沿用边缘解析'));
      expect(c.draft.pointToEdgeMask, 1);
      expect(c.canApply, isFalse);
      expect(c.draft.points[0].action, PointAction.volumeUp);
      expect(c.unsupportedChanges, isTrue);
      expect(c.canApply, isFalse);
      await c.apply();
      expect((c.transport as MockHidTransport).writes, 0);
      expect(c.current!.pointToEdgeMask, 0);
      expect(c.current!.points[0].enabled, isFalse);
    },
  );

  for (final isPoint in [false, true]) {
    testWidgets(
      '${isPoint ? 'Point' : 'Edge'} enable switch gates settings and retains parameters',
      (tester) async {
        final c = await show(tester);
        if (!isPoint) {
          await tapVisible(tester, find.widgetWithText(ListTile, '边缘手势'));
        }
        final enableLabel = isPoint ? '启用此焦点' : '启用此边缘';
        final regionLabel = isPoint ? '左上点' : '上边缘';
        void expectSettingsEnabled(bool enabled) {
          final toggles = tester.widgetList<SwitchListTile>(
            find.byType(SwitchListTile),
          );
          expect(toggles.first.onChanged, isNotNull);
          for (final toggle in toggles.skip(1)) {
            expect(toggle.onChanged, enabled ? isNotNull : isNull);
          }
          for (final slider in tester.widgetList<Slider>(find.byType(Slider))) {
            expect(slider.onChanged, enabled ? isNotNull : isNull);
          }
          final callback = isPoint
              ? tester
                    .widget<DropdownButtonFormField<PointAction>>(
                      find.byType(DropdownButtonFormField<PointAction>),
                    )
                    .onChanged
              : tester
                    .widget<DropdownButtonFormField<EdgeAction>>(
                      find.byType(DropdownButtonFormField<EdgeAction>),
                    )
                    .onChanged;
          expect(callback, enabled ? isNotNull : isNull);
        }

        await tapVisible(tester, find.widgetWithText(ChoiceChip, regionLabel));
        expectSettingsEnabled(false);
        await tapVisible(tester, find.text(enableLabel));
        expectSettingsEnabled(true);
        if (isPoint) {
          final points = [...c.draft.points];
          points[0] = const PointConfig(
            enabled: true,
            action: PointAction.arrowLeft,
            radius: 30,
            step: 7,
            repeatWhileHeld: true,
            allowPointToEdge: true,
          );
          c.update(c.draft.copyWith(points: points));
        } else {
          final edges = [...c.draft.edges];
          edges[0] = const EdgeConfig(
            enabled: true,
            action: EdgeAction.horizontalArrowKeys,
            width: 9,
            step: 7,
            reversed: true,
            repeatWhileHeld: true,
          );
          c.update(c.draft.copyWith(edges: edges));
        }
        await tester.pumpAndSettle();
        final configured = c.draft;
        await tapVisible(tester, find.text(enableLabel));
        expectSettingsEnabled(false);
        expect(
          tester.widget<Slider>(find.byType(Slider).first).value,
          isPoint ? 30 : 9,
        );
        expect(tester.widget<Slider>(find.byType(Slider).last).value, 7);
        await tapVisible(
          tester,
          find.widgetWithText(ChoiceChip, isPoint ? '右上点' : '下边缘'),
        );
        expectSettingsEnabled(false);
        await tapVisible(tester, find.widgetWithText(ChoiceChip, regionLabel));
        expectSettingsEnabled(false);
        await tapVisible(tester, find.text(enableLabel));
        expectSettingsEnabled(true);
        expect(c.draft.same(configured), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Disconnected point and conversion editors are disabled', (
    tester,
  ) async {
    await show(tester, connected: false);
    expect(
      tester
          .widgetList<ChoiceChip>(find.byType(ChoiceChip))
          .every((w) => w.onSelected == null),
      isTrue,
    );
    expect(
      tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .every((w) => w.onChanged == null),
      isTrue,
    );
    expect(
      tester
          .widgetList<Slider>(find.byType(Slider))
          .every((w) => w.onChanged == null),
      isTrue,
    );
    expect(
      tester.widget<PointDiagram>(find.byType(PointDiagram)).onSelect,
      isNull,
    );
  });

  testWidgets(
    'Compact point page preserves Windows semantics and keyboard access across scrolling',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final semantics = tester.ensureSemantics();
      try {
        final c = await show(tester, size: const Size(900, 640));
        for (final position in PointPosition.values) {
          final button = find
              .descendant(
                of: find.byType(PointDiagram),
                matching: find.byType(IconButton),
              )
              .at(position.index);
          await tester.ensureVisible(button);
          final node = tester.getSemantics(button);
          expect(node.label, contains(pointNames[position.index]));
          expect(
            node.getSemanticsData().hasAction(SemanticsAction.tap),
            isTrue,
          );
          final focus = Focus.of(
            tester.element(
              find.descendant(of: button, matching: find.byType(Icon)),
            ),
          );
          focus.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(
            tester.widget<PointDiagram>(find.byType(PointDiagram)).selected,
            position,
          );
        }
        await tapVisible(tester, find.text('启用此焦点'));
        await tapVisible(tester, find.text('允许点转为滑动时继续沿用边缘解析'));
        expect(c.draft.pointToEdgeMask, 8);
        final pointScroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        expect(pointScroll.position.pixels, greaterThan(0));
        final anchors = find.descendant(
          of: find.byType(Slider),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Semantics &&
                w.properties.traversalParentIdentifier != null,
          ),
        );
        expect(anchors, findsNWidgets(2));
        expect(
          tester.getSemantics(anchors.first).id,
          isNot(tester.getSemantics(anchors.last).id),
        );
        await tester.tap(find.widgetWithText(ListTile, '边缘手势'));
        await tester.pumpAndSettle();
        final edgeScroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        expect(identical(edgeScroll, pointScroll), isFalse);
        expect(edgeScroll.position.pixels, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
