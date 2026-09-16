import 'package:postgres/postgres.dart' hide ConnectionInfo;

import '../db_data.dart';
import '../db_metadata.dart';
import '../sql_row_cap.dart';
import '../table_design.dart';
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

  /// 执行「名称列 + 描述列」两列查询,聚成 名称 → 注释(trim 后)的 Map。
  Future<Map<String, String>> _objectComments(String sql) async {
    final conn = _get();
    final result = await conn.execute(sql);
    return {
      for (final row in result)
        if (row[0] != null) row[0].toString(): (row[1]?.toString() ?? '').trim(),
    };
  }

  // PG 的对象注释统一存于 pg_description,objsubid=0 表示对象级(非列级)注释。
  // 表 / 视图来自 pg_class(relkind r / v),函数来自 pg_proc,均按 nspname 过滤。
  @override
  Future<Map<String, String>> listTableComments(String database,
          {String? schema}) =>
      _objectComments(
          "SELECT c.relname, d.description FROM pg_class c "
          "JOIN pg_namespace n ON n.oid = c.relnamespace "
          "LEFT JOIN pg_description d ON d.objoid = c.oid AND d.objsubid = 0 "
          "WHERE n.nspname = ${_lit(schema ?? _schemaOrPublic)} "
          "AND c.relkind = 'r'");

  @override
  Future<Map<String, String>> listViewComments(String database,
          {String? schema}) =>
      _objectComments(
          "SELECT c.relname, d.description FROM pg_class c "
          "JOIN pg_namespace n ON n.oid = c.relnamespace "
          "LEFT JOIN pg_description d ON d.objoid = c.oid AND d.objsubid = 0 "
          "WHERE n.nspname = ${_lit(schema ?? _schemaOrPublic)} "
          "AND c.relkind = 'v'");

  @override
  Future<Map<String, String>> listFunctionComments(String database,
          {String? schema}) =>
      _objectComments(
          "SELECT p.proname, d.description FROM pg_proc p "
          "JOIN pg_namespace n ON n.oid = p.pronamespace "
          "LEFT JOIN pg_description d ON d.objoid = p.oid AND d.objsubid = 0 "
          "WHERE n.nspname = ${_lit(schema ?? _schemaOrPublic)}");

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
  Future<QueryResult> executeQuery(String sql,
      {int limit = 1000, int offset = 0}) async {
    final conn = _get();
    // 封顶必须下推到服务端:postgres 包的 Result 是已物化的 List<ResultRow>,
    // 在调用方 break 救不回来(详见 sql_row_cap.dart);offset 同理由服务端跳过
    final capped = capSelectSql(sql, maxRows: limit + 1, offset: offset);
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
        offset: offset,
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
      offset: offset,
      // 服务端只被允许返回 limit + 1 行,多出的那行即「还有更多」的确证
      moreRows: capped != null && result.length > limit,
    );
  }

  /// 元数据归一化时使用的方言 id([kPgLikeTypes] 的任一成员即可,
  /// 解析层只按方言族区分)
  static const String _dialect = 'postgresql';

  @override
  Future<int?> serverSessionId() async {
    final result = await _get().execute('SELECT pg_backend_pid()');
    final v = result.first[0];
    return v is int ? v : int.tryParse(v?.toString() ?? '');
  }

  @override
  Future<void> killSession(int sessionId) async {
    // 主连接正被 executeQuery 的 await 占住 → 用第二条临时连接发 pg_cancel_backend
    final killer = await Connection.open(
      Endpoint(
        host: _conn.host,
        port: int.tryParse(_conn.port) ?? 5432,
        database: _conn.database.isEmpty ? 'postgres' : _conn.database,
        username: _conn.username,
        password: _conn.password,
      ),
      settings: const ConnectionSettings(
        sslMode: SslMode.disable,
        connectTimeout: Duration(seconds: 10),
      ),
    );
    try {
      await killer.execute('SELECT pg_cancel_backend($sessionId)');
    } finally {
      await killer.close();
    }
  }

  @override
  Future<List<ColumnDef>> describeTable(String database, String table,
      {String? schema}) async {
    final conn = _get();
    // col_description 需要 pg_class 的 OID,information_schema 里没有,
    // 只能按 (nspname, relname) JOIN pg_namespace / pg_class 后取
    final result = await conn.execute(
      "SELECT c.column_name, c.data_type, c.is_nullable, c.column_default, "
      "col_description(pgc.oid, c.ordinal_position::int) "
      "FROM information_schema.columns c "
      "LEFT JOIN pg_namespace pgn ON pgn.nspname = c.table_schema "
      "LEFT JOIN pg_class pgc "
      "  ON pgc.relnamespace = pgn.oid AND pgc.relname = c.table_name "
      "WHERE c.table_schema = ${_lit(schema ?? _schemaOrPublic)} "
      "AND c.table_name = '${table.replaceAll("'", "''")}' "
      "ORDER BY c.ordinal_position",
    );
    return [
      for (final row in result)
        ColumnDef(
          name: row[0]?.toString() ?? '',
          type: row[1]?.toString() ?? '',
          nullable: (row[2]?.toString() ?? 'YES') == 'YES',
          defaultValue: row[3]?.toString(),
          comment: row[4]?.toString() ?? '',
        ),
    ];
  }

  /// 「设计表」反查:列 / 主键 / 索引 / 外键 / 唯一键 / 检查 / 排除 / 注释 / 存储参数。
  ///
  /// 一律走 `pg_*` 系统目录:identity 序列选项、索引方法、约束真名都无法从
  /// `information_schema` 取得。子查询均为单条语句,失败即抛出由界面展示错误。
  @override
  Future<DesignTable?> readTableDesign(String database, String table,
      {String? schema}) async {
    final conn = _get();
    final sch = _lit(schema ?? _schemaOrPublic);
    final tbl = _lit(table);
    final design = DesignTable()
      ..name = table
      ..schema = schema;

    // ── 列 ──────────────────────────────────────────────────
    // 类型取 format_type 原文(含长度 / 精度 / 数组维度);默认值取
    // pg_get_expr 原文(information_schema 会丢表达式细节);
    // attidentity: a = ALWAYS、d = BY DEFAULT、空 = 非 identity。
    final colResult = await conn.execute(
      'SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, '
      'pg_get_expr(d.adbin, d.adrelid), a.attidentity, '
      'col_description(a.attrelid, a.attnum), '
      '(SELECT collname FROM pg_collation WHERE oid = a.attcollation) '
      'FROM pg_attribute a '
      'JOIN pg_class cl ON cl.oid = a.attrelid '
      'JOIN pg_namespace nc ON nc.oid = cl.relnamespace '
      'LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum '
      'WHERE nc.nspname = $sch AND cl.relname = $tbl '
      'AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum',
    );
    for (final row in colResult) {
      final rawType = row[1]?.toString() ?? '';
      // 数组:格式为 `int4[]`,先剥维度标记再归一化类型名,维数单独回写
      final scalarType = rawType.replaceAll('[]', '');
      final dims = RegExp(r'\[\]').allMatches(rawType).length;
      final split = splitColumnType(scalarType);
      design.columns.add(
        DesignColumn(
          name: row[0]?.toString() ?? '',
          type: baseTypeOf(scalarType, _dialect),
          length: split.length,
          decimal: split.decimal,
          notNull: row[2] == true || row[2]?.toString() == 't',
          comment: row[5]?.toString() ?? '',
          // nextval / currval 默认值由 identity 建模承载,不重复写 DEFAULT
          defaultValue: normaliseDefault(row[3]?.toString(), _dialect) ?? '',
          dimension: dims == 0 ? '' : '$dims',
          collation: _collationOf(row[6]?.toString()),
          identityMode: switch (row[4]?.toString()) {
            'a' => 'ALWAYS',
            'd' => 'BY DEFAULT',
            _ => '',
          },
        ),
      );
    }

    // ── identity 序列选项 ────────────────────────────────────
    // pg_sequence 需 PG 10+,且需序列的读权限;失败只影响序列选项目展示,
    // 不能连带整个反查失败(退化为“仅不预填序列选项”)。
    if (design.columns.any((c) => c.hasIdentity)) {
      try {
        final seqResult = await conn.execute(
          'SELECT a.attname, q.seqincrement, q.seqstart, q.seqmin, q.seqmax, '
          'q.seqcache, q.seqcycle '
          'FROM pg_attribute a '
          'JOIN pg_class cl ON cl.oid = a.attrelid '
          'JOIN pg_namespace nc ON nc.oid = cl.relnamespace '
          'JOIN pg_sequence q ON q.seqrelid = to_regclass('
          "pg_get_serial_sequence(format('%I.%I', nc.nspname, cl.relname), "
          'a.attname)) '
          'WHERE nc.nspname = $sch AND cl.relname = $tbl '
          "AND a.attnum > 0 AND a.attidentity <> ''",
        );
        for (final row in seqResult) {
          final name = row[0]?.toString() ?? '';
          for (final col in design.columns) {
            if (col.name != name) continue;
            col.identityIncrement = _text(row[1]);
            col.identityStart = _text(row[2]);
            col.identityMinValue = _text(row[3]);
            col.identityMaxValue = _text(row[4]);
            col.identityCache = _text(row[5]);
            col.identityCycle = row[6] == true || row[6]?.toString() == 't';
          }
        }
      } catch (_) {
        // 序列选项读不到:保留 identity 模式,选项留空由服务端取默认
      }
    }

    // ── 约束(主键 / 唯一 / 外键 / 检查 / 排除) ──────────────
    final conResult = await conn.execute(
      'SELECT con.conname, con.contype, '
      "(SELECT string_agg(pa.attname, ',' ORDER BY k.ord) "
      'FROM generate_subscripts(con.conkey, 1) AS k(ord) '
      'JOIN pg_attribute pa ON pa.attrelid = con.conrelid '
      'AND pa.attnum = con.conkey[k.ord]), '
      "CASE WHEN con.contype = 'f' THEN "
      "(SELECT string_agg(ra.attname, ',' ORDER BY k.ord) "
      'FROM generate_subscripts(con.confkey, 1) AS k(ord) '
      'JOIN pg_attribute ra ON ra.attrelid = con.confrelid '
      'AND ra.attnum = con.confkey[k.ord]) END, '
      "CASE WHEN con.contype = 'f' THEN "
      '(SELECT rn.nspname FROM pg_class rc '
      'JOIN pg_namespace rn ON rn.oid = rc.relnamespace '
      'WHERE rc.oid = con.confrelid) END, '
      "CASE WHEN con.contype = 'f' THEN "
      '(SELECT rc.relname FROM pg_class rc WHERE rc.oid = con.confrelid) END, '
      'con.confdeltype, con.confupdtype, con.confmatchtype, '
      'con.condeferrable, con.condeferred, '
      "CASE WHEN con.contype IN ('c', 'x') THEN pg_get_constraintdef(con.oid) "
      'END, '
      // 约束注释(`COMMENT ON CONSTRAINT`):设计表的外键「注释」列需回显
      "shobj_description(con.oid, 'pg_constraint') "
      'FROM pg_constraint con '
      'JOIN pg_class cl ON cl.oid = con.conrelid '
      'JOIN pg_namespace nc ON nc.oid = cl.relnamespace '
      'WHERE nc.nspname = $sch AND cl.relname = $tbl ORDER BY con.conname',
    );
    final pkColumns = <String>{};
    for (final row in conResult) {
      final name = _text(row[0]);
      final type = _text(row[1]);
      final cols = _text(row[2]);
      switch (type) {
        case 'p':
          design.pkName = name;
          pkColumns.addAll(_nameList(cols));
        case 'u':
          design.uniqueKeys.add(DesignUniqueKey(
              name: name, columns: cols, comment: _text(row[12])));
        case 'f':
          design.foreignKeys.add(DesignForeignKey(
            name: name,
            columns: cols,
            refColumns: _text(row[3]),
            refSchema: _text(row[4]),
            refTable: _text(row[5]),
            onDelete: _fkAction(row[6]),
            onUpdate: _fkAction(row[7]),
            // confmatchtype: f = MATCH FULL、p = PARTIAL、s = SIMPLE(默认)
            matchAll: _text(row[8]) == 'f',
            deferrable: _text(row[9]).isEmpty
                ? ''
                : (_text(row[9]) == 't' ? 'YES' : 'NO'),
            deferred: _text(row[10]) == 't' ? 'YES' : 'NO',
            comment: _text(row[12]),
          ));
        case 'c':
          final def = _text(row[11]);
          design.checks.add(
            DesignCheck(
                name: name,
                expression: _checkExpr(def),
                comment: _text(row[12])),
          );
        case 'x':
          final def = _text(row[11]);
          final m = RegExp(r'^EXCLUDE\s+USING\s+(\w+)\s*\((.*)\)$',
                  caseSensitive: false)
              .firstMatch(def);
          design.excludes.add(DesignExclude(
            name: name,
            method: m?.group(1) ?? '',
            columns: m?.group(2) ?? def,
            comment: _text(row[12]),
          ));
      }
    }
    if (pkColumns.isNotEmpty) {
      for (final col in design.columns) {
        col.primaryKey = pkColumns.contains(col.name);
      }
    }

    // ── 索引(排除约束支撑的索引已由上面作为约束展示) ────────
    final idxResult = await conn.execute(
      'SELECT c.relname, am.amname, '
      "(SELECT string_agg(pg_get_indexdef(i.indexrelid, k.ord, true), ',' "
      'ORDER BY k.ord) FROM generate_subscripts(i.indkey, 1) AS k(ord)), '
      'i.indisunique, '
      "(SELECT split_part(o, '=', 2) FROM unnest(c.reloptions) AS o "
      "WHERE o LIKE 'fillfactor=%' LIMIT 1), "
      '(SELECT t2.spcname FROM pg_tablespace t2 WHERE t2.oid = c.reltablespace), '
      // 索引自己的注释(`COMMENT ON INDEX`)
      "obj_description(c.oid, 'pg_class') "
      'FROM pg_index i '
      'JOIN pg_class c ON c.oid = i.indexrelid '
      'JOIN pg_am am ON am.oid = c.relam '
      'JOIN pg_class t ON t.oid = i.indrelid '
      'JOIN pg_namespace nc ON nc.oid = t.relnamespace '
      'WHERE nc.nspname = $sch AND t.relname = $tbl '
      'AND NOT EXISTS (SELECT 1 FROM pg_constraint con '
      'WHERE con.conindid = i.indexrelid) ORDER BY c.relname',
    );
    for (final row in idxResult) {
      design.indexes.add(DesignIndex(
        name: _text(row[0]),
        method: _text(row[1]),
        columns: _text(row[2]),
        unique: row[3] == true || row[3]?.toString() == 't',
        fillFactor: _text(row[4]),
        tablespace: _text(row[5]),
        comment: _text(row[6]),
      ));
    }

    // ── 表注释与存储参数 ──────────────────────────────────
    // 表选项(relpersistence / owner / inherits / cluster)在编辑模式不可改,仍得
    // 回显:否则选项页看起来像“这张表没有所有者”。
    final tableResult = await conn.execute(
      'SELECT obj_description(c.oid), '
      "(SELECT split_part(o, '=', 2) FROM unnest(c.reloptions) AS o "
      "WHERE o LIKE 'fillfactor=%' LIMIT 1), "
      '(SELECT ts.spcname FROM pg_tablespace ts WHERE ts.oid = c.reltablespace), '
      "c.relpersistence, pg_get_userbyid(c.relowner), "
      "(SELECT string_agg(pn.nspname || '.' || pc.relname, ', ') "
      'FROM pg_inherits ih '
      'JOIN pg_class pc ON pc.oid = ih.inhparent '
      'JOIN pg_namespace pn ON pn.oid = pc.relnamespace '
      'WHERE ih.inhrelid = c.oid), '
      '(SELECT ic.relname FROM pg_index ci JOIN pg_class ic '
      'ON ic.oid = ci.indexrelid WHERE ci.indrelid = c.oid '
      'AND ci.indisclustered LIMIT 1) '
      'FROM pg_class c '
      'JOIN pg_namespace nc ON nc.oid = c.relnamespace '
      "WHERE nc.nspname = $sch AND c.relname = $tbl "
      "AND c.relkind IN ('r', 'p')",
    );
    if (tableResult.isNotEmpty) {
      final row = tableResult.first;
      design.tableComment = _text(row[0]);
      design.fillFactor = _text(row[1]);
      design.tablespace = _text(row[2]);
      // relpersistence: u = UNLOGGED、p = PERMANENT、t = TEMPORARY
      design.unlogged = _text(row[3]) == 'u';
      design.owner = _text(row[4]);
      design.inherits = _text(row[5]);
      design.cluster = _text(row[6]);
    }
    return design;
  }

  /// 设计器下拉候选:排序规则 / 运算符类别 / 表空间均直读系统目录。
  ///
  /// 三者都是实例级对象(不按库过滤);名称去重后按字典序返回,候选可达
  /// 上千行(ICU 排序规则),ComboBox 弹层为 `ListView.builder`,不致于卡顿。
  @override
  Future<DesignCandidates> readDesignCandidates(String database) async {
    final conn = _get();
    Future<List<String>> names(String sql) async {
      final rows = await conn.execute(sql);
      return [for (final row in rows) row[0]?.toString() ?? '']
          .where((e) => e.isNotEmpty)
          .toList();
    }

    return DesignCandidates(
      collations:
          await names('SELECT DISTINCT collname FROM pg_collation ORDER BY 1'),
      opClasses:
          await names('SELECT DISTINCT opcname FROM pg_opclass ORDER BY 1'),
      tablespaces:
          await names('SELECT spcname FROM pg_tablespace ORDER BY 1'),
    );
  }

  /// 标量值 → 字符串(null / 空统一为空串,供设计器“留空 = 不输出子句”)
  static String _text(Object? v) => v?.toString() ?? '';

  /// 逗号分隔的列名串 → 列表(pg_get_indexdef 己按标识符规则加引号)
  static List<String> _nameList(String s) => s
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .map((e) => e.replaceAll(RegExp(r'^"|"$'), '').replaceAll('""', '"'))
      .toList();

  /// 列使用了数据库默认排序规则时不回填(避免保存时多出 `COLLATE "default"`)
  static String _collationOf(String? v) {
    final s = v?.trim() ?? '';
    return (s.isEmpty || s == 'default') ? '' : s;
  }

  /// confdeltype / confupdtype 字母码 → SQL 动作关键字
  static String _fkAction(Object? v) => switch (_text(v)) {
        'a' => 'NO ACTION',
        'r' => 'RESTRICT',
        'c' => 'CASCADE',
        'n' => 'SET NULL',
        'd' => 'SET DEFAULT',
        _ => 'NO ACTION',
      };

  /// `CHECK ((expr))` → `expr`(保留内部的类型转换与括号)
  static String _checkExpr(String def) {
    var s = def.trim();
    if (s.length > 6 && s.substring(0, 6).toUpperCase() == 'CHECK ') {
      s = s.substring(6).trim();
    }
    return stripRedundantParens(s);
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
