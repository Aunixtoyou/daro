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
  procedure('过程', 'PROCEDURE'),
  sequence('序列', 'SEQUENCE');

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
            SyncObjectKind.sequence =>
              (d, db, {schema}) => d.listSequences(db, schema: schema),
          };

  /// [DatabaseDriver.getDefinition] 的 kind 参数(表无定义文本)。
  ///
  /// 序列虽有 'sequence' 这个 kind,但走的是 [DatabaseDriver.readSequence]
  /// (要额外读最后值),比对入口在 `_diffSequence`,不经 `_diffRoutine`。
  String? get definitionKind => switch (this) {
        SyncObjectKind.view => 'view',
        SyncObjectKind.function => 'function',
        SyncObjectKind.procedure => 'procedure',
        SyncObjectKind.sequence => 'sequence',
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

/// 结构同步的比对选项 —— 口径对齐参考工具的「比较选项」弹窗。
///
/// 界面映射:缩进在「比较表」之下的五项是表的**子块**;索引 / 触发器 / 规则 /
/// 所有者 / 用级联删除在弹窗里是平铺项,但在 daro 的数据模型里同样属于表
/// ([DesignTable] 的 `indexes` / `triggers` / `rules` / `owner`),实现上也是
/// 裁表的子块。序列是独立对象类别。
class SyncOptions {
  // ── 参与比对的对象类别(平铺项) ──
  bool tables = true;
  bool views = true;

  /// 函数。**同时涵盖存储过程**:参考工具的「比较选项」里没有单独的过程项,
  /// 而 daro 数据层支持过程 —— 拆成两项会凭空多一个菜单里没有的开关,
  /// 直接丢掉又白丢一项能力,故合并(与改前的默认行为一致)。
  bool functions = true;
  bool sequences = true;

  /// 表的子块之一:索引(同样只作用于表,平铺显示只是为了对齐参考工具的版式)
  bool indexes = true;

  /// 表的子块之一:触发器(PostgreSQL:表上 / 视图上的规则与触发器)
  bool triggers = true;

  /// 表的子块之一:规则(仅 PostgreSQL)
  bool rules = true;

  /// 表的子块之一:所有者。勾选时把源侧所有者**搬到目标**并生成
  /// `ALTER … OWNER TO`;取消勾选则完全不看所有者(改前的既有行为:所有者属
  /// 实例级设置,跨库搬运可能因目标端没有同名角色而失败,故可关掉)。
  bool owners = true;

  // ── 「比较表」的子项(弹窗里缩进显示) ──
  bool primaryKeys = true;
  bool foreignKeys = true;
  bool uniqueKeys = true;
  bool checks = true;
  bool excludes = true;

  // ── 弹窗底部的两项 ──
  /// 用级联删除:删对象时带 `CASCADE`(PostgreSQL 家族),连带删掉依赖它的对象。
  /// 默认关 —— 误删的代价太大,要开得用户自己勾。
  bool cascadeDrop = false;

  /// 比较序列最后值:除了参数,还把两侧序列的**分发位置**对齐
  /// (差异生成 `ALTER SEQUENCE … RESTART WITH`)。参考工具里默认勾选。
  bool sequenceLastValue = true;

  /// 该对象类别是否参与比对
  bool enabledOf(SyncObjectKind kind) => switch (kind) {
        SyncObjectKind.table => tables,
        SyncObjectKind.view => views,
        SyncObjectKind.function || SyncObjectKind.procedure => functions,
        SyncObjectKind.sequence => sequences,
      };

  /// 拷贝(弹窗回写用)
  SyncOptions copy() => SyncOptions()
    ..tables = tables
    ..views = views
    ..functions = functions
    ..sequences = sequences
    ..indexes = indexes
    ..triggers = triggers
    ..rules = rules
    ..owners = owners
    ..primaryKeys = primaryKeys
    ..foreignKeys = foreignKeys
    ..uniqueKeys = uniqueKeys
    ..checks = checks
    ..excludes = excludes
    ..cascadeDrop = cascadeDrop
    ..sequenceLastValue = sequenceLastValue;

  /// 「保存配置文件」写出的比对选项字段
  Map<String, dynamic> toJson() => {
        'tables': tables,
        'views': views,
        'functions': functions,
        'sequences': sequences,
        'indexes': indexes,
        'triggers': triggers,
        'rules': rules,
        'owners': owners,
        'primaryKeys': primaryKeys,
        'foreignKeys': foreignKeys,
        'uniqueKeys': uniqueKeys,
        'checks': checks,
        'excludes': excludes,
        'cascadeDrop': cascadeDrop,
        'sequenceLastValue': sequenceLastValue,
      };

  /// 「加载配置文件」回填比对选项。
  ///
  /// [json] 里**缺失或类型不对**的键一律保留当前值 —— 老版本配置文件里没有
  /// 新增的开关(如 sequences / primaryKeys),不能因为缺键就把它们清成 false。
  void loadJson(Map<String, dynamic> json) {
    bool flag(String key, bool current) {
      final v = json[key];
      return v is bool ? v : current;
    }

    tables = flag('tables', tables);
    views = flag('views', views);
    functions = flag('functions', functions);
    sequences = flag('sequences', sequences);
    indexes = flag('indexes', indexes);
    triggers = flag('triggers', triggers);
    rules = flag('rules', rules);
    owners = flag('owners', owners);
    primaryKeys = flag('primaryKeys', primaryKeys);
    foreignKeys = flag('foreignKeys', foreignKeys);
    uniqueKeys = flag('uniqueKeys', uniqueKeys);
    checks = flag('checks', checks);
    excludes = flag('excludes', excludes);
    cascadeDrop = flag('cascadeDrop', cascadeDrop);
    sequenceLastValue = flag('sequenceLastValue', sequenceLastValue);
  }
}

/// 结构同步的**部署**选项 —— 口径对齐参考工具的「部署选项」弹窗。
///
/// 与 [SyncOptions] 的区别:比对选项决定「哪些算差异」,部署选项只决定
/// 「差异怎么执行」(失败怎么办、日志写多细),不参与比对结果。
/// 两项在参考工具里都是**默认不勾**。
class SyncDeployOptions {
  /// 遇到错误时继续。
  ///
  /// 默认 false = 首个对象失败即中止,剩余对象以「未执行(前序失败)」记错
  /// (与参考工具一致);勾上则跑完全部对象,最后统一汇总失败明细。
  bool continueOnError = false;

  /// 在消息日志中包含部署查询。
  ///
  /// 默认 false = 日志只留「[n/N] 动作 对象」与「Result:」两行;勾上则每个
  /// 对象前额外展开它要执行的 SQL(排查问题时用)。
  bool logQueries = false;

  /// 拷贝(弹窗回写用;取消时丢弃副本,不动当前值)
  SyncDeployOptions copy() => SyncDeployOptions()
    ..continueOnError = continueOnError
    ..logQueries = logQueries;

  /// 「保存配置文件」写出的部署选项字段
  Map<String, dynamic> toJson() => {
        'continueOnError': continueOnError,
        'logQueries': logQueries,
      };

  /// 「加载配置文件」回填部署选项;缺键 / 类型不对保留当前值
  /// (老配置文件里没有这一块,不能因缺键就把开关清成 false)。
  void loadJson(Map<String, dynamic> json) {
    bool flag(String key, bool current) {
      final v = json[key];
      return v is bool ? v : current;
    }

    continueOnError = flag('continueOnError', continueOnError);
    logQueries = flag('logQueries', logQueries);
  }
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

  /// 该对象在 DDL 里引用到的**其它表名**(外键的目标表,已小写去空格)。
  ///
  /// 比对结束后据此对表对象做拓扑排序(见 [_orderTablesByDependency]):
  /// 部署是逐对象顺序执行的,被引用的表排在后面就会失败,而失败原因看起来
  /// 又像「表不存在」——实际是执行顺序问题。
  final Set<String> dependsOn = {};

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
  SyncPlan({
    this.objects = const [],
    this.errors = const [],
    this.canceled = false,
  });

  /// 全部对象(含无操作)
  final List<SyncObject> objects;

  /// 整体级错误(某类对象列表拉取失败等);非空时结果不完整,界面必须显示
  final List<String> errors;

  /// 用户中途取消:objects 为半成品,界面应丢弃本次结果保留旧计划
  final bool canceled;

  Iterable<SyncObject> ofAction(SyncAction action) =>
      objects.where((o) => o.action == action);

  int countOf(SyncAction action) => ofAction(action).length;

  /// 已勾选且可部署的对象(按 [_deployOrder] 排过依赖顺序)
  List<SyncObject> get selected => _deployOrder(
      objects.where((o) => o.selected && o.deployable).toList());

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
/// [isCancelled] 每处理一个对象前查询一次;返回 true 时立即停止,
/// 产出的 [SyncPlan.canceled] 为 true(半成品结果,界面应丢弃)。
Future<SyncPlan> compareSchemaSync({
  required SyncEndpoint source,
  required SyncEndpoint target,
  SyncOptions? options,
  SyncDriverFactory? driverFactory,
  void Function(String stage, int done, int total)? onProgress,
  bool Function()? isCancelled,
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
      if (isCancelled?.call() == true) {
        return SyncPlan(objects: objects, errors: errors, canceled: true);
      }
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
        if (isCancelled?.call() == true) {
          return SyncPlan(objects: objects, errors: errors, canceled: true);
        }
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
/// 默认任一对象失败不影响后续对象,[DeployItem.error] 记录原因;
/// [stopOnError] 为 true 时首个失败即中止(剩余对象以「未执行(前序失败)」记错)。
Future<DeployReport> deploySchemaSync({
  required SyncEndpoint target,
  required List<SyncObject> selected,
  SyncDriverFactory? driverFactory,
  void Function(DeployItem item)? onItemDone,
  bool stopOnError = false,
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
      if (stopOnError && !item.ok) {
        for (final rest in selected.skip(selected.indexOf(obj) + 1)) {
          final skipped =
              DeployItem(rest, error: '未执行(前序对象失败,已停止)');
          items.add(skipped);
          onItemDone?.call(skipped);
        }
        break;
      }
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

/// 部署顺序:先建 / 先改被引用的表,再轮到引用方;删表放到最后,且先删引用方。
///
/// 部署是「一个对象一条事务、按列表顺序执行」,而比对结果按**名字**排序,于是
/// `CREATE TABLE cameras (... REFERENCES parking_gates)` 会排在 `parking_gates`
/// 前面(目标库还没有它 → 42P01 relation does not exist);另一类是引用列的
/// 主键由后面的对象才补上(42830 no unique constraint matching given keys)。
/// 两类都不是数据问题,纯粹是顺序问题。
List<SyncObject> _deployOrder(List<SyncObject> list) {
  final others = [for (final o in list) if (o.kind != SyncObjectKind.table) o];
  final tables = list.where((o) => o.kind == SyncObjectKind.table).toList();
  return [
    ..._topo(tables.where((o) => o.action != SyncAction.drop).toList(),
        referencedFirst: true),
    ...others,
    // 删表放在最后:目标库里其它对象可能还引用它;若同时删多张互为外键的表,
    // 引用方必须先删,否则同样撞外键约束。
    ..._topo(tables.where((o) => o.action == SyncAction.drop).toList(),
        referencedFirst: false),
  ];
}

/// Kahn 拓扑排序:[referencedFirst] 为真时「被引用者在前」(建 / 改),
/// 为假时「引用者在前」(删)。名字序作稳定基准,循环外键无法靠排序满足,
/// 剩余对象退回原序收尾(交给数据库自己判错,总比整体卡住或丢对象好)。
List<SyncObject> _topo(List<SyncObject> list, {required bool referencedFirst}) {
  if (list.length < 2) return list;
  final names = {for (final o in list) _key(o.name)};
  final out = <SyncObject>[];
  final placed = <String>{};
  final pending = list.toList();
  bool ready(SyncObject o) {
    final self = _key(o.name);
    return referencedFirst
        // 依赖不在本列表里(目标库早已存在那张表)= 不需要等它
        ? o.dependsOn
            .every((d) => !names.contains(d) || d == self || placed.contains(d))
        // 反向:还有引用本表的对象没出局,本表就还不能删
        : list.every((r) =>
            identical(r, o) ||
            !r.dependsOn.contains(self) ||
            placed.contains(_key(r.name)));
  }

  while (pending.isNotEmpty) {
    final i = pending.indexWhere(ready);
    if (i < 0) {
      // 循环外键:排序无解,剩余按名字序收尾
      out.addAll(pending);
      break;
    }
    final o = pending.removeAt(i);
    out.add(o);
    placed.add(_key(o.name));
  }
  return out;
}

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
    } else if (kind == SyncObjectKind.sequence) {
      await _diffSequence(
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
  // 外键指向的表 = 部署时的依赖(见 [_topo])。删表时源侧没有该表,
  // 依赖关系只能从目标侧结构读出来;自引用由 [_topo] 按名字排除。
  for (final fk in (srcDesign ?? tgtDesign)?.foreignKeys ?? const <DesignForeignKey>[]) {
    final ref = fk.refTable.trim();
    if (ref.isNotEmpty) object.dependsOn.add(_key(ref));
  }

  // 比对用的副本:按「选项」把不参与比对的子块(主键 / 外键 / 唯一键 / 检查 /
  // 排除 / 索引 / 触发器 / 规则 / 所有者)从**两侧同时**裁掉,否则同一处差异只
  // 裁一侧会凭空多出一条。展示用的 DDL 仍是完整定义(上面的 srcText / tgtText)。
  final srcCmp = srcDesign == null ? null : _stripByOptions(srcDesign, options);
  final tgtCmp = tgtDesign == null ? null : _stripByOptions(tgtDesign, options);

  if (srcDesign == null && tgtDesign == null) {
    object
      ..blocked = true
      ..note = '两侧都读不到表结构';
    return;
  }
  // **先按名字定缺失一侧**,再判反查失败:目标没有该表时 tgtDesign 必然为
  // null(根本没去读),若先落进下面的反查分支就会去解引用 targetName! 而抛
  // Null check → 被 _diffOne 兜成 blocked + 无操作,表现为「空库比对不出新建」。
  if (targetName == null) {
    if (srcDesign == null) {
      // 源侧读不到:无法生成创建语句,标错但不影响其它对象
      object
        ..blocked = true
        ..note = '源库读不到表「$sourceName」的结构';
      return;
    }
    // 要在目标新建:按**源的完整定义**建(子块开关只决定「什么算差异」,
    // 不决定「新建的对象长什么样」——否则取消勾选「比较主键」会建出没有主键的表);
    // 实例级选项(所有者 / 表空间 / 继承 / 集群)是否跨库搬运由选项决定,
    // 表空间 / 继承 / 集群一律清空(目标端多半没有同名表空间)。
    final desired = _forTarget(srcDesign, target, options: options);
    object
      ..action = SyncAction.create
      ..statements = DdlBuilder.buildStatements(desired, typeId);
    return;
  }
  if (sourceName == null) {
    object
      ..action = SyncAction.drop
      ..statements = [
        dropObjectDdl(typeId, SyncObjectKind.table, target.endpoint.schema, targetName,
            cascade: options.cascadeDrop),
      ];
    return;
  }
  // 两侧都列出了该表却有一侧反查不出结构(驱动不支持 / 单表读取失败):
  // 无法比对,标错交人工处理——此时生成 DROP 会把读不到当成要删掉。
  if (srcDesign == null || tgtDesign == null) {
    final missing = srcDesign == null ? sourceName : targetName;
    final side = srcDesign == null ? '源' : '目标';
    object
      ..blocked = true
      ..note = '$side库读不到表「$missing」的结构';
    return;
  }

  // 差异只在**裁过的副本**上算:未勾选的子块(如索引)差异不算差异
  final desired = _forTarget(srcCmp!, target, baseline: tgtCmp, options: options);
  final blocked = DdlBuilder.alterUnsupported(desired, tgtCmp!, typeId);
  if (blocked != null) {
    object
      ..action = SyncAction.alter
      ..blocked = true
      ..note = blocked;
    return;
  }
  final stmts = DdlBuilder.buildAlterStatements(desired, tgtCmp, typeId);
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
  final srcText = _rewriteDefinition(srcDef, source, target);
  final tgtText = _rewriteDefinition(tgtDef, target, target);
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
      ..statements = [
        dropObjectDdl(typeId, kind, target.endpoint.schema, targetName,
            cascade: options.cascadeDrop),
      ];
    return;
  }
  if (srcText == null || tgtText == null || srcText.isEmpty || tgtText.isEmpty) {
    object
      ..blocked = true
      ..note = '读不到${kind.label}「$targetName」的定义,无法比较';
    return;
  }
  // 折叠空白后比对:数据库返回的定义常差一个换行 / 缩进,那不是结构差异。
  if (_collapseSpace(srcText) == _collapseSpace(tgtText)) {
    object.action = SyncAction.none;
    return;
  }
  // 定义差异:先 DROP 再 CREATE。PG 的 CREATE OR REPLACE 本可省掉 DROP,
  // 但改签名时旧版函数会残留,统一 DROP + CREATE 才能保证结果一致。
  object
    ..action = SyncAction.alter
    ..statements = [
      dropObjectDdl(typeId, kind, target.endpoint.schema, targetName,
          cascade: options.cascadeDrop),
      srcText,
    ];
}

/// 序列比对。
///
/// 序列的参数没有「定义文本」可取,由驱动把系统目录里的参数重建成一条
/// `CREATE SEQUENCE`([SequenceDef]);参数不等就是「要修改」,做法是重建。
/// 另外「比较序列最后值」勾选时,把两个序列的**分发位置**也对齐 ——
/// 位置差异只生成 `ALTER SEQUENCE … RESTART WITH`,不动参数。
Future<void> _diffSequence({
  required SyncObject object,
  required String typeId,
  required SyncOptions options,
  required _Side source,
  required _Side target,
  required String? sourceName,
  required String? targetName,
}) async {
  final srcDef = sourceName == null
      ? null
      : await source.driver.readSequence(
          source.endpoint.database, sourceName,
          schema: source.endpoint.schema);
  final tgtDef = targetName == null
      ? null
      : await target.driver.readSequence(
          target.endpoint.database, targetName,
          schema: target.endpoint.schema);
  object
    ..sourceDdl = srcDef?.createSql ?? ''
    ..targetDdl = tgtDef?.createSql ?? '';

  if (targetName == null) {
    if (srcDef == null) {
      object
        ..blocked = true
        ..note = '源库读不到序列「$sourceName」的定义';
      return;
    }
    object
      ..action = SyncAction.create
      ..statements = [
        srcDef.createSql,
        // 新建出来的序列停在起始值上;源序列若已用过,顺带把位置对齐
        if (options.sequenceLastValue && srcDef.nextValue != null)
          _restartDdl(typeId, target.endpoint.schema, sourceName!, srcDef.nextValue!),
      ];
    return;
  }
  if (sourceName == null) {
    object
      ..action = SyncAction.drop
      ..statements = [
        dropObjectDdl(typeId, SyncObjectKind.sequence, target.endpoint.schema,
            targetName,
            cascade: options.cascadeDrop),
      ];
    return;
  }
  if (srcDef == null || tgtDef == null) {
    object
      ..blocked = true
      ..note = '读不到序列「$targetName」的定义,无法比较';
    return;
  }

  final paramsSame =
      _collapseSpace(srcDef.createSql) == _collapseSpace(tgtDef.createSql);
  final srcNext = srcDef.nextValue;
  final tgtNext = tgtDef.nextValue;
  // 最后值只在「勾选了比较序列最后值」且**两侧都读得到**时才算差异:
  // 未取过值的一侧 nextValue 为 null(没有位置可比),拿它去比会凭空造出差异。
  final lastSame = !options.sequenceLastValue ||
      srcNext == null ||
      tgtNext == null ||
      srcNext == tgtNext;
  if (paramsSame && lastSame) {
    object.action = SyncAction.none;
    return;
  }

  object..action = SyncAction.alter;
  if (!paramsSame) {
    // 参数变了:重建(序列没有「一次改完所有参数」的稳妥 ALTER;重建后位置
    // 会回到起始值,故勾了「比较序列最后值」时要补一条 RESTART)
    object.statements = [
      dropObjectDdl(typeId, SyncObjectKind.sequence, target.endpoint.schema,
          targetName,
          cascade: options.cascadeDrop),
      srcDef.createSql,
      if (options.sequenceLastValue && srcNext != null)
        _restartDdl(typeId, target.endpoint.schema, targetName, srcNext),
    ];
    return;
  }
  // 只有位置不同:直接 RESTART,不动参数(重建会把使用中的序列打断)
  object.statements = [
    _restartDdl(typeId, target.endpoint.schema, targetName, srcNext!),
  ];
}

/// `ALTER SEQUENCE … RESTART WITH n`:把序列的**下一次分发值**设为 n。
///
/// 注意这里传的是源序列的「最后值 + 增量」(见 [SequenceDef.nextValue]),不是
/// 最后值本身 —— 后者会把目标的下一个值设成源已经发过的那个,直接撞号。
String _restartDdl(String typeId, String? schema, String name, String nextValue) {
  final ident = DdlBuilder.qualified(typeId, schema, name);
  return 'ALTER SEQUENCE $ident RESTART WITH $nextValue';
}

/// 把源侧设计数据改写成「在目标侧落地」的形态:名字与模式跟随目标基线。
///
/// 所有者:**勾选了「比较所有者」才跨库搬运**(差异由此生成 `ALTER … OWNER TO`),
/// 否则清空 —— 目标端多半没有同名角色,带着会直接失败。表空间 / 继承 / 集群
/// 一律清空(同因,且参考工具的「比较选项」里没有对应开关)。
DesignTable _forTarget(
  DesignTable from,
  _Side target, {
  DesignTable? baseline,
  SyncOptions? options,
}) {
  final d = from.snapshot()
    ..schema = baseline?.schema ?? target.endpoint.schema
    ..tablespace = ''
    ..inherits = ''
    ..cluster = '';
  if (options?.owners != true) d.owner = '';
  if (baseline != null) {
    // 名字必须与基线一致:否则差异生成会输出一条表重命名
    d.name = baseline.name;
    d.pkName = baseline.pkName;
  }
  return d;
}

/// 按「选项」裁掉**不参与比对**的表子块,返回副本(不改原对象)。
///
/// 只在比对与差异生成前用:`desired` 与 `tgtDesign` 必须同时裁,否则同一处
/// 差异只裁一侧会凭空多出一条(例如取消了「比较索引」,却仍拿源侧索引去比
/// 目标侧已裁空的索引列表)。
DesignTable _stripByOptions(DesignTable d, SyncOptions o) {
  final s = d.snapshot();
  if (!o.primaryKeys) {
    for (final c in s.columns) {
      c.primaryKey = false;
    }
    s.pkName = '';
  }
  if (!o.foreignKeys) s.foreignKeys.clear();
  if (!o.uniqueKeys) s.uniqueKeys.clear();
  if (!o.checks) s.checks.clear();
  if (!o.excludes) s.excludes.clear();
  if (!o.indexes) s.indexes.clear();
  if (!o.triggers) s.triggers.clear();
  if (!o.rules) s.rules.clear();
  if (!o.owners) s.owner = '';
  return s;
}

/// 定义文本改写:去掉 DEFINER 子句、把源库前缀换成目标库(MySQL 视图 / 函数
/// 的定义文本自带 `` `库名`. `` 限定,不替换会把语句写回源库)。
///
/// 去 DEFINER 是**无条件**的:改前它是默认勾选的选项「去掉 MySQL 定义中的
/// DEFINER 子句」,参考工具的「比较选项」里没有这一项,而目标端没有该账号时
/// CREATE 必然失败,故固定执行。
String? _rewriteDefinition(
  String? raw,
  _Side from,
  _Side to,
) {
  if (raw == null) return null;
  var text = raw.trim();
  if (text.isEmpty) return text;
  text = text.replaceAllMapped(
    RegExp(
      r"DEFINER\s*=\s*(?:`[^`]*`|'[^']*'|\[[^\]]*\])@(?:`[^`]*`|'[^']*'|\[[^\]]*\])\s*",
      caseSensitive: false,
    ),
    (_) => '',
  );
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
/// 改前是默认勾选的选项「定义比较忽略空白差异」,现固定执行(参考工具无此项)。
String _collapseSpace(String s) =>
    s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// 目标端删除对象的语句(带模式限定;`IF EXISTS` 让重复部署不至于失败)。
///
/// [cascade] 为真时补 `CASCADE`,连带删掉依赖该对象的对象 —— 对应「选项」里的
/// 「用级联删除」。**只有 PostgreSQL 家族支持**,其余类型忽略该参数
/// (MySQL 的 `DROP TABLE` 语法上收 `CASCADE` 却只当 `RESTRICT` 用,写了反而误导)。
String dropObjectDdl(
  String typeId,
  SyncObjectKind kind,
  String? schema,
  String name, {
  bool cascade = false,
}) {
  final ident = DdlBuilder.qualified(typeId, schema, name);
  final suffix = cascade && DdlBuilder.isPgLike(typeId) ? ' CASCADE' : '';
  return 'DROP ${kind.dropKeyword} IF EXISTS $ident$suffix';
}
