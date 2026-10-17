import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../shared/widgets.dart';

Widget desktopPlayerButton({
  required String label,
  required IconData icon,
  required VoidCallback? onPressed,
  Key? key,
  bool active = false,
}) => IconButton(
  key: key,
  tooltip: label,
  onPressed: onPressed,
  style: IconButton.styleFrom(
    minimumSize: const Size(36, 36),
    maximumSize: const Size(40, 40),
    padding: const EdgeInsets.all(7),
    foregroundColor: active ? ReelTheme.darkAccent : Colors.white,
    disabledForegroundColor: Colors.white24,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  ),
  icon: Icon(icon, size: 21),
);

class DesktopPlayerControls extends StatelessWidget {
  const DesktopPlayerControls({
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    required this.buffer,
    required this.volume,
    required this.speed,
    required this.fullScreen,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
    required this.onVolume,
    required this.onMute,
    required this.onEpisodes,
    required this.onSpeed,
    required this.onMenu,
    required this.onFullScreen,
    required this.onSeekStart,
    required this.onSeek,
    required this.onSeekEnd,
    required this.onSeekCancel,
    this.danmakuEnabled = false,
    this.onDanmaku,
  });
  final bool playing, fullScreen;
  final bool danmakuEnabled;
  final Duration position, duration, buffer;
  final double volume, speed;
  final VoidCallback onPlayPause,
      onMute,
      onEpisodes,
      onSpeed,
      onMenu,
      onFullScreen,
      onSeekCancel;
  final VoidCallback? onPrevious, onNext, onDanmaku;
  final ValueChanged<double> onVolume;
  final ValueChanged<double>? onSeekStart, onSeek, onSeekEnd;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 560;
      final total = duration.inMilliseconds;
      final fraction = total <= 0
          ? 0.0
          : (position.inMilliseconds / total).clamp(0.0, 1.0);
      final buffered = total <= 0
          ? 0.0
          : (buffer.inMilliseconds / total).clamp(fraction, 1.0);
      return DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Color(0xD9000000)],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 16 : 28,
            36,
            compact ? 16 : 28,
            16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    formatTime(position),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  const Spacer(),
                  Text(
                    formatTime(duration),
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
              SizedBox(
                height: 30,
                child: Listener(
                  onPointerCancel: (_) => onSeekCancel(),
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 10,
                      ),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 5,
                      ),
                      secondaryActiveTrackColor: Colors.white30,
                    ),
                    child: Slider(
                      key: const ValueKey('desktop-seek'),
                      value: fraction,
                      secondaryTrackValue: buffered,
                      onChangeStart: onSeekStart,
                      onChanged: onSeek,
                      onChangeEnd: onSeekEnd,
                      semanticFormatterCallback: (value) => formatTime(
                        Duration(milliseconds: (total * value).round()),
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  desktopPlayerButton(
                    label: '上一集 · PageUp',
                    icon: Icons.skip_previous_rounded,
                    onPressed: onPrevious,
                  ),
                  desktopPlayerButton(
                    key: const ValueKey('desktop-play-pause'),
                    label: '播放 / 暂停 · 空格',
                    icon: playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    onPressed: onPlayPause,
                  ),
                  desktopPlayerButton(
                    label: '下一集 · PageDown',
                    icon: Icons.skip_next_rounded,
                    onPressed: onNext,
                  ),
                  const SizedBox(width: 8),
                  desktopPlayerButton(
                    label: '音量 ${(volume * 100).round()}% · M 静音',
                    icon: volume == 0
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    onPressed: onMute,
                  ),
                  if (!compact)
                    SizedBox(
                      width: 88,
                      child: Slider(
                        key: const ValueKey('desktop-volume'),
                        value: volume,
                        onChanged: onVolume,
                        semanticFormatterCallback: (value) =>
                            '音量 ${(value * 100).round()}%',
                      ),
                    ),
                  const Spacer(),
                  if (!compact)
                    TextButton(
                      onPressed: onSpeed,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        minimumSize: const Size(52, 36),
                      ),
                      child: Text(
                        '${speed}x',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  if (onDanmaku != null)
                    desktopPlayerButton(
                      key: const ValueKey('desktop-danmaku-toggle'),
                      label: danmakuEnabled ? '关闭弹幕 · D' : '打开弹幕 · D',
                      icon: danmakuEnabled
                          ? Icons.subtitles_rounded
                          : Icons.subtitles_off_rounded,
                      onPressed: onDanmaku,
                    ),
                  desktopPlayerButton(
                    key: const ValueKey('desktop-episodes'),
                    label: '选集 · E',
                    icon: Icons.playlist_play_rounded,
                    onPressed: onEpisodes,
                  ),
                  desktopPlayerButton(
                    label: fullScreen ? '退出全屏 · F' : '全屏 · F',
                    icon: fullScreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    onPressed: onFullScreen,
                  ),
                  desktopPlayerButton(
                    key: const ValueKey('desktop-player-menu'),
                    label: '播放菜单',
                    icon: Icons.more_horiz_rounded,
                    onPressed: onMenu,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
