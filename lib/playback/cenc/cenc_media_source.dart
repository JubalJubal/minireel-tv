import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'cenc_mp4.dart';

/// 通过 HTTP Range 读取远端 CENC MP4：解析 moov 里的加密索引，并按字节区间
/// 解密后交给本地播放器。移植自参考实现 app_stream.go / app_stream_cenc.go
/// 的读取模型，只保留顺序播放需要的部分。
final class CencMediaSource {
  CencMediaSource({
    required this.uri,
    required this.headers,
    this.timeout = const Duration(seconds: 20),
  });

  final Uri uri;
  final Map<String, String> headers;
  final Duration timeout;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 20);
  CencMp4Index? _index;
  Future<CencMp4Index>? _indexing;
  int _total = 0;
  bool _closed = false;

  int get total => _total;
  bool get closed => _closed;

  Future<CencMp4Index> ensureIndex() {
    final ready = _index;
    if (ready != null) return Future.value(ready);
    return _indexing ??= _loadIndex().then((value) {
      _index = value;
      return value;
    }).catchError((Object error) {
      _indexing = null;
      throw error;
    });
  }

  Future<CencMp4Index> _loadIndex() async {
    await _bytes(0, 1);
    if (_total < 8 || _total > 64 << 30) {
      throw const CencFormatException('媒体文件大小异常，无法安全转发');
    }
    final prefixLength = min(64 << 10, _total);
    final prefix = await _bytes(0, prefixLength);
    var offset = 0;
    for (var boxes = 0; offset < _total && boxes < 256; boxes++) {
      final headerLength = min(16, _total - offset);
      if (headerLength < 8) {
        throw const CencFormatException('MP4 头部结构异常');
      }
      final header = offset + headerLength <= prefix.length
          ? Uint8List.sublistView(prefix, offset, offset + headerLength)
          : await _bytes(offset, headerLength);
      final view = ByteData.sublistView(header);
      var size = view.getUint32(0);
      var headerSize = 8;
      if (size == 1) {
        if (header.length < 16) {
          throw const CencFormatException('MP4 头部结构异常');
        }
        size = view.getUint64(8);
        headerSize = 16;
      }
      if (size == 0) size = _total - offset;
      if (size < headerSize || size > _total - offset) {
        throw const CencFormatException('MP4 头部结构异常');
      }
      final kind = String.fromCharCodes(header.sublist(4, 8));
      if (kind == 'moof') {
        throw const CencFormatException('分片 MP4 暂不支持安全转发');
      }
      if (kind == 'moov') {
        if (size > cencMetadataLimit) {
          throw const CencFormatException('MP4 元数据过大');
        }
        final moov = offset + size <= prefix.length
            ? Uint8List.sublistView(prefix, offset, offset + size)
            : await _bytes(offset, size);
        return CencMp4Index.parse(moov, offset, _total);
      }
      offset += size;
    }
    throw const CencFormatException('MP4 中找不到 moov 元数据');
  }

  Future<Uint8List> _bytes(int offset, int length) async {
    final response = await _request(offset, offset + length - 1);
    final builder = BytesBuilder(copy: false);
    final completer = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    void finish([Object? error, StackTrace? stack]) {
      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(error, stack);
      } else {
        completer.complete();
      }
    }

    subscription = response.listen(
      (chunk) {
        builder.add(chunk);
        if (builder.length >= length) {
          unawaited(subscription?.cancel());
          finish();
        }
      },
      onError: (Object error, StackTrace stack) => finish(error, stack),
      onDone: finish,
      cancelOnError: true,
    );
    await completer.future;
    if (builder.length < length) {
      throw const CencFormatException('媒体读取不完整');
    }
    final bytes = builder.takeBytes();
    return bytes.length == length
        ? bytes
        : Uint8List.sublistView(bytes, 0, length);
  }

  Future<HttpClientResponse> _request(int start, int end) async {
    if (_closed) throw StateError('媒体会话已关闭');
    final request = await _client.getUrl(uri).timeout(timeout);
    headers.forEach((key, value) => request.headers.set(key, value));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close().timeout(timeout);
    final range = _parseContentRange(
      response.headers.value(HttpHeaders.contentRangeHeader),
    );
    if (range != null && range.total > 0) _total = range.total;
    if (response.statusCode == HttpStatus.partialContent) return response;
    if (response.statusCode == HttpStatus.ok && start == 0) {
      final length = response.contentLength;
      if (length > 0) _total = length;
      return response;
    }
    await response.drain<void>().catchError((Object _) {});
    if (response.statusCode == HttpStatus.ok) {
      throw const CencFormatException('媒体服务器不支持分段读取');
    }
    throw CencFormatException('媒体读取失败（HTTP ${response.statusCode}）');
  }

  /// 从 [start] 到 [end]（含）的明文流，供本地代理边读边发。
  Stream<List<int>> read(int start, int end, Uint8List key) {
    late StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    controller = StreamController<List<int>>(
      onListen: () async {
        try {
          final index = await ensureIndex();
          if (start < 0 || end < start || end >= index.total) {
            throw const CencFormatException('媒体区间无效');
          }
          final response = await _request(start, end);
          var position = start;
          subscription = response.listen(
            (chunk) {
              if (position > end || controller.isClosed) return;
              var bytes = chunk is Uint8List
                  ? Uint8List.fromList(chunk)
                  : Uint8List.fromList(chunk);
              final room = end - position + 1;
              if (bytes.length > room) {
                bytes = Uint8List.sublistView(bytes, 0, room);
              }
              index.transform(bytes, position, key);
              position += bytes.length;
              controller.add(bytes);
              if (position > end) {
                unawaited(subscription?.cancel());
                unawaited(controller.close());
              }
            },
            onError: (Object error, StackTrace stack) {
              controller.addError(error, stack);
              unawaited(controller.close());
            },
            onDone: () => unawaited(controller.close()),
            cancelOnError: true,
          );
        } on Object catch (error, stack) {
          controller.addError(error, stack);
          await controller.close();
        }
      },
      onCancel: () async {
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }

  static ({int start, int end, int total})? _parseContentRange(String? value) {
    if (value == null) return null;
    final match = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+)').firstMatch(value);
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    final total = int.tryParse(match.group(3)!);
    if (start == null || end == null || total == null) return null;
    return (start: start, end: end, total: total);
  }
}
