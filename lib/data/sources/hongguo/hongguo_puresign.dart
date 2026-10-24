/// 红果 App 接口六个签名头的纯 Dart 实现。
///
/// 逐函数移植自参考实现 0.1.24 的 provider_hongguo_puresign.go（其上游为
/// sunnysky123/hongguo-web 的 pure-sign.js）。字节级对齐要求：任何一处位
/// 运算语义偏移都会导致 x-medusa 校验失败、服务端返回 HTTP 200 空正文。
///
/// 三个必须守住的原实现语义（Dart int 是 64 位有符号，统一用掩码承载）：
///   1. Java int 为 32 位有符号，溢出按补码回绕 —— 32 位运算后 `& 0xFFFFFFFF`。
///   2. JS 的 |0 / >> / >>> 分别对应 int32 转换、算术右移、逻辑右移。
///   3. JS 越界读 Buffer 返回 undefined，位运算中视作 0 —— 见 [_aesSrc]。
///
/// 可测试性：所有核心函数接受显式随机量（与上游 `_With` 后缀的变体一致），
/// 公开入口 [signHongguoAppRequest] 注入 `Random.secure()`。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pointycastle/digests/md5.dart';
import 'package:pointycastle/digests/sm3.dart';

// ==================== 基础位运算 ====================

int _randUint32(Random rng) {
  final buffer = Uint8List(4);
  for (var i = 0; i < 4; i++) {
    buffer[i] = rng.nextInt(256);
  }
  return ByteData.sublistView(buffer).getUint32(0, Endian.little);
}

int _randInt(Random rng, int n) {
  if (n <= 0) return 0;
  final buffer = Uint8List(8);
  for (var i = 0; i < 8; i++) {
    buffer[i] = rng.nextInt(256);
  }
  return (ByteData.sublistView(buffer).getUint64(0, Endian.little) % n).toInt();
}

int _rotl32(int x, int n) {
  final k = n & 31;
  if (k == 0) return x & 0xFFFFFFFF;
  return ((x << k) | (x >>> (32 - k))) & 0xFFFFFFFF;
}

int _rotr32(int x, int n) {
  final k = n & 31;
  if (k == 0) return x & 0xFFFFFFFF;
  return ((x >>> k) | (x << (32 - k))) & 0xFFFFFFFF;
}

int _rotl8(int x) => ((x << 4) | (x >> 4)) & 0xFF;

int _rotl8x3(int x) => ((x << 3) | (x >> 5)) & 0xFF;

int _reverse8(int v) {
  var r = 0;
  for (var i = 0; i < 8; i++) {
    r = (r << 1) | ((v >> i) & 1);
  }
  return r;
}

Uint8List _le32(int v) {
  final out = Uint8List(4);
  ByteData.sublistView(out).setUint32(0, v & 0xFFFFFFFF, Endian.little);
  return out;
}

Uint8List _be32(int v) {
  final out = Uint8List(4);
  ByteData.sublistView(out).setUint32(0, v & 0xFFFFFFFF, Endian.big);
  return out;
}

int _readLe32(Uint8List b, int off) =>
    ByteData.sublistView(b).getUint32(off, Endian.little);

int _readBe32(Uint8List b, int off) =>
    ByteData.sublistView(b).getUint32(off, Endian.big);

int _readU64Le(Uint8List b, int off) =>
    ByteData.sublistView(b).getUint64(off, Endian.little);

void _putU64Le(Uint8List b, int off, int v) =>
    ByteData.sublistView(b).setUint64(off, v, Endian.little);

// 对应 Java 的 Long.rotateRight。
int _rotr64(int x, int n) {
  final k = n & 63;
  if (k == 0) return x;
  return (x >>> k) | (x << (64 - k));
}

String _hex(Uint8List data) =>
    data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String text) {
  final clean = text.trim();
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _b64(Uint8List data) => base64.encode(data);

Uint8List _md5(List<int> data) => MD5Digest().process(Uint8List.fromList(data));

// ==================== SM3（GB/T 32905，pointycastle 实现） ====================

Uint8List _sm3(List<int> data) =>
    SM3Digest().process(Uint8List.fromList(data));

// ==================== protobuf 手写编码 ====================

List<int> _varint(int value) {
  var current = value;
  final out = <int>[];
  while (current > 127) {
    out.add((current & 127) | 128);
    current = current >>> 7;
  }
  out.add(current & 0xff);
  return out;
}

int _zigzag(int value) => value < 0 ? (-value) * 2 - 1 : value * 2;

class _PField {
  const _PField(this.tag, this.value, [this.type = 'string']);
  final int tag;
  final Object? value;
  final String type;
}

List<int> _protoField(_PField field) {
  final value = field.value;
  if (value == null) return const [];
  // 与 JS 的 proto() 一致：未显式声明类型时按 string 处理。
  final type = field.type;
  switch (type) {
    case 'string':
      final text = value as String;
      if (text.isEmpty) return const [];
      final body = utf8.encode(text);
      return [..._varint(field.tag << 3 | 2), ..._varint(body.length), ...body];
    case 'bytes':
    case 'message':
      final body = value as List<int>;
      return [..._varint(field.tag << 3 | 2), ..._varint(body.length), ...body];
    case 'float':
      final body = Uint8List(4);
      ByteData.sublistView(body)
          .setUint32(0, (value as num).toDouble().f32bits, Endian.little);
      return [..._varint(field.tag << 3 | 5), ...body];
    default:
      final number = value is int ? value : 0;
      final head = _varint(field.tag << 3);
      if (type == 'sint') return [...head, ..._varint(_zigzag(number))];
      return [...head, ..._varint(number)];
  }
}

extension on double {
  int get f32bits {
    final view = ByteData(4)..setFloat32(0, this);
    return view.getUint32(0);
  }
}

Uint8List _proto(List<_PField> fields) =>
    Uint8List.fromList([for (final field in fields) ..._protoField(field)]);

// ==================== hashF13 家族 ====================

/// 按字节奇偶交替混合的 32 位状态机。
int _getIv(int iv, Uint8List data) {
  var value = iv;
  for (var i = 0; i < data.length; i++) {
    final current = data[i];
    if (i & 1 == 0) {
      value = _mask32(value >> 4 ^ value ^ value << 6 ^ current);
    } else {
      value = _mask32(~_mask32(value >> 7 ^ value ^ (current | value << 12)));
    }
  }
  return value;
}

int _mask32(int x) => x & 0xFFFFFFFF;

/// 取前 12 字节的固定轮混淆，末位或 4 再异或 0x1000000。
int _sumMd5(Uint8List data) {
  var check = 0x20220420;
  for (var i = 0; i < 12; i++) {
    final temp = i & 1 == 0 ? _mask32(check >> 3 ^ check) : _mask32(check >> 5 ^ check);
    if (i & 1 == 0) {
      check = _mask32(data[i] ^ check << 7);
    } else {
      check = _mask32(data[i] | check << 11);
    }
    if (i & 1 != 0) check = _mask32(~check);
    check ^= temp;
  }
  return (check | 4) ^ 0x1000000;
}

const List<int> _branch2SV = [
  0xa7aefe20, 0x7149f1d6, 0x47e4ca07, 0xe9b58f67, 0x93b924de, 0xc614d0f5,
  0x38afe0ef, 0xb2bbad73, 0xe24444c3, 0x9d3aec9b, 0xdf7b37e4, 0xd8b16d40,
  0xf8ac31b8, 0x76b9a90b, 0x31d833ee, 0x953fce64, 0x353595a4, 0x4609c13b,
  0x36925008, 0x8c6d0925, 0x5df5c177, 0x1cfbf52b, 0x8a4fa7f0, 0x114ca35e,
  0x8193f984, 0x7a7a8733, 0x316ab4d5, 0x3c20cfc9, 0xa6d84453, 0x3a18500c,
  0x798ec47a, 0x97a76b28, 0x66c4ff96, 0x51716443, 0x0dd2fc3b, 0xb5696da7,
  0xbbeb3ac5, 0x5c53d204, 0xd32608ce, 0x7279b9ec, 0xf4188ecf, 0xf7d793db,
  0x332cc491, 0xab76ae15, 0x9bebe727, 0x18a01384, 0x5be9f8a7, 0x5f90a754,
  0x39b663c0, 0x36673c83, 0x7c92f514, 0x9d7d94d7, 0xe2e8d9aa, 0x5f7e9ea9,
  0x7abd4551, 0x569e05da, 0x40a25632, 0x3df5a9a5, 0xbab37d80, 0x454286dc,
  0x3f5d4e78, 0x03d7b75d, 0xb1fe4af7, 0xa5ab26a3,
];

final Uint8List _branch2Orders = _unhex(
  '0f0704000908030a060b050d0e010c02'
  '0f05080c0009020103070e060b0a0d04'
  '060500070c000a04080f010b0d09020e'
  '060b02050403080101070a000d0c090e'
  '0d070e0f0b0208030c0509010004060a'
  '0d0902060f0b0a040807000c0503010e'
  '0c090f07060f030e020d0405010b0a00'
  '0c050a090e0802040407030f01060b00'
  '0b0f0408020a0700090d06010e03050c'
  '0b060a0508020c03070f0e090d000104'
  '0906080f050800040a0b030d01020c0e'
  '090d0c0604070a03030f00080105020e'
  '01000d0f090a0b0e0402080703060c05'
  '01080a0c0f0905060b000304020e070d'
  '04080f000c0f0e0d0a01060207090503'
  '040205080d0b0a0606000e0f070c0903'
  '0a08040f000b01060d0c0709030e0502'
  '0a070b050f00020e0108030d0c060904'
  '0d070f08050f06040b0a0e0c09000203'
  '0d0c020704010b0e0e08060f09050003',
);

int _md5V3Step(
  int kind,
  int a,
  int b,
  int c,
  int d,
  int m,
  int shift,
  int constant,
) {
  int f;
  switch (kind) {
    case 0:
      f = (b & c) | (~b & d);
    case 1:
      f = (b & d) | (c & ~d);
    case 2:
      f = b ^ c ^ d;
    default:
      f = c ^ (b | ~d);
  }
  return _mask32(b + _rotl32(_mask32(a + f + m + constant), shift));
}

const List<int> _md5Shifts0 = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22];
const List<int> _md5Shifts1 = [5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20];
const List<int> _md5Shifts2 = [4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23];
const List<int> _md5Shifts3 = [6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];

/// MD5 变体：固定轮常量表 + 消息编排表驱动的 64 轮压缩。
Uint8List _md5SumV3(Uint8List message, int countV2, Uint8List orders, int countV1) {
  final sv = List<int>.generate(
    64,
    (i) => _rotr32(_branch2SV[i], countV1),
  );
  final start = [
    _rotr32(0x79e0f2fb, countV2),
    _rotr32(0xc8b52570, countV2),
    _rotr32(0xebc2f8cd, countV2),
    _rotr32(0x7c104d93, countV2),
  ];
  final endCount = (countV2 + 6) & 255;
  final end = [
    _rotr32(0x19be4866, endCount),
    _rotr32(0xe85986b4, endCount),
    _rotr32(0xe19b326e, endCount),
    _rotr32(0x71d1d7d4, endCount),
  ];
  final m = List<int>.generate(16, (i) => _readLe32(message, i * 4));
  var a = start[0], b = start[1], c = start[2], d = start[3];

  final shiftTables = [_md5Shifts0, _md5Shifts1, _md5Shifts2, _md5Shifts3];
  for (var kind = 0; kind < 4; kind++) {
    final shifts = shiftTables[kind];
    final offset = kind * 16;
    for (var i = 0; i < 16; i++) {
      final phase = i & 3;
      final order = offset + i < orders.length ? orders[offset + i] : 0;
      final mm = m[order & 0xff];
      final cc = sv[offset + i];
      switch (phase) {
        case 0:
          a = _md5V3Step(kind, a, b, c, d, mm, shifts[i], cc);
        case 1:
          d = _md5V3Step(kind, d, a, b, c, mm, shifts[i], cc);
        case 2:
          c = _md5V3Step(kind, c, d, a, b, mm, shifts[i], cc);
        default:
          b = _md5V3Step(kind, b, c, d, a, mm, shifts[i], cc);
      }
    }
  }
  final ret = Uint8List(16);
  final view = ByteData.sublistView(ret);
  view.setUint32(0, _mask32((start[0] + a) ^ end[0]), Endian.little);
  view.setUint32(4, _mask32((start[1] + b) ^ end[1]), Endian.little);
  view.setUint32(8, _mask32((start[2] + c) ^ end[2]), Endian.little);
  view.setUint32(12, _mask32((start[3] + d) ^ end[3]), Endian.little);
  return Uint8List.fromList([...ret, ..._le32(_sumMd5(ret))]);
}

const List<int> _branch2N1 = [0x8980f29b, 0xeb549c7f, 0xb08726db, 0xd40cb5e6, 0xe8f559e4];
const List<int> _branch2Seed = [0x84, 0x96, 0x77, 0x9d, 0xd4, 0x15, 0x0b, 0xf8];

Uint8List _branch2F13(int iv, Uint8List querySm3, Uint8List bodyMd5,
    Uint8List tsBytes, int khronos) {
  final v = (iv & 13) * 86;
  var ivV0 = ((v >> 15) & 255) + ((v >> 8) & 255);
  if (ivV0 >= _branch2N1.length) {
    ivV0 = _branch2N1.length - 1;
  }
  final n1 = _branch2N1[ivV0];
  final countV1 = (n1 + khronos + 1) & 255;
  final countV2 = _mask32(n1 + khronos);
  final shift = (countV2 + 5) & 7;
  final pad = Uint8List(8);
  for (var i = 0; i < 8; i++) {
    pad[i] = ((_branch2Seed[i] | (_branch2Seed[i] << 8)) >> shift) & 0xFF;
  }
  final input = Uint8List.fromList([
    ...querySm3,
    ...bodyMd5,
    ...tsBytes,
    ...pad,
    ..._unhex('a0010000'),
  ]);

  var from = ivV0 << 6;
  var to = (ivV0 + 1) << 6;
  if (from > _branch2Orders.length) from = _branch2Orders.length;
  if (to > _branch2Orders.length) to = _branch2Orders.length;
  final orders = _branch2Orders.sublist(from, to);
  return _md5SumV3(input, countV2, orders, countV1);
}

const List<int> _f13IV1 = [0xc4a78580, 0xb3c0fd39, 0xc58c5686, 0xc9aa3ba7, 0xf5a7adf2, 0x963c2ed1];

const List<int> _f13TT02 = [
  0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be,
  0xb41ad638, 0x34180eb8, 0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51,
  0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288, 0x2c077f0a, 0xda0dcad0,
  0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
  0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6,
  0x736f8650, 0x6560306c, 0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032,
  0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3, 0xe1d0b866, 0xbaa3dcb8,
  0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
  0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2,
  0xab0b3b86, 0x3d5dfb14, 0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1,
  0x6ca86f6e, 0x0284ba7, 0x08387cfa, 0x5fb37586,
];

const List<List<int>> _f13Chosen = [
  [101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3],
  [96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4],
  [96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5],
  [99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6],
  [96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4],
  [100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5],
];

const List<int> _f13InitRaw = [
  0x7aba4fc8,
  0x67166507,
  0x6403fa00,
  0x340f512f,
  984304912,
  3005047866,
  2874125293,
  2152413264,
];

/// 按 iv 低 4 位选分支（0 主分支、1 服务端不接受、2 备用变体）。
Uint8List _hashF13(
  Uint8List querySm3,
  Uint8List bodyMd5,
  Uint8List tsBytes,
  int khronos,
) {
  final iv = _getIv(_getIv(_getIv(0x20230928, querySm3), bodyMd5), tsBytes);
  final low = iv & 15;
  final ivV0 = (low * 171) >> 9;
  final branch = low - ivV0 * 3;
  if (branch == 2) {
    return _branch2F13(iv, querySm3, bodyMd5, tsBytes, khronos);
  }
  if (branch != 0) {
    final sum = _sumMd5(Uint8List.fromList([...querySm3, ...bodyMd5]));
    final merged = <int>[...querySm3.sublist(0, 16), ...bodyMd5];
    return Uint8List.fromList([...merged, ..._le32(sum)]);
  }

  final ivV1 = _f13IV1[ivV0];
  final countV1 = (ivV1 + khronos + 1) & 255;
  final countV2 = _mask32(ivV1 + khronos);
  final tt = List<int>.generate(64, (i) => _rotr32(_f13TT02[i], countV1));
  final n0 = (countV2 + 2) & 7;
  const seed = [0xfa, 0x45, 0x61, 0xd7];
  final pad = Uint8List(4);
  for (var i = 0; i < 4; i++) {
    pad[i] = ((seed[i] | (seed[i] << 8)) >> n0) & 0xFF;
  }
  final data = Uint8List.fromList([
    ...querySm3,
    ...bodyMd5,
    ...tsBytes,
    ...pad,
    ..._unhex('00000000000001a0'),
  ]);

  final di = <int>[
    for (var i = 0; i + 3 < data.length; i += 4) _readBe32(data, i),
  ];
  final di0 = di[0];
  for (var i = 0; i < 112; i++) {
    final di1 = di[i + 1];
    final di14 = di[i + 14];
    // Dart 的 ^ 优先级低于 >>，与 Go 相反，必须显式括号。
    final r1 = _rotl32(di1, 14) ^ _rotl32(di1, 25) ^ (di1 >> 3);
    final r2 = _rotl32(di14, 13) ^ _rotl32(di14, 15) ^ (di14 >> 10);
    di.add(_mask32(di0 + di[i + 9] + r1 + r2));
  }

  final init = List<int>.generate(
    8,
    (i) => _rotr32(_f13InitRaw[i], countV2 & 31),
  );
  final chosen = _f13Chosen[ivV0];
  final d = List<int>.from(init);
  for (var i = 0; i < chosen[0]; i++) {
    final base = _mask32(ivV1 + i);
    final n0v = di[base & 127];
    final n1 = _mask32(((d[chosen[3]] ^ d[chosen[4]]) & d[chosen[1]]) ^ d[chosen[3]]);
    final n2 = _rotl32(d[chosen[1]], 26) ^ _rotl32(d[chosen[1]], 21) ^ _rotl32(d[chosen[1]], 7);
    final n4 = _mask32(n0v + n1 + n2 + tt[base & 63] + d[chosen[5]]);
    final n5 = _rotl32(d[chosen[2]], 30) ^ _rotl32(d[chosen[2]], 19) ^ _rotl32(d[chosen[2]], 10);
    final n6 = (d[chosen[2]] & d[chosen[6]]) | ((d[chosen[2]] | d[chosen[6]]) & d[chosen[7]]);
    final n7 = _mask32(n5 + n6);
    final old = d[chosen[9]];
    final last = d[7];
    for (var k = 7; k >= 1; k--) {
      d[k] = d[k - 1];
    }
    d[0] = last;
    d[chosen[10]] = _mask32(n7 + n4);
    d[chosen[8]] = _mask32(old + n4);
  }
  final ret = Uint8List(32);
  final view = ByteData.sublistView(ret);
  for (var i = 0; i < 8; i++) {
    view.setUint32(i * 4, _mask32(d[i] + init[i]), Endian.big);
  }
  for (var i = 0; i < 16; i++) {
    ret[i] ^= ret[i + 16];
  }
  final head = Uint8List.sublistView(ret, 0, 16);
  return Uint8List.fromList([...head, ..._le32(_sumMd5(head))]);
}

// ==================== x-gorgon ====================

/// RC4 变体（KSA 只赋值不交换，PRGA 异或 s[(y+y)&255]）。
Uint8List _rc4Gorgon(Uint8List data, Uint8List key) {
  final s = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    s[i] = i;
  }
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + s[i] + key[i % key.length]) & 255;
    s[i] = s[j];
  }
  final out = Uint8List(data.length);
  var i = 0, j2 = 0;
  for (var k = 0; k < data.length; k++) {
    i++;
    final x = s[i];
    j2 += x;
    final y = s[j2 & 255];
    s[i] = y;
    out[k] = data[k] ^ s[(y + y) & 255];
  }
  return out;
}

String _xGorgon(String query, Uint8List? body, int timestamp, int random) {
  final queryHash = _md5(utf8.encode(query));
  final input = <int>[
    ...queryHash.sublist(0, 4),
    if (body != null && body.isNotEmpty)
      ..._md5(body).sublist(0, 4)
    else
      ...const [0, 0, 0, 0],
    ...const [0, 0, 0, 0],
    ..._le32(67503104),
    ..._be32(timestamp),
  ];
  final key = Uint8List.fromList([
    0x4a,
    0x40,
    0x16,
    (random >> 8) & 255,
    0x47,
    0x6c,
    0x01,
    random & 255,
  ]);
  final out = _rc4Gorgon(Uint8List.fromList(input), key);
  for (var i = 0; i < out.length; i++) {
    final value = _rotl8(out[i]);
    var next = out[0];
    if (i + 1 < out.length) next = out[i + 1];
    out[i] = (~_reverse8(next ^ value)) & 0xFF ^ 20;
  }
  final signature = <int>[
    ..._unhex('8404'),
    random & 255,
    (random >> 8) & 255,
    0x40,
    0x01,
  ];
  return _hex(Uint8List.fromList([...signature, ...out]));
}

// ==================== AesV3（medusa 内置的 AES 变体） ====================

const String _aesSBoxB64 =
    '+n0Ia5xZs0sEXznQOEqRmQBnpiCf9U2Ccybu3xhmgzOAAxn72f6uqqmwUsYL83klTni0NqxdGieeiNu9PGPsSRXBMB/cuFbUbM3KCUPINaPvHvSW0vwOcnuUhNHqRVpiAj/TEoE0K91+5ijypUYTATsh9mE3KSoN7Yyvv51cuyR2D3XkU4nhmI2xmmVwT1RMWKtub4sjxAcRDLrPoKSO2AU9FLLadMPX577Wf95IFj6FkKFVt3dCIsmGUC4X+WQxLJvxbRxEaOPpqJOXyzJX6+Vxaq3AzMfF/WAdoi1Hp+JRaV56zgpBtpWP97mH4DoGEIq1+FvV8LyS/3wvwugbQOwb2r26mJEMsiuDQTRn+wrYdrVGBVlhI3WQhyrjUBVMrLF5667llUcEaPCGPVGLD8qO5LlO8hKCvA7V9+8oJc9bXelqVQLhM76T5/WtnT45JKji+hdX0HoNCDDWuKON/QeaxB5uImSX0h2wv0VmP2zd2yeApxHcpsVS+MC2yFwAc2B7oBkTqsk1SEvTpM2fmfMQREBUfin0Bh+iq6EvPPavhWI2IX9e3yAas7Tm/3KEj2UmlFp36kN4x0rMLBRrxuh0U/zUHM4xcAMYjJY4MonxOl/X+alpt2M3WMI7w3HLnpIBigtNiJu7T21v4P6lSd5WFgntnMEt7oF92XzRLkJbTcGmXepE/UVOG6E/0YnhfS+q26utWcuxzpooyeD2cDlK1/8w9d28VzsRjbLuALbmGlp8+d7EzS6Au7lMpZ+ECMZvQmzwJ+eLOpxR+2chdUExp8ogQyq3v9l68rX4jCwjg0+PYKAEEzcU4wHFY2ZcdIHfWL1okD3SszT0GZMyKdZJrg1L2AeerB4tC0C4crp2EHGo5FYdSP7lwkeR2ocmnR+Ia8CYviUJlzOjhRZef9xuVOn3qcjow3fQgivsAmKKkg4+sA8F8/GWeDiGNhg8JM8KtFPMYWWkx5TVFX5t73kiNRJqjlIGVXtGZFCV4gzt0xcDopuZ6xz8r9Rzafpf9ywev8jh8592gHFIqpStZPuJxmDDMrNN0uBE3V+oscdoIzTJbRJ/t+sVvqnReJOgDJKk10fjisJwqyZBmnmn2BSFj8BvVtCMEbkuPOKdzw7eA11GPs04Qw8zWtkaZWwiO/wwpojqN6K0jY5RnNZA7vn4hPSul+nKCkVnVwQvg1zVxcSCtqORmB9KrJaBbssbCQivGJVJfVTt+hYxOtq4ZvWl8f4QAQZ0zGPffCgl9s6yT4vlvIdpu4YhBwA25wtQWZsc6GJYGWHyvSdeuh3mmUI9DSq13Fsp8C1MU3tqc04/df9LoTUXVXI5INOw/e8C7Hd+5CvbkMEFnnrUUmskEw==';

Uint8List? _aesSBoxCache;
Uint8List _aesSBox() =>
    _aesSBoxCache ??= base64.decode(_aesSBoxB64);

/// JS 越界读返回 undefined，位运算中等价于 0。
int _aesSrc(Uint8List data, int idx) {
  if (idx >= 0 && idx < data.length) return data[idx];
  return 0;
}

void _aesPut(Uint8List out, int idx, int value) {
  if (idx >= 0 && idx < out.length) out[idx] = value;
}

// （4x4 矩阵按行优先展平，与 Go 的 hgAESMatrix/hgAESFlat 一致。）

int _aesXt(int x) {
  if (x & 128 != 0) return ((x << 1) ^ 0x1b) & 0xFF;
  return (x << 1) & 0xFF;
}

void _aesMix(List<List<int>> rows) {
  for (var i = 0; i < 4; i++) {
    final t = rows[0][i] ^ rows[1][i] ^ rows[2][i] ^ rows[3][i];
    final u = rows[0][i];
    rows[0][i] ^= t ^ _aesXt(rows[0][i] ^ rows[1][i]);
    rows[1][i] ^= t ^ _aesXt(rows[1][i] ^ rows[2][i]);
    rows[2][i] ^= t ^ _aesXt(rows[2][i] ^ rows[3][i]);
    rows[3][i] ^= t ^ _aesXt(rows[3][i] ^ u);
  }
}

const List<List<int>> _aesCon2 = [
  [1, 0, 2, 3],
  [2, 0, 3, 1],
  [0, 1, 3, 2],
  [1, 0, 2, 3],
];

const List<List<int>> _aesOrder = [
  [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
  [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
  [0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15],
  [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
];

const List<int> _aesInit = [0xca025ddc, 0x823dc546, 0xc9420583, 0xc298225f];

class _AesV3 {
  _AesV3._(this._box, this._con2, this._order) {
    _keys = List.generate(12, (_) => List.filled(4, 0));
  }

  factory _AesV3(Uint8List key, int khronos) {
    final wordSize = khronos & 3;
    final sbox = _aesSBox();
    final aes = _AesV3._(
      Uint8List.sublistView(sbox, wordSize * 256, (wordSize + 1) * 256),
      _aesCon2[wordSize],
      _aesOrder[wordSize],
    );
    final init = _aesInit[wordSize];
    final initial = Uint8List(16);
    for (var i = 0; i < 4; i++) {
      ByteData.sublistView(initial).setUint32(i * 4, init, Endian.little);
    }
    final expanded = List<int>.filled(48, 0);
    for (var i = 0; i < 16; i++) {
      expanded[i] = initial[i] ^ key[i % key.length];
    }
    var rounds = 8;
    for (var i = 4; i < 12; i++) {
      final at = 4 * (i - 1);
      var a = expanded[at] & 0xFF;
      var b = expanded[at + 1] & 0xFF;
      var c = expanded[at + 2] & 0xFF;
      var d = expanded[at + 3] & 0xFF;
      if (i & 3 == 0) {
        final t = ((init >> (rounds & 24)) ^ aes._box[b]) & 0xFF;
        b = aes._box[c];
        c = aes._box[d];
        d = aes._box[a];
        a = t;
      }
      rounds += 2;
      expanded[at + 4] = a ^ expanded[at - 12];
      expanded[at + 5] = b ^ expanded[at - 11];
      expanded[at + 6] = c ^ expanded[at - 10];
      expanded[at + 7] = d ^ expanded[at - 9];
    }
    for (var i = 0; i < 12; i++) {
      for (var j = 0; j < 4; j++) {
        aes._keys[i][j] = expanded[i * 4 + j] & 0xFF;
      }
    }
    return aes;
  }

  final Uint8List _box;
  final List<int> _con2;
  final List<int> _order;
  late final List<List<int>> _keys;

  List<List<int>> _matrix(Uint8List bytes) => [
    for (var i = 0; i < 4; i++)
      [bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], bytes[i * 4 + 3]],
  ];

  Uint8List _flat(List<List<int>> rows) =>
      Uint8List.fromList([for (var i = 0; i < 4; i++) ...rows[i]]);

  void _add(List<List<int>> rows, List<List<int>> key) {
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        rows[i][j] ^= key[i][j];
      }
    }
  }

  void _addCon(List<List<int>> rows, List<List<int>> ks) {
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        rows[i][j] ^= ks[i][_con2[j]];
      }
    }
  }

  void _sub(List<List<int>> rows) {
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        rows[i][j] = _box[rows[i][j]];
      }
    }
    final old = [for (final row in rows) List<int>.from(row)];
    for (var i = 0; i < 4; i++) {
      rows[i] = old[_con2[i]];
    }
  }

  void _shift(List<List<int>> rows) {
    final flat = _flat(rows);
    final next = List.generate(4, (_) => List.filled(4, 0));
    for (var i = 0; i < 16; i++) {
      next[i ~/ 4][i % 4] = flat[_order[i]];
    }
    for (var i = 0; i < 4; i++) {
      rows[i] = next[i];
    }
  }

  void _shiftCon(List<List<int>> rows) {
    final old = [for (final row in rows) List<int>.from(row)];
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        rows[i][j] = old[i][_con2[j]];
      }
    }
  }

  List<List<int>> _subKeys(int from) => [
    for (var i = 0; i < 4; i++) List<int>.from(_keys[from + i]),
  ];

  Uint8List _block(Uint8List value) {
    final rows = _matrix(value);
    _addCon(rows, _subKeys(0));
    for (var i = 1; i < 3; i++) {
      _sub(rows);
      _shift(rows);
      if (i == 1) {
        _shiftCon(rows);
        _aesMix(rows);
      }
      _addCon(rows, _subKeys(i * 4));
    }
    _add(rows, _subKeys(4));
    return _flat(rows);
  }

  /// 明文具化到 32 字节 -> CBC 两轮 -> 按 key 逐位回填源数据，末尾缀 key 末字节。
  Uint8List encrypt(Uint8List data, Uint8List iv) {
    final plaintext = Uint8List(32);
    for (var i = 0; i < 31; i++) {
      final at = i * 8;
      var n = (_aesSrc(data, at) >> 4) & 2;
      n |= _aesSrc(data, at + 1) & 64;
      n |= (_aesSrc(data, at + 2) >> 2) & 1;
      n |= (_aesSrc(data, at + 3) << 3) & 128;
      n |= (_aesSrc(data, at + 4) >> 1) & 4;
      n |= (_aesSrc(data, at + 5) << 3) & 16;
      n |= (_aesSrc(data, at + 6) << 5) & 32;
      n |= (_aesSrc(data, at + 7) >> 4) & 8;
      plaintext[i] = n;
    }
    plaintext[31] = 1;

    final key = <int>[];
    var previous = Uint8List.fromList(iv);
    for (var i = 0; i < plaintext.length; i += 16) {
      final block = Uint8List(16);
      for (var j = 0; j < 16; j++) {
        block[j] = plaintext[i + j] ^ previous[j];
      }
      final value = _block(block);
      key.addAll(value);
      previous = value;
    }
    final out = Uint8List.fromList(data);
    for (var i = 0; i < 31; i++) {
      final at = i * 8;
      final k = key[i];
      _aesPut(out, at, (_aesSrc(out, at) & 0xdf) | ((k << 4) & 32));
      _aesPut(out, at + 1, (_aesSrc(out, at + 1) & 0xbf) | (k & 64));
      _aesPut(out, at + 2, (_aesSrc(out, at + 2) & 0xfb) | ((k << 2) & 4));
      _aesPut(out, at + 3, (_aesSrc(out, at + 3) & 0xef) | ((k >> 3) & 16));
      _aesPut(out, at + 4, (_aesSrc(out, at + 4) & 0xf7) | ((k + k) & 8));
      _aesPut(out, at + 5, (_aesSrc(out, at + 5) & 0xfd) | ((k >> 3) & 2));
      _aesPut(out, at + 6, (_aesSrc(out, at + 6) & 0xfe) | ((k >> 5) & 1));
      _aesPut(out, at + 7, (_aesSrc(out, at + 7) & 0x7f) | ((k << 4) & 128));
    }
    return Uint8List.fromList([key[key.length - 1], ...out]);
  }
}

// ==================== xmxor / keyHash / x-medusa / x-helios ====================

/// 按 key 表逐字节混淆 + 三段尾部修正。
Uint8List _xmxor(Uint8List data, Uint8List key) {
  final encoded = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    final at = (i * 4) & 28;
    final d0 = key[at];
    final d1 = key[at + 1];
    var d2 = (_rotl8(data[i]) + d0) & 0xFF;
    d2 = (~d2) & 0xFF ^ d1;
    d2 = _rotl8x3(d2);
    d2 = (d2 + d1) & 0xFF;
    d2 = d2 ^ d0;
    encoded[data.length - i - 1] = (~d2) & 0xFF;
  }
  final last = encoded[encoded.length - 1] ^ encoded[encoded.length - 2];
  final first = encoded[0];
  encoded[0] = (((~last) & 0xFF) + first) & 0xFF;
  encoded[1] =
      ((encoded[0] ^ encoded[encoded.length - 1] ^ 254) + encoded[1]) & 0xFF;
  encoded[2] = (encoded[2] +
          ((((last - first) & 0xFF) ^ _rotl8x3(encoded[1])) ^ 2)) &
      0xFF;
  for (var i = 0; i < encoded.length - 4; i++) {
    final temp =
        _rotl8x3(encoded[i + 2]) ^ encoded[i + 1] ^ ((i + 3) & 0xFF);
    encoded[i + 3] = (((~temp) & 0xFF) + encoded[i + 3]) & 0xFF;
  }
  encoded[encoded.length - 1] =
      encoded[encoded.length - 1] ^ encoded[encoded.length - 2];
  var sum = 0;
  for (var i = 0; i < encoded.length - 1; i++) {
    sum += encoded[i + 1];
  }
  encoded[0] = ((encoded[0] ^ encoded[1]) + (sum & 0xFF)) & 0xFF;
  return encoded;
}

final Uint8List _medusaSignKey =
    _unhex('8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5');
final Uint8List _medusaAESKey = _unhex('f1593376766ea98d34f31b057a9d5be4');
final Uint8List _medusaAESIV = _unhex('1fe109a4125283f418de9e051a969e12');
final Uint8List _medusaMagic16 = _unhex('f7e85ffad7d7dc3bd62ac87057cf6118');
final Uint8List _medusaMagic8 = _unhex('4001000000000000');
final Uint8List _medusaVersionBytes =
    _unhex('03000000f7e85ffad7d7dc3bd62ac87057cf6118');

String? _processNonceCache;
int? _processStartedCache;

(String, int) _processState(Random rng) {
  final existing = _processNonceCache;
  if (existing != null) return (existing, _processStartedCache!);
  final nonce = Uint8List(18);
  for (var i = 0; i < nonce.length; i++) {
    nonce[i] = _randUint32(rng) & 0xFF;
  }
  // 18 字节 base64url 正好 24 字符，无填充。
  _processNonceCache = base64Url.encode(nonce);
  _processStartedCache = DateTime.now().millisecondsSinceEpoch;
  return (_processNonceCache!, _processStartedCache!);
}

/// signKey || le32(random) || signKey 的 SM3，附一个由 random 派生的 4 字节种子。
(Uint8List, Uint8List) _keyHash(Uint8List signKey, int random) {
  final input = Uint8List.fromList([...signKey, ..._le32(random), ...signKey]);
  final hash = _sm3(input);
  final d1 = (random >> 16) & 255;
  var d2 = ((d1 << 11) | (random >> 24)) ^ (d1 >> 5) ^ d1;
  d2 = ~d2;
  return (hash, _le32(d2 & 0xFFFFFFFF));
}

/// medusa 里所有非确定输入，收拢便于逐字节比对与复现。
@immutable
class HongguoMedusaContext {
  const HongguoMedusaContext({
    required this.messageRand,
    required this.envLaunch,
    required this.envPID,
    required this.nonce,
    required this.started,
    required this.nowUnix,
  });

  final int messageRand;
  final int envLaunch;
  final int envPID;
  final String nonce;
  final int started;
  final int nowUnix;
}

HongguoMedusaContext _newMedusaContext(Random rng) {
  final (nonce, started) = _processState(rng);
  return HongguoMedusaContext(
    messageRand: _randUint32(rng),
    envLaunch: 100 + _randInt(rng, 21),
    envPID: 10001 + _randInt(rng, 2000),
    nonce: nonce,
    started: started,
    nowUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );
}

/// 设备信息 protobuf，用显式 nonce / started 便于比对。
Uint8List _deviceProtoWith(String deviceID, String nonce, int started) =>
    _proto([
      const _PField(1, 1, 'sint'),
      const _PField(2, 2, 'sint'),
      const _PField(3, '8662'),
      _PField(4, deviceID),
      _PField(5, nonce),
      const _PField(6, '!noperm!'),
      const _PField(7, -888888, 'sint'),
      const _PField(8, -888888, 'sint'),
      const _PField(9, 3, 'sint'),
      const _PField(10, -888888, 'sint'),
      const _PField(11, '!notset!'),
      const _PField(12, 'Asia/Shanghai,8'),
      const _PField(13, 'zh_CN'),
      const _PField(14, 4, 'sint'),
      const _PField(16, 0.0, 'float'),
      const _PField(17, 0.0, 'float'),
      const _PField(18, 0.0, 'float'),
      const _PField(19, 0.0, 'float'),
      const _PField(20, 0.0, 'float'),
      const _PField(21, 0.0, 'float'),
      const _PField(22, '16'),
      const _PField(23, 41, 'sint'),
      const _PField(24, 36, 'sint'),
      _PField(25, started, 'sint'),
      _PField(26, started, 'sint'),
      _PField(27, started, 'sint'),
      _PField(28, started, 'sint'),
      const _PField(29, -1, 'sint'),
      const _PField(30, '25053RT47C'),
      const _PField(31, 'Redmi'),
      const _PField(32, '25053RT47C'),
      const _PField(33, '25053RT47C'),
      const _PField(34, 'Xiaomi'),
      const _PField(35, 'Redmi'),
      const _PField(36, 'Redmi'),
      const _PField(38, 31, 'sint'),
    ]);

const String _medusaRuntimeJSON =
    '{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,'
    '"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"",'
    '"do":0,"tk":true}';

/// 组装 medusa 的 protobuf 消息体（混淆前）。
Uint8List _medusaMessage(
  String rawURL,
  Uint8List? body,
  int khronos,
  String deviceID,
  String version,
  HongguoMedusaContext ctx,
) {
  var bodyMd5 = Uint8List(16);
  if (body != null && body.isNotEmpty) {
    bodyMd5 = _md5(body);
  }
  final query = _queryOf(rawURL);
  final querySm3 = _sm3(utf8.encode(query));
  final ts = _le32(khronos);
  final queryBodyTs = _hashF13(querySm3, bodyMd5, ts, khronos);

  final env = _proto([
    _PField(1, ctx.envLaunch, 'sint'),
    const _PField(2, 146331399, 'sint'),
    const _PField(3, 146331396, 'sint'),
    const _PField(5, 7, 'sint'),
    const _PField(6, 'v04.06.04.03-bugfix'),
    _PField(7, ctx.envPID, 'sint'),
    _PField(12, _deviceProtoWith(deviceID, ctx.nonce, ctx.started), 'message'),
    _PField(
      13,
      _proto([
        _PField(1, ctx.nowUnix, 'sint'),
        const _PField(2, -2, 'sint'),
        const _PField(4, 200, 'sint'),
      ]),
      'message',
    ),
    _PField(14, version),
  ]);
  final queryHash = _sm3(
    Uint8List.fromList([...utf8.encode(query), ...bodyMd5, ...utf8.encode('none')]),
  );

  final nested = _proto([
    const _PField(1, 111, 'sint'),
    const _PField(2, 10, 'sint'),
    const _PField(3, 694367, 'sint'),
    const _PField(5, 586952199, 'sint'),
  ]);
  return _proto([
    _PField(1, _medusaMagic16, 'bytes'),
    const _PField(2, 3, 'sint'),
    _PField(3, ctx.messageRand, 'sint'),
    const _PField(4, '8662'),
    _PField(5, deviceID),
    const _PField(6, '1588093228'),
    _PField(7, version),
    const _PField(8, 'v04.06.04-ml-android'),
    const _PField(9, 67503104, 'sint'),
    _PField(10, _medusaMagic8, 'bytes'),
    _PField(12, khronos, 'sint'),
    _PField(13, queryBodyTs, 'bytes'),
    _PField(14, querySm3.sublist(0, 6), 'bytes'),
    _PField(15, nested, 'message'),
    _PField(16, ctx.nonce),
    _PField(17, khronos, 'sint'),
    _PField(19, queryHash, 'bytes'),
    const _PField(20, 'none'),
    const _PField(21, 312, 'sint'),
    _PField(23, env, 'message'),
    const _PField(24, _medusaRuntimeJSON),
  ]);
}

/// 构造 x-medusa（公开入口注入安全随机）。
String _buildMedusa(
  String rawURL,
  Uint8List? body,
  int khronos,
  String deviceID,
  String version,
  Random rng,
) => _buildMedusaWith(
  rawURL,
  body,
  khronos,
  deviceID,
  version,
  _newMedusaContext(rng),
  _randUint32(rng),
  _randUint32(rng),
);

String _buildMedusaWith(
  String rawURL,
  Uint8List? body,
  int khronos,
  String deviceID,
  String version,
  HongguoMedusaContext ctx,
  int random,
  int xmRand,
) {
  final querySm3 = _sm3(utf8.encode(_queryOf(rawURL)));
  var bodyMd5 = Uint8List(16);
  if (body != null && body.isNotEmpty) {
    bodyMd5 = _md5(body);
  }
  final ts = _le32(khronos);
  final queryBodyTs = _hashF13(querySm3, bodyMd5, ts, khronos);
  final message = _medusaMessage(rawURL, body, khronos, deviceID, version, ctx);

  final (hash, seed) = _keyHash(_medusaSignKey, random);
  final transformed = _xmxor(message, hash);
  final withMagic = Uint8List.fromList([..._medusaMagic8, ...transformed]);
  for (var i = 0, j = withMagic.length - 1; i < j; i++, j--) {
    final tmp = withMagic[i];
    withMagic[i] = withMagic[j];
    withMagic[j] = tmp;
  }
  for (var i = 0; i < withMagic.length; i++) {
    withMagic[i] ^= seed[(~i) & 3];
  }
  final check = (querySm3[0] & 63) << 14 | 0x18000001 | (queryBodyTs[0] & 63) << 8;
  final packed = Uint8List.fromList([
    0x35,
    ..._le32(xmRand),
    ..._le32(check),
    ...withMagic,
    (random >> 16) & 255,
    (random >> 24) & 255,
  ]);

  final encrypted = _AesV3(_medusaAESKey, khronos).encrypt(packed, _medusaAESIV);
  final prefix = Uint8List(20);
  for (var i = 0; i < 20; i += 4) {
    ByteData.sublistView(prefix)
        .setUint32(i, _readLe32(_medusaVersionBytes, i) ^ khronos, Endian.little);
  }
  final out = Uint8List.fromList([
    ...prefix,
    random & 255,
    (random >> 8) & 255,
    0,
    1,
    ...encrypted,
  ]);
  return _b64(out);
}

/// md5 ASCII 化 -> 64 位字表 -> 34 轮扩展 -> 分组类 Feistel。
String _helios(int khronos, Random rng) => _heliosWith(khronos, _randUint32(rng));

String _heliosWith(int khronos, int random) {
  final digest = _md5([..._le32(random), ...utf8.encode('8662')]);
  final ascii = _hex(digest).codeUnits;
  final asciiBytes = Uint8List.fromList(ascii);
  final words = List<int>.generate(4, (i) => _readU64Le(asciiBytes, i * 8));

  final queue = <int>[words[2], words[3]];
  var b0 = words[0];
  var b8 = words[1];
  final table = List<int>.filled(35, 0);
  table[0] = words[0];
  for (var i = 0; i < 34; i++) {
    var x8 = _rotr64(b8, 8) + b0;
    x8 ^= i;
    queue.add(x8);
    x8 ^= _rotr64(b0, 61);
    table[i + 1] = x8;
    b0 = x8;
    b8 = queue[0];
    queue.removeAt(0);
  }

  final text = '$khronos-1588093228-8662';
  final tb = utf8.encode(text);
  final padLen = (tb.length + 1 + 15) ~/ 16 * 16;
  final padFill = (16 - tb.length % 16) & 0xFF;
  final pad = Uint8List(padLen)..fillRange(0, padLen, padFill);
  pad.setAll(0, tb);

  final output = BytesBuilder();
  final view = ByteData.sublistView(pad);
  for (var at = 0; at < pad.length; at += 16) {
    var a = view.getUint64(at, Endian.little);
    var b = view.getUint64(at + 8, Endian.little);
    for (var i = 0; i < 34; i++) {
      b = table[i] ^ (a + _rotr64(b, 8));
      a = b ^ _rotr64(a, 61);
    }
    final block = Uint8List(16);
    _putU64Le(block, 0, a);
    _putU64Le(block, 8, b);
    output.add(block);
  }
  return _b64(Uint8List.fromList([..._le32(random), ...output.toBytes()]));
}

// ==================== 入口 ====================

String _queryOf(String rawURL) {
  final index = rawURL.indexOf('?');
  return index >= 0 ? rawURL.substring(index + 1) : '';
}

String _paramOf(String query, String key, String fallback) {
  for (final pair in query.split('&')) {
    final index = pair.indexOf('=');
    if (index <= 0) continue;
    if (pair.substring(0, index) == key) {
      final value = pair.substring(index + 1);
      if (value.isNotEmpty) return value;
    }
  }
  return fallback;
}

/// 与 [_hashF13] 用同一分支计算；结果为 1 时服务端不接受，
/// 调用方必须抖动 _rticket 重新签名。
@visibleForTesting
int hongguoBranchOf(String rawURL, Uint8List? body, int khronos) {
  var bodyMd5 = Uint8List(16);
  if (body != null && body.isNotEmpty) {
    bodyMd5 = _md5(body);
  }
  final query = _sm3(utf8.encode(_queryOf(rawURL)));
  final iv = _getIv(_getIv(_getIv(0x20230928, query), bodyMd5), _le32(khronos));
  final low = iv & 15;
  return low - ((low * 171) >> 9) * 3;
}

/// 返回需要合并进请求头的六个签名字段。
/// rawURL 必须与最终发出的请求字节一致（含 query 与 _rticket）。
Map<String, String> _signHeaders(
  String rawURL,
  Uint8List? body,
  int khronos,
  String deviceID,
  String version,
  Random rng,
) {
  final query = _queryOf(rawURL);
  return {
    'X-Gorgon': _xGorgon(query, body, khronos, _randInt(rng, 65536)),
    'X-Khronos': '$khronos',
    'X-Ladon': _b64(_be32(khronos)),
    'X-Argus': _b64(_le32(khronos)),
    'X-Helios': _helios(khronos, rng),
    'X-Medusa': _buildMedusa(rawURL, body, khronos, deviceID, version, rng),
  };
}

/// 把 _rticket 自增 1 并重建 query；缺失时先补一个再自增。
///
/// 与 Go 的 url.Values.Encode 语义对齐：键按字母序输出。我们的 query
/// 构造时已按字母序排列，这里保持原顺序并只改写 _rticket，保证其余
/// 字节与原请求完全一致。
String _bumpTicket(String rawQuery) {
  final rebuilt = <String>[];
  int? current;
  if (rawQuery.isNotEmpty) {
    for (final pair in rawQuery.split('&')) {
      if (pair.startsWith('_rticket=')) {
        current = int.tryParse(pair.substring('_rticket='.length));
      } else {
        rebuilt.add(pair);
      }
    }
  }
  final base = current ?? DateTime.now().millisecondsSinceEpoch;
  rebuilt.add('_rticket=${base + 1}');
  rebuilt.sort((a, b) {
    final aKey = a.indexOf('=') > 0 ? a.substring(0, a.indexOf('=')) : a;
    final bKey = b.indexOf('=') > 0 ? b.substring(0, b.indexOf('=')) : b;
    return aKey.compareTo(bKey);
  });
  return rebuilt.join('&');
}

/// 为红果 App 接口附加完整签名头。
///
/// 必须六个头齐全：官方播放接口对缺头的请求返回 HTTP 200 且正文为零
/// 字节，不会给出任何错误码，因此缺头时表现为「接口没数据」。
///
/// 另需处理 branch==1：签名内部按 iv 低 4 位选分支，落到 1 时服务端
/// 不接受，表现为同样的空正文。此处通过自增 _rticket 重算出不同 iv
/// 来避开（最多 32 次，与上游一致）。
///
/// 返回最终 URI（_rticket 可能被抖动改写）与需要合并的签名头集合。
({Uri uri, Map<String, String> headers}) signHongguoAppRequest(
  Uri uri,
  List<int> body,
  DateTime now, {
  Random? random,
}) {
  final rng = random ?? Random.secure();
  final bodyBytes = Uint8List.fromList(body);
  final timestamp = (now.millisecondsSinceEpoch ~/ 1000) & 0xFFFFFFFF;
  var current = uri;
  for (var attempt = 0; attempt < 32; attempt++) {
    if (hongguoBranchOf(current.toString(), bodyBytes, timestamp) != 1) {
      break;
    }
    current = current.replace(query: _bumpTicket(current.query));
  }

  final query = current.query;
  final headers = _signHeaders(
    current.toString(),
    bodyBytes,
    timestamp,
    _paramOf(query, 'device_id', '0'),
    _paramOf(query, 'version_name', '7.1.3.32'),
    rng,
  );
  if (bodyBytes.isNotEmpty) {
    headers['X-SS-STUB'] = _hex(_md5(bodyBytes)).toUpperCase();
  }
  var ticket = _paramOf(query, '_rticket', '');
  if (ticket.isEmpty) ticket = '${now.millisecondsSinceEpoch}';
  headers['X-SS-Req-Ticket'] = ticket;
  return (uri: current, headers: headers);
}

// ==================== 测试可见的公开包装 ====================
//
// 金样向量来自上游 provider_hongguo_sign_test.go，逐字节钉住每一层。

/// SM3（x-medusa / hashF13 的基础哈希）。
@visibleForTesting
Uint8List hongguoSm3ForTest(List<int> data) => _sm3(data);

@visibleForTesting
String hongguoXGorgon(String query, Uint8List? body, int timestamp, int random) =>
    _xGorgon(query, body, timestamp, random);

@visibleForTesting
String hongguoHeliosWith(int khronos, int random) => _heliosWith(khronos, random);

@visibleForTesting
String hongguoB64BE32(int value) => _b64(_be32(value));

@visibleForTesting
String hongguoB64LE32(int value) => _b64(_le32(value));

@visibleForTesting
Uint8List hongguoHashF13(
  Uint8List querySm3,
  Uint8List bodyMd5,
  Uint8List tsBytes,
  int khronos,
) => _hashF13(querySm3, bodyMd5, tsBytes, khronos);

@visibleForTesting
Uint8List hongguoMd5ForTest(List<int> data) => _md5(data);

@visibleForTesting
Uint8List hongguoAesV3Encrypt(Uint8List key, int khronos, Uint8List data, Uint8List iv) =>
    _AesV3(key, khronos).encrypt(data, iv);

@visibleForTesting
Uint8List hongguoXmxor(Uint8List data, Uint8List key) => _xmxor(data, key);

@visibleForTesting
Uint8List hongguoMedusaSignKeyForTest() => _medusaSignKey;

@visibleForTesting
(Uint8List, Uint8List) hongguoKeyHash(Uint8List signKey, int random) =>
    _keyHash(signKey, random);

@visibleForTesting
Uint8List hongguoMedusaMessage(
  String rawURL,
  Uint8List? body,
  int khronos,
  String deviceID,
  String version,
  HongguoMedusaContext ctx,
) => _medusaMessage(rawURL, body, khronos, deviceID, version, ctx);

@visibleForTesting
String hongguoBuildMedusaWith(
  String rawURL,
  Uint8List? body,
  int khronos,
  String deviceID,
  String version,
  HongguoMedusaContext ctx,
  int random,
  int xmRand,
) => _buildMedusaWith(rawURL, body, khronos, deviceID, version, ctx, random, xmRand);
