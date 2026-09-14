import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/app_controller.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/config.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/protocol.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/transport.dart';

class DelayedEnumeration extends MockHidTransport {
  final pending = Completer<List<HidDevice>>();
  @override
  Future<List<HidDevice>> enumerate() => pending.future;
}

class CapabilityLossTransport extends MockHidTransport {
  bool loseCapabilities = false;
  @override
  Future<void> send(Uint8List bytes) async {
    await super.send(bytes);
    if (loseCapabilities && Packet.decode(bytes).command == Command.info) {
      final response = replies.removeLast();
      response[12] = 3;
      replies.add(response);
    }
  }
}

void main() {
  test(
    'Old enumeration cannot replace device list after switching to demo',
    () async {
      final old = DelayedEnumeration();
      final c = AppController(transport: old);
      addTearDown(c.dispose);
      final scan = c.scan();
      await c.setDemo(true);
      old.pending.complete([]);
      await scan;
      expect(c.devices.single.id, 'demo-v1');
      expect(c.connected, isTrue);
    },
  );
  test(
    'Refresh after physical disconnect invalidates device state immediately',
    () async {
      final mock = MockHidTransport();
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      await c.connect(c.devices.first);
      mock.present = false;
      await c.refresh();
      expect(c.connected, isFalse);
      expect(c.current, isNull);
    },
  );
  test(
    'Capability loss after reenumeration cannot confirm a saved rotation',
    () async {
      final mock = CapabilityLossTransport();
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      await c.connect(c.devices.first);
      c.update(c.draft.copyWith(rotation: 1));
      mock.writeStatus = Status.reconnect;
      await c.apply();
      mock.loseCapabilities = true;
      await c.scan();
      expect(c.error, contains('未确认设置生效'));
    },
  );
  test('Disconnected defaults are never device readbacks', () async {
    final c = AppController(transport: MockHidTransport());
    addTearDown(c.dispose);
    expect(c.current, isNull);
    expect(c.knows(Capability.intensity), isFalse);
    expect(c.canApply, isFalse);
    expect(c.draft.intensity, 63);
  });
  test(
    'Disconnect preserves draft; reconnect reads without overwriting it',
    () async {
      final mock = MockHidTransport();
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      await c.connect(c.devices.first);
      c.update(c.draft.copyWith(intensity: 75));
      mock.present = false;
      await c.scan();
      expect(c.connected, isFalse);
      expect(c.draft.intensity, 75);
      expect(c.canApply, isFalse);
      mock.present = true;
      mock.config = mock.config.copyWith(intensity: 25);
      await c.scan();
      await c.connect(c.devices.first);
      expect(c.current!.intensity, 25);
      expect(c.draft.intensity, 75);
      expect(c.canApply, isTrue);
    },
  );
  test(
    'Unsupported drafts remain editable but cannot trigger writes',
    () async {
      final mock = MockHidTransport(legacy: true);
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      await c.connect(c.devices.first);
      c.update(c.draft.copyWith(rotation: 3));
      expect(c.unsupportedChanges, isTrue);
      expect(c.canApply, isFalse);
      c.update(c.draft.copyWith(intensity: 75));
      expect(c.canApply, isTrue);
      await c.apply();
      expect(c.current!.intensity, 75);
      expect(mock.config.rotation, 0);
      expect(c.draft.rotation, 3);
      expect(c.unsupportedChanges, isTrue);
      expect(c.error, isNull);
    },
  );
  test('Invalid supported thresholds block writes and valid readback clears dirtiness', () async {
    final mock = MockHidTransport();
    final c = AppController(transport: mock);
    addTearDown(c.dispose);
    await c.scan();
    await c.connect(c.devices.first);
    c.update(c.draft.copyWith(light: 150));
    expect(c.canApply, isFalse);
    c.update(c.draft.copyWith(light: 90));
    await c.apply();
    expect(c.current!.light, 90);
    expect(c.writableChanges, isFalse);
    expect(c.edited, isFalse);
  });
  test(
    'Failed write retains draft and exposes device state and error',
    () async {
      final mock = MockHidTransport();
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      await c.connect(c.devices.first);
      c.update(c.draft.copyWith(intensity: 75));
      mock.writeStatus = Status.storage;
      await c.apply();
      expect(c.error, contains('保存失败'));
      expect(c.draft.intensity, 75);
      expect(c.current!.intensity, 63);
      expect(c.canApply, isTrue);
    },
  );
  test(
    'Reenumeration waits for readback then confirms configuration',
    () async {
      final mock = MockHidTransport();
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      await c.connect(c.devices.first);
      c.update(c.draft.copyWith(rotation: 1));
      mock.writeStatus = Status.reconnect;
      await c.apply();
      expect(c.connected, isFalse);
      expect(c.current, isNull);
      await c.scan();
      expect(c.connected, isTrue);
      expect(c.current!.rotation, 1);
      expect(c.message, contains('读回校验通过'));
    },
  );
}
