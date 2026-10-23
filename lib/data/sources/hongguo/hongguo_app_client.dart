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
import 'hongguo_signer.dart';

/// 红果播放接口对 X-Gorgon 系列签名敏感：携带签名会被静默拒绝
/// （HTTP 200 但正文 0 字节）。其余接口必须带签名。
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
    // 播放模型接口偶发空正文（HTTP 200 + 0 字节，服务端风控抖动）：
    // 与参考实现 0.1.23 一致，做一次 250ms 短退避重试。
    if (path == hongguoVideoModelPath && text.isEmpty) {
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
    late DateTime now;
    final signed = path != hongguoVideoModelPath;
    return (transport as SignedJsonClient).postSignedJson(
      () {
        now = DateTime.now();
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
        return config.appBaseUrl!.resolve(path).replace(query: query);
      },
      body,
      (uri) {
        debugPrint(
          '[HongguoApp] POST $path signed=${signed && !comment} '
          'comment=$comment deviceId=${_deviceId.length}字 iid=${_installId.length}字',
        );
        final headers = <String, String>{
          ...config.appHeaders,
          'User-Agent': config.appUserAgent,
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          'X-XS-From-Web': '0',
          'Sdk-Version': '2',
        };
        if (comment) {
          headers['Comment-Source'] = '601';
          headers['Server-Channel'] = '1000';
          headers.addAll(
            signHongguoCommentRequest(uri, now, HongguoCommentNonce.random()),
          );
        } else if (signed) {
          headers.addAll(signHongguoRequest(uri, body, now));
        }
        return headers;
      },
      cancelToken: cancelToken,
    );
  }
}
