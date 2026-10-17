import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_http_client.dart';
import '../../../domain/models/drama.dart';
import '../../../domain/models/source_route.dart';
import '../../local/app_store.dart';
import 'hongguo_app_client.dart';
import 'hongguo_media_service.dart';
import 'hongguo_web_fallback.dart';

/// 单条线路的测速结果。
///
/// [message] 是给人看的结论/错误原因（成功时描述拿到的片源，失败时说明原因）；
/// [latencyMs] 即使失败也保留已耗时，方便判断是超时还是立刻被拒绝。
final class SourceRouteCheck {
  const SourceRouteCheck({
    required this.routeId,
    required this.ok,
    required this.latencyMs,
    required this.message,
    required this.testedAt,
  });

  final String routeId;
  final bool ok;
  final int latencyMs;
  final String message;
  final DateTime testedAt;

  String get label => SourceRouteSettings.labelOf(routeId);

  @override
  String toString() =>
      'SourceRouteCheck($routeId, ok: $ok, ${latencyMs}ms, $message)';
}

/// 红果线路设置持久化 + 线路测速 / 健康检测。
///
/// 线路设置写在 [SourceStateStore] 的 `hongguo:routes`（由 SqliteAppStore 落盘），
/// 写入做 350ms 节流：UI 上连续切换开关/首选时只落一次盘，写失败只记日志，
/// 不影响内存中的设置继续生效。
///
/// 测速必须走真实请求：
/// - App 线路：`video_model` 接口（需要 videoId）；
/// - 网页线路：网页 player 页（需要 seriesId + videoId）；
/// - 备用线路：`playbackEndpoint` 备用接口（需要 seriesId + videoId）。
/// 缺少剧集参数时退化为只探测站点连通性（GET 首页/接口）。
final class HongguoRouteService {
  HongguoRouteService(
    this.config,
    this.web,
    this.media,
    this.appClient, {
    this.store,
    this.timeout = const Duration(seconds: 13),
  });

  /// 持久化 key：与需求约定的 `hongguo:routes` 一致。
  static const storageKey = 'hongguo:routes';

  /// 单条线路测速的最长等待时间（AppHttpClient 自身约 12 秒超时，这里兜底）。
  final Duration timeout;
  final SourceConfig config;
  final HongguoWebFallback web;
  final HongguoMediaService media;
  final HongguoAppClient appClient;
  final SourceStateStore? store;

  SourceRouteSettings _settings = SourceRouteSettings.defaults;
  Future<SourceRouteSettings>? _loading;
  Timer? _saveTimer;
  Future<void> _writes = Future.value();
  bool _disposed = false;
  /// 读取磁盘期间用户是否已经改过设置（避免旧磁盘值覆盖新设置）。
  bool _dirty = false;

  /// 当前生效的线路设置（同步读取，未加载前为默认值）。
  SourceRouteSettings get settings => _settings;

  /// 读取持久化设置。只读一次并缓存；读失败回退默认值。
  Future<SourceRouteSettings> load() => _loading ??= _load();

  Future<SourceRouteSettings> _load() async {
    final stateStore = store;
    if (stateStore == null) return _settings = SourceRouteSettings.defaults;
    try {
      final state = await stateStore.readSourceState(storageKey);
      // 读取期间用户可能已经在设置页改了线路：新设置优先，不能被磁盘旧值覆盖。
      if (_dirty) return _settings;
      _settings = SourceRouteSettings.fromJson(state);
    } on Exception catch (error) {
      if (_dirty) return _settings;
      debugPrint('[Routes] 读取线路设置失败，使用默认值: $error');
      _settings = SourceRouteSettings.defaults;
    }
    return _settings;
  }

  /// 更新内存中的设置并节流写盘。
  ///
  /// 调用后立即对后续取流生效（[load] 也会返回新值），磁盘写入在防抖后执行。
  void update(SourceRouteSettings settings) {
    if (_disposed || settings == _settings) return;
    _dirty = true;
    _settings = settings;
    _loading = Future.value(settings);
    final stateStore = store;
    if (stateStore == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), () {
      _saveTimer = null;
      final snapshot = _settings;
      _writes = _writes.then((_) async {
        try {
          await stateStore.saveSourceState(storageKey, snapshot.toJson());
        } catch (error) {
          // 存储失败不能影响播放：设置留在内存里，下次启动回退旧值。
          debugPrint('[Routes] 保存线路设置失败: $error');
        }
      });
    });
  }

  /// 立即把尚未落盘的设置写入存储（退出页面/关闭应用前调用）。
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final stateStore = store;
    if (stateStore == null) return;
    final snapshot = _settings;
    _writes = _writes.then((_) async {
      try {
        await stateStore.saveSourceState(storageKey, snapshot.toJson());
      } catch (error) {
        debugPrint('[Routes] 保存线路设置失败: $error');
      }
    });
    await _writes;
  }

  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    _saveTimer = null;
  }

  /// 测试单条线路。
  ///
  /// [seriesId] / [videoId] 由调用方提供当前剧集或缓存中的任意一集；都为 null
  /// 时退化为只测站点连通性。取消时抛出 [DioException]（与原取流逻辑一致）。
  Future<SourceRouteCheck> testRoute(
    String routeId, {
    String? seriesId,
    String? videoId,
    CancelToken? cancelToken,
  }) {
    switch (routeId) {
      case SourceRouteIds.app:
        return _testApp(videoId: videoId, cancelToken: cancelToken);
      case SourceRouteIds.web:
        return _testWeb(
          seriesId: seriesId,
          videoId: videoId,
          cancelToken: cancelToken,
        );
      case SourceRouteIds.api:
        return _testApi(
          seriesId: seriesId,
          videoId: videoId,
          cancelToken: cancelToken,
        );
      default:
        return Future.value(
          SourceRouteCheck(
            routeId: routeId,
            ok: false,
            latencyMs: 0,
            message: '未知线路',
            testedAt: DateTime.now(),
          ),
        );
    }
  }

  /// 并发测试全部线路；每条线路独立计成功/失败，互不影响。
  ///
  /// 取消统一抛 [DioException]，由调用方忽略。
  Future<Map<String, SourceRouteCheck>> testAll({
    String? seriesId,
    String? videoId,
    CancelToken? cancelToken,
  }) async {
    final results = await Future.wait([
      for (final route in SourceRouteSettings.routes)
        _guardedTest(
          route.id,
          seriesId: seriesId,
          videoId: videoId,
          cancelToken: cancelToken,
        ),
    ]);
    return {for (final result in results) result.routeId: result};
  }

  Future<SourceRouteCheck> _guardedTest(
    String routeId, {
    String? seriesId,
    String? videoId,
    CancelToken? cancelToken,
  }) async {
    try {
      return await testRoute(
        routeId,
        seriesId: seriesId,
        videoId: videoId,
        cancelToken: cancelToken,
      );
    } on DioException {
      if (cancelToken?.isCancelled == true) rethrow;
      return _failure(routeId, 0, '网络请求失败');
    } on AppException catch (error) {
      return _failure(routeId, 0, error.message);
    } on Exception catch (error) {
      return _failure(routeId, 0, '测速失败：$error');
    }
  }

  Future<SourceRouteCheck> _testApp({
    String? videoId,
    CancelToken? cancelToken,
  }) =>
      _measure(
        SourceRouteIds.app,
        () async {
          final appBase = config.appBaseUrl;
          if (appBase == null || !appClient.enabled) {
            throw const AppException('App 接口未配置（缺少 appBaseUrl）');
          }
          if (videoId == null || videoId.isEmpty) {
            // 没有剧集时只验证站点可达：video_model 必须带 video_id。
            await _probeSite(appBase, cancelToken);
            return 'App 站点可达（未提供剧集，仅测连通性）';
          }
          final options = await media.resolve(
            videoId,
            cancelToken: cancelToken,
          );
          final best = options.sources.first;
          return '${options.sources.length} 个画质 · 最高 ${best.quality}';
        },
        cancelToken: cancelToken,
      );

  Future<SourceRouteCheck> _testWeb({
    String? seriesId,
    String? videoId,
    CancelToken? cancelToken,
  }) =>
      _measure(
        SourceRouteIds.web,
        () async {
          if (seriesId == null ||
              seriesId.isEmpty ||
              videoId == null ||
              videoId.isEmpty) {
            await _probeSite(config.baseUrl, cancelToken);
            return '网页站点可达（未提供剧集，仅测连通性）';
          }
          final source = await web.resolveWeb(
            _sampleDrama(seriesId),
            _sampleEpisode(seriesId, videoId),
            cancelToken: cancelToken,
          );
          return '${source.quality} 直链可用';
        },
        cancelToken: cancelToken,
      );

  Future<SourceRouteCheck> _testApi({
    String? seriesId,
    String? videoId,
    CancelToken? cancelToken,
  }) =>
      _measure(
        SourceRouteIds.api,
        () async {
          if (seriesId == null ||
              seriesId.isEmpty ||
              videoId == null ||
              videoId.isEmpty) {
            await _probeSite(config.playbackEndpoint, cancelToken);
            return '备用接口站点可达（未提供剧集，仅测连通性）';
          }
          final options = await web.resolveApi(
            _sampleDrama(seriesId),
            _sampleEpisode(seriesId, videoId),
            cancelToken: cancelToken,
          );
          return '${options.sources.length} 条可用片源';
        },
        cancelToken: cancelToken,
      );

  Future<SourceRouteCheck> _measure(
    String routeId,
    Future<String> Function() probe, {
    CancelToken? cancelToken,
  }) async {
    final watch = Stopwatch()..start();
    try {
      final message = await probe().timeout(timeout);
      cancelToken?.throwIfCancellationRequested();
      return SourceRouteCheck(
        routeId: routeId,
        ok: true,
        latencyMs: watch.elapsedMilliseconds,
        message: message,
        testedAt: DateTime.now(),
      );
    } on TimeoutException {
      return _failure(
        routeId,
        watch.elapsedMilliseconds,
        '测速超时（超过 ${timeout.inSeconds} 秒）',
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error) ||
          (cancelToken?.isCancelled ?? false)) {
        rethrow;
      }
      return _failure(
        routeId,
        watch.elapsedMilliseconds,
        '网络请求失败（${error.type.name}）',
      );
    } on AppException catch (error) {
      return _failure(routeId, watch.elapsedMilliseconds, error.message);
    } on FormatException {
      return _failure(routeId, watch.elapsedMilliseconds, '返回数据格式异常');
    } on Exception catch (error) {
      return _failure(routeId, watch.elapsedMilliseconds, '测速失败：$error');
    }
  }

  SourceRouteCheck _failure(String routeId, int latencyMs, String message) =>
      SourceRouteCheck(
        routeId: routeId,
        ok: false,
        latencyMs: latencyMs,
        message: message,
        testedAt: DateTime.now(),
      );

  /// 站点连通性探测：只要求服务端有响应。
  ///
  /// 站点首页通常返回 404/重定向，客户端会把非 2xx 转成 [AppException]；
  /// 能拿到响应（kind 不是 network）就说明站点可达，只有网络层失败才算不可达。
  Future<void> _probeSite(Uri uri, CancelToken? cancelToken) async {
    try {
      await web.client.getText(uri, cancelToken: cancelToken);
    } on AppException catch (error) {
      if (error.kind == FailureKind.network) rethrow;
    }
  }

  Drama _sampleDrama(String seriesId) => Drama(
    id: 'hongguo:$seriesId',
    source: 'hongguo',
    sourceId: seriesId,
    title: '线路测速',
  );

  Episode _sampleEpisode(String seriesId, String videoId) => Episode(
    id: 'hongguo:$seriesId:$videoId',
    dramaId: 'hongguo:$seriesId',
    sourceEpisodeId: videoId,
    index: 1,
  );
}
