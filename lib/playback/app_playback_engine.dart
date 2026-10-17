import 'dart:io' show Platform;

import '../domain/models/preferences.dart';
import 'buffered_playback_engine.dart';
import 'exo_playback_engine.dart';
import 'media_kit_engine.dart';

/// 创建平台默认的播放引擎。
///
/// Android 用 Media3/ExoPlayer（规避部分 Cortex-A73 电视 SoC 在
/// libmpv MediaCodec 硬解首帧时的花屏，软解又不够快）；Windows/macOS
/// 继续用 media_kit (libmpv)。两套引擎都实现 [BufferedPlaybackEngine]
/// 的池化协议，播放会话、预载与切集逻辑完全不感知差异。
BufferedPlaybackEngine createPlaybackEngine({Preferences? preferences}) {
  if (Platform.isAndroid) {
    return ExoPlaybackEngine(preferences: preferences);
  }
  return MediaKitEngine(preferences: preferences);
}
