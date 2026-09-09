/// 数据导入:源文件解析(CSV / JSON)、字段映射与批量 INSERT。
///
/// 与导出引擎对称:解析与 SQL 组装在此完成,写库由调用方注入 [SqlExecutor],
/// 故本文件不依赖 AppState / ConnectionManager,可脱离 UI 单测。
/// 只有一条解析管线 [importRows]:跳过行、表头、字段修剪都在管线内处理,
/// 预览与实际导入共用,保证「预览即所导」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'csv_codec.dart';
import 'table_design.dart';

/// 导入源格式
enum DbImportFormat { csv, json }

String dbImportFormatLabel(DbImportFormat f) => switch (f) {
      DbImportFormat.csv => 'CSV / 文本',
      DbImportFormat.json => 'JSON',
    };

/// 单条 SQL 的执行回调(由 AppState 桥接到 ConnectionManager)
typedef SqlExecutor = Future<void> Function(String sql);

/// 一次导入请求的配置
class DbImportRequest {
  const DbImportRequest({
    this.format = DbImportFormat.csv,
    this.style = const DelimitedStyle(),
    this.hasHeader = true,
    this.skipRows = 0,
    this.trimFields = false,
    this.emptyAsNull = true,
    this.batchSize = 200,
    this.truncateFirst = false,
  });

  final DbImportFormat format;

  /// CSV 分隔风格;其 [DelimitedStyle.nullAs] 为识别为 NULL 的文本
  final DelimitedStyle style;

  /// 首行(跳行之后)是否为列名
  final bool hasHeader;

  /// 起始跳过的行数(在表头判定之前生效)
  final int skipRows;

  /// 是否去除字段首尾空白
  final bool trimFields;

  /// 空字段是否导入为 NULL(false 时按空串写入)
  final bool emptyAsNull;

  /// 每条 INSERT 合并的行数
  final int batchSize;

  /// 导入前清空目标表(DELETE FROM,各方言通用)
  final bool truncateFirst;

  /// 同参数换格式(向导切换格式时保留其它选项)
  DbImportRequest copyWith({DbImportFormat? format}) => DbImportRequest(
        format: format ?? this.format,
        style: style,
        hasHeader: hasHeader,
        skipRows: skipRows,
        trimFields: trimFields,
        emptyAsNull: emptyAsNull,
        batchSize: batchSize,
        truncateFirst: truncateFirst,
      );
}

/// 源文件结构:列标题 + 预览数据行 + 解析告警
class ImportSource {
  const ImportSource({
    required this.headers,
    required this.sample,
    this.warning,
  });

  /// 列标题(来自表头行;无表头时为「列1 / 列2」占位)
  final List<String> headers;

  /// 预览数据行
  final List<List<String>> sample;

  /// 解析告警(行列数不一致等),null 表示无
  final String? warning;
}

/// 一个目标列的导入映射。
/// [sourceIndex] 为 -1 表示该列不参与导入(由数据库默认值填充)。
class ImportColumn {
  const ImportColumn({
    required this.targetColumn,
    required this.typeLabel,
    this.sourceIndex = -1,
    this.nullable = true,
  });

  final String targetColumn;

  /// 目标列类型展示文本(映射表格里提示用户)
  final String typeLabel;

  final int sourceIndex;

  final bool nullable;

  ImportColumn withSource(int sourceIndex) => ImportColumn(
        targetColumn: targetColumn,
        typeLabel: typeLabel,
        sourceIndex: sourceIndex,
        nullable: nullable,
      );
}

/// 导入执行结果
class ImportResult {
  const ImportResult({
    required this.rowsInserted,
    required this.rowsRead,
    required this.failedBatches,
    this.errors = const [],
    this.cancelled = false,
  });

  /// 成功写入的行数(失败批次按整批未写入计)
  final int rowsInserted;

  /// 从源文件读取的数据行数
  final int rowsRead;

  final int failedBatches;

  /// 前 [ImportResult.maxErrorsKept] 条错误信息
  final List<String> errors;

  final bool cancelled;

  /// 保留的错误条数上限(大文件下防止无界增长)
  static const int maxErrorsKept = 20;

  bool get ok => failedBatches == 0 && !cancelled;
}

/// 解析源文件的**数据行**(已应用 skipRows / 表头剥离 / 字段修剪)。
///
/// [onBytes] 回调累计已消费字节数,供向导按文件体积算进度百分比
/// (避免为统计总行数而把文件解析两遍)。
Stream<List<String>> importRows(
  String filePath,
  DbImportRequest request, {
  void Function(int bytesDone)? onBytes,
}) async* {
  final file = File(filePath);
  var skipped = 0;
  var headerTaken = false;

  await for (final raw in _rawRecords(file, request, onBytes)) {
    final cells = [
      for (final c in raw) request.trimFields ? c.trim() : c,
    ];
    if (skipped < request.skipRows) {
      skipped++;
      continue;
    }
    if (!headerTaken && request.hasHeader) {
      headerTaken = true;
      continue;
    }
    headerTaken = true;
    yield cells;
  }
}

/// 生成「原始记录」流:CSV 逐块增量解析;JSON 顶层对象数组时
/// 先取首条记录的键序列作为隐式表头,再把每条记录转成值列表。
///
/// [onBytes] 在**字节流**上累计消费进度,口径与 File.length() 一致。
Stream<List<String>> _rawRecords(
  File file,
  DbImportRequest request,
  void Function(int bytesDone)? onBytes,
) {
  var consumed = 0;
  final bytes = file.openRead().map((chunk) {
    consumed += chunk.length;
    onBytes?.call(consumed);
    return chunk;
  });
  return request.format == DbImportFormat.json
      ? _jsonRecords(bytes, request)
      : _csvRecords(bytes, request);
}

Stream<List<String>> _csvRecords(
  Stream<List<int>> bytes,
  DbImportRequest request,
) async* {
  final decoder = CsvStreamDecoder(request.style);
  // utf8.decoder 是分块转换器,能正确跨块拼接多字节字符(中文安全)
  await for (final chunk in bytes.transform(utf8.decoder)) {
    for (final r in decoder.feed(chunk)) {
      yield r;
    }
  }
  for (final r in decoder.flush()) {
    yield r;
  }
}

Stream<List<String>> _jsonRecords(
  Stream<List<int>> bytes,
  DbImportRequest request,
) async* {
  final buf = StringBuffer();
  await for (final chunk in bytes.transform(utf8.decoder)) {
    buf.write(chunk);
  }
  var text = buf.toString();
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
    text = text.substring(1);
  }
  final dynamic value = jsonDecode(text.isEmpty ? '[]' : text);
  if (value is! List) {
    throw const FormatException('JSON 顶层必须是数组(对象数组或二维数组)');
  }
  // 对象数组的各条记录键集合可能不同:以首条记录的键顺序为隐式表头,
  // 先产出键名行(与 CSV 表头同构),其后记录一律按该顺序对齐取值
  List<String>? keys;
  for (final item in value) {
    if (item is List) {
      yield [for (final v in item) _jsonCell(v)];
    } else if (item is Map) {
      if (keys == null) {
        keys = [for (final k in item.keys) '$k'];
        yield keys;
      }
      yield [for (final k in keys) _jsonCell(item[k])];
    }
  }
}

String _jsonCell(Object? v) => v == null ? '' : '$v';

/// 读取源文件的列标题与前 [sampleRows] 行数据,供向导预览与映射。
Future<ImportSource> readImportSample(
  String filePath,
  DbImportRequest request, {
  int sampleRows = 20,
}) async {
  List<String>? headers;
  final sample = <List<String>>[];
  var ragged = false;
  final records = <List<String>>[];

  // 标题来源:CSV 走原始记录的第一行(可能是表头),JSON 对象数组走键序列
  await for (final raw in _rawRecords(File(filePath), request, null)) {
    records.add([for (final c in raw) request.trimFields ? c.trim() : c]);
    if (records.length >= sampleRows + 2) break;
  }
  var idx = 0;
  for (; idx < request.skipRows && idx < records.length; idx++) {}
  if (request.hasHeader && idx < records.length) {
    headers = records[idx];
    idx++;
  } else {
    headers = const [];
  }
  for (; idx < records.length && sample.length < sampleRows; idx++) {
    final row = records[idx];
    if (headers.isNotEmpty && row.length != headers.length) ragged = true;
    sample.add(row);
  }
  final width = [
    headers.length,
    for (final r in sample) r.length,
  ].reduce((a, b) => a > b ? a : b);
  final finalHeaders = headers.isEmpty
      ? [for (var i = 0; i < width; i++) '列${i + 1}']
      : headers;
  return ImportSource(
    headers: finalHeaders,
    sample: [
      for (final r in sample) _fitWidth(r, finalHeaders.length),
    ],
    warning: ragged ? '存在列数与表头不一致的行,已按表头宽度补齐 / 截断' : null,
  );
}

List<String> _fitWidth(List<String> row, int width) {
  if (row.length == width) return row;
  if (row.length < width) {
    return [...row, ...List<String>.filled(width - row.length, '')];
  }
  return row.sublist(0, width);
}

/// 按映射把源文件导入目标表。
///
/// [mapping] 为目标表列顺序的映射列表;仅 sourceIndex >= 0 的列参与写入。
/// [onProgress] 回调(已读行, 已写字节, 文件字节总数或 -1)。
Future<ImportResult> importTable({
  required String filePath,
  required DbImportRequest request,
  required List<ImportColumn> mapping,
  required String typeId,
  required String database,
  required String table,
  String? schema,
  required SqlExecutor execute,
  void Function(int rowsDone, int bytesDone, int totalBytes)? onProgress,
  bool Function()? isCancelled,
}) async {
  final enabled = mapping.where((m) => m.sourceIndex >= 0).toList();
  if (enabled.isEmpty) {
    return const ImportResult(
      rowsInserted: 0,
      rowsRead: 0,
      failedBatches: 1,
      errors: ['未选中任何可导入的列'],
    );
  }
  final totalBytes = await File(filePath).length();
  final target = DdlBuilder.qualified(typeId, schema, table);
  final colIdents =
      enabled.map((m) => DdlBuilder.ident(typeId, m.targetColumn)).join(', ');
  final insertPrefix = 'INSERT INTO $target ($colIdents) VALUES ';
  // Jet(ODBC)不支持多值 VALUES,退化为逐行 INSERT(与导出引擎一致)
  final batchSize =
      typeId == 'access' ? 1 : (request.batchSize < 1 ? 1 : request.batchSize);

  var rowsRead = 0;
  var rowsInserted = 0;
  var failedBatches = 0;
  var cancelled = false;
  var bytesDone = 0;
  final errors = <String>[];
  final batch = <String>[];

  if (request.truncateFirst) {
    try {
      await execute('DELETE FROM $target');
    } catch (e) {
      return ImportResult(
        rowsInserted: 0,
        rowsRead: 0,
        failedBatches: 1,
        errors: ['清空目标表失败: $e'],
      );
    }
  }

  Future<void> flush() async {
    if (batch.isEmpty) return;
    final sql = '$insertPrefix${batch.join(', ')};';
    final from = rowsRead - batch.length + 1;
    final size = batch.length;
    batch.clear();
    try {
      await execute(sql);
      rowsInserted += size;
    } catch (e) {
      failedBatches++;
      if (errors.length < ImportResult.maxErrorsKept) {
        errors.add('第 $from~$rowsRead 行: $e');
      }
    }
  }

  await for (final cells in importRows(filePath, request,
      onBytes: (b) => bytesDone = b)) {
    if (isCancelled?.call() ?? false) {
      cancelled = true;
      break;
    }
    final tuple = StringBuffer('(');
    for (var i = 0; i < enabled.length; i++) {
      if (i > 0) tuple.write(', ');
      final src = enabled[i].sourceIndex;
      final value = src < cells.length ? cells[src] : '';
      tuple.write(_cellLiteral(value, request));
    }
    tuple.write(')');
    batch.add(tuple.toString());
    rowsRead++;
    if (batch.length >= batchSize) {
      await flush();
      onProgress?.call(rowsRead, bytesDone, totalBytes);
    }
  }
  if (batch.isNotEmpty && !cancelled) await flush();
  onProgress?.call(rowsRead, bytesDone, totalBytes);

  return ImportResult(
    rowsInserted: rowsInserted,
    rowsRead: rowsRead,
    failedBatches: failedBatches,
    errors: errors,
    cancelled: cancelled,
  );
}

/// 单元格 → SQL 字面量:命中 NULL 标记或(按选项)空串时输出 NULL
String _cellLiteral(String cell, DbImportRequest request) {
  if (request.style.nullAs.isNotEmpty && cell == request.style.nullAs) {
    return 'NULL';
  }
  if (cell.isEmpty && request.emptyAsNull) return 'NULL';
  return DdlBuilder.lit(cell);
}
