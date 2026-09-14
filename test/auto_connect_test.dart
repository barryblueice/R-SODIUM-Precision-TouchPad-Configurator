import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app_controller.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/config.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/transport.dart';

class MultipleDevices extends MockHidTransport {
  List<String> attached = ['B', 'A'];
  final values = {
    'A': TouchpadConfig(intensity: 63),
    'B': TouchpadConfig(intensity: 30),
  };
  String? active;
  int opens = 0;
  bool reject = false;
  @override
  Future<List<HidDevice>> enumerate() async => [
    for (final id in attached) HidDevice(id: id, name: 'Touchpad', serial: id),
  ];
  @override
  Future<void> open(String id) async {
    opens++;
    if (reject) throw const HidException('access_denied', '无法访问设备');
    await super.open(id);
    active = id;
    config = values[id]!;
  }

  @override
  Future<void> close() async {
    if (opened && active != null) values[active!] = config;
    await super.close();
  }
}

void main() {
  test(
    'Arrival connects automatically; stable scans do not reopen or write',
    () async {
      final t = MultipleDevices()..attached = [];
      final c = AppController(transport: t);
      addTearDown(c.dispose);
      await c.scan();
      expect(c.connected, isFalse);
      t.attached = ['B', 'A'];
      await c.scan();
      expect(c.selected!.id, 'A');
      expect(c.connected, isTrue);
      await c.scan();
      expect(t.opens, 1);
      expect(t.writes, 0);
      t.attached = [];
      await c.scan();
      expect(c.current, isNull);
      c.update(TouchpadConfig(intensity: 80));
      expect(c.draft.intensity, 63);
      t.attached = ['A'];
      await c.scan();
      expect(c.connected, isTrue);
      expect(t.opens, 2);
    },
  );
  test(
    'Selection survives scans; disappearance switches without copying drafts',
    () async {
      final t = MultipleDevices();
      final c = AppController(transport: t);
      addTearDown(c.dispose);
      await c.scan();
      c.update(c.draft.copyWith(intensity: 75));
      t.attached = ['B'];
      await c.scan();
      expect(c.selected!.id, 'B');
      expect(c.draft.intensity, 30);
      t.attached = ['A', 'B'];
      await c.scan();
      expect(c.selected!.id, 'B');
      await c.connect(c.devices.firstWhere((d) => d.id == 'A'));
      expect(c.draft.intensity, 75);
      expect(c.current!.intensity, 63);
      expect(t.writes, 0);
    },
  );
  test(
    'Failed automatic connection backs off until device reappears',
    () async {
      final t = MultipleDevices()..reject = true;
      final c = AppController(transport: t);
      addTearDown(c.dispose);
      await c.scan();
      await c.scan();
      expect(t.opens, 1);
      expect(c.connected, isFalse);
      expect(c.error, contains('无法访问'));
      t.attached = [];
      await c.scan();
      t.reject = false;
      t.attached = ['A'];
      await c.scan();
      expect(c.connected, isTrue);
    },
  );
  testWidgets(
    'Sidebar dropdown changes the active device and disables on removal',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final t = MultipleDevices();
      final c = AppController(transport: t);
      addTearDown(c.dispose);
      await c.scan();
      await tester.pumpWidget(TouchpadApp(controller: c));
      await tester.pumpAndSettle();
      final selector = find.byType(DropdownButtonFormField<String>);
      expect(tester.getTopLeft(selector).dx, lessThan(200));
      expect(tester.getTopLeft(selector).dy, greaterThan(650));
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('触摸板 2 · B').last);
      await tester.pumpAndSettle();
      expect(c.selected!.id, 'B');
      expect(c.current!.intensity, 30);
      t.attached = [];
      await c.scan();
      await tester.pumpAndSettle();
      expect(
        tester.widget<DropdownButtonFormField<String>>(selector).onChanged,
        isNull,
      );
      expect(
        tester.widget<Slider>(find.byType(Slider).first).onChanged,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
