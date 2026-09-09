/// 数据导出的格式定义与**流式**写出引擎。
///
/// 引擎不直接依赖 AppState / ConnectionManager:分页取数由调用方以
/// [ExportPageLoader] 注入,写出目标由 [File] 提供,因此可脱离 UI 单测。
/// 每一页取到后立即编码并写入 [IOSink],内存占用与表大小无关。
library;

import 'dart:convert';
import 'dart:io';

import 'csv_codec.dart';
import 'drivers/db_driver.dart';
import 'table_design.dart';

/// 导出格式
enum DbExportFormat { csv, sql, json }

/// 导出格式的展示名(向导选项)
String dbExportFormatLabel(DbExportFormat f) => switch (f) {
      DbExportFormat.csv => 'CSV / 文本',
      DbExportFormat.sql => 'SQL (INSERT)',
      DbExportFormat.json => 'JSON',
    };

/// 导出格式的默认文件扩展名
String dbExportFormatExt(DbExportFormat f) => switch (f) {
      DbExportFormat.csv => 'csv',
      DbExportFormat.sql => 'sql',
      DbExportFormat.json => 'json',
    };

/// SQL 导出选项
class SqlExportOptions {
  const SqlExportOptions({
    this.dropStatement = false,
    this.createStatement = false,
    this.insertBatchSize = 50,
  });

  /// 是否在结构前输出 DROP TABLE IF EXISTS
  final bool dropStatement;

  /// 是否包含建表语句(CREATE TABLE)
  final bool createStatement;

  /// 每条 INSERT 合并的行数(多值 VALUES);1 表示逐行 INSERT
  final int insertBatchSize;
}

/// JSON 导出选项
class JsonExportOptions {
  const JsonExportOptions({this.pretty = false});

  /// 是否缩进美化(大表下文件显著变大)
  final bool pretty;
}

/// 一次导出请求的完整配置
class DbExportRequest {
  const DbExportRequest({
    required this.format,
    this.csv = const DelimitedStyle(),
    this.csvQuoteAll = false,
    this.csvWithHeader = true,
    this.csvBom = false,
    this.sql = const SqlExportOptions(),
    this.json = const JsonExportOptions(),
    this.pageSize = 2000,
    this.createDdl,
  });

  final DbExportFormat format;

  /// CSV 分隔风格(含 NULL 输出文本)
  final DelimitedStyle csv;

  /// CSV 是否给所有字段加引号
  final bool csvQuoteAll;

  /// CSV 首行是否输出列名
  final bool csvWithHeader;

  /// CSV 是否写入 UTF-8 BOM(便于 Excel 直接双击识别中文)
  final bool csvBom;

  final SqlExportOptions sql;
  final JsonExportOptions json;

  /// 每次向数据库取数的行数
  final int pageSize;

  /// 建表语句文本(仅 [SqlExportOptions.createStatement] 为真时使用),
  /// 由调用方经 AppState 的转储逻辑生成
  final String? createDdl;

  /// 覆盖部分选项生成新请求(AppState 注入动态生成的 createDdl)
  DbExportRequest copyWith({String? createDdl}) => DbExportRequest(
        format: format,
        csv: csv,
        csvQuoteAll: csvQuoteAll,
        csvWithHeader: csvWithHeader,
        csvBom: csvBom,
        sql: sql,
        json: json,
        pageSize: pageSize,
        createDdl: createDdl ?? this.createDdl,
      );
}

/// 导出目标表标识
class ExportTarget {
  const ExportTarget({
    required this.typeId,
    required this.database,
    required this.table,
    this.schema,
  });

  final String typeId;
  final String database;
  final String table;
  final String? schema;

  /// 带模式限定的表标识符
  String get ident => DdlBuilder.qualified(typeId, schema, table);

  /// 建议文件名用的表名(去掉路径非法字符)
  String get safeName => table.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
}

/// 分页取数回调:返回从 [offset] 开始的至多 [limit] 行
typedef ExportPageLoader = Future<TablePreview> Function(int limit, int offset);

/// 导出执行结果
class ExportResult {
  const ExportResult({
    required this.rowsWritten,
    this.error,
    this.cancelled = false,
  });

  /// 已写出的行数
  final int rowsWritten;

  /// 失败原因(null 表示成功)
  final String? error;

  /// 用户中途取消(已写出的内容保留)
  final bool cancelled;

  bool get ok => error == null;
}

/// 把一张表导出到 [filePath]。
///
/// [load] 负责按 (limit, offset) 取数;调用方须保证分页顺序稳定
/// (AppState 的封装按主键、无主键时按全部列 ORDER BY)。
/// [onProgress] 每页回调一次(已完成行数, 总行数或 -1 表示未知)。
Future<ExportResult> exportTable({
  required ExportTarget target,
  required DbExportRequest request,
  required ExportPageLoader load,
  required String filePath,
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final sink = File(filePath).openWrite();
  final writer = _FormatWriter.create(target, request);
  var done = 0;
  try {
    if (request.format == DbExportFormat.csv && request.csvBom) {
      sink.add(const [0xEF, 0xBB, 0xBF]);
    }
    var page = await load(request.pageSize, 0);
    writer.begin(sink, page.columns);
    while (page.columns.isNotEmpty && page.rows.isNotEmpty) {
      writer.writeRows(sink, page);
      done += page.rows.length;
      onProgress?.call(done, -1);
      if (page.rows.length < request.pageSize) break;
      if (isCancelled?.call() ?? false) {
        writer.end(sink);
        return ExportResult(rowsWritten: done, cancelled: true);
      }
      page = await load(request.pageSize, done);
    }
    writer.end(sink);
    return ExportResult(rowsWritten: done);
  } catch (e) {
    return ExportResult(rowsWritten: done, error: e.toString());
  } finally {
    await sink.close();
  }
}

/// 把已在内存中的结果集一次写出到 [filePath]。
///
/// 用于查询页结果网格:数据已经全部取回,不需要分页取数、进度与取消,
/// 因此直接复用 [exportTable] 的编码与写出逻辑 —— 分页回调只在第一页
/// 返回全部数据,其后返回空页让引擎正常收尾。
///
/// 注意 SQL(INSERT) 格式需要真实目标表,结果集导出只应提供 CSV / JSON。
Future<ExportResult> exportRows({
  required ExportTarget target,
  required DbExportRequest request,
  required TablePreview data,
  required String filePath,
}) =>
    exportTable(
      target: target,
      request: request,
      filePath: filePath,
      load: (limit, offset) async => offset == 0
          ? data
          : const TablePreview(columns: [], rows: []),
    );

/// 各格式的写出器:begin 写文件头,end 收尾(缓冲区落盘由 IOSink 负责)
abstract class _FormatWriter {
  static _FormatWriter create(ExportTarget target, DbExportRequest req) {
    switch (req.format) {
      case DbExportFormat.csv:
        return _CsvWriter(req);
      case DbExportFormat.sql:
        return _SqlWriter(target, req);
      case DbExportFormat.json:
        return _JsonWriter(req);
    }
  }

  void begin(IOSink sink, List<String> columns);
  void writeRows(IOSink sink, TablePreview page);
  void end(IOSink sink);
}

class _CsvWriter implements _FormatWriter {
  _CsvWriter(this._req);

  final DbExportRequest _req;

  @override
  void begin(IOSink sink, List<String> columns) {
    if (_req.csvWithHeader) {
      sink.write(csvEncodeRow(columns, _req.csv) + _req.csv.eol);
    }
  }

  @override
  void writeRows(IOSink sink, TablePreview page) {
    for (var r = 0; r < page.rows.length; r++) {
      final cells = page.rows[r];
      final nulls = [
        for (var c = 0; c < cells.length; c++) page.isNullAt(r, c)
      ];
      sink.write(
        csvEncodeRow(cells, _req.csv,
            quoteAll: _req.csvQuoteAll, nullFlags: nulls) +
            _req.csv.eol,
      );
    }
  }

  @override
  void end(IOSink sink) {}
}

class _SqlWriter implements _FormatWriter {
  _SqlWriter(this._target, this._req);

  final ExportTarget _target;
  final DbExportRequest _req;
  List<String> _columns = const [];

  /// 待合并进一条 INSERT 的 VALUES 元组
  final List<String> _tuples = [];

  /// Jet(ODBC)不支持多值 VALUES,退化为逐行 INSERT
  int get _batchSize => _target.typeId == 'access'
      ? 1
      : (_req.sql.insertBatchSize < 1 ? 1 : _req.sql.insertBatchSize);

  /// 列清单前缀:`INSERT INTO t ("a", "b") VALUES `
  String get _insertPrefix {
    final cols = _columns
        .map((c) => DdlBuilder.ident(_target.typeId, c))
        .join(', ');
    return 'INSERT INTO ${_target.ident} ($cols) VALUES ';
  }

  @override
  void begin(IOSink sink, List<String> columns) {
    _columns = columns;
    final t = _target;
    final db = t.schema == null || t.schema!.isEmpty
        ? t.database
        : '${t.database}.${t.schema}';
    sink
      ..writeln('-- ============================================')
      ..writeln('-- daro 数据导出')
      ..writeln('-- 目标表: $db.${t.table}')
      ..writeln('-- 生成时间: ${DateTime.now().toIso8601String()}')
      ..writeln('-- ============================================')
      ..writeln();
    if (_req.sql.createStatement && _req.createDdl != null) {
      if (_req.sql.dropStatement) {
        sink.writeln('DROP TABLE IF EXISTS ${t.ident};');
        sink.writeln();
      }
      sink
        ..writeln(_req.createDdl!.trim())
        ..writeln();
    }
  }

  @override
  void writeRows(IOSink sink, TablePreview page) {
    for (var r = 0; r < page.rows.length; r++) {
      final cells = page.rows[r];
      final buf = StringBuffer('(');
      for (var c = 0; c < cells.length; c++) {
        if (c > 0) buf.write(', ');
        buf.write(page.isNullAt(r, c) ? 'NULL' : DdlBuilder.lit(cells[c]));
      }
      buf.write(')');
      _tuples.add(buf.toString());
      if (_tuples.length >= _batchSize) _flush(sink);
    }
  }

  void _flush(IOSink sink) {
    if (_tuples.isEmpty) return;
    sink.writeln('${_insertPrefix}${_tuples.join(', ')};');
    _tuples.clear();
  }

  @override
  void end(IOSink sink) => _flush(sink);
}

class _JsonWriter implements _FormatWriter {
  _JsonWriter(this._req);

  final DbExportRequest _req;
  List<String> _columns = const [];
  bool _wroteAny = false;

  @override
  void begin(IOSink sink, List<String> columns) {
    _columns = columns;
    sink.write('[');
    if (_req.json.pretty) sink.write('\n');
  }

  @override
  void writeRows(IOSink sink, TablePreview page) {
    for (var r = 0; r < page.rows.length; r++) {
      final map = <String, Object?>{};
      final cells = page.rows[r];
      for (var c = 0; c < _columns.length; c++) {
        map[_columns[c]] =
            (c < cells.length && !page.isNullAt(r, c)) ? cells[c] : null;
      }
      if (_wroteAny) sink.write(',');
      sink.write(_req.json.pretty ? '\n  ' : '');
      sink.write(jsonEncode(map));
      _wroteAny = true;
    }
  }

  @override
  void end(IOSink sink) {
    sink
      ..write(_wroteAny && _req.json.pretty ? '\n]' : ']')
      ..write(_req.json.pretty ? '\n' : '');
  }
}
