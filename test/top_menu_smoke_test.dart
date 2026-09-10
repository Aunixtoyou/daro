import 'package:daro/app/app_state.dart';
import 'package:daro/widgets/navicat_import_dialog.dart';
import 'package:daro/widgets/top_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Provider 必须在 MaterialApp 之上(与 main.dart 一致):showDialog 的弹层路由
/// 挂在 Navigator 上,拿不到 home 里的 Provider,取色时会直接抛异常。
Widget harness(AppState app) => ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: const TopMenu(),
      ),
    );

void main() {
  testWidgets('TopMenu lays out without throwing', (tester) async {
    await tester.pumpWidget(harness(AppState()));
    await tester.pumpAndSettle();
    expect(find.byType(TopMenu), findsOneWidget);
  });

  testWidgets('文件菜单里的「导入连接」可打开导入向导',
      (tester) async {
    await tester.pumpWidget(harness(AppState()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('导入连接'), findsOneWidget);

    await tester.tap(find.text('导入连接'));
    await tester.pumpAndSettle();
    expect(find.byType(NavicatImportDialog), findsOneWidget);
    expect(find.text('请先选择 Navicat 导出的 .ncx 文件。'), findsOneWidget);
  });
}
