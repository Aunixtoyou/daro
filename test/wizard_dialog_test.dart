import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:daro/app/app_state.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:daro/widgets/data_export_wizard.dart';
import 'package:daro/widgets/data_import_wizard.dart';
import 'package:daro/widgets/result_export_dialog.dart';
import 'package:daro/widgets/sql_file_run_dialog.dart';
import 'package:daro/l10n/locale_config.dart';

// 导入 / 导出向导的渲染冒烟测试:逐步走通对话框骨架,控件在 DialogBox 的
// IntrinsicHeight 约束下不抛布局异常,按钮可用态随表单进度变化。
// 导出向导按 Navicat 五步(格式 → 源与目标 → 列 → 附加选项 → 执行)覆盖,
// 其中「执行」步用手写假驱动真跑一遍批量导出,确认文件确实落盘。
// 各格式的编码细节由 test/db_transfer_test.dart 覆盖。

const _conn = ConnectionInfo(
  name: '本地 MySQL',
  typeId: 'mysql',
  host: '127.0.0.1',
  port: '3306',
  username: 'root',
  isLive: true,
);

/// 假驱动:isConnected 恒真,使 ConnectionManager 复用注入实例而不发起真实网络;
/// 只给向导用得上的最小面(表列表 / 字段 / 行数 / 分页取数)。
class _FakeDriver implements DatabaseDriver {
  _FakeDriver();

  static const tables = ['orders', 'users'];
  final List<String> previewSqls = [];

  static const _columns = ['id', 'city', 'note'];

  /// 每张表两行;orders 的第二行 note 为真 NULL
  int rowCount(String table) => table == 'users' ? 2 : 3;

  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> useDatabase(String database) async {}
  @override
  Future<List<String>> listDatabases() async => const ['demo'];
  @override
  Future<List<String>> listSchemas(String database, {String? schema}) async =>
      const [];
  @override
  Future<List<String>> listTables(String database, {String? schema}) async =>
      List.of(tables);
  @override
  Future<List<ColumnDef>> describeTable(String database, String table,
          {String? schema}) async =>
      [
        for (var i = 0; i < _columns.length; i++)
          ColumnDef(
            name: _columns[i],
            type: 'varchar(32)',
            primaryKey: i == 0,
          )
      ];
  @override
  Future<int> countTable(String database, String table,
          {String? schema, String? where}) async =>
      rowCount(table);
  @override
  Future<TablePreview> previewTable(String database, String table,
      {int limit = 100,
      int offset = 0,
      String? schema,
      String? where,
      String? orderBy}) async {
    previewSqls.add(orderBy ?? '');
    final total = rowCount(table);
    final rows = <List<String>>[];
    final nulls = <List<bool>>[];
    for (var i = offset; i < (offset + limit).clamp(0, total); i++) {
      final isNullRow = table == 'orders' && i == 1;
      rows.add([
        '$i',
        'c$i',
        isNullRow ? 'NULL' : 'n$i',
      ]);
      nulls.add([false, false, isNullRow]);
    }
    return TablePreview(
        columns: _columns, rows: rows, limit: limit, nullMask: nulls);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 大尺寸画布:向导是 900×640,默认 800×600 的测试视口会溢出
void _bigSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

late Directory _supportDir;

/// path_provider 在测试里无插件实现:统一回包临时目录,
/// 既让向导的默认输出目录可预期,也让 AppState 的异步落盘有处可去。
void _mockPathProvider() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => _supportDir.path,
  );
}

Widget harness(AppState app, Widget child) => ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: kAppLocalizationsDelegates,
        supportedLocales: kSupportedLocales,
        theme: ThemeData(brightness: Brightness.dark),
        home: Material(type: MaterialType.transparency, child: child),
      ),
    );

/// 打开向导并走到第 [step] 步(点 [step] 次「下一步 >」)
Future<void> _goto(WidgetTester tester, int step) async {
  for (var i = 0; i < step; i++) {
    await tester.tap(find.text('下一步 >'));
    await tester.pumpAndSettle();
  }
}

/// 找到指定文案所在 [Button] 的可用态
bool _buttonEnabled(WidgetTester tester, String text) {
  final el = tester.element(find.text(text));
  final button = el.findAncestorWidgetOfExactType<Button>();
  expect(button, isNotNull, reason: '$text 未包在 base-ui Button 中');
  return button!.onPressed != null;
}

/// 按 label 读取复选框勾选态
bool _checkValue(WidgetTester tester, String label) => tester
    .widget<CheckBox>(
        find.ancestor(of: find.text(label), matching: find.byType(CheckBox)))
    .value;

/// 按 label 勾选 / 取消复选框(点文字即可,CheckBox 的文字也在命中区内)
Future<void> _tapCheck(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  late AppState app;
  late _FakeDriver driver;

  setUp(() async {
    _supportDir = await Directory.systemTemp.createTemp('daro_wizard');
    _mockPathProvider();
    // 不在 tearDown 里 dispose:AppState 的异步 _loadPersisted 会在测试结束后
    // 仍回调 notifyListeners,主动释放反而触发「已释放的 ChangeNotifier」断言。
    app = AppState();
    app.addConnections([_conn]);
    driver = _FakeDriver();
    app.connectionManager.attachDriverForTest(_conn.name, driver);
  });

  // 不删临时目录:AppState._persist 是异步的,用例结束后仍可能回写
  // connections.json,提前删除会让测试被判为「完成后才失败」。

  Future<void> openWizard(WidgetTester tester,
      {String? presetWhere, String? presetSortColumn}) async {
    _bigSurface(tester);
    await tester.pumpWidget(harness(
      app,
      DataExportWizard(
        app: app,
        connection: _conn,
        database: 'demo',
        table: 'orders',
        presetWhere: presetWhere,
        presetSortColumn: presetSortColumn,
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('导出向导', () {
    testWidgets('五步可走通:每步有蓝色引导语,末步出现开始', (tester) async {
      await openWizard(tester);

      expect(find.text('导出向导'), findsOneWidget);
      expect(find.text('向导可以让你指定导出数据的细节。你要使用哪一种导出格式？'),
          findsOneWidget);
      // 6 种纯文本类格式,默认 CSV
      expect(find.text('CSV 文件 (*.csv)'), findsOneWidget);
      expect(find.text('SQL 脚本文件 (*.sql)'), findsOneWidget);
      expect(find.textContaining('逗号 / 分号 / 制表符分隔'), findsOneWidget);
      expect(_buttonEnabled(tester, '< 上一步'), isFalse);
      expect(find.text('取消'), findsOneWidget);

      await _goto(tester, 1);
      // 第 2 步:源/导出到 网格列出库内全部表,入口表已预勾选
      expect(find.text('你可以选择导出文件并定义一些附加选项。'), findsOneWidget);
      expect(find.text('源'), findsOneWidget);
      expect(find.text('导出到'), findsOneWidget);
      expect(find.text('orders'), findsOneWidget);
      expect(find.textContaining('orders.csv'), findsOneWidget);
      expect(find.textContaining('勾选 1 张表'), findsOneWidget);

      await _goto(tester, 1);
      // 第 3 步:源表下拉 + 可用字段,默认「所有字段」
      expect(find.text('你可以选择导出哪些列。'), findsOneWidget);
      expect(find.text('可用字段:'), findsOneWidget);
      expect(find.text('id'), findsOneWidget);
      expect(_checkValue(tester, '所有字段'), isTrue);

      await _goto(tester, 1);
      // 第 4 步:两个分组框
      expect(find.text('你可以定义一些附加的选项。'), findsOneWidget);
      expect(find.text('文件格式'), findsOneWidget);
      expect(find.text('数据格式'), findsOneWidget);

      await _goto(tester, 1);
      // 第 5 步:统计 + 日志 + 进度条,主按钮改为开始
      expect(find.textContaining('点击 [开始] 按钮开始导出'), findsOneWidget);
      expect(find.text('源表:'), findsOneWidget);
      expect(find.text('已处理:'), findsOneWidget);
      expect(find.text('时间:'), findsOneWidget);
      expect(find.text('开始'), findsOneWidget);
      expect(_buttonEnabled(tester, '下一步 >'), isFalse);
    });

    testWidgets('第 2 步未勾选任何表时不得前进', (tester) async {
      await openWizard(tester);
      await _goto(tester, 1);

      expect(_buttonEnabled(tester, '下一步 >'), isTrue);
      // 网格第 1 列是勾选框;取消唯一的勾选项后禁止前进
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消全选'));
      await tester.pumpAndSettle();
      expect(find.textContaining('勾选 0 张表'), findsOneWidget);
      expect(_buttonEnabled(tester, '下一步 >'), isFalse);
      // 「高级」跳到附加选项同样被禁止
      expect(_buttonEnabled(tester, '高级'), isFalse);
    });

    testWidgets('第 2 步单击行勾选框即刻生效(不被双击判定吞掉)', (tester) async {
      await openWizard(tester);
      await _goto(tester, 1);

      // 入口表已预勾选;勾选框在带双击手势的单元格里,按下瞬间就要结算
      await tester.tap(find.byType(CheckBox).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('勾选 0 张表'), findsOneWidget);
      await tester.tap(find.byType(CheckBox).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('勾选 1 张表'), findsOneWidget);
    });

    testWidgets('第 3 步取消「所有字段」后可逐列勾选,计数如实回显',
        (tester) async {
      await openWizard(tester);
      await _goto(tester, 2);

      expect(find.textContaining('导出 3 / 3 列'), findsOneWidget);
      // 全字段态下列复选框禁用,取消「所有字段」后才可编辑
      expect(_buttonEnabled(tester, '取消全选'), isFalse);
      await _tapCheck(tester, '所有字段');
      expect(_checkValue(tester, '所有字段'), isFalse);
      expect(find.textContaining('导出 3 / 3 列'), findsOneWidget);

      await _tapCheck(tester, 'note');
      expect(find.textContaining('导出 2 / 3 列'), findsOneWidget);
      await _tapCheck(tester, '取消全选');
      expect(find.textContaining('导出 0 / 3 列'), findsOneWidget);
    });

    testWidgets('附加选项只出现当前格式相关的项', (tester) async {
      await openWizard(tester);
      await _goto(tester, 3);
      // 默认 CSV:分隔符 / 文本识别符号 / BOM 在,SQL 与 JSON 专属项不在
      expect(find.text('分隔符:'), findsOneWidget);
      expect(find.text('文本识别符号:'), findsOneWidget);
      expect(find.text('写入 UTF-8 BOM(Excel 双击打开中文不乱码)'), findsOneWidget);
      expect(find.textContaining('包含建表语句'), findsNothing);
      expect(find.textContaining('缩进美化'), findsNothing);

      await tester.tap(find.text('<<'));
      await tester.pumpAndSettle();
      await _tapCheck(tester, 'SQL 脚本文件 (*.sql)');
      await _goto(tester, 3);
      // SQL:建表 / 批量在,纯分隔文本专属项消失;记录分隔符是通用项,仍在
      expect(find.textContaining('包含建表语句'), findsOneWidget);
      expect(find.text('每条 INSERT:'), findsOneWidget);
      expect(find.text('分隔符:'), findsNothing);
      expect(find.text('文本识别符号:'), findsNothing);
      expect(find.text('记录分隔符:'), findsOneWidget);
    });

    testWidgets('带入表数据页视图时标出筛选与排序,并注明只作用于当前表',
        (tester) async {
      await openWizard(
        tester,
        presetWhere: "`city` = '上海'",
        presetSortColumn: 'created_at',
      );

      await _goto(tester, 1);
      expect(find.textContaining("`city` = '上海'"), findsOneWidget);
      expect(find.textContaining('筛选条件仅应用于当前表「orders」'), findsOneWidget);

      await _goto(tester, 2);
      expect(
        find.textContaining('当前表沿用屏幕排序并以主键兜底'),
        findsOneWidget,
      );
    });

    testWidgets('集成:开始即按勾选表批量落盘,标题转 100% 并给出成功小结',
        (tester) async {
      await openWizard(tester);
      await _goto(tester, 1);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选').last);
      await tester.pumpAndSettle();
      await _goto(tester, 3);

      final ordersPath = '${_supportDir.path}/orders.csv';
      final usersPath = '${_supportDir.path}/users.csv';
      expect(File(usersPath).existsSync(), isFalse);

      await tester.runAsync(() async {
        await tester.tap(find.text('开始'));
        for (var i = 0; i < 60; i++) {
          await Future.delayed(const Duration(milliseconds: 25));
          if (File(ordersPath).existsSync() &&
              File(usersPath).existsSync()) break;
        }
        // 等 exportTablesBatch 收尾(cancel 计时器 + setState)
        await Future.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();

      expect(File(ordersPath).existsSync(), isTrue);
      final orders = File(ordersPath).readAsStringSync();
      // 首行表头 + 3 行;第二行的 note 是真 NULL → 按默认选项输出空串
      expect(orders, 'id,city,note\r\n0,c0,n0\r\n1,c1,\r\n2,c2,n2\r\n');
      // 默认勾选写 BOM(Excel 双击识别 UTF-8)
      expect(File(ordersPath).readAsBytesSync().sublist(0, 3),
          [0xEF, 0xBB, 0xBF]);
      expect(File(usersPath).readAsStringSync().replaceFirst('\uFEFF', ''),
          'id,city,note\r\n0,c0,n0\r\n1,c1,n1\r\n');

      // 标题跟随进度,日志逐表留痕,主按钮转为关闭
      expect(find.text('100% - 导出向导'), findsOneWidget);
      expect(find.textContaining('[EXP] Export table [orders]'), findsOneWidget);
      expect(find.textContaining('[EXP] Export table [users]'), findsOneWidget);
      expect(find.textContaining('导出完成:2 张表 / 5 行'), findsOneWidget);
      expect(find.text('关闭'), findsOneWidget);
      expect(tester.widget<ProgressBar>(find.byType(ProgressBar)).value, 100);
    });

    testWidgets('批量导出只写勾选的表', (tester) async {
      await openWizard(tester);
      await _goto(tester, 1);
      // 走真实交互:底部「全选」下拉里的同名菜单项(网格内勾选框被单元格双击手势接管)
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('勾选 2 张表'), findsOneWidget);
      await _goto(tester, 3);

      await tester.runAsync(() async {
        await tester.tap(find.text('开始'));
        for (var i = 0; i < 60; i++) {
          await Future.delayed(const Duration(milliseconds: 25));
          if (File('${_supportDir.path}/users.csv').existsSync()) break;
        }
        await Future.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();

      expect(File('${_supportDir.path}/users.csv').existsSync(), isTrue);
      expect(find.textContaining('导出完成:2 张表 / 5 行'), findsOneWidget);
    });

    testWidgets('列筛选真的少写列', (tester) async {
      await openWizard(tester);
      await _goto(tester, 2);
      await _tapCheck(tester, '所有字段');
      await _tapCheck(tester, 'note');
      await tester.tap(find.text('>>'));
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.text('开始'));
        await Future.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();

      expect(File('${_supportDir.path}/orders.csv').readAsStringSync(),
          isNot(contains('note')));
      expect(File('${_supportDir.path}/orders.csv').readAsStringSync(),
          'id,city\r\n0,c0\r\n1,c1\r\n2,c2\r\n');
    });
  });

  testWidgets('导入向导:未选文件时禁止进入映射步', (tester) async {
    _bigSurface(tester);
    await tester.pumpWidget(harness(
      app,
      DataImportWizard(
        app: app,
        connection: _conn,
        database: 'demo',
        table: 'orders',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('导入向导'), findsOneWidget);
    expect(find.text('源文件'), findsOneWidget);
    expect(find.text('字段映射'), findsOneWidget);
    expect(find.text('执行导入'), findsOneWidget);
    expect(find.text('浏览...'), findsOneWidget);
    expect(find.textContaining('请选择要导入的文件'), findsOneWidget);
    expect(_buttonEnabled(tester, '下一步 >'), isFalse);
  });

  testWidgets('结果导出对话框:无 SQL(INSERT),路径按标签预填', (tester) async {
    _bigSurface(tester);
    await tester.pumpWidget(harness(
      app,
      ResultExportDialog(
        data: _preview,
        typeId: 'mysql',
        database: 'demo',
        label: '查询 1',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('导出结果'), findsOneWidget);
    expect(find.textContaining('2 列 × 2 行结果'), findsOneWidget);
    expect(find.text('CSV 文件 (*.csv)'), findsOneWidget);
    // 结果集没有目标表:不提供 SQL(INSERT),也不出现 SQL 专属选项
    expect(find.text('SQL 脚本文件 (*.sql)'), findsNothing);
    expect(find.textContaining('包含建表语句'), findsNothing);
    expect(find.text('分隔符:'), findsOneWidget);
    expect(find.text('查询 1.csv'), findsOneWidget);
    expect(_buttonEnabled(tester, '导出'), isTrue);
  });

  testWidgets('结果导出对话框:点导出即把结果集写成文件', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('result_export');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = '${tmp.path}/out.csv';

    _bigSurface(tester);
    await tester.pumpWidget(harness(
      app,
      ResultExportDialog(
        data: _preview,
        typeId: 'mysql',
        database: 'demo',
        label: 'q',
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(Input), path);
    await tester.pumpAndSettle();
    // 真实磁盘 IO 不参与 FakeAsync 的时间推进,须在 runAsync 里等待事件循环
    await tester.runAsync(() async {
      await tester.tap(find.text('导出'));
      await Future.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(
      File(path).readAsStringSync(),
      'id,name\r\n1,\r\n2,bob\r\n',
      reason: '第一行的 name 是真 NULL,nullMask 应生效',
    );
    expect(find.textContaining('已导出 2 行'), findsOneWidget);
    // 导出完成后主按钮变为关闭,可再次改路径重跑
    expect(find.text('关闭'), findsOneWidget);
  });

  testWidgets('运行 SQL 文件:仅当路径可读时才允许开始执行', (tester) async {
    final dir = Directory.systemTemp.createTempSync('run_sql_ui');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // 测试结束后系统自会清理
      }
    });
    final sqlFile = File('${dir.path}/dump.sql')..writeAsStringSync('SELECT 1;');

    _bigSurface(tester);
    await tester.pumpWidget(harness(
      app,
      RunSqlFileDialog(app: app, connection: _conn, database: 'demo'),
    ));
    expect(_buttonEnabled(tester, '开始执行'), isFalse);

    await tester.enterText(find.byType(Input), sqlFile.path);
    await tester.pump();
    expect(_buttonEnabled(tester, '开始执行'), isTrue);
    expect(find.textContaining('dump.sql · 9 B'), findsOneWidget);

    // 改成不存在的路径:回显给出不可读提示,执行入口重新禁用
    await tester.enterText(find.byType(Input), '${dir.path}/missing.sql');
    await tester.pump();
    expect(_buttonEnabled(tester, '开始执行'), isFalse);
    expect(find.textContaining('文件不存在或不可读'), findsOneWidget);

    // 遇错即停默认不勾选(转储里可容忍报错很多)
    final checkBox = tester.widget<CheckBox>(find.byType(CheckBox).first);
    expect(checkBox.value, isFalse);
  });
}

/// 两行结果集:第二列首行为数据库 NULL(展示值同为 "NULL",靠 nullMask 区分)
final _preview = TablePreview(
  columns: const ['id', 'name'],
  rows: const [
    ['1', 'NULL'],
    ['2', 'bob']
  ],
  nullMask: const [
    [false, true],
    [false, false]
  ],
);
