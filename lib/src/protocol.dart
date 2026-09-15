import 'dart:typed_data';

abstract final class Command {
  static const info = 1;
  static const read = 2;
  static const write = 3;
}

abstract final class Status {
  static const ok = 0;
  static const unsupported = 1;
  static const version = 2;
  static const length = 3;
  static const invalid = 4;
  static const busy = 5;
  static const storage = 6;
  static const reconnect = 7;
  static const labels = [
    '成功',
    '固件不支持',
    '协议版本不兼容',
    '报文长度错误',
    '参数无效',
    '设备忙',
    '保存失败',
    '已保存，等待设备重新枚举',
  ];
}

class ProtocolException implements Exception {
  ProtocolException(this.message, [this.status]);
  final String message;
  final int? status;
  @override
  String toString() => message;
}

class Packet {
  Packet(this.command, this.sequence, {this.status = 0, Uint8List? payload})
    : payload = payload ?? Uint8List(0);
  final int command, sequence, status;
  final Uint8List payload;
  Uint8List encode() {
    if (payload.length > 52 ||
        command < 1 ||
        command > 3 ||
        sequence < 1 ||
        sequence > 65535 ||
        status < 0 ||
        status > 7) {
      throw const FormatException('RSTP 报文参数无效');
    }
    final b = Uint8List(64);
    b.setRange(0, 6, [0x52, 0x53, 0x54, 0x50, 1, command]);
    final d = ByteData.sublistView(b);
    d.setUint16(6, sequence, Endian.little);
    d.setUint16(8, payload.length, Endian.little);
    d.setUint16(10, status, Endian.little);
    b.setRange(12, 12 + payload.length, payload);
    return b;
  }

  static Packet decode(Uint8List b) {
    if (b.length != 64) throw const FormatException('RSTP 必须为 64 字节');
    if (b[0] != 0x52 || b[1] != 0x53 || b[2] != 0x54 || b[3] != 0x50) {
      throw const FormatException('RSTP 魔数错误');
    }
    if (b[4] != 1) throw ProtocolException('协议版本不兼容：${b[4]}', Status.version);
    final d = ByteData.sublistView(b);
    final length = d.getUint16(8, Endian.little);
    final status = d.getUint16(10, Endian.little);
    final seq = d.getUint16(6, Endian.little);
    if (length > 52 ||
        status > 7 ||
        b[5] < 1 ||
        b[5] > 3 ||
        seq == 0 ||
        b.skip(12 + length).any((v) => v != 0)) {
      throw const FormatException('RSTP 长度、枚举或填充错误');
    }
    return Packet(
      b[5],
      seq,
      status: status,
      payload: Uint8List.fromList(b.sublist(12, 12 + length)),
    );
  }
}

class DeviceInfo {
  const DeviceInfo(this.capabilities, this.firmware, {this.configVersion = 1});
  final int capabilities;
  final String firmware;
  final int configVersion;
  static DeviceInfo decode(Uint8List b) {
    if (b.length != 12 || b[10] < 1 || b[10] > 3 || b[11] != 0) {
      throw const FormatException('设备信息或配置结构版本不兼容');
    }
    final d = ByteData.sublistView(b);
    return DeviceInfo(
      d.getUint32(0, Endian.little),
      '${d.getUint16(4, Endian.little)}.${d.getUint16(6, Endian.little)}.${d.getUint16(8, Endian.little)}',
      configVersion: b[10],
    );
  }
}
