import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/widgets/navicat_export_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// 导出向导渲染与勾选冒烟:默认全选可导出、不支持的类型置灰并标注原因、
// 全选/取消全选按钮语义确定、路径默认值与「导出密码」开关。
// .ncx 内容生成与文件形制由 test/navicat_export_test.dart 覆盖;
// 落盘写文件是真实异步 I/O,fakeAsync 下无法推进,本测试不按「确定」。

/// Provider 必须在 MaterialApp 之上(与 main.dart 一致),否则弹层路由取不到
/// AppState(Tokens.of 依赖它)。
Widget harness(AppState app) => ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Builder(
          builder: (context) => Material(
            child: Button(
              text: '打开导出向导',
              onPressed: () => showNavicatExportDialog(context, app: app),
            ),
          ),
        ),
      ),
    );

const _conns = [
  ConnectionInfo(
      name: '账套库',
      typeId: 'mysql',
      host: '10.0.0.11',
      port: '3306',
      username: 'root',
      password: 'p@ssw0rd-mysql',
      isLive: true),
  ConnectionInfo(
      name: '订单库',
      typeId: 'sqlite',
      port: '',
      username: '',
      host: r'C:\data\orderdb.db',
      database: r'C:\data\orderdb.db',
      isLive: true),
  ConnectionInfo(
      name: '老Oracle',
      typeId: 'oracle',
      host: 'ora.example.com',
      port: '1521',
      username: 'scott',
      isLive: true),
];

void main() {
  late AppState app;
  late Directory supportDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // 连接配置落在「应用支持目录」：测试里把它指到临时目录，让落盘真实发生
    supportDir = await Directory.systemTemp.createTemp('daro_ncx_export_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => supportDir.path,
    );
    app = AppState();
    app.addConnections(_conns);
  });

  testWidgets('默认全选可导出,不支持的类型置灰并标注原因', (tester) async {
    await tester.pumpWidget(harness(app));
    await tester.tap(find.text('打开导出向导'));
    await tester.pumpAndSettle();

    expect(find.text('导出连接'), findsOneWidget);
    expect(find.textContaining('已勾选 2 条'), findsOneWidget);
    expect(find.text('可导出'), findsNWidgets(2));
    expect(find.text('Navicat 无此类型'), findsOneWidget);
    // 默认导出路径指向桌面 connections.ncx
    expect(_pathText(tester), endsWith('connections.ncx'));
    // 导出密码默认勾选
    expect(_masterChecked(tester), isTrue);
  });

  testWidgets('行点击切换勾选,全选/取消全选各自语义确定', (tester) async {
    await tester.pumpWidget(harness(app));
    await tester.tap(find.text('打开导出向导'));
    await tester.pumpAndSettle();

    // 点击「订单库」行 → 取消勾选
    await tester.tap(find.text('订单库'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已勾选 1 条'), findsOneWidget);

    await tester.tap(find.text('取消全选'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已勾选 0 条'), findsOneWidget);
    expect(_buttonEnabled(tester, '确定'), isFalse,
        reason: '0 条选中时不允许导出');

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已勾选 2 条'), findsOneWidget);
  });

  testWidgets('「导出密码」开关可切换,行勾选不受影响', (tester) async {
    await tester.pumpWidget(harness(app));
    await tester.tap(find.text('打开导出向导'));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('导出密码(密码按 Navicat'));
    await tester.pumpAndSettle();
    expect(_masterChecked(tester), isFalse);
    // 关掉开关只是不带口令,已勾选的连接仍然导出
    expect(find.textContaining('已勾选 2 条'), findsOneWidget);
  });
}

/// 找到指定文案所在 [Button] 的可用态
bool _buttonEnabled(WidgetTester tester, String text) {
  final el = tester.element(find.text(text));
  final button = el.findAncestorWidgetOfExactType<Button>();
  expect(button, isNotNull, reason: '$text 未包在 base-ui Button 中');
  return button!.onPressed != null;
}

/// 顶部路径输入框当前文本
String _pathText(WidgetTester tester) {
  final input = tester.widget<Input>(find.byType(Input));
  return input.controller?.text ?? '';
}

/// 底部「导出密码」主开关的勾选状态(带 label 的那个 CheckBox)
bool _masterChecked(WidgetTester tester) {
  final box = tester
      .widgetList<CheckBox>(find.byType(CheckBox))
      .firstWhere((b) => b.label != null);
  return box.value;
}
