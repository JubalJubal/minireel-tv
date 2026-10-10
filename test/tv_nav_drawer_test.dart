import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minireel/app/app.dart';
import 'package:minireel/app/app_controller.dart';
import 'package:minireel/app/platform.dart';
import 'package:minireel/data/repositories/drama_repository.dart';
import 'package:minireel/data/sources/source_adapter.dart';

import 'support/fakes.dart';

/// TV 侧边导航抽屉的交互回归测试。
///
/// 关键回归点：抽屉在「综合」频道靠悬浮搜索按钮作为内容区入口，能正常
/// 用右键收回；但切到真人剧等其他菜单后没有搜索按钮可当入口，如果入口
/// 节点失效（或几何查找被限制在导航栏自己的 FocusTraversalGroup 内），
/// 右键就会「失效」、收不回菜单。
void main() {
  const navDrawer = ValueKey('tv-nav-drawer');

  testWidgets('TV 侧边导航：左键唤出，切到其他菜单后右键仍能收回', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 强制走 TV UI 分支（仅 debug 生效）
    toggleDebugTvMode();
    addTearDown(toggleDebugTvMode);

    final store = MemoryStore()..favorites[sampleDrama.id] = sampleDrama;
    final app = AppController(
      store,
      DramaRepository(SourceRegistry([FakeSource()]), store),
    );
    await app.initialize();
    await tester.pumpWidget(MiniReelApp(controller: app));
    await tester.pumpAndSettle();

    double drawerWidth() => tester.getSize(find.byKey(navDrawer)).width;

    // 默认完全收起（不占画幅）
    expect(drawerWidth(), 0);

    // 焦点在内容区最左（综合频道的悬浮搜索按钮）时按左键 → 唤出导航
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(drawerWidth(), 200, reason: '左键应能唤出导航抽屉');

    // 下键切到「真人剧」：非综合频道，没有搜索按钮可当内容区入口
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(drawerWidth(), 200, reason: '预览其他菜单时抽屉保持展开');

    // 右键必须能收回 —— 这里就是「其他菜单下失效」的回归点
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(drawerWidth(), 0, reason: '右键应能在任意菜单下收回导航抽屉');
  });
}
