import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_http_client.dart';
import '../../../core/network/request_cache.dart';
import '../../../domain/models/discovery.dart';
import '../../../domain/models/drama.dart';
import 'hongguo_metadata.dart';
import 'hongguo_parser.dart';

final class HongguoRankingService {
  HongguoRankingService(this.config, this.client);
  final SourceConfig config;
  final TextClient client;
  final _cache = RequestCache<RankingPage>(capacity: 128);
  void clear() => _cache.clear();
  static const _boards = {
    RankingType.hot: (
      path: 'hot-drama',
      key: 'hongguo',
      channel: DramaChannel.real,
    ),
    RankingType.realDrama: (
      path: 'hot-real-drama',
      key: 'real',
      channel: DramaChannel.real,
    ),
    RankingType.comicDrama: (
      path: 'hot-comic-drama',
      key: 'comic',
      channel: DramaChannel.comicDrama,
    ),
    RankingType.aiDrama: (
      path: 'hot-ai-drama',
      key: 'ai',
      channel: DramaChannel.ai,
    ),
  };

  Future<RankingPage> load(
    RankingType type, {
    int page = 1,
    bool refresh = false,
    CancelToken? cancelToken,
  }) {
    if (page < 1 || page > 500) throw const AppException('榜单页码无效');
    if (refresh) _cache.clear(prefix: '${type.name}:');
    return _cache.get('${type.name}:$page', (token) async {
      final uri = config.baseUrl
          .resolve('/rank/${_boards[type]!.path}')
          .replace(queryParameters: {'page': '$page'});
      return parse(await client.getText(uri, cancelToken: token), type, page);
    }, cancelToken: cancelToken);
  }

  RankingPage parse(String html, RankingType type, int page) {
    const failure = AppException('榜单格式或分页已变化，请稍后重试');
    final board = _boards[type]!;
    final route = 'rank_${board.path}/page';
    final loader = objectMap(
      objectMap(const HongguoParser().routerData(html)['loaderData'])[route],
    );
    if (field(loader, ['rankKey']) != board.key ||
        field(loader, ['pageNum']) != '$page') {
      throw failure;
    }
    var content = objectMap(loader['content']);
    if (content.isEmpty) content = _contentFromScripts(html, route);
    final pagination = objectMap(content['pagination']);
    final totalPages = int.tryParse(field(pagination, ['totalPages'])) ?? 0;
    final rows = content['rankList'];
    if (content['isSuccess'] != true ||
        rows is! List ||
        field(pagination, ['pageNum']) != '$page' ||
        totalPages < page ||
        totalPages > 500) {
      throw failure;
    }
    final seen = <String>{};
    final items = <RankingItem>[];
    var previous = (page - 1) * 20;
    for (final value in rows) {
      final row = objectMap(value);
      final id = field(row, ['seriesId', 'id']);
      final oldId = field(row, ['id']);
      final rank = int.tryParse(field(row, ['rank'])) ?? 0;
      final title = field(row, ['title']);
      if (!RegExp(r'^[0-9]{1,32}$').hasMatch(id) ||
          (oldId.isNotEmpty && oldId != id) ||
          title.isEmpty ||
          rank <= previous ||
          rank > page * 20 ||
          !seen.add(id)) {
        throw failure;
      }
      previous = rank;
      final tags = stringList(row['tags']);
      final metric = field(row, ['heatText']);
      items.add(
        RankingItem(
          rank: rank,
          metric: metric,
          drama: Drama(
            id: 'hongguo:$id',
            source: 'hongguo',
            sourceId: id,
            title: title,
            coverUrl: field(row, [
              'series_cover',
              'cover',
              'coverUrl',
              'img',
              'poster',
              'thumb',
              'coverImg',
            ]),
            intro: field(row, ['description']),
            tags: tags,
            category: tags.isEmpty ? '' : tags.first,
            episodeCount: anyList(row['episodeVids']).length,
            channel: board.channel,
            heat: hongguoNumber(metric),
            score: hongguoNumber(field(row, ['scoreText'])),
          ),
        ),
      );
    }
    if (items.isEmpty && page < totalPages) throw failure;
    return RankingPage(
      type: type,
      page: page,
      items: items,
      totalPages: totalPages,
      updatedText: field(loader, ['updatedText']),
    );
  }

  /// 榜单内容不在 loaderData 里（那里是 `content: {}`），而是由页面脚本注入：
  ///
  /// ```html
  /// <script data-script-src="modern-run-window-fn"
  ///         data-fn-name="mergeLoaderData"
  ///         data-fn-args='["rank_hot-drama/page",[{"key":"content",
  ///           "routerDataFnName":"p","routerDataFnArgs":["{...}"]}]]'>
  /// ```
  ///
  /// 更早的版本用的是 `data-fn-name="r"` +
  /// `data-script-src="modern-run-router-data-fn"` 的三参数形式，两种都认。
  Map<String, dynamic> _contentFromScripts(String html, String route) {
    for (final tag in RegExp(
      r'<script\b[^>]*>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(html)) {
      final attrs = _attributes(tag[0]!);
      final Object? decoded;
      try {
        decoded = jsonDecode(attrs['data-fn-args'] ?? 'null');
      } on FormatException {
        continue;
      }
      if (decoded is! List || decoded.isEmpty || decoded[0] != route) {
        continue;
      }

      // 新格式：mergeLoaderData(route, [{key: 'content', routerDataFnArgs: [...]}])
      if (attrs['data-fn-name'] == 'mergeLoaderData' && decoded.length == 2) {
        final entries = decoded[1];
        if (entries is! List) continue;
        for (final entry in entries) {
          final map = objectMap(entry);
          if (field(map, ['key']) != 'content') continue;
          for (final value in anyList(map['routerDataFnArgs'])) {
            if (value is! String || !value.trimLeft().startsWith('{')) {
              continue;
            }
            try {
              final parsed = objectMap(jsonDecode(value));
              if (parsed.isNotEmpty) return parsed;
            } on FormatException {
              continue;
            }
          }
        }
        continue;
      }

      // 旧格式：r(route, 'content', {...})
      if (decoded.length == 3 && decoded[1] == 'content') {
        final parsed = objectMap(decoded[2]);
        if (parsed.isNotEmpty) return parsed;
      }
    }
    return const {};
  }

  Map<String, String> _attributes(String tag) {
    final matches = RegExp(
      r'''([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
    ).allMatches(tag);
    return {
      for (final m in matches)
        m[1]!.toLowerCase(): _unescape(m[2] ?? m[3] ?? ''),
    };
  }

  String _unescape(String text) => text.replaceAllMapped(
    RegExp(r'&(#x[0-9a-fA-F]+|#\d+|quot|apos|amp|lt|gt);'),
    (m) {
      const named = {
        'quot': '"',
        'apos': "'",
        'amp': '&',
        'lt': '<',
        'gt': '>',
      };
      final entity = m[1]!;
      if (named.containsKey(entity)) return named[entity]!;
      final code = entity.startsWith('#x')
          ? int.tryParse(entity.substring(2), radix: 16)
          : int.tryParse(entity.substring(1));
      return code != null && code > 0 && code <= 0x10ffff
          ? String.fromCharCode(code)
          : m[0]!;
    },
  );
}
