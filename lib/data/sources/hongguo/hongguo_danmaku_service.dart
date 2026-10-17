import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/errors/app_exception.dart';
import 'hongguo_app_client.dart';
import 'hongguo_parser.dart';

/// 一条弹幕。
final class HongguoDanmakuItem {
  const HongguoDanmakuItem({
    required this.id,
    required this.text,
    required this.timeMs,
  });
  final String id;
  final String text;
  final int timeMs;
}

/// 红果弹幕接口按「时间窗口」返回一段弹幕，窗口长度约 30 秒。
final class HongguoDanmakuPage {
  const HongguoDanmakuPage({
    required this.episodeId,
    required this.items,
    required this.startMs,
    required this.nextMs,
    required this.total,
  });
  final String episodeId;
  final List<HongguoDanmakuItem> items;
  final int startMs;
  final int nextMs;
  final int total;
}

/// 弹幕拉取：移植自参考实现 ui_playback_danmaku.go 的接口、解析与限流。
final class HongguoDanmakuService {
  HongguoDanmakuService(this.client);

  final HongguoAppClient client;
  static const windowMs = 30 * 1000;
  static const maxDurationMs = 24 * 60 * 60 * 1000;
  static const maxItems = 90;

  final _cache = <String, ({HongguoDanmakuPage page, DateTime expires})>{};
  final _pending = <String, Future<HongguoDanmakuPage>>{};

  bool get enabled => client.enabled;

  Future<HongguoDanmakuPage> fetch(
    String seriesId,
    String videoId, {
    required int startMs,
    required int durationMs,
    CancelToken? cancelToken,
  }) {
    if (!RegExp(r'^[0-9]{1,32}$').hasMatch(seriesId) ||
        !RegExp(r'^[0-9]{1,32}$').hasMatch(videoId) ||
        startMs < 0 ||
        durationMs <= startMs ||
        durationMs > maxDurationMs) {
      throw const AppException('弹幕请求参数无效');
    }
    final key = '$seriesId:$videoId:$startMs:$durationMs';
    final cached = _cache[key];
    if (cached != null && DateTime.now().isBefore(cached.expires)) {
      return Future.value(cached.page);
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final future = _load(
      seriesId,
      videoId,
      key,
      startMs,
      durationMs,
      cancelToken,
    );
    _pending[key] = future;
    return future.whenComplete(() => _pending.remove(key));
  }

  Future<HongguoDanmakuPage> _load(
    String seriesId,
    String videoId,
    String key,
    int startMs,
    int durationMs,
    CancelToken? cancelToken,
  ) async {
    final result = await client.post(
      '/novel/commentapi/comment/list/$videoId/v1/',
      {
        'comment_source': 601,
        'server_channel': 1000,
        'group_id': videoId,
        'group_type': 30,
        'comment_type': 20,
        'sort': 1,
        'count': maxItems,
        'cursor': '',
        'aid': 8662,
        'compliance_status': 0,
        'business_param': {
          'book_id': seriesId,
          'start_offset_time': startMs,
          'playlet_item_duration': durationMs,
          'need_danmaku_guide_type': [1, 3, 4, 2],
        },
      },
      cancelToken: cancelToken,
      comment: true,
    );
    final page = parse(result, videoId, startMs, durationMs);
    if (_cache.length >= 128) _cache.clear();
    _cache[key] = (
      page: page,
      expires: DateTime.now().add(const Duration(minutes: 5)),
    );
    return page;
  }

  HongguoDanmakuPage parse(
    Map<String, dynamic> result,
    String videoId,
    int start,
    int duration,
  ) {
    final data = objectMap(result['data']);
    final rows = anyList(data['data_list']);
    final next = int.tryParse(
      field(objectMap(data['extra']), ['next_query_danmaku_list_time']),
    );
    if (next == null || next <= start || next > maxDurationMs) {
      throw const AppException('弹幕时间段格式异常', kind: FailureKind.parsing);
    }
    final nextMs = next < duration ? next : duration;
    var total = 0;
    try {
      final cursor = <String, dynamic>{};
      final commonInfo = objectMap(data['common_list_info']);
      final rawCursor = field(commonInfo, ['cursor']);
      if (rawCursor.isNotEmpty && rawCursor.length <= 8192) {
        final decoded = jsonDecode(rawCursor);
        if (decoded is Map<String, dynamic>) cursor.addAll(decoded);
      }
      final count = cursor['danmaku_count'];
      if (count is num && count >= 0) total = count.toInt();
    } on Object {
      total = 0;
    }
    final items = <HongguoDanmakuItem>[];
    final seen = <String>{};
    for (final row in rows) {
      final comment = objectMap(objectMap(row)['comment']);
      final common = objectMap(comment['common']);
      if (field(common, ['group_id']) != videoId ||
          field(common, ['status']) != '1') {
        continue;
      }
      final position = int.tryParse(
        field(objectMap(comment['expand']), ['offset_time']),
      );
      final rawText = field(objectMap(common['content']), ['text']);
      final text = _sanitize(rawText);
      final id = field(comment, ['comment_id']);
      if (position == null ||
          position < start ||
          position >= nextMs ||
          text.isEmpty ||
          id.isEmpty ||
          id.length > 120 ||
          !seen.add(id)) {
        continue;
      }
      final characters = text.runes.toList();
      final clipped = characters.length > 180
          ? '${String.fromCharCodes(characters.take(180))}…'
          : text;
      items.add(HongguoDanmakuItem(id: id, text: clipped, timeMs: position));
      if (items.length == maxItems) break;
    }
    items.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return HongguoDanmakuPage(
      episodeId: videoId,
      items: items,
      startMs: start,
      nextMs: nextMs,
      total: total,
    );
  }

  String _sanitize(String value) => String.fromCharCodes(
    value.trim().runes.map(
      (rune) => rune < 0x20 || rune == 0x7f ? 0x20 : rune,
    ),
  ).trim();
}
