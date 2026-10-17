import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import '../../data/sources/hongguo/hongguo_adapter.dart';
import '../../data/sources/hongguo/hongguo_route_service.dart';
import '../../domain/models/drama.dart';
import '../../domain/models/source_route.dart';

/// 「站源与线路」页面的共享状态。
///
/// 手机端 SourcesScreen 与 TV 端 TVSourcesScreen 都使用本控制器，确保两端的
/// 设置读写、测速参数与结果处理完全一致。页面只负责渲染与遥控器焦点。
final class SourceRoutesController extends ChangeNotifier {
  SourceRoutesController(this.app);

  final AppController app;

  /// 红果适配器；站源未注册时为 null。
  HongguoAdapter? adapter;
  SourceRouteSettings settings = SourceRouteSettings.defaults;

  /// 各线路最近一次测速结果（仅保留本页面生命周期内，不持久化）。
  final Map<String, SourceRouteCheck> checks = {};

  /// 正在测速的线路 id 集合。
  final Set<String> testing = {};
  String? seriesId;
  String? videoId;
  bool testingAll = false;
  bool ready = false;
  bool _disposed = false;
  final Set<CancelToken> _tokens = {};

  bool get busy => testingAll || testing.isNotEmpty;
  bool get canTest => ready && adapter != null && !busy;

  /// 读取线路设置并挑选一部缓存剧集作为真实测速参数。
  Future<void> initialize() async {
    final found = _hongguoOf(app);
    var loaded = SourceRouteSettings.defaults;
    if (found != null) {
      loaded = await found.routes.load();
    }
    final sample = await _findSample(app);
    if (_disposed) return;
    adapter = found;
    settings = loaded;
    seriesId = sample?.$1;
    videoId = sample?.$2;
    ready = true;
    _notify();
  }

  /// 切换线路启用；关闭最后一条启用线路时拒绝并返回 false。
  bool toggleRoute(SourceRouteInfo route, bool enabled) {
    if (!enabled && settings.enabledRoutes.length <= 1) return false;
    _apply(settings.withRouteEnabled(route.id, enabled));
    return true;
  }

  /// 切换站点总开关。
  void toggleSource(bool enabled) =>
      _apply(settings.withSourceEnabled(enabled));

  /// 设置首选线路（[SourceRouteIds.auto] 表示自动顺序）。
  void setPreferred(String routeId) {
    if (settings.preferredRoute == routeId) return;
    _apply(settings.withPreferred(routeId));
  }

  /// 单独测试一条线路。失败不会抛出（取消除外，会被静默忽略）。
  Future<void> testRoute(String routeId) async {
    final service = adapter?.routes;
    if (!ready || service == null || testing.contains(routeId) || testingAll) {
      return;
    }
    final token = CancelToken();
    _tokens.add(token);
    testing.add(routeId);
    _notify();
    try {
      final result = await service.testRoute(
        routeId,
        seriesId: seriesId,
        videoId: videoId,
        cancelToken: token,
      );
      if (_disposed) return;
      checks[routeId] = result;
    } on DioException {
      // 取消（离开页面/切换测试）不展示结果。
    } finally {
      _tokens.remove(token);
      if (!_disposed) {
        testing.remove(routeId);
        _notify();
      }
    }
  }

  /// 并发测试全部线路；单条失败互不影响。
  Future<void> testAll() async {
    final service = adapter?.routes;
    if (!ready || service == null || testingAll) return;
    final token = CancelToken();
    _tokens.add(token);
    testingAll = true;
    testing.addAll(SourceRouteSettings.routes.map((route) => route.id));
    _notify();
    try {
      final results = await service.testAll(
        seriesId: seriesId,
        videoId: videoId,
        cancelToken: token,
      );
      if (_disposed) return;
      checks.addAll(results);
    } on DioException {
      // 取消不展示结果。
    } finally {
      _tokens.remove(token);
      if (!_disposed) {
        testingAll = false;
        testing.clear();
        _notify();
      }
    }
  }

  void _apply(SourceRouteSettings next) {
    if (next == settings) return;
    settings = next;
    final service = adapter?.routes;
    if (service != null) service.update(next);
    _notify();
  }

  HongguoAdapter? _hongguoOf(AppController app) {
    try {
      final source = app.repository.registry.require('hongguo');
      return source is HongguoAdapter ? source : null;
    } on Exception {
      return null;
    }
  }

  /// 从历史/收藏/缓存目录里找一部剧的第一集，作为测速的真实请求参数。
  ///
  /// 找不到时返回 null，测速退化为只检测站点连通性。
  Future<(String, String)?> _findSample(AppController app) async {
    final seen = <String>{};
    final candidates = <Drama>[
      ...app.history.map((record) => record.drama),
      ...app.favorites,
      ...app.repository.catalog,
    ];
    var inspected = 0;
    for (final drama in candidates) {
      if (drama.source != 'hongguo' || !seen.add(drama.id)) continue;
      if (!RegExp(r'^[0-9]{1,32}$').hasMatch(drama.sourceId)) continue;
      inspected++;
      final detail = await app.store.readDetail(drama.id);
      final episode = detail == null || detail.episodes.isEmpty
          ? null
          : detail.episodes.first;
      if (episode != null &&
          RegExp(r'^[0-9]{1,32}$').hasMatch(episode.sourceEpisodeId)) {
        return (drama.sourceId, episode.sourceEpisodeId);
      }
      if (inspected >= 12) break;
    }
    return null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final token in _tokens) {
      token.cancel();
    }
    _tokens.clear();
    final service = adapter?.routes;
    if (service != null) unawaited(service.flush());
    super.dispose();
  }
}
