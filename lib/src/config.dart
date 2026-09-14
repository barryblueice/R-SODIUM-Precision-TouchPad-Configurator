import 'dart:typed_data';

abstract final class Capability {
  static const intensity = 1;
  static const pressLevel = 2;
  static const thresholds = 4;
  static const rotation = 8;
  static const sleep = 16;
  static const edges = 32;
  static const all = 63;
}

enum EdgeSide {
  top,
  bottom,
  left,
  right;

  int get maxWidthPercent => this == top || this == bottom ? 30 : 15;
}

enum EdgeAction { off, brightness, volume, verticalWheel, horizontalWheel }

const edgeNames = ['上边缘', '下边缘', '左边缘', '右边缘'];
const actionNames = ['关闭', '亮度', '音量', '垂直滚轮', '水平滚轮'];
const rotationNames = ['横向', '纵向', '横向翻转', '纵向翻转'];

class EdgeConfig {
  const EdgeConfig({
    this.enabled = false,
    this.action = EdgeAction.off,
    this.reversed = false,
    this.width = 5,
    this.step = 2,
  });
  final bool enabled;
  final EdgeAction action;
  final bool reversed;
  final int width;
  final int step;
  EdgeConfig copyWith({
    bool? enabled,
    EdgeAction? action,
    bool? reversed,
    int? width,
    int? step,
  }) => EdgeConfig(
    enabled: enabled ?? this.enabled,
    action: action ?? this.action,
    reversed: reversed ?? this.reversed,
    width: width ?? this.width,
    step: step ?? this.step,
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
    this.rotation = 0,
    this.sleepEnabled = true,
    this.sleepMs = 180000,
    List<EdgeConfig>? edges,
  }) : edges = List.unmodifiable(edges ?? List.filled(4, const EdgeConfig()));
  static const byteLength = 32;
  final int intensity, pressLevel, light, medium, strong, rotation, sleepMs;
  final bool sleepEnabled;
  final List<EdgeConfig> edges;
  TouchpadConfig copyWith({
    int? intensity,
    int? pressLevel,
    int? light,
    int? medium,
    int? strong,
    int? rotation,
    bool? sleepEnabled,
    int? sleepMs,
    List<EdgeConfig>? edges,
  }) => TouchpadConfig(
    intensity: intensity ?? this.intensity,
    pressLevel: pressLevel ?? this.pressLevel,
    light: light ?? this.light,
    medium: medium ?? this.medium,
    strong: strong ?? this.strong,
    rotation: rotation ?? this.rotation,
    sleepEnabled: sleepEnabled ?? this.sleepEnabled,
    sleepMs: sleepMs ?? this.sleepMs,
    edges: edges ?? this.edges,
  );
  String? get validationError {
    if (intensity < 0 || intensity > 100) return '触觉强度必须为 0～100';
    if (pressLevel < 1 || pressLevel > 3) return '按压档位必须为 1～3';
    if (light < 1 || strong > 255 || light > medium || medium > strong) {
      return '压力阈值必须满足 1 ≤ 轻 ≤ 中 ≤ 重 ≤ 255';
    }
    if (rotation < 0 || rotation > 3) return '无效旋转方向';
    if (sleepMs < 1000 || sleepMs > 3600000 || sleepMs % 1000 != 0) {
      return '休眠时间必须为 1～3600 整秒';
    }
    if (edges.length != 4) return '必须包含四条边缘';
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

  Uint8List encode() {
    final error = validationError;
    if (error != null) throw FormatException(error);
    final b = Uint8List(byteLength);
    b.setRange(0, 8, [
      intensity,
      pressLevel,
      light,
      medium,
      strong,
      rotation,
      sleepEnabled ? 1 : 0,
      0,
    ]);
    ByteData.sublistView(b).setUint32(8, sleepMs, Endian.little);
    for (var i = 0; i < 4; i++) {
      b.setRange(12 + i * 5, 17 + i * 5, edges[i].bytes);
    }
    return b;
  }

  static TouchpadConfig decode(Uint8List b) {
    if (b.length != byteLength || b[7] != 0 || b[6] > 1) {
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
        ),
      );
    }
    final c = TouchpadConfig(
      intensity: b[0],
      pressLevel: b[1],
      light: b[2],
      medium: b[3],
      strong: b[4],
      rotation: b[5],
      sleepEnabled: b[6] == 1,
      sleepMs: ByteData.sublistView(b).getUint32(8, Endian.little),
      edges: edges,
    );
    final error = c.validationError;
    if (error != null) throw FormatException(error);
    return c;
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
    rotation: mask & Capability.rotation != 0 ? draft.rotation : rotation,
    sleepEnabled: mask & Capability.sleep != 0
        ? draft.sleepEnabled
        : sleepEnabled,
    sleepMs: mask & Capability.sleep != 0 ? draft.sleepMs : sleepMs,
    edges: mask & Capability.edges != 0 ? draft.edges : edges,
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
      ...edges.expand((e) => e.bytes),
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
      ...m.edges.expand((e) => e.bytes),
    ];
    return List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
  }
}
