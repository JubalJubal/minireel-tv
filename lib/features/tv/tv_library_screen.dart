import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/theme.dart';
import '../../data/repositories/drama_repository.dart';
import '../../domain/models/drama.dart';
import '../../domain/models/catalog_order.dart';
import '../shared/drama_metadata.dart';
import '../detail/detail_sheet.dart';
import '../shared/widgets.dart';
import 'tv_focus.dart';

/// TV 版短剧库页面。
/// 复用 LibraryScreen 的数据逻辑（channel/tag/filter/order），
/// UI 改为 TV 适配：所有可交互元素用 TVFocusable 包裹，D-pad 可操作。
class TVLibraryScreen extends StatefulWidget {
  const TVLibraryScreen({
    super.key,
    required this.onPlay,
    this.channel,
    this.atTopNotifier,
  });
  final void Function(Drama drama, [int? episode]) onPlay;
  /// 当前频道，由 TVAppShell 的侧边导航控制；null 表示「综合」。
  final DramaChannel? channel;
  /// 列表是否停在顶部。由 TVAppShell 传入，用来同步外层那个悬浮搜索
  /// 按钮的显隐：往下滚动时按钮与顶部栏一起让位给内容。
  final ValueNotifier<bool>? atTopNotifier;
  @override
  State<TVLibraryScreen> createState() => _TVLibraryScreenState();
}

class _TVLibraryScreenState extends State<TVLibraryScreen> {
  Set<String> _tags = {};
  ReleaseStatus? _status;
  bool _shortOnly = false;
  CatalogOrder _order = CatalogOrder.recommended;
  final _scroll = ScrollController();
  /// 内容网格区的焦点节点：把网格标记成一个独立焦点子树。
  final _contentFocus = FocusNode(debugLabel: 'tv-library-content');
  /// 缓存的筛选结果：避免每次 build 都全量 filter+sort。
  /// 仅在 catalog 长度变化（loadMore/refresh）或筛选条件变化时重算。
  List<Drama> _cachedItems = const [];
  List<String> _cachedPopularTags = const [];
  int _cachedCatalogLength = -1;
  String? _cachedFilterSignature;
  bool get _filtered =>
      _tags.isNotEmpty ||
      _status != null ||
      _shortOnly ||
      _order != CatalogOrder.recommended;

  /// 筛选条件签名：任一筛选状态变化时改变，用于判断缓存是否失效。
  String get _filterSignature =>
      '${widget.channel?.name}|${_tags.toList()..sort()}|$_status|$_shortOnly|${_order.name}';

  /// 按需重算筛选结果。catalog 长度或筛选条件变化时才重算，
  /// 焦点切换等不触发 repository、不改筛选的 build 直接命中缓存。
  void _ensureItemsComputed(DramaRepository repo) {
    final catalogLength = repo.catalog.length;
    final sig = _filterSignature;
    if (catalogLength == _cachedCatalogLength && sig == _cachedFilterSignature) {
      return;
    }
    _cachedCatalogLength = catalogLength;
    _cachedFilterSignature = sig;
    final available = repo.catalog
        .where(
          (drama) =>
              widget.channel == null || drama.channel == widget.channel,
        )
        .toList();
    final items = available
        .where(
          (drama) =>
              (_tags.isEmpty || _tags.any((tag) => drama.matches(tag))) &&
              (_status == null || drama.releaseStatus == _status) &&
              (!_shortOnly ||
                  drama.episodeCount > 0 && drama.episodeCount <= 60),
        )
        .toList();
    if (_order == CatalogOrder.title) {
      items.sort((a, b) => a.title.compareTo(b.title));
    }
    if (_order == CatalogOrder.short) {
      items.sort((a, b) => a.episodeCount.compareTo(b.episodeCount));
    }
    final popularTags = <String>{..._tags};
    for (final drama in available) {
      popularTags.addAll(drama.tags.where((tag) => tag.length <= 6));
      if (popularTags.length >= 12) break;
    }
    if (popularTags.isEmpty) {
      popularTags.addAll(['甜宠', '逆袭', '复仇', '穿越', '热血', '治愈', '玄幻']);
    }
    _cachedItems = items;
    _cachedPopularTags = popularTags.toList();
  }

  /// 列表是否停在顶部。false 时顶部栏（筛选）与外层悬浮搜索按钮一起收起，
  /// 把纵向空间让给卡片；滚回顶部再出现。
  bool _atTop = true;

  void _handleScroll() {
    // 阈值取很小：只要离开顶部就收起，滚回顶部立刻恢复。
    final atTop = !_scroll.hasClients || _scroll.offset <= 8;
    if (atTop != _atTop) {
      setState(() => _atTop = atTop);
    }
    widget.atTopNotifier?.value = atTop;
    if (_scroll.position.extentAfter < 700) {
      final repo = AppScope.read(context).repository;
      if (repo.errors.isEmpty) {
        unawaited(repo.loadMore(channel: widget.channel));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _contentFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    return ListenableBuilder(
      listenable: app.repository,
      builder: (context, _) {
        final repo = app.repository;
        _ensureItemsComputed(repo);
        final items = _cachedItems;
        final popularTags = _cachedPopularTags;
        // 列表为空 / 加载中时始终显示顶部栏（用户需要「刷新剧库」入口），
        // 否则跟随滚动位置收起，把纵向空间让给卡片。
        final showHeader = _atTop || items.isEmpty;
        return Column(
          children: [
            // 顶部栏：筛选（独立焦点区，与网格隔离）。
            // 用 AnimatedSize 让收起/展开呈现推挤效果，而不是突然消失。
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: showHeader
                  ? FocusTraversalGroup(
                      policy: TVFocusTraversalPolicy(),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          border: Border(
                            bottom: BorderSide(
                              color: Theme.of(context).dividerColor,
                            ),
                          ),
                        ),
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
                        child: Row(
                          children: [
                            // 搜索按钮在 TVAppShell 的屏幕级悬浮层上
                            // （固定在左上角，不随内容区推挤移动）。
                            const Spacer(),
                            TVFocusable(
                              radius: 20,
                              focusRole: 'filter',
                              onTap: () => _openFilters(popularTags.toList()),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.filter_list_rounded,
                                      size: 18,
                                      color: _filtered
                                          ? context.colors.primary
                                          : context.muted,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      '筛选',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: _filtered
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: _filtered
                                            ? context.colors.primary
                                            : context.muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity, height: 0),
            ),
            if (repo.refreshing && repo.catalog.isNotEmpty)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: Focus(
                focusNode: _contentFocus,
                canRequestFocus: false,
                descendantsAreFocusable: true,
                child: FocusTraversalGroup(
                policy: TVFocusTraversalPolicy(),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (repo.catalog.isEmpty && repo.refreshing) {
                      return _skeleton(constraints.maxWidth);
                    }
                  if (items.isEmpty) {
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        EmptyState(
                          icon: repo.errors.isEmpty
                              ? Icons.movie_outlined
                              : Icons.wifi_off_rounded,
                          title: _filtered ? '没有符合筛选的短剧' : '这里还没有短剧',
                          subtitle: _filtered
                              ? '试试其他题材，或者清空筛选'
                              : '正在加载，发现下一部好剧',
                          action: _filtered ? '清空筛选' : '刷新剧库',
                          onAction: () {
                            if (_filtered) {
                              setState(_resetFilters);
                            } else {
                              unawaited(repo.refresh());
                            }
                          },
                          actionBuilder: (label, onTap) => TVFocusable(
                            radius: 24,
                            onTap: onTap,
                            child: FilledButton(
                              onPressed: onTap,
                              child: Text(label),
                            ),
                          ),
                        ),
                      ],
                    );
                  }
                  final columns = app.preferences.tvColumns > 0
                      ? app.preferences.tvColumns
                      : dramaColumns(constraints.maxWidth);
                  return CustomScrollView(
                    controller: _scroll,
                    cacheExtent: 600,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      if (app.history.isNotEmpty &&
                          !_filtered &&
                          widget.channel == null)
                        SliverToBoxAdapter(child: _continueWatching(app)),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        sliver: SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisSpacing: 16,
                                crossAxisSpacing: 16,
                                childAspectRatio: _cardAspectRatio(
                                  constraints.maxWidth,
                                  columns,
                                ),
                              ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final drama = items[index];
                              return TVFocusable(
                                radius: 16,
                                focusRole: index == 0 ? 'firstGridCard' : null,
                                onTap: () => widget.onPlay(drama),
                                onLongPress: () => showDramaDetail(
                                  context,
                                  drama,
                                  widget.onPlay,
                                ),
                                child: DramaCard(
                                  drama: drama,
                                  favorite: app.isFavorite(drama.id),
                                  // 不再放排序指标 footer：默认排序下它只是
                                  // 一行空格占位，却让每张卡片底部多出一片空白。
                                  // 统一封面比例，并固定标题区为两行高度，
                                  // 卡片高度不再随标题行数或封面比例浮动。
                                  aspectRatio: _coverAspectRatio,
                                  fixedTitleHeight: _titleHeight,
                                  // 副标题显示题材标签（都市 / 现代…），
                                  // 取代默认的「集数 · 分类」。
                                  subtitle: _cardSubtitle(drama),
                                  onTap: () => widget.onPlay(drama),
                                  onLongPress: () => showDramaDetail(
                                    context,
                                    drama,
                                    widget.onPlay,
                                  ),
                                  interactive: false,
                                ),
                              );
                            },
                            childCount: items.length,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 30),
                          child: Center(
                            child: repo.loadingMore
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : repo.hasMoreFor(widget.channel)
                                ? TextButton(
                                    onPressed: () => repo.loadMore(
                                      channel: widget.channel,
                                    ),
                                    child: const Text('加载更多'),
                                  )
                                : Text(
                                    '· 已加载 ${items.length} 部短剧 ·',
                                    style: TextStyle(
                                      color: context.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  void didUpdateWidget(TVLibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 侧边导航切换频道：清掉标签筛选并回到列表顶部，让新频道从第一屏开始。
    if (oldWidget.channel != widget.channel) {
      _tags.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
  }

  Widget _continueWatching(AppController app) {
    final record = app.history.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: TVFocusable(
        radius: 16,
        focusRole: 'continueWatching',
        onTap: () => widget.onPlay(record.drama),
        child: Material(
          color: context.colors.surface,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 48,
                    height: 62,
                    child: CoverImage(drama: record.drama),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.drama.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '上次看到第 ${record.episodeIndex} 集 · ${formatTime(record.position)}',
                        style: TextStyle(color: context.muted, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.play_circle_fill_rounded,
                  color: context.colors.primary,
                  size: 38,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// TV 卡片封面统一宽高比：所有卡片一致，封面高度不再参差。
  static const double _coverAspectRatio = .68;

  /// 标题区固定高度：13.5 号字 × 1.35 行高 × 2 行。
  static const double _titleHeight = 13.5 * 1.35 * 2;

  /// 卡片文字区总高：标题区上下内边距(8+9) + 标题两行 + 间距 4 +
  /// 副标题一行，再留 6px 余量避免字体度量差异导致底部溢出。
  /// 已不含排序指标 footer —— 那行在默认排序下只是空格占位，
  /// 会让每张卡片底部多出一片空白。
  static const double _cardTextHeight = 8 + 9 + _titleHeight + 4 + 14 + 6;

  /// 卡片副标题：优先显示题材标签（最多两个），没有标签时退回分类。
  /// 不再显示集数 —— 挑剧时题材比集数有用，位置让给标签。
  String _cardSubtitle(Drama drama) {
    // 频道标签（真人剧 / 漫剧 / AI剧 / 动漫）始终保留在最前，
    // 后面接题材标签（最多两个）；没有题材标签时退回分类。
    final extras = drama.tags.isNotEmpty
        ? drama.tags.take(2)
        : <String>[if (drama.category.isNotEmpty) drama.category];
    return [drama.channel.label, ...extras].join(' · ');
  }

  /// 按列数与可用宽度反推「整卡宽高比」，让 SliverGrid 的格子
  /// 刚好容纳封面 + 文字区：同一行卡片高度完全一致，也不会溢出。
  double _cardAspectRatio(double maxWidth, int columns) {
    const horizontalPadding = 40.0; // SliverPadding 左右各 20
    const spacing = 16.0;
    final cardWidth =
        (maxWidth - horizontalPadding - spacing * (columns - 1)) / columns;
    final coverHeight = cardWidth / _coverAspectRatio;
    return cardWidth / (coverHeight + _cardTextHeight);
  }

  Widget _skeleton(double width) => GridView.builder(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.all(20),
    itemCount: 8,
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: dramaColumns(width),
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      childAspectRatio: _cardAspectRatio(width, dramaColumns(width)),
    ),
    itemBuilder: (_, _) => Container(
      decoration: BoxDecoration(
        color: context.chipColor,
        borderRadius: BorderRadius.circular(16),
      ),
    ),
  );

  void _resetFilters() {
    _tags = {};
    _status = null;
    _shortOnly = false;
    _order = CatalogOrder.recommended;
  }

  Future<void> _openFilters(List<String> tags) async {
    final draftTags = Set<String>.of(_tags);
    var status = _status;
    var shortOnly = _shortOnly;
    var order = _order;
    await showReelSheet<void>(
      context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SheetFrame(
          title: '轻量筛选',
          footer: Row(
            children: [
              Expanded(
                child: TVFocusable(
                  radius: 10,
                  borderWidth: 1.5,
                  onTap: () => update(() {
                    draftTags.clear();
                    status = null;
                    shortOnly = false;
                    order = CatalogOrder.recommended;
                  }),
                  child: Container(
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: context.muted.withValues(alpha: .4)),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '重置',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: context.colors.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TVFocusable(
                  radius: 10,
                  onTap: () {
                    setState(() {
                      _tags = draftTags;
                      _status = status;
                      _shortOnly = shortOnly;
                      _order = order;
                    });
                    Navigator.of(context).pop();
                  },
                  child: Container(
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: context.colors.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '确定',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: context.colors.onPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _filterLabel(context, '题材'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (int i = 0; i < tags.length; i++)
                    _TVTagPill(
                      tags.elementAt(i),
                      selected: draftTags.contains(tags.elementAt(i)),
                      role: i == 0 ? 'filterFirstTag' : null,
                      onTap: () => update(() {
                        final tag = tags.elementAt(i);
                        if (!draftTags.add(tag)) draftTags.remove(tag);
                      }),
                    ),
                ],
              ),
              _filterLabel(context, '状态 / 篇幅'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _TVTagPill(
                    '连载中',
                    selected: status == ReleaseStatus.ongoing,
                    onTap: () => update(
                      () => status = status == ReleaseStatus.ongoing
                          ? null
                          : ReleaseStatus.ongoing,
                    ),
                  ),
                  _TVTagPill(
                    '已完结',
                    selected: status == ReleaseStatus.completed,
                    onTap: () => update(
                      () => status = status == ReleaseStatus.completed
                          ? null
                          : ReleaseStatus.completed,
                    ),
                  ),
                  _TVTagPill(
                    '60 集内',
                    selected: shortOnly,
                    onTap: () => update(() => shortOnly = !shortOnly),
                  ),
                ],
              ),
              _filterLabel(context, '排序'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in {
                    CatalogOrder.recommended: '推荐',
                    CatalogOrder.title: '剧名',
                    CatalogOrder.short: '集数少优先',
                  }.entries)
                    _TVTagPill(
                      entry.value,
                      selected: order == entry.key,
                      onTap: () => update(() => order = entry.key),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterLabel(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 12),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: context.muted,
      ),
    ),
  );
}

/// TV 版 TagPill：复用 TagPill 视觉，外层包 TVFocusable。
class _TVTagPill extends StatelessWidget {
  const _TVTagPill(this.label, {required this.selected, required this.onTap, this.role});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? role;
  @override
  Widget build(BuildContext context) => TVFocusable(
    radius: 30,
    focusRole: role,
    onTap: onTap,
    child: TagPill(label, selected: selected),
  );
}
