import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_http_client.dart';
import '../../../domain/models/catalog_page.dart';
import '../../../domain/models/drama.dart';
import '../../../domain/models/playback_source.dart';
import '../../../domain/models/discovery.dart';
import '../../../domain/models/source_route.dart';
import '../../local/app_store.dart';
import '../source_adapter.dart';
import 'hongguo_app_client.dart';
import 'hongguo_catalog_service.dart';
import 'hongguo_detail_service.dart';
import 'hongguo_media_service.dart';
import 'hongguo_route_service.dart';
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
    appClient = HongguoAppClient(config, client, store: store);
    web = HongguoWebFallback(config, client);
    catalogService = HongguoCatalogService(appClient, web);
    detailService = HongguoDetailService(appClient);
    mediaService = HongguoMediaService(appClient, config);
    searchService = HongguoSearchService(config, client);
    rankingService = HongguoRankingService(config, client);
    routes = HongguoRouteService(
      config,
      web,
      mediaService,
      appClient,
      store: store,
    );
  }
  final SourceConfig config;
  final TextClient client;
  late final HongguoAppClient appClient;
  late final HongguoWebFallback web;
  late final HongguoCatalogService catalogService;
  late final HongguoDetailService detailService;
  late final HongguoMediaService mediaService;
  late final HongguoSearchService searchService;
  late final HongguoRankingService rankingService;

  /// 线路设置与测速服务（持久化 key：`hongguo:routes`）。
  late final HongguoRouteService routes;

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
    // 用户设置随取流即时生效：优先线路前置、禁用线路跳过。
    final settings = await routes.load();
    cancelToken?.throwIfCancellationRequested();
    if (!settings.sourceEnabled) {
      throw const AppException('红果剧库已停用，请在设置中重新启用');
    }
    final order = _attemptOrder(settings, start);
    if (order.isEmpty) {
      throw const AppException('没有可用的播放线路，请在设置中启用至少一条线路');
    }
    final failures = <String, String>{};
    for (final routeId in order) {
      cancelToken?.throwIfCancellationRequested();
      try {
        return await _resolveRoute(
          routeId,
          drama,
          episode,
          cancelToken: cancelToken,
        );
      } on AppException catch (error) {
        // 单条线路失败自动尝试下一条；改用取消/编程错误则立即退出循环。
        cancelToken?.throwIfCancellationRequested();
        failures[SourceRouteSettings.labelOf(routeId)] = error.message;
        debugPrint(
          '[Resolve] ${SourceRouteSettings.labelOf(routeId)} 取流失败: '
          '${error.message}',
        );
      }
    }
    // 单线路失败直接透传原始原因（旧行为）；多线路失败时合并原因，
    // release 包没有日志，合并信息是定位真机问题的唯一线索。
    if (failures.length == 1) {
      throw AppException(failures.values.first);
    }
    throw AppException(
      '取流失败（${failures.entries.map((entry) => '${entry.key}：${entry.value}').join('；')}）',
    );
  }

  /// 按用户设置计算实际尝试顺序。
  ///
  /// - [PlaybackRoute.app]：首选线路优先，其余按默认顺序（app → web → api）；
  /// - [PlaybackRoute.primary]：播放页在 App 线路失败后重试，跳过 App；
  /// - [PlaybackRoute.fallback]：兜底重试，只走备用接口；备用接口被禁用时
  ///   退化为其余非 App 线路，避免用户禁用备用接口后彻底无法恢复播放。
  List<String> _attemptOrder(
    SourceRouteSettings settings,
    PlaybackRoute start,
  ) {
    final all = settings.attemptOrder;
    switch (start) {
      case PlaybackRoute.app:
        return all;
      case PlaybackRoute.primary:
        return [
          for (final id in all)
            if (id != SourceRouteIds.app) id,
        ];
      case PlaybackRoute.fallback:
        if (settings.isEnabled(SourceRouteIds.api)) {
          return const [SourceRouteIds.api];
        }
        return [
          for (final id in all)
            if (id != SourceRouteIds.app) id,
        ];
    }
  }

  Future<PlaybackOptions> _resolveRoute(
    String routeId,
    Drama drama,
    Episode episode, {
    CancelToken? cancelToken,
  }) {
    switch (routeId) {
      case SourceRouteIds.app:
        return mediaService.resolve(
          episode.sourceEpisodeId,
          cancelToken: cancelToken,
          contentType: episode.contentType,
        );
      case SourceRouteIds.web:
        return web
            .resolveWeb(drama, episode, cancelToken: cancelToken)
            .then((source) => PlaybackOptions([source]));
      case SourceRouteIds.api:
        return web.resolveApi(drama, episode, cancelToken: cancelToken);
      default:
        throw AppException('未知播放线路：$routeId');
    }
  }

  void _validateId(String id) {
    if (!RegExp(r'^[0-9]{1,32}$').hasMatch(id)) {
      throw const AppException('剧集信息已失效，请刷新后重试');
    }
  }
}
