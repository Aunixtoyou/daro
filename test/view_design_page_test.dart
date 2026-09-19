import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/widgets/view_design_page.dart';

void main() {
  Widget harness() => ChangeNotifierProvider(
        create: (_) => AppState(),
        child: MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          // 与 main.dart 同构:应用根部有 Material,base-ui 的 Input(TextField)需要
          home: const Material(
            type: MaterialType.transparency,
            child: ViewDesignPage(
              name: 'v_demo',
              connection: '无此连接',
              database: 'db',
              category: ObjectCategory.view,
              schema: 'public',
            ),
          ),
        ),
      );

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).first);
    await tester.pumpAndSettle();
  }

  testWidgets('五个页签与工具栏齐全,规则按钮默认不显示', (tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    for (final tab in ['定义', '规则', '高级', '注释', 'SQL 预览']) {
      expect(find.text(tab), findsWidgets, reason: '缺少页签: $tab');
    }
    for (final btn in ['保存', '预览', '解释', '视图创建工具', '美化 SQL']) {
      expect(find.text(btn), findsOneWidget, reason: '缺少工具栏按钮: $btn');
    }
    expect(find.text('添加规则'), findsNothing);
    expect(find.text('删除规则'), findsNothing);
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
  });

  testWidgets('规则页:网格表头 + 位置/定义字段,工具栏追加规则按钮', (tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await openTab(tester, '规则');

    for (final col in ['名称', 'OID', '事件', '代替运行', '注释']) {
      expect(find.text(col), findsWidgets, reason: '缺少列头: $col');
    }
    expect(find.text('位置:'), findsOneWidget);
    expect(find.text('定义:'), findsOneWidget);
    expect(find.text('添加规则'), findsOneWidget);
    expect(find.text('删除规则'), findsOneWidget);
  });

  testWidgets('高级页:所有者 / 检查选项 / 安全屏障', (tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await openTab(tester, '高级');
    expect(find.text('所有者:'), findsOneWidget);
    expect(find.text('检查选项:'), findsOneWidget);
    expect(find.text('安全屏障'), findsOneWidget);
  });

  testWidgets('SQL 预览页:更改 / DDL 子页签可切换', (tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await openTab(tester, 'SQL 预览');
    expect(find.text('更改'), findsOneWidget);
    expect(find.text('DDL'), findsOneWidget);
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);

    await tester.tap(find.text('DDL'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('定义为空时预览只回消息,不抛异常', (tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();

    expect(find.text('消息'), findsOneWidget);
    // 「解释」既是工具栏按钮也是底部面板页签
    expect(find.text('解释'), findsNWidgets(2));
    expect(find.textContaining('视图定义为空'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全屏按钮收起 / 恢复左右侧栏', (tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = AppState();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: const SizedBox.expand(
          child: ViewDesignPage(
            name: 'v_demo',
            connection: '无此连接',
            database: 'db',
            category: ObjectCategory.view,
            schema: 'public',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(app.leftPanelVisible, isTrue);

    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pumpAndSettle();
    expect(app.leftPanelVisible, isFalse);
    expect(app.rightPanelVisible, isFalse);
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);

    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pumpAndSettle();
    expect(app.leftPanelVisible, isTrue);
    expect(app.rightPanelVisible, isTrue);
  });
}
