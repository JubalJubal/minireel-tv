import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app/app_controller.dart';
import '../../app/theme.dart';
import '../../domain/models/drama.dart';
import '../../domain/models/preferences.dart';
import '../../domain/models/remote_key_map.dart';
import '../../playback/device_controls.dart';
import '../../playback/media_kit_engine.dart';
import '../../playback/playback_session.dart';
import '../shared/widgets.dart';
import 'tv_focus.dart';

/// TV 版播放器。
///
/// 复用 PlaybackSession + MediaKitEngine + DeviceControls 的全部播放逻辑。
/// UI 全新：横屏固定、无手势、D-pad 控件栏。
/// 遥控器映射：
///   OK/ENTER → 播放/暂停（无焦点时）/ 激活按钮（有焦点时）
///   左右 → 焦点在控件间移动 / 长按快进快退 10s
///   上下 → 切换焦点区（视频区 ↔ 控件栏）
///   BACK → 退出播放器
///   MENU → 弹出选集/速度/画质面板
class TVPlayerScreen extends StatefulWidget {
  const TVPlayerScreen({super.key, required this.drama, this.initialEpisode});
  final Drama drama;
  final int? initialEpisode;
  @override
  State<TVPlayerScreen> createState() => _TVPlayerScreenState();
}

class _TVPlayerScreenState extends State<TVPlayerScreen>
    with WidgetsBindingObserver {
  late final AppController _app;
  late final MediaKitEngine _engine;
  late final PlaybackSession _session;
  late final DeviceControls _device;
  bool _controlsVisible = true;
  bool _sheetOpen = false;
  bool _foreground = true;
  bool _awake = false;
  bool _closing = false;
  Timer? _hideTimer;
  // seek 预览
  Duration? _seekPreview;
  // 边界提示（没有上/下集）
  String? _edgeToast;
  Timer? _edgeToastTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _app = AppScope.read(context);
    _engine = MediaKitEngine(preferences: _app.preferences);
    _device = DeviceControls(_engine);
    _session = PlaybackSession(
      app: _app,
      engine: _engine,
      drama: widget.drama,
    );
    _session.addListener(_sessionChanged);
    unawaited(_prepareDevice());
    unawaited(_session.initialize(initialEpisode: widget.initialEpisode));
    _showControls();
    // 注册调试悬浮面板动作：与控制栏的焦点导航共用同一套入口。
    tvPlayerDebugActions = TVPlayerDebugActions(
      onUp: () => _onRemoteDirection(RemoteAction.up),
      onDown: () => _onRemoteDirection(RemoteAction.down),
      onLeft: () => _onRemoteDirection(RemoteAction.left),
      onRight: () => _onRemoteDirection(RemoteAction.right),
      onOk: _debugOk,
    );
  }

  /// 调试手柄 OK 键：与控制栏的焦点状态联动。
  ///
  /// 控制栏收起 → 唤出并聚焦播放键；焦点已在控制栏按钮上 → 激活该按钮
  /// （走 TVFocusable 的全局激活信号）；其余情况 → 播放/暂停。
  void _debugOk() {
    if (!_controlsVisible) {
      _showControls();
      return;
    }
    if (_focusInControls) {
      tvActivateSignal.value++;
      return;
    }
    _togglePlay();
  }

  /// 调试悬浮面板方向键入口：与真实遥控器走同一套逻辑。
  void _onRemoteDirection(RemoteAction action) {
    if (_sheetOpen) return;
    final direction = switch (action) {
      RemoteAction.left => TraversalDirection.left,
      RemoteAction.right => TraversalDirection.right,
      RemoteAction.up => TraversalDirection.up,
      RemoteAction.down => TraversalDirection.down,
      _ => null,
    };
    if (direction != null) _handleDirectionalKey(direction);
  }

  /// 方向键统一入口。
  ///
  /// 控制栏收起时，任意方向键 = 唤出控制栏并把焦点放到播放键上；
  /// 控制栏展开后，方向键改为在按钮之间移动焦点 —— 播放/暂停、快进快退、
  /// 上一集下一集，以及下面那一排功能按钮都靠它选择、OK 确认。
  void _handleDirectionalKey(TraversalDirection direction) {
    if (!_controlsVisible) {
      _showControls();
      return;
    }
    handleDpadDirection(direction);
    _restartHideTimer();
  }

  Future<void> _prepareDevice() async {
    if (Platform.isAndroid) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      if (!mounted || _closing) return;
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    await _device.initialize();
    if (mounted && !_closing) setState(() {});
  }

  int? _currentEpisodeIndexForSkip;
  bool _introSkipped = false;
  bool _outroSkipped = false;

  void _sessionChanged() {
    if (!mounted || _closing) return;
    final awake = _foreground &&
        (_session.playing || _session.buffering) &&
        !_sheetOpen;
    if (awake != _awake) {
      _awake = awake;
      unawaited(_device.keepAwake(awake));
    }
    if (_session.playing && !_session.buffering && !_sheetOpen) {
      _ensureHideTimer();
    }
    _checkAutoSkip();
    setState(() {});
  }

  void _checkAutoSkip() {
    if (!_session.playing || _session.buffering || _session.duration <= Duration.zero) {
      return;
    }

    final epIndex = _session.currentIndex;
    if (_currentEpisodeIndexForSkip != epIndex) {
      _currentEpisodeIndexForSkip = epIndex;
      _introSkipped = false;
      _outroSkipped = false;
    }

    // 自动跳过片头
    final skipIntro = _app.preferences.skipIntroSeconds;
    if (skipIntro > 0 && !_introSkipped) {
      if (_session.position < const Duration(seconds: 1)) {
        _introSkipped = true;
        unawaited(_session.seek(Duration(seconds: skipIntro)));
        _showEdgeToast('已跳过片头 $skipIntro 秒');
        return;
      }
    }

    // 自动跳过片尾
    final skipOutro = _app.preferences.skipOutroSeconds;
    if (skipOutro > 0 &&
        !_outroSkipped &&
        _app.preferences.autoNext &&
        _session.canNext &&
        _session.duration > const Duration(seconds: 15)) {
      final remaining = _session.duration - _session.position;
      if (remaining <= Duration(seconds: skipOutro)) {
        _outroSkipped = true;
        _showEdgeToast('已跳过片尾，自动播放下一集');
        _changeEpisode(true);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closing) return;
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _session.release('background');
    } else {
      _session.boost(false);
      _session.hold('background');
      try {
        _engine.player.pause();
      } catch (_) {}
    }
    _sessionChanged();
  }

  void _showControls() {
    _controlsVisible = true;
    if (mounted) setState(() {});
    _restartHideTimer();
    // 焦点落到播放/暂停键：这样方向键立刻就能在控制栏里导航，
    // 不用「先按一下唤出、再按一下才选中」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controlsVisible) {
        TVFocusRegistry.get(_playToggleRole)?.requestFocus();
      }
    });
  }

  /// 播放/暂停按钮的焦点角色，唤出控制栏时用它定位焦点。
  static const String _playToggleRole = 'ctrl:playToggle';

  /// 焦点是否停在控制栏按钮上。停着的时候不做自动收起，
  /// 否则用户正选着按钮就被收走了。
  bool get _focusInControls {
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return false;
    return TVFocusRegistry.roleOf(node)?.startsWith('ctrl:') ?? false;
  }

  /// 重置并启动自动隐藏定时器（由用户交互或状态恢复触发）。
  void _restartHideTimer() {
    _hideTimer?.cancel();
    final timeout = _app.preferences.controlsAutoHideSeconds;
    if (timeout <= 0) return; // 0 表示从不自动隐藏
    _hideTimer = Timer(Duration(seconds: timeout), () {
      if (!mounted ||
          _closing ||
          !_session.playing ||
          _session.buffering ||
          _sheetOpen ||
          _seekPreview != null) {
        return;
      }
      // 焦点还在控制栏按钮上（用户正在选）→ 续一轮，不收起
      if (_focusInControls) {
        _restartHideTimer();
        return;
      }
      setState(() => _controlsVisible = false);
    });
  }

  /// 确保自动隐藏定时器正在运行。
  /// 关键修复：若当前定时器已在倒计时中，绝不能在播放 tick 中 cancel 重置它，
  /// 否则播放时高频事件会导致定时器永远无法触发。
  void _ensureHideTimer() {
    final timeout = _app.preferences.controlsAutoHideSeconds;
    if (timeout <= 0) {
      _hideTimer?.cancel();
      return;
    }
    if (_hideTimer != null && _hideTimer!.isActive) {
      return;
    }
    _restartHideTimer();
  }

  /// 显示边界提示（没有上/下集），2 秒后自动消失。
  void _showEdgeToast(String message) {
    _edgeToast = message;
    _edgeToastTimer?.cancel();
    _edgeToastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && !_closing) {
        setState(() => _edgeToast = null);
      }
    });
    _showControls();
  }

  void _togglePlay() {
    _session.togglePlay();
    _showControls();
  }

  /// 遥控器左右键 seek
  void _seekBy(Duration delta) {
    if (_session.duration == Duration.zero) return;
    final current = _seekPreview ?? _session.position;
    var target = current + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > _session.duration) target = _session.duration;
    _seekPreview = target;
    _showControls();
    // 防抖：停止操作 800ms 后真正 seek
    _seekDebounce?.cancel();
    _seekDebounce = Timer(const Duration(milliseconds: 800), () {
      if (_seekPreview != null && mounted) {
        unawaited(_session.seek(_seekPreview!));
        _seekPreview = null;
        setState(() {});
        if (_controlsVisible) _restartHideTimer();
      }
    });
  }

  Timer? _seekDebounce;

  void _changeEpisode(bool next) {
    if (_session.episodes.isEmpty) return;
    if (next && !_session.canNext) {
      _showEdgeToast('没有下集了');
      return;
    }
    if (!next && !_session.canPrevious) {
      _showEdgeToast('没有上集了');
      return;
    }
    unawaited(next ? _session.next() : _session.previous());
    _showControls();
  }

  Future<void> _openEpisodes() async {
    _session.hold('sheet');
    setState(() => _sheetOpen = true);
    try {
      final result = await showReelSheet<Episode>(
        context,
        dark: true,
        builder: (context) => SheetFrame(
          title: '选集',
          subtitle: '共 ${_session.episodes.length} 集',
          child: _EpisodeGrid(
            episodes: _session.episodes,
            current: _session.episode?.index,
            onSelect: (episode) => Navigator.of(context).pop(episode),
          ),
        ),
      );
      if (result != null) {
        final index = _session.episodes.indexOf(result);
        unawaited(_session.playEpisode(index));
      }
    } finally {
      if (mounted && !_closing) {
        setState(() => _sheetOpen = false);
        _session.release('sheet');
        _showControls();
      }
    }
  }

  Future<void> _openSpeed() async {
    _session.hold('sheet');
    setState(() => _sheetOpen = true);
    try {
      final result = await showReelSheet<double>(
        context,
        dark: true,
        builder: (context) => SheetFrame(
          title: '倍速',
          subtitle: '当前 ${_app.preferences.speed}x',
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 9,
              runSpacing: 9,
              children: [
                for (final speed in playbackSpeeds)
                  SizedBox(
                    width: (constraints.maxWidth - 18) / 3,
                    child: TVFocusable(
                      radius: 12,
                      onTap: () => Navigator.of(context).pop(speed),
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: speed == _app.preferences.speed
                              ? context.colors.primary
                              : Colors.white.withValues(alpha: .08),
                        ),
                        onPressed: null,
                        child: Text('${speed}x'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      if (result != null) _session.setSpeed(result);
    } finally {
      if (mounted && !_closing) {
        setState(() => _sheetOpen = false);
        _session.release('sheet');
        _showControls();
      }
    }
  }

  Future<void> _openQuality() async {
    final choices = _session.options?.sources.map((s) => s.quality).toSet() ??
        {_session.currentQuality};
    _session.hold('sheet');
    setState(() => _sheetOpen = true);
    try {
      final result = await showReelSheet<String>(
        context,
        dark: true,
        builder: (context) => SheetFrame(
          title: '画质',
          subtitle: choices.length == 1 ? '这集提供一种画质' : '切换后会保留当前播放进度',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final quality in choices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: TVFocusable(
                    radius: 12,
                    onTap: () => Navigator.of(context).pop(quality),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        quality,
                        style: TextStyle(
                          fontSize: 15,
                          color: quality == _session.currentQuality
                              ? context.colors.primary
                              : Colors.white,
                        ),
                      ),
                      trailing: quality == _session.currentQuality
                          ? Icon(
                              Icons.check_rounded,
                              color: context.colors.primary,
                              size: 20,
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      if (result != null) unawaited(_session.setQuality(result));
    } finally {
      if (mounted && !_closing) {
        setState(() => _sheetOpen = false);
        _session.release('sheet');
        _showControls();
      }
    }
  }

  String _fitLabel(String mode) => switch (mode) {
    'cover' => '撑满',
    'fill' => '拉伸',
    _ => '比例',
  };

  Future<void> _openFitMode() async {
    _session.hold('sheet');
    setState(() => _sheetOpen = true);
    final modes = {
      'contain': '原始比例（包含全图·两侧留黑）',
      'cover': '撑满裁切（无黑边沉浸·放大填屏）',
      'fill': '拉伸铺满（画面铺满·适应屏幕）',
    };
    try {
      final result = await showReelSheet<String>(
        context,
        dark: true,
        builder: (context) => SheetFrame(
          title: '画面比例与填充',
          subtitle: '当前：${modes[_app.preferences.videoFitMode] ?? "原始比例"}',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in modes.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TVFocusable(
                    radius: 12,
                    autofocus: entry.key == _app.preferences.videoFitMode,
                    onTap: () => Navigator.of(context).pop(entry.key),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                      decoration: BoxDecoration(
                        color: entry.key == _app.preferences.videoFitMode
                            ? context.colors.primary.withValues(alpha: .18)
                            : Colors.white.withValues(alpha: .06),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: entry.key == _app.preferences.videoFitMode
                              ? context.colors.primary
                              : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            entry.value,
                            style: TextStyle(
                              color: entry.key == _app.preferences.videoFitMode
                                  ? context.colors.primary
                                  : Colors.white,
                              fontSize: 14.5,
                              fontWeight: entry.key == _app.preferences.videoFitMode
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                          if (entry.key == _app.preferences.videoFitMode)
                            Icon(Icons.check_rounded, color: context.colors.primary, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      if (result != null) {
        _app.setPreferences(_app.preferences.copyWith(videoFitMode: result));
      }
    } finally {
      if (mounted && !_closing) {
        setState(() => _sheetOpen = false);
        _session.release('sheet');
        _showControls();
      }
    }
  }

  String _audioBoostLabel(int boost) => switch (boost) {
    25 => '人声+25%',
    50 => '增强+50%',
    100 => '倍增+100%',
    _ => '原声音量',
  };

  Future<void> _openAudioBoost() async {
    _session.hold('sheet');
    setState(() => _sheetOpen = true);
    final boosts = {
      0: '原始音量（100% 标准输出）',
      25: '清晰人声（+25% 对白清晰）',
      50: '沉浸增强（+50% 推荐·声音更洪亮）',
      100: '极限双倍（+100% 极小音量片源放大）',
    };
    try {
      final result = await showReelSheet<int>(
        context,
        dark: true,
        builder: (context) => SheetFrame(
          title: '声音与人声增强',
          subtitle: '当前：${boosts[_app.preferences.audioBoost] ?? "原始音量"}',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in boosts.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TVFocusable(
                    radius: 12,
                    autofocus: entry.key == _app.preferences.audioBoost,
                    onTap: () => Navigator.of(context).pop(entry.key),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                      decoration: BoxDecoration(
                        color: entry.key == _app.preferences.audioBoost
                            ? context.colors.primary.withValues(alpha: .18)
                            : Colors.white.withValues(alpha: .06),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: entry.key == _app.preferences.audioBoost
                              ? context.colors.primary
                              : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            entry.value,
                            style: TextStyle(
                              color: entry.key == _app.preferences.audioBoost
                                  ? context.colors.primary
                                  : Colors.white,
                              fontSize: 14.5,
                              fontWeight: entry.key == _app.preferences.audioBoost
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                          if (entry.key == _app.preferences.audioBoost)
                            Icon(Icons.check_rounded, color: context.colors.primary, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      if (result != null) {
        final newPrefs = _app.preferences.copyWith(audioBoost: result);
        _app.setPreferences(newPrefs);
        _engine.updatePreferences(newPrefs);
        unawaited(_engine.setVolume(_device.volume));
      }
    } finally {
      if (mounted && !_closing) {
        setState(() => _sheetOpen = false);
        _session.release('sheet');
        _showControls();
      }
    }
  }

  bool _cleanedUp = false;

  void _cleanup() {
    if (_cleanedUp) return;
    _cleanedUp = true;
    _closing = true;
    try {
      _engine.player.pause();
      _engine.player.stop();
    } catch (_) {}
    unawaited(_session.close());
  }

  void _exit() {
    if (_closing) return;
    _cleanup();
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _cleanup();
    if (tvPlayerDebugActions != null) {
      tvPlayerDebugActions = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _seekDebounce?.cancel();
    _edgeToastTimer?.cancel();
    _session.removeListener(_sessionChanged);
    _session.dispose();
    unawaited(_device.dispose());
    if (Platform.isAndroid) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      unawaited(SystemChrome.setPreferredOrientations([]));
    }
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_sheetOpen) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyMap = _app.remoteKeyMap;
    final step = Duration(seconds: _app.preferences.seekStepSeconds);

    // BACK / ESC → 若控制栏可见则先收起控制栏，已收起则退出播放
    if (keyMap.matches(RemoteAction.back, key)) {
      if (_sheetOpen) {
        Navigator.of(context).maybePop();
      } else if (_controlsVisible) {
        setState(() => _controlsVisible = false);
        _hideTimer?.cancel();
      } else {
        _exit();
      }
      return KeyEventResult.handled;
    }
    // MENU（三条横岗等）→ 显示控制栏。功能按钮已全部平铺在界面上，
    // 不再有二级菜单。
    if (keyMap.matches(RemoteAction.menu, key)) {
      _showControls();
      return KeyEventResult.handled;
    }
    // OK/ENTER/SPACE → 播放/暂停（同时确保控件可见）
    if (keyMap.matches(RemoteAction.ok, key)) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    // 方向键：控制栏收起时唤出并聚焦，展开后在按钮之间导航焦点。
    if (keyMap.matches(RemoteAction.left, key)) {
      _handleDirectionalKey(TraversalDirection.left);
      return KeyEventResult.handled;
    }
    if (keyMap.matches(RemoteAction.right, key)) {
      _handleDirectionalKey(TraversalDirection.right);
      return KeyEventResult.handled;
    }
    if (keyMap.matches(RemoteAction.up, key)) {
      _handleDirectionalKey(TraversalDirection.up);
      return KeyEventResult.handled;
    }
    if (keyMap.matches(RemoteAction.down, key)) {
      _handleDirectionalKey(TraversalDirection.down);
      return KeyEventResult.handled;
    }
    // 媒体键
    if (key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(step);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaRewind) {
      _seekBy(-step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  BoxFit _getVideoBoxFit(String mode) => switch (mode) {
    'cover' => BoxFit.cover,
    'fill' => BoxFit.fill,
    _ => BoxFit.contain,
  };

  @override
  Widget build(BuildContext context) {
    final displayed = _seekPreview ?? _session.position;
    final fraction = _session.duration.inMilliseconds <= 0
        ? 0.0
        : (displayed.inMilliseconds / _session.duration.inMilliseconds)
            .clamp(0.0, 1.0);
    return Theme(
      data: ReelTheme.make(
        Brightness.dark,
        _app.preferences.accentColorKey,
      ),
      child: PopScope(
        canPop: !_sheetOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) _cleanup();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Focus(
            onKeyEvent: _onKey,
            autofocus: true,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 视频层：用 videoChanges 监听引擎切换（预加载 promote 时
                // activeEngine 换成 standby 引擎，controller 引用变化），
                // 否则 Video widget 会停留在已 retire 的旧 controller 上黑屏。
                ValueListenableBuilder<int>(
                  valueListenable: _engine.videoChanges,
                  builder: (context, _, _) {
                    final controller = _engine.video;
                    return Video(
                      // key 随 controller 变化：media_kit 的 Video 在 didUpdateWidget
                      // 里不重新绑定 controller（只在 initState 绑定一次），
                      // 引擎 promote 后 controller 引用变了但 State 会复用旧
                      // controller（已 dispose）→ 黑屏。用 ObjectKey 强制重建
                      // State，新 State 绑定新 controller。
                      key: ObjectKey(controller),
                      controller: controller,
                      fit: _getVideoBoxFit(_app.preferences.videoFitMode),
                      controls: NoVideoControls,
                      pauseUponEnteringBackgroundMode: false,
                      resumeUponEnteringForegroundMode: false,
                      wakelock: false,
                    );
                  },
                ),
                // 画面任意区域点击：唤出或收起控制栏
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      if (_controlsVisible) {
                        setState(() => _controlsVisible = false);
                        _hideTimer?.cancel();
                      } else {
                        _showControls();
                      }
                    },
                  ),
                ),
                // 加载/缓冲指示
                if (_session.loadingDetail || _session.buffering)
                  IgnorePointer(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 32,
                            height: 32,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            _session.loadingDetail
                                ? '正在加载短剧…'
                                : _session.resolving
                                ? (_session.loadingMessage ?? '正在加载本集…')
                                : '正在缓冲…',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // 暂停指示
                if (!_session.playing &&
                    !_session.buffering &&
                    !_session.loadingDetail &&
                    _session.error == null &&
                    !_sheetOpen)
                  IgnorePointer(
                    child: Center(
                      child: _glass(
                        radius: 42,
                        child: const Padding(
                          padding: EdgeInsets.all(22),
                          child: Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 40,
                          ),
                        ),
                      ),
                    ),
                  ),
                // 错误提示
                if (_session.error != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: _glass(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.cloud_off_outlined,
                                size: 36,
                                color: Colors.white70,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                _session.error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  height: 1.6,
                                ),
                              ),
                              const SizedBox(height: 22),
                              TVFocusable(
                                radius: 12,
                                onTap: _session.retry,
                                child: FilledButton.icon(
                                  onPressed: null,
                                  icon: const Icon(
                                    Icons.refresh_rounded,
                                    size: 19,
                                  ),
                                  label: const Text('重新播放'),
                                ),
                              ),
                              if (_session.canNext)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: TVFocusable(
                                    radius: 12,
                                    onTap: () => _changeEpisode(true),
                                    child: TextButton(
                                      onPressed: null,
                                      child: const Text('试试下一集'),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                // seek HUD
                if (_seekPreview != null)
                  IgnorePointer(
                    child: Center(
                      child: _glass(
                        radius: 20,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 14,
                          ),
                          child: Text(
                            '${formatTime(_seekPreview!)} / ${formatTime(_session.duration)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // 边界提示（没有上/下集）
                if (_edgeToast != null)
                  IgnorePointer(
                    child: Center(
                      child: _glass(
                        radius: 20,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 28,
                            vertical: 14,
                          ),
                          child: Text(
                            _edgeToast!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // 顶部信息栏 + 底部控件栏
                if (_controlsVisible && !_sheetOpen) ...[
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: 1,
                        duration: const Duration(milliseconds: 240),
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xAA000000), Colors.transparent],
                            ),
                          ),
                          child: SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                24,
                                16,
                                24,
                                36,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _session.drama.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 18,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '第 ${_session.episode?.index ?? 1} 集 · 共 ${_session.episodes.length} 集',
                                          style: const TextStyle(
                                            color: Colors.white60,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    // 控制栏必须处在 TV 的几何遍历策略下：否则
                    // FocusTraversalGroup.of() 拿到的是默认策略，方向键只能在
                    // 同一行里横移，没法从上面那排跨到下面那排。
                    child: FocusTraversalGroup(
                      policy: TVFocusTraversalPolicy(),
                      child: _bottomControls(fraction),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomControls(double fraction) {
    final position = _seekPreview ?? _session.position;
    final remaining = _session.duration - position;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 28, 32, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 播放控制行：左对齐，右端显示当前时间（交叉轴居中）
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _ctrlButton(
                    Icons.skip_previous_rounded,
                    '上一集',
                    _session.canPrevious ? () => _changeEpisode(false) : null,
                  ),
                  const SizedBox(width: 14),
                  _ctrlButton(
                    Icons.replay_rounded,
                    '快退 ${_app.preferences.seekStepSeconds}s',
                    () => _seekBy(
                      Duration(seconds: -_app.preferences.seekStepSeconds),
                    ),
                  ),
                  const SizedBox(width: 14),
                  _ctrlButton(
                    _session.playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    _session.playing ? '暂停' : '播放',
                    _togglePlay,
                    role: _playToggleRole,
                  ),
                  const SizedBox(width: 14),
                  _ctrlButton(
                    Icons.forward_rounded,
                    '快进 ${_app.preferences.seekStepSeconds}s',
                    () => _seekBy(
                      Duration(seconds: _app.preferences.seekStepSeconds),
                    ),
                  ),
                  const SizedBox(width: 14),
                  _ctrlButton(
                    Icons.skip_next_rounded,
                    '下一集',
                    _session.canNext ? () => _changeEpisode(true) : null,
                  ),
                  const Spacer(),
                  _timeLabel(_clockLabel),
                ],
              ),
              const SizedBox(height: 12),
              // 进度条整行通铺，两端不再各放一个时间（时间统一收到右下）
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 5,
                  backgroundColor: Colors.white24,
                  valueColor: AlwaysStoppedAnimation(context.colors.primary),
                ),
              ),
              const SizedBox(height: 12),
              // 功能按钮行：左对齐，右端显示剩余 / 当前 / 总时长。
              // 交叉轴用 center：右侧文字与左侧按钮在高度上居中，
              // 原来用 end 会让文字贴到按钮底边、看起来偏下。
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _ctrlButton(
                    Icons.grid_view_rounded,
                    '选集',
                    () => unawaited(_openEpisodes()),
                  ),
                  const SizedBox(width: 10),
                  _ctrlButton(
                    _app.isFavorite(_session.drama.id)
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    _app.isFavorite(_session.drama.id) ? '已收藏' : '收藏',
                    () => _app.toggleFavorite(_session.drama),
                  ),
                  const SizedBox(width: 10),
                  _ctrlButton(
                    Icons.speed_rounded,
                    '${_app.preferences.speed}x',
                    () => unawaited(_openSpeed()),
                  ),
                  const SizedBox(width: 10),
                  _ctrlButton(
                    Icons.high_quality_outlined,
                    _session.currentQuality,
                    () => unawaited(_openQuality()),
                  ),
                  const SizedBox(width: 10),
                  _ctrlButton(
                    Icons.aspect_ratio_rounded,
                    _fitLabel(_app.preferences.videoFitMode),
                    () => unawaited(_openFitMode()),
                  ),
                  const SizedBox(width: 10),
                  _ctrlButton(
                    Icons.volume_up_rounded,
                    _audioBoostLabel(_app.preferences.audioBoost),
                    () => unawaited(_openAudioBoost()),
                  ),
                  const SizedBox(width: 10),
                  _ctrlButton(Icons.logout_rounded, '退出', _exit),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _timeLabel('剩余 ${formatTime(remaining)}'),
                      const SizedBox(height: 2),
                      _timeLabel(
                        '${formatTime(position)} / ${formatTime(_session.duration)}',
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 控制栏右端的次要信息文字（当前时间 / 剩余时长 / 进度）。
  Widget _timeLabel(String text) => Text(
    text,
    style: const TextStyle(color: Colors.white60, fontSize: 12.5),
  );

  /// 「10月11日 周日 00:53」：播放页右下角的当前时间。
  String get _clockLabel {
    final now = DateTime.now();
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return '${now.month}月${now.day}日 ${weekdays[now.weekday - 1]} $hour:$minute';
  }


  Widget _ctrlButton(
    IconData icon,
    String label,
    VoidCallback? onTap, {
    bool big = false,
    String? role,
  }) {
    // 默认按图标生成唯一焦点角色，用于判断「焦点是否还在控制栏里」。
    // 播放/暂停的图标会切换，所以调用处显式传入固定 role。
    final focusRole = role ?? 'ctrl:${icon.codePoint}';
    // 参考桌面播放器的风格：默认只有图标，聚焦后才在下方浮出文字提示。
    final dimension = big ? 50.0 : 36.0;
    return TVFocusable(
      radius: dimension / 2 + 4,
      focusRole: focusRole,
      onTap: onTap,
      child: Container(
        width: dimension,
        height: dimension,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .08),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: big ? 24 : 18,
          color: onTap == null ? Colors.white24 : Colors.white,
        ),
      ),
    );
  }

  Widget _glass({double radius = 28, required Widget child}) {
    final useGlass = _app.preferences.playerGlassEffect;
    final container = Container(
      decoration: BoxDecoration(
        color: useGlass ? const Color(0xCF12141A) : const Color(0xEE12141A),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white12),
      ),
      child: child,
    );
    if (!useGlass) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: container,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: container,
      ),
    );
  }
}

/// TV 版选集网格：每集用 TVFocusable 包裹。
class _EpisodeGrid extends StatelessWidget {
  const _EpisodeGrid({
    required this.episodes,
    required this.current,
    required this.onSelect,
  });
  final List<Episode> episodes;
  final int? current;
  final void Function(Episode) onSelect;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = (constraints.maxWidth / 90).floor().clamp(4, 10);
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final episode in episodes)
            SizedBox(
              width: (constraints.maxWidth - (columns - 1) * 8) / columns,
              child: TVFocusable(
                radius: 12,
                onTap: () => onSelect(episode),
                autofocus: episode.index == current,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: episode.index == current
                        ? context.colors.primary
                        : Colors.white.withValues(alpha: .06),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Text(
                      '${episode.index}',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: episode.index == current
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: episode.index == current
                            ? Colors.white
                            : Colors.white70,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
