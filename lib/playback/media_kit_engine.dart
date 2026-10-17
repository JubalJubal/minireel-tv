import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/errors/app_exception.dart';
import '../domain/models/playback_source.dart';
import '../domain/models/preferences.dart';
import 'buffered_playback_engine.dart';
import 'playback_engine.dart';
import 'native_error_guard.dart';
import 'cenc/cenc_playback_proxy.dart';

final class MediaKitEngine extends BufferedPlaybackEngine {
  MediaKitEngine({this.preferences})
      : super((preloading) => _MediaKitPlayer(preloading, preferences));

  final Preferences? preferences;

  VideoController get video => (activeEngine as _MediaKitPlayer).video;
  Player get player => (activeEngine as _MediaKitPlayer).player;

  VideoController? videoForEpisode(String episodeId) =>
      (engineForEpisode(episodeId) as _MediaKitPlayer?)?.video;

  void updatePreferences(Preferences preferences) {
    if (activeEngine is _MediaKitPlayer) {
      (activeEngine as _MediaKitPlayer).updatePreferences(preferences);
    }
  }
}

final class _MediaKitPlayer implements PlaybackEngine {
  _MediaKitPlayer(this._preloading, [Preferences? preferences])
    : _prefs = preferences ?? const Preferences(),
      player = Player(
        configuration: PlayerConfiguration(
          title: 'MiniReel',
          bufferSize: _preloading
              ? 4 * 1024 * 1024
              : ((preferences?.playerBufferSizeMb ?? (Platform.isAndroid ? 16 : 32)) *
                  1024 *
                  1024),
          muted: _preloading,
          logLevel: MPVLogLevel.info,
        ),
      ) {
    _errors = NativeErrorGuard(
      grace: const Duration(seconds: 6),
      onFailure: () => _emit(
        state.value.copyWith(
          error: '视频加载失败，请重试或切换下一集',
          playing: false,
          buffering: false,
        ),
      ),
    );
    video = VideoController(player);
    WidgetsBinding.instance.scheduleFrame();
    _subscriptions.addAll([
      player.stream.position.listen((v) {
        _errors.progress(v);
        _emit(state.value.copyWith(position: v));
      }),
      player.stream.duration.listen(
        (v) => _emit(state.value.copyWith(duration: v)),
      ),
      player.stream.buffer.listen(
        (v) => _emit(state.value.copyWith(buffer: v)),
      ),
      player.stream.playing.listen(
        (v) => _emit(state.value.copyWith(playing: v)),
      ),
      player.stream.buffering.listen(
        (v) => _emit(state.value.copyWith(buffering: v)),
      ),
      player.stream.completed.listen(
        (v) => _emit(state.value.copyWith(completed: v)),
      ),
      player.stream.error.listen((error) {
        debugPrint('[mpv] error: $error');
        _errors.reportError();
      }),
      player.stream.log.listen((event) {
        debugPrint('[mpv] ${event.level} ${event.prefix}: ${event.text}');
      }),
    ]);
  }

  Preferences _prefs;
  final Player player;
  bool _preloading;
  late final VideoController video;
  late final NativeErrorGuard _errors;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  @override
  final ValueNotifier<EngineSnapshot> state = ValueNotifier(
    const EngineSnapshot(),
  );
  Future<void> _operations = Future.value();
  bool _disposed = false;
  Uri? _proxyUrl;

  static Future<CencPlaybackProxy>? _proxyFuture;

  static Future<CencPlaybackProxy> _ensureProxy() async {
    final existing = _proxyFuture;
    if (existing != null) return existing;
    final created = CencPlaybackProxy.start();
    _proxyFuture = created;
    try {
      return await created;
    } on Object {
      _proxyFuture = null;
      rethrow;
    }
  }

  void _releaseProxy() {
    final url = _proxyUrl;
    _proxyUrl = null;
    if (url == null) return;
    final future = _proxyFuture;
    if (future == null) return;
    unawaited(
      future.then<void>((proxy) => proxy.release(url), onError: (Object _) {}),
    );
  }

  void updatePreferences(Preferences preferences) {
    _prefs = preferences;
  }

  void _emit(EngineSnapshot next) {
    if (!_disposed) state.value = next;
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.then((_) => operation());
    // A failed open does not poison subsequent retries or teardown.
    _operations = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  @override
  Future<void> open(
    PlaybackSource source, {
    required Duration start,
    required bool Function() isCurrent,
    String? episodeId,
  }) => _serialize(() async {
    bool valid() => !_disposed && isCurrent();
    if (!valid()) return;
    _errors.reset();
    _errors.setPlaying(false);
    await player.stop();
    _releaseProxy();
    if (!valid()) return;
    debugPrint(
      '[Engine] open kind=${source.kind.name} route=${source.route.name} '
      'quality=${source.quality} host=${source.uri.host} key=${source.keyHex.length}',
    );
    final native = player.platform;
    var playUri = source.uri;
    var playHeaders = source.headers;
    var viaProxy = false;
    if (native is NativePlayer) {
      if (source.kind == PlaybackKind.cenc && source.contentKey?.length != 16) {
        throw const AppException('本集播放信息不完整，请重试');
      }
      if (source.kind == PlaybackKind.cenc) {
        // 与参考实现一致：CENC 媒体先由本机代理解密成明文 MP4 再交给播放器，
        // 不依赖 libmpv 是否支持 cenc-aes-ctr 直解（不同 TV 固件差异很大）。
        try {
          final proxy = await _ensureProxy();
          final local = await proxy.open(source);
          if (!valid()) {
            proxy.release(local);
            return;
          }
          _proxyUrl = local;
          playUri = local;
          playHeaders = const {};
          viaProxy = true;
        } on Object catch (error) {
          debugPrint('[Engine] CENC 本地转发不可用，回退播放器解密: $error');
          _releaseProxy();
        }
      }
      // Clear the previous key for EVERY open, including unencrypted media.
      await native.setProperty(
        'demuxer-lavf-o',
        [
          'reconnect=1',
          'reconnect_streamed=1',
          'reconnect_on_network_error=1',
          'reconnect_delay_max=2',
          if (source.kind == PlaybackKind.cenc && !viaProxy)
            'decryption_key=${source.keyHex}',
        ].join(','),
      );
      await native.setProperty('network-timeout', '20');
      await native.setProperty('cache', 'yes');
      await native.setProperty('cache-on-disk', 'no');

      // 硬件解码策略：软解兼容(no) / 强制 MediaCodec / 默认（拷贝回内存）。
      //
      // 默认不用 auto-safe：在 Android 上它常选到 `mediacodec`（非 copy），
      // 解码帧直接输出到 Surface。部分电视 SoC（Cortex-A73 方案常见）在
      // 每集开头 2-3 秒会渲染出未初始化的纹理 —— 画面色块分布不均、甚至
      // 整片白块，之后自行恢复。`mediacodec-copy` 解码后拷回内存再交给
      // mpv 渲染，画质稳定，而这档电视的解码性能足够，代价可以忽略。
      final hwdec = switch (_prefs.hardwareDecoding) {
        'no' => 'no',
        'mediacodec' => 'mediacodec',
        _ => 'mediacodec-copy',
      };
      await native.setProperty('hwdec', hwdec);
      // 关闭解码器直出（direct rendering）。部分电视 SoC 的 GPU 驱动在硬解
      // 首帧时会把尚未初始化的缓冲直接上屏，表现为每集开头 2-3 秒画面色块
      // 分布不均、甚至大片白块，之后自行恢复。关掉 DR 后由 mpv 先拷一帧
      // 再交给渲染器，可消除该现象，额外开销很小。
      await native.setProperty('vd-lavc-dr', 'no');
      await native.setProperty('volume-max', '200');

      // 缓冲区大小动态调优
      final bufferMb = _prefs.playerBufferSizeMb;
      final maxBytes = _preloading ? (4 * 1024 * 1024) : (bufferMb * 1024 * 1024);
      final backBytes = _preloading ? 0 : (maxBytes ~/ 4);
      final readaheadSecs = _preloading ? '12' : (bufferMb >= 32 ? '30' : '20');

      await native.setProperty('demuxer-max-bytes', '$maxBytes');
      await native.setProperty('demuxer-max-back-bytes', '$backBytes');
      await native.setProperty('cache-secs', readaheadSecs);
      await native.setProperty('demuxer-readahead-secs', readaheadSecs);
    } else if (source.kind == PlaybackKind.cenc) {
      throw const AppException('当前设备暂不支持这个视频格式');
    }
    if (!valid()) return;
    _emit(const EngineSnapshot(buffering: true));
    debugPrint('[Engine] playUri=$playUri viaProxy=$viaProxy');
    // Always open paused: a late network response can never start audio
    // behind a sheet, in the background, or after the viewer leaves.
    await player.open(
      Media(
        playUri.toString(),
        httpHeaders: playHeaders,
        start: start > Duration.zero ? start : null,
      ),
      play: false,
    );
    debugPrint(
      '[Engine] opened duration=${player.state.duration}',
    );
    if (!valid()) await player.stop();
  });

  @override
  Future<void> stop() => _serialize(() async {
    if (_disposed) return;
    _errors.reset();
    _errors.setPlaying(false);
    await player.stop();
    _releaseProxy();
    _emit(const EngineSnapshot());
  });

  @override
  Future<void> setPlaying(bool playing) async {
    if (_disposed) return;
    if (playing && _preloading) {
      final native = player.platform;
      if (native is NativePlayer) {
        final bufferMb = _prefs.playerBufferSizeMb;
        final maxBytes = bufferMb * 1024 * 1024;
        final backBytes = maxBytes ~/ 4;
        final readaheadSecs = bufferMb >= 32 ? '30' : '20';
        await native.setProperty('demuxer-max-bytes', '$maxBytes');
        await native.setProperty('demuxer-max-back-bytes', '$backBytes');
        await native.setProperty('cache-secs', readaheadSecs);
        await native.setProperty('demuxer-readahead-secs', readaheadSecs);
      }
      _preloading = false;
    }
    if (_disposed) return;
    _errors.setPlaying(playing);
    if (playing) {
      await player.play();
    } else {
      await player.pause();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (!_disposed) await player.seek(position);
  }

  @override
  Future<void> setRate(double rate) async {
    if (!_disposed) await player.setRate(rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    if (!_disposed) {
      final multiplier = 1.0 + (_prefs.audioBoost / 100.0);
      final target = (volume * 100 * multiplier).clamp(0.0, 200.0);
      await player.setVolume(target);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _releaseProxy();
    _errors.dispose();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _operations;
    await player.dispose();
    state.dispose();
  }
}
