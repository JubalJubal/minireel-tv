import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/theme.dart';
import '../../data/sources/hongguo/hongguo_route_service.dart';
import '../../domain/models/source_route.dart';
import '../shared/widgets.dart';
import 'source_routes_controller.dart';

/// 手机端「站源与线路」页面。
///
/// 由设置页入口 `Navigator.push` 打开（无构造参数）：
/// ```dart
/// Navigator.of(context).push(
///   MaterialPageRoute<void>(builder: (_) => const SourcesScreen()),
/// );
/// ```
///
/// 页面展示红果站源开关、三条播放线路的启用/首选/测速，以及取流说明；
/// 设置通过 [HongguoRouteService.update] 节流写入 `hongguo:routes`。
final class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key});

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  SourceRoutesController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final controller = SourceRoutesController(AppScope.read(context));
    _controller = controller;
    unawaited(controller.initialize());
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  String _timeLabel(DateTime time) {
    final now = DateTime.now();
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    final sameDay =
        now.year == time.year && now.month == time.month && now.day == time.day;
    return sameDay ? '今天 $hh:$mm' : '${time.month}/${time.day} $hh:$mm';
  }

  IconData _routeIcon(String id) => switch (id) {
    SourceRouteIds.app => Icons.smartphone_rounded,
    SourceRouteIds.web => Icons.language_rounded,
    _ => Icons.swap_horiz_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 20, 12),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '返回',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: 2),
                    const Text(
                      '站源与线路',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: !controller.ready
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                        children: [
                          _group('站源', [_sourceCard(controller)]),
                          _group('播放线路', [
                            _autoPreferredRow(controller),
                            for (final route in SourceRouteSettings.routes)
                              _routeCard(controller, route),
                          ]),
                          const SizedBox(height: 2),
                          _testAllButton(controller),
                          const SizedBox(height: 10),
                          Text(
                            controller.seriesId == null
                                ? '未找到可用的缓存剧集：测速将只检测站点连通性。'
                                : '测速使用缓存剧集（series ${controller.seriesId} / '
                                      'video ${controller.videoId}）发起真实请求。',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.5,
                              color: context.muted,
                            ),
                          ),
                          const SizedBox(height: 18),
                          _notes(),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _group(String label, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(5, 7, 5, 10),
          child: Text(
            label,
            style: TextStyle(
              color: context.muted,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ...children,
      ],
    ),
  );

  Widget _sourceCard(SourceRoutesController controller) => Material(
    color: context.colors.surface,
    borderRadius: BorderRadius.circular(19),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(15, 12, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.movie_filter_rounded,
                size: 21,
                color: controller.settings.sourceEnabled
                    ? context.colors.primary
                    : context.muted,
              ),
              const SizedBox(width: 11),
              const Expanded(
                child: Text(
                  '红果剧库',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              Switch(
                value: controller.settings.sourceEnabled,
                onChanged: (value) {
                  controller.toggleSource(value);
                  if (!value) {
                    showToast(context, '停用后红果线路不再参与播放，可随时重新启用');
                  }
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              '红果短剧内容源，提供目录、搜索、详情与三条播放线路。关闭后不再用于播放，浏览资料不受影响。',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.55,
                color: context.muted,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _autoPreferredRow(SourceRoutesController controller) {
    final selected =
        controller.settings.preferredRoute == SourceRouteIds.auto;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(19),
        child: InkWell(
          borderRadius: BorderRadius.circular(19),
          onTap: () => controller.setPreferred(SourceRouteIds.auto),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 19,
                  color: selected ? context.colors.primary : context.muted,
                ),
                const SizedBox(width: 11),
                const Expanded(
                  child: Text(
                    '自动顺序',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  'App → 网页 → 备用',
                  style: TextStyle(fontSize: 12.5, color: context.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _routeCard(SourceRoutesController controller, SourceRouteInfo route) {
    final enabled = controller.settings.isEnabled(route.id);
    final preferred = controller.settings.preferredRoute == route.id;
    final check = controller.checks[route.id];
    final testing = controller.testing.contains(route.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(19),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(15, 12, 12, 13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _routeIcon(route.id),
                    size: 20,
                    color: enabled ? context.colors.primary : context.muted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      route.name,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: enabled ? null : context.muted,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: context.chipColor,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      route.qualityHint,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: context.muted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Switch(
                    value: enabled,
                    onChanged: (value) {
                      if (!controller.toggleRoute(route, value)) {
                        showToast(context, '至少保留一条启用线路');
                      }
                    },
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                route.description,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.55,
                  color: context.muted,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => controller.setPreferred(route.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 5,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            preferred
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            size: 18,
                            color: preferred
                                ? context.colors.primary
                                : context.muted,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            preferred ? '当前首选' : '设为首选',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: preferred
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: preferred
                                  ? context.colors.primary
                                  : context.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: testing || controller.testingAll
                        ? null
                        : () => unawaited(controller.testRoute(route.id)),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: testing
                        ? const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.speed_rounded, size: 16),
                    label: Text(
                      testing ? '测速中…' : '测试',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                ],
              ),
              if (check != null) ...[
                const SizedBox(height: 7),
                _checkRow(check),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _checkRow(SourceRouteCheck check) {
    final color = check.ok ? context.colors.primary : context.colors.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            check.ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              check.message,
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${check.latencyMs} ms · ${_timeLabel(check.testedAt)}',
            style: TextStyle(fontSize: 11, color: context.muted),
          ),
        ],
      ),
    );
  }

  Widget _testAllButton(SourceRoutesController controller) => SizedBox(
    width: double.infinity,
    child: FilledButton.icon(
      onPressed: controller.canTest
          ? () => unawaited(controller.testAll())
          : null,
      icon: controller.testingAll
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.network_check_rounded, size: 20),
      label: Text(controller.testingAll ? '正在测速…' : '测试全部线路'),
    ),
  );

  Widget _notes() => Container(
    padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
    decoration: BoxDecoration(
      color: context.chipColor,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _noteLine('取流顺序：首选线路优先，其余按 App 接口 → 网页直链 → 备用接口；禁用线路不会尝试，某条失败会自动试下一条。'),
        _noteLine('全部线路失败时，错误信息会合并展示每条线路的失败原因，便于定位。'),
        _noteLine('测速会发起真实请求（App video_model / 网页 player 页 / 备用接口），默认超时 13 秒。'),
        _noteLine('网页直链最高仅 360P；App 接口画质最完整（常见 1080P）；备用接口仅作兜底。'),
      ],
    ),
  );

  Widget _noteLine(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, height: 1.55, color: context.muted),
    ),
  );
}
