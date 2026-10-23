import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../domain/models/playback_source.dart';
import 'hongguo_app_client.dart';
import 'hongguo_parser.dart';
import 'hongguo_playback_codec.dart';

final class HongguoMediaService {
  HongguoMediaService(this.client, this.config);
  final HongguoAppClient client;
  final SourceConfig config;

  Future<PlaybackOptions> resolve(
    String videoId, {
    CancelToken? cancelToken,
    int contentType = 1,
  }) async {
    final result = await client.post('/novel/player/video_model/v1/', {
      'video_id': videoId,
      'content_type': contentType,
      'biz_param': {'need_all_video_definition': true, 'video_platform': 3},
    }, cancelToken: cancelToken);
    final value = objectMap(result['data'])['video_model'];
    try {
      return parse(objectMap(value is String ? jsonDecode(value) : value));
    } on FormatException {
      throw const AppException('App 播放信息格式异常');
    }
  }

  PlaybackOptions parse(Map<String, dynamic> model) {
    final rows = model['video_list'];
    final variants = rows is Map ? rows.values.toList() : anyList(rows);
    final seconds = double.tryParse(
      field(model, ['video_duration', 'duration']),
    );
    final duration = seconds != null && seconds.isFinite && seconds > 0
        ? Duration(milliseconds: (seconds * 1000).round())
        : null;
    final sources = <({PlaybackSource source, int score})>[];
    for (final row in variants) {
      final variant = objectMap(row);
      final meta = objectMap(variant['video_meta']);
      final codec = field(meta, ['codec_type']).toLowerCase();
      if (codec == 'bytevc2' ||
          field(variant, ['gear_des_key']).toLowerCase().contains('bytevc2')) {
        continue;
      }
      final uri = mediaUri(field(variant, ['main_url']));
      if (uri == null) continue;
      final encryption = objectMap(variant['encrypt_info']);
      final spade = field(encryption, ['spade_a']);
      final encrypted =
          spade.isNotEmpty ||
          encryption['encrypt'] == true ||
          field(encryption, ['encryption_method']) == 'cenc-aes-ctr';
      try {
        final key = encrypted
            ? const HongguoPlaybackCodec().decodeContentKey(spade)
            : null;
        final definition = int.tryParse(
          RegExp(r'\d+').firstMatch(field(meta, ['definition']))?.group(0) ??
              '',
        );
        final height =
            definition ?? int.tryParse(field(meta, ['vheight'])) ?? 0;
        sources.add((
          source: PlaybackSource(
            uri: uri,
            kind: encrypted
                ? PlaybackKind.cenc
                : uri.path.toLowerCase().contains('.m3u8')
                ? PlaybackKind.hls
                : PlaybackKind.direct,
            headers: config.playbackHeaders(mediaReferer: config.mediaReferer),
            duration: duration,
            contentKey: key,
            route: PlaybackRoute.app,
            quality: height > 0 ? '${height}P' : '原画',
          ),
          score:
              height * 10 + (['h264', 'avc1', 'avc'].contains(codec) ? 1 : 0),
        ));
      } on AppException {
        // A broken encrypted variant must not hide other playable variants.
        continue;
      }
    }
    sources.sort((a, b) => b.score.compareTo(a.score));
    if (sources.isEmpty) throw const AppException('App 未返回兼容的媒体');
    final qualities = <String>{};
    return PlaybackOptions([
      for (final item in sources)
        if (qualities.add(item.source.quality)) item.source,
    ]);
  }
}
