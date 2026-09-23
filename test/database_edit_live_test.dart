import 'dart:convert';
import 'dart:io';

import 'package:daro/data/create_database_catalog.dart';
import 'package:daro/data/database_edit_catalog.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:daro/data/table_design.dart';
import 'package:flutter_test/flutter_test.dart';

/// **实连**校验:「编辑数据库」要跑的五条目录查询在真实 PostgreSQL 上是否成立。
///
/// 这些 SQL 全是手写系统表查询,离线单测只能验解析函数,验不了列名在目标服务端
/// 版本上是否存在(`pg_database.datencoding` / `pg_available_extensions.comment`
/// 都有版本门槛)。任何一条拼错都会让对话框静默退化成空列表,所以这里必须实跑。
///
/// 全程只读(只 SELECT 系统目录,绝不执行 DDL)。
/// 默认**不跑**:`DARO_LIVE_DB=1 flutter test test/database_edit_live_test.dart`
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

/// 取一个可用的 PG 系连接:优先配置里指定的名字,否则第一个 PG 系。
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
    return pg.firstWhere((c) => c.name == _preferConnName, orElse: () => pg.first);
  } catch (_) {
    // 配置损坏按「不可用」处理,整组 skip
    return null;
  }
}

/// 在目标库上下文里跑一条查询,返回二维文本表。
Future<List<List<String>>> _rows(
  ConnectionInfo conn,
  String sql, {
  String? database,
}) async {
  final driver = createDriver(conn)!;
  await driver.connect();
  if (database != null) await driver.useDatabase(database);
  try {
    final r = await driver.executeQuery(sql, limit: 2000);
    return r.rows;
  } finally {
    await driver.close();
  }
}

Future<void> main() async {
  final enabled = Platform.environment['DARO_LIVE_DB'] == '1';
  final conn = enabled ? _pgConnection() : null;
  var skip = !enabled
      ? '未开启实连(DARO_LIVE_DB=1 时才跑)'
      : conn == null
          ? '未找到可用的 PostgreSQL 系连接(需本机 connections.json)'
          : null;
  // 跳过原因不打印就只能看到「All tests skipped」,排查实连为何没跑很费劲
  if (skip != null) {
    // ignore: avoid_print
    print('实连测试跳过:$skip');
  }
  List<String> dbs = const [];
  if (skip == null) {
    final driver = createDriver(conn!)!;
    await driver.connect();
    dbs = await driver.listDatabases();
    await driver.close();
  }
  final target = skip == null ? _pickDatabase(conn!, dbs) : '';
  skip ??= target.isEmpty ? '服务器上没有可查询的库' : null;

  if (skip != null) {
    test('实连:编辑数据库目录查询(跳过)', () {}, skip: skip);
    return;
  }
  // 闭包里不保留 conn 的非空提升,统一用这个局部
  final c = conn!;

  test('实连:pg_database 属性查询列数与取值符合解析约定', () async {
    final version =
        parseServerVersion(await _rows(c, kPgServerVersionSql));
    expect(version, isNotNull, reason: 'server_version_num 必须能解析');
    final rows = await _rows(
      c,
      pgDatabasePropsSql(target,
          pg18Plus: version! >= kPgEncodingColumnRenamedVersion),
    );
    expect(rows, hasLength(1), reason: '库「$target」应当恰好一行');
    final r = rows.single;
    // 少一列就返回 null → 对话框会误判「读不到现状」并禁用保存
    expect(r.length, greaterThanOrEqualTo(9), reason: '$r');
    final props = parseDatabasePropsRow(rows, target)!;
    expect(props.name, target);
    expect(props.owner, isNotEmpty, reason: '所有者不该为空:${props}');
    expect(props.tablespace, isNotEmpty);
    expect(props.encoding, isNotEmpty, reason: 'pg_encoding_to_char 应当可用');
    expect(props.connectionLimit, greaterThan(-2));
    // ignore: avoid_print
    print('  $target → owner=${props.owner} space=${props.tablespace} '
        'enc=${props.encoding} limit=${props.connectionLimit} '
        'allow=${props.allowConnections} tpl=${props.isTemplate} '
        'comment="${props.comment}"');
  });

  test('实连:所有者 / 表空间候选可解析', () async {
    final owners = firstColumnOf(await _rows(c, kPgOwnerCatalogSql));
    final spaces =
        firstColumnOf(await _rows(c, kPgTablespaceCatalogSql));
    expect(owners, isNotEmpty);
    expect(spaces, contains('pg_default'));
  });

  test('实连:可用 / 已安装扩展两份清单列数为三且互不重叠', () async {
    final availableRows =
        await _rows(c, kPgAvailableExtensionsSql, database: target);
    final installedRows =
        await _rows(c, kPgInstalledExtensionsSql, database: target);
    for (final row in [...availableRows, ...installedRows]) {
      expect(row.length, 3, reason: '扩展查询应返回 name/version/comment:$row');
    }
    final available = parseExtensionVersionRows(availableRows);
    final installed = parseExtensionVersionRows(installedRows);
    // 「可用」列表按 installed_version IS NULL 过滤,两个列表不该有同名项
    expect(
      available.map((e) => e.name).toSet().intersection(
            installed.map((e) => e.name).toSet(),
          ),
      isEmpty,
    );
    // ignore: avoid_print
    print('  已安装:${installed.map((e) => '${e.name}@${e.version}').join(', ')}');
    // ignore: avoid_print
    print('  可装 ${available.length} 项,样例:'
        '${available.take(5).map((e) => '${e.name}@${e.version}').join(', ')}');
    expect(installed.map((e) => e.name), contains('plpgsql'),
        reason: 'plpgsql 在所有 PG 库里默认已安装');
    expect(installed.every((e) => e.version.isNotEmpty), isTrue,
        reason: '已安装项必须带版本号(右侧「版本」列)');
  });
}

/// 挑一个库来查:优先连接自己的默认库,否则第一个非模板库。
String _pickDatabase(ConnectionInfo conn, List<String> dbs) {
  if (conn.database.isNotEmpty && dbs.contains(conn.database)) {
    return conn.database;
  }
  const skip = {'template0', 'template1'};
  return dbs.firstWhere((d) => !skip.contains(d), orElse: () => '');
}
