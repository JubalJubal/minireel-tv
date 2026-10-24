import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minireel/core/config/source_config.dart';
import 'package:minireel/core/errors/app_exception.dart';
import 'package:minireel/core/network/app_http_client.dart';

class _Transport implements HttpClientAdapter {
  _Transport(this.respond);
  final ResponseBody Function(int) respond;
  int requests = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(++requests);
  @override
  void close({bool force = false}) {}
}

void main() {
  final config = SourceConfig(
    baseUrl: Uri.parse('https://example.invalid'),
    playbackEndpoint: Uri.parse('https://example.invalid/play'),
    referer: '',
    mediaReferer: '',
    retries: 3,
  );

  AppHttpClient clientFor(_Transport transport) => AppHttpClient(
    config,
    dio: Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = transport,
  );

  test('429 fails immediately and surfaces the retry-after hint', () async {
    final transport = _Transport(
      (_) => ResponseBody.fromString('busy', 429, headers: {
        'retry-after': ['90'],
      }),
    );
    final client = clientFor(transport);
    addTearDown(client.close);
    await expectLater(
      client.getText(config.baseUrl),
      throwsA(
        isA<AppException>().having(
          (error) => error.message,
          'message',
          contains('90 秒后重试'),
        ),
      ),
    );
    // 与上游限流契约一致：429 不做短间隔重试。
    expect(transport.requests, 1);
  });

  test('ordinary 4xx errors are not retried', () async {
    final transport = _Transport(
      (_) => ResponseBody.fromString('missing', 404),
    );
    final client = clientFor(transport);
    addTearDown(client.close);
    await expectLater(
      client.getText(config.baseUrl),
      throwsA(isA<AppException>()),
    );
    expect(transport.requests, 1);
  });

  test(
    'cancellation interrupts retry delay and sends no second request',
    () async {
      final transport = _Transport((_) => ResponseBody.fromString('busy', 503));
      final client = clientFor(transport);
      addTearDown(client.close);
      final token = CancelToken();
      final request = client.getText(config.baseUrl, cancelToken: token);
      final assertion = expectLater(request, throwsA(isA<DioException>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel();
      await assertion;
      expect(transport.requests, 1);
    },
  );

  test(
    'streaming response guard rejects oversized bodies without retry',
    () async {
      final chunk = Uint8List(1024 * 1024);
      final transport = _Transport(
        (_) => ResponseBody(Stream.fromIterable(List.filled(21, chunk)), 200),
      );
      final client = clientFor(transport);
      addTearDown(client.close);
      await expectLater(
        client.getText(config.baseUrl),
        throwsA(isA<AppException>()),
      );
      expect(transport.requests, 1);
    },
  );
}
