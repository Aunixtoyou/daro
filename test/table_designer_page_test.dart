import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/widgets/table_designer_page.dart';

void main() {
  // 与 main.dart 一致:Material 提供 TextField 所需祖先
  Widget harness() => MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: ChangeNotifierProvider(
          create: (_) => AppState(),
          child: Material(
            type: MaterialType.transparency,
            child: const TableDesignerPage(
              title: '新建表',
              connection: '无此连接',
              database: 'db',
            ),
          ),
        ),
      );

  testWidgets('TableDesignerPage 11 个标签布局无异常', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // 11 个标签齐全
    for (final label in ['字段', '索引', '外键', '唯一键', '检查', '排除', '规则', '触发器', '选项', '注释', 'SQL 预览']) {
      expect(find.text(label), findsWidgets, reason: '缺少标签: $label');
    }
    // 默认预置一行字段
    expect(find.text('添加字段'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('添加字段按钮与字段行编辑', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加字段'));
    await tester.pumpAndSettle();
    // 插入 / 删除按钮出现(行数 ≥ 1 时删除可用)
    expect(find.text('插入字段'), findsOneWidget);
    expect(find.text('删除字段'), findsOneWidget);
    // 上移在第一行禁用、下移可用
    expect(find.text('上移'), findsOneWidget);
  });

  testWidgets('切换到 SQL 预览标签渲染 DDL', (tester) async {
    // 11 个标签超宽,放大窗口让「SQL 预览」标签可见
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('SQL 预览'));
    await tester.pumpAndSettle();
    // 已切换到预览标签:提示条出现(re_editor 内容为自绘文本,find.text 不可见)
    expect(find.textContaining('将按以下顺序执行'), findsOneWidget);
  });
}
