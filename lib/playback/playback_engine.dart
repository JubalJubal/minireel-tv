import 'package:flutter/foundation.dart';

import '../domain/models/playback_source.dart';

final class EngineSnapshot {
  const EngineSnapshot({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffer = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.error,
  });
  final Duration position;
  final Duration duration;
  final Duration buffer;
  final bool playing;
  final bool buffering;
  final bool completed;
  final String? error;

  EngineSnapshot copyWith({
    Duration? position,
    Duration? duration,
    Duration? buffer,
    bool? playing,
    bool? buffering,
    bool? completed,
    String? error,
  }) => EngineSnapshot(
    position: position ?? this.position,
    duration: duration ?? this.duration,
    buffer: buffer ?? this.buffer,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    completed: completed ?? this.completed,
    error: error ?? this.error,
  );
}

abstract interface class PlaybackEngine {
  ValueListenable<EngineSnapshot> get state;
  Future<void> open(
    PlaybackSource source, {
    required Duration start,
    required bool Function() isCurrent,
    String? episodeId,
  });
  Future<void> stop();
  Future<void> setPlaying(bool playing);
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> dispose();
}

/// Optional native media buffering, separate from playback URL resolution.
abstract interface class PreloadingPlaybackEngine {
  Future<void> preload(PlaybackSource source, {required String episodeId});
  void discardPreload();

  /// 已缓冲就绪、可直接 promote 的分集 id（没有则为 null）。
  ///
  /// 播放会话用它判断切集能否走瞬时切换：能的话就不必先停下来等，
  /// 也不用闪一层「正在加载短剧」。
  String? get preloadedEpisodeId;
}
