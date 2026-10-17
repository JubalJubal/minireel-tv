import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/digests/md5.dart';
import 'package:pointycastle/digests/sm3.dart';
import 'package:pointycastle/export.dart'
    show AESEngine, CBCBlockCipher, KeyParameter, ParametersWithIV;

/// 红果「评论/弹幕」接口的签名头。与普通播放接口不同，评论接口额外要求
/// X-Argus / X-Ladon / Comment-Source / Server-Channel，缺失时服务端返回
/// 110001「未知异常」。算法逐行移植自参考实现 provider_hongguo_comment_sign.go。
final class HongguoCommentNonce {
  HongguoCommentNonce(this.bytes) : assert(bytes.length == 11);

  final Uint8List bytes;

  factory HongguoCommentNonce.random([Random? random]) {
    final source = random ?? Random.secure();
    return HongguoCommentNonce(
      Uint8List.fromList(List<int>.generate(11, (_) => source.nextInt(256))),
    );
  }
}

Map<String, String> signHongguoCommentRequest(
  Uri uri,
  DateTime now,
  HongguoCommentNonce nonce,
) {
  final stamp = now.millisecondsSinceEpoch ~/ 1000;
  final query = uri.query;
  final head2 = ((nonce.bytes[0] % 7 + 1) << 5) & 0xFF;
  final head3 = 0xE0 | (nonce.bytes[1] & 15);
  final seed = Uint8List(20);
  final queryHash = _md5(utf8.encode(query));
  seed.setRange(0, 4, queryHash.sublist(0, 4));
  seed.setRange(12, 16, const [0, 1, 7, 4]);
  ByteData.sublistView(seed).setUint32(16, stamp, Endian.big);
  final key = Uint8List.fromList([0x4a, 0, 0x16, head3, 0x47, 0x6c, 0, head2]);
  final box = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    box[i] = i;
  }
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + box[i] + key[i & 7]) & 0xFF;
    box[i] = box[j];
  }
  j = 0;
  for (var offset = 0; offset < seed.length; offset++) {
    final i = (offset + 1) & 0xFF;
    j = (j + box[i]) & 0xFF;
    box[i] = box[j];
    seed[offset] ^= box[(box[i] + box[j]) & 0xFF];
  }
  for (var i = 0; i < seed.length; i++) {
    seed[i] = _reverse8(_rotl8(seed[i], 4) ^ seed[(i + 1) % seed.length]) ^ 0xEB;
  }
  final gorgon = <int>[0x84, 4, head2, head3, 0, 0, ...seed];
  return {
    'X-Gorgon': _hex(gorgon),
    'X-Khronos': '$stamp',
    'X-SS-Req-Ticket': '${now.millisecondsSinceEpoch}',
    'X-SS-STUB': '',
    'X-Argus': _argus(query, stamp, nonce),
    'X-Ladon': _ladon(query, stamp, nonce.bytes.sublist(2, 6)),
  };
}

String _argus(String query, int stamp, HongguoCommentNonce nonce) {
  final key = _hexBytes(
    'ac1adaae95a7af94a5114ab3b3a97dd8'
    '0050aa0a39314c40528caec95256c28c',
  );
  final message = <int>[];
  void varint(int field, int value) {
    message.addAll(_uvarint(field * 8));
    message.addAll(_uvarint(value));
  }

  void bytesField(int field, List<int> value) {
    message.addAll(_uvarint(field * 8 + 2));
    message.addAll(_uvarint(value.length));
    message.addAll(value);
  }

  varint(1, 0x20200929 * 2);
  varint(2, 2);
  varint(
    3,
    ByteData.sublistView(nonce.bytes).getUint32(6, Endian.little),
  );
  bytesField(4, ascii.encode('3019'));
  bytesField(6, ascii.encode('1611921764'));
  bytesField(7, ascii.encode('6.8.1.32'));
  bytesField(8, ascii.encode('v04.07.01-ml-android'));
  varint(9, 135135744);
  bytesField(10, List<int>.filled(8, 0));
  varint(12, stamp * 2);
  final bodyHash = _sm3(Uint8List(16));
  final queryHash = _sm3(utf8.encode(query));
  bytesField(13, bodyHash.sublist(0, 6));
  bytesField(14, queryHash.sublist(0, 6));
  final nested = <int>[8, (2 + (nonce.bytes[10] % 49) * 2) & 0xFF];
  for (final field in const [2, 3, 4]) {
    nested.addAll(_uvarint(field * 8));
    nested.addAll(_uvarint(1388734));
  }
  bytesField(15, nested);
  bytesField(20, ascii.encode('none'));
  varint(21, 738);
  final data = _pad(message);
  final seed = Uint8List.fromList([...key, 0x3c, 0xcc, 0x56, 0x7b, ...key]);
  final derived = _sm3(seed);
  final derivedView = ByteData.sublistView(derived);
  final rounds = List<int>.filled(72, 0);
  for (var i = 0; i < 4; i++) {
    rounds[i] = derivedView.getUint64(i * 8, Endian.little);
  }
  for (var i = 4; i < rounds.length; i++) {
    var mixed = _rotr64(rounds[i - 1], 3) ^ rounds[i - 3];
    mixed ^= _rotr64(mixed, 1);
    rounds[i] =
        ~rounds[i - 4] ^
        mixed ^
        ((0x3dc94c3a046d678b >> ((i - 4) % 62)) & 1) ^
        3;
  }
  final view = ByteData.sublistView(data);
  for (var offset = 0; offset < data.length; offset += 16) {
    var left = view.getUint64(offset, Endian.little);
    var right = view.getUint64(offset + 8, Endian.little);
    for (final round in rounds) {
      final previousLeft = left;
      left = right;
      right =
          previousLeft ^
          (_rotl64(right, 1) & _rotl64(right, 8)) ^
          _rotl64(right, 2) ^
          round;
    }
    view.setUint64(offset, left, Endian.little);
    view.setUint64(offset + 8, right, Endian.little);
  }
  const xor = [0xd0, 0x4f, 0xfd, 0xff, 0xd0, 0x4f, 0xfd, 0xff];
  for (var i = 0; i < data.length; i++) {
    data[i] ^= xor[i % 8];
  }
  final reversed = <int>[...xor, ...data].reversed.toList();
  var container = <int>[0xa6, 0xe7, 0x83, 0xee, 0x70, 0x01, 0x10, 0x09, 0x18];
  container.addAll(reversed);
  container = _pad([...container, 0x56, 0x7b]);
  final aesKey = _md5(key.sublist(0, 16));
  final iv = _md5(key.sublist(16, 32));
  final cipher = CBCBlockCipher(AESEngine())
    ..init(
      true,
      ParametersWithIV(KeyParameter(aesKey), iv),
    );
  final output = Uint8List.fromList(container);
  for (var offset = 0; offset < output.length; offset += 16) {
    cipher.processBlock(output, offset, output, offset);
  }
  return base64.encode([0x3c, 0xcc, ...output]);
}

String _ladon(String query, int stamp, List<int> prefix) {
  final aid = Uri.splitQueryString(query)['aid'] ?? '';
  final hash = _md5([...prefix, ...utf8.encode(aid)]);
  final digest = ascii.encode(_hex(hash));
  final view = ByteData.sublistView(Uint8List.fromList(digest));
  var left = view.getUint64(0, Endian.little);
  var right = view.getUint64(8, Endian.little);
  final queue = <int>[
    view.getUint64(16, Endian.little),
    view.getUint64(24, Endian.little),
  ];
  final keys = List<int>.filled(34, 0);
  for (var i = 0; i < keys.length; i++) {
    keys[i] = left;
    final mixed = (_rotr64(right, 8) + left) ^ i;
    queue.add(mixed);
    left = mixed ^ _rotl64(left, 3);
    right = queue.removeAt(0);
  }
  final data = _pad(
    ascii.encode('$stamp-1611921764-3019'),
  );
  final dataView = ByteData.sublistView(data);
  for (var offset = 0; offset < data.length; offset += 16) {
    var blockLeft = dataView.getUint64(offset, Endian.little);
    var blockRight = dataView.getUint64(offset + 8, Endian.little);
    for (final key in keys) {
      final previousLeft = blockLeft;
      final previousRight = blockRight;
      blockRight = key ^ (previousLeft + _rotr64(previousRight, 8));
      blockLeft = blockRight ^ _rotl64(previousLeft, 3);
    }
    dataView.setUint64(offset, blockLeft, Endian.little);
    dataView.setUint64(offset + 8, blockRight, Endian.little);
  }
  return base64.encode([...prefix, ...data]);
}

Uint8List _pad(List<int> data) {
  final padding = 16 - data.length % 16;
  return Uint8List.fromList([...data, ...List<int>.filled(padding, padding)]);
}

List<int> _uvarint(int value) {
  final out = <int>[];
  var current = value;
  while (current >= 0x80) {
    out.add((current & 0x7f) | 0x80);
    current = current >>> 7;
  }
  out.add(current & 0xff);
  return out;
}

Uint8List _md5(List<int> input) =>
    MD5Digest().process(Uint8List.fromList(input));

Uint8List _sm3(List<int> input) =>
    SM3Digest().process(Uint8List.fromList(input));

int _rotl8(int value, int count) => ((value << count) | (value >> (8 - count))) & 0xFF;

int _reverse8(int value) {
  var result = 0;
  for (var i = 0; i < 8; i++) {
    result = (result << 1) | ((value >> i) & 1);
  }
  return result;
}

int _rotl64(int value, int count) =>
    (value << count) | (value >>> (64 - count));

int _rotr64(int value, int count) =>
    (value >>> count) | (value << (64 - count));

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hexBytes(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);
