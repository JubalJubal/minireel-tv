import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';
import 'package:pointycastle/export.dart'
    show AESEngine, CBCBlockCipher, KeyParameter, ParametersWithIV, SHA512Digest;

import '../../../core/config/source_config.dart';
import '../../../core/errors/app_exception.dart';
import '../../../domain/models/playback_source.dart';
import 'hongguo_app_client.dart';
import 'hongguo_parser.dart';
import 'hongguo_playback_codec.dart';

/// 红果播放取源（对齐上游 0.1.24 provider_hongguo_native_media.go）。
///
/// 旧路径 /novel/player/video_model/v1/ 长期只返回 200 空正文；当前有效
/// 路径是 multi_video_model/v1：请求体用 mixed_video_id_map + biz_param，
/// map 键固定 1004、video_platform 固定 1024（其它取值返回 100001）。
/// video_model 有时直接带 video_list，有时只给 fallback_api，需二次 GET
/// 拿 video_info.data 并用 key_seed 解密受保护地址。
final class HongguoMediaService {
  HongguoMediaService(this.client, this.config);
  final HongguoAppClient client;
  final SourceConfig config;

  static const _modelPath = '/novel/player/multi_video_model/v1/';
  static const _fallbackDomains = ['fqnovel.com', 'snssdk.com'];

  /// 媒体 URL 解密的固定常量段（64 字节）。
  static final Uint8List _spadeURLConstants = _hexBytes(
    '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524'
    'f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58',
  );

  final _codec = const HongguoPlaybackCodec();

  Future<PlaybackOptions> resolve(
    String videoId, {
    CancelToken? cancelToken,
  }) async {
    if (!RegExp(r'^[0-9]{1,32}$').hasMatch(videoId)) {
      throw const AppException('红果视频 ID 无效');
    }
    final result = await client.post(_modelPath, {
      'biz_param': {
        'detail_page_version': 0,
        'device_level': 3,
        'disable_digg_stat': false,
        'need_all_video_definition': true,
        'need_mp4_align': false,
        'use_os_player': false,
        'use_server_dns': false,
        'video_platform': 1024,
      },
      'mixed_video_id_map': {
        '1004': [videoId],
      },
    }, cancelToken: cancelToken);
    final data = objectMap(result['data']);
    // 三种返回形态：data[vid].video_model（新）、data.video_model（旧）、
    // 其它单键条目。
    Map<String, dynamic> model;
    final entry = objectMap(data[videoId]);
    if (entry.isNotEmpty) {
      model = _videoModel(entry['video_model']);
    } else if (data.containsKey('video_model')) {
      model = _videoModel(data['video_model']);
    } else {
      model = const {};
      for (final candidate in data.values) {
        if (candidate is! Map) continue;
        try {
          final parsed = _videoModel(objectMap(candidate)['video_model']);
          if (parsed.isNotEmpty) {
            model = parsed;
            break;
          }
        } on AppException {
          continue;
        }
      }
      if (model.isEmpty) {
        throw const AppException('App 接口未返回该集播放信息');
      }
    }
    // 两种供给形态：直接给 video_list，或只给 fallback_api。
    if (_hasVideoList(model)) return parse(model);
    final fallback = field(model, ['fallback_api']).trim();
    if (fallback.isEmpty) {
      throw const AppException('App 接口未返回本集片源地址');
    }
    final outer = await _fallbackJson(fallback, cancelToken);
    var inner = objectMap(objectMap(outer['video_info'])['data']);
    if (inner.isEmpty) inner = objectMap(outer['data']);
    if (inner.isEmpty) {
      throw const AppException('App 接口未返回本集片源模型');
    }
    Uint8List? seed;
    final encoded = field(inner, ['key_seed']).trim();
    if (encoded.isNotEmpty) {
      seed = _tolerantBase64(encoded);
      if (seed == null) throw const AppException('App 媒体地址密钥无效');
    }
    return parse(<String, dynamic>{...model, ...inner}, seed: seed);
  }

  Map<String, dynamic> _videoModel(Object? value) {
    if (value is Map) return objectMap(value);
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) throw const AppException('App 播放信息为空');
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return objectMap(decoded);
      } on FormatException {
        // fallthrough
      }
      throw const AppException('App 播放信息格式异常');
    }
    throw const AppException('App 未返回播放信息');
  }

  bool _hasVideoList(Map<String, dynamic> model) {
    if (anyList(model['video_list']).isNotEmpty) return true;
    final rows = model['video_list'];
    return rows is Map && rows.isNotEmpty;
  }

  /// 跟随 fallback_api：普通 GET，不带签名头，只带 UA；域名白名单限制。
  Future<Map<String, dynamic>> _fallbackJson(
    String rawUrl,
    CancelToken? cancelToken,
  ) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) throw const AppException('红果片源地址无效');
    if (uri.scheme != 'https') {
      throw const AppException('红果片源地址不是 HTTPS');
    }
    final host = uri.host.toLowerCase();
    final allowed = _fallbackDomains.any(
      (domain) => host == domain || host.endsWith('.$domain'),
    );
    if (!allowed) throw const AppException('红果片源地址不在允许的域名内');
    final text = await client.transport.getText(
      uri,
      headers: {
        'User-Agent': config.appUserAgent,
        'Accept': 'application/json',
      },
      cancelToken: cancelToken,
    );
    if (text.isEmpty) throw const AppException('红果片源接口返回空正文');
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return objectMap(decoded);
    } on FormatException {
      // fallthrough
    }
    throw const AppException('红果片源接口返回了无效数据');
  }

  PlaybackOptions parse(Map<String, dynamic> model, {Uint8List? seed}) {
    var rows = anyList(model['video_list']);
    if (rows.isEmpty && model['video_list'] is Map) {
      final mapRows = objectMap(model['video_list']);
      // 与上游一致：map 形态按键名升序展开。
      final keys = mapRows.keys.toList()..sort();
      rows = [for (final key in keys) mapRows[key]];
    }
    final seconds = double.tryParse(
      field(model, ['video_duration', 'duration']),
    );
    final duration = seconds != null && seconds.isFinite && seconds > 0
        ? Duration(milliseconds: (seconds * 1000).round())
        : null;
    final sources = <({PlaybackSource source, int score})>[];
    Object? keyError;
    for (final row in rows) {
      final variant = objectMap(row);
      final meta = objectMap(variant['video_meta']);
      final codec = field(meta, ['codec_type']).toLowerCase();
      if (codec == 'bytevc2' ||
          field(variant, ['gear_des_key']).toLowerCase().contains('bytevc2')) {
        continue;
      }
      final addresses = _mediaAddresses(variant, seed);
      if (addresses.isEmpty) continue;
      final encryption = objectMap(variant['encrypt_info']);
      final spade = field(encryption, ['spade_a']);
      final encrypted =
          spade.isNotEmpty ||
          encryption['encrypt'] == true ||
          field(encryption, ['encryption_method']) == 'cenc-aes-ctr';
      Uint8List? key;
      if (encrypted) {
        try {
          key = _codec.decodeContentKey(spade);
        } on AppException catch (error) {
          // A broken encrypted variant must not hide other playable variants.
          keyError = error;
          continue;
        }
      }
      final definition = int.tryParse(
        RegExp(r'\d+').firstMatch(field(meta, ['definition']))?.group(0) ?? '',
      );
      var height = definition ?? int.tryParse(field(meta, ['vheight'])) ?? 0;
      final width = int.tryParse(field(meta, ['vwidth'])) ?? 0;
      if (height == 0 && width > 0) height = width;
      final score = height * 10 + (['h264', 'avc1'].contains(codec) ? 1 : 0);
      for (final address in addresses) {
        final uri = Uri.tryParse(address);
        if (uri == null) continue;
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
          score: score,
        ));
      }
    }
    // 与上游一致：稳定降序，全部地址按序进入档位列表。
    sources.sort((a, b) => b.score.compareTo(a.score));
    if (sources.isEmpty) {
      if (keyError != null && keyError is AppException) {
        throw AppException('App 媒体密钥不可用：${keyError.message}');
      }
      throw const AppException('App 未返回兼容的媒体，已跳过不支持的编码');
    }
    final qualities = <String>{};
    return PlaybackOptions([
      for (final item in sources)
        if (qualities.add(item.source.quality)) item.source,
    ]);
  }

  /// 收集候选媒体地址；seed 非空时先按 spade URL 解密。
  List<String> _mediaAddresses(Map<String, dynamic> info, Uint8List? seed) {
    final addresses = <String>[];
    final seen = <String>{};

    void add(Object? value) {
      if (value is List) {
        for (final item in value) {
          add(item);
        }
        return;
      }
      if (value is! String) return;
      var address = value.trim();
      if (address.length > 8192) return;
      if (!address.startsWith('http://') && !address.startsWith('https://')) {
        if (seed != null) {
          final decrypted = _decryptSpadeURL(address, seed);
          if (decrypted != null) address = decrypted;
        }
        if (!address.startsWith('http://') &&
            !address.startsWith('https://')) {
          final decoded = _tolerantBase64(address);
          if (decoded == null) return;
          address = utf8.decode(decoded, allowMalformed: true).trim();
        }
      }
      final uri = Uri.tryParse(address);
      final valid =
          uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
      if (valid && seen.add(address)) addresses.add(address);
    }

    for (final key in const [
      'main_url',
      'backup_url',
      'backup_url_1',
      'backup_url_2',
      'backup_urls',
      'url_list',
    ]) {
      add(info[key]);
    }
    return addresses;
  }

  /// 解密被 key_seed 保护的媒体地址。
  /// 布局：[0]=0xa8、[1] 保留、[2]=0x01、[3]=0x00、[4:] 为 AES-128-CBC 密文。
  String? _decryptSpadeURL(String value, Uint8List seed) {
    final raw = _tolerantBase64(value);
    if (raw == null || raw.length < 5) return null;
    if (raw[0] != 0xa8 || raw[2] != 0x01 || raw[3] != 0x00) return null;
    final cipherLength = (raw.length - 4) ~/ 16 * 16;
    if (cipherLength == 0) return null;
    final first = SHA512Digest().process(seed);
    final second = SHA512Digest().process(Uint8List.fromList([
      ...first,
      ..._spadeURLConstants,
    ]));
    final cipher = CBCBlockCipher(AESEngine())
      ..init(
        false,
        ParametersWithIV(KeyParameter(second.sublist(0, 16)), second.sublist(16, 32)),
      );
    final plain = Uint8List(cipherLength);
    var offset = 0;
    while (offset < cipherLength) {
      offset += cipher.processBlock(raw, 4 + offset, plain, offset);
    }
    var end = plain.length;
    if (end > 0) {
      final padding = plain[end - 1];
      if (padding >= 1 && padding <= 16 && padding <= end) {
        var valid = true;
        for (var i = end - padding; i < end; i++) {
          if (plain[i] != padding) valid = false;
        }
        if (valid) end -= padding;
      }
    }
    while (end > 0 && plain[end - 1] == 0) {
      end--;
    }
    if (end <= 0) return null;
    return utf8.decode(plain.sublist(0, end), allowMalformed: true);
  }

  /// 解密被 key_seed 保护的媒体地址（测试可见）。
  @visibleForTesting
  String? decryptSpadeURLForTest(String value, Uint8List seed) =>
      _decryptSpadeURL(value, seed);

  /// 构造 spade URL 密文（仅测试用，验证解密往返对称性）。
  @visibleForTesting
  String encryptSpadeURLForTest(String plain, Uint8List seed) {
    final first = SHA512Digest().process(seed);
    final second = SHA512Digest().process(Uint8List.fromList([
      ...first,
      ..._spadeURLConstants,
    ]));
    final cipher = CBCBlockCipher(AESEngine())
      ..init(
        true,
        ParametersWithIV(KeyParameter(second.sublist(0, 16)), second.sublist(16, 32)),
      );
    final body = utf8.encode(plain);
    final padding = 16 - body.length % 16;
    final block = Uint8List.fromList([
      ...body,
      ...List<int>.filled(padding, padding),
    ]);
    final encrypted = Uint8List(block.length);
    var offset = 0;
    while (offset < block.length) {
      offset += cipher.processBlock(block, offset, encrypted, offset);
    }
    return base64.encode([0xa8, 0x00, 0x01, 0x00, ...encrypted]);
  }
}

Uint8List? _tolerantBase64(String value) {
  try {
    return base64.decode(base64.normalize(value.trim()));
  } on FormatException {
    return null;
  }
}

Uint8List _hexBytes(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);
