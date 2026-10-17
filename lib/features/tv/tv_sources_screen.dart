import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/theme.dart';
import '../../data/sources/hongguo/hongguo_route_service.dart';
import '../../domain/models/source_route.dart';
import '../sources/source_routes_controller.dart';
import 'tv_focus.dart';

/// TV 端「站源与线路」页面。
///
/// 由 TV 设置页入口 `Navigator.push` 打开（无构造参数）：
/// ```dart
/// Navigator.of(context).push(
///   MaterialPageRoute<void>(builder: (_) => const TVSourcesScreen()),
/// );
/// ```
///
/// 全部交互都通过 [TVFocusable] 行点击完成，不使用 Switch 作为唯一交互：
/// - 红果站源行：点击切换启用/停用；
/// - 每张线路卡片：启用行、首选行、测试行各是一个可聚焦行；
/// - 遥控器返回键由 [TVDpadInterceptor] 兜住（部分电视以 KeyEvent 送入）。
final class TVSourcesScreen extends StatefulWidget {
  const TVSourcesScreen({super.key});

  @override
  State<TVSourcesScreen> createState() => _TVSourcesScreenState();
}

class _TVSourcesScreenState extends State<TVSourcesScreen> {
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
    return TVDpadInterceptor(
      onBack: () => Navigator.of(context).maybePop(),
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(),
                    Expanded(
                      child: !controller.ready
                          ? const Center(child: CircularProgressIndicator())
                          : FocusTraversalGroup(
                              policy: TVFocusTraversalPolicy(),
                              child: ListView(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  0,
                                  20,
                                  32,
                                ),
                                children: [
                                  _group(context, '站源', [
                                    _sourceRow(controller),
                                  ]),
                                  _group(context, '首选线路', [
                                    _autoPreferredRow(controller),
                                  ]),
                                  _group(context, '播放线路', [
                                    for (final route
                                        in SourceRouteSettings.routes)
                                      _routeCard(controller, route),
                                  ]),
                                  _testAllButton(controller),
                                  const SizedBox(height: 10),
                                  Text(
                                    controller.seriesId == null
                                        ? '未找到可用的缓存剧集：测速将只检测站点连通性。'
                                        : '测速使用缓存剧集（series ${controller.seriesId} / '
                                              'video ${controller.videoId}）发起真实请求。',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      height: 1.5,
                                      color: context.muted,
                                    ),
                                  ),
                                  const SizedBox(height: 18),
                                  _notes(),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(14, 16, 20, 14),
    child: Row(
      children: [
        TVFocusable(
          radius: 12,
          onTap: () => Navigator.of(context).maybePop(),
          child: const Padding(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.arrow_back_rounded, size: 26),
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          '站源与线路',
          style: TextStyle(fontSize: 27, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );

  Widget _group(BuildContext context, String title, List<Widget> children) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.muted,
                ),
              ),
            ),
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: context.colors.surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    children[i],
                    if (i < children.length - 1)
                      Divider(
                        height: 1,
                        indent: 56,
                        color: Theme.of(context).dividerColor,
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  Widget _sourceRow(SourceRoutesController controller) => _actionRow(
    icon: Icons.movie_filter_rounded,
    title: '红果剧库',
    subtitle: '红果短剧内容源，提供目录、搜索、详情与三条播放线路',
    value: controller.settings.sourceEnabled ? '已启用' : '已停用',
    highlighted: controller.settings.sourceEnabled,
    autofocus: true,
    onTap: () {
      final enable = !controller.settings.sourceEnabled;
      controller.toggleSource(enable);
    },
  );

  Widget _autoPreferredRow(SourceRoutesController controller) {
    final selected =
        controller.settings.preferredRoute == SourceRouteIds.auto;
    return _actionRow(
      icon: selected
          ? Icons.radio_button_checked
          : Icons.radio_button_unchecked,
      title: '自动顺序',
      subtitle: '按 App 接口 → 网页直链 → 备用接口 的顺序依次尝试',
      value: selected ? '当前首选' : '设为首选',
      highlighted: selected,
      onTap: () => controller.setPreferred(SourceRouteIds.auto),
    );
  }

  Widget _routeCard(SourceRoutesController controller, SourceRouteInfo route) {
    final enabled = controller.settings.isEnabled(route.id);
    final preferred = controller.settings.preferredRoute == route.id;
    final check = controller.checks[route.id];
    final testing = controller.testing.contains(route.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Row(
              children: [
                Icon(
                  _routeIcon(route.id),
                  size: 18,
                  color: enabled ? context.colors.primary : context.muted,
                ),
                const SizedBox(width: 8),
                Text(
                  route.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: enabled ? null : context.muted,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: context.chipColor,
                    borderRadius: BorderRadius.circular(6),
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
              ],
            ),
          ),
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: context.colors.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                _actionRow(
                  icon: enabled
                      ? Icons.toggle_on_rounded
                      : Icons.toggle_off_outlined,
                  title: enabled ? '已启用' : '已停用',
                  subtitle: enabled ? '按 OK 停用这条线路' : '按 OK 启用这条线路',
                  value: enabled ? '点击停用' : '点击启用',
                  highlighted: enabled,
                  onTap: () {
                    if (!controller.toggleRoute(route, !enabled)) {
                      _toast('至少保留一条启用线路');
                    }
                  },
                ),
                Divider(
                  height: 1,
                  indent: 56,
                  color: Theme.of(context).dividerColor,
                ),
                _actionRow(
                  icon: preferred
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  title: preferred ? '当前首选线路' : '设为首选线路',
                  subtitle: '首选线路会排到取流顺序最前面',
                  value: preferred ? '已选' : '点击选择',
                  highlighted: preferred,
                  onTap: () => controller.setPreferred(route.id),
                ),
                Divider(
                  height: 1,
                  indent: 56,
                  color: Theme.of(context).dividerColor,
                ),
                _actionRow(
                  icon: Icons.speed_rounded,
                  title: testing ? '测速中…' : '测试这条线路',
                  subtitle: '发起真实请求，检测可用性与耗时',
                  value: testing ? null : '按 OK 测速',
                  onTap: () => unawaited(controller.testRoute(route.id)),
                ),
                if (check != null) _resultRow(check),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 9, 16, 11),
                  child: Text(
                    route.description,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: context.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultRow(SourceRouteCheck check) {
    final color = check.ok ? context.colors.primary : context.colors.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
      color: color.withValues(alpha: .08),
      child: Row(
        children: [
          Icon(
            check.ok ? Icons.check_circle_rounded : Icons.error_rounded,
            size: 17,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              check.message,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${check.latencyMs} ms · ${_timeLabel(check.testedAt)}',
            style: TextStyle(fontSize: 11.5, color: context.muted),
          ),
        ],
      ),
    );
  }

  Widget _testAllButton(SourceRoutesController controller) {
    final enabled = controller.canTest;
    final child = Container(
      height: 54,
      width: double.infinity,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: enabled
            ? context.colors.primary.withValues(alpha: .16)
            : context.chipColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: enabled
              ? context.colors.primary.withValues(alpha: .45)
              : Colors.transparent,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (controller.testingAll)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              Icons.network_check_rounded,
              size: 21,
              color: enabled ? context.colors.primary : context.muted,
            ),
          const SizedBox(width: 9),
          Text(
            controller.testingAll ? '正在测速…' : '测试全部线路',
            style: TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w600,
              color: enabled ? context.colors.primary : context.muted,
            ),
          ),
        ],
      ),
    );
    if (!enabled) return child;
    return TVFocusable(
      radius: 16,
      scale: 1,
      onTap: () => unawaited(controller.testAll()),
      child: child,
    );
  }

  Widget _actionRow({
    required IconData icon,
    required String title,
    required String subtitle,
    String? value,
    bool highlighted = false,
    bool autofocus = false,
    required VoidCallback onTap,
  }) => TVFocusable(
    radius: 14,
    scale: 1,
    autofocus: autofocus,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          Icon(
            icon,
            size: 22,
            color: highlighted ? context.colors.primary : context.muted,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: highlighted ? context.colors.primary : null,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: context.muted),
                ),
              ],
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: 10),
            Text(
              value,
              style: TextStyle(fontSize: 13.5, color: context.muted),
            ),
          ],
          const SizedBox(width: 6),
          Icon(
            Icons.chevron_right_rounded,
            size: 19,
            color: context.muted.withValues(alpha: .5),
          ),
        ],
      ),
    ),
  );

  Widget _notes() => Container(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
    decoration: BoxDecoration(
      color: context.chipColor,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _noteLine('取流顺序：首选线路优先，其余按 App 接口 → 网页直链 → 备用接口；禁用线路不会尝试，某条失败会自动试下一条。'),
        _noteLine('全部线路失败时，错误信息会合并展示每条线路的失败原因。'),
        _noteLine('测速会发起真实请求（App video_model / 网页 player 页 / 备用接口），默认超时 13 秒。'),
        _noteLine('网页直链最高仅 360P；App 接口画质最完整（常见 1080P）；备用接口仅作兜底。'),
      ],
    ),
  );

  Widget _noteLine(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(fontSize: 12.5, height: 1.5, color: context.muted),
    ),
  );

  void _toast(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        width: 280,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
