import 'dart:ui';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../shared/widgets.dart';

class PlayerGlass extends StatelessWidget {
  const PlayerGlass({super.key, required this.child, this.radius = 24});
  final Widget child;
  final double radius;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xCF12141A),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: Colors.white.withValues(alpha: .13),
            width: .7,
          ),
        ),
        child: child,
      ),
    ),
  );
}

class PlayerControlButton extends StatelessWidget {
  const PlayerControlButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.prominent = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool prominent;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: prominent ? 48 : 42,
    height: prominent ? 48 : 42,
    child: IconButton(
      tooltip: label,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: prominent
            ? Colors.white
            : Colors.white.withValues(alpha: .12),
      ),
      icon: Icon(
        icon,
        size: prominent ? 26 : 21,
        color: onPressed == null
            ? Colors.white24
            : prominent
            ? const Color(0xFF12141A)
            : Colors.white,
      ),
    ),
  );
}

class PortraitPlayerControls extends StatelessWidget {
  const PortraitPlayerControls({
    super.key,
    required this.playing,
    required this.episode,
    required this.episodeCount,
    required this.position,
    required this.duration,
    required this.value,
    required this.right,
    required this.onCollapse,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    required this.onLandscape,
    required this.onLock,
    required this.onSeekStart,
    required this.onSeek,
    required this.onSeekEnd,
    required this.onSeekCancel,
    this.danmakuEnabled = false,
    this.onDanmaku,
  });
  final bool playing, right;
  final int episode, episodeCount;
  final Duration position, duration;
  final double value;
  final VoidCallback onCollapse, onPlayPause, onLandscape, onLock, onSeekCancel;
  final VoidCallback? onPrevious, onNext;
  final bool danmakuEnabled;
  final VoidCallback? onDanmaku;
  final ValueChanged<double>? onSeekStart, onSeek, onSeekEnd;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    child: PlayerGlass(
      radius: 28,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 30,
              width: 44,
              child: IconButton(
                tooltip: '收起控制栏',
                padding: EdgeInsets.zero,
                onPressed: onCollapse,
                icon: Icon(
                  right
                      ? Icons.chevron_right_rounded
                      : Icons.chevron_left_rounded,
                  size: 22,
                  color: Colors.white70,
                ),
              ),
            ),
            const SizedBox(height: 5),
            PlayerControlButton(
              label: '上一集',
              icon: Icons.skip_previous_rounded,
              onPressed: onPrevious,
            ),
            const SizedBox(height: 7),
            PlayerControlButton(
              label: playing ? '暂停' : '播放',
              icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              onPressed: onPlayPause,
              prominent: true,
            ),
            const SizedBox(height: 9),
            Text(
              '$episode / $episodeCount',
              style: const TextStyle(color: Colors.white70, fontSize: 10),
            ),
            const SizedBox(height: 12),
            const Text(
              '进度',
              style: TextStyle(color: Colors.white54, fontSize: 9),
            ),
            const SizedBox(height: 4),
            Text(
              formatTime(position),
              key: const ValueKey('rail-current-time'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            Listener(
              onPointerCancel: (_) => onSeekCancel(),
              child: SizedBox(
                height: 108,
                width: 34,
                child: RotatedBox(
                  // The horizontal slider's start is rotated to the TOP, not bottom.
                  quarterTurns: 1,
                  child: Slider(
                    key: const ValueKey('rail-progress'),
                    value: value,
                    activeColor: Colors.white,
                    semanticFormatterCallback: (_) =>
                        '${formatTime(position)}，共 ${formatTime(duration)}',
                    onChangeStart: onSeekStart,
                    onChanged: onSeek,
                    onChangeEnd: onSeekEnd,
                  ),
                ),
              ),
            ),
            Text(
              duration > Duration.zero ? formatTime(duration) : '--:--',
              key: const ValueKey('rail-total-time'),
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 10),
            PlayerControlButton(
              label: '下一集',
              icon: Icons.skip_next_rounded,
              onPressed: onNext,
            ),
            const SizedBox(height: 7),
            PlayerControlButton(
              label: danmakuEnabled ? '关闭弹幕' : '打开弹幕',
              icon: danmakuEnabled
                  ? Icons.subtitles_rounded
                  : Icons.subtitles_off_rounded,
              onPressed: onDanmaku,
            ),
            const SizedBox(height: 7),
            PlayerControlButton(
              label: '横屏播放',
              icon: Icons.stay_current_landscape_rounded,
              onPressed: onLandscape,
            ),
            const SizedBox(height: 7),
            PlayerControlButton(
              label: '锁定屏幕',
              icon: Icons.lock_outline_rounded,
              onPressed: onLock,
            ),
          ],
        ),
      ),
    ),
  );
}

class LandscapePlayerControls extends StatelessWidget {
  const LandscapePlayerControls({
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    required this.value,
    required this.speed,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    required this.onEpisodes,
    required this.onSpeed,
    required this.onPortrait,
    required this.onLock,
    required this.onSeekStart,
    required this.onSeek,
    required this.onSeekEnd,
    required this.onSeekCancel,
    this.danmakuEnabled = false,
    this.onDanmaku,
  });
  final bool playing;
  final Duration position, duration;
  final double value, speed;
  final VoidCallback? onPrevious, onNext;
  final VoidCallback onPlayPause,
      onEpisodes,
      onSpeed,
      onPortrait,
      onLock,
      onSeekCancel;
  final bool danmakuEnabled;
  final VoidCallback? onDanmaku;
  final ValueChanged<double>? onSeekStart, onSeek, onSeekEnd;

  @override
  Widget build(BuildContext context) => PlayerGlass(
    radius: 20,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(15, 5, 15, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                formatTime(position),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              Expanded(
                child: Listener(
                  onPointerCancel: (_) => onSeekCancel(),
                  child: Slider(
                    key: const ValueKey('landscape-progress'),
                    value: value,
                    activeColor: ReelTheme.darkAccent,
                    semanticFormatterCallback: (_) =>
                        '${formatTime(position)}，共 ${formatTime(duration)}',
                    onChangeStart: onSeekStart,
                    onChanged: onSeek,
                    onChangeEnd: onSeekEnd,
                  ),
                ),
              ),
              Text(
                duration > Duration.zero ? formatTime(duration) : '--:--',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
          Row(
            children: [
              PlayerControlButton(
                label: '上一集',
                icon: Icons.skip_previous_rounded,
                onPressed: onPrevious,
              ),
              const SizedBox(width: 8),
              PlayerControlButton(
                label: playing ? '暂停' : '播放',
                icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                onPressed: onPlayPause,
                prominent: true,
              ),
              const SizedBox(width: 8),
              PlayerControlButton(
                label: '下一集',
                icon: Icons.skip_next_rounded,
                onPressed: onNext,
              ),
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: onEpisodes,
                icon: const Icon(Icons.grid_view_rounded, size: 18),
                label: const Text('选集'),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
              ),
              TextButton(
                onPressed: onSpeed,
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: Text('${speed}x'),
              ),
              const Spacer(),
              PlayerControlButton(
                label: danmakuEnabled ? '关闭弹幕' : '打开弹幕',
                icon: danmakuEnabled
                    ? Icons.subtitles_rounded
                    : Icons.subtitles_off_rounded,
                onPressed: onDanmaku,
              ),
              const SizedBox(width: 9),
              PlayerControlButton(
                label: '锁定屏幕',
                icon: Icons.lock_outline_rounded,
                onPressed: onLock,
              ),
              const SizedBox(width: 9),
              PlayerControlButton(
                label: '切回竖屏',
                icon: Icons.stay_current_portrait_rounded,
                onPressed: onPortrait,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class PlayerLockButton extends StatelessWidget {
  const PlayerLockButton({super.key, required this.onUnlock});
  final VoidCallback onUnlock;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '解锁屏幕',
    button: true,
    child: GestureDetector(
      key: const ValueKey('player-unlock'),
      onTap: onUnlock,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: PlayerGlass(
            radius: 18,
            child: const SizedBox(
              width: 34,
              height: 34,
              child: Icon(
                Icons.lock_outline_rounded,
                size: 18,
                color: ReelTheme.darkAccent,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
