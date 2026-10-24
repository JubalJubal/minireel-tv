import 'package:dio/dio.dart';

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_http_client.dart';
import '../../../core/network/request_cache.dart';
import '../../../domain/models/discovery.dart';
import '../../../domain/models/drama.dart';
import 'hongguo_metadata.dart';
import 'hongguo_parser.dart';
import 'hongguo_suggestion_service.dart';

/// 红果搜索（对齐上游 provider_hongguo_search.go）。
///
/// 双路合并：名称检索借道联想接口（count=50，仅取 word_type 为
/// short_play_name 且 series_id 为数字的记录）+ 网页 `/search/<kw>` 解析；
/// 网页结果在前、名称结果在后，按 ID 去重，再按匹配等级（全等 0 / 前缀
/// 1 / 包含 2 / 分词全命中 3 / 其余 4）稳定排序，同基础名同单位的季号
/// 升序。一次性返回，不翻页。
final class HongguoSearchService {
  HongguoSearchService(this.config, this.client, [HongguoSuggestionService? suggestions])
    : suggestions = suggestions ?? HongguoSuggestionService(config, client);
  final SourceConfig config;
  final TextClient client;
  late final HongguoSuggestionService suggestions;
  final _cache = RequestCache<SearchResult>();
  void clear() {
    _cache.clear();
    suggestions.clear();
  }

  Future<SearchResult> search(String query, {CancelToken? cancelToken}) {
    final keyword = _validated(query);
    return _cache.get(keyword, (token) async {
      Object? pageError;
      var dramas = <Drama>[];
      var total = 0;
      try {
        final uri = config.baseUrl.replace(
          pathSegments: ['', 'search', keyword],
          query: '',
          fragment: '',
        );
        final html = await client.getText(uri, cancelToken: token);
        final page = parse(html, keyword);
        dramas = page.items;
        total = page.total;
      } on AppException catch (error) {
        pageError = error;
      }
      // 名称检索与网页搜索互为备份：一路成功即可给出结果。
      final names = await _nameDramas(keyword, cancelToken);
      if (dramas.isEmpty && names.isEmpty) {
        if (pageError is AppException) throw pageError;
        throw const AppException('搜索未返回有效结果，请稍后重试');
      }
      final merged = <String, Drama>{};
      for (final drama in [...dramas, ...names]) {
        merged.putIfAbsent(drama.id, () => drama);
      }
      hongguoRankSearchResults(merged.values.toList(), keyword);
      final warnings = <String>[];
      if (pageError != null && names.isNotEmpty) {
        warnings.add('红果综合搜索暂不可用，已保留名称匹配结果，可重试');
      }
      return SearchResult(
        items: merged.values.toList(),
        total: total < merged.length ? merged.length : total,
        warnings: warnings,
      );
    }, cancelToken: cancelToken);
  }

  /// 名称检索路：联想接口 count=50，仅保留 short_play_name 且
  /// series_id(_str) 为纯数字的记录；拿不到真实标题的丢弃。
  Future<List<Drama>> _nameDramas(String keyword, CancelToken? cancelToken) async {
    try {
      final records = await suggestions.fetch(keyword, count: 50, cancelToken: cancelToken);
      const parser = HongguoParser();
      final dramas = <Drama>[];
      for (final record in records) {
        if (record.wordType != 'short_play_name') continue;
        final data = record.videoData;
        if (data.isEmpty) continue;
        final drama = parser.dramaFrom(
          {'video_data': data, 'name': record.name, 'keyword': record.keyword},
          hongguoChannel(data),
        );
        if (drama == null) continue;
        if (!RegExp(r'^[0-9]{1,32}$').hasMatch(drama.sourceId)) continue;
        // 没拿到真实标题（标题退化成 ID）的条目没有展示价值。
        if (drama.title == drama.sourceId) continue;
        dramas.add(drama);
      }
      return dramas;
    } on AppException {
      return const [];
    }
  }

  String _validated(String query) {
    final keyword = query.trim();
    if (keyword.isEmpty ||
        keyword.runes.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(keyword)) {
      throw const AppException('请输入 1 至 80 个字符的搜索词');
    }
    return keyword;
  }

  SearchResult parse(String html, String keyword) {
    const parser = HongguoParser();
    final page = parser.loader(parser.routerData(html), [
      'search_(keyword)/page',
      'search_',
    ]);
    final rows = page['searchList'];
    if (page['isSuccess'] != true ||
        rows is! List ||
        field(page, ['query']) != keyword) {
      throw const AppException('搜索未返回有效结果，请稍后重试');
    }
    final items = <String, Drama>{};
    for (final row in rows) {
      final data = objectMap(row);
      if (objectMap(data['video_data']).isEmpty) continue;
      final drama = parser.dramaFrom(data, hongguoChannel(data));
      if (drama != null && RegExp(r'^[0-9]{1,32}$').hasMatch(drama.sourceId)) {
        items[drama.id] = drama;
      }
    }
    if (rows.isNotEmpty && items.isEmpty) {
      throw const AppException('搜索结果暂时无法读取');
    }
    final total = int.tryParse(field(page, ['totalCount'])) ?? items.length;
    return SearchResult(
      items: items.values.toList(),
      total: total < items.length ? items.length : total,
    );
  }
}

/// 标题归一化：小写并去除空白与标点（对应上游 hongguoSearchText）。
String hongguoSearchText(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');

/// 匹配等级：全等 0 / 前缀 1 / 包含 2 / 分词全命中 3 / 其余 4。
int hongguoTitleSearchRank(String title, String query) {
  if (title == query) return 0;
  if (title.startsWith(query)) return 1;
  if (title.contains(query)) return 2;
  final words = query
      .split(RegExp(r'[\s\p{P}\p{S}]+', unicode: true))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) return 4;
  var matches = 0;
  for (final word in words) {
    if (title.contains(hongguoSearchText(word))) matches++;
  }
  return matches == words.length ? 3 : 4;
}

final _seasonRegExp = RegExp(
  r'第\s*([0-9零〇一二两兩三四五六七八九十百]+)\s*([季部])[\p{P}\s]*$',
  unicode: true,
);

/// 标题末尾的季号解析：返回 (基础名, 季号, 单位)；无季号返回 null。
(String, int, String)? hongguoSearchSeason(String title) {
  final match = _seasonRegExp.firstMatch(title);
  if (match == null) return null;
  final season = _seasonNumber(match.group(1)!);
  if (season <= 0 || season > 200) return null;
  return (title.substring(0, match.start), season, match.group(2)!);
}

/// 中文数字解析（对应上游 seasonNumber，上限 200）。
int _seasonNumber(String raw) {
  final arabic = int.tryParse(raw);
  if (arabic != null) return arabic;
  const digits = {
    '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '兩': 2, '三': 3, '四': 4,
    '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
  };
  const units = {'十': 10, '百': 100};
  var total = 0;
  var current = 0;
  for (final char in raw.runes) {
    final text = String.fromCharCode(char);
    if (digits.containsKey(text)) {
      current = digits[text]!;
      continue;
    }
    final unit = units[text];
    if (unit == null) return -1;
    total += current == 0 && unit == 10 ? unit : current * unit;
    current = 0;
    if (total > 200) return -1;
  }
  return total + current;
}

/// 就地按匹配等级稳定排序，同基础名同单位的季号升序。
void hongguoRankSearchResults(List<Drama> dramas, String query) {
  final normalized = hongguoSearchText(query);
  int rankOf(String title) => hongguoTitleSearchRank(
    hongguoSearchText(title),
    normalized,
  );
  dramas.sort((left, right) {
    final rank = rankOf(left.title);
    final rankRight = rankOf(right.title);
    if (rank != rankRight) return rank.compareTo(rankRight);
    final leftSeason = hongguoSearchSeason(left.title);
    final rightSeason = hongguoSearchSeason(right.title);
    if (leftSeason != null &&
        rightSeason != null &&
        leftSeason.$3 == rightSeason.$3 &&
        hongguoSearchText(leftSeason.$1) == hongguoSearchText(rightSeason.$1)) {
      return leftSeason.$2.compareTo(rightSeason.$2);
    }
    return 0;
  });
}
