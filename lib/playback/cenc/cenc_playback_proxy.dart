import 'dart:async';
import 'dart:io';
import 'dart:math';
// ignore: unnecessary_import
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../domain/models/playback_source.dart';
import 'cenc_media_source.dart';

/// 本机 127.0.0.1 上的 CENC 解密转发服务：播放器拿到的是明文 MP4 流，
/// 不再依赖播放器自身能不能解 cenc-aes-ctr。移植自参考实现的本地流服务。
final class CencPlaybackProxy {
  CencPlaybackProxy._(this._server) {
    _server.listen(_serve);
  }

  static Future<CencPlaybackProxy> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return CencPlaybackProxy._(server);
  }

  final HttpServer _server;
  final Map<String, _ProxySession> _sessions = {};
  final Random _random = Random.secure();
  bool _disposed = false;

  int get port => _server.port;

  Future<Uri> open(PlaybackSource source) async {
    if (_disposed) {
      throw StateError('播放转发服务已关闭');
    }
    final key = source.contentKey;
    if (key == null || key.length != 16) {
      throw StateError('加密媒体缺少内容密钥');
    }
    final media = CencMediaSource(uri: source.uri, headers: source.headers);
    try {
      await media.ensureIndex();
    } on Object {
      media.close();
      rethrow;
    }
    final token = _nextToken();
    _sessions[token] = _ProxySession(media: media, key: key);
    return Uri.parse('http://127.0.0.1:$port/$token.mp4');
  }

  void release(Uri? url) {
    if (url == null) return;
    final segments = url.pathSegments;
    if (segments.isEmpty) return;
    final name = segments.first;
    final token = name.endsWith('.mp4')
        ? name.substring(0, name.length - 4)
        : name;
    _sessions.remove(token)?.close();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final session in _sessions.values) {
      session.close();
    }
    _sessions.clear();
    _server.close(force: true);
  }

  String _nextToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.isEmpty) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final name = segments.first;
      final token = name.endsWith('.mp4')
          ? name.substring(0, name.length - 4)
          : name;
      final session = _sessions[token];
      if (session == null) {
        response.statusCode = HttpStatus.gone;
        await response.close();
        return;
      }
      final total = session.media.total;
      final range = _parseRange(
        request.headers.value(HttpHeaders.rangeHeader),
        total,
      );
      if (range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$total',
        );
        await response.close();
        return;
      }
      final start = range.start;
      final end = range.end;
      final length = end - start + 1;
      response.statusCode = range.partial
          ? HttpStatus.partialContent
          : HttpStatus.ok;
      response.headers
        ..set(HttpHeaders.contentTypeHeader, 'video/mp4')
        ..set(HttpHeaders.contentLengthHeader, '$length')
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set('X-MiniReel-Media', 'clear-cenc-mp4');
      if (range.partial) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$total',
        );
      }
      response.bufferOutput = false;
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      try {
        await for (final chunk in session.media.read(start, end, session.key)) {
          response.add(chunk);
        }
        await response.close();
      } on Object catch (error) {
        // 响应头已经发出时无法再改状态码，只能中止连接，由播放器重试。
        debugPrint('[Proxy] 媒体转发中断: $error');
        try {
          await response.close();
        } on Object {
          // 客户端已断开。
        }
      }
    } on Object {
      try {
        await response.close();
      } on Object {
        // 客户端已断开。
      }
    }
  }

  static ({int start, int end, bool partial})? _parseRange(
    String? value,
    int total,
  ) {
    if (total <= 0) return null;
    if (value == null || value.isEmpty) {
      return (start: 0, end: total - 1, partial: false);
    }
    final match = RegExp(
      r'^bytes=(\d*)-(\d*)$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final first = match.group(1)!;
    final second = match.group(2)!;
    if (first.isEmpty && second.isEmpty) return null;
    int start;
    int end;
    if (first.isEmpty) {
      final suffix = int.tryParse(second);
      if (suffix == null || suffix <= 0) return null;
      start = total - suffix;
      if (start < 0) start = 0;
      end = total - 1;
    } else {
      start = int.tryParse(first) ?? -1;
      if (start < 0 || start >= total) return null;
      if (second.isEmpty) {
        end = total - 1;
      } else {
        end = int.tryParse(second) ?? -1;
        if (end < start) return null;
        if (end >= total) end = total - 1;
      }
    }
    return (start: start, end: end, partial: true);
  }
}

final class _ProxySession {
  _ProxySession({required this.media, required this.key});

  final CencMediaSource media;
  final Uint8List key;

  void close() => media.close();
}
