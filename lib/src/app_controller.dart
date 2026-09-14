import 'dart:async';

import 'package:flutter/foundation.dart';

import 'config.dart';
import 'device_client.dart';
import 'transport.dart';

class AppController extends ChangeNotifier {
  AppController({HidTransport? transport})
    : transport = transport ?? WindowsHidTransport() {
    client = DeviceClient(this.transport);
  }
  HidTransport transport;
  late DeviceClient client;
  List<HidDevice> devices = [];
  HidDevice? selected;
  TouchpadConfig draft = TouchpadConfig();
  TouchpadConfig? current;
  final Map<String, TouchpadConfig> _drafts = {};
  bool busy = false, connected = false, edited = false;
  String message = '未连接触摸板';
  String? error;
  String? discoveryError;
  Timer? _timer;
  bool _disposed = false, _scanning = false;
  int _epoch = 0;
  TouchpadConfig? _pendingReconnect;
  int _pendingCapabilities = 0;
  DateTime? _nextAutoAttempt;

  bool get demo => transport.isDemo;
  int get capabilities => connected ? client.capabilities : 0;
  bool supports(int bit) => capabilities & bit != 0;
  bool knows(int bit) => connected && client.known & bit != 0;
  bool get writableChanges =>
      current != null && !current!.same(draft, capabilities);
  bool get unsupportedChanges =>
      current != null && !current!.same(draft, Capability.all & ~capabilities);
  bool get canApply =>
      connected &&
      !busy &&
      writableChanges &&
      current!.merge(draft, capabilities).validationError == null;

  void emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    await scan();
    if (_disposed) return;
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      scan();
    });
  }

  Future<void> scan() async {
    if (_scanning || busy || _disposed) return;
    _scanning = true;
    final epoch = _epoch;
    try {
      final discovered = await transport.enumerate();
      if (epoch != _epoch || _disposed || busy) return;
      final previousIds = devices.map((d) => d.id).toSet();
      devices = [...discovered]..sort((a, b) => a.id.compareTo(b.id));
      discoveryError = null;
      if (selected != null && !devices.any((d) => d.id == selected!.id)) {
        if (connected) {
          connected = false;
          current = null;
          message = '设备已断开，编辑草稿已保留。';
          await client.close();
        }
      }
      if (!connected && devices.isNotEmpty && !_disposed) {
        final target = devices.firstWhere(
          (d) => d.id == selected?.id,
          orElse: () => devices.first,
        );
        final newlyPresent = !previousIds.contains(target.id);
        if (newlyPresent ||
            target.id != selected?.id ||
            _nextAutoAttempt == null ||
            !DateTime.now().isBefore(_nextAutoAttempt!)) {
          await connect(target);
        }
      }
    } catch (e) {
      if (epoch == _epoch && !_disposed) discoveryError = e.toString();
    } finally {
      _scanning = false;
      emit();
    }
  }

  void update(TouchpadConfig value) {
    if (!connected || busy) return;
    draft = value;
    edited = true;
    emit();
  }

  void useDeviceValues() {
    if (current == null) return;
    draft = draft.merge(current!, client.known);
    edited = unsupportedChanges;
    if (!edited && selected != null) _drafts.remove(selected!.id);
    emit();
  }

  Future<void> connect(HidDevice device) async {
    if (busy || _disposed) return;
    _epoch++;
    busy = true;
    error = null;
    emit();
    if (selected != null && edited) _drafts[selected!.id] = draft;
    final sameDevice = selected?.id == device.id;
    if (!sameDevice) {
      _pendingReconnect = null;
      draft = _drafts[device.id] ?? TouchpadConfig();
      edited = _drafts.containsKey(device.id);
    }
    selected = device;
    connected = false;
    current = null;
    try {
      await client.close();
      final read = await client.connect(device.id);
      current = read;
      connected = true;
      _nextAutoAttempt = null;
      if (!edited) draft = draft.merge(read, client.known);
      message = '已读取设置';
      if (_pendingReconnect != null) {
        if (!client.modern ||
            (client.known & _pendingCapabilities) != _pendingCapabilities ||
            !_pendingReconnect!.same(read)) {
          error = '重连后读回不一致，未确认设置生效。';
        } else {
          message = '设备重新连接，保存后的配置读回校验通过。';
        }
        _pendingReconnect = null;
      }
    } catch (e) {
      error = e.toString();
      message = '连接未完成，草稿已保留。';
      _nextAutoAttempt = DateTime.now().add(const Duration(seconds: 10));
      await client.close();
    } finally {
      busy = false;
      emit();
    }
  }

  Future<void> refresh() async {
    if (!connected || busy) return;
    busy = true;
    error = null;
    emit();
    try {
      current = await client.readConfig();
      if (!edited) draft = draft.merge(current!, client.known);
      message = '已重新读取设备，编辑草稿保持独立。';
    } catch (e) {
      error = e.toString();
      if (e is HidException &&
          ['disconnected', 'unavailable'].contains(e.code)) {
        connected = false;
        current = null;
        await client.close();
      }
    } finally {
      busy = false;
      emit();
    }
  }

  Future<void> apply() async {
    if (!canApply) return;
    busy = true;
    error = null;
    emit();
    final target = current!.merge(draft, capabilities);
    final targetCapabilities = capabilities;
    try {
      final result = await client.apply(draft, current!);
      message = result.message;
      if (result.reconnect) {
        _pendingReconnect = target;
        _pendingCapabilities = targetCapabilities;
        await client.close();
        connected = false;
        current = null;
      } else {
        current = result.config;
        edited = unsupportedChanges;
        if (!edited && selected != null) _drafts.remove(selected!.id);
      }
    } catch (e) {
      error = e.toString();
      message = '应用未完成；保留草稿，请检查设备读回值。';
      try {
        current = await client.readConfig();
      } catch (_) {
        current = null;
        connected = false;
        await client.close();
      }
    } finally {
      busy = false;
      emit();
    }
  }

  Future<void> setDemo(bool enabled, {bool legacy = false}) async {
    if (busy || _disposed) return;
    _epoch++;
    busy = true;
    emit();
    if (selected != null && edited) _drafts[selected!.id] = draft;
    await client.close();
    transport = enabled
        ? MockHidTransport(legacy: legacy)
        : WindowsHidTransport();
    client = DeviceClient(transport);
    selected = null;
    current = null;
    connected = false;
    edited = false;
    draft = TouchpadConfig();
    devices = [];
    _pendingReconnect = null;
    _nextAutoAttempt = null;
    error = discoveryError = null;
    message = enabled ? '演示模式：所有读写仅在内存中执行。' : '请连接 USB 触摸板。';
    try {
      devices = await transport.enumerate();
    } catch (e) {
      discoveryError = e.toString();
    }
    busy = false;
    if (enabled && devices.isNotEmpty) await connect(devices.first);
    emit();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _timer?.cancel();
    unawaited(client.close());
    super.dispose();
  }
}
