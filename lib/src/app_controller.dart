import 'dart:async';

import 'package:flutter/foundation.dart';

import 'config.dart';
import 'device_client.dart';
import 'transport.dart';

class AppController extends ChangeNotifier {
  AppController({HidTransport? transport, bool? isWindows11})
    : transport = transport ?? WindowsHidTransport() {
    client = DeviceClient(this.transport);
    this.isWindows11 = isWindows11 ?? this.transport.runsOnWindows11;
  }
  HidTransport transport;
  late DeviceClient client;
  late final bool isWindows11;
  static const _hapticMask = Capability.intensity | Capability.pressLevel;
  List<HidDevice> devices = [];
  List<HidDevice> get touchpads => devices.where((d) => !d.isReceiver).toList();
  HidDevice? selected;
  TouchpadConfig draft = TouchpadConfig();
  TouchpadConfig? current;
  final Map<String, TouchpadConfig> _drafts = {};
  bool busy = false, connected = false, edited = false;
  bool refreshing = false;
  String message = '未连接触摸板';
  String? error;
  String? discoveryError;
  String? dfuMessage;
  final Set<String> _dfuWaitingIds = {};
  Timer? _timer;
  bool _disposed = false, _scanning = false;
  int _epoch = 0;
  TouchpadConfig? _pendingReconnect;
  int _pendingCapabilities = 0;
  DateTime? _nextAutoAttempt;

  bool get demo => transport.isDemo;
  HidDevice? get dfuTarget {
    for (final device in devices) {
      if (device.id == selected?.id && device.supportsDfu) return device;
    }
    return null;
  }

  bool usbConnected(HidDevice? device) =>
      device != null &&
      discoveryError == null &&
      !_dfuWaitingIds.contains(device.id) &&
      devices.any((d) => d.id == device.id);
  bool waitingForDfu(HidDevice device) => _dfuWaitingIds.contains(device.id);
  bool canEnterDfuFor(HidDevice? device) =>
      !_disposed &&
      !busy &&
      usbConnected(device) &&
      device!.supportsDfu &&
      devices.any((d) => d.id == device.id && d.dfuPath == device.dfuPath);
  bool get canEnterDfu => canEnterDfuFor(dfuTarget);
  int get capabilities => connected ? client.capabilities : 0;
  bool get hapticSettingsAvailable => !isWindows11;
  int get editableCapabilities =>
      isWindows11 ? capabilities & ~_hapticMask : capabilities;
  bool supports(int bit) => capabilities & bit != 0;
  bool knows(int bit) => connected && client.known & bit != 0;
  bool get writableChanges =>
      current != null && !current!.same(draft, editableCapabilities);
  bool get unsupportedChanges =>
      current != null && !current!.merge(draft, capabilities).same(draft);
  bool get canApply =>
      connected &&
      !busy &&
      writableChanges &&
      current!.merge(draft, editableCapabilities).validationError == null;

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
      _dfuWaitingIds.removeWhere((id) => !devices.any((d) => d.id == id));
      if (selected != null && !devices.any((d) => d.id == selected!.id)) {
        if (connected) {
          connected = false;
          current = null;
          message = '设备已断开，上一次编辑已恢复。';
          await client.close();
        }
      }
      final candidates = touchpads
          .where((d) => !_dfuWaitingIds.contains(d.id))
          .toList();
      if (!connected &&
          candidates.isNotEmpty &&
          !_disposed &&
          !_dfuWaitingIds.contains(selected?.id)) {
        final target = candidates.firstWhere(
          (d) => d.id == selected?.id,
          orElse: () => candidates.first,
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
    draft = isWindows11 ? value.merge(draft, _hapticMask) : value;
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
    if (busy || _disposed || device.isReceiver) return;
    _epoch++;
    busy = true;
    error = null;
    emit();
    if (selected != null && edited) _drafts[selected!.id] = draft;
    final sameDevice = selected?.id == device.id;
    _dfuWaitingIds.remove(device.id);
    if (!sameDevice) dfuMessage = null;
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
      if (device.productId != 0x072C) {
        message = '已选择设备，可在设备信息中进入 DFU 模式。';
        _nextAutoAttempt = DateTime.now().add(const Duration(seconds: 10));
        return;
      }
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
      message = '连接未完成，上一次编辑已恢复。';
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
    refreshing = true;
    error = null;
    emit();
    try {
      current = await client.readConfig();
      draft = current!;
      edited = false;
      if (selected != null) _drafts.remove(selected!.id);
      message = '已重新读取设备设置。';
    } catch (e) {
      error = e.toString();
      message = '重新读取设备设置失败。';
      if (e is HidException &&
          ['disconnected', 'unavailable'].contains(e.code)) {
        connected = false;
        current = null;
        await client.close();
      }
    } finally {
      refreshing = false;
      busy = false;
      emit();
    }
  }

  Future<void> apply() async {
    if (!canApply) return;
    busy = true;
    error = null;
    emit();
    final targetCapabilities = capabilities;
    try {
      if (isWindows11) {
        // RSTP writes the complete configuration. Keep disabled haptic fields
        // fresh when saving another page after Windows has changed the device.
        current = await client.readConfig();
        draft = draft.merge(current!, _hapticMask);
      }
      final target = current!.merge(draft, editableCapabilities);
      final result = await client.apply(target, current!);
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
      message = '应用未完成；上一次编辑已恢复，请检查设备读回值。';
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

  Future<void> enterDfu([HidDevice? device]) async {
    final target = device ?? dfuTarget;
    if (!canEnterDfuFor(target)) return;
    final isSelected = target!.id == selected?.id;
    final epoch = ++_epoch;
    busy = true;
    error = null;
    dfuMessage = '正在发送 DFU 命令…';
    if (isSelected && edited) _drafts[target.id] = draft;
    emit();
    try {
      // Rescan before sending; never substitute a newly selected device.
      final List<HidDevice> present;
      try {
        present = await transport.enumerate();
      } catch (e) {
        discoveryError = e.toString();
        rethrow;
      }
      if (_disposed || epoch != _epoch) return;
      devices = [...present]..sort((a, b) => a.id.compareTo(b.id));
      if (!present.any(
        (d) =>
            d.id == target.id && d.dfuPath == target.dfuPath && d.supportsDfu,
      )) {
        throw const HidException('disconnected', '目标设备已断开，未发送 DFU 命令');
      }
      await transport.enterDfu(target);
      if (_disposed || epoch != _epoch) return;
      _dfuWaitingIds.add(target.id);
      if (isSelected) {
        _pendingReconnect = null;
        connected = false;
        current = null;
      }
      dfuMessage = demo
          ? '已模拟发送 DFU 命令，演示设备已断开。'
          : 'DFU 命令已发送，请在设备进入升级模式后使用刷写工具继续。';
      message = dfuMessage!;
      if (isSelected) await client.close();
    } catch (e) {
      if (_disposed || epoch != _epoch) return;
      error = e.toString();
      dfuMessage = 'DFU 命令未确认发送成功，请检查设备状态后重试。';
      message = dfuMessage!;
      if (e is HidException && e.code == 'disconnected') {
        devices.removeWhere((d) => d.id == target.id);
        if (isSelected) {
          connected = false;
          current = null;
          await client.close();
        }
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
    _dfuWaitingIds.clear();
    dfuMessage = null;
    _nextAutoAttempt = null;
    error = discoveryError = null;
    message = enabled ? '演示模式：所有读写仅在内存中执行。' : '请连接 USB 触摸板。';
    try {
      devices = await transport.enumerate();
    } catch (e) {
      discoveryError = e.toString();
    }
    busy = false;
    if (enabled && touchpads.isNotEmpty) await connect(touchpads.first);
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
