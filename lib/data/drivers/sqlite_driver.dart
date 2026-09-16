import 'package:sqlite3/sqlite3.dart';

import '../db_data.dart';
import '../sql_row_cap.dart';
import '../table_design.dart';
import 'db_driver.dart';

/// SQLite 驱动(基于 sqlite3 FFI)。
///
/// SQLite 为文件型数据库,一个文件即一个"数据库";
/// [ConnectionInfo.host] 存储数据库文件路径。
class SqliteDriver implements DatabaseDriver {
  SqliteDriver(this._conn);

  final ConnectionInfo _conn;
  Database? _db;

  @override
  bool get isConnected => _db != null;

  @override
  Future<void> connect() async {
    if (_db != null) return;
    final path = _conn.host;
    if (path.isEmpty) {
      throw Exception('未指定 SQLite 数据库文件路径');
    }
    _db = sqlite3.open(path);
  }

  @override
  Future<void> close() async {
    _db?.dispose();
    _db = null;
  }

  Database _get() {
    if (_db == null) {
      throw Exception('SQLite 数据库未连接');
    }
    return _db!;
  }

  /// 双引号包裹标识符,防表名与关键字冲突
  String _quoted(String name) => '"${name.replaceAll('"', '""')}"';

  @override
  Future<List<String>> listDatabases() async {
    // SQLite 一个文件即一个数据库,返回文件名作为唯一"数据库"
    final path = _conn.host;
    if (path.isEmpty) return [];
    // 从路径中提取文件名
    final name = path.replaceAll('\\', '/').split('/').last;
    return [name];
  }

  @override
  Future<List<String>> listSchemas(String database) async {
    // SQLite 文件型数据库无模式层,返回空列表(树不渲染模式节点)
    return const [];
  }

  @override
  Future<List<String>> listTables(String database, {String? schema}) async {
    final db = _get();
    final result = db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    return [
      for (final row in result)
        if (row['name'] != null) row['name'].toString(),
    ];
  }

  @override
  Future<List<String>> listViews(String database, {String? schema}) async {
    final db = _get();
    final result = db.select(
      "SELECT name FROM sqlite_master WHERE type = 'view' ORDER BY name",
    );
    return [
      for (final row in result)
        if (row['name'] != null) row['name'].toString(),
    ];
  }

  @override
  Future<List<String>> listMaterializedViews(String database,
          {String? schema}) async =>
      const <String>[];

  @override
  Future<List<String>> listFunctions(String database, {String? schema}) async {
    // SQLite 的函数是宿主语言注册的 C 扩展,无法在库内枚举
    return const [];
  }

  @override
  Future<List<String>> listProcedures(String database, {String? schema}) async {
    // SQLite 无存储过程概念
    return const [];
  }

  @override
  Future<List<String>> listUsers(String database) async {
    // SQLite 为文件型数据库,无用户/角色管理
    return const [];
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
    final db = _get();
    final result = db.select(
      'SELECT * FROM ${_quoted(table)}'
      '${whereClauseSql(where)}${orderByClauseSql(orderBy)}'
      ' LIMIT $limit OFFSET $offset',
    );

    final columns = result.columnNames.toList();
    final rows = <List<String>>[];
    // nullMask 记录每格的原始 null 判定:展示层里真 NULL 与字符串 "NULL"
    // 都是 "NULL",导出 / 导入必须靠它区分
    final nullMask = <List<bool>>[];
    for (final row in result) {
      final cells = <String>[];
      final nulls = <bool>[];
      for (var i = 0; i < columns.length; i++) {
        final v = row.columnAt(i);
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
    final result = _get().select(
      'SELECT COUNT(*) AS cnt FROM ${_quoted(table)}${whereClauseSql(where)}',
    );
    return parseCountValue(result.first.columnAt(0));
  }

  @override
  Future<void> useDatabase(String database) async {
    // SQLite 单文件即一个库,无需切换
  }

  @override
  Future<void> useSchema(String? schema) {
    // SQLite 文件型数据库无模式概念,仅 PostgreSQL 家族支持;
    // UI 层按类型显隐,不会对其调用本方法
    throw UnsupportedError('该数据库类型不支持会话级模式切换');
  }

  @override
  Future<QueryResult> executeQuery(String sql, {int limit = 1000}) {
    final db = _get();
    // 封顶必须下推到服务端:sqlite3 的 select() 返回已物化的 ResultSet,
    // 在调用方 break 救不回来(详见 sql_row_cap.dart)
    final capped = capSelectSql(sql, maxRows: limit + 1);
    // select() 对任何返回行的语句都适用(含 RETURNING);
    // 纯写语句经 select() 得到空结果集,再用 updatedRows 补受影响行数
    final result = db.select(capped ?? sql);

    final columns = result.columnNames.toList();
    final rows = <List<String>>[];
    for (final row in result) {
      if (rows.length >= limit) break;
      rows.add([
        for (var i = 0; i < columns.length; i++)
          row.columnAt(i)?.toString() ?? 'NULL',
      ]);
    }
    return Future.value(QueryResult(
      columns: columns,
      rows: rows,
      affectedRows: columns.isEmpty ? db.updatedRows : 0,
      limit: limit,
      // 服务端只被允许返回 limit + 1 行,多出的那行即「还有更多」的确证
      moreRows: capped != null && result.length > limit,
    ));
  }

  @override
  Future<List<ColumnDef>> describeTable(String database, String table,
      {String? schema}) async {
    final db = _get();
    final result = db.select('PRAGMA table_info(${_quoted(table)})');
    return [
      for (final row in result)
        ColumnDef(
          name: row['name']?.toString() ?? '',
          type: row['type']?.toString() ?? '',
          nullable: row['notnull'] == 0 || row['notnull'] == false,
          primaryKey: row['pk'] == 1 || row['pk'] == true,
          defaultValue: row['dflt_value']?.toString(),
        ),
    ];
  }

  /// 「设计表」不支持编辑:SQLite 没有改列类型 / 重建约束的 ALTER 语法,
  /// 改列需重建表并搬数据(本次范围外)。返回 null 使界面转为只读展示。
  @override
  Future<DesignTable?> readTableDesign(String database, String table,
          {String? schema}) async =>
      null;

  /// 设计器下拉候选:SQLite 无排序规则 / 表空间目录(COLLATE 名仅为声明式字段),
  /// 返回空集使界面退化为手输。
  @override
  Future<DesignCandidates> readDesignCandidates(String database) async =>
      DesignCandidates.empty;

  @override
  Future<String?> getDefinition(String database, String name, String kind,
      {String? schema}) async {
    // SQLite 的函数是宿主语言注册的扩展,无法在库内枚举与定义
    if (kind != 'view') return null;
    final db = _get();
    final result = db.select(
      "SELECT sql FROM sqlite_master WHERE type = 'view' AND name = ?",
      [name],
    );
    if (result.isEmpty) return null;
    return result.first['sql']?.toString();
  }
}
