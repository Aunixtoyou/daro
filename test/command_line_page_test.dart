import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/l10n/locale_config.dart';
import 'package:daro/widgets/command_line_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'mcp_fakes.dart';

// 命令列界面页:提示符、回车执行、↑ 召回历史、未收尾时的续行提示。
// 执行走 AppState.cliConsoleFor → ConnectionManager,因此挂一个假驱动即可,
// 不碰真实数据库。

const _conn = ConnectionInfo(
  name: 'c',
  typeId: 'postgresql',
  host: 'h',
  port: '5432',
  username: 'u',
  isLive: true,
);

Future<({AppState app, FakeDriver driver})> _pumpPage(
    WidgetTester tester) async {
  final app = AppState();
  final driver = FakeDriver('c1');
  // 必须先 connect:_driverFor 见 isConnected 为 false 会丢掉注入的驱动去连真库
  await driver.connect();
  app.addConnections([_conn]);
  app.connectionManager.attachDriverForTest('c', driver);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: kAppLocalizationsDelegates,
        supportedLocales: kSupportedLocales,
        // 与 main.dart 同构:Input 内的 TextField 需要 Material 祖先
        home: const Material(
          child: CommandLinePage(connection: 'c', database: 'daowei_dev'),
        ),
      ),
    ),
  );
  await _settle(tester);
  return (app: app, driver: driver);
}

/// 跑固定几帧代替 pumpAndSettle:输入框光标闪烁是持续动画,后者会等到超时
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 在输入行敲一段文本并按回车提交
///
/// 必须先 tap:不建立真实输入连接时 `receiveAction` 投递不到 EditableText,
/// onSubmitted 静默不触发(同 `navicat_import_dialog_test.dart` 的写法)。
Future<void> _submit(WidgetTester tester, String text) async {
  await tester.tap(find.byType(Input));
  await tester.enterText(find.byType(Input), text);
  await tester.pump();
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await _settle(tester);
}

void main() {
  late Directory supportDir;

  setUp(() async {
    // AppState 会异步落盘:指向临时目录,避免污染用户目录也避免悬空 future
    supportDir = await Directory.systemTemp.createTemp('daro_cli_page_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => supportDir.path,
    );
  });

  testWidgets('打开即给出提示符与用法说明', (tester) async {
    await _pumpPage(tester);

    expect(find.text('daowei_dev=# '), findsOneWidget);
    expect(find.textContaining('输入 SQL 语句后按回车执行'), findsOneWidget);
  });

  testWidgets('回车执行:回显语句、打印表格与摘要,并清空输入行', (tester) async {
    final s = await _pumpPage(tester);

    await _submit(tester, 'SELECT 1;');

    expect(s.driver.executedSql, ['SELECT 1']);
    expect(find.textContaining('daowei_dev=# SELECT 1;'), findsOneWidget);
    expect(find.textContaining('+----+'), findsOneWidget);
    expect(find.textContaining('| ok |'), findsOneWidget);
    expect(find.textContaining('1 row in set'), findsOneWidget);
    expect(tester.widget<Input>(find.byType(Input)).controller!.text, isEmpty);
  });

  testWidgets('未以分号收尾时不执行,提示符换成续行符', (tester) async {
    final s = await _pumpPage(tester);

    await _submit(tester, 'SELECT 1');

    expect(s.driver.executedSql, isEmpty);
    expect(find.text('daowei_dev=# '), findsNothing);
    expect(find.textContaining(RegExp(r'-> $')), findsOneWidget);
  });

  testWidgets('↑ 把上一条执行过的语句召回输入行', (tester) async {
    await _pumpPage(tester);

    await _submit(tester, 'SELECT 1;');
    await _submit(tester, 'SELECT 2;');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await _settle(tester);

    expect(tester.widget<Input>(find.byType(Input)).controller!.text,
        'SELECT 2');
  });
}
