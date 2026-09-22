import 'dart:typed_data';

abstract final class Capability {
  static const intensity = 1;
  static const pressLevel = 2;
  static const thresholds = 4;
  static const rotation = 8;
  static const sleep = 16;
  static const edges = 32;
  static const edgeArrowKeys = 64;
  static const edgeRepeat = 128;
  static const points = 256;
  static const pointToEdge = 512;
  static const wirelessThresholds = 1024;
  static const pointFunctionKeys = 2048;
  static const v1 = 255;
  static const v2 = 3071;
  static const all = 4095;

  static int negotiated(int mask, int configVersion) {
    mask &= switch (configVersion) {
      1 => v1,
      2 => v2,
      3 => all,
      _ => 0,
    };
    if (mask & edges == 0) {
      mask &= ~(edgeArrowKeys | edgeRepeat | pointToEdge);
    }
    if (mask & points == 0) mask &= ~(pointToEdge | pointFunctionKeys);
    return mask;
  }
}

enum EdgeSide {
  top,
  bottom,
  left,
  right;

  int get maxWidthPercent => this == top || this == bottom ? 30 : 15;
}

enum EdgeAction {
  off,
  brightness,
  volume,
  verticalWheel,
  horizontalWheel,
  verticalArrowKeys,
  horizontalArrowKeys;

  bool get isArrowKey =>
      this == verticalArrowKeys || this == horizontalArrowKeys;

  bool get usesTriggerStep => switch (this) {
    brightness || volume || verticalWheel || horizontalWheel => true,
    _ => false,
  };
}

const edgeNames = ['上边缘', '下边缘', '左边缘', '右边缘'];
const actionNames = ['关闭', '亮度', '音量', '垂直滚轮', '水平滚轮', '上下方向键', '左右方向键'];
const rotationNames = ['横向', '纵向', '横向翻转', '纵向翻转'];

enum PointPosition {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight;

  double centerX(double width) => index.isOdd ? width : 0;
  double centerY(double height) => index >= 2 ? height : 0;
}

enum PointAction {
  off,
  brightnessUp,
  brightnessDown,
  volumeUp,
  volumeDown,
  wheelUp,
  wheelDown,
  wheelRight,
  wheelLeft,
  arrowUp,
  arrowDown,
  arrowRight,
  arrowLeft,
  // Wire IDs are enum indices. Append new actions; never reorder existing ones.
  mute,
  playPause,
  previousTrack,
  nextTrack,
  mediaStop,
  escape,
  enter,
  tab,
  space,
  backspace,
  delete,
  insert,
  home,
  end,
  pageUp,
  pageDown,
  printScreen,
  f1,
  f2,
  f3,
  f4,
  f5,
  f6,
  f7,
  f8,
  f9,
  f10,
  f11,
  f12,
  copy,
  paste,
  cut,
  undo,
  redo,
  selectAll;

  bool get isFunctionKey => index >= mute.index;

  bool get usesTriggerStep => switch (this) {
    brightnessUp ||
    brightnessDown ||
    volumeUp ||
    volumeDown ||
    wheelUp ||
    wheelDown ||
    wheelRight ||
    wheelLeft => true,
    _ => false,
  };

  PointAction get opposite => this == off || isFunctionKey
      ? this
      : values[index.isOdd ? index + 1 : index - 1];
}

const pointNames = ['左上点', '右上点', '左下点', '右下点'];
const pointActionNames = [
  '关闭',
  '增加亮度',
  '降低亮度',
  '增加音量',
  '降低音量',
  '滚轮向上',
  '滚轮向下',
  '滚轮向右',
  '滚轮向左',
  '方向键 ↑',
  '方向键 ↓',
  '方向键 →',
  '方向键 ←',
  '静音',
  '播放 / 暂停',
  '上一曲',
  '下一曲',
  '停止播放',
  'Esc',
  'Enter',
  'Tab',
  '空格',
  'Backspace',
  'Delete',
  'Insert',
  'Home',
  'End',
  'Page Up',
  'Page Down',
  'Print Screen',
  'F1',
  'F2',
  'F3',
  'F4',
  'F5',
  'F6',
  'F7',
  'F8',
  'F9',
  'F10',
  'F11',
  'F12',
  '复制（Ctrl+C）',
  '粘贴（Ctrl+V）',
  '剪切（Ctrl+X）',
  '撤销（Ctrl+Z）',
  '重做（Ctrl+Y）',
  '全选（Ctrl+A）',
];

class PointConfig {
  const PointConfig({
    this.enabled = false,
    this.action = PointAction.off,
    this.radius = 5,
    this.step = 1,
    this.repeatWhileHeld = false,
    this.allowPointToEdge = false,
  });

  final bool enabled, repeatWhileHeld, allowPointToEdge;
  final PointAction action;
  final int radius, step;

  String get description => !enabled || action == PointAction.off
      ? '未启用'
      : pointActionNames[action.index];

  PointConfig copyWith({
    bool? enabled,
    PointAction? action,
    int? radius,
    int? step,
    bool? repeatWhileHeld,
    bool? allowPointToEdge,
  }) => PointConfig(
    enabled: enabled ?? this.enabled,
    action: action ?? this.action,
    radius: radius ?? this.radius,
    step: step ?? this.step,
    repeatWhileHeld: repeatWhileHeld ?? this.repeatWhileHeld,
    allowPointToEdge: allowPointToEdge ?? this.allowPointToEdge,
  );

  List<int> get bytes => [
    enabled ? 1 : 0,
    action.index,
    0, // Reserved; old reversal flags are normalized to a concrete action on read.
    radius,
    step,
  ];
  bool get isDefault =>
      !enabled &&
      action == PointAction.off &&
      radius == 5 &&
      step == 1 &&
      !repeatWhileHeld &&
      !allowPointToEdge;

  // Preview geometry uses the already-rotated surface, with equal X/Y units.
  double radiusFor(double width, double height) =>
      (width < height ? width : height) * radius / 100;

  bool contains(
    PointPosition position,
    double x,
    double y,
    double width,
    double height,
  ) {
    if (width <= 0 ||
        height <= 0 ||
        x < 0 ||
        y < 0 ||
        x > width ||
        y > height) {
      return false;
    }
    final dx = x - position.centerX(width);
    final dy = y - position.centerY(height);
    final r = radiusFor(width, height);
    return dx * dx + dy * dy <= r * r;
  }
}

class EdgeConfig {
  const EdgeConfig({
    this.enabled = false,
    this.action = EdgeAction.off,
    this.reversed = false,
    this.width = 5,
    this.step = 1,
    this.repeatWhileHeld = false,
  });
  final bool enabled;
  final EdgeAction action;
  final bool reversed;
  final int width;
  final int step;
  final bool repeatWhileHeld;
  EdgeConfig copyWith({
    bool? enabled,
    EdgeAction? action,
    bool? reversed,
    int? width,
    int? step,
    bool? repeatWhileHeld,
  }) => EdgeConfig(
    enabled: enabled ?? this.enabled,
    action: action ?? this.action,
    reversed: reversed ?? this.reversed,
    width: width ?? this.width,
    step: step ?? this.step,
    repeatWhileHeld: repeatWhileHeld ?? this.repeatWhileHeld,
  );
  List<int> get bytes => [
    enabled ? 1 : 0,
    action.index,
    reversed ? 1 : 0,
    width,
    step,
  ];
  String direction(EdgeSide side) {
    if (!enabled || action == EdgeAction.off) return '未启用';
    final positive = side == EdgeSide.left || side == EdgeSide.right
        ? '向上'
        : '向右';
    final negative = side == EdgeSide.left || side == EdgeSide.right
        ? '向下'
        : '向左';
    final a = reversed ? negative : positive;
    final b = reversed ? positive : negative;
    return switch (action) {
      EdgeAction.off => '未启用',
      EdgeAction.brightness => '$a 增加亮度 · $b 降低亮度',
      EdgeAction.volume => '$a 增加音量 · $b 降低音量',
      EdgeAction.verticalWheel => '$a 向上滚动 · $b 向下滚动',
      EdgeAction.horizontalWheel => '$a 向右滚动 · $b 向左滚动',
      EdgeAction.verticalArrowKeys => '$a 按 ↑ · $b 按 ↓',
      EdgeAction.horizontalArrowKeys => '$a 按 → · $b 按 ←',
    };
  }
}

class TouchpadConfig {
  TouchpadConfig({
    this.intensity = 63,
    this.pressLevel = 2,
    this.light = 80,
    this.medium = 100,
    this.strong = 130,
    this.wirelessLight = 60,
    this.wirelessMedium = 80,
    this.wirelessStrong = 100,
    this.rotation = 0,
    this.sleepEnabled = true,
    this.sleepMs = 180000,
    List<EdgeConfig>? edges,
    List<PointConfig>? points,
  }) : edges = List.unmodifiable(edges ?? List.filled(4, const EdgeConfig())),
       points = List.unmodifiable(
         points ?? List.filled(4, const PointConfig()),
       );
  static const byteLength = 32;
  static const v2ByteLength = 52;
  static const v3ByteLength = 52;
  final int intensity, pressLevel, light, medium, strong, rotation, sleepMs;
  final int wirelessLight, wirelessMedium, wirelessStrong;
  final bool sleepEnabled;
  final List<EdgeConfig> edges;
  final List<PointConfig> points;
  TouchpadConfig copyWith({
    int? intensity,
    int? pressLevel,
    int? light,
    int? medium,
    int? strong,
    int? wirelessLight,
    int? wirelessMedium,
    int? wirelessStrong,
    int? rotation,
    bool? sleepEnabled,
    int? sleepMs,
    List<EdgeConfig>? edges,
    List<PointConfig>? points,
  }) => TouchpadConfig(
    intensity: intensity ?? this.intensity,
    pressLevel: pressLevel ?? this.pressLevel,
    light: light ?? this.light,
    medium: medium ?? this.medium,
    strong: strong ?? this.strong,
    wirelessLight: wirelessLight ?? this.wirelessLight,
    wirelessMedium: wirelessMedium ?? this.wirelessMedium,
    wirelessStrong: wirelessStrong ?? this.wirelessStrong,
    rotation: rotation ?? this.rotation,
    sleepEnabled: sleepEnabled ?? this.sleepEnabled,
    sleepMs: sleepMs ?? this.sleepMs,
    edges: edges ?? this.edges,
    points: points ?? this.points,
  );
  String? get validationError {
    if (intensity < 0 || intensity > 100) return '触觉强度必须为 0～100';
    if (pressLevel < 1 || pressLevel > 3) return '按压档位必须为 1～3';
    if (light < 1 || strong > 255 || light > medium || medium > strong) {
      return '有线压力阈值必须满足 1 ≤ 轻 ≤ 中 ≤ 重 ≤ 255';
    }
    if (wirelessLight < 1 ||
        wirelessStrong > 100 ||
        wirelessLight > wirelessMedium ||
        wirelessMedium > wirelessStrong) {
      return '无线压力阈值必须满足 1 ≤ 轻 ≤ 中 ≤ 重 ≤ 100';
    }
    if (rotation < 0 || rotation > 3) return '无效旋转方向';
    if (sleepMs < 1000 || sleepMs > 3600000 || sleepMs % 1000 != 0) {
      return '休眠时间必须为 1～3600 整秒';
    }
    if (edges.length != 4) return '必须包含四条边缘';
    if (points.length != 4) return '必须包含四个单点';
    for (final position in PointPosition.values) {
      final p = points[position.index];
      if (p.radius < 1 || p.radius > 30 || p.step < 1 || p.step > 10) {
        return '${pointNames[position.index]}半径必须为 1～30%，步距必须为 1～10%';
      }
      if (p.enabled && p.action == PointAction.off) return '启用的单点必须选择功能';
    }
    for (final side in EdgeSide.values) {
      final e = edges[side.index];
      if (e.width < 1 ||
          e.width > side.maxWidthPercent ||
          e.step < 1 ||
          e.step > 10) {
        return '${edgeNames[side.index]}宽度必须为 1～${side.maxWidthPercent}%，步距必须为 1～10%';
      }
      if (e.enabled && e.action == EdgeAction.off) return '启用的边缘必须选择功能';
    }
    return null;
  }

  Uint8List encode({int version = 1}) {
    final error = validationError;
    if (error != null) throw FormatException(error);
    if (version < 1 || version > 3) throw const FormatException('配置结构版本不兼容');
    if (version < 3 && !hasDefaultWirelessThresholds) {
      throw const FormatException('无线阈值需要配置结构 v3');
    }
    if (version == 1 && points.any((p) => !p.isDefault)) {
      throw const FormatException('单点配置需要配置结构 v2');
    }
    final b = Uint8List(version == 1 ? byteLength : v2ByteLength);
    b.setRange(0, 8, [
      intensity,
      pressLevel,
      light,
      medium,
      strong,
      rotation,
      (sleepEnabled ? 1 : 0) | (pointToEdgeMask << 1),
      repeatMask | (pointRepeatMask << 4),
    ]);
    ByteData.sublistView(b).setUint32(8, sleepMs, Endian.little);
    for (var i = 0; i < 4; i++) {
      b.setRange(12 + i * 5, 17 + i * 5, edges[i].bytes);
      if (version == 2) b.setRange(32 + i * 5, 37 + i * 5, points[i].bytes);
      if (version == 3) {
        final p = points[i];
        b.setRange(32 + i * 4, 36 + i * 4, [
          p.enabled ? 1 : 0,
          p.action.index,
          p.radius,
          p.step,
        ]);
      }
    }
    if (version == 3) {
      b.setRange(48, 51, [wirelessLight, wirelessMedium, wirelessStrong]);
    }
    return b;
  }

  static TouchpadConfig decode(Uint8List b, {int version = 1}) {
    if (version < 1 || version > 3) throw const FormatException('配置结构版本不兼容');
    if (b.length != (version == 1 ? byteLength : v2ByteLength) ||
        (version == 1 && b[7] & 0xf0 != 0) ||
        b[6] > (version == 1 ? 1 : 31) ||
        (version == 3 && b[51] != 0)) {
      throw const FormatException('配置长度或保留字段错误');
    }
    final edges = <EdgeConfig>[];
    for (var i = 12; i < byteLength; i += 5) {
      if (b[i] > 1 || b[i + 1] >= EdgeAction.values.length || b[i + 2] > 1) {
        throw const FormatException('边缘枚举无效');
      }
      edges.add(
        EdgeConfig(
          enabled: b[i] == 1,
          action: EdgeAction.values[b[i + 1]],
          reversed: b[i + 2] == 1,
          width: b[i + 3],
          step: b[i + 4],
          repeatWhileHeld: b[7] & (1 << ((i - 12) ~/ 5)) != 0,
        ),
      );
    }
    final points = <PointConfig>[];
    if (version >= 2) {
      for (var n = 0; n < 4; n++) {
        final i = 32 + n * (version == 2 ? 5 : 4);
        final radiusOffset = version == 2 ? 3 : 2;
        if (b[i] > 1 ||
            b[i + 1] >= PointAction.values.length ||
            (version == 2 &&
                (b[i + 2] > 1 ||
                    (b[i + 2] == 1 && b[i + 1] >= PointAction.mute.index)))) {
          throw const FormatException('单点枚举无效');
        }
        points.add(
          PointConfig(
            enabled: b[i] == 1,
            action: version == 2 && b[i + 2] == 1
                ? PointAction.values[b[i + 1]].opposite
                : PointAction.values[b[i + 1]],
            radius: b[i + radiusOffset],
            step: b[i + radiusOffset + 1],
            repeatWhileHeld: b[7] & (1 << (n + 4)) != 0,
            allowPointToEdge: b[6] & (1 << (n + 1)) != 0,
          ),
        );
      }
    }
    final c = TouchpadConfig(
      intensity: b[0],
      pressLevel: b[1],
      light: b[2],
      medium: b[3],
      strong: b[4],
      wirelessLight: version == 3 ? b[48] : 60,
      wirelessMedium: version == 3 ? b[49] : 80,
      wirelessStrong: version == 3 ? b[50] : 100,
      rotation: b[5],
      sleepEnabled: b[6] & 1 != 0,
      sleepMs: ByteData.sublistView(b).getUint32(8, Endian.little),
      edges: edges,
      points: version >= 2 ? points : null,
    );
    final error = c.validationError;
    if (error != null) throw FormatException(error);
    return c;
  }

  int get repeatMask => edges.asMap().entries.fold(
    0,
    (mask, entry) => mask | (entry.value.repeatWhileHeld ? 1 << entry.key : 0),
  );
  bool get hasDefaultWirelessThresholds =>
      wirelessLight == 60 && wirelessMedium == 80 && wirelessStrong == 100;
  int get pointRepeatMask => points.asMap().entries.fold(
    0,
    (mask, entry) => mask | (entry.value.repeatWhileHeld ? 1 << entry.key : 0),
  );
  int get pointToEdgeMask => points.asMap().entries.fold(
    0,
    (mask, entry) => mask | (entry.value.allowPointToEdge ? 1 << entry.key : 0),
  );

  // An unsupported action keeps the entire edge mapping unchanged, so a
  // preview cannot accidentally enable the old device action. Repeat is
  // negotiated independently and does not change the five-byte edge layout.
  EdgeConfig _mergeEdge(EdgeConfig current, EdgeConfig draft, int mask) {
    if (draft.action.isArrowKey && mask & Capability.edgeArrowKeys == 0) {
      return current;
    }
    final base = mask & Capability.edges != 0 ? draft : current;
    return base.copyWith(
      repeatWhileHeld:
          mask & Capability.edges != 0 && mask & Capability.edgeRepeat != 0
          ? draft.repeatWhileHeld
          : current.repeatWhileHeld,
    );
  }

  // Preserve every unsupported device field when submitting a draft.
  TouchpadConfig merge(TouchpadConfig draft, int mask) => copyWith(
    intensity: mask & Capability.intensity != 0 ? draft.intensity : intensity,
    pressLevel: mask & Capability.pressLevel != 0
        ? draft.pressLevel
        : pressLevel,
    light: mask & Capability.thresholds != 0 ? draft.light : light,
    medium: mask & Capability.thresholds != 0 ? draft.medium : medium,
    strong: mask & Capability.thresholds != 0 ? draft.strong : strong,
    wirelessLight: mask & Capability.wirelessThresholds != 0
        ? draft.wirelessLight
        : wirelessLight,
    wirelessMedium: mask & Capability.wirelessThresholds != 0
        ? draft.wirelessMedium
        : wirelessMedium,
    wirelessStrong: mask & Capability.wirelessThresholds != 0
        ? draft.wirelessStrong
        : wirelessStrong,
    rotation: mask & Capability.rotation != 0 ? draft.rotation : rotation,
    sleepEnabled: mask & Capability.sleep != 0
        ? draft.sleepEnabled
        : sleepEnabled,
    sleepMs: mask & Capability.sleep != 0 ? draft.sleepMs : sleepMs,
    edges: List.generate(4, (i) => _mergeEdge(edges[i], draft.edges[i], mask)),
    points: List.generate(4, (i) {
      if (draft.points[i].action.isFunctionKey &&
          mask & Capability.pointFunctionKeys == 0) {
        return points[i];
      }
      final base = mask & Capability.points != 0 ? draft.points[i] : points[i];
      return base.copyWith(
        allowPointToEdge:
            mask & Capability.points != 0 &&
                mask & Capability.pointToEdge != 0 &&
                mask & Capability.edges != 0
            ? draft.points[i].allowPointToEdge
            : points[i].allowPointToEdge,
      );
    }),
  );
  bool same(TouchpadConfig other, [int mask = Capability.all]) {
    final a = [
      intensity,
      pressLevel,
      light,
      medium,
      strong,
      rotation,
      sleepEnabled,
      sleepMs,
      repeatMask,
      pointRepeatMask,
      pointToEdgeMask,
      ...points.expand((p) => p.bytes),
      ...edges.expand((e) => e.bytes),
      wirelessLight,
      wirelessMedium,
      wirelessStrong,
    ];
    final m = merge(other, mask);
    final b = [
      m.intensity,
      m.pressLevel,
      m.light,
      m.medium,
      m.strong,
      m.rotation,
      m.sleepEnabled,
      m.sleepMs,
      m.repeatMask,
      m.pointRepeatMask,
      m.pointToEdgeMask,
      ...m.points.expand((p) => p.bytes),
      ...m.edges.expand((e) => e.bytes),
      m.wirelessLight,
      m.wirelessMedium,
      m.wirelessStrong,
    ];
    return List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
  }
}
