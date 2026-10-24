import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:minireel/data/sources/hongguo/hongguo_puresign.dart';

/// 红果六头签名（puresign）金样测试。
///
/// 全部期望值来自上游 provider_hongguo_sign_test.go（其期望值由参考实现
/// pure-sign.js 以固定输入生成）。任何一处位运算语义偏移都会在这里暴露，
/// 而不是表现为线上 HTTP 200 空正文。
void main() {
  const query =
      'device_id=1234567890123456&version_name=7.1.3.32&_rticket=1700000000000';
  final body = Uint8List.fromList(
    '{"biz_param":{"video_platform":1024}}'.codeUnits,
  );
  const ts = 1700000000;

  Uint8List md5Of(String text) => hongguoMd5ForTest(text.codeUnits);
  Uint8List sm3Of(String text) => hongguoSm3ForTest(text.codeUnits);

  test('SM3 匹配国家标准向量', () {
    expect(
      hongguoSm3ForTest('abc'.codeUnits)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(),
      '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0',
    );
    expect(
      hongguoSm3ForTest(const [])
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(),
      '1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b',
    );
  });

  test('x-gorgon 金样', () {
    expect(
      hongguoXGorgon(query, body, ts, 0x5a3c),
      '84043c5a4001d7f13e8d8c0d5c51fffe947c5eca3b3ae360e4f4',
    );
  });

  test('x-helios 金样（固定随机量）', () {
    expect(
      hongguoHeliosWith(ts, 0x5f3759df),
      '31k3XyU8JrE4X57lcCNiui/SgyhKdrQ7pX2MvEcq6V05pLh4',
    );
  });

  test('helios 确定性：相同输入输出一致、随 khronos 变化', () {
    final first = hongguoHeliosWith(ts, 0x5f3759df);
    expect(hongguoHeliosWith(ts, 0x5f3759df), first);
    expect(hongguoHeliosWith(ts + 1, 0x5f3759df), isNot(first));
  });

  test('x-ladon / x-argus 格式金样', () {
    expect(hongguoB64BE32(ts), 'ZVPxAA==');
    expect(hongguoB64LE32(ts), 'APFTZQ==');
  });

  test('branchOf 金样：该样本落在 branch==2', () {
    final rawURL =
        'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_model/v1/?$query';
    expect(hongguoBranchOf(rawURL, body, ts), 2);
  });

  test('branchOf 始终在 0..2 范围内', () {
    const rawURL = 'https://api5-normal-sinfonlineb.fqnovel.com/x?a=1&_rticket=1';
    final body2 = Uint8List.fromList('{"a":1}'.codeUnits);
    for (var offset = 0; offset < 5; offset++) {
      final branch = hongguoBranchOf(rawURL, body2, ts + offset);
      expect(branch, inInclusiveRange(0, 2));
    }
  });

  test('AesV3 金样（四个 khronos 覆盖 wordSize 四分支）', () {
    final data = Uint8List(64);
    for (var i = 0; i < data.length; i++) {
      data[i] = (i * 7 + 3) & 0xFF;
    }
    final key = Uint8List.fromList(
      [
        for (var i = 0; i < 32; i += 2)
          int.parse('f1593376766ea98d34f31b057a9d5be4'.substring(i, i + 2), radix: 16),
      ],
    );
    final iv = Uint8List.fromList(
      [
        for (var i = 0; i < 32; i += 2)
          int.parse('1fe109a4125283f418de9e051a969e12'.substring(i, i + 2), radix: 16),
      ],
    );
    final want = <int, String>{
      1700000000:
          '8e230a110817242d343b024950575c65ec537a81988f969c24abb2bdc0cfced4dce3aaf5f8ff040c143b622d303f3c45cc735a65686f747d848bd299b0a7aeb5bc',
      1700000001:
          'c9230a111817242c343b024d40575c646c537a818887949c24abb2b9d0cfced55ce3eaf5e8f7040c143b622d20373c444c535a657867767d84abd299b0a7acb53c',
      1700000002:
          'a6034a150817262c343b024d505f5e656c533a85988f969ca4abb2b9c0c7ccd45ce3aaf1e8ff040c141b222d303f3c454c535a657867747d84ab929db0afacb53c',
      1700000003:
          '08234a15181f242cb41b0249405f5e64ec533a85888f949ca4abf2b9c0cfccd55cc3eaf1f8f7060d141b222d30373c454c731a61686f747d04abd299a0a7acb53c',
    };
    want.forEach((khronos, expected) {
      final got = hongguoAesV3Encrypt(key, khronos, data, iv)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(got, expected, reason: 'AesV3 khronos=$khronos');
    });
  });

  test('xmxor 金样', () {
    final data = Uint8List(64);
    for (var i = 0; i < data.length; i++) {
      data[i] = (i * 7 + 3) & 0xFF;
    }
    final keyBytes = <int>[
      for (var i = 0; i < 32; i++) (i * 11 + 5) & 0xFF,
    ];
    expect(
      hongguoXmxor(data, Uint8List.fromList(keyBytes))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(),
      'c6f0be038a7e460ca4a134229799d41353254bc5333f317eb9703fc31b5edaf7b11ab87d85cc30fdcb47cc1398e238476db0a953ad2d4bef37bb9f49ff097864',
    );
  });

  test('keyHash 金样', () {
    final (hash, seed) = hongguoKeyHash(hongguoMedusaSignKeyForTest(), 0x12345678);
    String toHex(Uint8List bytes) =>
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect(toHex(hash),
        '489143ef7f0135c393ebcef82f8e631276f292343e2bc4603e9d62b236414918');
    expect(toHex(seed), 'd85ffeff');
  });

  test('hashF13 三分支金样', () {
    final cases = <(String, String, int, String)>[
      (
        'device_id=1234567890123456&version_name=7.1.3.32&_rticket=1700000000000',
        '{"biz_param":{"video_platform":1024}}',
        1700000000,
        '074e4968e955e394b58e08b442e0bc20af180de2',
      ),
      ('a=1&b=2', '{}', 1700000005, '2b19648138724a7a2eaf1da95d6ac0902cffc5d9'),
      (
        'x=9',
        '',
        1700000010,
        '06108abf81691152f57f08fbe3ff1f96000000000000000000000000000000003f8ac19a',
      ),
    ];
    for (final (caseQuery, caseBody, khronos, want) in cases) {
      final bodyMd5 = caseBody.isEmpty ? Uint8List(16) : md5Of(caseBody);
      final got = hongguoHashF13(sm3Of(caseQuery), bodyMd5,
              Uint8List.fromList([for (var i = 0; i < 4; i++) (khronos >> (8 * i)) & 0xFF]),
              khronos)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(got, want, reason: 'hashF13(query=$caseQuery, body=$caseBody, ts=$khronos)');
    }
  });

  test('medusa protobuf 消息体逐字节金样', () {
    final want = File('test/fixtures/hongguo_medusa_message.hex')
        .readAsStringSync()
        .trim();
    const ctx = HongguoMedusaContext(
      messageRand: 0x12345678,
      envLaunch: 105,
      envPID: 11000,
      nonce: 'AAAAAAAAAAAAAAAAAAAAAAAA',
      started: 1700000000000,
      nowUnix: 1700000000,
    );
    final got = hongguoMedusaMessage(
      'https://x/?$query',
      body,
      ts,
      '1234567890123456',
      '7.1.3.32',
      ctx,
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect(got, want);
  });

  test('medusa 随请求体变化且为合法 base64', () {
    const rawURL = 'https://api5-normal-sinfonlineb.fqnovel.com'
        '/novel/player/video_model/v1/?$query';
    const ctx = HongguoMedusaContext(
      messageRand: 1,
      envLaunch: 100,
      envPID: 10001,
      nonce: 'AAAAAAAAAAAAAAAAAAAAAAAA',
      started: 1700000000000,
      nowUnix: 1700000000,
    );
    final first = hongguoBuildMedusaWith(
      rawURL,
      Uint8List.fromList('{"a":1}'.codeUnits),
      ts,
      '1234567890123456',
      '7.1.3.32',
      ctx,
      0x11223344,
      0x55667788,
    );
    final second = hongguoBuildMedusaWith(
      rawURL,
      Uint8List.fromList('{"a":2}'.codeUnits),
      ts,
      '1234567890123456',
      '7.1.3.32',
      ctx,
      0x11223344,
      0x55667788,
    );
    expect(first, isNotEmpty);
    expect(first, isNot(second));
    expect(() => base64Decode(first), returnsNormally);
  });
}
