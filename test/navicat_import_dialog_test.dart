import 'dart:convert';
import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/data/navicat_import.dart';
import 'package:daro/widgets/navicat_import_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// 导入向导的端到端测试:临时目录里放一份真实格式的 .ncx,走「粘贴/选路径 → 自动
// 解析(回车或失焦触发) → 勾选 → 导入」全链路,并检查 connections.json 真的落了盘、
// 密码确实解了出来。算法与字段映射本身的覆盖面在 test/navicat_import_test.dart。

const _ncx = '''
<?xml version="1.0" encoding="UTF-8"?>
<Connections Ver="1.5">
	<Connection ConnectionName="账套库" ConnType="MYSQL" ServiceProvider="Default" Host="10.0.0.11" Port="3306" UserName="root" Password="D079CE5CDFD2DBB3DE1C9AD758B6989F" SavePassword="true" Encoding="65001"/>
	<Connection ConnectionName="订单库" ConnType="SQLITE" DatabaseFileName="C:\\data\\orderdb.db" UserName="" Password="" SavePassword="true" SQLiteEncrypt="false"/>
	<Connection ConnectionName="老 Oracle" ConnType="ORACLE" Host="10.0.0.20" Port="1521" Database="ORCL" UserName="scott" Password="ACCD060DF11B61DB7730FA7791F5B178" SavePassword="true"/>
</Connections>
''';

/// 与 main.dart 同层级:Provider 必须在 MaterialApp 之上,否则 showDialog 的
/// 弹层路由拿不到 AppState(Tokens.of 依赖它)
Widget harness(AppState app, Widget home) => ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: home,
      ),
    );

/// 与「文件 → 从 Navicat 导入连接...」一致的入口:showDialog 打开向导
Widget entryPage(AppState app) => Builder(
      builder: (context) => Material(
        child: Button(
          text: '打开导入向导',
          onPressed: () => showNavicatImportDialog(context, app: app),
        ),
      ),
    );

void main() {
  late AppState app;
  late Directory supportDir;
  late File ncxFile;

  setUp(() async {
    app = AppState();
    // 连接配置落在「应用支持目录」:测试里把它指到临时目录,
    // 既让落盘真实发生,也不污染用户目录
    supportDir = await Directory.systemTemp.createTemp('daro_ncx_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => supportDir.path,
    );
    ncxFile = File('${supportDir.path}${Platform.pathSeparator}connections.ncx')
      ..writeAsStringSync(_ncx, flush: true);
  });

  testWidgets('解析 → 导入:密码解密落盘,不支持的引擎不进入连接树',
      (tester) async {
    await tester.pumpWidget(harness(app, entryPage(app)));
    await tester.tap(find.text('打开导入向导'));
    await tester.pumpAndSettle();

    expect(find.text('请先选择 Navicat 导出的 .ncx 文件。'), findsOneWidget);
    // 「解析」按钮已删除:选文件、回车、失焦都会自动读取
    expect(find.text('解析'), findsNothing);
    // 未解析时「导入选中」不可用,避免空列表点出个 0 条的假成功
    expect(_buttonEnabled(tester, '导入选中'), isFalse);

    await _pasteAndBlur(tester, ncxFile.path);

    expect(find.textContaining('已解析 3 条连接'), findsOneWidget);
    // 同一路径再次失焦不重复解析:默认勾选不会被抹掉
    await tester.tap(find.byType(Input));
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(find.text('已勾选 2 / 可导入 2'), findsOneWidget);
    expect(find.textContaining('引擎不支持 1'), findsOneWidget);
    // MySQL 那条密码应还原为明文;SQLite 无密码;Oracle 不参与导入
    expect(find.text('密码已解密'), findsOneWidget);
    expect(find.text('不支持 ORACLE'), findsOneWidget);
    expect(find.text('订单库'), findsOneWidget);

    await tester.tap(find.text('导入选中'));
    await tester.pumpAndSettle();

    expect(app.connections.map((c) => c.name), ['账套库', '订单库']);
    final mysql = app.connections.first;
    expect(mysql.password, 'p@ssw0rd-mysql');
    expect(mysql.typeId, 'mysql');
    expect(mysql.isLive, isTrue);
    // 落盘校验见下面的纯异步 test:fakeAsync 不驱动 path_provider 通道回包,
    // 在 widget 测试里等 connections.json 只会等出一个假阴性
  });

  testWidgets('再次导入同一文件:全部标为已存在同名,默认不勾选', (tester) async {
    // 先导入一遍
    app.addConnections([
      ConnectionInfo(
        name: '账套库',
        typeId: 'mysql',
        host: '10.0.0.11',
        port: '3306',
        username: 'root',
        isLive: true,
      ),
    ]);
    await tester.pumpWidget(harness(app, entryPage(app)));
    await tester.tap(find.text('打开导入向导'));
    await tester.pumpAndSettle();
    await _pasteAndSubmit(tester, ncxFile.path);

    expect(find.textContaining('重名 1'), findsOneWidget);
    // 剩下的可导入项(订单库)默认勾选,重名的那条默认不勾
    expect(find.text('已勾选 1 / 可导入 2'), findsOneWidget);
    expect(find.text('已存在同名'), findsOneWidget);
    expect(app.connections.length, 1);
  });

  testWidgets('行点击即切换勾选,与复选框共用同一状态', (tester) async {
    await tester.pumpWidget(harness(app, entryPage(app)));
    await tester.tap(find.text('打开导入向导'));
    await tester.pumpAndSettle();
    await _pasteAndBlur(tester, ncxFile.path);

    expect(_checked(tester, '订单库'), isTrue);
    await tester.tap(find.text('订单库'));
    await tester.pumpAndSettle();
    expect(_checked(tester, '订单库'), isFalse);
    expect(find.text('已勾选 1 / 可导入 2'), findsOneWidget);

    await tester.tap(find.text('全选可导入'));
    await tester.pumpAndSettle();
    expect(find.text('已勾选 2 / 可导入 2'), findsOneWidget);
  });

  testWidgets('选了非 NCX 文件:如实报出原因,不给出可导入列表', (tester) async {
    final bogus = File('${supportDir.path}${Platform.pathSeparator}bogus.ncx')
      ..writeAsStringSync('这不是 XML', flush: true);
    await tester.pumpWidget(harness(app, entryPage(app)));
    await tester.tap(find.text('打开导入向导'));
    await tester.pumpAndSettle();
    await _pasteAndSubmit(tester, bogus.path);

    expect(find.textContaining('解析失败'), findsOneWidget);
    expect(find.textContaining('已解析'), findsNothing);
    expect(_buttonEnabled(tester, '导入选中'), isFalse);
  });

  /// 落盘 + 启动加载竞态:这条链要走真实事件循环(path_provider 通道回包),
  /// 所以用普通 test 而不是 testWidgets。
  test('导入结果写入 connections.json,且不被启动期间的加载冲掉', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('daro_ncx_persist');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (c) async => dir.path);
    // 磁盘上先放一条旧连接:AppState 的加载是异步的,新导入若发生在加载完成前,
    // 老实现的 clear() 会把它抹掉,并把只剩旧连接的列表写回磁盘
    final store =
        File('${dir.path}${Platform.pathSeparator}connections.json')
          ..writeAsStringSync(jsonEncode({
            'connections': [
              const ConnectionInfo(
                      name: '旧连接',
                      typeId: 'mysql',
                      host: 'h0',
                      port: '3306',
                      username: 'u')
                  .toJson(),
            ]
          }));
    final app = AppState();
    final ncx = NavicatNcx.parse(_ncx);
    app.addConnections(ncx.connections
        .where((e) => e.isSupported)
        .map((e) => e.toConnection())
        .toList());
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final saved = jsonDecode(store.readAsStringSync()) as Map<String, dynamic>;
    final byName = {
      for (final c in (saved['connections'] as List).cast<Map<String, dynamic>>())
        c['name'] as String: c,
    };
    expect(byName.keys, containsAll(['旧连接', '账套库', '订单库']));
    expect(byName['账套库']!['password'], 'p@ssw0rd-mysql');
    expect(byName['账套库']!['host'], '10.0.0.11');
    expect(byName['订单库']!['host'], r'C:\data\orderdb.db');
  });
}

/// 粘贴路径后「点到别处」:输入框失焦即自动读取(取代原先的「解析」按钮)
Future<void> _pasteAndBlur(WidgetTester tester, String path) async {
  await tester.tap(find.byType(Input));
  await tester.enterText(find.byType(Input), path);
  await tester.pump();
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

/// 粘贴路径后按回车:走输入的 onSubmitted 解析
Future<void> _pasteAndSubmit(WidgetTester tester, String path) async {
  await tester.tap(find.byType(Input));
  await tester.enterText(find.byType(Input), path);
  await tester.pump();
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

/// 找到指定文案所在 [Button] 的可用态（base-ui Button 用 onPressed==null 表示禁用）
bool _buttonEnabled(WidgetTester tester, String text) {
  final el = tester.element(find.text(text));
  final button = el.findAncestorWidgetOfExactType<Button>();
  expect(button, isNotNull, reason: '$text 未包在 base-ui Button 中');
  return button!.onPressed != null;
}

/// 指定名称所在行的复选框状态
bool _checked(WidgetTester tester, String name) {
  final el = tester.element(find.text(name));
  final row = el.findAncestorWidgetOfExactType<Row>()!;
  final box = row.children.whereType<CheckBox>().first;
  return box.value;
}
