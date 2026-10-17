import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AspectRatio, BoxFit, Center, Clip, FittedBox, ObjectKey, SizedBox,
    Widget;
import 'package:video_player/video_player.dart';

import '../core/errors/app_exception.dart';
import '../domain/models/playback_source.dart';
import '../domain/models/preferences.dart';
import 'buffered_playback_engine.dart';
import 'cenc/cenc_proxy_pool.dart';
import 'native_error_guard.dart';
import 'playback_engine.dart';

/// Android 专用引擎：Media3/ExoPlayer（MediaCodec 标准路径）。
///
/// libmpv 的 `mediacodec*` 硬解在部分 Cortex-A73 电视 SoC 上首帧会渲染
/// 未初始化纹理（每集开头 1-3 秒花屏/白块），软解又不够快。ExoPlayer 走
/// AndroidX Media3 的 MediaCodec 管线，首帧就绪前不会向 Surface 送任何
/// 数据，从根上规避该问题，也是各大视频 App 的标准解码路径。
///
/// 引擎生命周期与 [BufferedPlaybackEngine] 对齐：待播分集先在 standby
/// 引擎里完成 prepare（解码器就绪、首帧已出），promote 时瞬时切换。
///
/// [allowMediaPreload] 为 false 时（电视/盒子）不创建待机解码器：廉价
/// 电视 SoC 的 HEVC surface 解码实例只允许极少数并存，活动播放器 +
/// 待机播放器双解码会在待机实例初始化时把活动解码器挤掉，真机表现
/// 为每集播放约 3 秒后报错换源、循环失败。电视端切集退回活动引擎
/// 就地重开（URL 级预取不占解码器，仍然有效）。
final class ExoPlaybackEngine extends BufferedPlaybackEngine {
  ExoPlaybackEngine({
    Preferences? preferences,
    VideoViewType viewType = VideoViewType.textureView,
    this.allowMediaPreload = true,
  }) : super((_) => _ExoPlayer(preferences, viewType));

  final bool allowMediaPreload;

  _ExoPlayer get _activePlayer => activeEngine as _ExoPlayer;

  @override
  Future<void> preload(PlaybackSource source, {required String episodeId}) =>
      allowMediaPreload
      ? super.preload(source, episodeId: episodeId)
      : Future<void>.value();

  @override
  Widget? videoView({String? episodeId, BoxFit fit = BoxFit.contain}) {
    final player = episodeId == null
        ? _activePlayer
        : engineForEpisode(episodeId) as _ExoPlayer?;
    final controller = player?.controller;
    if (controller == null || !controller.value.isInitialized) return null;
    final raw = controller.value.aspectRatio;
    final aspect = (raw > 0 && raw.isFinite) ? raw : 9 / 16;
    if (fit == BoxFit.contain) {
      return Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: VideoPlayer(controller, key: ObjectKey(controller)),
        ),
      );
    }
    // cover/fill：按视频真实尺寸铺满或拉伸，交给 FittedBox 裁切。
    final size = controller.value.size;
    return Center(
      child: FittedBox(
        fit: fit,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: size.width > 0 ? size.width : 9,
          height: size.height > 0 ? size.height : 16,
          child: VideoPlayer(controller, key: ObjectKey(controller)),
        ),
      ),
    );
  }

  @override
  double? get videoAspect {
    final controller = _activePlayer.controller;
    if (controller == null || !controller.value.isInitialized) return null;
    final size = controller.value.size;
    if (size.width <= 0 || size.height <= 0) return null;
    return size.width / size.height;
  }

  @override
  Future<void> pauseActive() async {
    try {
      await _activePlayer.setPlaying(false);
    } on Object catch (_) {}
  }

  @override
  void applyPreferences(Preferences preferences) {
    super.applyPreferences(preferences);
    _activePlayer.updatePreferences(preferences);
  }
}

final class _ExoPlayer implements PlaybackEngine {
  _ExoPlayer([
    Preferences? preferences,
    this._viewType = VideoViewType.textureView,
  ]) : _prefs = preferences ?? const Preferences() {
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
  }

  static const _initializationTimeout = Duration(seconds: 20);

  Preferences _prefs;
  final VideoViewType _viewType;
  late final NativeErrorGuard _errors;
  VideoPlayerController? _controller;
  VoidCallback? _listener;
  Timer? _positionPoll;
  Future<void> _operations = Future.value();
  bool _disposed = false;
  Uri? _proxyUrl;

  @override
  final ValueNotifier<EngineSnapshot> state = ValueNotifier(
    const EngineSnapshot(),
  );

  VideoPlayerController? get controller => _controller;

  void updatePreferences(Preferences preferences) {
    _prefs = preferences;
  }

  void _emit(EngineSnapshot next) {
    if (!_disposed) state.value = next;
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.then((_) => operation());
    _operations = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _releaseProxy() {
    final url = _proxyUrl;
    _proxyUrl = null;
    if (url == null) return;
    CencProxyPool.release(url);
  }

  VideoPlayerController _createController(
    Uri uri, {
    required Map<String, String> headers,
    VideoFormat? formatHint,
  }) => VideoPlayerController.networkUrl(
    uri,
    viewType: _viewType,
    formatHint: formatHint,
    httpHeaders: headers,
    videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
  );

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
    await _releaseController();
    _releaseProxy();
    if (!valid()) return;
    debugPrint(
      '[ExoEngine] open kind=${source.kind.name} route=${source.route.name} '
      'quality=${source.quality} host=${source.uri.host}',
    );
    var playUri = source.uri;
    var playHeaders = source.headers;
    if (source.kind == PlaybackKind.cenc) {
      if (source.contentKey?.length != 16) {
        throw const AppException('本集播放信息不完整，请重试');
      }
      // 与参考实现一致：CENC 媒体先由本机代理解密成明文 MP4 再交给播放器。
      try {
        final proxy = await CencProxyPool.acquire();
        final local = await proxy.open(source);
        if (!valid()) {
          proxy.release(local);
          return;
        }
        _proxyUrl = local;
        playUri = local;
        playHeaders = const {};
      } on Object catch (error) {
        debugPrint('[ExoEngine] CENC 本地转发不可用: $error');
        _releaseProxy();
        throw const AppException('本集播放信息不完整，请重试');
      }
    }
    final isHls =
        playUri.path.toLowerCase().endsWith('.m3u8') ||
        playUri.toString().toLowerCase().contains('.m3u8?');
    var formatHint = isHls ? VideoFormat.hls : null;

    if (!valid()) return;
    _emit(const EngineSnapshot(buffering: true));
    var controller = _createController(
      playUri,
      headers: playHeaders,
      formatHint: formatHint,
    );
    try {
      await controller.initialize().timeout(_initializationTimeout);
    } on Object catch (error) {
      if (_disposed || !isCurrent()) {
        await _disposeController(controller);
        return;
      }
      // 来源未标注 HLS 且初始化失败时，按参考实现做一次格式自愈重试。
      if (formatHint == null && !playUri.isScheme('file')) {
        debugPrint('[ExoEngine] 初始化失败，切换 HLS 格式重试: $error');
        await _disposeController(controller);
        if (!valid()) return;
        formatHint = VideoFormat.hls;
        controller = _createController(
          playUri,
          headers: playHeaders,
          formatHint: formatHint,
        );
        try {
          await controller.initialize().timeout(_initializationTimeout);
        } on Object {
          if (_disposed || !isCurrent()) {
            await _disposeController(controller);
            return;
          }
          await _disposeController(controller);
          throw const AppException(
            '视频加载失败，请重试或切换下一集',
            kind: FailureKind.playback,
          );
        }
      } else {
        await _disposeController(controller);
        throw AppException(
          '视频加载失败，请重试或切换下一集',
          kind: FailureKind.playback,
        );
      }
    }
    if (!valid()) {
      await _disposeController(controller);
      return;
    }
    _controller = controller;
    _listener = () => _onControllerChanged(controller);
    controller.addListener(_listener!);
    _startPositionPoll();
    _emit(
      state.value.copyWith(
        duration: controller.value.duration,
        buffering: controller.value.isBuffering,
      ),
    );
    if (start > Duration.zero) {
      try {
        await controller.seekTo(start).timeout(const Duration(seconds: 3));
      } on Object catch (_) {}
      if (!valid()) return;
      _emit(state.value.copyWith(position: start));
    }
  });

  @override
  Future<void> stop() => _serialize(() async {
    if (_disposed) return;
    _errors.reset();
    _errors.setPlaying(false);
    _positionPoll?.cancel();
    _positionPoll = null;
    await _releaseController();
    _releaseProxy();
    _emit(const EngineSnapshot());
  });

  @override
  Future<void> setPlaying(bool playing) async {
    final controller = _controller;
    if (_disposed || controller == null) return;
    _errors.setPlaying(playing);
    try {
      if (playing) {
        await controller.play().timeout(const Duration(seconds: 3));
      } else {
        await controller.pause();
      }
    } on TimeoutException catch (error) {
      _reportError('播放响应超时，请重试', error);
    } on Object catch (error) {
      _reportError('播放失败，请重试', error);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    final controller = _controller;
    if (_disposed || controller == null) return;
    try {
      await controller.seekTo(position);
      _emit(state.value.copyWith(position: position));
    } on Object catch (_) {}
  }

  @override
  Future<void> setRate(double rate) async {
    final controller = _controller;
    if (_disposed || controller == null) return;
    try {
      await controller.setPlaybackSpeed(
        rate.isFinite && rate > 0 ? rate.clamp(0.25, 4.0) : 1.0,
      );
    } on Object catch (_) {}
  }

  @override
  Future<void> setVolume(double volume) async {
    final controller = _controller;
    if (_disposed || controller == null) return;
    try {
      // ExoPlayer 音量上限 1.0；音频增强只在 0-100% 范围内生效。
      final multiplier = 1.0 + (_prefs.audioBoost / 100.0);
      await controller.setVolume(
        (volume * multiplier).clamp(0.0, 1.0),
      );
    } on Object catch (_) {}
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _errors.dispose();
    _positionPoll?.cancel();
    _positionPoll = null;
    await _operations;
    await _releaseController();
    _releaseProxy();
    state.dispose();
  }

  void _startPositionPoll() {
    _positionPoll?.cancel();
    _positionPoll = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final controller = _controller;
      if (_disposed || controller == null || !controller.value.isInitialized) {
        return;
      }
      _errors.progress(controller.value.position);
      final position = controller.value.position;
      if (position != state.value.position) {
        _emit(state.value.copyWith(position: position));
      }
    });
  }

  void _onControllerChanged(VideoPlayerController controller) {
    if (_disposed || _controller != controller) return;
    final value = controller.value;
    if (value.hasError) {
      _reportError(value.errorDescription ?? '播放器发生未知错误', null);
      return;
    }
    _emit(
      state.value.copyWith(
        playing: value.isPlaying,
        buffering: value.isBuffering,
        duration: value.duration > Duration.zero ? value.duration : null,
        // isCompleted 必须双向同步：seek 离开片尾后要能把快照里的
        // completed 重置回 false，否则会话会认为本集已播完。
        completed: value.duration > Duration.zero ? value.isCompleted : null,
        buffer: value.buffered.isEmpty ? null : value.buffered.last.end,
      ),
    );
  }

  void _reportError(String message, Object? cause) {
    debugPrint('[ExoEngine] error: $message (${cause ?? ''})');
    _errors.reportError();
    // 把 Exo 的原始错误类别带出来：真机上失败 UI 展示的这条消息是
    // 判断解码器/网络类问题的关键线索。
    final match = RegExp('ERROR_CODE_[A-Z_]+').firstMatch(message);
    final code = match?.group(0);
    final detail = code == null ? message : '视频播放失败（$code）';
    if (state.value.error != detail) {
      _emit(state.value.copyWith(error: detail, buffering: false));
    }
  }

  Future<void> _releaseController() async {
    final controller = _controller;
    final listener = _listener;
    _controller = null;
    _listener = null;
    if (controller == null) return;
    if (listener != null) controller.removeListener(listener);
    await _disposeController(controller);
  }

  Future<void> _disposeController(VideoPlayerController controller) async {
    try {
      await controller.dispose().timeout(const Duration(seconds: 2));
    } on Object catch (error) {
      debugPrint('[ExoEngine] release incomplete: $error');
    }
  }
}
