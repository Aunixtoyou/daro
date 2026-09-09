import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:daro/app/app_state.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:daro/widgets/data_export_wizard.dart';
import 'package:daro/widgets/data_import_wizard.dart';
import 'package:daro/widgets/result_export_dialog.dart';
import 'package:daro/widgets/sql_file_run_dialog.dart';

// 导入 / 导出向导的渲染冒烟测试:三步骨架能逐步走通,控件在 DialogBox 的
// IntrinsicHeight 约束下不抛布局异常,按钮的可用态随表单进度变化。
// 取数 / 写库与文件格式由 test/db_transfer_test.dart 覆盖。

const _conn = ConnectionInfo(
  name: '本地 MySQL',
  typeId: 'mysql',
  host: '127.0.0.1',
  port: '3306',
  username: 'root',
);

Widget harness(AppState app, Widget child) => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: Material(
          type: MaterialType.transparency,
          child: child,
        ),
      ),
    );

/// 找到指定文案所在 [Button] 的可用态
bool _buttonEnabled(WidgetTester tester, String text) {
  final el = tester.element(find.text(text));
  final button = el.findAncestorWidgetOfExactType<Button>();
  expect(button, isNotNull, reason: '$text 未包在 base-ui Button 中');
  return button!.onPressed != null;
}

void main() {
  late AppState app;

  // 不在 tearDown 里 dispose:AppState 的异步 _loadPersisted 会在测试结束后
  // 仍回调 notifyListeners,主动释放反而触发「已释放的 ChangeNotifier」断言。
  setUp(() => app = AppState());

  testWidgets('导出向导:三步可走通,末步出现开始导出', (tester) async {
    await tester.pumpWidget(harness(
      app,
      DataExportWizard(
        app: app,
        connection: _conn,
        database: 'demo',
        table: 'orders',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('导出向导'), findsOneWidget);
    // 步骤条三步齐全
    expect(find.text('源与格式'), findsOneWidget);
    expect(find.text('导出选项'), findsOneWidget);
    expect(find.text('输出文件'), findsOneWidget);
    // 第 1 步:目标信息 + 默认格式
    expect(find.textContaining('导出表「orders」的数据'), findsOneWidget);
    expect(find.text('CSV / 文本'), findsOneWidget);
    expect(_buttonEnabled(tester, '< 上一步'), isFalse);

    await tester.tap(find.text('下一步 >'));
    await tester.pumpAndSettle();
    // 第 2 步:CSV 选项 + 共用分页设置
    expect(find.text('NULL 文本:'), findsOneWidget);
    expect(find.text('首行写入列名'), findsOneWidget);
    expect(find.text('分页行数:'), findsOneWidget);

    await tester.tap(find.text('下一步 >'));
    await tester.pumpAndSettle();
    // 第 3 步:输出路径已按表名 + 扩展名预填,可直接开始
    expect(find.text('输出文件:'), findsOneWidget);
    expect(find.text('orders.csv'), findsOneWidget);
    expect(_buttonEnabled(tester, '开始导出'), isTrue);
    // 最后一步时「下一步」禁用
    expect(_buttonEnabled(tester, '下一步 >'), isFalse);
  });

  testWidgets('导出向导:第 2 步只展示当前格式相关的选项', (tester) async {
    await tester.pumpWidget(harness(
      app,
      DataExportWizard(
        app: app,
        connection: _conn,
        database: 'demo',
        table: 'orders',
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('下一步 >'));
    await tester.pumpAndSettle();
    // 默认 CSV:只出现 CSV 选项,不出现 SQL / JSON 选项
    expect(find.text('分隔符:'), findsOneWidget);
    expect(find.text('写入 UTF-8 BOM(Excel 双击打开中文不乱码)'), findsOneWidget);
    expect(find.textContaining('包含建表语句'), findsNothing);
    expect(find.textContaining('缩进美化'), findsNothing);
  });

  testWidgets('导入向导:未选文件时禁止进入映射步', (tester) async {
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

  testWidgets('结果导出对话框:只有 CSV / JSON,路径按标签预填',
      (tester) async {
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
    expect(find.text('CSV / 文本'), findsOneWidget);
    // 结果集没有目标表:不提供 SQL(INSERT),也不出现 SQL 专属选项
    expect(find.text('SQL (INSERT)'), findsNothing);
    expect(find.textContaining('包含建表语句'), findsNothing);
    expect(find.text('分隔符:'), findsOneWidget);
    expect(find.text('查询 1.csv'), findsOneWidget);
    expect(_buttonEnabled(tester, '导出'), isTrue);
  });

  testWidgets('结果导出对话框:点导出即把结果集写成文件', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('result_export');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = '${tmp.path}/out.csv';

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

  testWidgets('导出向导:继承表数据页视图时标出筛选与排序', (tester) async {
    await tester.pumpWidget(harness(
      app,
      DataExportWizard(
        app: app,
        connection: _conn,
        database: 'demo',
        table: 'orders',
        presetWhere: "`city` = '上海'",
        presetSortColumn: 'created_at',
        presetSortAscending: false,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('筛选:'), findsOneWidget);
    expect(find.textContaining("`city` = '上海'"), findsOneWidget);
    expect(find.text('排序:'), findsOneWidget);
    expect(find.text('created_at 降序'), findsOneWidget);

    await tester.tap(find.text('下一步 >'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('导出沿用当前视图的排序'),
      findsOneWidget,
    );
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
    final checkBox =
        tester.widget<CheckBox>(find.byType(CheckBox).first);
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
