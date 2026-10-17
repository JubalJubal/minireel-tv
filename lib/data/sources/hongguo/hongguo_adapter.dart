import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_http_client.dart';
import '../../../domain/models/catalog_page.dart';
import '../../../domain/models/drama.dart';
import '../../../domain/models/playback_source.dart';
import '../../../domain/models/discovery.dart';
import '../../local/app_store.dart';
import '../source_adapter.dart';
import 'hongguo_app_client.dart';
import 'hongguo_catalog_service.dart';
import 'hongguo_detail_service.dart';
import 'hongguo_media_service.dart';
import 'hongguo_web_fallback.dart';
import 'hongguo_search_service.dart';
import 'hongguo_ranking_service.dart';

final class HongguoAdapter
    implements
        DramaSourceAdapter,
        CursorCatalogSource,
        RoutedPlaybackSource,
        SourceCacheControl,
        RemoteSearchSource,
        RankingSource {
  HongguoAdapter(this.config, this.client, {SourceStateStore? store}) {
    final app = HongguoAppClient(config, client, store: store);
    web = HongguoWebFallback(config, client);
    catalogService = HongguoCatalogService(app, web);
    detailService = HongguoDetailService(app);
    mediaService = HongguoMediaService(app, config);
    searchService = HongguoSearchService(config, client);
    rankingService = HongguoRankingService(config, client);
  }
  final SourceConfig config;
  final TextClient client;
  late final HongguoWebFallback web;
  late final HongguoCatalogService catalogService;
  late final HongguoDetailService detailService;
  late final HongguoMediaService mediaService;
  late final HongguoSearchService searchService;
  late final HongguoRankingService rankingService;

  @override
  Future<SearchResult> searchRemote(
    String keyword, {
    CancelToken? cancelToken,
  }) => searchService.search(keyword, cancelToken: cancelToken);

  @override
  Future<RankingPage> getRanking(
    RankingType type, {
    int page = 1,
    bool refresh = false,
    CancelToken? cancelToken,
  }) => rankingService.load(
    type,
    page: page,
    refresh: refresh,
    cancelToken: cancelToken,
  );

  @override
  void clearTransientCache() {
    detailService.clear();
    searchService.clear();
    rankingService.clear();
    catalogService.webFallbackActive = false;
  }

  @override
  String get id => 'hongguo';
  @override
  String get displayName => '红果剧库';
  @override
  int get maxPages => config.maxPages;
  @override
  int get pageSize => config.pageSize;
  @override
  List<DramaChannel> get catalogChannels => [
    DramaChannel.real,
    DramaChannel.comicDrama,
    DramaChannel.ai,
    if (!catalogService.client.enabled || catalogService.webFallbackActive)
      DramaChannel.animation,
  ];

  @override
  Future<CatalogPage> loadCatalog(
    DramaChannel channel, {
    CatalogCursor cursor = const CatalogCursor(),
    bool refresh = false,
    Set<String> knownIds = const {},
    CancelToken? cancelToken,
  }) => catalogService.load(
    channel,
    cursor,
    refresh: refresh,
    knownIds: knownIds,
    cancelToken: cancelToken,
  );

  // Compatibility for page-based consumers; the repository uses loadCatalog.
  @override
  Future<List<Drama>> fetchCatalog(
    DramaChannel channel,
    int page, {
    CancelToken? cancelToken,
  }) => web.fetchCatalog(channel, page, cancelToken: cancelToken);

  @override
  Future<DramaDetail> fetchDetail(
    Drama drama, {
    CancelToken? cancelToken,
  }) async {
    _validateId(drama.sourceId);
    try {
      return await detailService.getDetail(drama, cancelToken: cancelToken);
    } on AppException {
      cancelToken?.throwIfCancellationRequested();
      return web.fetchDetail(drama, cancelToken: cancelToken);
    }
  }

  @override
  Future<PlaybackOptions> resolvePlayback(
    Drama drama,
    Episode episode, {
    CancelToken? cancelToken,
    bool fallbackOnly = false,
  }) => resolveFrom(
    drama,
    episode,
    start: fallbackOnly ? PlaybackRoute.fallback : PlaybackRoute.app,
    cancelToken: cancelToken,
  );

  @override
  Future<PlaybackOptions> resolveFrom(
    Drama drama,
    Episode episode, {
    PlaybackRoute start = PlaybackRoute.app,
    CancelToken? cancelToken,
  }) async {
    _validateId(drama.sourceId);
    _validateId(episode.sourceEpisodeId);
    if (episode.dramaId != drama.id) {
      throw const AppException('分集信息已失效，请刷新短剧后重试');
    }
    cancelToken?.throwIfCancellationRequested();
    var appError = '';
    if (start == PlaybackRoute.app) {
      try {
        return await mediaService.resolve(
          episode.sourceEpisodeId,
          cancelToken: cancelToken,
        );
      } on AppException catch (error) {
        appError = error.message;
        debugPrint('[Resolve] App 取流失败: ${error.message}');
        cancelToken?.throwIfCancellationRequested();
      }
    }
    try {
      return await web.resolvePlayback(
        drama,
        episode,
        cancelToken: cancelToken,
        fallbackOnly: start == PlaybackRoute.fallback,
      );
    } on AppException catch (error) {
      debugPrint('[Resolve] 网页/备用取流失败: ${error.message}');
      if (appError.isNotEmpty) {
        // 两条链路都失败时把真实原因带回 UI：release 包没有日志，
        // 只显示「本集暂时无法播放」会让真机问题无从定位。
        throw AppException('App 取流：$appError；兜底取流：${error.message}');
      }
      rethrow;
    }
  }

  void _validateId(String id) {
    if (!RegExp(r'^[0-9]{1,32}$').hasMatch(id)) {
      throw const AppException('剧集信息已失效，请刷新后重试');
    }
  }
}
