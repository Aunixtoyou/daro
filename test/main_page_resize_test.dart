import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/main.dart';
import 'package:daro/widgets/database_info.dart';
import 'package:daro/widgets/database_tree.dart';
import 'package:daro/widgets/view_tabs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'pin_system_locale.dart';

/// 主布局接线验证:拖动分隔条真的改变左右侧栏宽度(用真实 DbApp 装配)。
void main() {
  Future<AppState> pumpApp(WidgetTester tester) async {
    pinSystemChineseLocale(tester);
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const DbApp(),
      ),
    );
    await tester.pump();
    return app;
  }

  testWidgets('左栏分隔条:向右拖动加宽左栏', (tester) async {
    final app = await pumpApp(tester);
    final before = app.leftPanelWidth.value;

    await tester.drag(find.byType(Splitter).first, const Offset(80, 0));
    await tester.pump();

    expect(app.leftPanelWidth.value, closeTo(before + 80, 1));
    expect(
      tester.getSize(find.byType(DatabaseTree)).width,
      closeTo(before + 80, 1),
      reason: '左栏内容应渲染为新宽度',
    );
  });

  testWidgets('右栏分隔条:向左拖动加宽右栏', (tester) async {
    final app = await pumpApp(tester);
    final before = app.rightPanelWidth.value;

    await tester.drag(find.byType(Splitter).last, const Offset(-120, 0));
    await tester.pump();

    expect(app.rightPanelWidth.value, closeTo(before + 120, 1));
    expect(
      tester.getSize(find.byType(DatabaseInfo)).width,
      closeTo(before + 120, 1),
    );
  });

  testWidgets('收起左栏后其分隔条一并隐藏,拖动上下限仍生效', (tester) async {
    final app = await pumpApp(tester);
    app.toggleLeftPanel();
    await tester.pumpAndSettle();

    // 仅剩右栏分隔条
    expect(find.byType(Splitter), findsOneWidget);
    app.resizeLeftPanel(-10000);
    expect(app.leftPanelWidth.value, 180);
    app.resizeLeftPanel(100000);
    expect(app.leftPanelWidth.value, 600);
  });

  testWidgets('三栏贴合:分隔条不占布局宽度,侧栏与中间面板之间无间隙',
      (tester) async {
    final app = await pumpApp(tester);
    await tester.pumpAndSettle();

    final tree = tester.getRect(find.byType(DatabaseTree));
    final center = tester.getRect(find.byType(ViewTabs));
    final info = tester.getRect(find.byType(DatabaseInfo));

    // 中间面板两侧既无间隙也无分隔线:左右缘与两侧侧栏严丝合缝
    expect(center.left, closeTo(tree.right, 0.01),
        reason: '左栏与中间面板之间不应有间隙');
    expect(info.left, closeTo(center.right, 0.01),
        reason: '中间面板与右栏之间不应有间隙');
    // 宽度全部由侧栏自身决定,未被分隔条吃掉
    expect(tree.width, closeTo(app.leftPanelWidth.value, 0.01));
    expect(info.width, closeTo(app.rightPanelWidth.value, 0.01));
    // 拼缝不着色:静止态与 hover / 拖动都不画线(两个浮层分隔条的发丝线全透明)
    final hairlines = find.descendant(
        of: find.byType(Splitter), matching: find.byType(ColoredBox));
    expect(hairlines, findsNWidgets(2));
    for (final box in tester.widgetList<ColoredBox>(hairlines)) {
      expect(box.color, Colors.transparent,
          reason: '侧栏与中间面板的拼缝不应画线(含悬浮高亮)');
    }
  });
}
