import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app/theme.dart';
import '../../app/platform.dart';
import '../../domain/models/drama.dart';
import '../tv/tv_focus.dart';

int dramaColumns(double width) => isWindowsDesktop
    ? ((width - 28) / 190).floor().clamp(2, 10)
    : isMacOSDesktop
    ? ((width - 48) / 185).floor().clamp(3, 8)
    : isAndroidTV
    ? ((width - 28) / 175).floor().clamp(4, 8)
    : width >= 1100
    ? 5
    : width >= 800
    ? 4
    : width >= 600
    ? 3
    : 2;

String formatTime(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 359999);
  final minutes = seconds ~/ 60;
  return '${minutes.toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String relativeTime(DateTime time) {
  final elapsed = DateTime.now().difference(time);
  if (elapsed.inMinutes < 1) return '刚刚';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes} 分钟前';
  if (elapsed.inDays < 1) return '${elapsed.inHours} 小时前';
  if (elapsed.inDays < 7) return '${elapsed.inDays} 天前';
  return '${time.month}月${time.day}日';
}

void showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 38});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    padding: EdgeInsets.all(size * .13),
    decoration: BoxDecoration(
      color: const Color(0xFF101318),
      borderRadius: BorderRadius.circular(size * .3),
    ),
    child: Image.asset(
      'assets/logo.png',
      fit: BoxFit.contain,
      excludeFromSemantics: true,
    ),
  );
}

class CoverImage extends StatefulWidget {
  const CoverImage({super.key, required this.drama, this.fit = BoxFit.cover});
  final Drama drama;
  final BoxFit fit;
  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  // 部分封面 CDN（如推荐流的 p3-reading-sign.fqnovelpic.com）会拒绝
  // 非浏览器 UA；首次失败后去掉自定义 UA 重试一次。
  bool _retryWithoutHeaders = false;

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.drama.coverUrl != widget.drama.coverUrl) {
      _retryWithoutHeaders = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget placeholder() => ColoredBox(
      color: context.colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          size: 32,
          color: context.muted.withValues(alpha: .45),
        ),
      ),
    );
    final url = widget.drama.coverUrl;
    if (url.isEmpty || url.contains('.heic')) return placeholder();
    // TV/低端设备性能优化：按显示尺寸解码，避免把原图整张解码进内存。
    final useCacheWidth = defaultTargetPlatform != TargetPlatform.macOS;
    return Image.network(
      url,
      fit: widget.fit,
      cacheWidth: useCacheWidth ? 350 : null,
      headers: _retryWithoutHeaders
          ? null
          : const {
              'User-Agent':
                  'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) '
                  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 '
                  'Mobile/15E148 Safari/604.1',
            },
      excludeFromSemantics: true,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) {
        if (!_retryWithoutHeaders) {
          _retryWithoutHeaders = true;
          scheduleMicrotask(() {
            if (mounted) setState(() {});
          });
          return placeholder();
        }
        return placeholder();
      },
      frameBuilder: (context, child, frame, synchronous) =>
          synchronous || frame != null ? child : placeholder(),
    );
  }
}

class DramaCard extends StatelessWidget {
  const DramaCard({
    super.key,
    required this.drama,
    required this.onTap,
    this.onLongPress,
    this.favorite = false,
    this.aspectRatio = .68,
    this.fixedTitleHeight,
    this.selected = false,
    this.selecting = false,
    this.footer,
    this.subtitle,
    this.interactive = true,
  });
  final Drama drama;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool favorite;
  final double aspectRatio;
  /// 标题区固定高度：TV 网格为对齐卡片高度而传入。
  /// 为 null 时标题区按内容自适应（保持原有行为）。
  final double? fixedTitleHeight;
  /// 卡片副标题（覆盖 [Drama.subtitle]）：TV 网格用它显示题材标签，
  /// 取代默认的「集数 · 分类」。
  final String? subtitle;
  final bool selected;
  final bool selecting;
  final Widget? footer;
  /// 是否响应触摸点击。TV 版由外层 TVFocusable 接管点击时设为 false，
  /// InkWell 仅保留水波纹视觉，不再独立触发 onTap（避免双重点击）。
  final bool interactive;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '${drama.title}，${drama.episodeLabel}',
    child: Material(
      color: context.colors.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: interactive ? onTap : null,
        onLongPress: interactive ? onLongPress : null,
        onSecondaryTap: interactive && isWindowsDesktop ? onLongPress : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cover(drama, context),
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 8, 9, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _titleBlock(context, drama.title),
                  const SizedBox(height: 4),
                  Text(
                    subtitle ?? drama.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: context.muted),
                  ),
                  if (footer != null) ...[const SizedBox(height: 7), footer!],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// 标题块。[fixedTitleHeight] 非空时固定高度，让 TV 网格里
  /// 单行标题与双行标题占用同样的空间，卡片高度完全对齐。
  Widget _titleBlock(BuildContext context, String title) {
    const style = TextStyle(
      fontSize: 13.5,
      height: 1.35,
      fontWeight: FontWeight.w600,
    );
    // 默认：最多两行，超出自动截断
    final text = Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (fixedTitleHeight == null) return text;
    final aligned = Align(alignment: Alignment.topLeft, child: text);
    // TV 网格：标题区固定两行高度；卡片获得焦点时改成单行跑马灯循环滚动，
    // 让被截断的完整标题能读全；失焦后回到两行截断。
    final focusNode = Focus.maybeOf(context);
    if (focusNode == null) {
      return SizedBox(height: fixedTitleHeight, child: aligned);
    }
    return SizedBox(
      height: fixedTitleHeight,
      child: ListenableBuilder(
        listenable: focusNode,
        builder: (context, _) => focusNode.hasFocus
            ? Align(
                alignment: Alignment.centerLeft,
                child: _MarqueeTitle(text: title, style: style),
              )
            : aligned,
      ),
    );
  }

  /// 封面区。普通布局按 [aspectRatio] 固定比例；TV 网格
  /// （[fixedTitleHeight] 非空）改用 Expanded 填满格子剩余高度，
  /// 卡片高度完全由网格统一决定，内部不会出现空白。
  Widget _cover(Drama drama, BuildContext context) {
    final Widget cover = Stack(
      fit: StackFit.expand,
      children: [
        CoverImage(drama: drama),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 72,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0x99000000)],
              ),
            ),
          ),
        ),
        Positioned(
          left: 7,
          bottom: 7,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 142),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: drama.releaseStatus == ReleaseStatus.ongoing
                  ? context.colors.primary
                  : Colors.white.withValues(alpha: .23),
            ),
            child: Text(
              drama.episodeLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        if (favorite || selecting)
          Positioned(
            right: 7,
            top: 7,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: selected ? context.colors.primary : Colors.black38,
                shape: BoxShape.circle,
              ),
              child: Icon(
                selecting
                    ? (selected ? Icons.check_rounded : Icons.circle_outlined)
                    : Icons.favorite_rounded,
                color: selecting ? Colors.white : context.colors.primary,
                size: 14,
              ),
            ),
          ),
      ],
    );
    if (fixedTitleHeight != null) return Expanded(child: cover);
    return AspectRatio(aspectRatio: aspectRatio, child: cover);
  }
}

/// 单行跑马灯标题：文字超出可用宽度时循环横向滚动，读全被截断的标题。
///
/// 只在卡片获得焦点时使用；失焦仍是普通两行截断，避免整屏同时滚动。
class _MarqueeTitle extends StatefulWidget {
  const _MarqueeTitle({required this.text, required this.style});
  final String text;
  final TextStyle style;

  @override
  State<_MarqueeTitle> createState() => _MarqueeTitleState();
}

class _MarqueeTitleState extends State<_MarqueeTitle>
    with SingleTickerProviderStateMixin {
  /// 每帧推进的逻辑像素（60fps 下约 60 px/s），以及两段文字的间隔。
  static const double _stepPerFrame = 1.0;
  static const double _gap = 56;

  late final Ticker _ticker;
  double _dx = 0;
  double _textWidth = 0;

  @override
  void initState() {
    super.initState();
    // 用 Ticker 按帧直接推进偏移。原来用 AnimationController.repeat()
    // 在 TV 环境上会停住不推进，标题卡在某个固定偏移，后半段永远露不出来。
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    if (_textWidth <= 0) return;
    final cycle = _textWidth + _gap;
    // 按帧推进，而不是按 elapsed 算时间：模拟器 / 部分 TV 盒子上 frame
    // callback 的 elapsed 长时间不前进（UI 被 throttle），按时间算的话
    // 标题每秒只挪几个像素，看起来就是「跑马灯没生效、后半段看不到」。
    setState(() {
      _dx -= _stepPerFrame;
      // 滚完一整段后回到起点，无缝循环
      if (_dx <= -cycle) _dx += cycle;
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Widget _text() => Text(
    widget.text,
    maxLines: 1,
    softWrap: false,
    style: widget.style,
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        maxLines: 1,
        textDirection: Directionality.of(context),
      )..layout();
      _textWidth = painter.width;
      if (_textWidth <= constraints.maxWidth) {
        // 放得下就不滚，静止显示
        return _text();
      }
      final cycle = _textWidth + _gap;
      final dx = _dx.clamp(-cycle, 0.0);
      // 用 OverflowBox 让 Row 取自然宽度（两份文字 + 间隔），再整体平移，
      // 由外层 ClipRect 裁到容器宽。不能用 Stack 装这两份文字：它的尺寸
      // 要么被文字撑开、要么被 SizedBox 压窄，两种情况下第二份都露不出来，
      // 表现就是滚动时右侧一直空着、只剩中间几个字。
      return SizedBox(
        width: constraints.maxWidth,
        height: painter.height,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            maxWidth: double.infinity,
            child: Transform.translate(
              offset: Offset(dx, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _text(),
                  const SizedBox(width: _gap),
                  // 第二份紧跟在后面，形成无缝循环
                  _text(),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class TagPill extends StatelessWidget {
  const TagPill(this.label, {super.key, this.selected = false, this.onTap});
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: selected
        ? context.colors.primary.withValues(alpha: .12)
        : context.chipColor,
    borderRadius: BorderRadius.circular(30),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(30),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? context.colors.primary : context.muted,
          ),
        ),
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.onAction,
    this.actionBuilder,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget Function(String action, VoidCallback? onAction)? actionBuilder;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: context.chipColor,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Icon(
              icon,
              size: 30,
              color: context.muted.withValues(alpha: .6),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.muted,
                fontSize: 12.5,
                height: 1.6,
              ),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 20),
            actionBuilder?.call(action!, onAction) ??
                FilledButton(onPressed: onAction, child: Text(action!)),
          ],
        ],
      ),
    ),
  );
}

Future<T?> showReelSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dark = false,
}) {
  // TV 与桌面都走居中 Dialog（横屏大屏，底部 sheet 体验差）
  if (isDesktopApp || isAndroidTV) {
    return showDialog<T>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .5),
      builder: (dialogContext) => Dialog(
        backgroundColor: dark ? const Color(0xFF171A22) : null,
        constraints: const BoxConstraints(maxWidth: 540),
        clipBehavior: Clip.antiAlias,
        child: FocusTraversalGroup(
          policy: TVFocusTraversalPolicy(),
          child: dark
              ? Theme(
                  data: ReelTheme.make(Brightness.dark),
                  child: Builder(builder: builder),
                )
              : Builder(builder: builder),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: dark ? const Color(0xFF171A22) : null,
    barrierColor: Colors.black.withValues(alpha: .55),
    builder: (sheetContext) => dark
        ? Theme(
            data: ReelTheme.make(Brightness.dark),
            child: Builder(builder: builder),
          )
        : builder(sheetContext),
  );
}

class SheetFrame extends StatelessWidget {
  const SheetFrame({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.footer,
    this.maxHeight = .86,
  });
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? footer;
  final double maxHeight;
  @override
  Widget build(BuildContext context) => _SheetAutofocus(
    child: SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * maxHeight,
        ),
        child: Padding(
          padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isDesktopApp) const SizedBox(height: 18),
            if (!isDesktopApp)
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10, bottom: 10),
                  decoration: BoxDecoration(
                    color: context.muted.withValues(alpha: .28),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 12, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            subtitle!,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: context.muted,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  _CloseButton(),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: child,
              ),
            ),
            if (footer != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: footer,
              ),
          ],
        ),
      ),
    ),
    ),
  );
}

/// Sheet 右上角关闭按钮：TV 上用 TVFocusable 提供红框焦点 + 辉光，
/// 手机/桌面上退化为普通 IconButton。
class _CloseButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    if (isAndroidTV) {
      return TVFocusable(
        radius: 10,
        borderWidth: 2,
        focusRole: 'sheetClose',
        autofocus: true,
        onTap: () => Navigator.of(context).pop(),
        semanticLabel: '关闭',
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            Icons.close_rounded,
            size: 20,
            color: context.muted,
          ),
        ),
      );
    }
    return IconButton(
      tooltip: '关闭',
      onPressed: () => Navigator.of(context).pop(),
      icon: Icon(
        Icons.close_rounded,
        size: 20,
        color: context.muted,
      ),
    );
  }
}

/// TV 上 sheet 打开时自动聚焦首个可遍历子节点（TVFocusable）。
/// 手机/桌面无副作用。
class _SheetAutofocus extends StatefulWidget {
  const _SheetAutofocus({required this.child});
  final Widget child;
  @override
  State<_SheetAutofocus> createState() => _SheetAutofocusState();
}

class _SheetAutofocusState extends State<_SheetAutofocus> {
  @override
  void initState() {
    super.initState();
    if (isAndroidTV) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          final scope = FocusScope.of(context);
          scope.requestFocus();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            // 若已有节点持焦点（如某个 TVFocusable 设了 autofocus），保留它；
            // 否则聚焦首个可遍历子节点。
            final primary = FocusManager.instance.primaryFocus;
            if (primary == null ||
                primary == scope ||
                !scope.children.any((n) => n.hasFocus)) {
              scope.traversalChildren.firstOrNull?.requestFocus();
            }
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<T?> pickOption<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required T value,
  required Map<T, String> options,
  bool dark = false,
}) => showReelSheet<T>(
  context,
  dark: dark,
  builder: (context) => SheetFrame(
    title: title,
    subtitle: subtitle,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final option in options.entries)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 3),
            title: Text(
              option.value,
              style: TextStyle(
                fontSize: 15,
                color: option.key == value ? context.colors.primary : null,
              ),
            ),
            trailing: option.key == value
                ? Icon(
                    Icons.check_rounded,
                    color: context.colors.primary,
                    size: 20,
                  )
                : null,
            onTap: () => Navigator.of(context).pop(option.key),
          ),
      ],
    ),
  ),
);
