import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/theme.dart';
import '../../core/errors/app_exception.dart';
import '../../domain/models/drama.dart';
import '../detail/detail_sheet.dart';
import '../shared/drama_list_tile.dart';

/// 推荐页（数据链路对齐上游 provider_hongguo_recommendations.go）。
///
/// 三个频道各自维护独立的推荐状态机；底部「继续推荐」续拉下一页，
/// 「刷新获取新推荐」重置状态机（对应上游 force）。
class RecommendationsScreen extends StatefulWidget {
  const RecommendationsScreen({super.key, required this.onPlay});
  final void Function(Drama, [int?]) onPlay;

  @override
  State<RecommendationsScreen> createState() => _RecommendationsScreenState();
}

class _RecommendationsScreenState extends State<RecommendationsScreen> {
  static const _channels = [
    (DramaChannel.real, '真人剧'),
    (DramaChannel.comicDrama, '漫剧'),
    (DramaChannel.ai, 'AI剧'),
  ];

  DramaChannel _channel = DramaChannel.real;
  final _items = <Drama>[];
  int _generation = 0;
  bool _loading = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) _items.clear();
    });
    try {
      final dramas = await AppScope.read(context).repository.recommendations(
        _channel,
        more: !reset,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _items.addAll(dramas);
        _hasMore = dramas.isNotEmpty;
      });
    } on DioException catch (error) {
      if (!CancelToken.isCancel(error) && mounted && generation == _generation) {
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

  void _select(DramaChannel channel) {
    if (channel == _channel) return;
    setState(() {
      _channel = channel;
      _items.clear();
      _hasMore = true;
      _error = null;
      _loading = false;
    });
    unawaited(_load(reset: true));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('推荐'),
        actions: [
          IconButton(
            tooltip: '刷新获取新推荐',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : () => _load(reset: true),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              children: [
                for (final (channel, label) in _channels)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: channel == _channel,
                      onSelected: (_) => _select(channel),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _body(app)),
        ],
      ),
    );
  }

  Widget _body(AppController app) {
    if (_items.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_items.isEmpty && _error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.explore_outlined, size: 40, color: context.muted),
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: context.muted)),
            const SizedBox(height: 14),
            FilledButton.tonal(
              onPressed: () => _load(reset: true),
              child: const Text('重新获取推荐'),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text('推荐还在准备中，稍后再来看看', style: TextStyle(color: context.muted)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
      itemCount: _items.length + 1,
      itemBuilder: (context, index) {
        if (index >= _items.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: _loading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : _error != null
                  ? Column(
                      children: [
                        Text(_error!, style: TextStyle(color: context.muted)),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () => _load(),
                          child: const Text('重试'),
                        ),
                      ],
                    )
                  : _hasMore
                  ? FilledButton.tonalIcon(
                      key: const ValueKey('recommendations-more'),
                      onPressed: () => _load(),
                      icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                      label: const Text('继续推荐'),
                    )
                  : TextButton.icon(
                      onPressed: () => _load(reset: true),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('刷新获取新推荐'),
                    ),
            ),
          );
        }
        final drama = _items[index];
        return DramaListTile(
          key: ValueKey('recommendation-${drama.id}'),
          drama: drama,
          onTap: () => showDramaDetail(context, drama, widget.onPlay),
        );
      },
    );
  }
}
