import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minireel/core/config/source_config.dart';
import 'package:pointycastle/digests/md5.dart';
import 'package:minireel/core/network/app_http_client.dart';
import 'package:minireel/data/sources/hongguo/hongguo_app_client.dart';
import 'package:minireel/data/sources/hongguo/hongguo_puresign.dart';

/// 红果 App 接口的签名契约（对齐上游 0.1.24 六头全签）：
/// 除旧版单集播放模型接口外，所有请求必须携带六头签名 + X-SS-STUB +
/// X-SS-Req-Ticket；缺头或签名落到 branch==1 都会表现为 HTTP 200 空正文。
class _CapturingClient implements TextClient, SignedJsonClient {
  final requests = <({Uri uri, Map<String, String> headers})>[];

  @override
  Future<String> postSignedJson(
    Uri Function() prepareUri,
    String body,
    Map<String, String> Function(Uri) prepareHeaders, {
    CancelToken? cancelToken,
  }) async {
    final uri = prepareUri();
    requests.add((uri: uri, headers: prepareHeaders(uri)));
    return '{"code":0,"data":{}}';
  }

  @override
  Future<String> getText(
    Uri uri, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async => '';
}

const _sixHeaders = [
  'X-Gorgon',
  'X-Khronos',
  'X-Ladon',
  'X-Argus',
  'X-Helios',
  'X-Medusa',
];

void main() {
  final config = SourceConfig(
    baseUrl: Uri.parse('https://hongguoduanju.com'),
    playbackEndpoint: Uri.parse('https://example.invalid/api/play'),
    referer: 'https://hongguoduanju.com/',
    mediaReferer: 'https://novel.snssdk.com/',
    appBaseUrl: Uri.parse('https://api5-normal-sinfonlineb.fqnovel.com'),
    appUserAgent: 'com.phoenix.read/73532 (Linux; U; Android 16)',
    appParameters: const {
      'aid': '8662',
      'version_code': '73532',
      'version_name': '7.3.5.32',
    },
  );

  test('播放模型接口同样带六头签名（0.1.24 全签契约）', () async {
    final client = _CapturingClient();
    await HongguoAppClient(config, client).post(
      hongguoVideoModelPath,
      {
        'biz_param': {'video_platform': 1024},
        'mixed_video_id_map': {
          '1004': ['7692096762072288280'],
        },
      },
    );
    final headers = client.requests.single.headers;
    for (final name in _sixHeaders) {
      expect(headers[name], isNotNull, reason: name);
    }
    expect(headers['X-SS-STUB'], isNotNull);
    expect(headers['X-SS-Req-Ticket'], isNotNull);
    // 非签名头必须保留
    expect(headers['X-XS-From-Web'], '0');
    expect(headers['Sdk-Version'], '2');
    expect(headers['Accept'], 'application/json');
  });

  test('详情接口发送完整六头签名 + STUB + Ticket', () async {
    final client = _CapturingClient();
    await HongguoAppClient(config, client).post(
      '/novel/player/video_detail/v1/',
      {'series_id': '7692043430955863102'},
    );
    final request = client.requests.single;
    for (final name in _sixHeaders) {
      expect(request.headers[name], isNotNull, reason: name);
    }
    // X-Khronos 与 X-Ladon/X-Argus 必须一致
    final khronos = request.headers['X-Khronos']!;
    final seconds = int.parse(khronos);
    final queryTicket = request.uri.queryParameters['_rticket']!;
    final millis = int.parse(queryTicket);
    expect((millis ~/ 1000 - seconds).abs(), lessThanOrEqualTo(1));

    // X-SS-STUB = 大写 hex MD5(body)
    const body = '{"series_id":"7692043430955863102"}';
    final stub = request.headers['X-SS-STUB']!;
    final expectedStub = MD5Digest()
        .process(Uint8List.fromList(body.codeUnits))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    expect(stub, expectedStub);

    // X-SS-Req-Ticket 与 query 的 _rticket 一致
    expect(request.headers['X-SS-Req-Ticket'], queryTicket);

    // X-Medusa 是合法 base64
    expect(
      () => base64Decode(request.headers['X-Medusa']!),
      returnsNormally,
    );
    // medusa 最短也要包含 20 字节前缀 + 加密输出
    expect(base64Decode(request.headers['X-Medusa']!).length, greaterThan(40));
  });

  test('签名后 branch 不落在被服务端拒绝的 branch==1', () async {
    final client = _CapturingClient();
    final app = HongguoAppClient(config, client);
    for (var i = 0; i < 8; i++) {
      await app.post('/novel/player/video_detail/v1/', {'series_id': '$i'});
      final request = client.requests[i];
      final body = '{"series_id":"$i"}';
      final branch = hongguoBranchOf(
        request.uri.toString(),
        Uint8List.fromList(body.codeUnits),
        int.parse(request.headers['X-Khronos']!),
      );
      expect(branch, isNot(1), reason: 'request #$i branch=$branch');
    }
  });

  test('设备标识在多次请求间保持一致', () async {
    final client = _CapturingClient();
    final app = HongguoAppClient(config, client);
    await app.post('/novel/player/video_detail/v1/', {'series_id': '1'});
    await app.post('/novel/player/video_detail/v1/', {'series_id': '2'});
    final deviceIds = client.requests
        .map((r) => r.uri.queryParameters['device_id'])
        .toSet();
    final installIds = client.requests
        .map((r) => r.uri.queryParameters['iid'])
        .toSet();
    expect(deviceIds, hasLength(1));
    expect(installIds, hasLength(1));
    expect(deviceIds.single, matches(RegExp(r'^[0-9]{1,32}$')));
  });

  test('目录接口同样带六头签名', () async {
    final client = _CapturingClient();
    await HongguoAppClient(config, client).post(
      '/reading/distribution/category/landpage/v/',
      {'req_type': 'only_content'},
    );
    final headers = client.requests.single.headers;
    for (final name in _sixHeaders) {
      expect(headers[name], isNotNull, reason: name);
    }
  });
}
