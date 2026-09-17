import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:daro/data/schema_sync.dart';
import 'package:daro/widgets/schema_sync_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// 结构同步弹窗的「冒烟」widget 测试:只验证界面装配与浅层交互——打开即渲染源/目标、
// 预填当前树选中的连接、未选库时比较 / 部署禁用、连接下拉过滤掉文件型库、选项弹窗可开
// 并如实回写。比对 / 部署的深层逻辑属于 lib/data/schema_sync.dart(已单独被数据层覆盖),
// 且需要真实驱动会话,不在 widget 冒烟范围内(弹窗内部用默认工厂另开会话,测试不注入)。

/// 与 main.dart 同层级:Provider 必须在 MaterialApp 之上,showDialog 的弹层路由
/// 才能拿到 AppState(Tokens.of / AppColors.of 依赖它)。
Widget harness(AppState app, Widget home) => ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        theme: ThemeData(brightness: Brightness.light),
        home: home,
      ),
    );

/// 与「工具 → 结构同步...」一致的入口:showDialog 打开大弹窗。
Widget entryPage(AppState app) => Builder(
      builder: (context) => Material(
        child: Button(
          text: '打开结构同步',
          onPressed: () => showSchemaSyncDialog(context, app: app),
        ),
      ),
    );

/// 假驱动:isConnected 恒真 → [ConnectionManager] 复用注入的实例,不再新建真实连接;
/// listDatabases 给两条库名,足以驱动下拉框渲染。未覆写的成员走 noSuchMethod 返回 null。
class _FakeDriver implements DatabaseDriver {
  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> useDatabase(String database) async {}
  @override
  Future<List<String>> listDatabases() async => const ['dev', 'test'];
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

ConnectionInfo _mysql(String name) => ConnectionInfo(
      name: name,
      typeId: 'mysql',
      host: '10.255.255.1', // 不可路由;测试里永不真正连接(下拉/预填走假驱动)
      port: '3306',
      username: 'u',
      isLive: true,
    );

void main() {
  const src = '源库A';
  const tgt = '目标库B';
  const file = '文件库C'; // sqlite:被 structureSyncUnsupported 过滤,不进下拉

  late AppState app;
  late Directory supportDir;

  setUp(() async {
    // 指向临时目录:让 AppState 的异步落盘真实完成(而非悬到测试结束后),
    // 同时不污染用户目录。见 navicat_import_dialog_test 同款处理。
    supportDir = await Directory.systemTemp.createTemp('daro_sync_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => supportDir.path,
    );
    app = AppState();
    app.addConnections([
      _mysql(src),
      _mysql(tgt),
      ConnectionInfo(
        name: file,
        typeId: 'sqlite',
        host: '',
        port: '',
        username: '',
        isLive: true,
      ),
    ]);
    // 给两条 MySQL 连接挂假驱动:预填会自动 expandConnection,
    // 借假驱动完成,避免测试期发起真实网络。
    app.connectionManager.attachDriverForTest(src, _FakeDriver());
    app.connectionManager.attachDriverForTest(tgt, _FakeDriver());
  });

  testWidgets('打开即渲染源/目标、预填当前树选中连接、未选库时比较/部署禁用', (tester) async {
    _bigSurface(tester);
    // 预填:仅源侧连接名跟随树的选中项
    app.detailSelection.value =
        SelectedNode(NodeKind.connection, src, connection: src);

    await tester.pumpWidget(harness(app, entryPage(app)));
    await tester.tap(find.text('打开结构同步'));
    await tester.pumpAndSettle();

    expect(find.text('结构同步'), findsOneWidget); // DialogBox 标题
    expect(find.text('源(结构来源)'), findsOneWidget);
    expect(find.text('目标(部署到)'), findsOneWidget);
    // 源侧已预填该连接(只读下拉展示当前值),目标侧留空
    expect(find.text(src), findsWidgets);
    expect(find.text('选择连接'), findsWidgets);
    // 未选库 → 尚不可比较 / 不可部署
    expect(_buttonEnabled(tester, '比较'), isFalse);
    expect(_buttonEnabled(tester, '部署到目标'), isFalse);
    expect(find.text('尚未比较'), findsWidgets); // 结果区 + 页脚各一
  });

  testWidgets('连接下拉过滤掉文件型库(sqlite 不参与结构同步)', (tester) async {
    _bigSurface(tester);
    await tester.pumpWidget(harness(app, entryPage(app)));
    await tester.tap(find.text('打开结构同步'));
    await tester.pumpAndSettle();

    // 展开源侧连接下拉(第一个 ConnectionInfo 组合框)
    await tester.tap(find.byType(ComboBox<ConnectionInfo>).first);
    await tester.pumpAndSettle();

    expect(find.text(src), findsWidgets);
    expect(find.text(tgt), findsWidgets);
    expect(find.text(file), findsNothing); // 文件型库被过滤
  });

  testWidgets('选项弹窗:7 个开关齐全、默认值来自 SyncOptions、改一项确定后回到主弹窗', (tester) async {
    _bigSurface(tester);
    await tester.pumpWidget(harness(app, entryPage(app)));
    await tester.tap(find.text('打开结构同步'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('选项...'));
    await tester.pumpAndSettle();

    expect(find.text('结构同步选项'), findsOneWidget);
    for (final label in const [
      '表',
      '视图',
      '函数',
      '过程',
      '忽略注释差异',
      '去掉 MySQL 定义中的 DEFINER 子句',
      '定义比较忽略空白差异',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '缺少开关:$label');
    }
    // 默认值:忽略注释关,去 DEFINER 开(与 SyncOptions 一致)
    expect(_checkValue(tester, '忽略注释差异'), isFalse);
    expect(_checkValue(tester, '去掉 MySQL 定义中的 DEFINER 子句'), isTrue);

    await tester.tap(find.text('忽略注释差异'));
    await tester.pumpAndSettle();
    expect(_checkValue(tester, '忽略注释差异'), isTrue);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 选项弹窗已关闭,主弹窗仍在(比较按钮回来了)
    expect(find.text('结构同步选项'), findsNothing);
    expect(find.text('比较'), findsOneWidget);
    // 改了选项 → 旧比对作废:仍是「尚未比较」
    expect(find.text('尚未比较'), findsWidgets);
  });

  testWidgets('集成:注入假驱动走比对 → 差异树(新建/修改/删除)→ DDL 比较',
      (tester) async {
    _bigSurface(tester);

    final app = AppState();
    app.addConnections([_mysql('sync_src'), _mysql('sync_tgt')]);
    // 元数据缓存用假驱动填库名(源 srcdb / 目标 tgtdb),不触网。
    app.connectionManager
        .attachDriverForTest('sync_src', _Driver(db: 'srcdb', source: true));
    app.connectionManager
        .attachDriverForTest('sync_tgt', _Driver(db: 'tgtdb', source: false));
    // 源侧连接随树选中预填
    app.detailSelection.value =
        SelectedNode(NodeKind.connection, 'sync_src', connection: 'sync_src');

    // 比对 / 部署用工厂:按连接名回假驱动(视图三类差异)。
    final SyncDriverFactory factory = (ConnectionInfo c) => c.name == 'sync_src'
        ? _Driver(db: 'srcdb', source: true)
        : _Driver(db: 'tgtdb', source: false);

    await tester.pumpWidget(harness(
      app,
      Builder(
        builder: (context) => Material(
          child: Button(
            text: '打开结构同步',
            onPressed: () =>
                showSchemaSyncDialog(context, app: app, driverFactory: factory),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开结构同步'));
    await tester.pumpAndSettle();

    // 选源库
    await tester.tap(find.byType(ComboBox<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('srcdb'));
    await tester.pumpAndSettle();
    // 选目标连接
    await tester.tap(find.byType(ComboBox<ConnectionInfo>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('sync_tgt'));
    await tester.pumpAndSettle();
    // 选目标库
    await tester.tap(find.byType(ComboBox<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('tgtdb'));
    await tester.pumpAndSettle();

    // 两侧齐备 → 比较可用
    expect(_buttonEnabled(tester, '比较'), isTrue);
    await tester.tap(find.text('比较'));
    await tester.pumpAndSettle();

    // 差异分组:源独有新建立、两侧不同修改、目标独有删除,各 1
    expect(find.textContaining('要创建的对象（1）'), findsOneWidget);
    expect(find.textContaining('要修改的对象（1）'), findsOneWidget);
    expect(find.textContaining('要删除的对象（1）'), findsOneWidget);
    expect(find.text('v_only_src'), findsOneWidget);
    expect(find.text('v_diff'), findsOneWidget);
    expect(find.text('v_only_tgt'), findsOneWidget);
    // 默认勾选策略:新建 + 修改入勾,删除不入勾 → 页脚 2/3
    expect(find.text('勾选 2 / 共 3 处差异待部署（其中删除 1 项）'), findsOneWidget);

    // 未选对象时右侧是占位提示
    expect(find.text('从左侧选择一个对象查看 DDL 比较。'), findsOneWidget);

    // 点选“要创建”的视图 → 右侧渲染源 DDL 与将执行语句
    await tester.tap(find.text('v_only_src'));
    await tester.pumpAndSettle();
    expect(find.textContaining('源 · v_only_src'), findsOneWidget);
    expect(find.textContaining('将执行的语句（1）'), findsOneWidget);
    expect(find.textContaining('CREATE VIEW v_only_src'), findsWidgets);
  });
}

/// 放大测试视口,避免 1040×700 大弹窗被默认 800×600 压扁 / 命中重叠。
void _bigSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// base-ui Button 以 onPressed==null 表示禁用。
bool _buttonEnabled(WidgetTester tester, String text) {
  final el = tester.element(find.text(text));
  final button = el.findAncestorWidgetOfExactType<Button>();
  expect(button, isNotNull, reason: '$text 未包在 base-ui Button 中');
  return button!.onPressed != null;
}

/// 按 label 定位选项复选框并读取勾选态。
bool _checkValue(WidgetTester tester, String label) => tester
    .widget<CheckBox>(
        find.byWidgetPredicate((w) => w is CheckBox && w.label == label))
    .value;

/// 集成测试用假驱动:既能填库名(下拉),也提供视图定义(比对)。
/// 差异只来自视图:源独有 v_only_src(新建)、两侧 v_diff 定义不同(修改)、
/// 目标独有 v_only_tgt(删除);表 / 函数 / 过程留空避免走 readTableDesign。
class _Driver implements DatabaseDriver {
  _Driver({required this.db, required this.source});

  final String db;
  final bool source;

  Map<String, String?> get _views => source
      ? {
          'v_only_src': 'CREATE VIEW v_only_src AS SELECT 1',
          'v_diff': 'CREATE VIEW v_diff AS SELECT 1',
        }
      : {
          'v_diff': 'CREATE VIEW v_diff AS SELECT 2',
          'v_only_tgt': 'CREATE VIEW v_only_tgt AS SELECT 9',
        };

  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> useDatabase(String database) async {}
  @override
  Future<void> useSchema(String? schema) async {}
  @override
  Future<List<String>> listDatabases() async => [db];
  @override
  Future<List<String>> listSchemas(String database) async => const [];
  @override
  Future<List<String>> listTables(String database, {String? schema}) async =>
      const [];
  @override
  Future<List<String>> listViews(String database, {String? schema}) async =>
      _views.keys.toList();
  @override
  Future<List<String>> listFunctions(String database, {String? schema}) async =>
      const [];
  @override
  Future<List<String>> listProcedures(String database,
      {String? schema}) async => const [];
  @override
  Future<String?> getDefinition(String database, String name, String kind,
      {String? schema}) async =>
      _views[name];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
