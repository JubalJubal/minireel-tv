import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minireel/core/config/source_config.dart';
import 'package:minireel/core/network/app_http_client.dart';
import 'package:minireel/data/sources/hongguo/hongguo_app_client.dart';

/// 红果播放接口必须不带 X-Gorgon 系列签名，否则服务端返回
/// HTTP 200 但正文 0 字节，播放会静默失败。
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

void main() {
  final config = SourceConfig(
    baseUrl: Uri.parse('https://hongguoduanju.com'),
    playbackEndpoint: Uri.parse('https://example.invalid/api/play'),
    referer: 'https://hongguoduanju.com/',
    mediaReferer: 'https://novel.snssdk.com/',
    appBaseUrl: Uri.parse('https://api5-normal-sinfonlineb.fqnovel.com'),
    appUserAgent: 'com.phoenix.read/73532 (Linux; U; Android 16)',
    appParameters: const {'aid': '8662', 'version_code': '73532'},
  );

  test('播放接口不发送签名头', () async {
    final client = _CapturingClient();
    await HongguoAppClient(config, client).post(
      hongguoVideoModelPath,
      {'video_id': '7692096762072288280'},
    );
    final headers = client.requests.single.headers;
    expect(headers.containsKey('X-Gorgon'), isFalse);
    expect(headers.containsKey('X-Khronos'), isFalse);
    expect(headers.containsKey('X-SS-STUB'), isFalse);
    expect(headers.containsKey('X-SS-Req-Ticket'), isFalse);
    // 非签名头必须保留
    expect(headers['X-XS-From-Web'], '0');
    expect(headers['Sdk-Version'], '2');
    expect(headers['Accept'], 'application/json');
  });

  test('其余接口仍必须发送签名头', () async {
    final client = _CapturingClient();
    await HongguoAppClient(config, client).post(
      '/novel/player/video_detail/v1/',
      {'series_id': '7692043430955863102'},
    );
    final headers = client.requests.single.headers;
    expect(headers['X-Gorgon'], isNotNull);
    expect(headers['X-Khronos'], isNotNull);
    expect(headers['X-SS-STUB'], isNotNull);
    expect(headers['X-SS-Req-Ticket'], isNotNull);
  });

  test('设备标识在多次请求间保持一致', () async {
    final client = _CapturingClient();
    final app = HongguoAppClient(config, client);
    await app.post('/novel/player/video_detail/v1/', {'series_id': '1'});
    await app.post('/novel/player/video_model/v1/', {'video_id': '2'});
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
}
