import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/device_client.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/transport.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows native enumeration, handshake and optional reversible Feature writes',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('R-SODIUM HID integration verification')),
        ),
      );
      final transport = WindowsHidTransport();
      final report = <String, Object?>{
        'timeUtc': DateTime.now().toUtc().toIso8601String(),
        'featureWrites': [],
      };
      try {
        final devices = await transport.enumerate();
        report['devices'] = [
          for (final d in devices)
            {
              'id': d.id,
              'name': d.name,
              'serial': d.serial,
              'collections': d.collections,
              'details': d.details,
            },
        ];
        // Never choose arbitrarily among multiple physical devices.
        if (devices.length == 1) {
          final client = DeviceClient(transport);
          final config = await client.connect(devices.single.id);
          report.addAll({
            'modern': client.modern,
            'capabilities': client.capabilities,
            'known': client.known,
            'intensity': config.intensity,
            'pressLevel': config.pressLevel,
            'configurationBytes': config.encode().toList(),
            'edges': [
              for (var i = 0; i < config.edges.length; i++)
                {
                  'edge': i,
                  'enabled': config.edges[i].enabled,
                  'action': config.edges[i].action.name,
                  'reversed': config.edges[i].reversed,
                  'width': config.edges[i].width,
                  'step': config.edges[i].step,
                },
            ],
            'note': client.note,
          });
          expect(client.known, greaterThan(0));
          if (const bool.fromEnvironment('HID_WRITE_TEST')) {
            for (final id in [0x40, 0x41]) {
              if (client.known & (id == 0x40 ? 2 : 1) == 0) continue;
              final original = await transport.getFeature(id);
              final temporary = id == 0x40
                  ? (original == 2 ? 1 : 2)
                  : (original == 63 ? 62 : 63);
              final item = <String, Object?>{
                'reportId': id,
                'original': original,
                'temporary': temporary,
              };
              try {
                await transport.setFeature(id, temporary);
                item['readback'] = await transport.getFeature(id);
                item['changeConfirmed'] = item['readback'] == temporary;
              } catch (e) {
                item['writeError'] = e.toString();
              } finally {
                // Restore even if the initial call failed after reaching the device.
                await transport.setFeature(id, original);
                final restored = await transport.getFeature(id);
                item['restored'] = restored;
                expect(
                  restored,
                  original,
                  reason: 'Feature 0x${id.toRadixString(16)} must be restored',
                );
                (report['featureWrites'] as List).add(item);
              }
            }
          }
        } else {
          report['hardwareSkipped'] =
              'Expected exactly one device; found ${devices.length}';
        }
      } catch (e) {
        report['error'] = e.toString();
        rethrow;
      } finally {
        await transport.close();
        final output = Directory('build/verification')
          ..createSync(recursive: true);
        File(
          '${output.path}/hardware.json',
        ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
        // Visible in the test output even when the runner has a different cwd.
        debugPrint('HID_VERIFICATION ${jsonEncode(report)}');
      }
    },
  );
}
