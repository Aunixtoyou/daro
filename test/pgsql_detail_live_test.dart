import 'dart:convert';
import 'dart:io';

import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:daro/data/table_design.dart';
import 'package:flutter_test/flutter_test.dart';

/// **实连**校验:详情面板给 PostgreSQL 新写的四条目录查询在真实服务端上跑得通。
///
/// 和 `database_edit_live_test.dart` 同一个理由:这些 SQL 全是手写系统表查询,
/// 离线单测只能验解析函数,验不了列名 / 目录 OID 在目标服务端版本上是否存在
/// (`pg_class.relfamily`、`pg_depend` 的 regclass 解析、`pg_roles` 权限都有版本门槛)。
/// 拼错的后果是详情面板整页空或弹错误,而不是测试里的红字,所以必须实跑。
///
/// 全程只读(只 SELECT 系统目录,绝不执行 DDL)。
/// 默认**不跑**:`DARO_LIVE_DB=1 flutter test test/pgsql_detail_live_test.dart`
const _preferConnName = 'shucong_aliyun';

/// 与 [ConnectionStore] 相同落点(path_provider 在测试宿主里不可用,直读文件)
File? _storeFile() {
  final env = Platform.environment;
  final sep = Platform.pathSeparator;
  for (final root in [env['APPDATA'], env['LOCALAPPDATA']]) {
    if (root == null || root.isEmpty) continue;
    for (final appId in ['daro', 'db_lite']) {
      final f =
          File('$root$sep' 'com.example$sep$appId$sep' 'connections.json');
      if (f.existsSync()) return f;
    }
  }
  return null;
}

ConnectionInfo? _pgConnection() {
  final file = _storeFile();
  if (file == null) return null;
  try {
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final pg = <ConnectionInfo>[];
    for (final raw in (json['connections'] as List)) {
      final c = ConnectionInfo.fromJson(raw as Map<String, dynamic>);
      if (c.isLive && DdlBuilder.isPgLike(c.typeId)) pg.add(c);
    }
    if (pg.isEmpty) return null;
    return pg
        .firstWhere((c) => c.name == _preferConnName, orElse: () => pg.first);
  } catch (_) {
    return null;
  }
}

/// 挑一张**有外键**的表(依赖页只有在这种表上才有内容可验),退化则挑第一张
Future<(String, String, String?)> _pickTable(
    DatabaseDriver driver, List<String> dbs) async {
  for (final db in dbs) {
    await driver.useDatabase(db);
    final schemas = await driver.listSchemas(db);
    for (final sch in [if (schemas.isNotEmpty) ...schemas, 'public']) {
      final tables = await driver.listTables(db, schema: sch);
      for (final t in tables) {
        final deps =
            await driver.readTableDependencies(db, t, schema: sch, usedBy: true);
        if (deps != null && deps.any((e) => e.kind == 'FOREIGN KEY')) {
          return (db, t, sch);
        }
      }
    }
  }
  final db = dbs.first;
  await driver.useDatabase(db);
  final tables = await driver.listTables(db);
  return (db, tables.isEmpty ? '' : tables.first, null);
}

void main() {
  final enabled = Platform.environment['DARO_LIVE_DB'] == '1';
  final conn = enabled ? _pgConnection() : null;
  var skip = !enabled
      ? '未开启实连(DARO_LIVE_DB=1 时才跑)'
      : conn == null
          ? '未找到可用的 PostgreSQL 系连接(需本机 connections.json)'
          : null;
  if (skip != null) {
    // ignore: avoid_print
    print('实连测试跳过:$skip');
    test('实连:PG 详情目录查询(跳过)', () {}, skip: skip);
    return;
  }

  late DatabaseDriver driver;
  late String db;
  late String table;
  late String? schema;

  setUpAll(() async {
    driver = createDriver(conn!)!;
    await driver.connect();
    final dbs = (await driver.listDatabases())
        .where((d) => d != 'template0' && d != 'template1')
        .toList();
    expect(dbs, isNotEmpty, reason: '服务器上没有任何可查询的库');
    final picked = await _pickTable(driver, dbs);
    db = picked.$1;
    table = picked.$2;
    schema = picked.$3;
    // ignore: avoid_print
    print('  样本:$db.${schema ?? ''}.$table');
  });

  tearDownAll(() async => driver.close());

  test('实连:库详情字段齐全(编码 / 排序规则 / 所有者 / 表空间 / OID)', () async {
    final d = await driver.readDatabaseDetail(db);
    expect(d, isNotNull, reason: '读不到库属性会让详情面板退回基础展示');
    expect(d!.name, db);
    expect(d.oid, isNotEmpty, reason: 'pg_database.oid 应当取到');
    expect(d.owner, isNotEmpty);
    expect(d.tablespace, isNotEmpty);
    expect(d.charset, isNotEmpty, reason: '编码列名未按版本切换时会读空');
    // ignore: avoid_print
    print('  库:oid=${d.oid} owner=${d.owner} space=${d.tablespace} '
        'enc=${d.charset} collate=${d.collation} '
        'limit=${d.connectionLimit} comment="${d.comment}"');
  });

  test('实连:表详情字段齐全且 reltuples=-1 折算成 null', () async {
    final d = await driver.readTableDetail(db, table, schema: schema);
    expect(d, isNotNull);
    expect(d!.oid, isNotEmpty);
    expect(d.owner, isNotEmpty);
    expect(RegExp(r'^[a-z]$').hasMatch(d.tableType), isTrue,
        reason: 'tableType 应是 relkind 单字母码(翻译归界面),实得 "${d.tableType}"');
    expect(int.tryParse(d.oid), isNotNull, reason: 'OID 应是数字:${d.oid}');
    expect(d.rowEstimate == null || d.rowEstimate! >= 0, isTrue,
        reason: '未 ANALYZE 的 -1 必须折成 null 而不是当行数');
    // ignore: avoid_print
    print('  表:oid=${d.oid} owner=${d.owner} type=${d.tableType} '
        'rows=${d.rowEstimate} partOf=${d.partitionOf} '
        'inherits=${d.inheritsFrom} space=${d.tablespace} '
        'ff=${d.fillFactor} hasOids=${d.hasOids} '
        'acl="${d.acl.replaceAll('\n', ' | ')}"');
  });

  test('实连:被使用依赖可解析出类型与性质,外键带内部触发器子项', () async {
    final deps = await driver.readTableDependencies(db, table,
        schema: schema, usedBy: true);
    expect(deps, isNotNull, reason: 'null 会被界面当成「不支持」而隐藏页签');
    for (final o in deps!) {
      expect(o.name, isNotEmpty);
      expect(o.kind, isNotEmpty, reason: 'objs 目录漏了某张系统表就会解析不出类型');
      expect(
        const {'NORMAL', 'AUTO', 'INTERNAL', 'EXTENSION'},
        contains(o.degree),
        reason: 'deptype 未解码会落成 UNKNOWN:${o.degree}',
      );
      // 系统模式的对象不该出现在列表里(pg_toast 等)
      expect(o.schema, isNot('pg_catalog'));
    }
    final fk = deps.where((o) => o.kind == 'FOREIGN KEY').toList();
    expect(fk, isNotEmpty, reason: '样本表应带外键,否则这条断言没验到子项逻辑');
    for (final f in fk) {
      // ignore: avoid_print
      print('  外键:${f.qualifiedName} (${f.degree}) → '
          '${f.children.map((c) => '${c.name}').join(', ')}');
    }
    // 至少一个外键应当挂上 PG 自建的 RI_ConstraintTrigger_*
    expect(fk.any((f) => f.children.isNotEmpty), isTrue,
        reason: '内部触发器未按 tgconstraint 挂回父约束时,子项会全空');
  });

  test('实连:使用方向能查到本表引用的目标表(与反向不共用缓存)', () async {
    final uses = await driver.readTableDependencies(db, table,
        schema: schema, usedBy: false);
    expect(uses, isNotNull);
    // ignore: avoid_print
    print('  使用:${uses!.map((o) => '${o.qualifiedName}(${o.kind})').join(', ')}');
    // 自引用不该出现在任一方向里
    for (final o in uses) {
      expect(
        o.schema == (schema ?? 'public') && o.name == table,
        isFalse,
        reason: '表不依赖自己:${o.qualifiedName}',
      );
    }
  });

  test('实连:表 DDL 由设计器模型重建并可执行文本非空', () async {
    final ddl = await driver.getDefinition(db, table, 'table', schema: schema);
    expect(ddl, isNotNull);
    expect(ddl!, contains('CREATE TABLE'), reason: ddl);
    // ignore: avoid_print
    print('  DDL:\n$ddl');
  });

  test('实连:库 DDL 重建含 CREATE DATABASE 与所有者', () async {
    final ddl = await driver.getDefinition(db, db, 'database');
    expect(ddl, isNotNull);
    expect(ddl!, contains('CREATE DATABASE'));
    expect(ddl, contains('ENCODING'), reason: ddl);
    // ignore: avoid_print
    print('  库 DDL:\n$ddl');
  });
}
