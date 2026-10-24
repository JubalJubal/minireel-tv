import 'package:dio/dio.dart';

import '../../core/errors/app_exception.dart';
import '../../domain/models/drama.dart';
import '../../domain/models/catalog_page.dart';
import '../../domain/models/playback_source.dart';
import '../../domain/models/discovery.dart';

abstract interface class RemoteSearchSource {
  Future<SearchResult> searchRemote(String keyword, {CancelToken? cancelToken});
}

/// 推荐能力（当前只有红果提供）。
abstract interface class RecommendationSource {
  /// 取推荐；[more] 为 false 时重置该频道的推荐状态机重新开始。
  Future<List<Drama>> recommendations(DramaChannel channel, {bool more});
}

/// 搜索词推荐能力（当前只有红果提供）。
abstract interface class SearchSuggestionSource {
  /// 返回与 [query] 前缀相关的联想词（去重，最多 10 条）。
  Future<List<String>> searchSuggestions(String query);
}

abstract interface class RankingSource {
  Future<RankingPage> getRanking(
    RankingType type, {
    int page = 1,
    bool refresh = false,
    CancelToken? cancelToken,
  });
}

abstract interface class SourceCacheControl {
  void clearTransientCache();
}

abstract interface class CursorCatalogSource {
  List<DramaChannel> get catalogChannels;
  Future<CatalogPage> loadCatalog(
    DramaChannel channel, {
    CatalogCursor cursor = const CatalogCursor(),
    bool refresh = false,
    Set<String> knownIds = const {},
    CancelToken? cancelToken,
  });
}

abstract interface class RoutedPlaybackSource {
  Future<PlaybackOptions> resolveFrom(
    Drama drama,
    Episode episode, {
    PlaybackRoute start = PlaybackRoute.app,
    CancelToken? cancelToken,
  });
}

abstract interface class DramaSourceAdapter {
  String get id;
  String get displayName;
  int get maxPages;
  int get pageSize;

  Future<List<Drama>> fetchCatalog(
    DramaChannel channel,
    int page, {
    CancelToken? cancelToken,
  });
  Future<DramaDetail> fetchDetail(Drama drama, {CancelToken? cancelToken});
  Future<PlaybackOptions> resolvePlayback(
    Drama drama,
    Episode episode, {
    CancelToken? cancelToken,
    bool fallbackOnly = false,
  });
}

final class SourceRegistry {
  SourceRegistry(Iterable<DramaSourceAdapter> adapters)
    : _adapters = {for (final adapter in adapters) adapter.id: adapter};

  final Map<String, DramaSourceAdapter> _adapters;
  Iterable<DramaSourceAdapter> get all => _adapters.values;
  DramaSourceAdapter require(String id) =>
      _adapters[id] ?? (throw const AppException('这个剧库暂不可用'));
}
