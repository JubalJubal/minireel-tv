import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minireel/core/config/source_config.dart';
import 'package:minireel/core/errors/app_exception.dart';
import 'package:minireel/core/network/app_http_client.dart';
import 'package:minireel/data/sources/hongguo/hongguo_web_fallback.dart';
import 'package:minireel/domain/models/drama.dart';
import 'package:minireel/domain/models/playback_source.dart';

/// 红果网页播放页在 2026-10 改为 protectedPlayback：不再下发
/// video_player_info.main_url，只对 publicVideoSeo 公布的公开视频给出
/// /video/public/<itemId>/360p.mp4 直链。
String playerHtml(Map<String, dynamic> page) =>
    '<script>window._ROUTER_DATA = '
    '${jsonEncode({
      'loaderData': {
        'player_layout': null,
        'player_(series_id)/(vid)/page': page,
      },
    })}; window.after=true;</script>';

Map<String, dynamic> seoPage({
  bool available = true,
  String seriesId = '100',
  String itemId = '202',
}) => {
  'vid': '202',
  'series_id': '100',
  'protectedPlayback': true,
  'videoList': <String, dynamic>{},
  'publicVideoSeo': {
    'available': available,
    'seriesId': seriesId,
    'itemId': itemId,
    'posterUrl': 'https://img.invalid/poster.webp',
    'durationSeconds': 148.353,
    'width': 640,
    'height': 360,
  },
};

class _Client implements TextClient {
  _Client(this.body);
  final String body;
  final calls = <Uri>[];

  @override
  Future<String> getText(
    Uri uri, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    calls.add(uri);
    return body;
  }
}

/// 网页页返回 HTML，第三方播放接口返回已验证的空结果。
class _RouteClient extends _Client {
  _RouteClient(this.playerBody) : super('{"parse":0,"url":""}');
  final String playerBody;

  @override
  Future<String> getText(
    Uri uri, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    calls.add(uri);
    return uri.path.startsWith('/player/') ? playerBody : body;
  }
}

void main() {
  final config = SourceConfig(
    baseUrl: Uri.parse('https://example.invalid'),
    playbackEndpoint: Uri.parse('https://example.invalid/api/play'),
    referer: 'https://example.invalid/',
    mediaReferer: 'https://media.invalid/',
  );
  const drama = Drama(
    id: 'hongguo:100',
    source: 'hongguo',
    sourceId: '100',
    title: '测试短剧',
  );
  const episode = Episode(
    id: 'hongguo:100:202',
    dramaId: 'hongguo:100',
    sourceEpisodeId: '202',
    index: 2,
  );

  test('publicVideoSeo 公开视频回退到 360p 直链', () async {
    final client = _Client(playerHtml(seoPage()));
    final result = await HongguoWebFallback(
      config,
      client,
    ).resolvePlayback(drama, episode);

    final source = result.sources.single;
    expect(client.calls.single.path, '/player/100/202');
    expect(
      source.uri.toString(),
      'https://example.invalid/video/public/202/360p.mp4',
    );
    expect(source.kind, PlaybackKind.direct);
    expect(source.quality, '360P');
    expect(source.duration, const Duration(milliseconds: 148353));
    expect(source.headers['Referer'], isNotNull);
  });

  test('video_player_info.main_url 仍优先于公开直链', () async {
    final page = seoPage();
    page['video_player_info'] = {
      'main_url': 'https://media.invalid/ep2.m3u8',
      'duration': '90.5',
    };
    final result = await HongguoWebFallback(
      config,
      _Client(playerHtml(page)),
    ).resolvePlayback(drama, episode);

    final source = result.sources.single;
    expect(source.uri.toString(), 'https://media.invalid/ep2.m3u8');
    expect(source.kind, PlaybackKind.hls);
    expect(source.quality, '原画');
  });

  test('公开视频未覆盖本集时不臆造地址', () async {
    for (final page in [
      seoPage(available: false),
      seoPage(itemId: '999'),
      seoPage(seriesId: '999'),
    ]) {
      final client = _RouteClient(playerHtml(page));
      await expectLater(
        HongguoWebFallback(config, client).resolvePlayback(drama, episode),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            '本集暂时无法播放，请稍后重试',
          ),
        ),
      );
      // 网页路径失败后按既有顺序回退到第三方接口。
      expect(client.calls, hasLength(2));
      expect(client.calls.last.path, '/api/play');
    }
  });

  test('网页返回的分集与请求不一致时拒绝', () async {
    final page = seoPage()..['vid'] = '303';
    await expectLater(
      HongguoWebFallback(
        config,
        _Client(playerHtml(page)),
      ).resolvePlayback(drama, episode),
      throwsA(isA<AppException>()),
    );
  });
}
