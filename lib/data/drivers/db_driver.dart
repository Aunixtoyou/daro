import '../db_data.dart';
import '../table_design.dart';
import 'access_driver.dart';
import 'mariadb_driver.dart';
import 'mysql_driver.dart';
import 'pgsql_driver.dart';
import 'sqlite_driver.dart';
import 'sqlserver_driver.dart';

/// 表数据预览结果:列名 + 前 N 行字符串化数据
class TablePreview {
  const TablePreview({
    required this.columns,
    required this.rows,
    this.limit = 100,
    this.nullMask,
  });

  /// 列名(按结果集顺序)
  final List<String> columns;

  /// 行数据:每行为与 [columns] 等长的字符串列表(NULL 显示为 "NULL")
  final List<List<String>> rows;

  /// 查询行数上限
  final int limit;

  /// 每格是否为数据库 NULL:与 [rows] 等长等宽的布尔矩阵。
  /// [rows] 中真 NULL 与字符串 "NULL" 无法区分,导出 / 导入需要精确的
  /// 空值语义,故由驱动在取数时一并记录原始 null 判定;
  /// 为 null 表示驱动未提供(此时按展示约定把值 "NULL" 当作空)。
  final List<List<bool>>? nullMask;

  /// 是否达到上限(可能还有更多行)
  bool get truncated => rows.length >= limit;

  /// 指定单元格是否为 NULL:优先读 [nullMask],无掩码时按展示约定
  /// (值等于 "NULL" 视为空)兜底
  bool isNullAt(int row, int col) {
    final mask = nullMask;
    if (mask != null && row < mask.length && col < mask[row].length) {
      return mask[row][col];
    }
    return rows[row][col] == 'NULL';
  }
}

/// 任意 SQL 的执行结果:SELECT 返回列 + 行,写操作返回受影响行数
/// (查询编辑页「运行」按钮使用)
class QueryResult {
  const QueryResult({
    required this.columns,
    required this.rows,
    this.affectedRows = 0,
    this.limit = 1000,
    this.moreRows = false,
    this.offset = 0,
  });

  /// 列名(仅 SELECT 有值;空列表表示语句无结果集)
  final List<String> columns;

  /// 行数据:每行为与 [columns] 等长的字符串列表(NULL 显示为 "NULL")
  final List<List<String>> rows;

  /// 写操作(INSERT / UPDATE / DELETE)受影响的行数
  final int affectedRows;

  /// 结果行数上限(超出截断,避免大结果集拖垮 UI)
  final int limit;

  /// 是否返回了结果集
  bool get isSelect => columns.isNotEmpty;

  /// 驱动精确上报的「还有更多行未取回」:封顶流式取数(见 `odbcQueryCapped`)
  /// 靠多读的那一行判定;一次性取数的驱动无从得知,保持默认 false
  final bool moreRows;

  /// 本次结果在整体结果集中的起始行偏移(「加载更多」分页续取用);首页为 0
  final int offset;

  /// 是否达到上限(可能还有更多行)
  bool get truncated => isSelect && (moreRows || rows.length >= limit);
}

/// 表字段(列)定义:「设计表」视图展示的结构信息。
class ColumnDef {
  const ColumnDef({
    required this.name,
    required this.type,
    this.nullable = true,
    this.primaryKey = false,
    this.defaultValue,
    this.comment = '',
  });

  /// 列名
  final String name;

  /// 数据类型(含长度 / 精度,如 varchar(255)、int unsigned)
  final String type;

  /// 是否允许 NULL
  final bool nullable;

  /// 是否主键
  final bool primaryKey;

  /// 默认值(NULL 显示为 "NULL")
  final String? defaultValue;

  /// 列注释
  final String comment;
}

/// 数据库驱动抽象:统一各数据库类型的元数据与数据访问接口。
///
/// UI 层(连接树 / 表数据页)只依赖本接口,新增数据库类型时
/// 实现一个 Driver 并在 [createDriver] 工厂注册即可,界面完全复用。
abstract class DatabaseDriver {
  /// 建立连接;databaseName 可选(为空则连接到服务器默认)
  Future<void> connect();

  /// 断开连接(幂等)
  Future<void> close();

  /// 连接是否存活
  bool get isConnected;

  /// 列出服务器上的所有数据库
  Future<List<String>> listDatabases();

  /// 列出指定数据库下的模式(schema / 架构)。
  /// 仅有模式层的数据库(PostgreSQL 等)返回非空列表;
  /// MySQL / MariaDB(Database 即 Schema)、SQLite / Access(文件型)返回空列表。
  /// 注意:各驱动用 `implements` 实现本接口,不继承默认实现,故每个驱动都需显式重写。
  Future<List<String>> listSchemas(String database);

  /// 列出指定数据库下的表;[schema] 指定模式(仅有模式层的类型使用,
  /// 为空时用该类型的默认模式,如 PostgreSQL 的 public)
  Future<List<String>> listTables(String database, {String? schema});

  /// 列出指定数据库下的视图([schema] 语义同 [listTables])
  Future<List<String>> listViews(String database, {String? schema});

  /// 表名 → 表注释(供 SQL 补全面板展示;无表注释概念的驱动返回空 map)。
  /// 键须与 [listTables] 返回的表名一致。读取失败由调用方(ConnectionManager)
  /// 降级为「无注释」,不影响表列表本身。
  /// 注意:各驱动用 `implements` 实现本接口,不继承默认实现,故每个驱动都需显式重写。
  Future<Map<String, String>> listTableComments(String database,
      {String? schema});

  /// 视图名 → 视图注释([schema] 语义同 [listTableComments])
  Future<Map<String, String>> listViewComments(String database,
      {String? schema});

  /// 表名 → **估算行数**(读系统目录 / 统计信息,绝不扫描数据)。
  ///
  /// 一次查询覆盖整库(或 [schema] 模式)的全部表,代价与 [listTables] 同级,
  /// 故随对象列表一起拉取。键须与 [listTables] 一致;取不到估算值的引擎
  /// (Access)、从未统计过的表(SQLite 未跑 ANALYZE、PG 刚建表)一律**不带键**,
  /// 由界面显示横杠。读取失败由调用方(ConnectionManager)降级为「无估算值」。
  Future<Map<String, int>> listTableRowEstimates(String database,
      {String? schema});

  /// 函数名 → 函数注释([schema] 语义同 [listTableComments],键与 [listFunctions] 一致)
  Future<Map<String, String>> listFunctionComments(String database,
      {String? schema});

  /// 列出指定数据库下的实体化视图([schema] 语义同 [listTables])。
  /// 仅 PostgreSQL 家族存在实体化视图概念,其余驱动返回空列表。
  Future<List<String>> listMaterializedViews(String database,
      {String? schema});

  /// 列出指定数据库下的函数([schema] 语义同 [listTables];
  /// SQLite 无存储函数,返回空列表)
  Future<List<String>> listFunctions(String database, {String? schema});

  /// 列出指定数据库下的存储过程([schema] 语义同 [listTables]。
  /// SQLite / Access 无存储过程概念,返回空列表)
  Future<List<String>> listProcedures(String database, {String? schema});

  /// 列出数据库的用户/角色(MySQL: mysql.user;PG: pg_roles;SQL Server: sys.database_principals)
  Future<List<String>> listUsers(String database);

  /// 查询指定表的分页数据(服务端分页):跳过 [offset] 行后取 [limit] 行;
  /// [schema] 非空时按模式限定表名。
  /// [where] / [orderBy] 为调用方按驱动标识符规则预生成的
  /// WHERE / ORDER BY 片段(不含关键字,可为 null),用于服务端筛选 / 排序。
  Future<TablePreview> previewTable(String database, String table,
      {int limit = 100,
      int offset = 0,
      String? schema,
      String? where,
      String? orderBy});

  /// 统计指定表的总行数(服务端分页的"分页针对全表"总数依据);
  /// [where] 语义同 [previewTable],非空时统计筛选后的行数。
  Future<int> countTable(String database, String table,
      {String? schema, String? where});

  /// 切换会话当前使用的数据库(展开库节点 / 表数据预览 / 查询编辑页「运行上下文」共用)。
  /// MySQL / SQL Server 发 USE 语句;PostgreSQL 需断开重连;
  /// SQLite 单文件即一个库,为 no-op
  Future<void> useDatabase(String database);

  /// 切换会话当前模式(schema):PostgreSQL 家族发 SET search_path,
  /// 使后续未带模式限定的 SQL 命中所选模式(查询编辑页「运行上下文」使用)。
  /// [schema] 为空时恢复会话默认 search_path(RESET;本就无覆盖时 no-op)。
  /// 仅 [kUseSchemaTypes] 中的类型支持;其余驱动抛 [UnsupportedError]
  /// (UI 层按类型显隐,不会对其调用本方法)
  Future<void> useSchema(String? schema);

  /// 执行任意 SQL:SELECT 返回结果集,写操作返回受影响行数。
  /// 结果最多 [limit] 行(超出截断);[offset] 跳过前若干行再取(「加载更多」
  /// 分页续取,首页 0)。MySQL / PG / SQLite 以 `LIMIT n OFFSET m` 下推服务端;
  /// SQL Server / Access 走封顶流式游标,从头读取并丢弃前 [offset] 行。
  /// 语句文本由调用方保证非空
  Future<QueryResult> executeQuery(String sql,
      {int limit = 1000, int offset = 0});

  /// 当前会话的服务端会话 id,供「停止」按钮带外取消正在执行的查询。
  /// MySQL = CONNECTION_ID(),PostgreSQL = pg_backend_pid(),SQL Server = @@SPID;
  /// SQLite / Access 等本地文件型无服务端会话,返回 null。
  Future<int?> serverSessionId();

  /// 带外取消 [sessionId] 对应会话上正在执行的查询。
  /// 执行查询的连接正被 await 占住、无法自取消,故各驱动用**第二条临时连接**
  /// 下发(MySQL `KILL`、PostgreSQL `pg_cancel_backend`、SQL Server `KILL`)。
  /// 需要服务端权限(MySQL CONNECTION_ADMIN、PG 同用户/管理员、SQL Server
  /// ALTER SERVER STATE);无会话可取消的驱动为 no-op。
  Future<void> killSession(int sessionId);

  /// 查询指定表的字段(列)结构,供「设计表」视图展示。
  /// 返回按定义顺序排列的列定义;不支持的驱动可返回空列表。
  /// [schema] 非空时限定该模式下的表。
  Future<List<ColumnDef>> describeTable(String database, String table,
      {String? schema});

  /// 反查已有表的完整设计信息(列 / 主键 / 索引 / 外键 / 唯一键 / 检查 /
  /// 注释 / 存储参数),供「设计表」以编辑模式回填设计器。
  ///
  /// 返回 `null` 表示该类型暂不支持结构编辑(SQLite / Access:改列型需重建表、
  /// 元数据能力不足),界面转为只读展示;与「读取失败」(抛异常)区分。
  /// 返回的 [DesignTable.name] 为该表名,[schema] 为该表所属模式。
  Future<DesignTable?> readTableDesign(String database, String table,
      {String? schema});

  /// 设计器下拉候选(排序规则 / 运算符类别 / 表空间)。
  ///
  /// 默认返回空集:没有对应系统目录(或不值得多发一次查询)的驱动无需实现,
  /// 界面退化为纯输入框(仍可手输)。[database] 仅为上下文,候选本身库无关。
  Future<DesignCandidates> readDesignCandidates(String database) async =>
      DesignCandidates.empty;

  /// 获取视图 / 函数 / 过程的定义(CREATE 语句文本),供「设计视图 / 设计函数 /
  /// 设计过程」展示与重写。[kind] 为 'view' / 'function' / 'procedure';
  /// 不支持的驱动(如 SQLite 的函数、Access)返回 null。
  /// [schema] 非空时限定该模式下的对象。
  Future<String?> getDefinition(String database, String name, String kind,
      {String? schema});
}

/// 当前已实现驱动的数据库类型 id(见 db_types.dart)
const kSupportedDriverTypes = {'mysql', 'mariadb', 'postgresql', 'sqlite', 'sqlserver', 'access'};

/// 打开前需要密码的连接类型(「是否需要密码」判断的唯一入口)。
/// 文件型 SQLite / Access 无密码概念;SQL Server 的 Windows 身份验证
/// (authMethod == 'windows')走系统凭据,也不需要密码。
bool connectionNeedsPassword(ConnectionInfo conn) => switch (conn.typeId) {
      'mysql' || 'mariadb' || 'postgresql' => true,
      'sqlserver' => conn.authMethod != 'windows',
      _ => false,
    };

/// 有独立模式层(schema)的数据库类型:库节点下渲染模式层级,
/// 右键库节点提供「新建模式」等模式级操作。
/// PostgreSQL / SQL Server 的 listSchemas 返回真实模式列表;
/// MySQL / MariaDB(Database 即 Schema)、SQLite / Access(文件型)不属于此类。
const kSchemaLayerTypes = {
  'postgresql',
  'aliyun-rds-postgres',
  'aliyun-polardb-postgres',
  'aliyun-oceanbase-postgres',
  'sqlserver',
  'aliyun-rds-sqlserver',
};

/// 支持会话级模式切换的数据库类型(PostgreSQL 家族,通过 SET search_path
/// 实现)。查询编辑页「运行上下文」的模式下拉框仅对这些类型显示,
/// 选中模式后执行查询前会先应用 search_path。
/// SQL Server 虽有模式层但无会话级默认模式机制,故不在此列。
const kUseSchemaTypes = {
  'postgresql',
  'aliyun-rds-postgres',
  'aliyun-polardb-postgres',
  'aliyun-oceanbase-postgres',
};

/// 支持 ALTER SCHEMA ... RENAME TO 的数据库类型(PostgreSQL 家族)。
/// SQL Server 无模式重命名语法,「编辑模式」菜单项按类型隐藏。
const kRenameSchemaTypes = {
  'postgresql',
  'aliyun-rds-postgres',
  'aliyun-polardb-postgres',
  'aliyun-oceanbase-postgres',
};

/// 支持存储函数 / 存储过程的数据库类型。
/// SQLite 无存储函数概念(驱动 listFunctions 返回空);
/// Access 同样不支持(驱动返回空)。
const kFunctionTypes = {
  'mysql',
  'mariadb',
  'postgresql',
  'sqlserver',
};

/// 支持存储过程的数据库类型(与函数一致;PostgreSQL 11+ 才支持过程,
/// 驱动按 version 查询 information_schema.routines,低版本自然返回空)。
const kProcedureTypes = {
  'mysql',
  'mariadb',
  'postgresql',
  'sqlserver',
};

/// 支持用户 / 角色管理的数据库类型。
/// SQLite / Access 为文件型数据库,无独立用户管理体系。
const kUserTypes = {
  'mysql',
  'mariadb',
  'postgresql',
  'sqlserver',
};

/// 支持实体化视图的数据库类型(PostgreSQL 家族)。
const kMaterializedViewTypes = {
  'postgresql',
  'aliyun-rds-postgres',
  'aliyun-polardb-postgres',
  'aliyun-oceanbase-postgres',
};

/// 判断指定数据库类型是否支持某个对象分类(按分类名匹配)。
/// [categoryName] 为 ObjectCategory 的 name 属性值:
/// 'table' / 'view' / 'materializedView' / 'function' / 'procedure' /
/// 'user' / 'query' / 'backup'。
/// 用于 Ribbon 按钮与树分组节点的动态显隐,避免 db_driver 反向依赖 app_state。
bool isCategorySupportedForType(String typeId, String categoryName) => switch (categoryName) {
  'table' || 'view' || 'query' => true,
  'materializedView' => kMaterializedViewTypes.contains(typeId),
  'function' => kFunctionTypes.contains(typeId),
  'procedure' => kProcedureTypes.contains(typeId),
  'user' => kUserTypes.contains(typeId),
  _ => false,
};

/// 判断连接是否可由真实驱动驱动(未实现驱动的类型在树里提示不支持)
bool hasDriver(ConnectionInfo conn) =>
    conn.isLive && kSupportedDriverTypes.contains(conn.typeId);

/// 驱动工厂:按连接类型返回驱动实例;未支持的类型返回 null
DatabaseDriver? createDriver(ConnectionInfo conn) {
  switch (conn.typeId) {
    case 'mysql':
      return MysqlDriver(conn);
    case 'mariadb':
      return MariadbDriver(conn);
    case 'postgresql':
      return PgsqlDriver(conn);
    case 'sqlite':
      return SqliteDriver(conn);
    case 'sqlserver':
      return SqlServerDriver(conn);
    case 'access':
      return AccessDriver(conn);
    default:
      return null;
  }
}

/// 组装 WHERE 子句片段:[where] 为空返回 ''(供各驱动拼接 SQL)
String whereClauseSql(String? where) =>
    where == null || where.isEmpty ? '' : ' WHERE $where';

/// 组装 ORDER BY 子句片段:[orderBy] 为空返回 ''(供各驱动拼接 SQL)
String orderByClauseSql(String? orderBy) =>
    orderBy == null || orderBy.isEmpty ? '' : ' ORDER BY $orderBy';

/// 把驱动返回的 COUNT(*) 标量值解析为 int(int 原样,字符串按数字解析,失败回退 0)
int parseCountValue(Object? v) => v is int ? v : (int.tryParse('$v') ?? 0);

/// 把目录 / 统计信息里的行数标量解析为 int:不可解析或 NULL 返回 null,
/// 语义是「无估算值」(界面显示横杠),与 [parseCountValue] 的 0 兜底区分
int? parseRowCount(Object? v) =>
    v == null ? null : (v is num ? v.toInt() : num.tryParse('$v')?.round());
