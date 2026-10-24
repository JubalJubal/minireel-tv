import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_http_client.dart';
import '../../local/app_store.dart';
import 'hongguo_parser.dart';
import 'hongguo_comment_signer.dart';
import 'hongguo_puresign.dart';

/// 红果 App 接口的完整签名契约（对齐上游 0.1.24）：
/// 除旧版单集播放模型接口外，所有请求必须携带六头签名（x-gorgon /
/// x-khronos / x-ladon / x-argus / x-helios / x-medusa）+ X-SS-STUB +
/// X-SS-Req-Ticket；缺头或签名落到 branch==1 都表现为 HTTP 200 空正文。
const hongguoVideoModelPath = '/novel/player/video_model/v1/';

final class HongguoAppClient {
  HongguoAppClient(this.config, this.transport, {this.store});
  final SourceConfig config;
  final TextClient transport;
  final SourceStateStore? store;
  Future<void>? _identityReady;
  late String _deviceId;
  late String _installId;

  bool get enabled =>
      config.appBaseUrl != null && transport is SignedJsonClient;

  Future<void> _loadIdentity() async {
    final saved = await store?.readSourceState('hongguo:identity');
    String identity(dynamic value) {
      if (value is String && RegExp(r'^[0-9]{1,32}$').hasMatch(value)) {
        return value;
      }
      final random = Random.secure();
      var number = BigInt.zero;
      for (var i = 0; i < 8; i++) {
        number = (number << 8) | BigInt.from(random.nextInt(256));
      }
      return (BigInt.parse('1000000000000000000') +
              number % BigInt.parse('8000000000000000000'))
          .toString();
    }

    _deviceId = identity(saved?['deviceId']);
    _installId = identity(saved?['installId']);
    await store?.saveSourceState('hongguo:identity', {
      'deviceId': _deviceId,
      'installId': _installId,
    });
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> payload, {
    CancelToken? cancelToken,
    bool comment = false,
  }) async {
    if (!enabled) throw const AppException('App 数据源未配置');
    cancelToken?.throwIfCancellationRequested();
    try {
      await (_identityReady ??= _loadIdentity());
    } on Exception {
      _identityReady = null;
      throw const AppException('App 设备信息暂时无法保存', kind: FailureKind.storage);
    }
    cancelToken?.throwIfCancellationRequested();
    var text = await _postOnce(path, payload, cancelToken: cancelToken);
    // 与上游 0.1.24 的空正文契约一致：只有播放模型接口的纯空正文才做
    // 一次 250ms 短退避软重试（目录/详情等读接口不重试，直接走多线路
    // 或报错），总尝试次数封顶 2。
    if (text.isEmpty && path == hongguoVideoModelPath) {
      debugPrint('[HongguoApp] $path 空正文，250ms 后重试');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      cancelToken?.throwIfCancellationRequested();
      text = await _postOnce(path, payload, cancelToken: cancelToken);
    }
    debugPrint('[HongguoApp] $path -> ${text.length}B');
    cancelToken?.throwIfCancellationRequested();
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      final code = field(decoded, [
        'code',
        'Code',
        'status_code',
      ], field(objectMap(decoded['BaseResp']), ['StatusCode']));
      if (code.isNotEmpty && code != '0') {
        throw const AppException('App 接口暂不可用');
      }
      return decoded;
    } on FormatException {
      debugPrint('[HongguoApp] $path 响应非 JSON: ${text.substring(0, text.length.clamp(0, 120))}');
      throw const AppException('App 接口返回格式异常', kind: FailureKind.parsing);
    }
  }

  Future<String> _postOnce(
    String path,
    Map<String, dynamic> payload, {
    CancelToken? cancelToken,
    bool comment = false,
  }) {
    final body = jsonEncode(payload);
    final now = DateTime.now();
    final parameters = {
      ...config.appParameters,
      'device_id': _deviceId,
      'iid': _installId,
      '_rticket': '${now.millisecondsSinceEpoch}',
    };
    final keys = parameters.keys.toList()..sort();
    // Match Go url.Values.Encode; sign this exact ordering and encoding.
    final query = keys
        .map(
          (key) =>
              '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(parameters[key]!)}',
        )
        .join('&');
    var uri = config.appBaseUrl!.resolve(path).replace(query: query);
    final headers = <String, String>{
      ...config.appHeaders,
      'User-Agent': config.appUserAgent,
      'Accept': 'application/json',
      'Content-Type': 'application/json; charset=utf-8',
      'X-XS-From-Web': '0',
      'Sdk-Version': '2',
    };
    final signed = path != hongguoVideoModelPath;
    if (comment) {
      headers['Comment-Source'] = '601';
      headers['Server-Channel'] = '1000';
      headers.addAll(
        signHongguoCommentRequest(uri, now, HongguoCommentNonce.random()),
      );
    } else if (signed) {
      // 六头全签在发送前最后一刻进行：_rticket 可能被 branch 规避抖动，
      // 签名必须与最终发出的请求字节完全一致。
      final signedRequest = signHongguoAppRequest(uri, utf8.encode(body), now);
      uri = signedRequest.uri;
      headers.addAll(signedRequest.headers);
    }
    debugPrint(
      '[HongguoApp] POST $path signed=${signed && !comment} '
      'comment=$comment deviceId=${_deviceId.length}字 iid=${_installId.length}字',
    );
    return (transport as SignedJsonClient).postSignedJson(
      () => uri,
      body,
      (_) => headers,
      cancelToken: cancelToken,
    );
  }
}
