import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../app/app_controller.dart';
import '../../app/theme.dart';
import '../../domain/models/drama.dart';
import '../../domain/models/catalog_order.dart';
import '../detail/detail_sheet.dart';
import '../search/search_screen.dart';
import '../rankings/rankings_screen.dart';
import '../recommendations/recommendations_screen.dart';
import '../shared/widgets.dart';
import '../shared/drama_metadata.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.onPlay});
  final void Function(Drama drama, [int? episode]) onPlay;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  DramaChannel? _channel;
  Set<String> _tags = {};
  ReleaseStatus? _status;
  bool _shortOnly = false;
  CatalogOrder _order = CatalogOrder.recommended;
  final _scroll = ScrollController();
  bool get _filtered =>
      _tags.isNotEmpty ||
      _status != null ||
      _shortOnly ||
      _order != CatalogOrder.recommended;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 700) {
        final repo = AppScope.read(context).repository;
        if (repo.errors.isEmpty) unawaited(repo.loadMore(channel: _channel));
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    return ListenableBuilder(
      listenable: app.repository,
      builder: (context, _) {
        final repo = app.repository;
        if (_channel != null && !repo.channels.contains(_channel)) {
          _channel = null;
        }
        final available = repo.catalog
            .where((drama) => _channel == null || drama.channel == _channel)
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
        sortCatalog(items, _order);
        final popularTags = <String>{..._tags};
        for (final drama in available) {
          popularTags.addAll(drama.tags.where((tag) => tag.length <= 6));
          if (popularTags.length >= 12) break;
        }
        if (popularTags.isEmpty) {
          popularTags.addAll(['甜宠', '逆袭', '复仇', '穿越', '热血', '治愈', '玄幻']);
        }
        return Column(
          children: [
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                border: Border(
                  bottom: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Material(
                          color: context.chipColor,
                          borderRadius: BorderRadius.circular(28),
                          child: InkWell(
                            key: const ValueKey('open-search'),
                            borderRadius: BorderRadius.circular(28),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    SearchScreen(onPlay: widget.onPlay),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 11,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.search_rounded,
                                    size: 19,
                                    color: context.muted,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '搜索剧名、题材或标签',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        color: context.muted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const BrandMark(),
                    ],
                  ),
                  const SizedBox(height: 11),
                  Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _category(null, '综合'),
                              for (final channel in app.repository.channels)
                                _category(channel, channel.label),
                            ],
                          ),
                        ),
                      ),
                      if (repo.hasRecommendations)
                        IconButton(
                          tooltip: '推荐',
                          icon: const Icon(Icons.auto_awesome_outlined),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  RecommendationsScreen(onPlay: widget.onPlay),
                            ),
                          ),
                        ),
                      if (repo.hasRankings)
                        IconButton(
                          tooltip: '热播榜',
                          icon: const Icon(Icons.emoji_events_outlined),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  RankingsScreen(onPlay: widget.onPlay),
                            ),
                          ),
                        ),
                      TextButton(
                        onPressed: () => _openFilters(popularTags.toList()),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.only(left: 9),
                          minimumSize: const Size(48, 40),
                          foregroundColor: _filtered
                              ? context.colors.primary
                              : context.muted,
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.filter_list_rounded, size: 16),
                            const SizedBox(width: 3),
                            Text(
                              '筛选',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: _filtered
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final tag in popularTags.take(12))
                          Padding(
                            padding: const EdgeInsets.only(right: 7),
                            child: TagPill(
                              tag,
                              selected: _tags.contains(tag),
                              onTap: () => setState(() {
                                if (!_tags.add(tag)) _tags.remove(tag);
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (repo.refreshing && repo.catalog.isNotEmpty)
              const LinearProgressIndicator(minHeight: 2),
            if (repo.errors.isNotEmpty && !repo.refreshing)
              Container(
                width: double.infinity,
                color: context.colors.primary.withValues(alpha: .06),
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.cloud_off_outlined,
                      size: 16,
                      color: context.muted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        repo.catalog.isEmpty
                            ? '剧库暂时无法连接'
                            : '部分内容未能更新，仍可浏览已加载短剧',
                        style: TextStyle(color: context.muted, fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: repo.refresh,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: repo.refresh,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (repo.catalog.isEmpty && repo.refreshing) {
                      return _skeleton();
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
                                : '下拉刷新，发现下一部好剧',
                            action: _filtered ? '清空筛选' : '刷新剧库',
                            onAction: () {
                              if (_filtered) {
                                setState(_resetFilters);
                              } else {
                                unawaited(repo.refresh());
                              }
                            },
                          ),
                          if (repo.hasMoreFor(_channel) &&
                              repo.catalog.isNotEmpty)
                            Center(
                              child: TextButton(
                                onPressed: repo.loadingMore
                                    ? null
                                    : () => repo.loadMore(channel: _channel),
                                child: Text(
                                  repo.loadingMore ? '正在加载…' : '继续加载更多短剧',
                                ),
                              ),
                            ),
                        ],
                      );
                    }
                    final columns = dramaColumns(constraints.maxWidth);
                    return CustomScrollView(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        if (app.history.isNotEmpty &&
                            !_filtered &&
                            _channel == null)
                          SliverToBoxAdapter(child: _continueWatching(app)),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(14, 13, 14, 0),
                          sliver: SliverMasonryGrid.count(
                            crossAxisCount: columns,
                            mainAxisSpacing: 14,
                            crossAxisSpacing: 14,
                            childCount: items.length,
                            itemBuilder: (context, index) {
                              final drama = items[index];
                              return DramaCard(
                                drama: drama,
                                favorite: app.isFavorite(drama.id),
                                footer: sortMetric(drama, _order) == null
                                    ? null
                                    : Text(
                                        sortMetric(drama, _order)!,
                                        style: TextStyle(
                                          color: context.muted,
                                          fontSize: 11,
                                        ),
                                      ),
                                aspectRatio: [
                                  0.66,
                                  0.72,
                                  0.70,
                                  0.64,
                                ][index % 4],
                                onTap: () => widget.onPlay(drama),
                                onLongPress: () => showDramaDetail(
                                  context,
                                  drama,
                                  widget.onPlay,
                                ),
                              );
                            },
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 25),
                            child: Center(
                              child: repo.loadingMore
                                  ? const SizedBox(
                                      width: 21,
                                      height: 21,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : repo.hasMoreFor(_channel)
                                  ? TextButton(
                                      onPressed: () =>
                                          repo.loadMore(channel: _channel),
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
          ],
        );
      },
    );
  }

  Widget _category(DramaChannel? value, String label) {
    final selected = _channel == value;
    return InkWell(
      onTap: () => setState(() {
        _channel = value;
        _tags.clear();
        if (_scroll.hasClients) _scroll.jumpTo(0);
      }),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 2),
        child: Column(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? context.colors.onSurface : context.muted,
              ),
            ),
            const SizedBox(height: 5),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 3,
              width: selected ? 18 : 0,
              decoration: BoxDecoration(
                color: context.colors.primary,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _continueWatching(AppController app) {
    final record = app.history.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Material(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => widget.onPlay(record.drama),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: SizedBox(
                    width: 36,
                    height: 47,
                    child: CoverImage(drama: record.drama),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.drama.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '上次看到第 ${record.episodeIndex} 集 · ${formatTime(record.position)}',
                        style: TextStyle(color: context.muted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.play_circle_fill_rounded,
                  color: context.colors.primary,
                  size: 32,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _skeleton() => LayoutBuilder(
    builder: (context, constraints) => GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(14),
      itemCount: 6,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: dramaColumns(constraints.maxWidth),
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: .59,
      ),
      itemBuilder: (_, _) => Container(
        decoration: BoxDecoration(
          color: context.chipColor,
          borderRadius: BorderRadius.circular(16),
        ),
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
                child: OutlinedButton(
                  onPressed: () => update(() {
                    draftTags.clear();
                    status = null;
                    shortOnly = false;
                    order = CatalogOrder.recommended;
                  }),
                  child: const Text('重置'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: () {
                    setState(() {
                      _tags = draftTags;
                      _status = status;
                      _shortOnly = shortOnly;
                      _order = order;
                    });
                    Navigator.of(context).pop();
                  },
                  child: const Text('确定'),
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
                  for (final tag in tags)
                    TagPill(
                      tag,
                      selected: draftTags.contains(tag),
                      onTap: () => update(() {
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
                  TagPill(
                    '连载中',
                    selected: status == ReleaseStatus.ongoing,
                    onTap: () => update(
                      () => status = status == ReleaseStatus.ongoing
                          ? null
                          : ReleaseStatus.ongoing,
                    ),
                  ),
                  TagPill(
                    '已完结',
                    selected: status == ReleaseStatus.completed,
                    onTap: () => update(
                      () => status = status == ReleaseStatus.completed
                          ? null
                          : ReleaseStatus.completed,
                    ),
                  ),
                  TagPill(
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
                  for (final item in CatalogOrder.values)
                    TagPill(
                      item.label,
                      selected: order == item,
                      onTap: () => update(() => order = item),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '按已加载短剧排序，缺少数据的短剧排在最后',
                style: TextStyle(color: context.muted, fontSize: 12),
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
