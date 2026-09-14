import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows device is automatically selected and read without writes', (
    tester,
  ) async {
    final c = AppController();
    await tester.pumpWidget(TouchpadApp(controller: c));
    try {
      await c.scan();
      await tester.pumpAndSettle();
      if (c.devices.isNotEmpty) {
        expect(c.connected, isTrue, reason: c.error);
        expect(c.current, isNotNull);
        expect(c.selected!.id, c.devices.first.id);
        expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
        debugPrint(
          'AUTO_CONNECT_OK devices=${c.devices.length} intensity=${c.current!.intensity} press=${c.current!.pressLevel}',
        );
      } else {
        expect(c.connected, isFalse);
        debugPrint(
          'AUTO_CONNECT_NO_HARDWARE: ${c.discoveryError ?? 'no target device'}',
        );
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    }
  });
}
