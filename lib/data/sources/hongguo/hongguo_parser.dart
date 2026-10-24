import 'dart:convert';

import '../../../core/errors/app_exception.dart';
import '../../../domain/models/drama.dart';
import 'hongguo_metadata.dart';

final class HongguoParser {
  const HongguoParser();

  /// 解析 category_schema 里的题材标签（都市 / 现代 / 玄幻…）。
  ///
  /// 该字段是 JSON 字符串，元素形如
  /// `{"category_id":5022,"name":"都市","schema":"dragon8662://..."}`。
  /// 短剧列表接口不返回 data['tags']，题材只能从这里取。
  List<String>? _categorySchemaTags(Map<String, dynamic> data) {
    final raw = data['category_schema'];
    Object? decoded;
    try {
      decoded = switch (raw) {
        String value when value.trim().isNotEmpty => jsonDecode(value),
        List value => value,
        _ => null,
      };
    } on FormatException {
      return null;
    }
    if (decoded is! List) return null;
    final names = <String>[];
    for (final item in decoded) {
      final name = field(objectMap(item), ['name']).trim();
      if (name.isNotEmpty && !names.contains(name)) names.add(name);
    }
    return names.isEmpty ? null : names;
  }

  /// Decode just the assigned JSON object, not the surrounding JavaScript.
  /// Braces in quoted strings and trailing script blocks are supported.
  Map<String, dynamic> routerData(String html) {
    final marker = RegExp(r'(?:window\.)?_ROUTER_DATA\s*=\s*').firstMatch(html);
    if (marker == null ||
        marker.end >= html.length ||
        html[marker.end] != '{') {
      throw const AppException('剧库数据暂时不可用，请稍后重试', kind: FailureKind.parsing);
    }
    var depth = 0;
    var quoted = false;
    var escaped = false;
    for (var i = marker.end; i < html.length; i++) {
      final c = html.codeUnitAt(i);
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (c == 92) {
          escaped = true;
        } else if (c == 34) {
          quoted = false;
        }
      } else if (c == 34) {
        quoted = true;
      } else if (c == 123) {
        depth++;
      } else if (c == 125 && --depth == 0) {
        try {
          return jsonDecode(html.substring(marker.end, i + 1))
              as Map<String, dynamic>;
        } on FormatException {
          break;
        }
      }
    }
    throw const AppException('剧库数据格式发生变化，请稍后重试', kind: FailureKind.parsing);
  }

  Map<String, dynamic> loader(Map<String, dynamic> data, List<String> names) {
    final loaders = objectMap(data['loaderData']);
    for (final name in names) {
      final value = objectMap(loaders[name]);
      if (value.isNotEmpty) return value;
    }
    for (final entry in loaders.entries) {
      if (names.any(
        (name) => entry.key.startsWith(name.replaceAll(r'$', '')),
      )) {
        final value = objectMap(entry.value);
        if (value.isNotEmpty) return value;
      }
    }
    throw const AppException('剧库页面暂时无法读取', kind: FailureKind.parsing);
  }

  List<Drama> catalog(String html, DramaChannel channel) {
    final page = loader(routerData(html), ['category_page', r'category_$']);
    if (page['isSuccess'] == false || !page.containsKey('recommendList')) {
      throw const AppException('这个分类暂时无法更新');
    }
    final dramas = <String, Drama>{};
    for (final item in anyList(page['recommendList'])) {
      final drama = dramaFrom(item, channel);
      if (drama != null) dramas[drama.id] = drama;
    }
    return dramas.values.toList(growable: false);
  }

  Drama? dramaFrom(dynamic value, DramaChannel channel, {Drama? fallback}) {
    final map = objectMap(value);
    final video = objectMap(map['video_data']);
    final data = {...map, ...video};
    final sourceId = field(data, [
      'series_id_str',
      'series_id',
      'keyword',
    ], fallback?.sourceId ?? '');
    if (sourceId.isEmpty) return null;
    // 题材标签来自 category_schema（data['tags'] 通常为空）。
    final tags = _categorySchemaTags(data) ?? stringList(data['tags']);
    final remark = field(data, ['episode_right_text'], fallback?.remark ?? '');
    final count =
        int.tryParse(field(data, ['episode_cnt'])) ??
        fallback?.episodeCount ??
        0;
    return Drama(
      id: 'hongguo:$sourceId',
      source: 'hongguo',
      sourceId: sourceId,
      title: field(data, [
        'series_title',
        'series_name',
        'title',
        'name',
      ], fallback?.title ?? sourceId),
      coverUrl: field(data, [
        'series_cover',
        'cover',
        // 推荐流（landpage sort 空）的行结构不同：封面在 vertical /
        // horiz_cover 上，catalog 行的 cover 为空时回退取用。
        'vertical',
        'horiz_cover',
      ], fallback?.coverUrl ?? ''),
      intro: field(data, ['series_intro', 'video_desc'], fallback?.intro ?? ''),
      category: field(data, [
        'category_name',
        'categoryName',
        'category',
      ], tags.isNotEmpty ? tags.first : fallback?.category ?? channel.label),
      episodeCount: count,
      remark: remark,
      tags: tags.isNotEmpty ? tags : fallback?.tags ?? const [],
      channel: channel,
      releaseStatus: field(data, ['series_status']) == '1'
          ? ReleaseStatus.completed
          : field(data, ['series_status']) == '0'
          ? ReleaseStatus.ongoing
          : remark.contains('完结') || remark.startsWith('全')
          ? ReleaseStatus.completed
          : remark.contains('更新') || remark.contains('连载')
          ? ReleaseStatus.ongoing
          : fallback?.releaseStatus ?? ReleaseStatus.unknown,
      score: hongguoNumber(field(data, ['score'])) ?? fallback?.score,
      views:
          hongguoNumber(
            field(data, ['series_play_cnt', 'play_cnt']),
          )?.toInt() ??
          fallback?.views,
      heat:
          hongguoNumber(
            field(objectMap(data['hot_score_data']), [
              'score',
            ], field(data, ['hot_score'])),
          ) ??
          hongguoNumber(field(objectMap(data['hot_score_data']), ['text'])) ??
          fallback?.heat,
      onlineDate: hongguoOnlineDate(data) ?? fallback?.onlineDate,
    );
  }

  DramaDetail detail(String html, Drama drama) {
    final page = loader(routerData(html), ['detail_page', 'detail_']);
    final data = objectMap(page['seriesDetail']);
    if (data.isEmpty) throw const AppException('暂时无法获取这部短剧的分集');
    final returnedId = field(data, ['series_id']);
    if (returnedId.isNotEmpty && returnedId != drama.sourceId) {
      throw const AppException('未能获取所选短剧，请重新打开');
    }
    final vids = anyList(data['vid_list']);
    final episodes = <Episode>[];
    final seen = <String>{};
    for (var i = 0; i < vids.length; i++) {
      final value = vids[i];
      final vid = value is Map
          ? field(objectMap(value), ['vid', 'video_id', 'id'])
          : value?.toString().trim() ?? '';
      if (!RegExp(r'^[0-9]{1,32}$').hasMatch(vid) || !seen.add(vid)) {
        throw const AppException('网页分集信息不完整，请稍后重试');
      }
      episodes.add(
        Episode(
          id: '${drama.id}:$vid',
          dramaId: drama.id,
          sourceEpisodeId: vid,
          index: i + 1,
        ),
      );
    }
    if (episodes.isEmpty) throw const AppException('这部短剧暂时没有可播放的分集');
    if ((int.tryParse(field(data, ['episode_cnt'])) ?? 0) > episodes.length) {
      throw const AppException('网页未返回完整分集，请稍后重试');
    }
    return DramaDetail(
      drama: dramaFrom(
        {...data, 'episode_cnt': episodes.length},
        drama.channel,
        fallback: drama,
      )!,
      episodes: episodes,
    );
  }
}

Map<String, dynamic> objectMap(dynamic value) =>
    value is Map<String, dynamic> ? value : const {};

String field(
  Map<String, dynamic> data,
  List<String> keys, [
  String fallback = '',
]) {
  for (final key in keys) {
    final value = data[key];
    if (value is String || value is num) {
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
  }
  return fallback;
}

List<dynamic> anyList(dynamic value) {
  if (value is List) return value;
  if (value is Map) {
    for (final key in ['list', 'items', 'data']) {
      final list = anyList(value[key]);
      if (list.isNotEmpty) return list;
    }
  }
  return const [];
}

List<String> stringList(dynamic value) {
  final values = value is String
      ? value.split(RegExp(r'[,/，、]'))
      : value is List
      ? value
      : const [];
  return values
      .map(
        (item) => item is Map
            ? field(objectMap(item), ['name', 'tag_name', 'text'])
            : item.toString().trim(),
      )
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList(growable: false);
}

Uri? mediaUri(String value) {
  if (value.length > 8192) return null;
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? uri
      : null;
}
