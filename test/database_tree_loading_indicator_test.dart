import 'dart:async';
import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:daro/main.dart';
import 'pin_system_locale.dart';
import 'package:daro/widgets/database_tree.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// 「打开中」的呈现方式:节点行首图标整体换成转圈指示器(Navicat 风格),
// 连接 / 库(对象列表)统一走这一条路,不再在节点下挂「加载中...」提示行。
//
// 驱动的库列表与表列表都用 Completer 卡住,把「加载中」这一瞬间稳定下来断言。

/// 库列表 / 表列表由测试决定何时返回,其余查询一律立即返回空
class _BlockingDriver implements DatabaseDriver {
  final dbs = Completer<List<String>>();
  final tables = Completer<List<String>>();

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> useDatabase(String database) async {}

  // 选中库节点会即时拉一次库级详情。驱动接口里返回 `Future<X?>` 的方法
  // 不能靠 noSuchMethod 兜底:它返回的 null 不是 Future,详情读失败会让
  // ConnectionManager 丢弃并重建**真实**驱动(去连 10.0.0.1),加载永远挂住。
  @override
  Future<DatabaseDetail?> readDatabaseDetail(String database) async => null;

  @override
  Future<List<String>> listSchemas(String database) async => const [];

  @override
  Future<List<String>> listDatabases() => dbs.future;

  @override
  Future<List<String>> listTables(String database, {String? schema}) =>
      tables.future;

  @override
  Future<List<String>> listViews(String database, {String? schema}) async =>
      const [];

  @override
  Future<List<String>> listMaterializedViews(String database,
          {String? schema}) async =>
      const [];

  @override
  Future<List<String>> listFunctions(String database, {String? schema}) async =>
      const [];

  @override
  Future<List<String>> listProcedures(String database,
          {String? schema}) async =>
      const [];

  @override
  Future<List<String>> listUsers(String database) async => const [];

  @override
  Future<Map<String, String>> listTableComments(String database,
          {String? schema}) async =>
      const {};

  @override
  Future<Map<String, String>> listViewComments(String database,
          {String? schema}) async =>
      const {};

  @override
  Future<Map<String, String>> listFunctionComments(String database,
          {String? schema}) async =>
      const {};

  @override
  Future<Map<String, int>> listTableRowEstimates(String database,
          {String? schema}) async =>
      const {};

  @override
  Future<QueryResult> executeQuery(String sql,
          {int limit = 1000, int offset = 0}) async =>
      const QueryResult(columns: [], rows: []);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 已保存密码 → 打开连接不再弹密码补录窗(that 弹窗另有回归用例)
const _conn = ConnectionInfo(
  name: '甲',
  typeId: 'mysql',
  host: '10.0.0.1',
  port: '3306',
  username: 'root',
  password: 'p',
  isLive: true,
);

void main() {
  late Directory dir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // AppState 每次改动都会 _persist → path_provider,没有该通道会抛
    dir = await Directory.systemTemp.createTemp('daro_tree_loading_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (c) async => dir.path);
  });

  Future<AppState> pumpApp(WidgetTester tester) async {
    pinSystemChineseLocale(tester);
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: const DbApp(),
    ));
    await tester.pump();
    return app;
  }

  Finder inTree(Finder matching) =>
      find.descendant(of: find.byType(DatabaseTree), matching: matching);

  Finder treeText(String text) => inTree(find.text(text));

  /// 树内行首的转圈指示器(scoped 到树,避开 Ribbon / 对象面板等处的 Spinner)
  Finder treeSpinner() => inTree(find.byType(Spinner));

  /// 推进若干帧让异步加载的后续步骤落地。
  /// 刻意不用 pumpAndSettle:加载中树上存在无限循环的转圈动画,永远等不到静止。
  Future<void> pumpFrames(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// 推过指示器的最小可见时长,让它自然收起
  Future<void> settleSpinner(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await pumpFrames(tester);
  }

  /// 双击树内某行展开(树的双击判定窗口是 500ms,两次点击需落在同窗口内)
  Future<void> doubleTapRow(WidgetTester tester, String name) async {
    await tester.tap(treeText(name));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(treeText(name));
    await pumpFrames(tester);
  }

  testWidgets('打开中:行首图标换成转圈指示器,不再挂「加载中...」提示行', (tester) async {
    final app = await pumpApp(tester);
    final driver = _BlockingDriver();
    app.addConnection(_conn);
    app.connectionManager.attachDriverForTest(_conn.name, driver);
    await tester.pump();

    expect(treeSpinner(), findsNothing, reason: '初始没有任何节点在打开中');

    // —— 打开连接:库列表卡在加载中,连接行的行首品牌图标应让位给转圈指示器
    await doubleTapRow(tester, '甲');
    expect(treeSpinner(), findsOneWidget, reason: '连接行行首应显示转圈指示器');
    expect(treeText('加载中...'), findsNothing, reason: '不再挂提示行');

    driver.dbs.complete(const ['bfin']);
    await pumpFrames(tester);
    // 指示器有最小可见时长:数据到位后仍会多留一会儿才收起
    expect(treeText('bfin'), findsOneWidget);
    await settleSpinner(tester);
    expect(treeSpinner(), findsNothing, reason: '库列表到位并停留够时长后恢复品牌图标');

    // —— 打开库:对象列表(表 / 视图 / 函数)卡在加载中,库行的行首图标换成转圈
    await doubleTapRow(tester, 'bfin');
    expect(treeSpinner(), findsOneWidget, reason: '库行行首应显示转圈指示器');
    expect(treeText('加载中...'), findsNothing, reason: '不再挂提示行');

    driver.tables.complete(const ['orders']);
    await pumpFrames(tester);
    await settleSpinner(tester);
    expect(treeSpinner(), findsNothing, reason: '对象列表到位并停留够时长后恢复库图标');
    expect(treeText('表'), findsOneWidget, reason: '加载完成后分组正常渲染');
  });

  testWidgets('加载快于一帧时,转圈指示器仍保证可见时长', (tester) async {
    final app = await pumpApp(tester);
    // 库列表立即返回:模拟本地库 / 已建连会话「打开」比一帧还快的情况。
    // 此时 loading→loaded 之间没有帧,指示器本会一次都不绘制。
    final driver = _BlockingDriver()..dbs.complete(const ['bfin']);
    app.addConnection(_conn);
    app.connectionManager.attachDriverForTest(_conn.name, driver);
    await tester.pump();

    await doubleTapRow(tester, '甲');
    expect(treeText('bfin'), findsOneWidget, reason: '库列表其实已经到位');
    expect(treeSpinner(), findsOneWidget,
        reason: '快于渲染一帧也要保证「打开中」被看见');
    expect(treeText('加载中...'), findsNothing);

    // 超过最小可见时长后自动收起(期间不阻塞数据,只是指示器多留一会儿)
    await settleSpinner(tester);
    expect(treeSpinner(), findsNothing, reason: '停留够时长后收起');
    expect(treeText('bfin'), findsOneWidget, reason: '数据不受影响');
  });
}
