import 'package:flutter/foundation.dart';

import '../data/db_data.dart';
import '../data/drivers/db_driver.dart';
import '../data/table_design.dart';
import 'app_state.dart';

/// 元数据加载状态
enum LoadStatus { idle, loading, loaded, error }

/// 一个连接下「数据库列表」的加载状态
class DatabaseListState {
  DatabaseListState({this.status = LoadStatus.idle, this.databases = const [], this.error});
  LoadStatus status;
  List<String> databases;
  String? error;
}

/// 一个库下「模式列表」的加载状态。
/// 仅 PostgreSQL 等有模式层的类型返回非空列表(树据此渲染模式层级),
/// 其它类型 listSchemas 返回空列表,列表字段恒为空。
class SchemaListState {
  SchemaListState({this.status = LoadStatus.idle, this.schemas = const [], this.error});
  LoadStatus status;
  List<String> schemas;
  String? error;
}

/// 一个库下「对象列表」的加载状态(表 / 视图 / 函数一次拉齐)。
/// 列表字段可空:热重载不会为旧实例跑新字段初始化器,读取处需空安全兑底
/// (详见 database_tree 的 _itemsOf / object_panel 的 items)
class TableListState {
  TableListState({
    this.status = LoadStatus.idle,
    this.tables = const [],
    this.views = const [],
    this.materializedViews = const [],
    this.functions = const [],
    this.procedures = const [],
    this.users = const [],
    this.categoryErrors,
    this.error,
  });
  LoadStatus status;
  List<String>? tables;
  List<String>? views;
  List<String>? materializedViews;
  List<String>? functions;
  List<String>? procedures;
  List<String>? users;

  /// 整体加载失败(会话无法定位 / 表列表都拉不到)时的错误;
  /// 为 null 表示库可正常打开
  String? error;

  /// 分类级降级:某一类对象列表单独读取失败时记录的原因(键 = 分类)。
  /// 典型场景是「角色」——MySQL 读 mysql.user、PG 读 pg_roles,生产只读账号
  /// 普遍无该权限(1142 SELECT command denied),但表 / 视图完全可用。
  /// 可空字段:热重载后旧实例上为 null,读取处一律用 `?[category]` 兑底。
  Map<ObjectCategory, String>? categoryErrors;

  /// 取某分类的降级错误(无错误返回 null)
  String? categoryErrorOf(ObjectCategory category) => categoryErrors?[category];
}

/// 连接管理器:维护每个连接的驱动实例与元数据加载状态。
///
/// - 连接树展开连接节点 → [expandConnection] 拉取库列表
/// - 展开库节点 → [expandDatabase] 拉取表列表(先把会话切到该库)
/// - 双击表 → [previewTable] 查询前 N 行(先把会话切到该库)
/// 状态变化通过 [notifyListeners] 通知,树与数据页各自订阅重建。
class ConnectionManager extends ChangeNotifier {
  /// 连接名 → 活跃驱动(长连接)
  final _drivers = <String, DatabaseDriver>{};

  /// 连接名 → 库列表加载状态
  final _databaseStates = <String, DatabaseListState>{};

  /// "连接名|数据库" → 模式列表加载状态
  final _schemaStates = <String, SchemaListState>{};

  /// "连接名|数据库" 或 "连接名|数据库|模式" → 表列表加载状态
  final _tableStates = <String, TableListState>{};

  DatabaseListState databaseStateOf(String connection) =>
      _databaseStates[connection] ??= DatabaseListState();

  /// 连接是否保持活跃(已建立驱动且未断开);树右键「关闭连接」的可用性判断
  bool isConnected(String connection) =>
      _drivers[connection]?.isConnected ?? false;

  SchemaListState schemaStateOf(String connection, String database) =>
      _schemaStates['$connection|$database'] ??= SchemaListState();

  /// [schema] 为空时取库级(默认模式)状态;非空时取该模式的独立状态
  TableListState tableStateOf(String connection, String database,
          {String? schema}) =>
      schema == null
          ? _tableStates['$connection|$database'] ??= TableListState()
          : _tableStates['$connection|$database|$schema'] ??= TableListState();

  /// 取(或建立)连接的活跃驱动
  Future<DatabaseDriver> _driverFor(ConnectionInfo conn) async {
    final driver = _drivers[conn.name];
    if (driver != null && driver.isConnected) return driver;
    await driver?.close();
    final fresh = createDriver(conn);
    if (fresh == null) {
      throw UnsupportedError('暂不支持 ${conn.typeId} 类型的连接');
    }
    await fresh.connect();
    _drivers[conn.name] = fresh;
    return fresh;
  }

  /// 测试注入:预先挂一个「已连接」的驱动,使 [_driverFor] 直接复用,
  /// 从而在无真实数据库的情况下验证元数据加载 / 降级逻辑(仅单测使用)。
  @visibleForTesting
  void attachDriverForTest(String connection, DatabaseDriver driver) {
    _drivers[connection] = driver;
  }

  /// 连接向导「测试连接」:连上即断,不保留长连接
  Future<(bool, String)> testConnection(ConnectionInfo conn) async {
    final driver = createDriver(conn);
    if (driver == null) {
      return (false, '暂不支持 ${conn.typeId} 类型的连接');
    }
    try {
      await driver.connect();
      return (true, '连接成功');
    } catch (e) {
      return (false, '连接失败: $e');
    } finally {
      await driver.close();
    }
  }

  /// 展开连接节点:确保连接存活并拉取库列表
  Future<void> expandConnection(ConnectionInfo conn) async {
    final state = databaseStateOf(conn.name);
    if (state.status == LoadStatus.loading ||
        state.status == LoadStatus.loaded) {
      return;
    }
    state
      ..status = LoadStatus.loading
      ..error = null;
    notifyListeners();

    try {
      final driver = await _driverFor(conn);
      state
        ..databases = await driver.listDatabases()
        ..status = LoadStatus.loaded;
    } catch (e) {
      // 连接失败时丢弃驱动,下次展开重连
      await _drivers.remove(conn.name)?.close();
      state
        ..status = LoadStatus.error
        ..error = e.toString();
    }
    notifyListeners();
  }

  /// 重试加载库列表(树里点击错误节点触发)
  Future<void> retryExpandConnection(ConnectionInfo conn) async {
    databaseStateOf(conn.name).status = LoadStatus.idle;
    notifyListeners();
    await expandConnection(conn);
  }

  /// 「打开连接」:无视缓存状态,强制真实通信——重新建立驱动连接并拉取库列表。
  /// 与 [expandConnection] 不同:即使已有库列表缓存也会重新连一次;
  /// 驱动不存活时自动重连(创建新驱动),存活则复用并重新查询。
  /// 返回 (是否成功, 结果 / 错误信息) 供 UI 给出明确反馈。
  Future<(bool, String)> forceExpandConnection(ConnectionInfo conn) async {
    final state = databaseStateOf(conn.name);
    state
      ..status = LoadStatus.loading
      ..databases = const []
      ..error = null;
    notifyListeners();
    try {
      final driver = await _driverFor(conn);
      final databases = await driver.listDatabases();
      state
        ..databases = databases
        ..status = LoadStatus.loaded;
      return (true, '连接成功,共 ${databases.length} 个数据库');
    } catch (e) {
      // 连接失败时丢弃驱动,下次展开重连
      await _drivers.remove(conn.name)?.close();
      state
        ..status = LoadStatus.error
        ..error = e.toString();
      return (false, e.toString());
    } finally {
      notifyListeners();
    }
  }

  /// 强制刷新库列表(新建 / 删除数据库后调用),使新库出现在连接树下
  Future<void> refreshDatabases(ConnectionInfo conn) async {
    final state = databaseStateOf(conn.name);
    state
      ..status = LoadStatus.idle
      ..databases = const []
      ..error = null;
    notifyListeners();
    await expandConnection(conn);
  }

  /// 展开库节点:拉取该库的模式列表 + 默认模式的 表 / 视图 / 函数列表。
  /// 模式列表非空(PostgreSQL 等)时连接树在库下渲染模式层级,
  /// 展开各模式节点时走 [expandSchema] 按模式懒加载。
  Future<void> expandDatabase(ConnectionInfo conn, String database) async {
    final state = tableStateOf(conn.name, database);
    if (state.status == LoadStatus.loading ||
        state.status == LoadStatus.loaded) {
      return;
    }
    state
      ..status = LoadStatus.loading
      ..categoryErrors = null
      ..error = null;
    notifyListeners();

    try {
      final driver = await _driverFor(conn);
      // 先把会话切到目标库再查:PostgreSQL 会话绑定单一库,
      // 不切换会查到连接默认库的表(与展开的库名不符)
      await driver.useDatabase(database);
      // 模式列表与库级对象列表一并拉取(同一会话顺序执行);
      // 无模式层的类型返回空列表,不产生额外查询
      final schemaState = schemaStateOf(conn.name, database);
      if (schemaState.status == LoadStatus.idle) {
        schemaState
          ..schemas = await driver.listSchemas(database)
          ..status = LoadStatus.loaded;
      }
      await _loadObjectLists(state, driver, database);
      state
        ..error = null
        ..status = LoadStatus.loaded;
    } catch (e) {
      await _drivers.remove(conn.name)?.close();
      state
        ..status = LoadStatus.error
        ..categoryErrors = null
        ..error = e.toString();
    }
    notifyListeners();
  }

  /// 逐分类拉取对象列表并写入 [state](同一会话顺序执行,连接非并发安全)。
  ///
  /// 「表」是核心分类:失败意味着该库整体不可访问(或连接已断),异常向上抛出,
  /// 由调用方把整个状态置错并丢弃驱动。其余分类**独立降级**:单类失败只记入
  /// [TableListState.categoryErrors] 并把该分类置空,不影响已成功的分类——
  /// 生产只读账号普遍无 mysql.user / pg_roles 的读取权限(1142 SELECT command
  /// denied),若一并抛出就会出现「能列出所有库、却打不开库看表」。
  Future<void> _loadObjectLists(
    TableListState state,
    DatabaseDriver driver,
    String database, {
    String? schema,
  }) async {
    final errors = <ObjectCategory, String>{};
    // 单类拉取:失败降级为 null(该分类在 UI 上显示错误 + 重试,而非假装为空)
    Future<List<String>?> load(ObjectCategory category) async {
      try {
        return await _listByCategory(driver, category, database, schema: schema);
      } catch (e) {
        errors[category] = e.toString();
        return null;
      }
    }

    final tables = await driver.listTables(database, schema: schema);
    final views = await load(ObjectCategory.view);
    final materializedViews = await load(ObjectCategory.materializedView);
    final functions = await load(ObjectCategory.function);
    final procedures = await load(ObjectCategory.procedure);
    final users = await load(ObjectCategory.user);
    state
      ..tables = tables
      ..views = views
      ..materializedViews = materializedViews
      ..functions = functions
      ..procedures = procedures
      ..users = users
      ..categoryErrors = errors;
  }

  /// 分类 → 驱动元数据查询的**唯一**映射(新增分类时只改这里)。
  /// 「表」由 [_loadObjectLists] 直接调用以便异常上抛,此处的 table 分支
  /// 只为枚举穷尽保留。
  Future<List<String>> _listByCategory(DatabaseDriver driver,
      ObjectCategory category, String database,
      {String? schema}) =>
      switch (category) {
        ObjectCategory.table =>
          driver.listTables(database, schema: schema),
        ObjectCategory.view => driver.listViews(database, schema: schema),
        ObjectCategory.materializedView =>
          driver.listMaterializedViews(database, schema: schema),
        ObjectCategory.function =>
          driver.listFunctions(database, schema: schema),
        ObjectCategory.procedure =>
          driver.listProcedures(database, schema: schema),
        ObjectCategory.user => driver.listUsers(database),
        // 查询 / 备份来自本地保存的 SQL,不经驱动
        ObjectCategory.query || ObjectCategory.backup =>
          Future.value(const <String>[]),
      };

  /// 重试加载库级对象列表(树里点击错误节点触发)
  Future<void> retryExpandDatabase(ConnectionInfo conn, String database) async {
    tableStateOf(conn.name, database).status = LoadStatus.idle;
    notifyListeners();
    await expandDatabase(conn, database);
  }

  /// 展开模式节点:拉取该模式下的 表 / 视图 / 函数列表。
  /// 状态独立缓存于 "连接|库|模式" 键下,与库级(默认模式)互不影响。
  Future<void> expandSchema(
      ConnectionInfo conn, String database, String schema) async {
    final state = tableStateOf(conn.name, database, schema: schema);
    if (state.status == LoadStatus.loading ||
        state.status == LoadStatus.loaded) {
      return;
    }
    state
      ..status = LoadStatus.loading
      ..categoryErrors = null
      ..error = null;
    notifyListeners();

    try {
      final driver = await _driverFor(conn);
      await driver.useDatabase(database);
      await _loadObjectLists(state, driver, database, schema: schema);
      state
        ..error = null
        ..status = LoadStatus.loaded;
    } catch (e) {
      await _drivers.remove(conn.name)?.close();
      state
        ..status = LoadStatus.error
        ..categoryErrors = null
        ..error = e.toString();
    }
    notifyListeners();
  }

  /// 重试加载某模式的对象列表
  Future<void> retryExpandSchema(
      ConnectionInfo conn, String database, String schema) async {
    tableStateOf(conn.name, database, schema: schema).status = LoadStatus.idle;
    notifyListeners();
    await expandSchema(conn, database, schema);
  }

  /// 查询表数据分页(服务端分页):跳过 [offset] 行后取 [limit] 行;
  /// [where] / [orderBy] 为按驱动标识符规则预生成的筛选 / 排序片段。
  /// 连接失效时自动重连一次。[schema] 非空时按模式限定表名。
  Future<TablePreview> previewTable(
    ConnectionInfo conn,
    String database,
    String table, {
    int limit = 100,
    int offset = 0,
    String? schema,
    String? where,
    String? orderBy,
  }) async {
    final driver = await _driverFor(conn);
    try {
      // 先把会话切到表所在库再查:PostgreSQL 会话绑定单一库,
      // 不切换会查到连接默认库里同名表(空表)或报 relation does not exist
      await driver.useDatabase(database);
      return await driver.previewTable(database, table,
          limit: limit, offset: offset, schema: schema, where: where, orderBy: orderBy);
    } catch (e) {
      // 可能是连接被服务端断开:丢弃驱动,重连后重试一次
      await _drivers.remove(conn.name)?.close();
      final fresh = await _driverFor(conn);
      await fresh.useDatabase(database);
      return fresh.previewTable(database, table,
          limit: limit, offset: offset, schema: schema, where: where, orderBy: orderBy);
    }
  }

  /// 统计表的总行数(服务端分页的"分页针对全表"总数依据);
  /// [where] 非空时统计筛选后的行数。连接失效时自动重连一次。
  Future<int> countTable(
    ConnectionInfo conn,
    String database,
    String table, {
    String? schema,
    String? where,
  }) async {
    final driver = await _driverFor(conn);
    try {
      await driver.useDatabase(database);
      return await driver.countTable(database, table, schema: schema, where: where);
    } catch (e) {
      await _drivers.remove(conn.name)?.close();
      final fresh = await _driverFor(conn);
      await fresh.useDatabase(database);
      return fresh.countTable(database, table, schema: schema, where: where);
    }
  }

  /// 取得**已定位好运行上下文**的驱动:切到 [database]、必要时再切到 [schema]。
  /// 供需要复用同一会话批量执行 many 语句的场景(如「运行 SQL 文件」)使用——
  /// [runQuery] 每次调用都会重新定位会话,而 PostgreSQL 家族的 `useDatabase`
  /// 实现为断开重连,逐条语句调用会让转储执行永远停留在新会话上。
  Future<DatabaseDriver> sessionFor(
    ConnectionInfo conn, {
    String? database,
    String? schema,
  }) async {
    final driver = await _driverFor(conn);
    if (database != null && database.isNotEmpty) {
      await driver.useDatabase(database);
    }
    if (kUseSchemaTypes.contains(conn.typeId)) {
      await driver.useSchema(schema);
    }
    return driver;
  }

  /// 查询编辑页:对指定连接执行任意 SQL。
  /// [database] 为运行上下文所选库,非空时先把会话切换到该库;
  /// [schema] 为运行上下文所选模式(PostgreSQL 家族):非空时切换到该模式,
  /// 为空时恢复会话默认 search_path(本就无覆盖时驱动内 no-op)。
  /// 模式切换仅对 [kUseSchemaTypes] 类型生效,其余类型忽略 [schema]。
  /// 不做断线自动重试——写语句重复执行会产生重复数据
  Future<QueryResult> runQuery(
    ConnectionInfo conn,
    String sql, {
    int limit = 1000,
    String? database,
    String? schema,
  }) async {
    final driver =
        await sessionFor(conn, database: database, schema: schema);
    return driver.executeQuery(sql, limit: limit);
  }

  /// 查询表结构(字段列表),供「设计表」视图展示;连接失效时自动重连一次。
  /// [schema] 非空时限定该模式下的表
  Future<List<ColumnDef>> describeTable(
    ConnectionInfo conn,
    String database,
    String table, {
    String? schema,
  }) async {
    final driver = await _driverFor(conn);
    try {
      await driver.useDatabase(database);
      return await driver.describeTable(database, table, schema: schema);
    } catch (e) {
      // 可能是连接被服务端断开:丢弃驱动,重连后重试一次
      await _drivers.remove(conn.name)?.close();
      final fresh = await _driverFor(conn);
      await fresh.useDatabase(database);
      return fresh.describeTable(database, table, schema: schema);
    }
  }

  /// 反查已有表的完整设计信息,供「设计表」以编辑模式回填设计器。
  /// 返回 `null` = 该类型不支持结构编辑(界面转只读展示),抛异常 = 读取失败;
  /// 驱动实例获取与失效重连一次的处理与 [describeTable] 一致。
  Future<DesignTable?> readTableDesign(
    ConnectionInfo conn,
    String database,
    String table, {
    String? schema,
  }) async {
    final driver = await _driverFor(conn);
    try {
      await driver.useDatabase(database);
      return await driver.readTableDesign(database, table, schema: schema);
    } catch (e) {
      // 可能是连接被服务端断开:丢弃驱动,重连后重试一次
      await _drivers.remove(conn.name)?.close();
      final fresh = await _driverFor(conn);
      await fresh.useDatabase(database);
      return fresh.readTableDesign(database, table, schema: schema);
    }
  }

  /// 读取设计器下拉候选(排序规则 / 运算符类别 / 表空间)。
  /// 无对应系统目录的驱动返回空集(界面退化为手输),不当作错误;
  /// 连接异常仍向上抛出,由调用方静默兜底。
  Future<DesignCandidates> readDesignCandidates(
      ConnectionInfo conn, String database) async {
    final driver = await _driverFor(conn);
    await driver.useDatabase(database);
    return driver.readDesignCandidates(database);
  }

  /// 获取视图 / 函数的定义(CREATE 语句文本),供「设计视图 / 设计函数」展示与重写。
  /// [schema] 非空时限定该模式下的对象。
  /// 先把会话切到目标库:PostgreSQL 等会话绑定单库,否则 pg_get_viewdef 等
  /// 会查到当前会话所在库而非 [database] 的对象
  Future<String?> getDefinition(
    ConnectionInfo conn,
    String database,
    String name,
    String kind, {
    String? schema,
  }) async {
    final driver = await _driverFor(conn);
    try {
      await driver.useDatabase(database);
      return await driver.getDefinition(database, name, kind, schema: schema);
    } catch (e) {
      // 可能是连接被服务端断开:丢弃驱动,重连后重试一次
      await _drivers.remove(conn.name)?.close();
      final fresh = await _driverFor(conn);
      await fresh.useDatabase(database);
      return fresh.getDefinition(database, name, kind, schema: schema);
    }
  }

  /// 清空某连接下指定库的模式 / 对象元数据缓存(删除数据库后调用,
  /// 避免旧库的对象状态残留;驱动连接保持不变)
  void clearDatabaseState(String connection, String database) {
    final prefix = '$connection|$database';
    _schemaStates.removeWhere((key, _) => key == prefix);
    _tableStates.removeWhere(
        (key, _) => key == prefix || key.startsWith('$prefix|'));
    notifyListeners();
  }

  /// 清空某库下指定模式的对象元数据缓存(删除模式 / 模式重命名后调用,
  /// 避免旧模式的对象状态残留;模式列表由 [refreshSchemas] 重拉)
  void clearSchemaState(String connection, String database, String schema) {
    final prefix = '$connection|$database|$schema';
    _tableStates.removeWhere(
        (key, _) => key == prefix || key.startsWith('$prefix|'));
    notifyListeners();
  }

  /// 确保某库的模式列表已加载(查询编辑页模式下拉打开时调用,幂等)。
  /// 与连接树展开库节点的加载共享同一状态缓存([schemaStateOf])
  Future<void> ensureSchemas(ConnectionInfo conn, String database) async {
    final state = schemaStateOf(conn.name, database);
    if (state.status == LoadStatus.loading ||
        state.status == LoadStatus.loaded) {
      return;
    }
    state
      ..status = LoadStatus.loading
      ..error = null;
    notifyListeners();
    try {
      final driver = await _driverFor(conn);
      await driver.useDatabase(database);
      state
        ..schemas = await driver.listSchemas(database)
        ..status = LoadStatus.loaded;
    } catch (e) {
      await _drivers.remove(conn.name)?.close();
      state
        ..status = LoadStatus.error
        ..error = e.toString();
    }
    notifyListeners();
  }

  /// 强制刷新某库的模式列表(新建 / 删除模式后调用)。
  /// 单独实现:expandDatabase 在表列表已加载时会提前返回,不会重拉模式列表
  Future<void> refreshSchemas(ConnectionInfo conn, String database) async {
    final state = schemaStateOf(conn.name, database);
    state
      ..status = LoadStatus.idle
      ..schemas = const []
      ..error = null;
    notifyListeners();
    try {
      final driver = await _driverFor(conn);
      await driver.useDatabase(database);
      state
        ..schemas = await driver.listSchemas(database)
        ..status = LoadStatus.loaded;
    } catch (e) {
      await _drivers.remove(conn.name)?.close();
      state
        ..status = LoadStatus.error
        ..error = e.toString();
    }
    notifyListeners();
  }

  /// 强制刷新对象列表(表 / 视图 / 函数 / 过程 / 用户)。
  /// [schema] 为空刷新库级(默认模式)状态,非空刷新该模式的独立状态。
  /// DDL 操作(新建 / 删除)后调用,使对象面板与连接树重新加载最新列表。
  Future<void> refreshDatabase(ConnectionInfo conn, String database,
      {String? schema}) async {
    final state = tableStateOf(conn.name, database, schema: schema);
    state
      ..status = LoadStatus.idle
      ..tables = null
      ..views = null
      ..materializedViews = null
      ..functions = null
      ..procedures = null
      ..users = null
      ..categoryErrors = null
      ..error = null;
    notifyListeners();
    if (schema == null) {
      await expandDatabase(conn, database);
    } else {
      await expandSchema(conn, database, schema);
    }
  }

  /// 关闭并移除某连接的驱动(如删除连接时)
  Future<void> disconnect(String connection) async {
    await _drivers.remove(connection)?.close();
    _databaseStates.remove(connection);
    _schemaStates.removeWhere((key, _) => key.startsWith('$connection|'));
    _tableStates.removeWhere((key, _) => key.startsWith('$connection|'));
    notifyListeners();
  }

  @override
  void dispose() {
    for (final driver in _drivers.values) {
      driver.close();
    }
    _drivers.clear();
    super.dispose();
  }
}
