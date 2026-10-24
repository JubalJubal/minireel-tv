import 'package:dio/dio.dart';

import '../../../core/errors/app_exception.dart';
import '../../../domain/models/drama.dart';
import 'hongguo_app_client.dart';
import 'hongguo_metadata.dart';
import 'hongguo_parser.dart';

/// 红果推荐（对齐上游 provider_hongguo_recommendations.go + app_recommendations.go）。
///
/// 与目录同一 endpoint（landpage），差异：`sort` 传空数组、`filter_ids`
/// 填已看 ID（≤540 个、逗号连接、剥掉 hongguo: 前缀）。按频道维护独立
/// 状态机（offset/session/seen/hasMore）；[fetch] 默认取下一页（首次自
/// 动重置），[reset] 对应上游 force 清空重开。
final class HongguoRecommendationService {
  HongguoRecommendationService(this.appClient);
  final HongguoAppClient appClient;

  static const _seenLimit = 540;
  static const _seenFlush = 100;

  final _states = <String, _RecommendationState>{};

  void reset(String genreKey) => _states.remove(genreKey);

  Future<List<Drama>> fetch(
    String genreKey, {
    required String scene,
    CancelToken? cancelToken,
  }) async {
    final state = _states.putIfAbsent(genreKey, _RecommendationState.new);
    final payload = <String, dynamic>{
      'req_scene': scene,
      'offset': state.offset,
      'limit': 18,
      'req_type': 'only_content',
      'need_selector_panel': false,
      'client_req_type': state.offset > 0 ? 2 : 3,
      'session_id': state.sessionId,
      'filter_ids': state.seen.join(','),
      'select_items': {
        'genre': [genreKey],
        'sort': <String>[],
        'gender': <String>[],
        'category_dim_theme': <String>[],
        'category_dim_role': <String>[],
        'category_dim_epoch': <String>[],
        'online_time': <String>[],
        'creation_status': <String>[],
      },
    };
    final result = await appClient.post(
      '/reading/distribution/category/landpage/v/',
      payload,
      cancelToken: cancelToken,
    );
    final data = objectMap(result['data']);
    final rows = data['video_data'];
    if (rows is! List) throw const AppException('推荐数据格式异常');
    final dramas = <Drama>[];
    for (final row in rows) {
      final drama = const HongguoParser().dramaFrom(
        row,
        hongguoChannel(objectMap(row)),
      );
      if (drama != null && RegExp(r'^[0-9]{1,32}$').hasMatch(drama.sourceId)) {
        dramas.add(drama);
      }
    }
    final more = data['has_more'] == true;
    final next = int.tryParse(field(data, ['next_offset']));
    // 与上游一致：has_more 但页未前进 → 报「推荐分页未前进」。
    if (more &&
        (next == null || next <= state.offset || next > 1000000)) {
      throw const AppException('推荐分页未前进，请刷新重试');
    }
    state
      ..offset = next != null && next >= 0 && next <= 1000000
          ? next
          : state.offset
      ..sessionId = field(data, ['session_id'])
      ..hasMore = more;
    for (final drama in dramas) {
      state.seen.add(drama.sourceId);
    }
    // seen 上限 540：超出时从头部丢弃（保留最近的）。
    while (state.seen.length > _seenLimit) {
      state.seen.removeAt(0);
    }
    if (dramas.isEmpty && state.seen.length > _seenFlush) {
      // 空页不重置 seen，仅在有内容时扩张；保持行为可预期。
      return const [];
    }
    return dramas;
  }
}

final class _RecommendationState {
  int offset = 0;
  String sessionId = '';
  bool hasMore = true;
  final List<String> seen = [];
}
