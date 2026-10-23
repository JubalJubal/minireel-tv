import 'package:dio/dio.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_http_client.dart';
import '../../../domain/models/drama.dart';
import 'hongguo_app_client.dart';
import 'hongguo_parser.dart';

final class _DetailCall {
  final token = CancelToken();
  late Future<DramaDetail> result;
  int waiters = 0;
}

final class HongguoDetailService {
  HongguoDetailService(this.client);
  final HongguoAppClient client;
  final _cache = <String, ({DramaDetail detail, DateTime expires})>{};
  final _pending = <String, _DetailCall>{};

  void clear() {
    _cache.clear();
    for (final call in _pending.values) {
      call.token.cancel();
    }
    _pending.clear();
  }

  Future<DramaDetail> getDetail(Drama drama, {CancelToken? cancelToken}) async {
    cancelToken?.throwIfCancellationRequested();
    final cached = _cache[drama.id];
    if (cached != null && DateTime.now().isBefore(cached.expires)) {
      return cached.detail;
    }
    var call = _pending[drama.id];
    if (call == null || call.token.isCancelled) {
      call = _DetailCall();
      final current = call;
      _pending[drama.id] = current;
      current.result = (() async {
        try {
          final result = await client.post('/novel/player/video_detail/v1/', {
            'series_id': drama.sourceId,
          }, cancelToken: current.token);
          final detail = parse(result, drama);
          current.token.throwIfCancellationRequested();
          if (_cache.length >= 128) _cache.remove(_cache.keys.first);
          _cache[drama.id] = (
            detail: detail,
            expires: DateTime.now().add(const Duration(minutes: 5)),
          );
          return detail;
        } finally {
          if (identical(_pending[drama.id], current)) _pending.remove(drama.id);
        }
      })();
    }
    call.waiters++;
    try {
      return await (cancelToken == null
          ? call.result
          : Future.any<DramaDetail>([
              call.result,
              cancelToken.whenCancel.then<DramaDetail>((error) => throw error),
            ]));
    } finally {
      call.waiters--;
      if (call.waiters == 0 && identical(_pending[drama.id], call)) {
        call.token.cancel();
      }
    }
  }

  /// 红果按剧集下发 content_type（普通短剧 1，AI/漫画等 1000+），
  /// 取流时必须原样回传；范围外的值按普通短剧处理。
  static int _contentTypeOf(String value, {String fallback = ''}) {
    for (final candidate in [value, fallback]) {
      final parsed = int.tryParse(candidate);
      if (parsed != null &&
          (parsed >= 1 && parsed <= 7 || parsed >= 1000 && parsed <= 1011)) {
        return parsed;
      }
    }
    return 1;
  }

  DramaDetail parse(Map<String, dynamic> result, Drama drama) {
    final data = objectMap(objectMap(result['data'])['video_data']);
    if (field(data, ['series_id_str', 'series_id']) != drama.sourceId) {
      throw const AppException('App 未返回所选短剧');
    }
    final episodes = <Episode>[];
    final ids = <String>{};
    final indices = <int>{};
    for (final row in anyList(data['video_list'])) {
      final video = objectMap(row);
      final vid = field(video, ['vid']);
      final index = int.tryParse(field(video, ['vid_index']));
      final series = field(video, ['series_id_str', 'series_id']);
      if (index == null ||
          index < 1 ||
          !RegExp(r'^[0-9]{1,32}$').hasMatch(vid) ||
          (series.isNotEmpty && series != drama.sourceId) ||
          !ids.add(vid) ||
          !indices.add(index)) {
        throw const AppException('App 分集编号或视频 ID 无效');
      }
      episodes.add(
        Episode(
          id: '${drama.id}:$vid',
          dramaId: drama.id,
          sourceEpisodeId: vid,
          index: index,
          contentType: _contentTypeOf(
            field(video, ['content_type']),
            fallback: field(data, ['content_type']),
          ),
        ),
      );
    }
    episodes.sort((a, b) => a.index.compareTo(b.index));
    final total = int.tryParse(field(data, ['episode_cnt'])) ?? 0;
    if (episodes.isEmpty || total > episodes.length) {
      throw const AppException('App 未返回完整分集');
    }
    for (var i = 0; i < episodes.length; i++) {
      if (episodes[i].index != i + 1) throw const AppException('App 分集不连续');
    }
    return DramaDetail(
      drama: const HongguoParser().dramaFrom(
        {...data, 'episode_cnt': episodes.length},
        drama.channel,
        fallback: drama,
      )!,
      episodes: List.unmodifiable(episodes),
    );
  }
}
