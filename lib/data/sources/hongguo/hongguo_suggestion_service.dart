import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_http_client.dart';
import 'hongguo_parser.dart';

/// 一条搜索联想记录。
///
/// [wordType] 为空表示不在上游白名单内（仅作纯文本联想展示）；
/// [videoData] 非空且 series_id 为数字时可用于搜索的「名称检索」路。
final class HongguoSuggestionRecord {
  const HongguoSuggestionRecord({
    required this.name,
    required this.wordType,
    required this.keyword,
    required this.videoData,
  });
  final String name;
  final String wordType;
  final String keyword;
  final Map<String, dynamic> videoData;
}

/// 红果搜索词推荐（对齐上游 provider_hongguo_suggestions.go）。
///
/// `GET {baseUrl}/incent_resource/suggestion?app_id=8662&count=N&query=`
/// 普通网页接口：无需签名，Safari UA + 首页 Referer。缓存 TTL 2 分钟、
/// 容量 128、单飞去重并发 32。
final class HongguoSuggestionService {
  HongguoSuggestionService(this.config, this.client);
  final SourceConfig config;
  final TextClient client;

  static const _defaultCount = 10;
  static const _cacheLimit = 128;
  static const _pendingLimit = 32;
  static const _bodyLimit = 256 * 1024;
  static const _ttl = Duration(minutes: 2);

  /// 上游词型白名单；不在名单内的记录 [HongguoSuggestionRecord.wordType] 为空。
  static const _wordTypes = {
    'short_play_name',
    'short_play_category',
    'common_query',
    'actor_name',
    'short_play_actor',
  };

  final _cache = <String, ({List<HongguoSuggestionRecord> records, DateTime expires})>{};
  final _pending = <String, Future<List<HongguoSuggestionRecord>>>{};

  void clear() {
    _cache.clear();
    _pending.clear();
  }

  Future<List<HongguoSuggestionRecord>> fetch(
    String query, {
    int count = _defaultCount,
    CancelToken? cancelToken,
  }) {
    final keyword = _normalize(query);
    if (keyword == null) return Future.value(const []);
    final cached = _cache[keyword];
    if (cached != null && DateTime.now().isBefore(cached.expires)) {
      return Future.value(cached.records.take(count).toList());
    }
    final pending = _pending[keyword];
    if (pending != null) return pending;
    if (_pending.length >= _pendingLimit) {
      throw const AppException('搜索联想请求较多，请稍后重试');
    }
    final future = _load(keyword, count, cancelToken);
    _pending[keyword] = future;
    return future.whenComplete(() => _pending.remove(keyword));
  }

  Future<List<HongguoSuggestionRecord>> _load(
    String keyword,
    int count,
    CancelToken? cancelToken,
  ) async {
    final uri = config.baseUrl.replace(
      pathSegments: ['', 'incent_resource', 'suggestion'],
      queryParameters: {'app_id': '8662', 'count': '$count', 'query': keyword},
      fragment: '',
    );
    final text = await client.getText(
      uri,
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 '
            'Mobile/15E148 Safari/604.1',
        'Referer': 'https://hongguoduanju.com/',
        'Accept': 'application/json',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      },
      cancelToken: cancelToken,
    );
    if (text.length > _bodyLimit) {
      throw const AppException('搜索联想响应过大');
    }
    final records = parse(text);
    // 与上游一致：仅缓存成功结果；写入前先清理过期项，再近似 LRU 淘汰。
    final now = DateTime.now();
    _cache.removeWhere((_, value) => !now.isBefore(value.expires));
    while (_cache.length >= _cacheLimit) {
      String? oldest;
      DateTime? oldestAt;
      for (final entry in _cache.entries) {
        if (oldestAt == null || entry.value.expires.isBefore(oldestAt)) {
          oldest = entry.key;
          oldestAt = entry.value.expires;
        }
      }
      if (oldest == null) break;
      _cache.remove(oldest);
    }
    _cache[keyword] = (
      records: records,
      expires: now.add(_ttl),
    );
    return records.take(count).toList();
  }

  String? _normalize(String query) {
    final keyword = query.trim();
    if (keyword.isEmpty ||
        keyword.runes.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(keyword)) {
      return null;
    }
    return keyword;
  }

  List<HongguoSuggestionRecord> parse(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const AppException('搜索联想响应格式异常', kind: FailureKind.parsing);
    }
    final root = objectMap(decoded);
    var rows = anyList(root['suggest_list']);
    if (rows.isEmpty) rows = anyList(objectMap(root['data'])['suggest_list']);
    final items = <HongguoSuggestionRecord>[];
    final seen = <String>{};
    for (final row in rows) {
      final map = objectMap(row);
      final name = field(map, ['name']).trim();
      if (name.isEmpty || name.runes.length > 80) continue;
      if (!seen.add(name.toLowerCase())) continue;
      final rawType = field(map, ['word_type']);
      items.add(
        HongguoSuggestionRecord(
          name: name,
          wordType: _wordTypes.contains(rawType) ? rawType : '',
          keyword: field(map, ['keyword']),
          videoData: objectMap(map['video_data']),
        ),
      );
    }
    return items;
  }
}
