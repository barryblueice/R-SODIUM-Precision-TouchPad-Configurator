import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'config.dart';
import 'transport.dart';

class TouchpadApp extends StatelessWidget {
  const TouchpadApp({super.key, this.controller});
  final AppController? controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    home: Configurator(controller: controller),
  );
  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF39699C),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'Microsoft YaHei UI',
      fontFamilyFallback: const ['Segoe UI'],
      scaffoldBackgroundColor: dark
          ? const Color(0xFF202020)
          : const Color(0xFFF7F7F7),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: dark ? const Color(0xFF282828) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(5)),
      ),
    );
  }
}

class Configurator extends StatefulWidget {
  const Configurator({super.key, this.controller});
  final AppController? controller;
  @override
  State<Configurator> createState() => _ConfiguratorState();
}

class _ConfiguratorState extends State<Configurator> {
  late final AppController c;
  int page = 1;
  EdgeSide? _selectedEdge;
  PointPosition? _selectedPoint;
  final Map<bool, String> _dfuSelections = {};
  static const titles = ['设备信息', '触觉与按压', '方向与休眠', '边缘手势', '单点手势'];
  bool get _editable => c.connected && !c.busy;
  bool get _selectedDevicePresent =>
      c.devices.any((d) => d.id == c.selected?.id);
  bool get _hapticEditable => _editable && c.hapticSettingsAvailable;
  @override
  void initState() {
    super.initState();
    c = widget.controller ?? AppController();
    c.addListener(_changed);
    if (widget.controller == null) c.start();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    if (widget.controller == null) c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            Container(
              width: 200,
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: .5),
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(padding: EdgeInsets.fromLTRB(24, 5, 16, 26)),
                  for (final item in [
                    (1, Icons.vibration_rounded),
                    (2, Icons.screen_rotation_alt_rounded),
                    (3, Icons.swipe_rounded),
                    (4, Icons.touch_app_rounded),
                    (0, Icons.usb_rounded),
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      child: ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(5),
                        ),
                        selected: page == item.$1,
                        selectedTileColor: scheme.primary.withValues(
                          alpha: .08,
                        ),
                        leading: Icon(item.$2, size: 20),
                        title: Text(titles[item.$1]),
                        onTap: () => setState(() => page = item.$1),
                      ),
                    ),
                  const Spacer(),
                  _deviceSelector(),
                ],
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  if (c.demo)
                    Container(
                      width: double.infinity,
                      color: scheme.secondaryContainer,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '演示模式 · 不连接硬件',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          TextButton(
                            onPressed: c.busy ? null : () => c.setDemo(false),
                            child: const Text('退出'),
                          ),
                        ],
                      ),
                    ),
                  SizedBox(
                    height: 2,
                    child: c.busy
                        ? const LinearProgressIndicator(minHeight: 2)
                        : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            titles[page],
                            style: const TextStyle(
                              fontSize: 23,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        _actions(),
                      ],
                    ),
                  ),
                  Expanded(
                    child: c.refreshing
                        ? const Center(child: Text('正在重新读取设备设置…'))
                        : SingleChildScrollView(
                            // Do not reuse scroll/semantics nodes across unrelated
                            // pages. Windows applies AXTree updates incrementally.
                            key: ValueKey('settings-page-$page'),
                            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 900,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (!c.connected) ...[
                                      _notice(
                                        c.busy
                                            ? '正在连接触摸板…'
                                            : '未连接触摸板。接入 USB 后将自动连接。',
                                      ),
                                      const SizedBox(height: 16),
                                    ],
                                    if (c.error != null ||
                                        c.discoveryError != null) ...[
                                      _notice(
                                        c.error ?? c.discoveryError!,
                                        error: true,
                                      ),
                                      const SizedBox(height: 16),
                                    ],
                                    ...switch (page) {
                                      0 => _devicePage(),
                                      1 => _hapticPage(),
                                      2 => _generalPage(),
                                      3 => _edgePage(),
                                      _ => _pointPage(),
                                    },
                                  ],
                                ),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _deviceLabel(HidDevice device) {
    final index =
        c.devices
            .where((d) => d.isReceiver == device.isReceiver)
            .toList()
            .indexWhere((d) => d.id == device.id) +
        1;
    final serial = device.serial;
    final suffix = serial.length > 6
        ? serial.substring(serial.length - 6)
        : serial;
    return '${device.kindLabel} $index${suffix.isEmpty ? '' : ' · $suffix'}';
  }

  Widget _deviceSelector() {
    final devices = c.touchpads;
    final available = devices.any((d) => d.id == c.selected?.id);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                c.usbConnected(c.selected)
                    ? Icons.usb_rounded
                    : Icons.usb_off_rounded,
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  c.busy && !c.connected
                      ? '正在连接…'
                      : c.usbConnected(c.selected)
                      ? '已连接'
                      : '未连接',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            key: ValueKey(
              'device-selector-${available ? c.selected!.id : 'none'}',
            ),
            initialValue: available ? c.selected!.id : null,
            isExpanded: true,
            hint: const Text('未检测到设备', style: TextStyle(fontSize: 12)),
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
            items: [
              for (final d in devices)
                DropdownMenuItem(
                  value: d.id,
                  child: Tooltip(
                    message: '${d.name}\n${d.id}',
                    child: Text(
                      _deviceLabel(d),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
            ],
            onChanged: c.busy || devices.isEmpty
                ? null
                : (id) {
                    if (id != null) {
                      c.connect(devices.firstWhere((d) => d.id == id));
                    }
                  },
          ),
        ],
      ),
    );
  }

  Widget _notice(String text, {bool error = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        color: error ? scheme.errorContainer : scheme.surfaceContainerHighest,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(error ? Icons.error_outline : Icons.info_outline, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              text,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(
    String title,
    String subtitle,
    Widget child, {
    int? capability,
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
  List<Widget> _devicePage() => [
    _card(
      '设备',
      '',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _detail('名称', _selectedDevicePresent ? c.selected!.name : '未连接'),
          _detail('连接', _selectedDevicePresent ? 'USB' : '未连接'),
          _detail('设备 ID', c.selected?.usbId ?? '—'),
          _detail('序列号', _selectedDevicePresent ? c.selected!.serial : '—'),
          _detail(
            '固件版本',
            c.connected && c.client.modern ? c.client.firmware : '未提供',
          ),
          if (c.selected != null)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('连接详情', style: TextStyle(fontSize: 13)),
              children: [
                SelectableText(
                  '${c.selected!.id}\n${c.selected!.details}\n${c.client.note}',
                  style: const TextStyle(fontSize: 12, height: 1.5),
                ),
              ],
            ),
        ],
      ),
    ),
    const SizedBox(height: 16),
    _card(
      'DFU 固件升级',
      '让触摸板或接收器进入 DFU 升级模式',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (c.edited) ...[
            const Text('尚未保存的设置会保留在配置器中。'),
            const SizedBox(height: 12),
          ],
          _dfuRow(false),
          const Divider(height: 24),
          _dfuRow(true),
          if (c.dfuMessage != null) ...[
            const SizedBox(height: 12),
            Semantics(liveRegion: true, child: Text(c.dfuMessage!)),
          ],
        ],
      ),
    ),
    const SizedBox(height: 16),
    ExpansionTile(
      title: const Text('调试', style: TextStyle(fontSize: 13)),
      children: [
        ListTile(
          title: const Text('演示设备'),
          trailing: TextButton(
            onPressed: c.busy ? null : () => c.setDemo(!c.demo),
            child: Text(c.demo ? '退出' : '打开'),
          ),
        ),
      ],
    ),
  ];
  Widget _dfuRow(bool receiver) {
    final devices = c.devices.where((d) => d.isReceiver == receiver).toList();
    final selection = _dfuSelections[receiver];
    HidDevice? target;
    for (final device in devices) {
      if (device.id == (selection ?? c.selected?.id)) target = device;
    }
    if (selection == null && target == null && devices.length == 1) {
      target = devices.single;
    }
    final device = target;
    final label = receiver ? '接收器' : '触摸板';
    final online = c.usbConnected(device);
    final status = c.discoveryError != null
        ? '连接状态未知'
        : device != null && c.waitingForDfu(device)
        ? '已发送，等待断开'
        : online
        ? '已连接'
        : devices.isNotEmpty && device == null
        ? '请选择设备'
        : '未连接';
    return Row(
      key: ValueKey(receiver ? 'dfu-receiver' : 'dfu-touchpad'),
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$label · $status',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (devices.length > 1 ||
                  (selection != null &&
                      device == null &&
                      devices.isNotEmpty)) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: ValueKey('dfu-$receiver-${device?.id}'),
                  initialValue: device?.id,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: '选择$label'),
                  items: [
                    for (final d in devices)
                      DropdownMenuItem(
                        value: d.id,
                        child: Text(
                          _deviceLabel(d),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: c.busy
                      ? null
                      : (id) {
                          if (id != null) {
                            setState(() => _dfuSelections[receiver] = id);
                          }
                        },
                ),
              ] else if (device != null) ...[
                const SizedBox(height: 4),
                Text(
                  '${device.name} · ${device.usbId}',
                  style: const TextStyle(fontSize: 12),
                ),
              ] else if (receiver) ...[
                const SizedBox(height: 4),
                const Text('0D00:072D', style: TextStyle(fontSize: 12)),
              ],
            ],
          ),
        ),
        const SizedBox(width: 16),
        FilledButton.icon(
          onPressed: c.canEnterDfuFor(device) ? () => c.enterDfu(device) : null,
          icon: const Icon(Icons.system_update_alt_rounded),
          label: Text(c.demo ? '模拟进入 DFU 模式' : '进入 DFU 模式'),
        ),
      ],
    );
  }

  Widget _detail(String name, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(name, style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: SelectableText(value, style: const TextStyle(fontSize: 13)),
        ),
      ],
    ),
  );

  List<Widget> _hapticPage() {
    final intensity = _hapticEditable
        ? c.draft.intensity
        : c.knows(Capability.intensity)
        ? c.current?.intensity
        : null;
    final pressLevel = _hapticEditable
        ? c.draft.pressLevel
        : c.knows(Capability.pressLevel)
        ? c.current?.pressLevel
        : null;
    return [
      if (!c.hapticSettingsAvailable) ...[
        _notice('Windows 11 下触觉强度与按压触发设置将不可用，避免与原生系统偏好冲突。'),
        const SizedBox(height: 16),
      ],
      _card(
        '触觉反馈',
        '强度为 0 时关闭触觉反馈。',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (intensity == null)
              _detail('触觉强度', '未读取')
            else ...[
              _slider(
                '触觉强度',
                intensity,
                0,
                100,
                (v) => c.update(c.draft.copyWith(intensity: v)),
                suffix: '%',
                enabled: _hapticEditable,
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final v in [0, 25, 63, 75, 100])
                    ChoiceChip(
                      label: Text(v == 0 ? '关闭' : '$v'),
                      selected: intensity == v,
                      onSelected: !_hapticEditable
                          ? null
                          : (_) => c.update(c.draft.copyWith(intensity: v)),
                    ),
                ],
              ),
            ],
          ],
        ),
        capability: Capability.intensity,
      ),
      const SizedBox(height: 20),
      _card(
        '按压触发',
        '设置触发点击所需的按压力度。',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pressLevel == null)
              const Text('未读取')
            else
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('轻')),
                  ButtonSegment(value: 2, label: Text('中')),
                  ButtonSegment(value: 3, label: Text('重')),
                ],
                selected: {pressLevel},
                onSelectionChanged: !_hapticEditable
                    ? null
                    : (v) => c.update(c.draft.copyWith(pressLevel: v.first)),
              ),
          ],
        ),
        capability: Capability.pressLevel,
      ),
      const SizedBox(height: 20),
      _card(
        '有线连接三档阈值',
        '有线连接下的原始压力值，范围 1～255；轻 ≤ 中 ≤ 重。',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                NumberEditor(
                  label: '轻档阈值',
                  value: c.draft.light,
                  min: 1,
                  max: 255,
                  enabled: _editable,
                  onChanged: (v) => c.update(c.draft.copyWith(light: v)),
                ),
                NumberEditor(
                  label: '中档阈值',
                  value: c.draft.medium,
                  min: 1,
                  max: 255,
                  enabled: _editable,
                  onChanged: (v) => c.update(c.draft.copyWith(medium: v)),
                ),
                NumberEditor(
                  label: '重档阈值',
                  value: c.draft.strong,
                  min: 1,
                  max: 255,
                  enabled: _editable,
                  onChanged: (v) => c.update(c.draft.copyWith(strong: v)),
                ),
              ],
            ),
            if (c.draft.light > c.draft.medium ||
                c.draft.medium > c.draft.strong)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _notice('请确保轻档 ≤ 中档 ≤ 重档。', error: true),
              ),
          ],
        ),
        capability: Capability.thresholds,
      ),
      const SizedBox(height: 20),
      _card(
        '无线连接三档阈值',
        '无线连接下的压力值，范围 1～100；轻 ≤ 中 ≤ 重。',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                NumberEditor(
                  label: '无线轻档阈值',
                  value: c.draft.wirelessLight,
                  min: 1,
                  max: 100,
                  enabled: _editable,
                  onChanged: (v) =>
                      c.update(c.draft.copyWith(wirelessLight: v)),
                ),
                NumberEditor(
                  label: '无线中档阈值',
                  value: c.draft.wirelessMedium,
                  min: 1,
                  max: 100,
                  enabled: _editable,
                  onChanged: (v) =>
                      c.update(c.draft.copyWith(wirelessMedium: v)),
                ),
                NumberEditor(
                  label: '无线重档阈值',
                  value: c.draft.wirelessStrong,
                  min: 1,
                  max: 100,
                  enabled: _editable,
                  onChanged: (v) =>
                      c.update(c.draft.copyWith(wirelessStrong: v)),
                ),
              ],
            ),
            if (c.draft.wirelessLight > c.draft.wirelessMedium ||
                c.draft.wirelessMedium > c.draft.wirelessStrong)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _notice('请确保无线轻档 ≤ 中档 ≤ 重档。', error: true),
              ),
          ],
        ),
        capability: Capability.wirelessThresholds,
      ),
    ];
  }

  List<Widget> _generalPage() => [
    _card(
      '摆放方向',
      '按触摸板的摆放方向设置。',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 12,
            children: [
              for (var i = 0; i < 4; i++)
                ChoiceChip(
                  avatar: RotatedBox(
                    quarterTurns: i,
                    child: const Icon(Icons.stay_current_landscape, size: 20),
                  ),
                  label: Text(rotationNames[i]),
                  selected: c.draft.rotation == i,
                  onSelected: !_editable
                      ? null
                      : (_) => c.update(c.draft.copyWith(rotation: i)),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
      capability: Capability.rotation,
    ),
    const SizedBox(height: 20),
    _card(
      '自动休眠',
      '闲置超过指定时间后休眠。',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用自动休眠'),
            value: c.draft.sleepEnabled,
            onChanged: !_editable
                ? null
                : (v) => c.update(c.draft.copyWith(sleepEnabled: v)),
          ),
          const SizedBox(height: 16),
          NumberEditor(
            label: '闲置时间（秒）',
            value: c.draft.sleepMs ~/ 1000,
            min: 1,
            max: 3600,
            enabled: _editable && c.draft.sleepEnabled,
            onChanged: (v) => c.update(c.draft.copyWith(sleepMs: v * 1000)),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final seconds in [60, 180, 300, 600])
                ActionChip(
                  label: Text('${seconds ~/ 60} 分钟'),
                  onPressed: !_editable
                      ? null
                      : () =>
                            c.update(c.draft.copyWith(sleepMs: seconds * 1000)),
                ),
            ],
          ),
        ],
      ),
      capability: Capability.sleep,
    ),
  ];
  List<Widget> _edgePage() {
    final selectedEdge = _selectedEdge;
    final edgeEditable = _editable && selectedEdge != null;
    final edgeConfig = selectedEdge == null
        ? const EdgeConfig()
        : c.draft.edges[selectedEdge.index];
    final edgeSettingsEditable = edgeEditable && edgeConfig.enabled;
    void updateEdgeConfig(EdgeConfig updatedEdgeConfig) {
      if (!edgeEditable) return;
      final updatedEdges = [...c.draft.edges];
      updatedEdges[selectedEdge.index] = updatedEdgeConfig;
      c.update(c.draft.copyWith(edges: updatedEdges));
    }

    return [
      _card(
        '边缘区域',
        '左、右边上下滑动；上、下边左右滑动。',
        Column(
          children: [
            SizedBox(
              height: 220,
              child: Center(
                child: SizedBox(
                  width: 300,
                  height: 220,
                  child: TouchpadDiagram(
                    edges: c.draft.edges,
                    selectedEdge: selectedEdge,
                    onEdgeSelected: _editable
                        ? (edgeSide) => setState(() => _selectedEdge = edgeSide)
                        : null,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final edgeSide in EdgeSide.values)
                  ChoiceChip(
                    label: Text(edgeNames[edgeSide.index]),
                    selected: selectedEdge == edgeSide,
                    onSelected: _editable
                        ? (_) => setState(() => _selectedEdge = edgeSide)
                        : null,
                  ),
              ],
            ),
          ],
        ),
        capability: Capability.edges,
      ),
      const SizedBox(height: 20),
      _card(
        selectedEdge == null ? '边缘设置' : '${edgeNames[selectedEdge.index]}设置',
        selectedEdge == null ? '请先选择边缘区域' : '',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用此边缘'),
              value: edgeConfig.enabled,
              onChanged: !edgeEditable
                  ? null
                  : (value) => updateEdgeConfig(
                      edgeConfig.copyWith(
                        enabled: value,
                        action: value && edgeConfig.action == EdgeAction.off
                            ? EdgeAction.volume
                            : edgeConfig.action,
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<EdgeAction>(
              key: ValueKey('${selectedEdge?.name}-${edgeConfig.action.name}'),
              initialValue: edgeConfig.action,
              decoration: const InputDecoration(labelText: '绑定功能'),
              items: [
                for (final action in EdgeAction.values)
                  DropdownMenuItem(
                    value: action,
                    child: Text(actionNames[action.index]),
                  ),
              ],
              onChanged: !edgeSettingsEditable
                  ? null
                  : (value) {
                      if (value != null) {
                        updateEdgeConfig(
                          edgeConfig.copyWith(
                            action: value,
                            enabled: value != EdgeAction.off,
                          ),
                        );
                      }
                    },
            ),
            const SizedBox(height: 12),
            _slider(
              '边缘宽度',
              edgeConfig.width,
              1,
              selectedEdge?.maxWidthPercent ?? EdgeSide.left.maxWidthPercent,
              (value) => updateEdgeConfig(edgeConfig.copyWith(width: value)),
              suffix: '%',
              enabled: edgeSettingsEditable,
            ),
            _slider(
              '触发步距',
              edgeConfig.step,
              1,
              10,
              (value) => updateEdgeConfig(edgeConfig.copyWith(step: value)),
              suffix: '%',
              enabled: edgeSettingsEditable,
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('反转滑动方向'),
              subtitle: selectedEdge == null
                  ? null
                  : Text(edgeConfig.direction(selectedEdge)),
              value: edgeConfig.reversed,
              onChanged: !edgeSettingsEditable
                  ? null
                  : (value) =>
                        updateEdgeConfig(edgeConfig.copyWith(reversed: value)),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('手指不抬起继续动作'),
              subtitle: Text('随着手指移到触控板边缘外，继续执行动作'),
              value: edgeConfig.repeatWhileHeld,
              onChanged: !edgeSettingsEditable
                  ? null
                  : (value) => updateEdgeConfig(
                      edgeConfig.copyWith(repeatWhileHeld: value),
                    ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
    ];
  }

  List<Widget> _pointPage() {
    final selectedPoint = _selectedPoint;
    final pointEditable = _editable && selectedPoint != null;
    final pointConfig = selectedPoint == null
        ? const PointConfig()
        : c.draft.points[selectedPoint.index];
    final pointSettingsEditable = pointEditable && pointConfig.enabled;
    void updatePointConfig(PointConfig updatedPointConfig) {
      if (!pointEditable) return;
      final updatedPoints = [...c.draft.points];
      updatedPoints[selectedPoint.index] = updatedPointConfig;
      c.update(c.draft.copyWith(points: updatedPoints));
    }

    return [
      _card(
        '焦点区域',
        '圆心固定在四角，半径按触控板短边百分比计算。单点与边缘分别设置。',
        Column(
          children: [
            SizedBox(
              height: 220,
              child: Center(
                child: SizedBox(
                  width: 300,
                  height: 220,
                  child: PointDiagram(
                    points: c.draft.points,
                    selectedPoint: selectedPoint,
                    onPointSelected: _editable
                        ? (pointPosition) =>
                              setState(() => _selectedPoint = pointPosition)
                        : null,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final position in PointPosition.values)
                  ChoiceChip(
                    label: Text(pointNames[position.index]),
                    selected: selectedPoint == position,
                    onSelected: _editable
                        ? (_) => setState(() => _selectedPoint = position)
                        : null,
                  ),
              ],
            ),
          ],
        ),
        capability: Capability.points,
      ),
      const SizedBox(height: 20),
      _card(
        selectedPoint == null ? '单点设置' : '${pointNames[selectedPoint.index]}设置',
        selectedPoint == null ? '请先选择焦点区域' : '',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用此焦点'),
              value: pointConfig.enabled,
              onChanged: !pointEditable
                  ? null
                  : (value) => updatePointConfig(
                      pointConfig.copyWith(
                        enabled: value,
                        action: value && pointConfig.action == PointAction.off
                            ? PointAction.volumeUp
                            : pointConfig.action,
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<PointAction>(
              key: ValueKey(
                'point-${selectedPoint?.name}-${pointConfig.action.name}',
              ),
              initialValue: pointConfig.action,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: '绑定功能',
                helperText:
                    pointConfig.action.isFunctionKey &&
                        c.capabilities & Capability.pointFunctionKeys == 0
                    ? '当前设备不支持此功能键，此点设置仅保留为预览。'
                    : null,
                helperMaxLines: 2,
              ),
              items: [
                for (final action in PointAction.values)
                  DropdownMenuItem(
                    value: action,
                    child: Text(pointActionNames[action.index]),
                  ),
              ],
              onChanged: !pointSettingsEditable
                  ? null
                  : (value) {
                      if (value != null) {
                        updatePointConfig(
                          pointConfig.copyWith(
                            action: value,
                            enabled: value != PointAction.off,
                          ),
                        );
                      }
                    },
            ),
            const SizedBox(height: 12),
            _slider(
              '区域半径',
              pointConfig.radius,
              1,
              30,
              (value) => updatePointConfig(pointConfig.copyWith(radius: value)),
              suffix: '%',
              enabled: pointSettingsEditable,
            ),
            _slider(
              '触发步距',
              pointConfig.step,
              1,
              10,
              (value) => updatePointConfig(pointConfig.copyWith(step: value)),
              suffix: '%',
              enabled: pointSettingsEditable,
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('手指不抬起继续动作'),
              subtitle: const Text('重复当前单点动作；转为滑动后进入边缘手势。'),
              value: pointConfig.repeatWhileHeld,
              onChanged: !pointSettingsEditable
                  ? null
                  : (value) => updatePointConfig(
                      pointConfig.copyWith(repeatWhileHeld: value),
                    ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('允许点转为滑动时继续沿用边缘解析'),
              subtitle: Text('仅作用于从此点开始的点击。关闭时移动仍按点击处理；开启后保留点击，达到此点步距再进入边缘解析。'),
              value: pointConfig.allowPointToEdge,
              onChanged: !pointSettingsEditable
                  ? null
                  : (value) => updatePointConfig(
                      pointConfig.copyWith(allowPointToEdge: value),
                    ),
            ),
          ],
        ),
        capability: Capability.points,
      ),
      const SizedBox(height: 20),
    ];
  }

  Widget _slider(
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> onChanged, {
    String suffix = '',
    bool enabled = true,
  }) => Column(
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            '$value$suffix',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: enabled
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).disabledColor,
            ),
          ),
        ],
      ),
      // Slider owns an OverlayPortal for its value indicator, even when the
      // indicator is not visible. Give each anchor a distinct semantics node
      // so adjacent sliders cannot merge their traversal parent identifiers.
      Semantics(
        container: true,
        child: Slider(
          value: value.clamp(min, max).toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          label: '$value$suffix',
          onChanged: !_editable || !enabled
              ? null
              : (v) => onChanged(v.round()),
        ),
      ),
    ],
  );
  Future<void> _runDeviceAction(Future<void> Function() action) async {
    await action();
    if (!mounted || c.error != null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(c.message)));
  }

  Widget _actions() => Wrap(
    spacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      IconButton(
        tooltip: '重新读取设备',
        onPressed: _editable ? () => _runDeviceAction(c.refresh) : null,
        icon: const Icon(Icons.refresh),
      ),
      TextButton(
        onPressed: _editable ? c.useDeviceValues : null,
        child: const Text('恢复设备值'),
      ),
      FilledButton.icon(
        onPressed: c.canApply ? () => _runDeviceAction(c.apply) : null,
        icon: const Icon(Icons.check_rounded),
        label: Text(c.demo ? '保存到演示设备' : '保存'),
      ),
    ],
  );
}

class NumberEditor extends StatefulWidget {
  const NumberEditor({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.enabled = true,
  });
  final String label;
  final int value, min, max;
  final bool enabled;
  final ValueChanged<int> onChanged;
  @override
  State<NumberEditor> createState() => _NumberEditorState();
}

class _NumberEditorState extends State<NumberEditor> {
  late final TextEditingController text = TextEditingController(
    text: '${widget.value}',
  );
  @override
  void didUpdateWidget(NumberEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value &&
        int.tryParse(text.text) != widget.value &&
        !(text.text.isEmpty && widget.value == 0)) {
      text.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 170,
    child: TextField(
      controller: text,
      enabled: widget.enabled,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: '${widget.min}～${widget.max}',
        errorText: widget.value < widget.min || widget.value > widget.max
            ? '超出范围'
            : null,
      ),
      onChanged: (v) => widget.onChanged(int.tryParse(v) ?? 0),
    ),
  );
}

class TouchpadDiagram extends StatelessWidget {
  const TouchpadDiagram({
    super.key,
    required this.edges,
    this.selectedEdge,
    this.onEdgeSelected,
  });
  final List<EdgeConfig> edges;
  final EdgeSide? selectedEdge;
  final ValueChanged<EdgeSide>? onEdgeSelected;
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: CustomPaint(
          painter: _EdgePainter(
            Theme.of(context).colorScheme,
            edges,
            selectedEdge,
          ),
        ),
      ),
      if (onEdgeSelected != null) ...[
        for (final edgeSide in EdgeSide.values)
          Align(
            alignment: switch (edgeSide) {
              EdgeSide.top => Alignment.topCenter,
              EdgeSide.bottom => Alignment.bottomCenter,
              EdgeSide.left => Alignment.centerLeft,
              EdgeSide.right => Alignment.centerRight,
            },
            // Keep each OverlayPortal traversal anchor on its own node.
            // Merging sibling tooltip anchors can orphan Windows AX nodes:
            // https://github.com/flutter/flutter/issues/182444
            child: Semantics(
              container: true,
              child: Tooltip(
                message:
                    '${edgeNames[edgeSide.index]}：${actionNames[edges[edgeSide.index].action.index]}',
                child: IconButton(
                  onPressed: () => onEdgeSelected!(edgeSide),
                  icon: Icon(
                    edgeSide == EdgeSide.left || edgeSide == EdgeSide.right
                        ? Icons.swap_vert
                        : Icons.swap_horiz,
                    color: selectedEdge == edgeSide
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                ),
              ),
            ),
          ),
      ],
    ],
  );
}

class PointDiagram extends StatelessWidget {
  const PointDiagram({
    super.key,
    required this.points,
    this.selectedPoint,
    this.onPointSelected,
  });
  final List<PointConfig> points;
  final PointPosition? selectedPoint;
  final ValueChanged<PointPosition>? onPointSelected;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: CustomPaint(
          painter: _PointPainter(
            Theme.of(context).colorScheme,
            points,
            selectedPoint,
          ),
        ),
      ),
      Center(
        child: Text(
          selectedPoint == null
              ? '选择焦点'
              : '${pointNames[selectedPoint!.index]}\n半径 ${points[selectedPoint!.index].radius}% 短边',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
      ),
      for (final position in PointPosition.values)
        Align(
          alignment: switch (position) {
            PointPosition.topLeft => Alignment.topLeft,
            PointPosition.topRight => Alignment.topRight,
            PointPosition.bottomLeft => Alignment.bottomLeft,
            PointPosition.bottomRight => Alignment.bottomRight,
          },
          child: Semantics(
            container: true,
            selected: selectedPoint == position,
            child: Tooltip(
              message:
                  '${pointNames[position.index]}：${points[position.index].description}，半径 ${points[position.index].radius}%',
              excludeFromSemantics: true,
              child: IconButton(
                onPressed: onPointSelected == null
                    ? null
                    : () => onPointSelected!(position),
                icon: Icon(
                  Icons.adjust,
                  semanticLabel:
                      '${pointNames[position.index]}：${points[position.index].description}，半径 ${points[position.index].radius}%',
                  color: selectedPoint == position
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class _PointPainter extends CustomPainter {
  _PointPainter(this.scheme, this.points, this.selectedPoint);
  final ColorScheme scheme;
  final List<PointConfig> points;
  final PointPosition? selectedPoint;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = const EdgeInsets.all(38).deflateRect(Offset.zero & size);
    canvas.drawRect(rect, Paint()..color = scheme.surfaceContainerHighest);
    canvas.save();
    canvas.clipRect(rect);
    for (final position in PointPosition.values) {
      final pointConfig = points[position.index];
      final center =
          rect.topLeft +
          Offset(position.centerX(rect.width), position.centerY(rect.height));
      final radius = pointConfig.radiusFor(rect.width, rect.height);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = scheme.primary.withValues(
            alpha: selectedPoint == position
                ? .6
                : pointConfig.enabled
                ? .3
                : .08,
          ),
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = scheme.primary.withValues(alpha: .6),
      );
      canvas.drawCircle(center, 2, Paint()..color = scheme.primary);
      if (selectedPoint == position) {
        // The diagonal radius stays inside the quarter circle.
        final dx = (position.index.isOdd ? -1 : 1) * radius * .7071067811865476;
        final dy = (position.index >= 2 ? -1 : 1) * radius * .7071067811865476;
        canvas.drawLine(
          center,
          center + Offset(dx, dy),
          Paint()
            ..color = scheme.onSurface
            ..strokeWidth = 1,
        );
      }
    }
    canvas.restore();
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = scheme.outline.withValues(alpha: .3),
    );
  }

  @override
  bool shouldRepaint(covariant _PointPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.selectedPoint != selectedPoint ||
      oldDelegate.scheme != scheme;
}

class _EdgePainter extends CustomPainter {
  _EdgePainter(this.scheme, this.edges, this.selectedEdge);
  final ColorScheme scheme;
  final List<EdgeConfig> edges;
  final EdgeSide? selectedEdge;
  @override
  void paint(Canvas canvas, Size size) {
    // Leave the same clearance for the arrow icons on all four sides.
    final rect = const EdgeInsets.all(38).deflateRect(Offset.zero & size);
    final rounded = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas.drawRRect(rounded, Paint()..color = scheme.surfaceContainerHighest);
    canvas.save();
    canvas.clipRRect(rounded);
    for (final edgeSide in EdgeSide.values) {
      final edgeConfig = edges[edgeSide.index];
      final width =
          (edgeSide == EdgeSide.top || edgeSide == EdgeSide.bottom
              ? rect.height
              : rect.width) *
          edgeConfig.width /
          100;
      final band = switch (edgeSide) {
        EdgeSide.top => Rect.fromLTWH(rect.left, rect.top, rect.width, width),
        EdgeSide.bottom => Rect.fromLTWH(
          rect.left,
          rect.bottom - width,
          rect.width,
          width,
        ),
        EdgeSide.left => Rect.fromLTWH(rect.left, rect.top, width, rect.height),
        EdgeSide.right => Rect.fromLTWH(
          rect.right - width,
          rect.top,
          width,
          rect.height,
        ),
      };
      canvas.drawRect(
        band,
        Paint()
          ..color = scheme.primary.withValues(
            alpha: selectedEdge == edgeSide
                ? .6
                : edgeConfig.enabled
                ? .3
                : .06,
          ),
      );
    }
    canvas.restore();
    canvas.drawRRect(
      rounded,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = scheme.outline.withValues(alpha: .3),
    );
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) =>
      oldDelegate.edges != edges ||
      oldDelegate.selectedEdge != selectedEdge ||
      oldDelegate.scheme != scheme;
}
