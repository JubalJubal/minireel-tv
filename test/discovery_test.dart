import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minireel/core/config/source_config.dart';
import 'package:minireel/core/errors/app_exception.dart';
import 'package:minireel/core/network/app_http_client.dart';
import 'package:minireel/core/network/request_cache.dart';
import 'package:minireel/data/repositories/drama_repository.dart';
import 'package:minireel/data/sources/hongguo/hongguo_adapter.dart';
import 'package:minireel/data/sources/hongguo/hongguo_metadata.dart';
import 'package:minireel/data/sources/hongguo/hongguo_ranking_service.dart';
import 'package:minireel/data/sources/hongguo/hongguo_search_service.dart';
import 'package:minireel/data/sources/source_adapter.dart';
import 'package:minireel/domain/models/catalog_order.dart';
import 'package:minireel/domain/models/discovery.dart';
import 'package:minireel/domain/models/drama.dart';
import 'package:minireel/playback/next_episode_prefetch.dart';

import 'support/fakes.dart';

class _TextClient implements TextClient {
  final calls = <Uri>[];
  late Future<String> Function(Uri) respond;
  @override
  Future<String> getText(
    Uri uri, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    calls.add(uri);
    return respond(uri);
  }
}

final _config = SourceConfig(
  baseUrl: Uri.parse('https://example.invalid'),
  playbackEndpoint: Uri.parse('https://example.invalid/play'),
  referer: '',
  mediaReferer: '',
);
String _html(Map<String, dynamic> loaders) =>
    '<script>window._ROUTER_DATA=${jsonEncode({'loaderData': loaders})};</script>';

void main() {
  test(
    'search encodes one path segment, merges concurrent queries, and rejects a mismatched response',
    () async {
      const query = '长/夜 & 光';
      final client = _TextClient()
        ..respond = (_) async => _html({
          'search_(keyword)/page': {
            'isSuccess': true,
            'query': query,
            'totalCount': 7,
            'searchList': [
              for (var i = 0; i < 2; i++)
                {
                  'video_data': {'series_id': '100', 'series_title': '长夜'},
                },
            ],
          },
        });
      final service = HongguoSearchService(_config, client);
      final results = await Future.wait([
        service.search(query),
        service.search(query),
      ]);
      // 双路合并（对齐上游）：网页搜索 + 联想接口的名称检索。
      expect(client.calls, hasLength(2));
      expect(client.calls.first.pathSegments, ['search', query]);
      expect(
        client.calls.last.pathSegments,
        ['incent_resource', 'suggestion'],
      );
      expect(results.first.items, hasLength(1));
      expect(results.first.total, 7);
      await service.search(query);
      expect(client.calls, hasLength(2));
      expect(() => service.search('a' * 81), throwsA(isA<AppException>()));
      expect(
        () => service.parse(
          _html({
            'search_(keyword)/page': {
              'isSuccess': true,
              'query': 'other',
              'searchList': [],
            },
          }),
          query,
        ),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'streamed rankings retain upstream gaps and distinguish heat from views',
    () {
      final service = HongguoRankingService(_config, _TextClient());
      const route = 'rank_hot-drama/page';
      final rows = [
        {
          'id': '100',
          'seriesId': '100',
          'rank': 21,
          'title': '甲 & <乙> "丙"',
          'heatText': '1.2亿热度',
          'scoreText': '评分9.2',
        },
        {'id': '101', 'seriesId': '101', 'rank': 23, 'title': '另一部'},
      ];
      String fixture() {
        final args = jsonEncode([
          route,
          'content',
          {
            'isSuccess': true,
            'rankList': rows,
            'pagination': {'pageNum': 2, 'totalPages': 2},
          },
        ]);
        return '${_html({
          route: {'rankKey': 'hongguo', 'pageNum': 2, 'content': {}},
        })}<script data-fn-name="r" data-script-src="modern-run-router-data-fn" data-fn-args="${const HtmlEscape(HtmlEscapeMode.attribute).convert(args)}"></script>';
      }

      final result = service.parse(fixture(), RankingType.hot, 2);
      expect(result.items.map((item) => item.rank), [21, 23]);
      expect(result.items.first.drama.title, '甲 & <乙> "丙"');
      expect(result.items.first.drama.heat, 120000000);
      expect(result.items.first.drama.views, isNull);
      expect(result.hasMore, false);
      rows[1]['rank'] = 21;
      expect(
        () => service.parse(fixture(), RankingType.hot, 2),
        throwsA(isA<AppException>()),
      );
    },
  );

  test('search persistence does not erase richer cached metadata', () async {
    final store = MemoryStore();
    const previous = Drama(
      id: 'hongguo:100',
      source: 'hongguo',
      sourceId: '100',
      title: '旧标题',
      coverUrl: 'https://image.invalid/cover',
      channel: DramaChannel.comicDrama,
      views: 0,
      heat: 900,
      episodeCount: 80,
    );
    await store.saveCatalog([previous]);
    final client = _TextClient()
      ..respond = (_) async => _html({
        'search_(keyword)/page': {
          'isSuccess': true,
          'query': '新',
          'searchList': [
            {
              'video_data': {'series_id': '100', 'series_title': '新标题'},
            },
          ],
        },
      });
    final repo = DramaRepository(
      SourceRegistry([HongguoAdapter(_config, client)]),
      store,
    );
    addTearDown(repo.dispose);
    await repo.loadCache();
    await repo.searchRemote('新');
    final result = repo.searchLocal('新').single;
    expect(result.coverUrl, previous.coverUrl);
    expect(result.views, 0);
    expect(result.heat, 900);
    expect(result.channel, DramaChannel.comicDrama);
    expect(store.catalog[result.id]!.episodeCount, 80);
  });

  test(
    'zero is sortable and unknown values stay last; dates use the source time zone',
    () {
      final items = [
        const Drama(id: 'unknown', source: 'test', sourceId: '1', title: 'A'),
        const Drama(
          id: 'zero',
          source: 'test',
          sourceId: '2',
          title: 'B',
          views: 0,
        ),
        const Drama(
          id: 'known',
          source: 'test',
          sourceId: '3',
          title: 'C',
          views: 120,
        ),
      ];
      sortCatalog(items, CatalogOrder.views);
      expect(items.map((drama) => drama.id), ['known', 'zero', 'unknown']);
      expect(Drama.fromJson(items.last.toJson()).views, isNull);
      expect(hongguoNumber('9000万热度'), 90000000);
      expect(hongguoNumber('暂无'), isNull);
      expect(
        hongguoOnlineDate({
          'sub_title_list': [
            {'content': '今日上新'},
          ],
        }, now: DateTime.utc(2026, 9, 12, 17)),
        DateTime.utc(2026, 9, 13),
      );
      expect(
        hongguoOnlineDate({
          'sub_title_list': [
            {'content': '2026-02-31上新'},
          ],
        }),
        isNull,
      );
    },
  );

  test('a shared request survives cancellation of only one caller', () async {
    final cache = RequestCache<String>();
    final reply = Completer<String>();
    final token = CancelToken();
    final one = cache.get('key', (_) => reply.future, cancelToken: token);
    final two = cache.get('key', (_) async => 'wrong');
    final cancelled = expectLater(one, throwsA(isA<DioException>()));
    token.cancel();
    await cancelled;
    reply.complete('shared');
    expect(await two, 'shared');
    expect(await cache.get('key', (_) async => 'wrong'), 'shared');
    cache.clear();
  });

  test(
    'prefetch is consumed once and expired or failed resolutions are ignored',
    () async {
      var now = DateTime.utc(2026);
      final prefetch = NextEpisodePrefetch(now: () => now);
      final source = mediaFor(sampleEpisodes.first);
      prefetch.start('one', (_) async => source);
      expect(await prefetch.take('one', CancelToken()), same(source));
      expect(await prefetch.take('one', CancelToken()), isNull);
      prefetch.start('two', (_) async => source);
      now = now.add(const Duration(minutes: 2));
      expect(await prefetch.take('two', CancelToken()), isNull);
      prefetch.start(
        'broken',
        (_) async => throw const AppException('offline'),
      );
      expect(await prefetch.take('broken', CancelToken()), isNull);
      prefetch.clear();
    },
  );
}
