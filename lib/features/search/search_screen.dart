import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/theme.dart';
import '../../core/errors/app_exception.dart';
import '../../domain/models/discovery.dart';
import '../../domain/models/drama.dart';
import '../shared/drama_list_tile.dart';
import '../shared/widgets.dart';
import '../shared/search_suggestions.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.onPlay});
  final void Function(Drama, [int?]) onPlay;
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  CancelToken? _token;
  int _generation = 0;
  bool _loading = false;
  SearchResult? _remote;
  String? _error;

  @override
  void dispose() {
    _token?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed() {
    _token?.cancel();
    ++_generation;
    setState(() {
      _remote = null;
      _error = null;
      _loading = false;
    });
  }

  void _setQuery(String text) {
    _query.text = text;
    _query.selection = TextSelection.collapsed(offset: text.length);
    _changed();
  }

  Future<void> _search([String? value]) async {
    final keyword = _query.text.trim();
    if (_loading || keyword.isEmpty) return;
    final app = AppScope.read(context);
    FocusScope.of(context).unfocus();
    _token?.cancel();
    final token = _token = CancelToken();
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _remote = null;
      _error = null;
    });
    try {
      final result = await app.repository.searchRemote(
        keyword,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      app.addSearch(keyword);
      setState(() => _remote = result);
    } on DioException catch (error) {
      if (!CancelToken.isCancel(error) &&
          mounted &&
          generation == _generation) {
        setState(() => _error = '网络连接失败，请重试');
      }
    } on Exception catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = readableError(error));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _play(Drama drama) {
    AppScope.read(context).addSearch(_query.text.trim());
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop();
    widget.onPlay(drama);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _query,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onChanged: (_) => _changed(),
                      onSubmitted: app.repository.canSearchRemote
                          ? _search
                          : app.addSearch,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '搜索剧名、题材或标签',
                        filled: true,
                        fillColor: context.chipColor,
                        hintStyle: TextStyle(color: context.muted),
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          size: 20,
                          color: context.muted,
                        ),
                        suffixIcon: _query.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清空搜索',
                                onPressed: () => _setQuery(''),
                                icon: const Icon(
                                  Icons.cancel_rounded,
                                  size: 18,
                                ),
                              ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(30),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  if (app.repository.canSearchRemote)
                    TextButton(
                      onPressed: _loading || _query.text.trim().isEmpty
                          ? null
                          : _search,
                      child: const Text('搜索'),
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
            if (app.repository.hasSearchSuggestions)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: SearchSuggestionPanel(
                  controller: _query,
                  fetch: (query) => app.repository.searchSuggestions(query),
                  onSelected: (_) => _search(),
                ),
              ),
            Expanded(
              child: ListenableBuilder(
                listenable: app.repository,
                builder: (context, _) {
                  final query = _query.text.trim();
                  if (query.isEmpty) {
                    final tags = app.repository.catalog
                        .expand((drama) => drama.tags)
                        .toSet()
                        .take(10);
                    return ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        Text(
                          '热门题材',
                          style: TextStyle(fontSize: 13, color: context.muted),
                        ),
                        const SizedBox(height: 13),
                        Wrap(
                          spacing: 8,
                          runSpacing: 10,
                          children: [
                            for (final tag in tags)
                              TagPill(tag, onTap: () => _setQuery(tag)),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Text(
                              '搜索历史',
                              style: TextStyle(
                                fontSize: 13,
                                color: context.muted,
                              ),
                            ),
                            const Spacer(),
                            if (app.searches.isNotEmpty)
                              IconButton(
                                tooltip: '清除搜索历史',
                                onPressed: app.clearSearches,
                                icon: Icon(
                                  Icons.delete_outline_rounded,
                                  size: 18,
                                  color: context.muted,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 10,
                          children: [
                            for (final text in app.searches)
                              TagPill(text, onTap: () => _setQuery(text)),
                          ],
                        ),
                      ],
                    );
                  }
                  final remoteIds =
                      _remote?.items.map((drama) => drama.id).toSet() ??
                      <String>{};
                  final local = app.repository
                      .searchLocal(query)
                      .where((drama) => !remoteIds.contains(drama.id))
                      .toList();
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 30),
                    children: [
                      if (_loading)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: TextStyle(color: context.muted),
                                ),
                              ),
                              TextButton(
                                onPressed: _search,
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      if (_remote case final result?) ...[
                        Text(
                          '联网搜索：找到 ${result.total} 部，返回 ${result.items.length} 部',
                          style: TextStyle(color: context.muted, fontSize: 12),
                        ),
                        for (final warning in result.warnings)
                          Text(
                            warning,
                            style: TextStyle(
                              color: context.muted,
                              fontSize: 12,
                            ),
                          ),
                        const SizedBox(height: 10),
                        for (final drama in result.items)
                          DramaListTile(
                            drama: drama,
                            onTap: () => _play(drama),
                          ),
                        if (result.items.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('没有找到相关短剧，试试其他关键词'),
                          ),
                        const SizedBox(height: 16),
                      ],
                      Text(
                        _remote == null
                            ? '已加载剧库中找到 ${local.length} 部'
                            : '本地另有 ${local.length} 部匹配',
                        style: TextStyle(color: context.muted, fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      for (final drama in local)
                        DramaListTile(drama: drama, onTap: () => _play(drama)),
                      if (local.isEmpty && _remote == null && !_loading)
                        EmptyState(
                          icon: Icons.search_off_rounded,
                          title: '本地还没找到「$query」',
                          subtitle: app.repository.canSearchRemote
                              ? '点击搜索或按回车，查找更多短剧'
                              : '试试更短的剧名，或加载更多短剧后再搜索',
                        ),
                      if (app.repository.hasMore)
                        Center(
                          child: TextButton(
                            onPressed:
                                app.repository.loadingMore ||
                                    app.repository.refreshing
                                ? null
                                : app.repository.loadMore,
                            child: Text(
                              app.repository.loadingMore
                                  ? '正在加载更多短剧…'
                                  : '加载更多本地剧库',
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
