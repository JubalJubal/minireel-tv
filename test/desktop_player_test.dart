import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minireel/app/app.dart';
import 'package:minireel/app/app_controller.dart';
import 'package:minireel/app/theme.dart';
import 'package:minireel/data/repositories/drama_repository.dart';
import 'package:minireel/data/sources/source_adapter.dart';
import 'package:minireel/desktop/desktop_window.dart';
import 'package:minireel/features/player/desktop_player_controls.dart';
import 'package:minireel/features/player/desktop_player_input.dart';
import 'package:minireel/features/player/desktop_player_screen.dart';
import 'package:minireel/features/settings/settings_screen.dart';

import 'support/fakes.dart';

void main() {
  late AppController app;
  late FakeEngine engine;
  late DesktopWindow window;

  Future<void> setup(
    WidgetTester tester, {
    Size size = const Size(1100, 760),
    bool shell = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final store = MemoryStore()..favorites[sampleDrama.id] = sampleDrama;
    app = AppController(
      store,
      DramaRepository(SourceRegistry([FakeSource()]), store),
    );
    engine = FakeEngine();
    window = DesktopWindow();
    await app.initialize();
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      shell
          ? MiniReelApp(controller: app)
          : AppScope(
              controller: app,
              child: MaterialApp(
                theme: ReelTheme.make(Brightness.dark),
                home: DesktopPlayerScreen(
                  drama: sampleDrama,
                  engine: engine,
                  window: window,
                ),
              ),
            ),
    );
    await tester.pumpAndSettle();
  }

  void desktopTest(
    String description,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await app.flush();
        await window.leavePlayer();
        if (!engine.disposed) await engine.dispose();
        app.repository.dispose();
        app.dispose();
        window.dispose();
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  desktopTest('Windows shell uses icon navigation and desktop settings', (
    tester,
  ) async {
    await setup(tester, shell: true);
    final rail = find.byKey(const ValueKey('desktop-navigation'));
    expect(tester.getSize(rail).width, 68);
    expect(find.descendant(of: rail, matching: find.text('短剧库')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pumpAndSettle();
    expect(find.text('收藏 1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pumpAndSettle();
    // 设置页是懒加载列表，桌面控制分组排在首屏之外；先滚动到目标再断言，
    // 避免断言依赖具体屏幕高度或 Flutter 版本之间的排版差异。
    await tester.scrollUntilVisible(
      find.text('最小化时暂停'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('最小化时暂停'), findsOneWidget);
    expect(find.text('手势灵敏度'), findsNothing);
    await tester.tap(find.text('鼠标与快捷键'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  desktopTest(
    'keyboard playback, seeking, volume, full screen and panel precedence',
    (tester) async {
      await setup(tester);
      engine.tick(10);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(engine.state.value.position.inSeconds, 15);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(engine.state.value.position, Duration.zero);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(engine.volumes.last, closeTo(.8, .001));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pumpAndSettle();
      expect(engine.volumes.last, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pumpAndSettle();
      expect(engine.volumes.last, closeTo(.8, .001));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(engine.state.value.playing, false);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(window.fullScreen, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-player-panel')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(engine.state.value.playing, false);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('desktop-player-panel')), findsNothing);
      expect(window.fullScreen, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(window.fullScreen, false);
      expect(engine.opened, ['/1.mp4']);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(engine.opened, ['/1.mp4', '/2.mp4']);
      expect(tester.takeException(), isNull);
    },
  );

  desktopTest(
    'focus loss continues; minimize, lock and suspend respect pause intent',
    (tester) async {
      await setup(tester);
      expect(engine.state.value.playing, true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(engine.state.value.playing, true);
      window.onWindowMinimize();
      await tester.pumpAndSettle();
      expect(engine.state.value.playing, false);
      window.onWindowRestore();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(engine.state.value.playing, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(engine.state.value.playing, false);
      window.onWindowMinimize();
      window.onWindowRestore();
      await tester.pumpAndSettle();
      expect(engine.state.value.playing, false);
      app.setPreferences(app.preferences.copyWith(pauseWhenMinimized: false));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      window.onWindowMinimize();
      await tester.pumpAndSettle();
      expect(engine.state.value.playing, true);
      window.handleSystemEvent('sessionLocked');
      window.handleSystemEvent('suspend');
      await tester.pumpAndSettle();
      expect(engine.state.value.playing, false);
      window.handleSystemEvent('sessionUnlocked');
      window.onWindowRestore();
      await tester.pumpAndSettle();
      expect(engine.state.value.playing, false);
      window.handleSystemEvent('resume');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(engine.state.value.playing, true);
      expect(tester.takeException(), isNull);
    },
  );

  desktopTest(
    'small player hides idle controls and preserves playback when changing window mode',
    (tester) async {
      await setup(tester, size: const Size(360, 540));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      await mouse.moveTo(const Offset(180, 250));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 250));
      final opacity = find.ancestor(
        of: find.byType(DesktopPlayerControls),
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
      await mouse.moveTo(const Offset(180, 260));
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
      engine.tick(26);
      await window.changePlayerMode(PlayerWindowMode.mini, 9 / 16);
      await tester.pumpAndSettle();
      expect(window.pinned, true);
      expect(engine.state.value.position.inSeconds, 26);
      expect(engine.state.value.playing, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(window.mode, PlayerWindowMode.normal);
      expect(engine.opened, ['/1.mp4']);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('playback hotkeys do not intercept text editing', (tester) async {
    final focus = FocusNode();
    final commands = <DesktopPlayerCommand>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopPlayerInput(
            focusNode: focus,
            onCommand: (command, _) => commands.add(command),
            onKeyboardNavigation: () {},
            child: const TextField(),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
    focus.dispose();
  });
}
