import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../app/theme.dart';
import '../../core/services/app_update_service.dart';
import '../../domain/models/drama.dart';
import '../shared/widgets.dart';
import 'tv_focus.dart';
import 'tv_library_screen.dart';
import 'tv_mine_screen.dart';
import 'tv_rankings_screen.dart';
import 'tv_player_screen.dart';
import 'tv_settings_screen.dart';
import 'tv_update_dialog.dart';

/// TV 版主界面。
///
/// 布局：左侧导航栏（图标 + 文字，~200 宽）+ 右侧内容区。
/// 设计继承：导航栏用 surface 背景 + divider 分隔（同 DesktopNavigation），
/// 选中项 accent 半透明背景 + 左侧 3px accent 竖条（同 library _category 动画竖条）。
/// 交互：D-pad 上下切换导航项，左右进入/离开内容区。
class TVAppShell extends StatefulWidget {
  const TVAppShell({super.key});
  @override
  State<TVAppShell> createState() => _TVAppShellState();
}

class _TVAppShellState extends State<TVAppShell> {
  /// 导航抽屉宽度，与 [_TVNavigation] 的固定宽度保持一致。
  static const double _navWidth = 200;
  /// 当前聚焦的导航项下标。焦点即选中：焦点一落到菜单项就切换内容。
  int _navIndex = 0;
  bool _openingPlayer = false;
  /// 导航抽屉是否滑出。默认 false：完全移出屏幕左侧，不留图标、不占画幅。
  bool _navVisible = false;

  /// 当前导航项对应的页面下标（IndexedStack 的 index）。
  int get _tab => _TVNavItem.all[_navIndex].page;
  /// 当前导航项对应的短剧库频道；null 表示「综合」。
  DramaChannel? get _channel => _TVNavItem.all[_navIndex].channel;
  /// 顶部搜索框的焦点节点：由 shell 统一持有，用于
  /// 1) 初始焦点落在搜索框（而非导航栏）
  /// 2) 从导航栏按→进入内容区时统一落到搜索框
  final _searchFocus = FocusNode(debugLabel: 'tv-shell-search');
  /// 内容区的焦点节点：切 tab 后用于把焦点从导航栏移到内容区。
  /// canRequestFocus=false，只作为遍历入口（requestFocus 后遍历其子节点）。
  final _contentScope = FocusNode(debugLabel: 'tv-shell-content-scope');

  Future<void> _play(Drama drama, [int? episode]) async {
    if (_openingPlayer) return;
    _openingPlayer = true;
    try {
      await Navigator.of(context).push(
        PageRouteBuilder<void>(
          pageBuilder: (_, _, _) =>
              TVPlayerScreen(drama: drama, initialEpisode: episode),
          transitionDuration: const Duration(milliseconds: 240),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          transitionsBuilder: (_, animation, _, child) => FadeTransition(
            opacity: animation,
            child: child,
          ),
        ),
      );
    } finally {
      _openingPlayer = false;
    }
  }

  static bool _hasCheckedAutoUpdate = false;

  @override
  void initState() {
    super.initState();
    // 注册搜索框节点供导航栏→内容区跳转使用
    searchFocusNode = _searchFocus;
    // 初始内容区入口：短剧库的搜索框
    contentEntryFocusNode = _searchFocus;
    // 内容区到最左仍无法左移时，由 D-pad 拦截器回调唤出导航抽屉
    onNavRevealRequested = _showNav;
    // 焦点离开导航项（例如在抽屉里按右键回到内容区）时自动收回抽屉
    FocusManager.instance.addListener(_onPrimaryFocusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 默认焦点：进入后红点在顶部搜索框
      _searchFocus.requestFocus();
      unawaited(AppScope.read(context).repository.refresh());
      if (!_hasCheckedAutoUpdate) {
        _hasCheckedAutoUpdate = true;
        _checkAutoUpdate();
      }
    });
  }

  Future<void> _checkAutoUpdate() async {
    final app = AppScope.read(context);
    if (!app.preferences.autoCheckUpdate) return;

    // 启动延迟 2.5 秒，先确保首屏界面和短剧库就绪
    await Future.delayed(const Duration(milliseconds: 2500));
    if (!mounted || _openingPlayer) return;
    try {
      final info = await AppUpdateService.checkForUpdate();
      if (!mounted || _openingPlayer || info == null || !info.hasUpdate) return;
      await showTVUpdateDialog(context, info);
    } catch (_) {
      // 启动静默失败，不打扰用户
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onPrimaryFocusChanged);
    onNavRevealRequested = null;
    searchFocusNode = null;
    contentEntryFocusNode = null;
    _searchFocus.dispose();
    _contentScope.dispose();
    super.dispose();
  }

  /// 唤出导航抽屉，并把焦点落到当前选中的导航项（遥控器可直接上下切换）。
  void _showNav() {
    if (_navVisible || !mounted) return;
    setState(() => _navVisible = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_navVisible) return;
      TVFocusRegistry.get('navItem$_navIndex')?.requestFocus();
    });
  }

  /// 收回导航抽屉，焦点回到当前页面的内容区入口。
  void _hideNav() {
    if (!_navVisible || !mounted) return;
    setState(() => _navVisible = false);
    _applyContentEntry(_tab);
  }

  /// 焦点一离开导航项就收回抽屉，覆盖「在抽屉里按右键」与「进入内容区」。
  void _onPrimaryFocusChanged() {
    if (!_navVisible) return;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return;
    if (TVFocusRegistry.roleOf(focus)?.startsWith('navItem') ?? false) return;
    _hideNav();
  }

  /// 鼠标交互：右键唤出导航，左键点击导航之外的区域收回。
  void _handlePointerDown(PointerDownEvent event) {
    if (event.buttons == kSecondaryMouseButton) {
      _showNav();
      return;
    }
    if (event.buttons == kPrimaryMouseButton &&
        _navVisible &&
        event.position.dx > _navWidth) {
      _hideNav();
    }
  }

  /// 焦点落到导航项：立即切换内容，但焦点留在导航栏。
  ///
  /// 电视交互是「焦点即预览」：在菜单里上下移动就能看到对应页面，
  /// 不需要再按 OK；用户可以继续上下浏览，直到按 OK 或右键进入内容区。
  void _previewNav(int index) {
    if (!mounted || index == _navIndex) return;
    setState(() => _navIndex = index);
  }

  /// 进入导航项对应页面：焦点移到内容区，抽屉随之收回。
  ///
  /// 用于按 OK、点击菜单项，以及「我的」页里的「去逛剧库」。
  void _activateNav(int index) {
    if (!mounted) return;
    if (index != _navIndex) setState(() => _navIndex = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyContentEntry(_tab);
    });
  }

  /// 根据当前 tab 设置内容区入口节点并把焦点收到内容区。
  ///
  /// - 短剧库：入口 = 搜索框（[_searchFocus]）
  /// - 热播榜：入口 = 左侧首个榜单类型节点（角色 `rankingsTypeFirst`）
  /// - 我的：入口 = segment「收藏」节点（角色 `mineEntry`）
  /// - 设置：入口 = 首个设置项节点（角色 `settingsEntry`）
  ///
  /// 用 [TVFocusRegistry] 角色查找而非 [findFirstFocus]，后者会遍历
  /// IndexedStack 所有子页（含隐藏 tab），返回 widget 树首个节点
  /// （短剧库搜索框），在「我的/设置」tab 会落到不可见节点。
  void _applyContentEntry(int tab) {
    if (tab == 0) {
      contentEntryFocusNode = _searchFocus;
      _searchFocus.requestFocus();
      return;
    }
    final role = switch (tab) {
      1 => 'rankingsTypeFirst',
      2 => 'mineEntry',
      3 => 'settingsEntry',
      _ => null,
    };
    if (role != null) {
      final entry = TVFocusRegistry.get(role);
      if (entry != null && entry.rect.width > 0) {
        contentEntryFocusNode = entry;
        entry.requestFocus();
        return;
      }
    }
    // 兜底：直接请求内容区 scope
    contentEntryFocusNode = _contentScope;
    _contentScope.requestFocus();
  }

  DateTime? _lastBackPressTime;

  void _handleBack() {
    if (_tab != 0) {
      _activateNav(0);
      return;
    }
    final now = DateTime.now();
    if (_lastBackPressTime == null ||
        now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
      _lastBackPressTime = now;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('再按一次返回键退出程序'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          width: 260,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: TVDpadInterceptor(
        child: Scaffold(
          body: Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Listener(
              // 鼠标：右键唤出导航，左键点击导航外区域收回
              onPointerDown: _handlePointerDown,
              child: Stack(
                children: [
                  // 内容区占满整个画幅：导航栏改成覆盖式抽屉，不再挤占宽度
                  Positioned.fill(
                    child: Focus(
                      focusNode: _contentScope,
                      canRequestFocus: false,
                      descendantsAreFocusable: true,
                      child: FocusTraversalGroup(
                        policy: TVFocusTraversalPolicy(),
                        child: IndexedStack(
                          index: _tab,
                          children: [
                            TVLibraryScreen(
                              onPlay: _play,
                              searchFocus: _searchFocus,
                              channel: _channel,
                            ),
                            TVRankingsScreen(onPlay: _play),
                            TVMineScreen(
                              onPlay: _play,
                              onExplore: () => _activateNav(0),
                            ),
                            TVSettingsScreen(),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 导航抽屉：默认完全移出屏幕左侧（不留图标、不占画幅），
                  // 唤出时从左侧滑入并覆盖在内容之上。
                  // ExcludeFocus 保证抽屉收起时其内部的焦点节点不会被 D-pad 选中。
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    left: _navVisible ? 0 : -_navWidth,
                    top: 0,
                    bottom: 0,
                    width: _navWidth,
                    child: ExcludeFocus(
                      excluding: !_navVisible,
                      child: FocusTraversalGroup(
                        key: navRegionKey,
                        policy: TVFocusTraversalPolicy(),
                        child: _TVNavigation(
                          selected: _navIndex,
                          onFocusItem: _previewNav,
                          onActivateItem: _activateNav,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 侧边导航项：短剧库的频道分类（综合/真人剧/漫剧/AI剧/动漫），
/// 以及热播榜/我的/设置三个功能页。
///
/// 频道项与「综合」共用短剧库页面（page 0），只是切换筛选条件；
/// 这样分类就不再占用内容区顶部的一整行。
class _TVNavItem {
  const _TVNavItem(
    this.label,
    this.icon,
    this.activeIcon, {
    required this.page,
    this.channel,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
  /// IndexedStack 的页面下标：0 短剧库、1 热播榜、2 我的、3 设置。
  final int page;
  /// 短剧库内的频道筛选；null 表示「综合」（不筛选）。
  final DramaChannel? channel;

  /// 前 [channelCount] 项是短剧库的频道，其后是独立页面。
  static const List<_TVNavItem> all = [
    _TVNavItem('综合', Icons.grid_view_outlined, Icons.grid_view_rounded,
        page: 0),
    _TVNavItem('真人剧', Icons.videocam_outlined, Icons.videocam_rounded,
        page: 0, channel: DramaChannel.real),
    _TVNavItem('漫剧', Icons.auto_stories_outlined, Icons.auto_stories_rounded,
        page: 0, channel: DramaChannel.comicDrama),
    _TVNavItem('AI剧', Icons.smart_toy_outlined, Icons.smart_toy_rounded,
        page: 0, channel: DramaChannel.ai),
    _TVNavItem('动漫', Icons.animation_outlined, Icons.animation_rounded,
        page: 0, channel: DramaChannel.animation),
    _TVNavItem('热播榜', Icons.emoji_events_outlined,
        Icons.emoji_events_rounded, page: 1),
    _TVNavItem('我的', Icons.person_outline_rounded, Icons.person_rounded,
        page: 2),
    _TVNavItem('设置', Icons.tune_rounded, Icons.tune_rounded, page: 3),
  ];

  /// 短剧库频道分组在 [all] 中的数量。
  static const int channelCount = 5;
}

/// TV 侧边导航栏。图标 + 文字标签（TV 10 尺距离需文字辅助）。
///
/// 交互：焦点落到某一项就立即切换内容（焦点即预览），按 OK 才把焦点
/// 交回内容区；这样在菜单里上下浏览时能直接看到每个页面的效果。
class _TVNavigation extends StatelessWidget {
  const _TVNavigation({
    required this.selected,
    required this.onFocusItem,
    required this.onActivateItem,
  });
  final int selected;
  final ValueChanged<int> onFocusItem;
  final ValueChanged<int> onActivateItem;

  @override
  Widget build(BuildContext context) {
    final items = _TVNavItem.all;
    return Container(
      width: 200,
      decoration: BoxDecoration(
        color: context.colors.surface,
        // 抽屉覆盖在内容之上，用右侧阴影拉开层次
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .38),
            blurRadius: 28,
            offset: const Offset(8, 0),
          ),
        ],
      ),
      // 8 个导航项在浅屏（横屏约 384dp 高）会超出可视高度：用可滚动的
      // Column 承载，既不溢出，也不会像 ListView 那样把视口外的项懒加载掉
      // 导致 D-pad 聚焦不到「我的 / 设置」。
      child: Column(
        children: [
          const SizedBox(height: 14),
          const BrandMark(size: 32),
          const SizedBox(height: 4),
          Text(
            'MiniReel',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: context.muted,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                children: [
                  // 短剧库频道分组
                  for (int i = 0; i < _TVNavItem.channelCount; i++)
                    _destination(context, items[i], i),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                    child: Divider(
                      height: 1,
                      thickness: 1,
                      color: Theme.of(context).dividerColor,
                    ),
                  ),
                  // 热播榜 / 我的 / 设置
                  for (int i = _TVNavItem.channelCount; i < items.length; i++)
                    _destination(context, items[i], i),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _destination(BuildContext context, _TVNavItem item, int index) {
    final isSel = selected == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: TVFocusable(
        radius: 13,
        // 角色供抽屉唤出时定位当前选中项（TVFocusRegistry.get）
        focusRole: 'navItem$index',
        // 焦点即预览：焦点一落到本项就切换内容，无需按 OK
        onFocus: () => onFocusItem(index),
        // OK / 点击才真正进入页面（焦点交回内容区，抽屉收回）
        onTap: () => onActivateItem(index),
        semanticLabel: item.label,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 12),
          decoration: BoxDecoration(
            color: isSel
                ? context.colors.primary.withValues(alpha: .1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Row(
            children: [
              // 左侧 accent 竖条（选中态），复用 library _category 动画语言
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                width: 3,
                height: 18,
                decoration: BoxDecoration(
                  color: isSel ? context.colors.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                isSel ? item.activeIcon : item.icon,
                size: 19,
                color: isSel ? context.colors.primary : context.muted,
              ),
              const SizedBox(width: 10),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
                  color: isSel ? context.colors.onSurface : context.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
