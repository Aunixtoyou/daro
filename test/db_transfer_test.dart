import 'dart:convert';
import 'dart:io';

import 'package:daro/data/csv_codec.dart';
import 'package:daro/data/db_export.dart';
import 'package:daro/data/db_import.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造一页数据:nulls[r][c] 为真表示该格是数据库 NULL(展示值写成 "NULL",
/// 与真 null 在 rows 里无法区分,正是 nullMask 要解决的场景)
TablePreview _page(
  List<String> columns,
  List<List<String>> rows, {
  List<List<bool>>? nulls,
  int limit = 1000,
}) =>
    TablePreview(
        columns: columns, rows: rows, limit: limit, nullMask: nulls);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('db_transfer'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('CSV 编码', () {
    test('分隔符 / 引号 / 换行一律加引号,内部引号双写', () {
      expect(
        csvEncodeRow(['a,b', 'c"d', 'e\nf', 'plain'], DelimitedStyle.standard),
        '"a,b","c""d","e\nf",plain',
      );
    });

    test('真 NULL 输出 nullAs,字符串 "NULL" 保持原值', () {
      final style = DelimitedStyle(nullAs: r'\N');
      final line = csvEncodeRow(['x', 'NULL'], style,
          nullFlags: [true, false]);
      expect(line, r'\N,NULL');
    });

    test('quoteAll 给所有字段加引号', () {
      expect(
        csvEncodeRow(['a', 'b'], DelimitedStyle.standard, quoteAll: true),
        '"a","b"',
      );
    });
  });

  group('CSV 增量解析', () {
    test('引号内的换行不算行结束', () {
      final d = CsvStreamDecoder(DelimitedStyle.standard);
      final out = <List<String>>[]
        ..addAll(d.feed('a,"b\nb",c\n'))
        ..addAll(d.feed('2,3,4'))
        ..addAll(d.flush());
      expect(out, [
        ['a', 'b\nb', 'c'],
        ['2', '3', '4']
      ]);
    });

    test('跨块的转义引号与半行正确拼接', () {
      final d = CsvStreamDecoder(DelimitedStyle.standard);
      final out = <List<String>>[]
        ..addAll(d.feed('x,"y"'))
        ..addAll(d.feed('"z",w'))
        ..addAll(d.feed('\r\nnext,2'));
      out.addAll(d.flush());
      expect(out, [
        ['x', 'y"z', 'w'],
        ['next', '2']
      ]);
    });

    test('CRLF 与分号分隔', () {
      final d = CsvStreamDecoder(DelimitedStyle.semicolon);
      final out = d.feed('a;b;c\r\nd;e;f\r\n');
      expect(out, [
        ['a', 'b', 'c'],
        ['d', 'e', 'f']
      ]);
    });

    test('跳过 UTF-8 BOM', () {
      final d = CsvStreamDecoder(DelimitedStyle.standard);
      expect(d.feed('\uFEFFa,b\n'), [
        ['a', 'b']
      ]);
    });
  });

  group('导出引擎', () {
    test('CSV:表头 + NULL 标记 + 多页拼接', () async {
      final path = '${tmp.path}/out.csv';
      final pages = [
        _page(['id', 'name'], [
          ['1', 'NULL'],
          ['2', 'NULL']
        ], nulls: [
          [false, true],
          [false, false]
        ], limit: 2),
        _page(['id', 'name'], [
          ['3', 'z']
        ], nulls: [
          [false, false]
        ], limit: 2),
      ];
      var call = 0;
      final r = await exportTable(
        target: const ExportTarget(
            typeId: 'mysql', database: 'd', table: 't'),
        request: DbExportRequest(
          format: DbExportFormat.csv,
          csv: const DelimitedStyle(nullAs: r'\N'),
          pageSize: 2,
        ),
        filePath: path,
        load: (limit, offset) async => pages[call++],
      );
      expect(r.ok, isTrue);
      expect(r.rowsWritten, 3);
      expect(File(path).readAsStringSync(), 'id,name\r\n1,\\N\r\n2,NULL\r\n3,z\r\n');
    });

    test('SQL:多值 INSERT 合并、单引号转义、NULL 关键字', () async {
      final path = '${tmp.path}/out.sql';
      final r = await exportTable(
        target: const ExportTarget(
            typeId: 'postgresql', database: 'd', table: 't'),
        request: DbExportRequest(
          format: DbExportFormat.sql,
          sql: const SqlExportOptions(insertBatchSize: 2),
          pageSize: 10,
        ),
        filePath: path,
        load: (limit, offset) async => _page(['id', "o'k"], [
          ['1', "a'b"],
          ['2', 'c'],
          ['3', 'd']
        ], nulls: [
          [false, false],
          [true, false],
          [false, false]
        ]),
      );
      expect(r.rowsWritten, 3);
      final sql = File(path).readAsStringSync();
      // 无模式限定:表标识符即 "t"(库由会话 search_path 定位);
      // 列标识符用双引号,内部单引号不转义('' 是字面量规则而非标识符规则)
      expect(sql, contains('INSERT INTO "t" ("id", "o\'k") VALUES '));
      expect(sql, contains("('1', 'a''b'), (NULL, 'c');"));
      expect(sql, contains("('3', 'd');"));
    });

    test('Access 目标退化为逐行 INSERT', () async {
      final path = '${tmp.path}/a.sql';
      await exportTable(
        target: const ExportTarget(
            typeId: 'access', database: 'd', table: 't'),
        request: DbExportRequest(
          format: DbExportFormat.sql,
          sql: const SqlExportOptions(insertBatchSize: 50),
        ),
        filePath: path,
        load: (limit, offset) async => _page(['id'], [
          ['1'],
          ['2']
        ], nulls: [
          [false],
          [false]
        ]),
      );
      final sql = File(path).readAsStringSync();
      expect('INSERT INTO'.allMatches(sql).length, 2);
    });

    test('JSON:对象数组,null 保真', () async {
      final path = '${tmp.path}/out.json';
      await exportTable(
        target: const ExportTarget(typeId: 'sqlite', database: 'd', table: 't'),
        request: const DbExportRequest(format: DbExportFormat.json),
        filePath: path,
        load: (limit, offset) async => _page(['id', 'name'], [
          ['1', 'NULL'],
          ['2', 'b']
        ], nulls: [
          [false, true],
          [false, false]
        ]),
      );
      final list = jsonDecode(File(path).readAsStringSync()) as List;
      expect(list.length, 2);
      expect(list[0], {'id': '1', 'name': null});
      expect(list[1], {'id': '2', 'name': 'b'});
    });

    test('取消:已写出行保留并标记 cancelled', () async {
      final path = '${tmp.path}/cancel.csv';
      final r = await exportTable(
        target: const ExportTarget(typeId: 'mysql', database: 'd', table: 't'),
        request: const DbExportRequest(format: DbExportFormat.csv, pageSize: 2),
        filePath: path,
        load: (limit, offset) async => _page(['id'], [
          ['1'],
          ['2']
        ], nulls: [
          [false],
          [false]
        ], limit: 2),
        isCancelled: () => true,
      );
      expect(r.cancelled, isTrue);
      // 取消在页写完(2 行)之后判定:已写出的内容保留
      expect(r.rowsWritten, 2);
    });
  });

  group('结果集导出(内存)', () {
    const target = ExportTarget(typeId: 'mysql', database: 'd', table: 't');

    test('行数超过 pageSize 也不会重复取页', () async {
      final path = '${tmp.path}/rows.csv';
      final data = _page(['id', 'name'], [
        ['1', 'a'],
        ['2', 'b'],
        ['3', 'c']
      ]);
      final r = await exportRows(
        target: target,
        request: const DbExportRequest(
            format: DbExportFormat.csv, pageSize: 2),
        data: data,
        filePath: path,
      );
      expect(r.ok, isTrue);
      expect(r.rowsWritten, 3);
      expect(
        File(path).readAsStringSync(),
        'id,name\r\n1,a\r\n2,b\r\n3,c\r\n',
      );
    });

    test('空结果集:CSV 只写表头,JSON 写空数组', () async {
      final csvPath = '${tmp.path}/empty.csv';
      final jsonPath = '${tmp.path}/empty.json';
      final none = _page(['id', 'name'], const []);
      await exportRows(
        target: target,
        request: const DbExportRequest(format: DbExportFormat.csv),
        data: none,
        filePath: csvPath,
      );
      await exportRows(
        target: target,
        request: const DbExportRequest(format: DbExportFormat.json),
        data: none,
        filePath: jsonPath,
      );
      expect(File(csvPath).readAsStringSync(), 'id,name\r\n');
      expect(File(jsonPath).readAsStringSync(), '[]');
    });

    test('驱动未给 nullMask 时按展示约定把值 "NULL" 当作空', () async {
      final path = '${tmp.path}/convention.csv';
      await exportRows(
        target: target,
        request: const DbExportRequest(
            format: DbExportFormat.csv,
            csv: DelimitedStyle(nullAs: r'\N'),
            pageSize: 10),
        data: _page(['v'], [
          ['NULL'],
          ['x']
        ]),
        filePath: path,
      );
      expect(File(path).readAsStringSync(), 'v\r\n\\N\r\nx\r\n');
    });

    test('CSV BOM 开关', () async {
      final path = '${tmp.path}/bom.csv';
      await exportRows(
        target: target,
        request: const DbExportRequest(
            format: DbExportFormat.csv, csvBom: true, pageSize: 10),
        data: _page(['id'], [
          ['1']
        ]),
        filePath: path,
      );
      final bytes = File(path).readAsBytesSync();
      expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      expect(utf8.decode(bytes.sublist(3)), 'id\r\n1\r\n');
    });
  });

  group('导入引擎', () {
    test('预览:表头 + 样本行', () async {
      final path = '${tmp.path}/in.csv';
      File(path).writeAsStringSync('id,name\r\n1,"a,b"\r\n2,c\r\n');
      final src = await readImportSample(path, const DbImportRequest());
      expect(src.headers, ['id', 'name']);
      expect(src.sample, [
        ['1', 'a,b'],
        ['2', 'c']
      ]);
    });

    test('预览:无表头时用列序号占位', () async {
      final path = '${tmp.path}/in2.csv';
      File(path).writeAsStringSync('1,x\r\n2,y\r\n');
      final src = await readImportSample(
          path, const DbImportRequest(hasHeader: false));
      expect(src.headers, ['列1', '列2']);
      expect(src.sample.length, 2);
    });

    test('批量 INSERT:每批一条语句,值按 NULL 选项处理', () async {
      final path = '${tmp.path}/batch.csv';
      File(path).writeAsStringSync('id,name\r\n1,a\r\n2,\r\n3,c\r\n');
      final sqls = <String>[];
      final r = await importTable(
        filePath: path,
        request: const DbImportRequest(batchSize: 2),
        mapping: const [
          ImportColumn(targetColumn: 'id', typeLabel: 'int', sourceIndex: 0),
          ImportColumn(targetColumn: 'name', typeLabel: 'text', sourceIndex: 1),
        ],
        typeId: 'mysql',
        database: 'db',
        table: 't',
        execute: (sql) async => sqls.add(sql),
      );
      expect(r.rowsRead, 3);
      expect(r.rowsInserted, 3);
      expect(sqls.length, 2);
      // MySQL 无模式层:表标识符不带库名,由会话 USE 定位
      expect(sqls[0], "INSERT INTO `t` (`id`, `name`) VALUES ('1', 'a'), ('2', NULL);");
      expect(sqls[1], "INSERT INTO `t` (`id`, `name`) VALUES ('3', 'c');");
    });

    test('未映射列跳过;清空表先行', () async {
      final path = '${tmp.path}/skip.csv';
      File(path).writeAsStringSync('id,ignored\r\n1,junk\r\n');
      final sqls = <String>[];
      await importTable(
        filePath: path,
        request: const DbImportRequest(truncateFirst: true),
        mapping: const [
          ImportColumn(targetColumn: 'id', typeLabel: 'int', sourceIndex: 0),
          ImportColumn(targetColumn: 'extra', typeLabel: 'text'),
        ],
        typeId: 'postgresql',
        database: 'db',
        table: 't',
        schema: 'public',
        execute: (sql) async => sqls.add(sql),
      );
      expect(sqls[0], 'DELETE FROM "public"."t"');
      expect(sqls[1], 'INSERT INTO "public"."t" ("id") VALUES (\'1\');');
    });

    test('Access 目标:即使 batchSize 很大也逐行 INSERT', () async {
      final path = '${tmp.path}/access.csv';
      File(path).writeAsStringSync('id\r\n1\r\n2\r\n3\r\n');
      final sqls = <String>[];
      final r = await importTable(
        filePath: path,
        request: const DbImportRequest(batchSize: 100),
        mapping: const [
          ImportColumn(targetColumn: 'id', typeLabel: 'int', sourceIndex: 0),
        ],
        typeId: 'access',
        database: 'db',
        table: 't',
        execute: (sql) async => sqls.add(sql),
      );
      expect(r.rowsInserted, 3);
      expect(sqls.length, 3);
      expect(sqls[0], r"INSERT INTO [t] ([id]) VALUES ('1');");
    });

    test('批次失败:记录错误、继续后续批次、成功行数只计已提交', () async {
      final path = '${tmp.path}/fail.csv';
      File(path).writeAsStringSync('id\r\n1\r\n2\r\n3\r\n4\r\n5\r\n');
      var batch = 0;
      final r = await importTable(
        filePath: path,
        request: const DbImportRequest(batchSize: 2),
        mapping: const [
          ImportColumn(targetColumn: 'id', typeLabel: 'int', sourceIndex: 0),
        ],
        typeId: 'mysql',
        database: 'db',
        table: 't',
        execute: (sql) async {
          batch++;
          if (batch == 2) throw Exception('约束冲突');
        },
      );
      expect(r.rowsRead, 5);
      expect(r.failedBatches, 1);
      expect(r.rowsInserted, 3);
      expect(r.errors.single, contains('约束冲突'));
      expect(r.ok, isFalse);
    });

    test('JSON 对象数组导入:按首条键顺序对齐', () async {
      final path = '${tmp.path}/in.json';
      File(path).writeAsStringSync(
          '[{"id":"1","name":"a"},{"id":"2","name":null}]');
      final sqls = <String>[];
      final src = await readImportSample(path,
          const DbImportRequest(format: DbImportFormat.json));
      expect(src.headers, ['id', 'name']);
      final r = await importTable(
        filePath: path,
        request: const DbImportRequest(format: DbImportFormat.json),
        mapping: const [
          ImportColumn(targetColumn: 'id', typeLabel: 'int', sourceIndex: 0),
          ImportColumn(targetColumn: 'name', typeLabel: 'text', sourceIndex: 1),
        ],
        typeId: 'sqlite',
        database: 'db',
        table: 't',
        execute: (sql) async => sqls.add(sql),
      );
      expect(r.rowsInserted, 2);
      expect(sqls.single, 'INSERT INTO "t" ("id", "name") VALUES '
          '(\'1\', \'a\'), (\'2\', NULL);');
    });

    test('行宽不齐:缺列补空、多列截断', () async {
      final path = '${tmp.path}/ragged.csv';
      File(path).writeAsStringSync('id,name\r\n1\r\n2,b,extra\r\n');
      final src = await readImportSample(path, const DbImportRequest());
      expect(src.warning, isNotNull);
      expect(src.sample, [
        ['1', ''],
        ['2', 'b']
      ]);
    });
  });
}
