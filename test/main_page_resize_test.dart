import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/main.dart';
import 'package:daro/widgets/database_info.dart';
import 'package:daro/widgets/database_tree.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';

/// 主布局接线验证:拖动分隔条真的改变左右侧栏宽度(用真实 DbApp 装配)。
void main() {
  Future<AppState> pumpApp(WidgetTester tester) async {
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
}
