import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';

/// 搜索联想下拉面板（对齐上游 300ms 防抖 + 命中高亮 + 选中即搜）。
///
/// 内联面板而非浮层：插入在搜索输入框与结果列表之间，不改变页面骨架；
/// 无联想时完全收起。选中后把词回填进输入框并回调 [onSelected]。
class SearchSuggestionPanel extends StatefulWidget {
  const SearchSuggestionPanel({
    super.key,
    required this.controller,
    required this.fetch,
    required this.onSelected,
    this.maxEntries = 8,
    this.rowHeight = 44,
  });

  final TextEditingController controller;
  final Future<List<String>> Function(String query) fetch;
  final ValueChanged<String> onSelected;
  final int maxEntries;
  final double rowHeight;

  @override
  State<SearchSuggestionPanel> createState() => _SearchSuggestionPanelState();
}

class _SearchSuggestionPanelState extends State<SearchSuggestionPanel> {
  Timer? _debounce;
  int _generation = 0;
  String _query = '';
  List<String> _items = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onQueryChanged);
    _schedule();
  }

  @override
  void didUpdateWidget(SearchSuggestionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller) &&
        identical(oldWidget.fetch, widget.fetch)) {
      return;
    }
    _schedule();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onQueryChanged() => _schedule();

  void _schedule() {
    final query = widget.controller.text.trim();
    _debounce?.cancel();
    if (query.isEmpty) {
      _generation++;
      if (_query.isNotEmpty || _items.isNotEmpty) {
        setState(() {
          _query = '';
          _items = const [];
        });
      }
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _load(query));
  }

  Future<void> _load(String query) async {
    final generation = ++_generation;
    try {
      final items = await widget.fetch(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _query = query;
        _items = items.take(widget.maxEntries).toList();
      });
    } on Exception {
      if (!mounted || generation != _generation) return;
      setState(() {
        _query = query;
        _items = const [];
      });
    }
  }

  void _select(String name) {
    widget.controller.text = name;
    widget.controller.selection = TextSelection.collapsed(
      offset: name.length,
    );
    HapticFeedback.selectionClick();
    widget.onSelected(name);
  }

  @override
  Widget build(BuildContext context) {
    if (_query.isEmpty || _items.isEmpty) return const SizedBox.shrink();
    return Material(
      color: context.colors.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in _items)
            _SuggestionRow(
              key: ValueKey('suggestion-$item'),
              query: _query,
              name: item,
              height: widget.rowHeight,
              onSelected: () => _select(item),
            ),
        ],
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    super.key,
    required this.query,
    required this.name,
    required this.height,
    required this.onSelected,
  });

  final String query;
  final String name;
  final double height;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onSelected,
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            const SizedBox(width: 14),
            Icon(Icons.search_rounded, size: 17, color: context.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                _highlight(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5),
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  /// 把命中 query 的子串用主题色加粗（对应上游 _highlight）。
  TextSpan _highlight(BuildContext context) {
    final lower = name.toLowerCase();
    final at = lower.indexOf(query.toLowerCase());
    if (at < 0) return TextSpan(text: name);
    return TextSpan(
      children: [
        if (at > 0) TextSpan(text: name.substring(0, at)),
        TextSpan(
          text: name.substring(at, at + query.length),
          style: TextStyle(
            color: context.colors.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (at + query.length < name.length)
          TextSpan(text: name.substring(at + query.length)),
      ],
    );
  }
}
