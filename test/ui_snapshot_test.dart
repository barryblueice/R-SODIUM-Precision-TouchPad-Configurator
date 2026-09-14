import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app_controller.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/transport.dart';

// Opt-in artifact export; assertions live in widget_test.dart.
void main() {
  testWidgets('Export light and dark previews with actual Windows CJK font', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('EXPORT_UI_PREVIEWS')) return;
    final font = File('C:/Windows/Fonts/msyh.ttc');
    await tester.runAsync(() async {
      final loader = FontLoader('Microsoft YaHei UI');
      loader.addFont(
        Future.value(ByteData.sublistView(await font.readAsBytes())),
      );
      await loader.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final c = AppController(transport: MockHidTransport());
    addTearDown(c.dispose);
    await c.scan();
    await c.connect(c.devices.first);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: TouchpadApp(controller: c),
      ),
    );
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = Directory('build/verification/previews')
          ..createSync(recursive: true);
        File('${output.path}/$name.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.tap(find.text('设备信息').first);
    await capture('device-light');
    await tester.tap(find.text('触觉与按压').first);
    await capture('haptics-light');
    await tester.tap(find.text('方向与休眠').first);
    await capture('settings-light');
    await tester.tap(find.text('边缘滑动').first);
    await capture('edges-light');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    await capture('edges-dark');
  });
}
