import 'dart:async';

import 'package:dart_odbc/dart_odbc.dart';

import '../db_data.dart';
import 'db_driver.dart';
import 'odbc_query.dart';

/// SQL Server 驱动,单一后端:系统 ODBC(dart_odbc)。
///
/// 通过 Windows ODBC 驱动管理器访问 SQL Server,天然同时支持:
/// - SQL Server 身份验证([ConnectionInfo.authMethod] != 'windows'):
///   连接串带 UID / PWD;
/// - Windows 身份验证('windows'):
///   连接串带 `Trusted_Connection=yes`,使用当前 Windows 账户集成认证。
///
/// 前提:本机已安装 SQL Server ODBC 驱动(优先 ODBC Driver 18/17 for SQL
/// Server,其次 Native Client 11 / 旧版 SQL Server 驱动,依次尝试)。
///
/// 持有单条长连接,元数据查询与数据预览共用同一连接;
/// 连接断开时由上层([ConnectionManager])负责重建。
class SqlServerDriver implements DatabaseDriver {
  SqlServerDriver(this._conn);

  final ConnectionInfo _conn;
  DartOdbc? _odbc;

  @override
  bool get isConnected => _odbc != null;

  /// 连接超时(dart_odbc 的 SQLDriverConnectW 无内置超时,
  /// 服务器不可达时会在 isolate 里无限阻塞,这里在 Dart 层兜底)
  static const _connectTimeout = Duration(seconds: 10);

  @override
  Future<void> connect() async {
    if (_odbc != null) return;
    // 常见 SQL Server ODBC 驱动名依次尝试,兼容不同本机安装
    const drivers = [
      'ODBC Driver 18 for SQL Server',
      'ODBC Driver 17 for SQL Server',
      'SQL Server Native Client 11.0',
      'SQL Server',
    ];
    String? lastError;
    for (final driver in drivers) {
      final odbc = DartOdbc();
      try {
        await odbc
            .connectWithConnectionString(_connectionString(driver))
            .timeout(_connectTimeout);
        _odbc = odbc;
        return;
      } on TimeoutException {
        // 底层 ODBC 调用在 isolate 里阻塞:不再复用该实例,
        // 后台尝试关闭其 isolate,避免遗留僵尸连接
        unawaited(odbc.disconnect().catchError((_) {}));
        throw Exception(
          '连接超时(${_connectTimeout.inSeconds} 秒无响应),'
          '请检查主机 / 端口 / 防火墙及服务器状态',
        );
      } catch (e) {
        lastError = e.toString();
        try {
          await odbc.disconnect();
        } catch (_) {}
      }
    }
    throw Exception(
      'SQL Server 连接失败(请确认本机已安装 SQL Server ODBC 驱动): '
      '$lastError',
    );
  }

  /// 组装 ODBC 连接串:按认证方式选择 Trusted_Connection 或 UID/PWD。
  /// 对齐原 mssql_connection 的 encrypt=false + trustServerCertificate=true,
  /// 关闭强制加密以兼容未配置证书的服务器
  String _connectionString(String driver) {
    final db = _conn.database.isEmpty ? 'master' : _conn.database;
    final port = _conn.port.isEmpty ? '1433' : _conn.port;
    final buf = StringBuffer()
      ..write('DRIVER={$driver};SERVER=${_conn.host},$port;DATABASE=$db;')
      ..write('Encrypt=No;TrustServerCertificate=Yes;');
    if (_conn.authMethod == 'windows') {
      buf.write('Trusted_Connection=yes;');
    } else {
      buf.write('UID=${_conn.username};PWD=${_conn.password};');
    }
    return buf.toString();
  }

  /// 统一 SQL 执行入口:返回 列名 + 行数据(列名 → 值)
  Future<({List<String> columns, List<Map<String, dynamic>> rows})>
      _runSql(String sql) async {
    final rows = await _get().execute(sql);
    final columns =
        rows.isEmpty ? const <String>[] : rows.first.keys.toList();
    return (columns: columns, rows: rows);
  }

  @override
  Future<void> close() async {
    final odbc = _odbc;
    _odbc = null;
    if (odbc != null) {
      try {
        await odbc.disconnect();
      } catch (_) {
        // 断开时忽略错误
      }
    }
  }

  DartOdbc _get() {
    final odbc = _odbc;
    if (odbc == null) {
      throw Exception('SQL Server 未连接');
    }
    return odbc;
  }

  /// 最近一次 USE 的库,避免每次执行都发 USE
  String? _currentDatabase;

  /// 方括号包裹标识符,防库/表名与关键字冲突
  String _quoted(String name) => '[${name.replaceAll(']', ']]')}]';

  /// 转义字符串字面量中的单引号(翻倍),调用处自行包裹单引号(与 mysql/mariadb 驱动一致)
  String _literal(String value) => value.replaceAll("'", "''");

  @override
  Future<List<String>> listDatabases() async {
    final r = await _runSql('SELECT name FROM sys.databases ORDER BY name');
    return [
      for (final row in r.rows)
        if (row['name'] != null) row['name'].toString(),
    ];
  }

  @override
  Future<List<String>> listSchemas(String database) async {
    // 排除系统模式:sys / guest / INFORMATION_SCHEMA / db_* 固定角色
    final r = await _runSql(
      'SELECT name FROM ${_quoted(database)}.sys.schemas '
      "WHERE name NOT IN ('guest', 'INFORMATION_SCHEMA', 'sys') "
      "AND name NOT LIKE 'db\\_%' ESCAPE '\\' ORDER BY name",
    );
    return [
      for (final row in r.rows)
        if (row['name'] != null) row['name'].toString(),
    ];
  }

  @override
  Future<List<String>> listTables(String database, {String? schema}) async {
    final schemaFilter = schema == null
        ? ''
        : "AND TABLE_SCHEMA = '${_literal(schema)}' ";
    final r = await _runSql(
      "SELECT TABLE_NAME FROM ${_quoted(database)}.INFORMATION_SCHEMA.TABLES "
      "WHERE TABLE_TYPE = 'BASE TABLE' $schemaFilter"
      "ORDER BY TABLE_NAME",
    );
    return [
      for (final row in r.rows)
        if (row['TABLE_NAME'] != null) row['TABLE_NAME'].toString(),
    ];
  }

  @override
  Future<List<String>> listViews(String database, {String? schema}) async {
    final schemaFilter = schema == null
        ? ''
        : "WHERE TABLE_SCHEMA = '${_literal(schema)}' ";
    final r = await _runSql(
      'SELECT TABLE_NAME FROM ${_quoted(database)}.INFORMATION_SCHEMA.VIEWS '
      '$schemaFilter'
      'ORDER BY TABLE_NAME',
    );
    return [
      for (final row in r.rows)
        if (row['TABLE_NAME'] != null) row['TABLE_NAME'].toString(),
    ];
  }

  /// 执行「OBJ_NAME + CMT」两列查询,聚成 名称 → 注释(trim 后)的 Map。
  Future<Map<String, String>> _objectComments(String sql) async {
    final r = await _runSql(sql);
    return {
      for (final row in r.rows)
        if (row['OBJ_NAME'] != null)
          row['OBJ_NAME'].toString(): (row['CMT']?.toString() ?? '').trim(),
    };
  }

  // SQL Server 对象级注释存于 sys.extended_properties(class=1、minor_id=0、
  // name='MS_Description');ep.value 是 sql_variant,CAST 成 NVARCHAR 便于读取。
  @override
  Future<Map<String, String>> listTableComments(String database,
      {String? schema}) {
    final qdb = _quoted(database);
    final sf = schema == null ? '' : "AND s.name = '${_literal(schema)}' ";
    return _objectComments(
      "SELECT t.name AS OBJ_NAME, CAST(ep.value AS NVARCHAR(4000)) AS CMT "
      "FROM $qdb.sys.tables t "
      "JOIN $qdb.sys.schemas s ON s.schema_id = t.schema_id "
      "LEFT JOIN $qdb.sys.extended_properties ep "
      "  ON ep.class = 1 AND ep.major_id = t.object_id AND ep.minor_id = 0 "
      " AND ep.name = 'MS_Description' "
      "WHERE 1 = 1 $sf",
    );
  }

  @override
  Future<Map<String, String>> listViewComments(String database,
      {String? schema}) {
    final qdb = _quoted(database);
    final sf = schema == null ? '' : "AND s.name = '${_literal(schema)}' ";
    return _objectComments(
      "SELECT v.name AS OBJ_NAME, CAST(ep.value AS NVARCHAR(4000)) AS CMT "
      "FROM $qdb.sys.views v "
      "JOIN $qdb.sys.schemas s ON s.schema_id = v.schema_id "
      "LEFT JOIN $qdb.sys.extended_properties ep "
      "  ON ep.class = 1 AND ep.major_id = v.object_id AND ep.minor_id = 0 "
      " AND ep.name = 'MS_Description' "
      "WHERE 1 = 1 $sf",
    );
  }

  @override
  Future<Map<String, String>> listFunctionComments(String database,
      {String? schema}) {
    final qdb = _quoted(database);
    final sf = schema == null ? '' : "AND s.name = '${_literal(schema)}' ";
    // FN 标量函数 / IF 内联表值 / TF 表值 / AF 聚合 / PC 程序化 CLR 函数
    return _objectComments(
      "SELECT o.name AS OBJ_NAME, CAST(ep.value AS NVARCHAR(4000)) AS CMT "
      "FROM $qdb.sys.objects o "
      "JOIN $qdb.sys.schemas s ON s.schema_id = o.schema_id "
      "LEFT JOIN $qdb.sys.extended_properties ep "
      "  ON ep.class = 1 AND ep.major_id = o.object_id AND ep.minor_id = 0 "
      " AND ep.name = 'MS_Description' "
      "WHERE o.type IN ('FN', 'IF', 'TF', 'AF', 'PC') $sf",
    );
  }

  @override
  Future<List<String>> listMaterializedViews(String database,
          {String? schema}) async =>
      const <String>[];

  @override
  Future<List<String>> listFunctions(String database, {String? schema}) async {
    final r = await _runSql(
      'SELECT ROUTINE_NAME FROM ${_quoted(database)}.INFORMATION_SCHEMA.ROUTINES '
      "WHERE ROUTINE_TYPE = 'FUNCTION' "
      "AND ROUTINE_SCHEMA = '${_literal(schema ?? 'dbo')}' "
      'ORDER BY ROUTINE_NAME',
    );
    return [
      for (final row in r.rows)
        if (row['ROUTINE_NAME'] != null) row['ROUTINE_NAME'].toString(),
    ];
  }

  @override
  Future<List<String>> listProcedures(String database, {String? schema}) async {
    final r = await _runSql(
      'SELECT ROUTINE_NAME FROM ${_quoted(database)}.INFORMATION_SCHEMA.ROUTINES '
      "WHERE ROUTINE_TYPE = 'PROCEDURE' "
      "AND ROUTINE_SCHEMA = '${_literal(schema ?? 'dbo')}' "
      'ORDER BY ROUTINE_NAME',
    );
    return [
      for (final row in r.rows)
        if (row['ROUTINE_NAME'] != null) row['ROUTINE_NAME'].toString(),
    ];
  }

  @override
  Future<List<String>> listUsers(String database) async {
    final r = await _runSql(
      'SELECT name FROM ${_quoted(database)}.sys.database_principals '
      "WHERE type IN ('S', 'U', 'G') AND principal_id > 0 "
      'ORDER BY name',
    );
    return [
      for (final row in r.rows)
        if (row['name'] != null) row['name'].toString(),
    ];
  }

  @override
  Future<TablePreview> previewTable(
    String database,
    String table, {
    int limit = 100,
    int offset = 0,
    String? schema,
    String? where,
    String? orderBy,
  }) async {
    // schema 为空时用默认模式 dbo;非空时显式限定 db.schema.table
    final schemaPart = _quoted(schema ?? 'dbo');
    // OFFSET/FETCH 要求 ORDER BY;无排序时用常量表达式占位(不改变行序)
    final order = orderByClauseSql(orderBy).isNotEmpty
        ? ' ORDER BY $orderBy'
        : ' ORDER BY (SELECT NULL)';
    final r = await _runSql(
      'SELECT * FROM ${_quoted(database)}.$schemaPart.${_quoted(table)}'
      '${whereClauseSql(where)}$order'
      ' OFFSET $offset ROWS FETCH NEXT $limit ROWS ONLY',
    );

    final rows = <List<String>>[];
    // nullMask 记录每格的原始 null 判定:展示层里真 NULL 与字符串 "NULL"
    // 都是 "NULL",导出 / 导入必须靠它区分
    final nullMask = <List<bool>>[];
    for (final row in r.rows) {
      final cells = <String>[];
      final nulls = <bool>[];
      for (final col in r.columns) {
        final v = row[col];
        cells.add(v?.toString() ?? 'NULL');
        nulls.add(v == null);
      }
      rows.add(cells);
      nullMask.add(nulls);
    }
    return TablePreview(
      columns: r.columns,
      rows: rows,
      limit: limit,
      nullMask: nullMask,
    );
  }

  @override
  Future<int> countTable(String database, String table,
      {String? schema, String? where}) async {
    final schemaPart = _quoted(schema ?? 'dbo');
    final r = await _runSql(
      'SELECT COUNT(*) AS cnt FROM ${_quoted(database)}.$schemaPart.${_quoted(table)}'
      '${whereClauseSql(where)}',
    );
    return parseCountValue(r.rows.first[r.columns.first]);
  }

  @override
  Future<void> useDatabase(String database) async {
    if (_currentDatabase == database) return;
    await _runSql('USE ${_quoted(database)}');
    _currentDatabase = database;
  }

  @override
  Future<void> useSchema(String? schema) {
    // SQL Server 虽有模式层但无会话级默认模式机制,仅 PostgreSQL 家族支持;
    // UI 层按类型显隐,不会对其调用本方法
    throw UnsupportedError('该数据库类型不支持会话级模式切换');
  }

  @override
  Future<QueryResult> executeQuery(String sql,
      {int limit = 1000, int offset = 0}) async {
    // 走封顶流式,不能用 _runSql:dart_odbc 的 execute 会把整棵结果集在
    // ODBC isolate 里抽干后整体拷回,`SELECT * FROM 大表` 会把进程内存
    // 顶到数 GB(实测 5.3 GB)并报 HY001「Memory allocation failure」,
    // 且要等全表读完才出结果。详见 odbcQueryCapped。
    final r = await odbcQueryCapped(_get(), sql, limit: limit, offset: offset);
    return QueryResult(
      columns: r.columns,
      rows: r.rows,
      limit: limit,
      offset: offset,
      moreRows: r.moreRows,
    );
  }

  @override
  Future<int?> serverSessionId() async {
    final r = await _runSql('SELECT @@SPID AS spid');
    if (r.rows.isEmpty) return null;
    return int.tryParse(r.rows.first['spid']?.toString() ?? '');
  }

  @override
  Future<void> killSession(int sessionId) async {
    // 主连接被 executeQuery 占住 → 第二条 ODBC 连接发 KILL;依次试已装驱动
    const drivers = [
      'ODBC Driver 18 for SQL Server',
      'ODBC Driver 17 for SQL Server',
      'SQL Server Native Client 11.0',
      'SQL Server',
    ];
    Object? lastError;
    for (final driver in drivers) {
      final odbc = DartOdbc();
      try {
        await odbc.connectWithConnectionString(_connectionString(driver));
        await odbc.execute('KILL $sessionId');
        return;
      } catch (e) {
        lastError = e;
      } finally {
        try {
          await odbc.disconnect();
        } catch (_) {}
      }
    }
    if (lastError != null) throw Exception('取消查询失败: $lastError');
  }

  @override
  Future<List<ColumnDef>> describeTable(String database, String table,
      {String? schema}) async {
    final schemaFilter = schema == null
        ? ''
        : "AND c.TABLE_SCHEMA = '${_literal(schema)}' ";
    final qdb = _quoted(database);
    // SQL Server 列注释存于 sys.extended_properties(name='MS_Description'),
    // INFORMATION_SCHEMA 拿不到;按 表名 → 模式 → 列 三级 JOIN 定位到
    // (major_id, minor_id) 后再取 ep.value。ep.value 是 sql_variant,
    // CAST 成 NVARCHAR(4000) 便于驱动直接读文本
    final r = await _runSql(
      "SELECT c.COLUMN_NAME, c.DATA_TYPE, c.IS_NULLABLE, c.COLUMN_DEFAULT, "
      "CAST(ep.value AS NVARCHAR(4000)) AS COLUMN_COMMENT "
      "FROM $qdb.INFORMATION_SCHEMA.COLUMNS c "
      "LEFT JOIN $qdb.sys.tables tb ON tb.name = c.TABLE_NAME "
      "LEFT JOIN $qdb.sys.schemas s "
      "  ON s.schema_id = tb.schema_id AND s.name = c.TABLE_SCHEMA "
      "LEFT JOIN $qdb.sys.columns sc "
      "  ON sc.object_id = tb.object_id AND sc.name = c.COLUMN_NAME "
      "LEFT JOIN $qdb.sys.extended_properties ep "
      "  ON ep.class = 1 AND ep.major_id = sc.object_id "
      " AND ep.minor_id = sc.column_id AND ep.name = 'MS_Description' "
      "WHERE c.TABLE_NAME = '${_literal(table)}' $schemaFilter"
      "ORDER BY c.ORDINAL_POSITION",
    );
    return [
      for (final row in r.rows)
        ColumnDef(
          name: row['COLUMN_NAME']?.toString() ?? '',
          type: row['DATA_TYPE']?.toString() ?? '',
          nullable: (row['IS_NULLABLE']?.toString() ?? 'YES') == 'YES',
          defaultValue: row['COLUMN_DEFAULT']?.toString(),
          comment: row['COLUMN_COMMENT']?.toString() ?? '',
        ),
    ];
  }

  @override
  Future<String?> getDefinition(String database, String name, String kind,
      {String? schema}) async {
    // SQL Server 视图 / 函数均为可定义对象,OBJECT_DEFINITION 返回完整 CREATE 文本
    final objName = '$database.${schema ?? 'dbo'}.$name';
    final r = await _runSql(
      "SELECT OBJECT_DEFINITION(OBJECT_ID('${_literal(objName)}')) AS def",
    );
    if (r.rows.isEmpty) return null;
    final v = r.rows.first['def'];
    return v?.toString();
  }
}
