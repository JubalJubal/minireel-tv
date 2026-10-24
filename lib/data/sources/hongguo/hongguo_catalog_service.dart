import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart' show SHA256Digest;

import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_http_client.dart';
import '../../../domain/models/catalog_page.dart';
import '../../../domain/models/drama.dart';
import 'hongguo_app_client.dart';
import 'hongguo_parser.dart';
import 'hongguo_web_fallback.dart';

final class HongguoCatalogService {
  HongguoCatalogService(this.client, this.web);
  final HongguoAppClient client;
  final HongguoWebFallback web;
  bool webFallbackActive = false;

  Future<CatalogPage> load(
    DramaChannel channel,
    CatalogCursor cursor, {
    bool refresh = false,
    Set<String> knownIds = const {},
    CancelToken? cancelToken,
  }) async {
    if (channel != DramaChannel.animation && client.enabled) {
      try {
        if (!refresh) {
          if (cursor.exhausted) return CatalogPage([], cursor, hasMore: false);
          return await _appPage(channel, cursor, cancelToken);
        }
        var head = const CatalogCursor();
        final items = <String, Drama>{};
        // Refresh only scans a small head; tail continuation remains untouched.
        for (var i = 0; i < (cursor.initialized ? 3 : 1); i++) {
          CatalogPage page;
          try {
            page = await _appPage(channel, head, cancelToken);
          } on AppException {
            if (items.isEmpty) rethrow;
            break;
          }
          head = page.cursor;
          for (final drama in page.items) {
            items[drama.id] = drama;
          }
          if (!page.hasMore ||
              page.items.every((drama) => knownIds.contains(drama.id))) {
            break;
          }
        }
        final tail = cursor.initialized
            ? cursor
            : CatalogCursor(
                offset: head.offset,
                sessionId: head.sessionId,
                lastId: head.lastId,
                initialized: head.initialized,
                exhausted: head.exhausted,
                updatedAt: head.updatedAt,
                webPage: cursor.webPage,
                webExhausted: cursor.webExhausted,
              );
        return CatalogPage(
          items.values.toList(),
          tail,
          hasMore: !tail.exhausted,
        );
      } on AppException {
        cancelToken?.throwIfCancellationRequested();
        webFallbackActive = true;
      }
    }
    if (!refresh && cursor.webExhausted) {
      return CatalogPage([], cursor, hasMore: false);
    }
    final page = refresh ? 1 : cursor.webPage + 1;
    final items = await web.fetchCatalog(
      channel,
      page,
      cancelToken: cancelToken,
    );
    final end = items.length < web.pageSize || page >= web.maxPages;
    final preserveTail = refresh && cursor.webPage > 0;
    final next = CatalogCursor(
      offset: cursor.offset,
      sessionId: cursor.sessionId,
      lastId: cursor.lastId,
      initialized: cursor.initialized,
      exhausted: cursor.exhausted,
      updatedAt: cursor.updatedAt,
      webPage: preserveTail ? cursor.webPage : page,
      webExhausted: preserveTail ? cursor.webExhausted : end,
    );
    return CatalogPage(items, next, hasMore: !next.webExhausted);
  }

  Future<CatalogPage> _appPage(
    DramaChannel channel,
    CatalogCursor cursor,
    CancelToken? token,
  ) async {
    final genre = switch (channel) {
      DramaChannel.real => 'short_play',
      DramaChannel.comicDrama => 'comic_series',
      DramaChannel.ai => 'ai_series',
      DramaChannel.animation => throw const AppException('App 暂不支持动漫分类'),
    };
    final session =
        cursor.updatedAt != null &&
            DateTime.now().difference(cursor.updatedAt!) <
                const Duration(minutes: 30)
        ? cursor.sessionId
        : '';
    final payload = <String, dynamic>{
      'req_scene': channel == DramaChannel.real ? 'default' : genre,
      'offset': cursor.offset,
      'limit': 18,
      'req_type': 'only_content',
      'need_selector_panel': false,
      'client_req_type': cursor.offset > 0 ? 2 : 3,
      'session_id': session,
      'filter_ids': '',
      'select_items': {
        'genre': [genre],
        'sort': ['online_time'],
        'gender': <String>[],
        'category_dim_theme': <String>[],
        'category_dim_role': <String>[],
        'category_dim_epoch': <String>[],
        'online_time': <String>[],
        'creation_status': <String>[],
      },
    };
    Map<String, dynamic> result;
    try {
      result = await client.post(
        '/reading/distribution/category/landpage/v/',
        payload,
        cancelToken: token,
      );
    } on AppException {
      token?.throwIfCancellationRequested();
      if (session.isEmpty) rethrow;
      payload['session_id'] = '';
      result = await client.post(
        '/reading/distribution/category/landpage/v/',
        payload,
        cancelToken: token,
      );
    }
    final data = objectMap(result['data']);
    final rows = data['video_data'];
    if (rows is! List) throw const AppException('App 分类数据格式异常');
    final items = <String, Drama>{};
    for (final row in rows) {
      final drama = const HongguoParser().dramaFrom(row, channel);
      if (drama != null && RegExp(r'^[0-9]{1,32}$').hasMatch(drama.sourceId)) {
        items[drama.id] = drama;
      }
    }
    if (rows.isNotEmpty && items.isEmpty) {
      throw const AppException('App 分类未返回可识别的剧集');
    }
    final more = data['has_more'];
    final next = int.tryParse(field(data, ['next_offset']));
    final lastId = items.isEmpty ? '' : items.keys.last;
    // 对齐上游 PageSignature：本页 ID 升序 SHA-256，用于识别同一页重复。
    final signature = items.isEmpty ? '' : _pageSignature(items.keys);
    if (more is! bool ||
        (more &&
            (next == null ||
                next <= cursor.offset ||
                next > 1000000 ||
                items.isEmpty ||
                (lastId == cursor.lastId && signature == cursor.pageSignature)))) {
      throw const AppException('App 分页未前进，已保留上次位置');
    }
    return CatalogPage(
      items.values.toList(),
      CatalogCursor(
        offset: next != null && next >= 0 && next <= 1000000
            ? next
            : cursor.offset + rows.length,
        sessionId: field(data, ['session_id']),
        lastId: lastId,
        pageSignature: signature,
        initialized: true,
        exhausted: !more,
        updatedAt: DateTime.now(),
        webPage: cursor.webPage,
        webExhausted: cursor.webExhausted,
      ),
      hasMore: more,
    );
  }

  /// 本页全部剧集 ID 升序排列、换行连接后的 SHA-256 hex。
  String _pageSignature(Iterable<String> ids) {
    final sorted = ids.toList()..sort();
    final digest = SHA256Digest().process(
      utf8.encode(sorted.join('\n')),
    );
    return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
