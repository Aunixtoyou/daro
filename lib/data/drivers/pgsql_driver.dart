import 'package:postgres/postgres.dart' hide ConnectionInfo;

import '../db_data.dart';
import '../sql_row_cap.dart';
import 'db_driver.dart';

/// PostgreSQL 驱动(纯 Dart 实现,基于 postgres 包)。
///
/// 持有单条长连接,元数据查询与数据预览共用同一连接;
/// 连接断开时由上层([ConnectionManager])负责重建。
class PgsqlDriver implements DatabaseDriver {
  PgsqlDriver(this._conn);

  final ConnectionInfo _conn;
  Connection? _connection;

  /// 当前连接的库(null = 未切换过,用连接配置的默认库)
  String? _database;

  /// 当前会话的模式(null = 未显式切换,走连接默认 search_path)
  String? _schema;

  @override
  bool get isConnected => _connection != null && _connection!.isOpen;

  @override
  Future<void> connect() async {
    if (isConnected) return;
    final conn = await Connection.open(
      Endpoint(
        host: _conn.host,
        port: int.tryParse(_conn.port) ?? 5432,
        database:
            _database ?? (_conn.database.isEmpty ? 'postgres' : _conn.database),
        username: _conn.username,
        password: _conn.password,
      ),
      settings: const ConnectionSettings(
        // 本地 / 内网 PostgreSQL 通常未启用 SSL
        sslMode: SslMode.disable,
        connectTimeout: Duration(seconds: 10),
      ),
    );
    _connection = conn;
  }

  @override
  Future<void> close() async {
    final conn = _connection;
    _connection = null;
    if (conn != null && conn.isOpen) {
      await conn.close();
    }
  }

  Connection _get() {
    if (_connection == null || !_connection!.isOpen) {
      throw Exception('PostgreSQL 连接不可用');
    }
    return _connection!;
  }

  /// 双引号包裹标识符,防库/表名与关键字冲突
  String _quoted(String name) => '"${name.replaceAll('"', '""')}"';

  /// 单引号包裹字符串字面量(模式名作为 SQL 字符串比较值使用)
  String _lit(String s) => "'${s.replaceAll("'", "''")}'";

  /// 模式名兜底:未显式切换时用默认模式 public
  String get _schemaOrPublic => _schema ?? 'public';

  @override
  Future<List<String>> listDatabases() async {
    final conn = _get();
    final result = await conn.execute(
      'SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname',
    );
    return [
      for (final row in result)
        if (row[0] != null) row[0].toString(),
    ];
  }

  @override
  Future<List<String>> listSchemas(String database) async {
    final conn = _get();
    // 排除系统模式:pg_catalog / information_schema / pg_temp_* / pg_toast*
    final result = await conn.execute(
      "SELECT nspname FROM pg_namespace "
      "WHERE nspname NOT IN ('information_schema', 'pg_catalog') "
      "AND nspname !~ '^pg_' "
      "ORDER BY nspname",
    );
    return [
      for (final row in result)
        if (row[0] != null) row[0].toString(),
    ];
  }

  @override
  Future<List<String>> listTables(String database, {String? schema}) async {
    final conn = _get();
    // 使用 information_schema 查询指定模式的用户表
    final result = await conn.execute(
      "SELECT table_name FROM information_schema.tables "
      "WHERE table_schema = ${_lit(schema ?? _schemaOrPublic)} "
      "AND table_type = 'BASE TABLE' "
      "ORDER BY table_name",
    );
    return [
      for (final row in result)
        if (row[0] != null) row[0].toString(),
    ];
  }

  @override
  Future<List<String>> listViews(String database, {String? schema}) async {
    final conn = _get();
    final result = await conn.execute(
      "SELECT table_name FROM information_schema.views "
      "WHERE table_schema = ${_lit(schema ?? _schemaOrPublic)} ORDER BY table_name",
    );
    return [
      for (final row in result)
        if (row[0] != null) row[0].toString(),
    ];
  }

  @override
  Future<List<String>> listMaterializedViews(String database,
      {String? schema}) async {
    final conn = _get();
    final result = await conn.execute(
      "SELECT matviewname FROM pg_matviews "
      "WHERE schemaname = ${_lit(schema ?? _schemaOrPublic)} "
      "ORDER BY matviewname",
    );
    return [
      for (final row in result)
        if (row[0] != null) row[0].toString(),
    ];
  }

  @override
  Future<List<String>> listFunctions(String database, {String? schema}) async {
    final conn = _get();
    final result = await conn.execute(
      "SELECT routine_name FROM information_schema.routines "
      "WHERE routine_schema = ${_lit(schema ?? _schemaOrPublic)} "
      "AND routine_type = 'FUNCTION' "
      "ORDER BY routine_name",
    );
    return [
      for (final row in result)
        if (row[0] != null) row[0].toString(),
    ];
  }

  @override
  Future<List<String>> listProcedures(String database, {String? schema}) async {
    final conn = _get();
    // PostgreSQL 11+ 才支持存储过程;低版本该查询自然返回空
    final result = await conn.execute(
      "SELECT routine_name FROM information_schema.routines "
      "WHERE routine_schema = ${_lit(schema ?? _schemaOrPublic)} "
      "AND routine_type = 'PROCEDURE' "
      "ORDER BY routine_name",
    );
    return [
      for (final row in result)
        if (row[0] != null) row[0].toString(),
    ];
  }

  @override
  Future<List<String>> listUsers(String database) async {
    final conn = _get();
    final result = await conn.execute(
      "SELECT rolname FROM pg_roles WHERE rolcanlogin = true ORDER BY rolname",
    );
    return [
      for (final row in result)
        if (row[0] != null) row[0].toString(),
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
    final conn = _get();
    // schema 为空时不限定(走 search_path,默认 public);
    // 非空时显式限定 "schema"."table",避免查到其它模式的同名表
    final qualified = schema == null || schema.isEmpty
        ? _quoted(table)
        : '${_quoted(schema)}.${_quoted(table)}';
    final result = await conn.execute(
      'SELECT * FROM $qualified'
      '${whereClauseSql(where)}${orderByClauseSql(orderBy)}'
      ' LIMIT $limit OFFSET $offset',
    );

    // postgres 包的 Result.schema.columns 提供列元信息
    final columns = [
      for (final col in result.schema.columns)
        if (col.columnName != null) col.columnName!,
    ];

    final rows = <List<String>>[];
    // nullMask 记录每格的原始 null 判定:展示层里真 NULL 与字符串 "NULL"
    // 都是 "NULL",导出 / 导入必须靠它区分
    final nullMask = <List<bool>>[];
    for (final row in result) {
      final cells = <String>[];
      final nulls = <bool>[];
      for (var i = 0; i < columns.length; i++) {
        final v = row[i];
        cells.add(v?.toString() ?? 'NULL');
        nulls.add(v == null);
      }
      rows.add(cells);
      nullMask.add(nulls);
    }
    return TablePreview(
        columns: columns, rows: rows, limit: limit, nullMask: nullMask);
  }

  @override
  Future<int> countTable(String database, String table,
      {String? schema, String? where}) async {
    final conn = _get();
    // 与 previewTable 相同的模式限定逻辑
    final qualified = schema == null || schema.isEmpty
        ? _quoted(table)
        : '${_quoted(schema)}.${_quoted(table)}';
    final result = await conn.execute(
      'SELECT COUNT(*) AS cnt FROM $qualified${whereClauseSql(where)}',
    );
    return parseCountValue(result.first[0]);
  }

  @override
  Future<void> useDatabase(String database) async {
    if (_database == database ||
        (_database == null && database == _conn.database)) {
      return;
    }
    // PostgreSQL 会话绑定单一库:切换库需要断开重连
    final old = _connection;
    _connection = null;
    await old?.close();
    _database = database;
    // 重连后回到连接默认 search_path,旧模式选择失效
    _schema = null;
    await connect();
  }

  @override
  Future<void> useSchema(String? schema) async {
    if (_schema == schema) return;
    if (schema == null) {
      // 恢复会话默认 search_path(连接 / 角色级配置)
      await _get().execute('RESET search_path');
    } else {
      await _get().execute('SET search_path TO ${_quoted(schema)}');
    }
    _schema = schema;
  }

  @override
  Future<QueryResult> executeQuery(String sql, {int limit = 1000}) async {
    final conn = _get();
    // 封顶必须下推到服务端:postgres 包的 Result 是已物化的 List<ResultRow>,
    // 在调用方 break 救不回来(详见 sql_row_cap.dart)
    final capped = capSelectSql(sql, maxRows: limit + 1);
    final result = await conn.execute(capped ?? sql);

    final columns = [
      for (final col in result.schema.columns)
        if (col.columnName != null && col.columnName!.isNotEmpty)
          col.columnName!,
    ];
    if (columns.isEmpty) {
      // 写操作:无结果集,返回受影响行数
      return QueryResult(
        columns: const [],
        rows: const [],
        affectedRows: result.affectedRows,
        limit: limit,
      );
    }

    final rows = <List<String>>[];
    for (final row in result) {
      if (rows.length >= limit) break;
      rows.add([
        for (var i = 0; i < columns.length; i++) row[i]?.toString() ?? 'NULL',
      ]);
    }
    return QueryResult(
      columns: columns,
      rows: rows,
      limit: limit,
      // 服务端只被允许返回 limit + 1 行,多出的那行即「还有更多」的确证
      moreRows: capped != null && result.length > limit,
    );
  }

  @override
  Future<List<ColumnDef>> describeTable(String database, String table,
      {String? schema}) async {
    final conn = _get();
    final result = await conn.execute(
      "SELECT column_name, data_type, is_nullable, column_default "
      "FROM information_schema.columns "
      "WHERE table_schema = ${_lit(schema ?? _schemaOrPublic)} "
      "AND table_name = '${table.replaceAll("'", "''")}' "
      "ORDER BY ordinal_position",
    );
    return [
      for (final row in result)
        ColumnDef(
          name: row[0]?.toString() ?? '',
          type: row[1]?.toString() ?? '',
          nullable: (row[2]?.toString() ?? 'YES') == 'YES',
          defaultValue: row[3]?.toString(),
        ),
    ];
  }

  @override
  Future<String?> getDefinition(String database, String name, String kind,
      {String? schema}) async {
    final conn = _get();
    // 带 schema 限定的对象引用文本(pg_get_viewdef / regproc 均支持)
    final ref = schema == null || schema.isEmpty
        ? _quoted(name)
        : '${_quoted(schema)}.${_quoted(name)}';
    if (kind == 'view') {
      final result = await conn.execute(
        "SELECT 'CREATE OR REPLACE VIEW ${_quoted(name)} AS ' "
        "|| pg_get_viewdef('$ref', true)",
      );
      if (result.isEmpty) return null;
      final v = result.first[0];
      return v == null ? null : v.toString();
    } else {
      final result = await conn.execute(
        "SELECT pg_get_functiondef('$ref'::regproc)",
      );
      if (result.isEmpty) return null;
      final v = result.first[0];
      return v == null ? null : v.toString();
    }
  }
}
