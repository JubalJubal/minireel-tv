import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minireel/core/config/source_config.dart';
import 'package:minireel/core/network/app_http_client.dart';
import 'package:minireel/data/sources/hongguo/hongguo_ranking_service.dart';
import 'package:minireel/domain/models/discovery.dart';

/// 榜单页面只在 loader 里放了 pageNum / rankKey，真正的 rankList 由
/// `mergeLoaderData` 脚本注入 —— 这段解析一旦跟不上站点改版，热播榜就会
/// 整体报「榜单格式或分页已变化」。用真实页面做夹具锁住它。
class _NoopClient implements TextClient {
  @override
  Future<String> getText(
    Uri uri, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async => '';
}

HongguoRankingService _service() => HongguoRankingService(
  SourceConfig(
    baseUrl: Uri.parse('https://hongguoduanju.com'),
    playbackEndpoint: Uri.parse('https://example.com/api/play'),
    referer: 'https://hongguoduanju.com/',
    mediaReferer: 'https://hongguoduanju.com/',
  ),
  _NoopClient(),
);

void main() {
  test('热播榜：rankList 由 mergeLoaderData 脚本注入时也能解析', () {
    final html = File(
      'test/fixtures/rank_hot_drama.html',
    ).readAsStringSync();
    final page = _service().parse(html, RankingType.hot, 1);

    expect(page.items, isNotEmpty, reason: '应解析出榜单条目');
    expect(page.totalPages, greaterThan(0));
    expect(page.items.first.rank, 1);
    expect(page.items.first.drama.title, isNotEmpty);
    expect(page.items.first.drama.sourceId, matches(RegExp(r'^\d+$')));
    expect(page.items.first.drama.coverUrl, isNotEmpty);
    expect(page.items.first.drama.tags, isNotEmpty);
    // 榜单名次必须连续递增
    for (var i = 1; i < page.items.length; i++) {
      expect(page.items[i].rank, greaterThan(page.items[i - 1].rank));
    }
  });
}
