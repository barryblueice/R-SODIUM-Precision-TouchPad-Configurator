import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/config.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/device_client.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/protocol.dart';
import 'package:r_sodium_precision_touchpad_configurator/src/transport.dart';

class NoisyTransport extends MockHidTransport {
  bool noisy = true;
  @override
  Future<void> send(Uint8List packet) async {
    await super.send(packet);
    if (noisy) {
      final p = Packet.decode(packet);
      replies.addFirst(Packet(p.command == 1 ? 2 : 1, p.sequence).encode());
      replies.addFirst(Packet(p.command, p.sequence + 99).encode());
    }
  }
}

class DelayedTransport extends MockHidTransport {
  final pending = Completer<Uint8List>();
  @override
  Future<Uint8List> read(int timeoutMs) => pending.future;
}

class RetryTransport extends MockHidTransport {
  int reads = 0;
  @override
  Future<Uint8List> read(int timeoutMs) async {
    if (reads++ == 0) {
      replies.clear();
      throw const HidException('timeout', 'test');
    }
    return super.read(timeoutMs);
  }
}

void main() {
  test(
    'Readback rejects extension values missing the matching capability',
    () async {
      for (final edge in [
        const EdgeConfig(action: EdgeAction.verticalArrowKeys),
        const EdgeConfig(repeatWhileHeld: true),
      ]) {
        final mock = MockHidTransport(capabilities: 0x3f);
        mock.config = mock.config.copyWith(
          edges: [edge, ...mock.config.edges.skip(1)],
        );
        final client = DeviceClient(mock);
        await expectLater(client.connect('demo-v1'), throwsFormatException);
        await client.close();
      }
    },
  );
  test('Extension bits require the base edge capability', () async {
    final client = DeviceClient(MockHidTransport(capabilities: 0xdf));
    await client.connect('demo-v1');
    expect(client.capabilities, 0x1f);
    await client.close();
  });
  test('Repeat-only write requires exact readback confirmation', () async {
    final mock = MockHidTransport();
    final client = DeviceClient(mock);
    final current = await client.connect('demo-v1');
    final draft = current.copyWith(
      edges: [
        current.edges[0].copyWith(repeatWhileHeld: true),
        ...current.edges.skip(1),
      ],
    );
    mock.ignoreWrites = true;
    await expectLater(
      client.apply(draft, current),
      throwsA(isA<ProtocolException>()),
    );
    mock.ignoreWrites = false;
    final result = await client.apply(draft, current);
    expect(result.config!.repeatMask, 1);
    expect(result.config!.same(draft), isTrue);
    await client.close();
  });
  test(
    'RSTP handshake, capability discovery and verified persistence',
    () async {
      final mock = MockHidTransport();
      final client = DeviceClient(mock);
      final current = await client.connect('demo-v1');
      expect(client.capabilities, Capability.all);
      expect(client.modern, isTrue);
      final result = await client.apply(
        current.copyWith(intensity: 75),
        current,
      );
      expect(result.config!.intensity, 75);
      expect(result.message, contains('设备已确认保存'));
    },
  );
  test('Legacy fallback reads only existing settings and preserves unsupported drafts', () async {
    final mock = MockHidTransport(legacy: true);
    final client = DeviceClient(mock);
    final current = await client.connect('demo-legacy');
    expect(client.modern, isFalse);
    expect(client.known, 3);
    final result = await client.apply(
      current.copyWith(intensity: 25, rotation: 3),
      current,
    );
    expect(result.config!.intensity, 25);
    expect(mock.config.rotation, 0);
    expect(result.message, contains('不提供持久化确认'));
  });
  test('Missing capability is never written', () async {
    final mock = MockHidTransport(capabilities: Capability.intensity);
    final client = DeviceClient(mock);
    final current = await client.connect('demo-v1');
    await client.apply(current.copyWith(intensity: 75, rotation: 3), current);
    expect(mock.config.rotation, 0);
  });
  test(
    'Write timeout reads back without resending or claiming persistence',
    () async {
      final mock = MockHidTransport();
      final client = DeviceClient(mock);
      final current = await client.connect('demo-v1');
      mock.dropWriteReply = true;
      final result = await client.apply(
        current.copyWith(intensity: 75),
        current,
      );
      expect(mock.writes, 1);
      expect(result.config!.intensity, 75);
      expect(result.message, contains('持久化状态未确认'));
    },
  );
  test(
    'Storage error, ignored write and disconnect cannot become success',
    () async {
      final mock = MockHidTransport();
      final client = DeviceClient(mock);
      final current = await client.connect('demo-v1');
      final draft = current.copyWith(intensity: 75);
      mock.writeStatus = Status.storage;
      await expectLater(
        client.apply(draft, current),
        throwsA(isA<ProtocolException>()),
      );
      mock.writeStatus = 0;
      mock.ignoreWrites = true;
      await expectLater(
        client.apply(draft, current),
        throwsA(isA<ProtocolException>()),
      );
      mock.present = false;
      await expectLater(client.readConfig(), throwsA(isA<HidException>()));
    },
  );
  test(
    'Legacy SET_FEATURE accepted but ignored is detected by readback',
    () async {
      final mock = MockHidTransport(legacy: true);
      final client = DeviceClient(mock);
      final current = await client.connect('demo-legacy');
      mock.ignoreWrites = true;
      await expectLater(
        client.apply(current.copyWith(intensity: 75), current),
        throwsA(isA<ProtocolException>()),
      );
    },
  );
  test(
    'Reenumeration response remains pending instead of reporting applied',
    () async {
      final mock = MockHidTransport();
      final client = DeviceClient(mock);
      final current = await client.connect('demo-v1');
      mock.writeStatus = Status.reconnect;
      final result = await client.apply(current.copyWith(rotation: 1), current);
      expect(result.reconnect, isTrue);
      expect(result.config, isNull);
    },
  );
  test('Wrong sequence and wrong command responses are discarded', () async {
    final client = DeviceClient(NoisyTransport());
    expect((await client.connect('demo-v1')).intensity, 63);
  });
  test('Read timeout gets one retry', () async {
    final mock = RetryTransport();
    final client = DeviceClient(mock);
    await client.connect('demo-v1');
    expect(mock.reads, 3);
  });
  test(
    'Concurrent requests are refused and prior generation response is dropped',
    () async {
      final mock = DelayedTransport();
      await mock.open('demo-v1');
      final client = DeviceClient(mock);
      final request = client.request(Command.info);
      await Future<void>.delayed(Duration.zero);
      await expectLater(client.request(Command.read), throwsStateError);
      await client.close();
      mock.pending.complete(Packet(Command.info, 1).encode());
      await expectLater(
        request,
        throwsA(
          isA<HidException>().having((e) => e.code, 'code', 'disconnected'),
        ),
      );
    },
  );
}
