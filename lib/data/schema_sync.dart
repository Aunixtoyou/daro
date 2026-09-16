/// 「工具 → 结构同步」的数据层:比对源 / 目标两侧的模式,产出可部署的 DDL,
/// 并把选中的差异部署到目标。
///
/// 结构差异不自己实现:表级差异复用「设计表」已有的
/// [DdlBuilder.buildAlterStatements] / [DdlBuilder.alterUnsupported](两侧都经
/// [DatabaseDriver.readTableDesign] 反查为 [DesignTable]),视图 / 函数 / 过程
/// 按 [DatabaseDriver.getDefinition] 取回的定义文本比较。
///
/// 比对与部署都**另开专用驱动实例**(见 [SyncDriverFactory]),不复用
/// [ConnectionManager] 里连接树共享的长连接:源与目标常是同一连接下的两个库
/// (dev → test),共享会话会被反复 `useDatabase` 改上下文,PG 家族还会因此
/// 断开重连,既拖慢比对也会打乱树与查询页的运行上下文。
library;

import '../app/connection_manager.dart';
import 'db_data.dart';
import 'drivers/db_driver.dart';
import 'table_design.dart';

/// 参与同步比对的对象类别。
enum SyncObjectKind {
  table('表', 'TABLE'),
  view('视图', 'VIEW'),
  function('函数', 'FUNCTION'),
  procedure('过程', 'PROCEDURE');

  const SyncObjectKind(this.label, this.dropKeyword);

  /// 界面显示名
  final String label;

  /// DROP 语句的关键字
  final String dropKeyword;

  /// 该类别 → 驱动上的列表查询
  Future<List<String>> Function(DatabaseDriver driver, String database,
      {String? schema}) get lister => switch (this) {
            SyncObjectKind.table => (d, db, {schema}) => d.listTables(db, schema: schema),
            SyncObjectKind.view => (d, db, {schema}) => d.listViews(db, schema: schema),
            SyncObjectKind.function =>
              (d, db, {schema}) => d.listFunctions(db, schema: schema),
            SyncObjectKind.procedure =>
              (d, db, {schema}) => d.listProcedures(db, schema: schema),
          };

  /// [DatabaseDriver.getDefinition] 的 kind 参数(表无定义文本)
  String? get definitionKind => switch (this) {
        SyncObjectKind.view => 'view',
        SyncObjectKind.function => 'function',
        SyncObjectKind.procedure => 'procedure',
        SyncObjectKind.table => null,
      };
}

/// 单个对象在同步中的处置动作。
enum SyncAction {
  alter('要修改的对象', '修改'),
  create('要创建的对象', '新建'),
  drop('要删除的对象', '删除'),
  none('无操作', '无操作');

  const SyncAction(this.groupLabel, this.label);

  /// 分组标题(与参考工具的差异树一致)
  final String groupLabel;

  /// 「操作」列文本
  final String label;
}

/// 一侧的定位:连接 + 库 + 可选模式。
class SyncEndpoint {
  const SyncEndpoint({
    required this.connection,
    required this.database,
    this.schema,
  });

  final ConnectionInfo connection;
  final String database;

  /// 模式(无模式层的类型为空;MySQL 的模式就是库,故留空)
  final String? schema;

  /// 库已选定即可比对(无模式层的类型不要求模式)
  bool get ready => connection.name.isNotEmpty && database.isNotEmpty;

  /// 头部摘要用的 `库.模式` 文本
  String get displayTarget =>
      schema == null || schema!.isEmpty ? database : '$database.${schema!}';
}

/// 比对选项(「选项」按钮弹出的那组开关)。
class SyncOptions {
  bool tables = true;
  bool views = true;
  bool functions = true;
  bool procedures = true;

  /// 忽略注释差异:只过滤**独立**的注释语句(PG 的 `COMMENT ON …`、
  /// MySQL 的表注释 `ALTER TABLE … COMMENT = …`)。MySQL 的列注释写在列定义里,
  /// 无法从 MODIFY COLUMN 中剥掉,故该类型下列注释差异仍会出现。
  bool ignoreComments = false;

  /// 去掉 MySQL 定义文本里的 `DEFINER=…@…` 子句(目标端没有该账号时 CREATE 会失败)
  bool stripDefiner = true;

  /// 例程定义比较时折叠空白(数据库返回的定义常差一个换行 / 缩进)
  bool ignoreDefinitionSpace = true;

  /// 该对象类别是否参与比对
  bool enabledOf(SyncObjectKind kind) => switch (kind) {
        SyncObjectKind.table => tables,
        SyncObjectKind.view => views,
        SyncObjectKind.function => functions,
        SyncObjectKind.procedure => procedures,
      };

  /// 拷贝(弹窗回写用)
  SyncOptions copy() => SyncOptions()
    ..tables = tables
    ..views = views
    ..functions = functions
    ..procedures = procedures
    ..ignoreComments = ignoreComments
    ..stripDefiner = stripDefiner
    ..ignoreDefinitionSpace = ignoreDefinitionSpace;
}

/// 一个对象(表 / 视图 / 函数 / 过程)的比对结果。
class SyncObject {
  SyncObject({
    required this.kind,
    required this.name,
    this.action = SyncAction.none,
    this.statements = const [],
    this.sourceDdl = '',
    this.targetDdl = '',
    this.note,
    this.blocked = false,
    this.checked,
  });

  final SyncObjectKind kind;

  /// 对象名(源侧名字;目标侧仅大小写不同时也用源侧写法展示)
  final String name;

  /// 处置动作
  SyncAction action;

  /// 要在目标上执行的 DDL(按顺序)
  List<String> statements;

  /// 「DDL 比较」左栏:源侧结构文本
  String sourceDdl;

  /// 「DDL 比较」右栏:目标侧结构文本
  String targetDdl;

  /// 补充说明(读取失败 / 无法用 ALTER 表达 / 目标多余对象默认不勾选)
  String? note;

  /// 不可部署(比对该对象时出错);勾选它也没有语句可执行
  bool blocked;

  /// 是否纳入部署(差异页勾选)
  bool get deployable => !blocked && statements.isNotEmpty;

  /// 是否可勾选(无操作 / 不可部署的对象不给勾)
  bool get selectable => deployable;

  /// 有差异(需要出现在要创建 / 要修改 / 要删除分组里)
  bool get changed => action != SyncAction.none;

  /// 界面勾选状态;null = 用户未动过,取 [defaultSelected]。
  /// 直接落在对象上(而非外挂表),重新比较后勾选态自然随对象一起丢弃。
  bool? checked;

  /// 默认勾选策略:新建 / 修改默认勾选;**删除默认不勾选**
  /// (破坏性操作必须人工确认,避免一键把目标库多余对象清空)。
  bool get defaultSelected =>
      action == SyncAction.create || action == SyncAction.alter;

  /// 是否纳入部署(不可部署的对象永远为 false)
  bool get selected => deployable && (checked ?? defaultSelected);

  set selected(bool value) => checked = value;
}

/// 一次比对的完整结果。
class SyncPlan {
  SyncPlan({this.objects = const [], this.errors = const []});

  /// 全部对象(含无操作)
  final List<SyncObject> objects;

  /// 整体级错误(某类对象列表拉取失败等);非空时结果不完整,界面必须显示
  final List<String> errors;

  Iterable<SyncObject> ofAction(SyncAction action) =>
      objects.where((o) => o.action == action);

  int countOf(SyncAction action) => ofAction(action).length;

  /// 已勾选且可部署的对象
  List<SyncObject> get selected =>
      objects.where((o) => o.selected && o.deployable).toList();

  /// 部署脚本全文(按勾选顺序拼接)
  String deployScript() => [
        for (final o in selected) ...o.statements.map((s) => '$s;'),
      ].join('\n');
}

/// 对象上的勾选状态由 [SyncObject.checked] 持有(界面写,引擎读)。

/// 驱动工厂:比对 / 部署用**独立**会话,测试可注入假驱动。
typedef SyncDriverFactory = DatabaseDriver? Function(ConnectionInfo conn);

DatabaseDriver? _defaultDriverFactory(ConnectionInfo conn) => createDriver(conn);

/// 该连接能否参与结构同步;不能时返回原因(界面直接展示,不静默跳过)。
String? structureSyncUnsupported(ConnectionInfo conn) {
  if (!conn.isLive) return '连接「${conn.name}」不是真实连接,无法读取结构';
  if (!kSupportedDriverTypes.contains(conn.typeId)) {
    return '连接「${conn.name}」的类型(${conn.typeId})暂无驱动实现';
  }
  if (conn.typeId == 'sqlite' || conn.typeId == 'access') {
    return '连接「${conn.name}」是文件型数据库,不支持结构反查,暂不参与结构同步';
  }
  return null;
}

/// 比对源 / 目标两侧。
///
/// [onProgress] 在每开始处理一个对象时回调(阶段名 + 已完成 / 总数),界面据此
/// 显示进度;总数为 0 表示该类别无对象。
Future<SyncPlan> compareSchemaSync({
  required SyncEndpoint source,
  required SyncEndpoint target,
  SyncOptions? options,
  SyncDriverFactory? driverFactory,
  void Function(String stage, int done, int total)? onProgress,
}) async {
  final opt = options ?? SyncOptions();
  final factory = driverFactory ?? _defaultDriverFactory;
  final errors = <String>[];
  final objects = <SyncObject>[];

  final reason = _sideReason(source) ?? _sideReason(target);
  if (reason != null) {
    return SyncPlan(errors: [reason]);
  }
  if (source.connection.typeId != target.connection.typeId) {
    return SyncPlan(errors: [
      '源与目标的连接类型不同'
          '(${source.connection.typeId} → ${target.connection.typeId}),暂不支持跨类型结构同步',
    ]);
  }
  final typeId = source.connection.typeId;

  final srcDriver = factory(source.connection);
  final tgtDriver = factory(target.connection);
  if (srcDriver == null || tgtDriver == null) {
    return SyncPlan(errors: ['暂不支持 ${typeId} 类型的结构同步']);
  }

  final src = _Side(driver: srcDriver, endpoint: source);
  final tgt = _Side(driver: tgtDriver, endpoint: target);
  try {
    await src.open();
    await tgt.open();

    for (final kind in SyncObjectKind.values) {
      if (!opt.enabledOf(kind)) continue;
      final List<String> srcNames, tgtNames;
      try {
        srcNames = await kind.lister(src.driver, source.database, schema: source.schema);
        tgtNames = await kind.lister(tgt.driver, target.database, schema: target.schema);
      } catch (e) {
        errors.add('读取${kind.label}列表失败:$e');
        continue;
      }
      final names = _pairByName(srcNames, tgtNames);
      final total = names.length;
      var done = 0;
      for (final pair in names) {
        done++;
        onProgress?.call('比对${kind.label}', done, total);
        objects.add(await _diffOne(
          kind: kind,
          typeId: typeId,
          options: opt,
          source: src,
          target: tgt,
          sourceName: pair.$1,
          targetName: pair.$2,
        ));
      }
    }
    onProgress?.call('比对完成', 1, 1);
  } catch (e) {
    // 打不开会话(地址 / 密码 / 权限问题):整体失败,不产出半成品差异表
    errors.add(e.toString());
  } finally {
    await src.driver.close();
    await tgt.driver.close();
  }
  return SyncPlan(objects: objects, errors: errors);
}

/// 把选中的差异部署到目标库。
///
/// 逐对象执行:PostgreSQL 家族把**单个对象**的语句包进一条事务(失败只回滚该
/// 对象,已成功的对象保留),其余类型 DDL 自带提交,按顺序执行。
/// 任一对象失败不影响后续对象,[DeployItem.error] 记录原因。
Future<DeployReport> deploySchemaSync({
  required SyncEndpoint target,
  required List<SyncObject> selected,
  SyncDriverFactory? driverFactory,
  void Function(DeployItem item)? onItemDone,
}) async {
  final factory = driverFactory ?? _defaultDriverFactory;
  final items = <DeployItem>[];
  if (selected.isEmpty) return DeployReport(items);
  final driver = factory(target.connection);
  if (driver == null) {
    return DeployReport([
      for (final o in selected) DeployItem(o, error: '暂不支持 ${target.connection.typeId} 类型'),
    ]);
  }
  final useTx = DdlBuilder.isPgLike(target.connection.typeId);
  try {
    await driver.connect();
    await driver.useDatabase(target.database);
    if (kUseSchemaTypes.contains(target.connection.typeId)) {
      await driver.useSchema(target.schema);
    }
    for (final obj in selected) {
      final item = DeployItem(obj);
      items.add(item);
      try {
        if (useTx) await driver.executeQuery('BEGIN', limit: 1);
        for (final sql in obj.statements) {
          await driver.executeQuery(sql, limit: 1);
        }
        if (useTx) await driver.executeQuery('COMMIT', limit: 1);
      } catch (e) {
        if (useTx) {
          try {
            await driver.executeQuery('ROLLBACK', limit: 1);
          } catch (_) {
            // 回滚失败不覆盖原始错误
          }
        }
        item.error = e.toString();
      }
      onItemDone?.call(item);
    }
  } catch (e) {
    // 会话建立失败:未执行的项统一记错,已记录的项保持原状
    for (final obj in selected) {
      if (items.any((it) => it.object == obj)) continue;
      final item = DeployItem(obj, error: e.toString());
      items.add(item);
      onItemDone?.call(item);
    }
  } finally {
    await driver.close();
  }
  return DeployReport(items);
}

/// 一个对象的部署结果。
class DeployItem {
  DeployItem(this.object, {this.error});

  /// 被部署的对象
  final SyncObject object;

  /// 失败原因;null = 成功
  String? error;

  bool get ok => error == null;
}

/// 一次部署的汇总。
class DeployReport {
  const DeployReport(this.items);

  final List<DeployItem> items;

  int get successCount => items.where((e) => e.ok).length;
  int get failureCount => items.length - successCount;
  bool get allOk => failureCount == 0;
}

/// 服务器版本文本(信息面板「服务器版本」)。
///
/// 走 [ConnectionManager](连接树已建立的长连接),不额外开新会话;取不到时
/// 返回 null,界面显示 `--`。SQL 按类型选定:PG 的 `current_setting('server_version')`
/// 返回形如 `180003` 的整数版本,与参考工具一致。
Future<String?> readServerVersion(
  ConnectionManager manager,
  ConnectionInfo conn, {
  String? database,
}) async {
  if (!conn.isLive || !kSupportedDriverTypes.contains(conn.typeId)) return null;
  final sql = switch (conn.typeId) {
    'postgresql' => "SELECT current_setting('server_version')",
    'mysql' || 'mariadb' => 'SELECT VERSION()',
    'sqlserver' => "SELECT CONVERT(varchar(128), SERVERPROPERTY('ProductVersion'))",
    'sqlite' => 'SELECT sqlite_version()',
    _ => null,
  };
  if (sql == null) return null;
  try {
    final result = await manager.runQuery(
      conn,
      sql,
      database: database,
      limit: 1,
    );
    if (result.rows.isEmpty || result.rows.first.isEmpty) return null;
    final v = result.rows.first.first.trim();
    return v.isEmpty ? null : v;
  } catch (_) {
    // 版本查询失败不影响主流程:信息面板该格留空即可
    return null;
  }
}

// ────────────────────────────────────────────────────────────
// 内部实现
// ────────────────────────────────────────────────────────────

String? _sideReason(SyncEndpoint side) {
  if (!side.ready) return '请完整选择源与目标的连接 / 数据库';
  return structureSyncUnsupported(side.connection);
}

/// 一侧的会话上下文(驱动 + 定位)
class _Side {
  _Side({required this.driver, required this.endpoint});

  final DatabaseDriver driver;
  final SyncEndpoint endpoint;

  ConnectionInfo get connection => endpoint.connection;

  Future<void> open() async {
    await driver.connect();
    await driver.useDatabase(endpoint.database);
    // 只有 PG 家族有会话级 search_path;SQL Server 的模式在语句里显式限定
    if (kUseSchemaTypes.contains(connection.typeId)) {
      await driver.useSchema(endpoint.schema);
    }
  }
}

/// 按名字配对(忽略大小写):返回 (源名, 目标名),缺失一侧为 null。
///
/// 两侧各自按名排序后合并,输出顺序稳定,便于界面直接渲染。
List<(String?, String?)> _pairByName(List<String> src, List<String> tgt) {
  final srcByKey = <String, String>{};
  for (final n in src) {
    srcByKey.putIfAbsent(_key(n), () => n);
  }
  final tgtByKey = <String, String>{};
  for (final n in tgt) {
    tgtByKey.putIfAbsent(_key(n), () => n);
  }
  final keys = <String>{...srcByKey.keys, ...tgtByKey.keys}.toList()
    ..sort();
  return [
    for (final k in keys) (srcByKey[k], tgtByKey[k]),
  ];
}

String _key(String name) => name.trim().toLowerCase();

Future<SyncObject> _diffOne({
  required SyncObjectKind kind,
  required String typeId,
  required SyncOptions options,
  required _Side source,
  required _Side target,
  required String? sourceName,
  required String? targetName,
}) async {
  final name = sourceName ?? targetName!;
  final object = SyncObject(kind: kind, name: name);
  try {
    if (kind == SyncObjectKind.table) {
      await _diffTable(
        object: object,
        typeId: typeId,
        options: options,
        source: source,
        target: target,
        sourceName: sourceName,
        targetName: targetName,
      );
    } else {
      await _diffRoutine(
        object: object,
        kind: kind,
        typeId: typeId,
        options: options,
        source: source,
        target: target,
        sourceName: sourceName,
        targetName: targetName,
      );
    }
  } catch (e) {
    object
      ..action = SyncAction.none
      ..statements = const []
      ..blocked = true
      ..note = '读取结构失败:$e';
  }
  return object;
}

Future<void> _diffTable({
  required SyncObject object,
  required String typeId,
  required SyncOptions options,
  required _Side source,
  required _Side target,
  required String? sourceName,
  required String? targetName,
}) async {
  final srcDesign = sourceName == null
      ? null
      : await source.driver.readTableDesign(
          source.endpoint.database, sourceName,
          schema: source.endpoint.schema);
  final tgtDesign = targetName == null
      ? null
      : await target.driver.readTableDesign(
          target.endpoint.database, targetName,
          schema: target.endpoint.schema);
  final srcText = srcDesign == null ? '' : DdlBuilder.buildCreateTable(srcDesign, typeId);
  final tgtText = tgtDesign == null ? '' : DdlBuilder.buildCreateTable(tgtDesign, typeId);
  object
    ..sourceDdl = srcText
    ..targetDdl = tgtText;

  if (srcDesign == null && tgtDesign == null) {
    object
      ..blocked = true
      ..note = '两侧都读不到表结构';
    return;
  }
  // 驱动不支持结构反查(SQLite / Access 已在入口拦掉,这里兜住单表读取失败)
  if (srcDesign == null || tgtDesign == null) {
    final missing = srcDesign == null ? sourceName! : targetName!;
    final side = srcDesign == null ? '源' : '目标';
    if (srcDesign == null && tgtDesign != null) {
      // 源侧读不到:无法生成创建语句,标错但不影响其它对象
      object
        ..blocked = true
        ..note = '源库读不到表「$missing」的结构';
      return;
    }
    object
      ..action = SyncAction.drop
      ..statements = [dropObjectDdl(typeId, SyncObjectKind.table, target.endpoint.schema, missing)]
      ..note = '$side库读不到该表结构,仅生成删除语句';
    return;
  }

  if (targetName == null) {
    // 要在目标新建:实例级对象(所有者 / 表空间 / 继承 / 集群)不跨库搬运,
    // 目标端多半没有同名角色 / 表空间,带着会直接失败。
    final desired = _forTarget(srcDesign, target);
    object
      ..action = SyncAction.create
      ..statements = _applyComments(DdlBuilder.buildStatements(desired, typeId), options);
    return;
  }
  if (sourceName == null) {
    object
      ..action = SyncAction.drop
      ..statements = [
        dropObjectDdl(typeId, SyncObjectKind.table, target.endpoint.schema, targetName),
      ];
    return;
  }

  final desired = _forTarget(srcDesign, target, baseline: tgtDesign);
  final blocked = DdlBuilder.alterUnsupported(desired, tgtDesign, typeId);
  if (blocked != null) {
    object
      ..action = SyncAction.alter
      ..blocked = true
      ..note = blocked;
    return;
  }
  final stmts =
      _applyComments(DdlBuilder.buildAlterStatements(desired, tgtDesign, typeId), options);
  if (stmts.isEmpty) {
    object.action = SyncAction.none;
    return;
  }
  object
    ..action = SyncAction.alter
    ..statements = stmts;
}

Future<void> _diffRoutine({
  required SyncObject object,
  required SyncObjectKind kind,
  required String typeId,
  required SyncOptions options,
  required _Side source,
  required _Side target,
  required String? sourceName,
  required String? targetName,
}) async {
  final kind_ = kind.definitionKind!;
  final srcDef = sourceName == null
      ? null
      : await source.driver.getDefinition(
          source.endpoint.database, sourceName, kind_,
          schema: source.endpoint.schema);
  final tgtDef = targetName == null
      ? null
      : await target.driver.getDefinition(
          target.endpoint.database, targetName, kind_,
          schema: target.endpoint.schema);
  final srcText = _rewriteDefinition(srcDef, source, target, options);
  final tgtText = _rewriteDefinition(tgtDef, target, target, options);
  object
    ..sourceDdl = srcText ?? ''
    ..targetDdl = tgtText ?? '';

  if (targetName == null) {
    if (srcText == null || srcText.isEmpty) {
      object
        ..blocked = true
        ..note = '源库读不到${kind.label}「$sourceName」的定义';
      return;
    }
    object
      ..action = SyncAction.create
      ..statements = [srcText];
    return;
  }
  if (sourceName == null) {
    object
      ..action = SyncAction.drop
      ..statements = [dropObjectDdl(typeId, kind, target.endpoint.schema, targetName)];
    return;
  }
  if (srcText == null || tgtText == null || srcText.isEmpty || tgtText.isEmpty) {
    object
      ..blocked = true
      ..note = '读不到${kind.label}「$targetName」的定义,无法比较';
    return;
  }
  final same = options.ignoreDefinitionSpace
      ? _collapseSpace(srcText) == _collapseSpace(tgtText)
      : srcText == tgtText;
  if (same) {
    object.action = SyncAction.none;
    return;
  }
  // 定义差异:先 DROP 再 CREATE。PG 的 CREATE OR REPLACE 本可省掉 DROP,
  // 但改签名时旧版函数会残留,统一 DROP + CREATE 才能保证结果一致。
  object
    ..action = SyncAction.alter
    ..statements = [
      dropObjectDdl(typeId, kind, target.endpoint.schema, targetName),
      srcText,
    ];
}

/// 把源侧设计数据改写成「在目标侧落地」的形态:名字与模式跟随目标基线,
/// 实例级选项清空(跨库搬运多半无效)。
DesignTable _forTarget(DesignTable from, _Side target, {DesignTable? baseline}) {
  final d = from.snapshot()
    ..schema = baseline?.schema ?? target.endpoint.schema
    ..owner = ''
    ..tablespace = ''
    ..inherits = ''
    ..cluster = '';
  if (baseline != null) {
    // 名字必须与基线一致:否则差异生成会输出一条表重命名
    d.name = baseline.name;
    d.pkName = baseline.pkName;
  }
  return d;
}

/// 过滤独立注释语句([SyncOptions.ignoreComments])。
List<String> _applyComments(List<String> stmts, SyncOptions options) {
  if (!options.ignoreComments) return stmts;
  return stmts.where((s) {
    final t = s.trimLeft();
    if (t.startsWith('COMMENT ON')) return false;
    // MySQL / MariaDB 的表注释是独立一条 ALTER … COMMENT = …
    if (RegExp(r'^ALTER\s+TABLE\s+.*\bCOMMENT\b', caseSensitive: false).hasMatch(t) &&
        !RegExp(r'\bCOLUMN\b', caseSensitive: false).hasMatch(t)) {
      return false;
    }
    return true;
  }).toList();
}

/// 定义文本改写:去掉 DEFINER 子句、把源库前缀换成目标库(MySQL 视图 / 函数
/// 的定义文本自带 `` `库名`. `` 限定,不替换会把语句写回源库)。
String? _rewriteDefinition(
  String? raw,
  _Side from,
  _Side to,
  SyncOptions options,
) {
  if (raw == null) return null;
  var text = raw.trim();
  if (text.isEmpty) return text;
  if (options.stripDefiner) {
    text = text.replaceAllMapped(
      RegExp(
        r"DEFINER\s*=\s*(?:`[^`]*`|'[^']*'|\[[^\]]*\])@(?:`[^`]*`|'[^']*'|\[[^\]]*\])\s*",
        caseSensitive: false,
      ),
      (_) => '',
    );
  }
  final fromDb = from.endpoint.database;
  final toDb = to.endpoint.database;
  if (DdlBuilder.isMysqlLike(from.connection.typeId) &&
      fromDb.isNotEmpty &&
      fromDb != toDb) {
    text = text.replaceAll('`$fromDb`.', '`$toDb`.');
  }
  return text;
}

/// 折叠所有空白(比较定义文本用:数据库返回的换行 / 缩进差异不算差异)。
String _collapseSpace(String s) =>
    s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// 目标端删除对象的语句(带模式限定;`IF EXISTS` 让重复部署不至于失败)。
String dropObjectDdl(String typeId, SyncObjectKind kind, String? schema, String name) {
  final ident = DdlBuilder.qualified(typeId, schema, name);
  return 'DROP ${kind.dropKeyword} IF EXISTS $ident';
}
