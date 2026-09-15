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
    'Windows 11 blocks shared haptic edits while allowing custom thresholds',
    () async {
      final mock = MockHidTransport();
      final c = AppController(transport: mock, isWindows11: true);
      addTearDown(c.dispose);
      await c.scan();
      c.update(c.draft.copyWith(intensity: 75, pressLevel: 1));
      expect(c.draft.intensity, 63);
      expect(c.draft.pressLevel, 2);
      expect(c.canApply, isFalse);
      await c.apply();
      expect(mock.writes, 0);
      c.update(c.draft.copyWith(light: 90));
      expect(c.canApply, isTrue);
      // Windows changes these after the Manager initially read the device.
      mock.config = mock.config.copyWith(intensity: 25, pressLevel: 3);
      await c.apply();
      expect(c.error, isNull);
      expect(mock.config.light, 90);
      expect(mock.config.intensity, 25);
      expect(mock.config.pressLevel, 3);
      expect(c.draft.same(c.current!), isTrue);
    },
  );

  test(
    'Windows 11 ignores stale locked values when saving other settings',
    () async {
      final mock = MockHidTransport();
      final c = AppController(transport: mock, isWindows11: true);
      addTearDown(c.dispose);
      await c.scan();
      c.draft = c.draft.copyWith(intensity: 75, pressLevel: 1);
      expect(c.canApply, isFalse);
      c.draft = c.draft.copyWith(rotation: 1);
      await c.apply();
      expect(c.error, isNull);
      expect(mock.config.intensity, 63);
      expect(mock.config.pressLevel, 2);
      expect(mock.config.rotation, 1);
    },
  );
  test(
    'Original RSTP preserves arrow and repeat drafts without writing them',
    () async {
      final mock = MockHidTransport(capabilities: 0x3f);
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      c.update(
        c.draft.copyWith(
          edges: [
            const EdgeConfig(
              enabled: true,
              action: EdgeAction.verticalArrowKeys,
              reversed: true,
              repeatWhileHeld: true,
            ),
            ...c.draft.edges.skip(1),
          ],
        ),
      );
      expect(c.canApply, isFalse);
      expect(c.unsupportedChanges, isTrue);
      await c.apply();
      expect(mock.writes, 0);
      c.update(c.draft.copyWith(intensity: 75));
      await c.apply();
      expect(mock.config.intensity, 75);
      expect(mock.config.edges[0].enabled, isFalse);
      expect(mock.config.edges[0].action, EdgeAction.off);
      expect(mock.config.repeatMask, 0);
      expect(c.draft.edges[0].repeatWhileHeld, isTrue);
      expect(c.draft.edges[0].action, EdgeAction.verticalArrowKeys);
      expect(c.edited, isTrue);
      expect(c.unsupportedChanges, isTrue);
      expect(c.error, isNull);
    },
  );
  test('Edge extensions are negotiated independently and read back', () async {
    for (final extra in [
      0,
      Capability.edgeArrowKeys,
      Capability.edgeRepeat,
      Capability.edgeArrowKeys | Capability.edgeRepeat,
    ]) {
      final mock = MockHidTransport(capabilities: 0x3f | extra);
      final c = AppController(transport: mock);
      try {
        await c.scan();
        c.update(
          c.draft.copyWith(
            edges: [
              const EdgeConfig(
                enabled: true,
                action: EdgeAction.horizontalArrowKeys,
              ),
              const EdgeConfig(
                enabled: true,
                action: EdgeAction.volume,
                repeatWhileHeld: true,
              ),
              ...c.draft.edges.skip(2),
            ],
          ),
        );
        await c.apply();
        expect(c.error, isNull);
        expect(
          mock.config.edges[0].action,
          extra & Capability.edgeArrowKeys != 0
              ? EdgeAction.horizontalArrowKeys
              : EdgeAction.off,
        );
        expect(mock.config.edges[1].action, EdgeAction.volume);
        expect(
          mock.config.edges[1].repeatWhileHeld,
          extra & Capability.edgeRepeat != 0,
        );
        expect(c.current!.same(mock.config), isTrue);
        expect(c.unsupportedChanges, extra != 192);
      } finally {
        c.dispose();
      }
    }
  });
  test(
    'Unsupported arrow preview cannot start repeating the previous mapping',
    () async {
      final mock = MockHidTransport(capabilities: 0xbf);
      mock.config = mock.config.copyWith(
        edges: [
          const EdgeConfig(enabled: true, action: EdgeAction.volume),
          ...mock.config.edges.skip(1),
        ],
      );
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      c.update(
        c.draft.copyWith(
          edges: [
            c.draft.edges[0].copyWith(
              action: EdgeAction.verticalArrowKeys,
              repeatWhileHeld: true,
            ),
            ...c.draft.edges.skip(1),
          ],
        ),
      );
      expect(c.canApply, isFalse);
      c.update(c.draft.copyWith(intensity: 75));
      await c.apply();
      expect(mock.config.edges[0].action, EdgeAction.volume);
      expect(mock.config.edges[0].repeatWhileHeld, isFalse);
      expect(c.unsupportedChanges, isTrue);
    },
  );
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
  test('Refresh replaces edits and clears cached drafts for modern and legacy devices', () async {
    for (final legacy in [false, true]) {
      final mock = MockHidTransport(legacy: legacy);
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      c.update(c.draft.copyWith(intensity: 75, rotation: 3));
      // Reconnecting stores the edited values in the per-device cache.
      await c.connect(c.devices.first);
      mock.config = mock.config.copyWith(intensity: 25);
      final refresh = c.refresh();
      expect(c.refreshing, isTrue);
      expect(c.canApply, isFalse);
      await refresh;
      expect(c.draft.same(c.current!), isTrue);
      expect(c.draft.intensity, 25);
      expect(c.draft.rotation, 0);
      expect(c.edited, isFalse);
      expect(c.refreshing, isFalse);
      expect(c.busy, isFalse);
      expect(c.canApply, isFalse);
      expect(mock.writes, 0);

      // Switching away and back must not resurrect the discarded draft.
      final device = c.devices.first;
      await c.connect(const HidDevice(id: 'another-device', name: 'Other'));
      await c.connect(device);
      expect(c.draft.intensity, 25);
      expect(c.edited, isFalse);
    }
  });
  test(
    'Refresh after physical disconnect invalidates device state immediately',
    () async {
      final mock = MockHidTransport();
      final c = AppController(transport: mock);
      addTearDown(c.dispose);
      await c.scan();
      await c.connect(c.devices.first);
      c.update(c.draft.copyWith(intensity: 75));
      mock.present = false;
      await c.refresh();
      expect(c.connected, isFalse);
      expect(c.current, isNull);
      expect(c.error, isNotNull);
      expect(c.refreshing, isFalse);
      expect(c.busy, isFalse);
      expect(c.draft.intensity, 75);
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
