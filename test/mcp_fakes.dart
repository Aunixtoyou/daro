/// MCP 单测共用的假驱动 / 假策略加载器(不连真库,钉死判定与池行为)。
///
/// `DatabaseDriver` 接口很宽,用 `noSuchMethod` 兜住不关心的方法;
/// 关心的行为(握手计数、可挂死的执行、可断的连接)全部显式覆写,
/// 让测试读起来就是契约本身。
import 'dart:async';

import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:daro/data/table_design.dart';
import 'package:daro/mcp/mcp_policy.dart';

class FakeDriver implements DatabaseDriver {
  FakeDriver(this.label);

  final String label;

  int connectCount = 0;
  int closeCount = 0;
  bool throwOnConnect = false;
  bool _connected = false;

  /// executeQuery 的可控延迟(模拟慢查询以触发 MCP 侧超时)。
  Duration executeDelay = Duration.zero;
  List<String> executedSql = [];
  int? lastLimit;
  int? lastOffset;
  int? sessionId = null;
  int killCount = 0;

  /// 元数据工具的返回值(按需覆写;默认给一组够用的假数据)
  List<String> tables = ['users', 'orders'];
  List<String> views = ['v_users'];
  List<String> schemas = const [];
  Map<String, String> tableComments = {'users': '用户表'};
  Map<String, int> rowEstimates = {'users': 120};
  List<String> functions = ['fn_new_id'];
  List<String> procedures = ['pr_sync'];
  List<ColumnDef> columns = const [
    ColumnDef(name: 'id', type: 'int', nullable: false, primaryKey: true),
    ColumnDef(name: 'name', type: 'varchar(255)', comment: '姓名'),
  ];
  TablePreview preview = const TablePreview(
    columns: ['id', 'name'],
    rows: [
      ['1', 'NULL'],
      ['2', 'bob'],
    ],
    limit: 2,
    nullMask: [
      [false, true],
      [false, false],
    ],
  );
  int? tableCount;
  String? definition = 'CREATE VIEW v_users AS SELECT * FROM users';

  /// 引擎侧报错(语法错 / 对象不存在):与基础设施错误分诊的关键一条路径。
  String? throwOnExecute;

  /// 报错的同时把连接弄断(模拟服务端会话被杀)—— 池必须销毁该实例。
  bool breaksConnectionOnExecute = false;

  /// killSession 本身报错(权限不足 / 会话已结束)。
  String? throwOnKill;

  /// readTableDesign 返回 null 时驱动真实行为是抛异常;这里用 null 走「降级」分支。
  DesignTable? design;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    if (throwOnConnect) throw StateError('$label: 模拟握手失败');
    connectCount++;
    _connected = true;
  }

  @override
  Future<void> close() async {
    closeCount++;
    _connected = false;
  }

  @override
  Future<QueryResult> executeQuery(String sql,
      {int limit = 1000, int offset = 0}) async {
    lastLimit = limit;
    lastOffset = offset;
    if (executeDelay > Duration.zero) {
      await Future.delayed(executeDelay);
    }
    executedSql.add(sql);
    final err = throwOnExecute;
    if (err != null) {
      if (breaksConnectionOnExecute) _connected = false;
      throw Exception(err);
    }
    // 写语句回 affectedRows(与真驱动一致:结果集为空),SELECT 回列 + 行。
    // 判别只看开头词,足够把工具层的两条 payload 分支都跑到。
    final head = RegExp(r'^\s*([A-Za-z]+)').firstMatch(sql)?.group(1)?.toUpperCase();
    if (head == 'INSERT' || head == 'UPDATE' || head == 'DELETE') {
      return QueryResult(
        columns: const [],
        rows: const [],
        affectedRows: 7,
        limit: limit,
        offset: offset,
      );
    }
    return QueryResult(
      columns: const ['ok'],
      rows: [
        [label],
      ],
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<int?> serverSessionId() async => sessionId;

  @override
  Future<void> killSession(int sessionId) async {
    killCount++;
    final err = throwOnKill;
    if (err != null) throw Exception(err);
  }

  @override
  Future<List<String>> listDatabases() async => const ['db_a', 'db_b', 'secret'];

  @override
  Future<List<String>> listSchemas(String database) async => schemas;

  @override
  Future<List<String>> listTables(String database, {String? schema}) async => tables;

  @override
  Future<List<String>> listViews(String database, {String? schema}) async => views;

  @override
  Future<Map<String, String>> listTableComments(String database,
          {String? schema}) async =>
      tableComments;

  @override
  Future<Map<String, int>> listTableRowEstimates(String database,
          {String? schema}) async =>
      rowEstimates;

  @override
  Future<List<String>> listFunctions(String database, {String? schema}) async =>
      functions;

  @override
  Future<List<String>> listProcedures(String database, {String? schema}) async =>
      procedures;

  @override
  Future<List<ColumnDef>> describeTable(String database, String table,
          {String? schema}) async =>
      columns;

  @override
  Future<DesignTable?> readTableDesign(String database, String table,
      {String? schema}) async {
    final d = design;
    if (d == null) throw UnsupportedError('$label: 该引擎不支持结构反查');
    return d;
  }

  @override
  Future<TablePreview> previewTable(String database, String table,
      {int limit = 100,
      int offset = 0,
      String? schema,
      String? where,
      String? orderBy}) async {
    lastLimit = limit;
    lastOffset = offset;
    return preview;
  }

  @override
  Future<int> countTable(String database, String table,
          {String? schema, String? where}) async =>
      tableCount ?? 12345;

  @override
  Future<String?> getDefinition(String database, String name, String kind,
          {String? schema}) async =>
      definition;

  @override
  Future<void> useDatabase(String database) async {
    usedDatabases.add(database);
  }

  @override
  Future<void> useSchema(String? schema) async {
    usedSchemas.add(schema);
  }

  final List<String> usedDatabases = [];
  final List<String?> usedSchemas = [];

  @override
  dynamic noSuchMethod(Invocation invocation) => switch (invocation.memberName) {
        #isConnected => _connected,
        _ => throw UnsupportedError(
            'FakeDriver($label) 未实现 ${invocation.memberName}'),
      };
}

/// 连接工厂替身:记录每个连接名被建了几次实例(= 握手次数的上限)。
class DriverFactorySpy {
  final created = <String, List<FakeDriver>>{};
  final Map<String, FakeDriver Function(String name)> overrides = {};

  /// 每个新建实例出厂后跑一遍(预设元数据 / 行为),对 overrides 造的实例同样生效。
  void Function(FakeDriver driver)? tune;

  FakeDriver? call(ConnectionInfo conn) {
    final name = conn.name;
    final make = overrides[name] ?? (n) => FakeDriver(n);
    final driver = make(name);
    tune?.call(driver);
    (created[name] ??= []).add(driver);
    return driver;
  }

  int connectCountOf(String name) =>
      created[name]?.fold<int>(0, (sum, d) => sum + d.connectCount) ?? 0;

  int instancesOf(String name) => created[name]?.length ?? 0;

  /// 该连接名被创建过的全部实例(最新一个即当前池里那条)。
  List<FakeDriver> listOf(String name) => created[name] ?? const [];

  List<FakeDriver> get allDrivers => [
        for (final list in created.values) ...list,
      ];
}

McpPolicy enabledPolicy({
  bool enabled = true,
  McpMode defaultMode = McpMode.readonly,
  bool scopeAll = true,
  List<String> names = const [],
  List<McpConnectionRule> rules = const [],
  List<String> tools = const [],
  int maxRows = 100,
  int hardRowCap = 1000,
  McpTimeouts timeouts = const McpTimeouts(),
  int poolMaxDrivers = 8,
  int poolIdleTtlSecs = 600,
  McpPasswordPrompt passwordPrompt = McpPasswordPrompt.deny,
}) =>
    McpPolicy(
      enabled: enabled,
      defaultMode: defaultMode,
      connectionScopeAll: scopeAll,
      connectionNames: names,
      connections: rules,
      tools: tools,
      maxRows: maxRows,
      hardRowCap: hardRowCap,
      timeouts: timeouts,
      poolMaxDrivers: poolMaxDrivers,
      poolIdleTtlSecs: poolIdleTtlSecs,
      passwordPrompt: passwordPrompt,
    );

/// 一条「已保存密码」的真实连接(工具层单测的默认输入)。
ConnectionInfo fakeConn(
  String name, {
  String typeId = 'mysql',
  String password = 'pw-saved',
  String database = '',
  String authMethod = '',
}) =>
    ConnectionInfo(
      name: name,
      typeId: typeId,
      host: '127.0.0.1',
      port: '3306',
      username: 'root',
      password: password,
      database: database,
      authMethod: authMethod,
      isLive: true,
    );
