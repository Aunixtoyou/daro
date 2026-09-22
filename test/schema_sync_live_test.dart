import 'dart:convert';
import 'dart:io';

import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:daro/data/schema_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// **实连**回归测试:用本机 `shucong_aliyun` 连接验证「结构同步」的差异判定。
///
/// 全程只读(只做 listTables / readTableDesign,绝不部署 DDL),对应线上反馈:
/// 38 张表的库 vs 空库,差异页却把 38 张表全列成「无操作」。根因是
/// `_diffTable` 先判「某一侧反查失败」再判「目标缺该表」,而目标缺失时
/// tgtDesign 天然为 null → 解引用 targetName! 抛 Null check → 被兜底成
/// blocked + 无操作。离线假驱动版见 schema_sync_table_diff_test.dart。
///
/// 只在能读到该连接配置且网络可达时运行;否则整组 skip(不阻塞离线测试)。
///
/// 默认**不跑**:实连要占十几秒网络等待,和同批并行的 widget 时序用例
/// (如转圈可见时长)互相干扰。按需执行:
/// `DARO_LIVE_DB=1 flutter test test/schema_sync_live_test.dart`
const _connName = 'shucong_aliyun';
const _sourceDb = 'daowei_dev';
const _targetDb = 'test';
const _schema = 'public';

/// 与 [ConnectionStore] 相同落点(path_provider 在测试宿主里不可用,直读文件)
File? _storeFile() {
  final env = Platform.environment;
  final sep = Platform.pathSeparator;
  for (final root in [env['APPDATA'], env['LOCALAPPDATA']]) {
    if (root == null || root.isEmpty) continue;
    for (final appId in ['daro', 'db_lite']) {
      final f = File('$root$sep' 'com.example$sep$appId$sep' 'connections.json');
      if (f.existsSync()) return f;
    }
  }
  return null;
}

ConnectionInfo? _connectionByName() {
  final file = _storeFile();
  if (file == null) return null;
  try {
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    for (final raw in (json['connections'] as List)) {
      final c = ConnectionInfo.fromJson(raw as Map<String, dynamic>);
      if (c.name == _connName && c.isLive) return c;
    }
  } catch (_) {
    // 配置损坏按「不可用」处理,整组 skip
  }
  return null;
}

/// 探一次真实会话:能否连上且两个库都在。返回 skip 原因(null = 可跑)。
Future<String?> _unavailableReason(ConnectionInfo conn) async {
  final reason = structureSyncUnsupported(conn);
  if (reason != null) return reason;
  final driver = createDriver(conn);
  if (driver == null) return '无可用驱动';
  const budget = Duration(seconds: 20);
  try {
    await driver.connect().timeout(budget);
    final dbs = await driver.listDatabases().timeout(budget);
    final missing = [
      for (final db in [_sourceDb, _targetDb])
        if (!dbs.contains(db)) db,
    ];
    return missing.isEmpty
        ? null
        : '服务器上缺少库 $missing(现有:${dbs.join(', ')})';
  } catch (e) {
    return '无法连接 $_connName:$e';
  } finally {
    await driver.close();
  }
}

/// 某库某模式下的对象清单(表 / 视图)
Future<Map<SyncObjectKind, List<String>>> _names(
    ConnectionInfo conn, String db) async {
  final driver = createDriver(conn)!;
  await driver.connect();
  await driver.useDatabase(db);
  if (kUseSchemaTypes.contains(conn.typeId)) await driver.useSchema(_schema);
  try {
    return {
      SyncObjectKind.table: await driver.listTables(db, schema: _schema),
      SyncObjectKind.view: await driver.listViews(db, schema: _schema),
    };
  } finally {
    await driver.close();
  }
}

Future<void> main() async {
  final enabled = Platform.environment['DARO_LIVE_DB'] == '1';
  final conn = enabled ? _connectionByName() : null;
  var skip = !enabled
      ? '未开启实连(DARO_LIVE_DB=1 时才跑)'
      : conn == null
          ? '未找到「$_connName」连接配置(需本机 connections.json)'
          : await _unavailableReason(conn);
  skip ??= '';
  if (skip.isNotEmpty) {
    // 跳过原因不打印就只能看到「All tests skipped」,排查实连为何没跑很费劲
    // ignore: avoid_print
    print('实连测试跳过:$skip');
  }

  test('实连:目标库缺的表 → 判为「新建」并带 CREATE 语句', () async {
    final src = await _names(conn!, _sourceDb);
    final tgt = await _names(conn, _targetDb);

    final plan = await compareSchemaSync(
      source: SyncEndpoint(
          connection: conn, database: _sourceDb, schema: _schema),
      target: SyncEndpoint(
          connection: conn, database: _targetDb, schema: _schema),
      // 函数开关现在同时涵盖过程(Navicat 版式里没有单独的「过程」项)
      options: SyncOptions()..functions = false,
    );

    expect(plan.errors, isEmpty, reason: '${plan.errors}');
    expect(plan.canceled, isFalse);

    // 本用例的前提:目标侧确实比源侧少表(否则测不到「新建」路径)
    final srcTables = src[SyncObjectKind.table]!;
    final tgtTables = tgt[SyncObjectKind.table]!;
    expect(srcTables, isNotEmpty);
    final tgtKeys = tgtTables.map(_key).toSet();
    final missing = [
      for (final n in srcTables)
        if (!tgtKeys.contains(_key(n))) n,
    ];
    expect(missing, isNotEmpty,
        reason: '$_targetDb 已含 $_sourceDb 的全部表,测不到新建路径'
            '(请换一个空库再跑)');

    final byName = {
      for (final o in plan.objects) (o.kind, _key(o.name)): o,
    };
    for (final kind in [SyncObjectKind.table, SyncObjectKind.view]) {
      final tgtKeysOfKind = (kind == SyncObjectKind.table
              ? tgtTables
              : tgt[kind]!)
          .map(_key)
          .toSet();
      for (final n in src[kind]!) {
        final o = byName[(kind, _key(n))];
        expect(o, isNotNull, reason: '${kind.label}「$n」没进差异表');
        if (tgtKeysOfKind.contains(_key(n))) {
          // 两侧都在:该走结构比对,绝不该判成新建
          expect(o!.action, isNot(SyncAction.create),
              reason: '「$n」两侧都有却判成了新建');
          continue;
        }
        expect(o!.action, SyncAction.create,
            reason: '${kind.label}「$n」判成了 ${o.action}');
        expect(o.blocked, isFalse, reason: '${o.name} 被标错:${o.note}');
        expect(o.statements, isNotEmpty, reason: '${o.name} 无 DDL 可部署');
        expect(o.sourceDdl, isNotEmpty);
        expect(o.targetDdl, isEmpty, reason: '目标侧本不该有该对象的结构');
        expect(o.selected, isTrue, reason: '新建应默认勾选');
      }
      for (final n in tgt[kind]!) {
        // 两侧都在的归源侧那一轮判;这里只盯「目标独有」
        if (src[kind]!.map(_key).contains(_key(n))) continue;
        final o = byName[(kind, _key(n))];
        expect(o, isNotNull, reason: '目标独有${kind.label}「$n」没进差异表');
        expect(o!.action, SyncAction.drop,
            reason: '目标独有${kind.label}「$n」判成了 ${o.action}');
        expect(o.selected, isFalse, reason: '删除必须人工确认,不默认勾选');
      }
    }

    // 回归点:一个对象都不该被标错(旧版 38 张表全部 blocked + 无操作)
    final blocked = plan.objects.where((o) => o.blocked).toList();
    expect(blocked, isEmpty,
        reason: blocked.map((o) => '${o.name}:${o.note}').join(' | '));

    // 部署顺序不变量:轮到某个对象时,它引用到的表要么目标库里已经有了,
    // 要么在它之前已经建好(否则 CREATE … REFERENCES 撞 42P01,或引用列的
    // 主键还没补上撞 42830)
    final deployOrder = {
      for (var i = 0; i < plan.selected.length; i++) _key(plan.selected[i].name): i,
    };
    for (final o in plan.selected) {
      for (final dep in o.dependsOn) {
        final at = deployOrder[dep];
        expect(at != null ? at < deployOrder[_key(o.name)]! : tgtKeys.contains(dep),
            isTrue,
            reason: '${o.name} 依赖「$dep」:目标库没有它,而部署顺序里它排在后面'
                '(deployOrder[$dep]=$at < ${deployOrder[_key(o.name)]})');
      }
    }
    // 依赖元数据本身也得在实连下填出来:cameras 的两条外键在源库里是真实的
    final cams = byName[(SyncObjectKind.table, _key('cameras'))];
    if (cams != null) {
      expect(cams.dependsOn,
          containsAll(<String>['parking_gates', 'parking_zones']),
          reason: 'cameras 的 dependsOn 是 ${cams.dependsOn} —— 外键依赖没被提取');
    }

    print('实连 $_sourceDb → $_targetDb:'
        'create=${plan.countOf(SyncAction.create)} '
        'drop=${plan.countOf(SyncAction.drop)} '
        'alter=${plan.countOf(SyncAction.alter)} '
        'none=${plan.countOf(SyncAction.none)}');
  }, timeout: const Timeout(Duration(minutes: 4)), skip: skip.isEmpty ? false : skip);

  /// 反查保真度:源库每张表都过一遍。
  ///
  /// 钉住两个只能实连暴露的驱动 bug:
  /// 1. `"char"`(oid 18)在 postgres 驱动里没注册编解码器,取回的是
  ///    `UndecodedBytes`,`toString()` 得到 `Instance of 'UndecodedBytes'`
  ///    → `contype` / `attidentity` / `relpersistence` 的字母码分支全部静默
  ///    落空,**主键 / 外键 / identity 凭空消失**(部署出去的表没有主键)。
  /// 2. `pg_get_indexdef(oid, n, true)` 的列号从 1 起,而 `indkey`(int2vector)
  ///    下标从 0 起 → 首列拿到 0 = 整条索引定义原文,反查出的「索引字段」其实是
  ///    一句 `CREATE INDEX …`,部署时 42703 column does not exist。
  /// 两者都不报错、只是数据变空,所以断言必须直接盯住「该有值的没值」。
  test('实连:反查保真度(主键 / 外键 / identity / 索引列)', () async {
    final driver = createDriver(conn!)!;
    await driver.connect();
    await driver.useDatabase(_sourceDb);
    if (kUseSchemaTypes.contains(conn.typeId)) await driver.useSchema(_schema);
    final tables = await driver.listTables(_sourceDb, schema: _schema);
    expect(tables, isNotEmpty);

    final withPkOrFk = <String>[];
    for (final t in tables) {
      final d = await driver.readTableDesign(_sourceDb, t, schema: _schema);
      expect(d, isNotNull, reason: '「$t」反查返回 null');
      final design = d!;
      expect(design.columns, isNotEmpty, reason: '「$t」连列都没读出来');

      // 索引列必须是该表真实列名,不能混进 DDL 片段(bug 2)
      final colNames = design.columns.map((c) => c.name).toSet();
      for (final idx in design.indexes) {
        final parts = idx.columnList;
        expect(parts, isNotEmpty, reason: '$t 的索引 ${idx.name} 没有列');
        for (final p in parts) {
          // 整条定义被当成「列名」= int2vector 下标未 +1(首列取到 0)
          expect(p.contains('CREATE'), isFalse,
              reason: '$t 索引 ${idx.name} 的「列」是 `$p` —— '
                  '反查把 DDL 原文当成了列名(int2vector 下标未 +1)');
          // 表达式索引(lower(x) 之类)本就不是列名,只校验裸标识符
          if (!p.contains('(')) {
            expect(colNames, contains(p),
                reason: '$t 索引 ${idx.name} 引用了不存在的列 `$p`');
          }
        }
      }

      if (design.pkName.isNotEmpty) {
        withPkOrFk.add(t);
        final pkCols =
            design.columns.where((c) => c.primaryKey).map((c) => c.name);
        expect(pkCols, isNotEmpty,
            reason: '$t 有 pkName=${design.pkName} 却没有任何列被标成主键'
                '(contype 又解不出来了)');
      }
      // 带自增的表:identity 模式必须是 ALWAYS / BY DEFAULT 之一
      for (final c in design.columns.where((c) => c.hasIdentity)) {
        expect(['ALWAYS', 'BY DEFAULT'], contains(c.identityMode),
            reason: '$t.${c.name} 的 identityMode 是 `${c.identityMode}`'
                '(attidentity 又解不出来了)');
      }
      for (final fk in design.foreignKeys) {
        expect(fk.refTable, isNotEmpty,
            reason: '$t 的外键 ${fk.name} 没有引用表(外键被读成了空壳)');
      }
    }
    // 源库里确实存在带主键的表,否则上面的断言等于没跑
    expect(withPkOrFk, isNotEmpty,
        reason: '$_sourceDb 一张有主键的表都没反查出来');

    // 外键依赖要能喂给部署排序:cameras → parking_gates / parking_zones
    final cameras = await driver.readTableDesign(_sourceDb, 'cameras',
        schema: _schema);
    if (cameras != null && cameras.foreignKeys.isNotEmpty) {
      expect(cameras.foreignKeys.map((f) => f.refTable),
          containsAll(<String>['parking_gates', 'parking_zones']));
    }
    await driver.close();
  }, timeout: const Timeout(Duration(minutes: 4)), skip: skip.isEmpty ? false : skip);
}

String _key(String name) => name.trim().toLowerCase();
