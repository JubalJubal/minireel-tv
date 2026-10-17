import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum DesktopPlayerCommand {
  playPause,
  seekBack,
  seekForward,
  volumeUp,
  volumeDown,
  fullScreen,
  back,
  mute,
  previous,
  next,
  episodes,
  danmaku,
}

class DesktopPlayerInput extends StatelessWidget {
  const DesktopPlayerInput({
    super.key,
    required this.child,
    required this.focusNode,
    required this.onCommand,
    required this.onKeyboardNavigation,
    this.allowPlayback = true,
  });
  final Widget child;
  final FocusNode focusNode;
  final void Function(DesktopPlayerCommand, bool accelerated) onCommand;
  final VoidCallback onKeyboardNavigation;
  final bool allowPlayback;

  static final bindings = {
    LogicalKeyboardKey.space: DesktopPlayerCommand.playPause,
    LogicalKeyboardKey.mediaPlayPause: DesktopPlayerCommand.playPause,
    LogicalKeyboardKey.arrowLeft: DesktopPlayerCommand.seekBack,
    LogicalKeyboardKey.arrowRight: DesktopPlayerCommand.seekForward,
    LogicalKeyboardKey.arrowUp: DesktopPlayerCommand.volumeUp,
    LogicalKeyboardKey.arrowDown: DesktopPlayerCommand.volumeDown,
    LogicalKeyboardKey.keyF: DesktopPlayerCommand.fullScreen,
    LogicalKeyboardKey.enter: DesktopPlayerCommand.fullScreen,
    LogicalKeyboardKey.escape: DesktopPlayerCommand.back,
    LogicalKeyboardKey.keyM: DesktopPlayerCommand.mute,
    LogicalKeyboardKey.pageUp: DesktopPlayerCommand.previous,
    LogicalKeyboardKey.pageDown: DesktopPlayerCommand.next,
    LogicalKeyboardKey.keyE: DesktopPlayerCommand.episodes,
    LogicalKeyboardKey.keyD: DesktopPlayerCommand.danmaku,
  };

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    focusNode: focusNode,
    onKeyEvent: (_, event) {
      if (ModalRoute.of(context)?.isCurrent == false) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.tab && event is KeyDownEvent) {
        onKeyboardNavigation();
      }
      final focusContext = FocusManager.instance.primaryFocus?.context;
      if (focusContext?.widget is EditableText ||
          focusContext?.findAncestorWidgetOfExactType<EditableText>() != null) {
        return KeyEventResult.ignored;
      }
      final keyboard = HardwareKeyboard.instance;
      if (keyboard.isControlPressed ||
          keyboard.isAltPressed ||
          keyboard.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      final command = bindings[event.logicalKey];
      if (command == null ||
          (!allowPlayback && command != DesktopPlayerCommand.back)) {
        return KeyEventResult.ignored;
      }
      const repeatable = {
        DesktopPlayerCommand.seekBack,
        DesktopPlayerCommand.seekForward,
        DesktopPlayerCommand.volumeUp,
        DesktopPlayerCommand.volumeDown,
      };
      if (event is KeyDownEvent ||
          event is KeyRepeatEvent && repeatable.contains(command)) {
        onCommand(command, keyboard.isShiftPressed);
      }
      // Also consume key-up, preventing a focused button from activating again.
      return KeyEventResult.handled;
    },
    child: child,
  );
}

class DesktopShortcutGuide extends StatelessWidget {
  const DesktopShortcutGuide({super.key});
  static const shortcuts = [
    ('空格', '播放 / 暂停'),
    ('← / →', '后退 / 前进 5 秒'),
    ('Shift + ← / →', '后退 / 前进 15 秒'),
    ('↑ / ↓', '音量增加 / 降低 5%'),
    ('M', '静音 / 恢复音量'),
    ('F / Enter', '进入 / 退出全屏'),
    ('PageUp / PageDown', '上一集 / 下一集'),
    ('E', '打开选集'),
    ('D', '打开 / 关闭弹幕'),
    ('Esc', '关闭面板、退出全屏、小窗或播放'),
    ('单击 / 双击画面', '播放暂停 / 切换全屏'),
    ('右键画面', '打开播放菜单'),
  ];

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final (keys, action) in shortcuts)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 140,
                child: Text(
                  keys,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  action,
                  style: const TextStyle(fontSize: 12.5, height: 1.5),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}
