import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../data/sources/hongguo/hongguo_danmaku_service.dart';

/// 弹幕接口的分页窗口：一次请求覆盖约 30 秒。
const danmakuWindowMs = HongguoDanmakuService.windowMs;

/// 时间轴上限，防御异常的播放位置/时长。
const danmakuMaxDurationMs = HongguoDanmakuService.maxDurationMs;

/// 弹幕飞过整屏的基准时长（8 秒），渲染层会按速度因子缩短。
const danmakuLifetimeMs = 8000;

/// 单集弹幕的时间轴、分页缓存与渲染设置。
///
/// 播放页只负责把播放器状态推进来（[update]）并在 seek 时调用
/// [beginSeek]/[endSeek]；本类负责按 30 秒窗口分页加载、合并时间轴、
/// 维护页缓存与失败节流，并把渲染设置暴露给 `DanmakuOverlay`。
///
/// 时间轴分页策略：
/// * 进入一个尚无边界的播放位置时，按 30 秒对齐拉取第一页；
/// * 当前页的 `nextMs` 距离播放位置不足 [danmakuLifetimeMs] 时预取下一页；
/// * 最多缓存 6 页，超出后丢弃距当前位置最远的页面；
/// * 失败的窗口在 [_failureCooldown] 内不再自动重试，[retry] 可手动重试。
final class DanmakuController extends ChangeNotifier {
  DanmakuController({
    required HongguoDanmakuService service,
    required String seriesId,
    required String videoId,
    void Function()? onChanged,
  }) : _service = service,
       _seriesId = seriesId,
       _videoId = videoId,
       _onChanged = onChanged;

  static const _maxPages = 6;
  static const _failureCooldown = Duration(seconds: 15);
  static final _numericId = RegExp(r'^[0-9]{1,32}$');

  final HongguoDanmakuService _service;

  /// 对外摘要状态（加载中/可见性/设置）变化时回调，便于播放页刷新状态文字；
  /// 逐帧的位置推进不会触发它，避免高频重建整页。
  final void Function()? _onChanged;

  final _pages = <int, HongguoDanmakuPage>{};
  final _failures = <int, DateTime>{};

  String _seriesId;
  String _videoId;
  int _generation = 0;
  int? _pendingStart;
  CancelToken? _request;
  bool _closed = false;
  bool _enabled = true;
  bool _foreground = true;
  bool _playing = false;
  bool _seeking = false;
  int _positionMs = 0;
  int _durationMs = 0;
  double _rate = 1;

  List<HongguoDanmakuItem> _items = const [];
  int _dataRevision = 0;
  int _timelineRevision = 0;
  int _motionRevision = 0;

  double _fontSize = 18;
  double _opacity = .9;
  double _areaRatio = .4;
  double _speedFactor = 1;

  DateTime? _anchorTime;
  int _anchorPosition = 0;
  double _anchorRate = 1;
  bool _anchorMoving = false;

  ({
    int position,
    int duration,
    bool playing,
    double speed,
    bool enabled,
    bool foreground,
  })?
  _lastUpdate;

  /// 本集是否具备弹幕条件（红果弹幕要求纯数字的剧集/分集 id）。
  bool get supported =>
      _numericId.hasMatch(_seriesId) && _numericId.hasMatch(_videoId);

  /// 当前是否应渲染弹幕：开关打开、处于前台、非 seek 中且时间轴有效。
  bool get visible =>
      !_closed &&
      supported &&
      _enabled &&
      _foreground &&
      !_seeking &&
      _durationMs > 0 &&
      _positionMs < _durationMs;

  /// 是否正在播放（弹幕随时间移动）；暂停时为 false，弹幕应保持静止。
  bool get moving => visible && _playing;

  /// 是否有分页窗口请求进行中。
  bool get loading => _pendingStart != null;

  /// 是否存在失败窗口，可由用户手动重试。
  bool get canRetry => visible && _failures.isNotEmpty;

  /// 已加载窗口合并、去重、按时间排序后的弹幕时间轴。
  List<HongguoDanmakuItem> get items => _items;

  /// 供播放页展示的一句话状态。
  String get status {
    if (!supported) return '本集暂不支持弹幕';
    if (!_enabled) return '弹幕已关闭';
    if (canRetry) return '弹幕暂不可用，可重试';
    if (loading && _items.isEmpty) return '正在加载弹幕';
    if (_pages.isNotEmpty) {
      return _items.isEmpty ? '这段暂无弹幕' : '已载入 ${_items.length} 条弹幕';
    }
    if (!_foreground) return '弹幕已暂停';
    if (_durationMs <= 0) return '等待播放';
    if (_positionMs >= _durationMs) return '本集已播完';
    return '正在加载弹幕';
  }

  int get positionMs => _positionMs;
  int get durationMs => _durationMs;

  /// 播放倍速，渲染层用它同步弹幕移动速度。
  double get rate => _rate;

  /// 数据（页/时间轴）版本号，渲染层据此重排。
  int get dataRevision => _dataRevision;

  /// 时间轴版本号：seek/切集/时长变化时递增。
  int get timelineRevision => _timelineRevision;

  /// 运动版本号：需要重新校准弹幕位置时递增。
  int get motionRevision => _motionRevision;

  /// 弹幕字号，默认 18。
  double get fontSize => _fontSize;
  set fontSize(double value) {
    final next = (value.isFinite ? value : _fontSize)
        .clamp(12.0, 32.0)
        .toDouble();
    if (next == _fontSize) return;
    _fontSize = next;
    _resetMotion();
    _notifyState();
  }

  /// 弹幕不透明度，默认 0.9。
  double get opacity => _opacity;
  set opacity(double value) {
    final next = (value.isFinite ? value : _opacity).clamp(0.0, 1.0).toDouble();
    if (next == _opacity) return;
    _opacity = next;
    _notifyState();
  }

  /// 弹幕占屏幕高度的比例，默认 0.4（轨道数 = 高度 * 比例 / 行高）。
  double get areaRatio => _areaRatio;
  set areaRatio(double value) {
    final next = (value.isFinite ? value : _areaRatio)
        .clamp(0.1, 1.0)
        .toDouble();
    if (next == _areaRatio) return;
    _areaRatio = next;
    _resetMotion();
    _notifyState();
  }

  /// 速度因子，默认 1.0；数值越大弹幕飞得越快（飞行时长 = 基准 / 因子）。
  double get speedFactor => _speedFactor;
  set speedFactor(double value) {
    final next = (value.isFinite ? value : _speedFactor)
        .clamp(0.25, 4.0)
        .toDouble();
    if (next == _speedFactor) return;
    _speedFactor = next;
    _resetMotion();
    _notifyState();
  }

  /// 播放页每帧（或播放器事件）推进一次播放器状态。
  ///
  /// [position]/[duration] 来自播放器；[speed] 是播放倍速；
  /// [enabled] 是用户弹幕开关；[foreground] 表示页面是否处于前台。
  /// 关闭开关或切到后台后不再发起请求。
  void update({
    required Duration position,
    required Duration duration,
    required bool playing,
    required double speed,
    required bool enabled,
    required bool foreground,
  }) {
    if (_closed) return;
    final input = (
      position: position.inMilliseconds.clamp(0, danmakuMaxDurationMs).toInt(),
      duration: duration.inMilliseconds,
      playing: playing,
      speed: speed,
      enabled: enabled,
      foreground: foreground,
    );
    // 暂停或页面静止时播放器可能重复上报同一组状态，直接跳过。
    if (_lastUpdate == input) return;
    _lastUpdate = input;

    final wasVisible = visible;
    final wasMoving = moving;
    final previousRate = _rate;
    final nextPosition = input.position;
    final nextDuration = input.duration;
    final now = DateTime.now();
    final elapsed = _anchorTime == null
        ? 0
        : now
              .difference(_anchorTime!)
              .inMilliseconds
              .clamp(0, danmakuMaxDurationMs)
              .toInt();
    final expected =
        _anchorPosition + (_anchorMoving ? elapsed * _anchorRate : 0);
    // 播放器位置与按真实时间推算的位置明显不符时，认为时间轴发生了抖动。
    final drift = !_seeking && (nextPosition - expected).abs() > 600;
    final durationChanged = nextDuration != _durationMs && _durationMs > 0;
    final jumped =
        !_seeking &&
        (nextPosition < _positionMs || nextPosition - _positionMs > 2000);
    final enabledChanged = enabled != _enabled;
    final foregroundChanged = foreground != _foreground;

    _enabled = enabled;
    _foreground = foreground;
    if (durationChanged || jumped || enabledChanged || foregroundChanged) {
      _timelineRevision++;
    }
    if (durationChanged || (enabledChanged && !enabled)) {
      // 时长变化后旧窗口全部失效；关闭弹幕则释放缓存。
      _cancel();
      _pages.clear();
      _failures.clear();
      _rebuildItems();
    } else if (jumped || enabledChanged) {
      _cancel();
    }
    if (!_seeking) _positionMs = nextPosition;
    _durationMs = nextDuration > 0 && nextDuration <= danmakuMaxDurationMs
        ? nextDuration
        : 0;
    _rate = speed.isFinite && speed > 0 ? speed : 1;
    _playing = playing;
    if (wasVisible && !visible) _cancel();
    if (drift ||
        jumped ||
        durationChanged ||
        enabledChanged ||
        foregroundChanged ||
        wasVisible != visible ||
        wasMoving != moving ||
        previousRate != _rate) {
      _resetMotion();
    }
    final stateChanged =
        wasVisible != visible ||
        wasMoving != moving ||
        durationChanged ||
        enabledChanged ||
        foregroundChanged;
    if (stateChanged) {
      _notifyState();
    } else {
      _notify();
    }
    _ensureWindow();
  }

  /// 切换到另一集：清空时间轴与缓存，等下一次 [update] 带来新位置后重新加载。
  void resetForEpisode({required String seriesId, required String videoId}) {
    if (_closed) return;
    if (seriesId == _seriesId && videoId == _videoId) return;
    _seriesId = seriesId;
    _videoId = videoId;
    _cancel();
    _pages.clear();
    _failures.clear();
    _rebuildItems();
    _seeking = false;
    _positionMs = 0;
    _durationMs = 0;
    _lastUpdate = null;
    _timelineRevision++;
    _resetMotion();
    _notifyState();
    _ensureWindow();
  }

  /// 用户开始拖动进度条：暂停渲染并取消在途请求。
  void beginSeek() {
    if (_closed) return;
    _cancel();
    _seeking = true;
    _failures.clear();
    _resetMotion();
    _notifyState();
  }

  /// 拖动结束：以新位置重新对齐分页窗口。
  void endSeek(Duration position) {
    if (_closed) return;
    _seeking = false;
    _timelineRevision++;
    _positionMs = position.inMilliseconds
        .clamp(0, danmakuMaxDurationMs)
        .toInt();
    // 跳得很远时旧页已无意义；附近 seek 保留缓存便于来回拖动。
    final aligned = _positionMs ~/ danmakuWindowMs * danmakuWindowMs;
    final nearby = _pages.keys.any(
      (start) => (start - aligned).abs() <= danmakuWindowMs,
    );
    if (!nearby) {
      _pages.clear();
      _rebuildItems();
    }
    _resetMotion();
    _notifyState();
    _ensureWindow();
  }

  /// 清空失败冷却并立即重试当前窗口。
  void retry() {
    if (_closed || !visible) return;
    _failures.clear();
    _ensureWindow();
    _notifyState();
  }

  void _resetMotion() {
    _motionRevision++;
    _anchorTime = DateTime.now();
    _anchorPosition = _positionMs;
    _anchorRate = _rate;
    _anchorMoving = moving;
  }

  void _cancel() {
    _generation++;
    _pendingStart = null;
    final token = _request;
    _request = null;
    if (token != null && !token.isCancelled) token.cancel();
  }

  HongguoDanmakuPage? _covering(int position) {
    HongguoDanmakuPage? found;
    for (final page in _pages.values) {
      if (page.startMs <= position &&
          position < page.nextMs &&
          (found == null || page.startMs > found.startMs)) {
        found = page;
      }
    }
    return found;
  }

  void _ensureWindow() {
    if (_closed || !visible || !supported || _pendingStart != null) return;
    final page = _covering(_positionMs);
    var start = _positionMs ~/ danmakuWindowMs * danmakuWindowMs;
    // 对齐窗口已缓存却不覆盖当前位置（服务端窗口边界不齐），改为按当前位置请求。
    if (page == null && _pages.containsKey(start)) start = _positionMs;
    if (page != null) {
      final prefetchAt = page.nextMs - danmakuLifetimeMs;
      // 服务端窗口异常偏小时不预取，等播放越过页尾后按位置重新对齐请求，
      // 避免窗口边界异常时连续触发下一页请求。
      final windowTooSmall = page.nextMs - page.startMs < danmakuLifetimeMs;
      if (!moving ||
          windowTooSmall ||
          _positionMs < prefetchAt ||
          page.nextMs >= _durationMs ||
          _covering(page.nextMs) != null) {
        return;
      }
      start = page.nextMs;
    }
    if (start >= _durationMs) return;
    final retryAt = _failures[start];
    if (retryAt != null && DateTime.now().isBefore(retryAt)) return;
    unawaited(_load(start));
  }

  Future<void> _load(int start) async {
    final ticket = _generation;
    final seriesId = _seriesId;
    final videoId = _videoId;
    final duration = _durationMs;
    _pendingStart = start;
    final token = _request = CancelToken();
    _notifyState();
    try {
      final page = await _service.fetch(
        seriesId,
        videoId,
        startMs: start,
        durationMs: duration,
        cancelToken: token,
      );
      if (_closed || ticket != _generation) return;
      if (page.episodeId != videoId ||
          page.startMs != start ||
          page.nextMs <= start ||
          page.nextMs > danmakuMaxDurationMs ||
          page.items.length > HongguoDanmakuService.maxItems ||
          page.items.any(
            (item) => item.timeMs < start || item.timeMs >= page.nextMs,
          )) {
        throw const FormatException('弹幕时间范围无效');
      }
      _pages[start] = page;
      _failures.remove(start);
      final nearest = _pages.keys.toList()
        ..sort(
          (a, b) => (a - _positionMs).abs().compareTo((b - _positionMs).abs()),
        );
      for (final key in nearest.skip(_maxPages)) {
        _pages.remove(key);
      }
      _rebuildItems();
    } on Object catch (error) {
      if (_closed || ticket != _generation) return;
      if (error is DioException && CancelToken.isCancel(error)) return;
      _failures[start] = DateTime.now().add(_failureCooldown);
      while (_failures.length > 8) {
        _failures.remove(_failures.keys.first);
      }
    } finally {
      if (!_closed && ticket == _generation) {
        _request = null;
        _pendingStart = null;
        _notifyState();
        _ensureWindow();
      }
    }
  }

  void _rebuildItems() {
    final unique = <String, HongguoDanmakuItem>{};
    final pages = _pages.values.toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    for (final page in pages) {
      for (final item in page.items) {
        unique.putIfAbsent(item.id, () => item);
      }
    }
    final merged = unique.values.toList()
      ..sort((a, b) {
        final time = a.timeMs.compareTo(b.timeMs);
        return time != 0 ? time : a.id.compareTo(b.id);
      });
    _items = List.unmodifiable(merged);
    _dataRevision++;
  }

  void _notify() {
    if (_closed) return;
    notifyListeners();
  }

  void _notifyState() {
    if (_closed) return;
    _onChanged?.call();
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _cancel();
    super.dispose();
  }
}
