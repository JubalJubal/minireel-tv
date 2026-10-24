import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minireel/core/config/source_config.dart';
import 'package:minireel/core/network/app_http_client.dart';
import 'package:minireel/data/sources/hongguo/hongguo_app_client.dart';
import 'package:minireel/data/sources/hongguo/hongguo_media_service.dart';
import 'package:minireel/domain/models/playback_source.dart';

/// multi_video_model 新取流契约（对齐上游 0.1.24 provider_hongguo_native_media.go）。
class _Client implements TextClient, SignedJsonClient {
  _Client();

  Object? respond;
  String getTextBody = '';
  final posts = <({String path, Map<String, dynamic> body})>[];
  final gets = <Uri>[];

  @override
  Future<String> postSignedJson(
    Uri Function() prepareUri,
    String body,
    Map<String, String> Function(Uri) prepareHeaders, {
    CancelToken? cancelToken,
  }) async {
    final uri = prepareUri();
    prepareHeaders(uri);
    posts.add((path: uri.path, body: jsonDecode(body) as Map<String, dynamic>));
    return jsonEncode(respond);
  }

  @override
  Future<String> getText(
    Uri uri, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    gets.add(uri);
    return getTextBody;
  }
}

SourceConfig _config() => SourceConfig(
  baseUrl: Uri.parse('https://hongguoduanju.com'),
  playbackEndpoint: Uri.parse('https://djapi.invalid/api/play'),
  referer: 'https://hongguoduanju.com/',
  mediaReferer: 'https://novel.snssdk.com/',
  appBaseUrl: Uri.parse('https://api5-normal-sinfonlineb.fqnovel.com'),
  appUserAgent: 'com.phoenix.read/73532 (Linux; U; Android 16)',
  appParameters: const {'aid': '8662', 'version_name': '7.3.5.32'},
);

Map<String, dynamic> _model({String host = 'media.invalid'}) => {
  'video_duration': 12.5,
  'video_list': {
    'hevc': {
      'main_url': 'https://$host/hevc.mp4',
      'backup_url': ['https://$host/hevc-b1.mp4', 'https://$host/hevc-b2.mp4'],
      'video_meta': {'codec_type': 'hevc', 'definition': '1080p'},
    },
    'avc': {
      'main_url': 'https://$host/avc.mp4',
      'video_meta': {'codec_type': 'h264', 'definition': '720p'},
    },
  },
};

void main() {
  test('新接口 payload 与 multi_video_model 路径', () async {
    final client = _Client()
      ..respond = {
        'data': {'video_model': _model()},
      };
    final service = HongguoMediaService(
      HongguoAppClient(_config(), client),
      _config(),
    );
    await service.resolve('7692096762072288280');
    expect(client.posts.single.path, '/novel/player/multi_video_model/v1/');
    expect(client.posts.single.body['mixed_video_id_map'], {
      '1004': ['7692096762072288280'],
    });
    expect(
      (client.posts.single.body['biz_param'] as Map)['video_platform'],
      1024,
    );
  });

  test('data[vid].video_model 新形态解析且多地址按序进入档位', () async {
    final client = _Client()
      ..respond = {
        'data': {
          '7692096762072288280': {'video_model': _model()},
        },
      };
    final service = HongguoMediaService(
      HongguoAppClient(_config(), client),
      _config(),
    );
    final options = await service.resolve('7692096762072288280');
    // 1080P hevc 优先，720P avc 次之。
    expect(options.sources.first.quality, '1080P');
    expect(options.sources.first.uri.host, 'media.invalid');
    expect(options.sources.map((s) => s.quality), contains('720P'));
  });

  test('fallback_api 二次 GET 合并 key_seed 模型', () async {
    final fallbackModel = {
      'video_info': {
        'data': {
          'key_seed': base64.encode(utf8.encode('0123456789abcdef')),
          'video_list': {
            'hevc': {
              // 受 key_seed 保护的地址：base64(0xa8,0,0x01,0x00 + 明文补齐)
              // 无法用固定 seed 伪造合法密文，这里给明文直链验证合并路径。
              'main_url': 'https://v.fqnovel.com/fallback.mp4',
              'video_meta': {'codec_type': 'hevc', 'definition': '1080p'},
            },
          },
        },
      },
    };
    final client = _Client()
      ..respond = {
        'data': {'video_model': {'fallback_api': 'https://x.fqnovel.com/f'}},
      }
      ..getTextBody = jsonEncode(fallbackModel)
    ;
    final service = HongguoMediaService(
      HongguoAppClient(_config(), client),
      _config(),
    );
    final options = await service.resolve('7692096762072288280');
    expect(client.gets.single.host, 'x.fqnovel.com');
    expect(options.sources.first.uri.host, 'v.fqnovel.com');
    expect(options.sources.first.kind, PlaybackKind.direct);
  });

  test('fallback_api 域名白名单拒绝第三方', () async {
    final client = _Client()
      ..respond = {
        'data': {
          'video_model': {'fallback_api': 'https://evil.example.com/f'},
        },
      };
    final service = HongguoMediaService(
      HongguoAppClient(_config(), client),
      _config(),
    );
    await expectLater(
      service.resolve('7692096762072288280'),
      throwsA(predicate(
        (e) => e is Exception && e.toString().contains('允许的域名'),
      )),
    );
    expect(client.gets, isEmpty);
  });

  test('spade URL 解密往返（seed + 固定常量）', () async {
    // 构造：SHA512(SHA512(seed)+常量) 派生 key/iv 后的 CBC 密文。
    final seed = Uint8List.fromList(utf8.encode('0123456789abcdef'));
    const plain = 'https://v.fqnovel.com/spade.mp4';
    // 用服务自身逻辑生成密文再解密，验证对称性。
    final service = HongguoMediaService(
      HongguoAppClient(_config(), _Client()),
      _config(),
    );
    final cipher = service.encryptSpadeURLForTest(plain, seed);
    expect(service.decryptSpadeURLForTest(cipher, seed), plain);
  });
}
