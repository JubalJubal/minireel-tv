import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../data/sources/hongguo/hongguo_danmaku_service.dart';
import 'danmaku_controller.dart';

/// 一条已经排布好的滚动弹幕。
final class DanmakuFlight {
  const DanmakuFlight({
    required this.item,
    required this.text,
    required this.lane,
    required this.width,
    required this.lifetimeMs,
  });

  final HongguoDanmakuItem item;
  final String text;

  /// 所在轨道（0 起）。
  final int lane;

  /// 文本宽度 + 左右留白。
  final double width;

  /// 该弹幕从进入到离屏的飞行时长。
  final int lifetimeMs;
}

/// 把时间轴上的一段弹幕排进 [rows] 条轨道，保证同一轨道前后不重叠。
///
/// 算法参考红果 TV 实现：按时间顺序逐条尝试轨道，同轨道的上一条弹幕必须
/// 已经让出足够间距，否则换下一条轨道；所有轨道都挤不下时丢弃该条。
/// [measure] 返回文本宽度（不含留白），由渲染层用 TextPainter 提供。
/// 返回列表按时间升序，同一时刻最多保留 [maxFlightsPerScreen] 条。
List<DanmakuFlight> planDanmaku(
  List<HongguoDanmakuItem> items, {
  required double width,
  required int rows,
  required double Function(String text) measure,
  int lifetimeMs = danmakuLifetimeMs,
  int maxFlightsPerScreen = 30,
}) {
  if (!width.isFinite || width <= 0 || rows < 1 || lifetimeMs <= 0) {
    return const [];
  }
  final laneCount = rows.clamp(1, 12);
  final lanes = List<DanmakuFlight?>.filled(laneCount, null);
  final sorted = items.toList()
    ..sort((a, b) {
      final time = a.timeMs.compareTo(b.timeMs);
      return time != 0 ? time : a.id.compareTo(b.id);
    });
  final seen = <String>{};
  final flights = <DanmakuFlight>[];
  for (final item in sorted) {
    if (item.id.isEmpty || item.text.trim().isEmpty || item.timeMs < 0) {
      continue;
    }
    if (!seen.add(item.id)) continue;
    // 同一屏幕（一个飞行时长窗口）内的活跃弹幕上限。
    final recent = flights.reversed
        .takeWhile((flight) => item.timeMs - flight.item.timeMs < lifetimeMs)
        .length;
    if (recent >= maxFlightsPerScreen) continue;
    final text = item.text.trim();
    final measured = measure(text);
    if (!measured.isFinite || measured < 0) continue;
    final size = measured.ceilToDouble() + 8;
    final lane = lanes.indexWhere((previous) {
      if (previous == null) return true;
      final gap = item.timeMs - previous.item.timeMs;
      if (gap < 0) return false;
      if (gap >= lifetimeMs) return true;
      // 上一条的尾部已经离开右边界 24 像素以上，且新弹幕不会追尾。
      final cleared =
          (width + previous.width) * gap / lifetimeMs - previous.width >= 24;
      final headroom =
          width - (width + size) * (lifetimeMs - gap) / lifetimeMs >= 24;
      return cleared && headroom;
    });
    if (lane < 0) continue;
    final flight = DanmakuFlight(
      item: item,
      text: text,
      lane: lane,
      width: size,
      lifetimeMs: lifetimeMs,
    );
    lanes[lane] = flight;
    flights.add(flight);
  }
  return flights;
}

/// 从已排好的时间轴中挑出 [positionMs] 时刻仍在屏幕上的弹幕。
///
/// [flights] 必须按 `item.timeMs` 升序，[lifetimeMs] 是该批次统一的飞行时长。
/// 返回结果按时间升序，最多 [maxVisible] 条（超出时保留最新进入的）。
List<DanmakuFlight> visibleDanmakuFlights(
  List<DanmakuFlight> flights, {
  required int positionMs,
  required int lifetimeMs,
  int maxVisible = 30,
}) {
  if (flights.isEmpty || lifetimeMs <= 0 || maxVisible <= 0) return const [];
  // 二分找到第一条晚于当前位置的弹幕，再向前回溯一个飞行时长。
  var low = 0;
  var high = flights.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (flights[middle].item.timeMs <= positionMs) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  final visible = <DanmakuFlight>[];
  for (var index = low - 1; index >= 0; index--) {
    final flight = flights[index];
    if (positionMs - flight.item.timeMs >= lifetimeMs) break;
    visible.add(flight);
    if (visible.length >= maxVisible) break;
  }
  return visible.reversed.toList();
}

/// 滚动弹幕层：从右向左飞行、按轨道避让，不拦截手势。
///
/// [controller] 由播放页驱动（见 `DanmakuController.update`），本组件只负责
/// 排布与绘制；[aspectRatio] 用来把弹幕限制在视频画面内；[television] 为
/// true 时用内部 Ticker 推进时间轴，避免电视端播放位置粒度粗导致的抖动。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.controller,
    required this.aspectRatio,
    this.television = false,
  });

  final DanmakuController controller;
  final double aspectRatio;
  final bool television;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

final class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  static const _topInset = 8.0;
  static const _maxRows = 10;
  static const _maxVisible = 30;

  Object? _layout;
  List<DanmakuFlight> _schedule = const [];
  final _measureCache = <String, double>{};
  (double, double)? _measureKey;

  late final Ticker _ticker;
  int _televisionPositionMs = 0;
  int _televisionBaseMs = 0;
  int _televisionTimeline = -1;
  bool _televisionAligned = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final next = _televisionBaseMs + elapsed.inMilliseconds;
      if (next == _televisionPositionMs) return;
      _televisionPositionMs = next;
    });
  }

  @override
  void didUpdateWidget(DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    _resetTelevision();
    _layout = null;
    _schedule = const [];
    _measureCache.clear();
    _measureKey = null;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (!constraints.hasBoundedWidth ||
                  !constraints.hasBoundedHeight ||
                  constraints.maxWidth <= 0 ||
                  constraints.maxHeight <= 0) {
                return const SizedBox.shrink();
              }
              final aspect =
                  widget.aspectRatio.isFinite && widget.aspectRatio > 0
                  ? widget.aspectRatio
                  : 16 / 9;
              final width = math.min(
                constraints.maxWidth,
                constraints.maxHeight * aspect,
              );
              final height = math.min(
                constraints.maxHeight,
                constraints.maxWidth / aspect,
              );
              return Center(
                child: SizedBox(
                  width: width,
                  height: height,
                  child: ClipRect(
                    child: AnimatedBuilder(
                      animation: widget.controller,
                      builder: (context, _) =>
                          _buildFlights(context, width, height),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildFlights(BuildContext context, double width, double height) {
    final controller = widget.controller;
    if (!controller.visible) {
      _resetTelevision();
      _layout = null;
      return const SizedBox.shrink();
    }
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2);
    final fontSize = controller.fontSize;
    final rowHeight = math.max(scaler.scale(fontSize) * 1.5, 1.0);
    final rows = ((height * controller.areaRatio - _topInset) / rowHeight)
        .floor()
        .clamp(1, _maxRows)
        .toInt();
    final lifetimeMs = (danmakuLifetimeMs / controller.speedFactor)
        .round()
        .clamp(1200, 16000)
        .toInt();
    final measureKey = (fontSize, scaler.scale(fontSize));
    if (_measureKey != measureKey) {
      _measureKey = measureKey;
      _measureCache.clear();
    }
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
      color: Colors.white.withValues(alpha: controller.opacity),
      height: 1.2,
      shadows: const [Shadow(color: Color(0x99000000), blurRadius: 2)],
    );
    if (widget.television) _alignTelevision(controller);
    _syncTicker(controller.moving);

    double measure(String text) {
      final cached = _measureCache[text];
      if (cached != null) return cached;
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        textScaler: scaler,
      )..layout();
      final measured = painter.width;
      painter.dispose();
      if (!measured.isFinite || measured <= 0) return 0;
      // 跨集切换时旧文本可能持续累积，超过上限就整体丢弃重测。
      if (_measureCache.length >= 1200) _measureCache.clear();
      _measureCache[text] = measured;
      return measured;
    }

    final layout = (
      controller,
      controller.dataRevision,
      fontSize,
      controller.speedFactor,
      width,
      height,
      rows,
      lifetimeMs,
      scaler,
    );
    if (_layout != layout) {
      _layout = layout;
      _schedule = planDanmaku(
        controller.items,
        width: width,
        rows: rows,
        lifetimeMs: lifetimeMs,
        measure: measure,
      );
    }
    final position = widget.television
        ? _televisionPositionMs
        : controller.positionMs;
    final flights = visibleDanmakuFlights(
      _schedule,
      positionMs: position,
      lifetimeMs: lifetimeMs,
      maxVisible: _maxVisible,
    );
    if (flights.isEmpty) return const SizedBox.shrink();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final flight in flights)
          Positioned(
            key: ValueKey('danmaku-${flight.item.id}'),
            left: 0,
            top: _topInset + flight.lane * rowHeight,
            width: flight.width,
            height: rowHeight,
            child: _DanmakuFlightView(
              flight: flight,
              lifetimeMs: lifetimeMs,
              width: width,
              positionMs: position,
              moving: controller.moving,
              // 电视模式的时间轴由真实时间 Ticker 推进，动画也按 1 倍速同步。
              rate: widget.television ? 1 : controller.rate,
              revision: controller.motionRevision,
              style: style,
              scaler: scaler,
            ),
          ),
      ],
    );
  }

  void _alignTelevision(DanmakuController controller) {
    final drift = (controller.positionMs - _televisionPositionMs).abs();
    if (_televisionAligned &&
        controller.timelineRevision == _televisionTimeline &&
        drift <= 1500) {
      return;
    }
    _televisionAligned = true;
    _televisionTimeline = controller.timelineRevision;
    _televisionPositionMs = controller.positionMs;
    _televisionBaseMs = controller.positionMs;
    if (_ticker.isActive) {
      _ticker.stop();
      _ticker.start();
    }
  }

  void _syncTicker(bool moving) {
    final shouldRun = widget.television && moving;
    if (!shouldRun) {
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    if (_ticker.isActive) return;
    _televisionBaseMs = _televisionPositionMs;
    _ticker.start();
  }

  void _resetTelevision() {
    if (_ticker.isActive) _ticker.stop();
    _televisionAligned = false;
    _televisionTimeline = -1;
    _televisionPositionMs = 0;
    _televisionBaseMs = 0;
  }
}

/// 单条弹幕：内部用 AnimationController 平滑飞行，文本用 RepaintBoundary
/// 缓存，父层重建时只有 Transform 更新，不会反复 layout 文本。
final class _DanmakuFlightView extends StatefulWidget {
  const _DanmakuFlightView({
    required this.flight,
    required this.lifetimeMs,
    required this.width,
    required this.positionMs,
    required this.moving,
    required this.rate,
    required this.revision,
    required this.style,
    required this.scaler,
  });

  final DanmakuFlight flight;
  final int lifetimeMs;
  final double width;
  final int positionMs;
  final bool moving;
  final double rate;
  final int revision;
  final TextStyle style;
  final TextScaler scaler;

  @override
  State<_DanmakuFlightView> createState() => _DanmakuFlightViewState();
}

final class _DanmakuFlightViewState extends State<_DanmakuFlightView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(vsync: this);
  Widget? _label;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_DanmakuFlightView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flight.text != widget.flight.text ||
        oldWidget.style != widget.style ||
        oldWidget.scaler != widget.scaler) {
      _label = null;
    }
    if (oldWidget.lifetimeMs != widget.lifetimeMs ||
        oldWidget.revision != widget.revision ||
        oldWidget.width != widget.width ||
        oldWidget.flight.width != widget.flight.width ||
        oldWidget.flight.item.timeMs != widget.flight.item.timeMs ||
        oldWidget.moving != widget.moving ||
        oldWidget.rate != widget.rate) {
      _sync();
    }
  }

  void _sync() {
    _motion.stop();
    final elapsed = (widget.positionMs - widget.flight.item.timeMs).clamp(
      0,
      widget.lifetimeMs,
    );
    _motion.value = elapsed / widget.lifetimeMs;
    if (!widget.moving || elapsed >= widget.lifetimeMs) return;
    final rate = widget.rate.isFinite && widget.rate > 0 ? widget.rate : 1.0;
    final remaining = widget.lifetimeMs - elapsed;
    _motion.animateTo(
      1,
      duration: Duration(
        microseconds: (remaining * 1000 / rate).round().clamp(1, 60000000),
      ),
      curve: Curves.linear,
    );
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _motion,
      child: _buildLabel(),
      builder: (context, child) => Transform.translate(
        offset: Offset(
          widget.width - (widget.width + widget.flight.width) * _motion.value,
          0,
        ),
        child: child,
      ),
    );
  }

  Widget _buildLabel() {
    final cached = _label;
    if (cached != null) return cached;
    final label = RepaintBoundary(
      child: Text(
        widget.flight.text,
        style: widget.style,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        textScaler: widget.scaler,
      ),
    );
    _label = label;
    return label;
  }
}
