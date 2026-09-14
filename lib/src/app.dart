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
  EdgeSide side = EdgeSide.left;
  static const titles = ['设备信息', '触觉与按压', '方向与休眠', '边缘滑动'];
  bool get _editable => c.connected && !c.busy;
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
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 5, 16, 26),
                  ),
                  for (final item in [
                    (1, Icons.vibration_rounded),
                    (2, Icons.screen_rotation_alt_rounded),
                    (3, Icons.swipe_rounded),
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
                    child: SingleChildScrollView(
                      // Do not reuse scroll/semantics nodes across unrelated
                      // pages. Windows applies AXTree updates incrementally.
                      key: ValueKey('settings-page-$page'),
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 900),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!c.connected) ...[
                                _notice(
                                  c.busy ? '正在连接触摸板…' : '未连接触摸板。接入 USB 后将自动连接。',
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
                                _ => _edgePage(),
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
    final index = c.devices.indexWhere((d) => d.id == device.id) + 1;
    final serial = device.serial;
    final suffix = serial.length > 6
        ? serial.substring(serial.length - 6)
        : serial;
    return '触摸板 $index${suffix.isEmpty ? '' : ' · $suffix'}';
  }

  Widget _deviceSelector() {
    final available = c.devices.any((d) => d.id == c.selected?.id);
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
                c.connected ? Icons.usb_rounded : Icons.usb_off_rounded,
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  c.busy && !c.connected
                      ? '正在连接…'
                      : c.connected
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
              for (final d in c.devices)
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
            onChanged: c.busy || c.devices.isEmpty
                ? null
                : (id) {
                    if (id != null) {
                      c.connect(c.devices.firstWhere((d) => d.id == id));
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
              if (c.connected && capability != null && !c.supports(capability))
                Text(
                  '固件暂不支持',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
  Widget _readback(int bit, String value) => !c.edited
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            '设备当前值：${c.knows(bit) ? value : '未读取'}',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
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
          _detail('名称', c.connected ? c.selected!.name : '未连接'),
          _detail('连接', 'USB'),
          _detail('设备 ID', '0D00:072C'),
          _detail('序列号', c.connected ? c.selected!.serial : '—'),
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

  List<Widget> _hapticPage() => [
    _card(
      '触觉反馈',
      '强度为 0 时关闭触觉反馈。',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _slider(
            '触觉强度',
            c.draft.intensity,
            0,
            100,
            (v) => c.update(c.draft.copyWith(intensity: v)),
            suffix: '%',
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final v in [0, 25, 63, 75, 100])
                ChoiceChip(
                  label: Text(
                    v == 0
                        ? '关闭'
                        : v == 63
                        ? '默认 63'
                        : '$v',
                  ),
                  selected: c.draft.intensity == v,
                  onSelected: !_editable
                      ? null
                      : (_) => c.update(c.draft.copyWith(intensity: v)),
                ),
            ],
          ),
          _readback(Capability.intensity, '${c.current?.intensity} / 100'),
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
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('轻')),
              ButtonSegment(value: 2, label: Text('中')),
              ButtonSegment(value: 3, label: Text('重')),
            ],
            selected: {c.draft.pressLevel},
            onSelectionChanged: !_editable
                ? null
                : (v) => c.update(c.draft.copyWith(pressLevel: v.first)),
          ),
          _readback(
            Capability.pressLevel,
            c.current == null ? '' : ['轻', '中', '重'][c.current!.pressLevel - 1],
          ),
        ],
      ),
      capability: Capability.pressLevel,
    ),
    const SizedBox(height: 20),
    _card(
      '自定义三档阈值',
      '原始压力值，范围 1～255；轻 ≤ 中 ≤ 重。',
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
          if (c.draft.light > c.draft.medium || c.draft.medium > c.draft.strong)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _notice('请确保轻档 ≤ 中档 ≤ 重档。', error: true),
            ),
          _readback(
            Capability.thresholds,
            '${c.current?.light} / ${c.current?.medium} / ${c.current?.strong}',
          ),
        ],
      ),
      capability: Capability.thresholds,
    ),
  ];
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
          _readback(
            Capability.rotation,
            c.current == null ? '' : rotationNames[c.current!.rotation],
          ),
          const SizedBox(height: 12),
          const Text('更改方向后，设备可能会短暂断开并重新连接。', style: TextStyle(fontSize: 12)),
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
          _readback(
            Capability.sleep,
            c.current?.sleepEnabled == true
                ? '${c.current!.sleepMs ~/ 1000} 秒后休眠'
                : '关闭',
          ),
        ],
      ),
      capability: Capability.sleep,
    ),
  ];
  List<Widget> _edgePage() {
    final e = c.draft.edges[side.index];
    void change(EdgeConfig value) {
      final edges = [...c.draft.edges];
      edges[side.index] = value;
      c.update(c.draft.copyWith(edges: edges));
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
                  width: 380,
                  height: 220,
                  child: TouchpadDiagram(
                    edges: c.draft.edges,
                    selected: side,
                    onSelect: _editable
                        ? (s) => setState(() => side = s)
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
                for (final s in EdgeSide.values)
                  ChoiceChip(
                    label: Text(edgeNames[s.index]),
                    selected: side == s,
                    onSelected: _editable
                        ? (_) => setState(() => side = s)
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
        '${edgeNames[side.index]}设置',
        e.direction(side),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用此边缘'),
              value: e.enabled,
              onChanged: !_editable
                  ? null
                  : (v) => change(
                      e.copyWith(
                        enabled: v,
                        action: v && e.action == EdgeAction.off
                            ? EdgeAction.volume
                            : e.action,
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<EdgeAction>(
              key: ValueKey('${side.name}-${e.action.name}'),
              initialValue: e.action,
              decoration: const InputDecoration(labelText: '绑定功能'),
              items: [
                for (final action in EdgeAction.values)
                  DropdownMenuItem(
                    value: action,
                    child: Text(actionNames[action.index]),
                  ),
              ],
              onChanged: !_editable
                  ? null
                  : (v) {
                      if (v != null) {
                        change(
                          e.copyWith(action: v, enabled: v != EdgeAction.off),
                        );
                      }
                    },
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('反转滑动方向'),
              subtitle: Text(e.direction(side)),
              value: e.reversed,
              onChanged: !_editable
                  ? null
                  : (v) => change(e.copyWith(reversed: v)),
            ),
            _slider(
              '边缘宽度',
              e.width,
              1,
              side.maxWidthPercent,
              (v) => change(e.copyWith(width: v)),
              suffix: '%',
            ),
            _slider(
              '触发步距',
              e.step,
              1,
              10,
              (v) => change(e.copyWith(step: v)),
              suffix: '%',
            ),
            const Text(
              '宽度按垂直于该边的尺寸计算；步距按沿边尺寸计算。每跨过一个步距触发一次增减或滚动。',
              style: TextStyle(fontSize: 12, height: 1.7),
            ),
            _readback(
              Capability.edges,
              c.current == null
                  ? ''
                  : '${actionNames[c.current!.edges[side.index].action.index]} · ${c.current!.edges[side.index].direction(side)}',
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      _notice('边缘功能由设备执行。亮度调节需要系统和显示器支持。'),
    ];
  }

  Widget _slider(
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> onChanged, {
    String suffix = '',
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
              color: Theme.of(context).colorScheme.primary,
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
          onChanged: !_editable ? null : (v) => onChanged(v.round()),
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
    this.selected,
    this.onSelect,
  });
  final List<EdgeConfig> edges;
  final EdgeSide? selected;
  final ValueChanged<EdgeSide>? onSelect;
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: CustomPaint(
          painter: _PadPainter(Theme.of(context).colorScheme, edges, selected),
        ),
      ),
      if (onSelect != null) ...[
        for (final s in EdgeSide.values)
          Align(
            alignment: switch (s) {
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
                    '${edgeNames[s.index]}：${actionNames[edges[s.index].action.index]}',
                child: IconButton(
                  onPressed: () => onSelect!(s),
                  icon: Icon(
                    s == EdgeSide.left || s == EdgeSide.right
                        ? Icons.swap_vert
                        : Icons.swap_horiz,
                    color: selected == s
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

class _PadPainter extends CustomPainter {
  _PadPainter(this.scheme, this.edges, this.selected);
  final ColorScheme scheme;
  final List<EdgeConfig> edges;
  final EdgeSide? selected;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(38, 22, size.width - 76, size.height - 44);
    final rounded = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas.drawRRect(rounded, Paint()..color = scheme.surfaceContainerHighest);
    canvas.save();
    canvas.clipRRect(rounded);
    for (final s in EdgeSide.values) {
      final edge = edges[s.index];
      final width =
          (s == EdgeSide.top || s == EdgeSide.bottom
              ? rect.height
              : rect.width) *
          edge.width /
          100;
      final band = switch (s) {
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
            alpha: selected == s
                ? .6
                : edge.enabled
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
  bool shouldRepaint(covariant _PadPainter oldDelegate) =>
      oldDelegate.edges != edges ||
      oldDelegate.selected != selected ||
      oldDelegate.scheme != scheme;
}
