import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../config/source_config.dart';
import '../errors/app_exception.dart';

extension CancelTokenCheck on CancelToken {
  void throwIfCancellationRequested() {
    if (isCancelled) throw cancelError!;
  }
}

abstract interface class TextClient {
  Future<String> getText(
    Uri uri, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  });
}

abstract interface class SignedJsonClient {
  Future<String> postSignedJson(
    Uri Function() prepareUri,
    String body,
    Map<String, String> Function(Uri) prepareHeaders, {
    CancelToken? cancelToken,
  });
}

final class AppHttpClient implements TextClient, SignedJsonClient {
  AppHttpClient(SourceConfig config, {Dio? dio})
    : _config = config,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: Duration(seconds: config.timeoutSeconds),
              receiveTimeout: Duration(seconds: config.timeoutSeconds),
              sendTimeout: Duration(seconds: config.timeoutSeconds),
              headers: config.headers,
              followRedirects: true,
              maxRedirects: 5,
              responseType: ResponseType.stream,
              validateStatus: (status) => status != null,
            ),
          );

  final SourceConfig _config;
  final Dio _dio;
  static const maxBodyBytes = 20 * 1024 * 1024;

  @override
  Future<String> getText(
    Uri uri, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) => _request(
    () => uri,
    headers: (_) => headers ?? {},
    cancelToken: cancelToken,
  );

  @override
  Future<String> postSignedJson(
    Uri Function() prepareUri,
    String body,
    Map<String, String> Function(Uri) prepareHeaders, {
    CancelToken? cancelToken,
  }) => _request(
    prepareUri,
    body: body,
    headers: prepareHeaders,
    cancelToken: cancelToken,
  );

  Future<String> _request(
    Uri Function() prepareUri, {
    required Map<String, String> Function(Uri) headers,
    String? body,
    CancelToken? cancelToken,
  }) async {
    for (var attempt = 0; attempt < _config.retries; attempt++) {
      cancelToken?.throwIfCancellationRequested();
      Uri? uri;
      try {
        uri = prepareUri();
        final response = await _dio.requestUri<ResponseBody>(
          uri,
          data: body,
          options: Options(
            method: body == null ? 'GET' : 'POST',
            headers: headers(uri),
            // A redirected signed request must be rebuilt and re-signed.
            followRedirects: body == null,
            responseType: ResponseType.stream,
          ),
          cancelToken: cancelToken,
        );
        final responseBody = response.data!;
        final bytes = BytesBuilder(copy: false);
        // Streaming the metadata bounds memory even with an absent/fake length.
        await for (final chunk in responseBody.stream) {
          cancelToken?.throwIfCancellationRequested();
          if (bytes.length + chunk.length > maxBodyBytes) {
            throw const AppException('剧库响应过大，请稍后重试', kind: FailureKind.parsing);
          }
          bytes.add(chunk);
        }
        final text = utf8.decode(bytes.takeBytes(), allowMalformed: true);
        if (text.contains('cf-chl-') || text.contains('<title>Just a moment')) {
          throw const AppException('站点暂时要求浏览器验证，请稍后刷新');
        }
        final status = response.statusCode ?? 0;
        if (status >= 200 && status < 300) return text;
        final retryable = status == 408 || status == 429 || status >= 500;
        if (!retryable || attempt == _config.retries - 1) {
          throw AppException(
            status == 404 ? '暂时没有找到这部短剧' : '剧库暂时无法连接，请稍后重试',
            kind: FailureKind.network,
          );
        }
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) rethrow;
        if (attempt == _config.retries - 1) {
          // 把失败类型和主机带回 UI：release 包没有日志，只显示「网络连接
          // 较慢」会让真机问题无从定位。
          throw AppException(
            '网络连接较慢（${error.type.name} ${uri?.host ?? ''}），请检查网络后重试',
            kind: FailureKind.network,
          );
        }
      }
      // Cancellation also interrupts retry backoff when switching episodes.
      final delay = Future<void>.delayed(
        Duration(milliseconds: 450 * (attempt + 1)),
      );
      if (cancelToken == null) {
        await delay;
      } else {
        await Future.any([delay, cancelToken.whenCancel]);
        cancelToken.throwIfCancellationRequested();
      }
    }
    throw const AppException('网络连接失败', kind: FailureKind.network);
  }

  void close() => _dio.close(force: true);
}
