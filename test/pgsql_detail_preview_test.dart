// 开发期自查工具：把 PostgreSQL 详情面板的四页离屏光栅化到 build/，
// 用于对照 Navicat 的字段顺序、行高与「使用 / 被使用」树的排版密度。
// 运行：flutter test test/pgsql_detail_preview_test.dart
//      → build/pgsql_{database,table,used_by,uses,ddl}.png
// 测试环境没有中文回退字体，图里中文会是方块：只用来核对版式，不核对字形。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:daro/app/app_state.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:daro/l10n/locale_config.dart';
import 'package:daro/theme/app_theme.dart';
import 'package:daro/widgets/database_info.dart';
import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _connName = 'pg预览';
const _dbName = 'daro_roadtest';
const _table = 'parking_zones';

const _tableNode = SelectedNode(NodeKind.table, _table,
    connection: _connName, database: _dbName);
const _dbNode =
    SelectedNode(NodeKind.database, _dbName, connection: _connName);

final _boundaryKey = GlobalKey();

/// 贴近实盘的一份 PG 元数据（public.parking_zones）。
const _tableDetail = TableDetail(
  name: _table,
  oid: '16834',
  owner: 'postgres',
  tableType: 'r',
  tablespace: 'pg_default',
  // reltuples = -1：从未 ANALYZE，驱动折成 null 而不是显示 0
  rowEstimate: null,
);

const _dbDetail = DatabaseDetail(
  name: _dbName,
  oid: '16393',
  owner: 'postgres',
  tablespace: 'pg_default',
  charset: 'UTF8',
  collation: 'Chinese_Centina.936',
  connectionLimit: '-1',
);

/// 「被使用」页：外键名下挂着 4 个 PG 自动生成的内部触发器，默认展开。
final _usedBy = [
  const DependentObject(
      schema: 'public',
      name: 'parking_gates_fkey',
      kind: 'FOREIGN KEY',
      degree: 'NORMAL',
      children: [
        DependentObject(
            schema: 'public',
            name: 'RI_ConstraintTrigger_a_16845',
            kind: 'TRIGGER',
            degree: 'INTERNAL'),
        DependentObject(
            schema: 'public',
            name: 'RI_ConstraintTrigger_a_16846',
            kind: 'TRIGGER',
            degree: 'INTERNAL'),
        DependentObject(
            schema: 'public',
            name: 'RI_ConstraintTrigger_c_16847',
            kind: 'TRIGGER',
            degree: 'INTERNAL'),
        DependentObject(
            schema: 'public',
            name: 'RI_ConstraintTrigger_c_16848',
            kind: 'TRIGGER',
            degree: 'INTERNAL'),
      ]),
  DependentObject(
      schema: 'public',
      name: '$_table',
      kind: 'SEQUENCE',
      degree: 'AUTO'),
  const DependentObject(
      schema: 'public',
      name: 'parking_zones_pkey',
      kind: 'PRIMARY KEY',
      degree: 'AUTO'),
  const DependentObject(
      schema: 'public',
      name: 'idx_parking_zones_code',
      kind: 'INDEX',
      degree: 'AUTO'),
  const DependentObject(
      schema: 'public',
      name: 'parking_zones_gate_id_not_null',
      kind: 'NOT NULL',
      degree: 'AUTO'),
  const DependentObject(
      schema: 'public',
      name: 'trig_touch_gate',
      kind: 'TRIGGER',
      degree: 'NORMAL'),
  const DependentObject(
      schema: 'public', name: 'gate_kind', kind: 'TYPE', degree: 'NORMAL'),
];

const _uses = [
  DependentObject(
      schema: 'public', name: 'parking_gates', kind: 'TABLE', degree: 'NORMAL'),
  DependentObject(
      schema: 'public', name: 'gate_kind', kind: 'TYPE', degree: 'NORMAL'),
];

class _PreviewDriver implements DatabaseDriver {
  /// 记每次调用的方向，用于断言「点哪页才取哪页」
  final List<bool> depCalls = [];

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> useDatabase(String database) async {}

  @override
  Future<DatabaseDetail?> readDatabaseDetail(String database) async =>
      _dbDetail;

  @override
  Future<TableDetail?> readTableDetail(String database, String table,
          {String? schema}) async =>
      _tableDetail;

  @override
  Future<int> countTable(String database, String table,
          {String? schema, String? where}) async =>
      128;

  @override
  Future<String?> getDefinition(String database, String name, String kind,
          {String? schema}) async =>
      'CREATE TABLE "public"."$_table" (\n'
      '  "id" int8 NOT NULL DEFAULT nextval(\'parking_zones_id_seq\'::regclass),\n'
      '  "code" varchar(32) COLLATE pg_catalog."default" NOT NULL,\n'
      '  "gate_id" int8 NOT NULL,\n'
      '  CONSTRAINT "parking_zones_pkey" PRIMARY KEY ("id"),\n'
      '  CONSTRAINT "parking_gates_fkey" FOREIGN KEY ("gate_id")\n'
      '      REFERENCES "public"."parking_gates" ("id") MATCH SIMPLE\n'
      '      ON UPDATE NO ACTION ON DELETE NO ACTION\n'
      ')\n'
      'TABLESPACE "pg_default";\n\n'
      'ALTER TABLE "public"."$_table" OWNER TO "postgres";\n\n'
      'CREATE UNIQUE INDEX "idx_parking_zones_code" ON "public"."$_table"\n'
      '  USING btree ("code" COLLATE pg_catalog."default" ASC NULLS LAST);';

  @override
  Future<List<DependentObject>?> readTableDependencies(
      String database, String table,
      {String? schema, bool usedBy = true}) async {
    depCalls.add(usedBy);
    return usedBy ? _usedBy : _uses;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late Directory dir;
  late _PreviewDriver driver;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    dir = Directory.systemTemp;
    driver = _PreviewDriver();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (c) async => dir.path);
  });

  Future<void> pump(WidgetTester tester, SelectedNode selection) async {
    tester.view.devicePixelRatio = 1.0;
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = AppState()
      ..addConnection(ConnectionInfo(
        name: _connName,
        typeId: 'postgresql',
        host: '121.40.5.11',
        port: '5432',
        username: 'postgres',
        isLive: true,
      ));
    app.connectionManager.attachDriverForTest(_connName, driver);
    app.detailSelection.value = selection;
    await tester.pumpWidget(MultiProvider(
      providers: [ChangeNotifierProvider.value(value: app)],
      child: TokenScope(
        tokens: AppTheme.light.toDesktopTokens(),
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light, AppTheme.light),
          locale: const Locale('zh'),
          localizationsDelegates: kAppLocalizationsDelegates,
          supportedLocales: kSupportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: _boundaryKey,
                child: SizedBox(
                    width: 380, height: 860, child: DatabaseInfo()),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  Future<void> shoot(WidgetTester tester, String file) async {
    // toImage 的 Future 在假异步调度下不完成，整段必须走 runAsync
    await tester.runAsync(() async {
      final boundary = _boundaryKey.currentContext!
          .findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/$file.png')
          .writeAsBytes(byteData!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull, reason: '抓帧前页面已抛异常');
  }

  testWidgets('预览:PG 表详情的信息 / 被使用 / 使用 / DDL 四页', (tester) async {
    await pump(tester, _tableNode);
    await shoot(tester, 'pgsql_table');

    await tester.tap(find.byIcon(Icons.call_received));
    await tester.pump();
    await tester.pump();
    await shoot(tester, 'pgsql_used_by');
    expect(driver.depCalls, [true]);

    await tester.tap(find.byIcon(Icons.call_made));
    await tester.pump();
    await tester.pump();
    await shoot(tester, 'pgsql_uses');
    expect(driver.depCalls, [true, false]);

    await tester.tap(find.text('DDL'));
    await tester.pump();
    await tester.pump();
    await shoot(tester, 'pgsql_ddl');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('预览:PG 库详情', (tester) async {
    await pump(tester, _dbNode);
    await shoot(tester, 'pgsql_database');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
