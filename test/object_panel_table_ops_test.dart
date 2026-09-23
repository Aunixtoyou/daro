import 'dart:io';

import 'package:daro/app/app_state.dart';
import 'package:daro/app/connection_manager.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:daro/widgets/object_panel.dart';
import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:daro/l10n/locale_config.dart';

// 对象面板表列表的四项交互:框选多选、F2 内联改名、Ctrl+C / Ctrl+V 复制粘贴表、
// Del 删除选中表。
// 交互全部落在 AppState(批量选中 / 表剪贴板 / 粘贴命名),因此既有纯逻辑用例
// 直接测 AppState,再由 widget 用例用手势与真实按键驱动面板。
// 驱动走假实现:只记录收到的 SQL,不断言服务端行为。

/// 记录收到的 SQL;表列表可按需增长(粘贴克隆后刷新要能看见新表)
class _FakeDriver implements DatabaseDriver {
  _FakeDriver(
    this.tables, {
    this.comments = const {},
    this.rows = const {},
  });

  final List<String> tables;
  final List<String> sqls = [];

  /// 表名 → 注释(列表模式「注释」列的数据源)
  final Map<String, String> comments;

  /// 表名 → 估算行数(未列出的表无估算值,界面显示横杠)
  final Map<String, int> rows;

  /// 被 COUNT(*) 过的表名,按调用顺序
  final List<String> counted = [];

  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> useDatabase(String database) async {}
  @override
  Future<List<String>> listSchemas(String database) async => const [];
  @override
  Future<List<String>> listDatabases() async => const ['bfin'];
  @override
  Future<List<String>> listTables(String database, {String? schema}) async =>
      List.of(tables);
  @override
  Future<Map<String, String>> listTableComments(String database,
          {String? schema}) async =>
      comments;
  @override
  Future<Map<String, int>> listTableRowEstimates(String database,
          {String? schema}) async =>
      rows;
  @override
  Future<int> countTable(String database, String table,
      {String? schema, String? where}) async {
    counted.add(table);
    return rows[table] ?? 0;
  }
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
  Future<QueryResult> executeQuery(String sql,
      {int limit = 1000, int offset = 0}) async {
    sqls.add(sql);
    return const QueryResult(columns: [], rows: []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _conn = ConnectionInfo(
  name: 'c',
  typeId: 'mysql',
  host: 'h',
  port: '3306',
  username: 'u',
  isLive: true,
);

Future<({AppState app, _FakeDriver driver})> _panelWith(
  WidgetTester tester,
  List<String> tables, {
  Map<String, String> comments = const {},
  Map<String, int> rows = const {},
  bool grid = true,
}) async {
  final app = AppState();
  final driver = _FakeDriver(tables, comments: comments, rows: rows);
  app.addConnections([_conn]);
  app.connectionManager.attachDriverForTest('c', driver);
  await app.connectionManager.expandDatabase(_conn, 'bfin');
  app.setObjectContext('c', 'bfin');
  app.setObjectLayout(grid);
  expect(
    app.connectionManager.tableStateOf('c', 'bfin').status,
    LoadStatus.loaded,
    reason: '假驱动没能完成对象列表加载,面板不会渲染表项',
  );

  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: kAppLocalizationsDelegates,
        supportedLocales: kSupportedLocales,
        // 与 main.dart 同构:Input 内的 TextField 需要 Material 祖先
        home: const Material(child: ObjectPanel()),
      ),
    ),
  );
  await _settle(tester);
  return (app: app, driver: driver);
}

/// 跑固定几帧代替 pumpAndSettle:输入框光标闪烁 / 加载指示都是持续动画,
/// pumpAndSettle 会一直等到超时
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  late Directory supportDir;

  setUp(() async {
    // AppState 会异步落盘:指向临时目录,避免污染用户目录也避免悬空 future
    supportDir = await Directory.systemTemp.createTemp('daro_panel_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => supportDir.path,
    );
  });

  group('AppState 批量选中与粘贴命名', () {
    test('selectMany 整盘替换选中,只通知真正变化的项', () {
      final app = AppState();
      app.selectTable('a');
      final bNotifier = app.itemNotifierFor('b');
      final aNotifier = app.itemNotifierFor('a');
      expect(aNotifier.value, isTrue);

      app.selectMany(['b', 'c']);

      expect(app.selectedTables, {'b', 'c'});
      expect(aNotifier.value, isFalse);
      expect(bNotifier.value, isTrue);
      // 再次给同一批:命中集合未变,不重复通知
      var notified = 0;
      bNotifier.addListener(() => notified++);
      app.selectMany(['b', 'c']);
      expect(notified, 0);
    });

    test('selectMany additive 并入原选中(Ctrl 框选)', () {
      final app = AppState();
      app.selectTable('a');
      app.selectMany(['b'], additive: true);
      expect(app.selectedTables, {'a', 'b'});
    });

    test('粘贴命名:x_copy,占用则 x_copy_2 递增且批次内互不撞名', () {
      final app = AppState();
      app.copyTablesToClipboard(['x', 'y'], connection: 'c', database: 'bfin');

      expect(
        app.tablePastePlan({'x', 'y'}),
        [('x', 'x_copy'), ('y', 'y_copy')],
      );
      // 库里已有 x_copy → 让位给 x_copy_2
      expect(
        app.tablePastePlan({'x', 'y', 'x_copy'}),
        [('x', 'x_copy_2'), ('y', 'y_copy')],
      );
    });

    test('无剪贴板时粘贴计划为空', () {
      expect(AppState().tablePastePlan({'x'}), isEmpty);
    });
  });

  group('对象面板交互', () {
    testWidgets('鼠标框选命中选框内的表(网格按列优先取项)', (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctx =
          await _panelWith(tester, ['t1', 't2', 't3', 't4', 't5', 't6']);
      final app = ctx.app;

      // 列高 = 可视高度 → 6 个对象全在第一列纵向排开;
      // 选框从 t1 左上角内侧横到 t3 中心即命中 t1~t3(手势给全局坐标,
      // 面板内部按内容区原点换算)。起手点必须落在内容区内:紧凑行高下
      // 文字顶距内容区顶缘只剩几 px,再向上偏就打不到框选层了。
      final first = tester.getTopLeft(find.text('t1'));
      final third = tester.getCenter(find.text('t3'));
      final gesture = await tester.startGesture(first + const Offset(-8, 2));
      await tester.pump();
      await gesture.moveTo(third + const Offset(8, 4));
      await tester.pump();
      await gesture.up();
      await _settle(tester);

      expect(app.selectedTables, {'t1', 't2', 't3'});
    });

    testWidgets('详细布局纵向排:第一列排满可视高度才向右开新列', (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final names = [for (var i = 1; i <= 60; i++) 't$i'];
      await _panelWith(tester, names);

      final center = {for (final n in names) n: tester.getCenter(find.text(n))};
      final firstX = center['t1']!.dx;
      // 第 2 项在第 1 项**正下方**(旧实现按 ceil(数量/列数) 定行高,会摊到右侧)
      expect(center['t2']!.dx, closeTo(firstX, 1));
      expect(center['t2']!.dy, greaterThan(center['t1']!.dy));

      final firstCol = names.where((n) => (center[n]!.dx - firstX).abs() < 1);
      // 一屏高度装得下 30+ 行:列是真的排满,而不是按对象数均分
      expect(firstCol.length, greaterThanOrEqualTo(30));
      // 溢出项紧接第一列末尾,并回到顶部另起一列
      final overflow = names.firstWhere((n) => center[n]!.dx > firstX + 1);
      expect(overflow, 't${firstCol.length + 1}');
      expect(center[overflow]!.dy, closeTo(center['t1']!.dy, 1));
    });

    testWidgets('F2 进入内联改名,点到别处即提交 ALTER TABLE … RENAME TO', (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final (:app, :driver) =
          await _panelWith(tester, ['acct_bill', 'acct_pay']);

      await tester.tap(find.text('acct_bill'));
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await _settle(tester);

      expect(find.byType(InlineEditor), findsOneWidget);

      await tester.enterText(find.byType(InlineEditor), 'acct_bill_v2');
      // 点编辑格以外的空白:失焦 → 提交
      await tester.tapAt(const Offset(400, 500));
      await _settle(tester);

      expect(find.byType(InlineEditor), findsNothing);
      expect(
        driver.sqls,
        contains('ALTER TABLE `acct_bill` RENAME TO `acct_bill_v2`'),
      );
      // 改名成功后选中跟随新名
      expect(app.selectedTables, {'acct_bill_v2'});
    });

    testWidgets('Ctrl+点选多张表 → Ctrl+C → Ctrl+V 确认后逐表克隆', (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final tables = ['acct_bill', 'acct_pay'];
      final (:app, :driver) = await _panelWith(tester, tables);

      await tester.tap(find.text('acct_bill'));
      await _settle(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('acct_pay'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);
      expect(app.selectedTables, {'acct_bill', 'acct_pay'});

      // Ctrl+C
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(app.tableClipboard!.tables, ['acct_bill', 'acct_pay']);

      // Ctrl+V → 确认框列出「源 → 新名」
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);

      expect(find.textContaining('acct_bill → acct_bill_copy'), findsOneWidget);
      expect(find.textContaining('acct_pay → acct_pay_copy'), findsOneWidget);
      await tester.tap(find.text('粘贴'));
      await _settle(tester);

      expect(
        driver.sqls,
        containsAll([
          'CREATE TABLE `acct_bill_copy` AS SELECT * FROM `acct_bill`',
          'CREATE TABLE `acct_pay_copy` AS SELECT * FROM `acct_pay`',
        ]),
      );
    });

    testWidgets('选中表按 Del → 确认后 DROP TABLE；未选中时不弹确认', (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final (:app, :driver) =
          await _panelWith(tester, ['acct_bill', 'acct_pay']);

      // 工具栏的「删除表」按钮常驻(仅禁用),故只匹配确认框正文
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await _settle(tester);
      expect(find.textContaining('确定要删除表'), findsNothing);

      await tester.tap(find.text('acct_bill'));
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await _settle(tester);
      expect(find.textContaining('确定要删除表「acct_bill」'), findsOneWidget);

      await tester.tap(find.text('删除'));
      await _settle(tester);

      expect(driver.sqls, contains('DROP TABLE IF EXISTS `acct_bill`'));
      expect(app.selectedTables, isEmpty);
    });
  });

  group('对象面板列表模式(名称 / 行 / 注释)', () {
    testWidgets('渲染固定表头;无估算值的对象显示横杠,加载过程不发 COUNT(*)',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctx = await _panelWith(tester, ['t1', 't2'],
          comments: {'t1': '账单表'}, grid: false);

      expect(find.text('名称'), findsOneWidget);
      expect(find.text('行(估算)'), findsOneWidget);
      expect(find.text('注释'), findsOneWidget);
      // 行数只读目录统计信息:两张表都没有估算值 → 横杠,且绝不发 COUNT(*)
      expect(find.text('-'), findsNWidgets(2));
      expect(ctx.driver.counted, isEmpty);
      // 无注释的对象留空,不显示 'null'
      expect(find.text('账单表'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    testWidgets('估算行数随列表自动填上,过万折成「约 N 万」', (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctx = await _panelWith(tester, ['t1', 't2', 't3'],
          rows: {'t1': 17, 't2': 12345}, grid: false);

      expect(find.text('17'), findsOneWidget);
      expect(find.text('约1.2万'), findsOneWidget);
      // 未统计的表留横杠,而不是 0(0 会被误读成空表)
      expect(find.text('-'), findsOneWidget);
      expect(ctx.driver.counted, isEmpty);
    });

    testWidgets('框选命中扣除固定表头:表头内拖动不选中,行区间按列表行号取',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctx = await _panelWith(tester, ['t1', 't2', 't3'], grid: false);
      final app = ctx.app;

      // 完全落在表头内的拖动:扣掉表头后选框在列表上方 → 无命中
      final headerTop = tester.getTopLeft(find.text('名称'));
      var gesture =
          await tester.startGesture(headerTop + const Offset(20, 2));
      await tester.pump();
      await gesture.moveTo(headerTop + const Offset(60, 16));
      await tester.pump();
      await gesture.up();
      await _settle(tester);
      expect(app.selectedTables, isEmpty);

      // 从首行左上拖到第三行中心 → 恰好三行(未因表头偏移错行)
      final first = tester.getTopLeft(find.text('t1'));
      final third = tester.getCenter(find.text('t3'));
      gesture = await tester.startGesture(first - const Offset(8, 2));
      await tester.pump();
      await gesture.moveTo(third + const Offset(8, 4));
      await tester.pump();
      await gesture.up();
      await _settle(tester);
      expect(app.selectedTables, {'t1', 't2', 't3'});
    });
  });

  group('估算行数', () {
    test('随对象列表一起加载;重载列表时重新取值,全程不 COUNT', () async {
      final manager = ConnectionManager();
      final driver = _FakeDriver(['t1', 't2'], rows: {'t2': 5});
      manager.attachDriverForTest('c', driver);
      await manager.expandDatabase(_conn, 'bfin');

      expect(manager.tableStateOf('c', 'bfin').rowEstimates, {'t2': 5});

      await manager.refreshDatabase(_conn, 'bfin');
      expect(manager.tableStateOf('c', 'bfin').rowEstimates, {'t2': 5});
      expect(driver.counted, isEmpty);
    });

    test('引擎取不到估算值时降级为空,不影响列表本身', () async {
      final manager = ConnectionManager();
      manager.attachDriverForTest('c', _NoEstimateDriver(['t1']));
      await manager.expandDatabase(_conn, 'bfin');

      final state = manager.tableStateOf('c', 'bfin');
      expect(state.status, LoadStatus.loaded);
      expect(state.tables, ['t1']);
      expect(state.rowEstimates, isEmpty);
    });
  });
}

/// 估算行数查询抛错的驱动:验证降级路径(权限不足 / 引擎无此统计)
class _NoEstimateDriver extends _FakeDriver {
  _NoEstimateDriver(super.tables);

  @override
  Future<Map<String, int>> listTableRowEstimates(String database,
      {String? schema}) async {
    throw Exception('no permission');
  }
}
