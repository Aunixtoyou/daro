import 'dart:convert';
import 'dart:io';

import 'package:daro/data/sql_file_run.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUpAll(() => dir = Directory.systemTemp.createTempSync('sql_run_test'));
  tearDownAll(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 测试进程退出时系统会清理临时目录
    }
  });

  /// 把 [text] 写成临时 .sql 文件并返回路径(测试里要真实走文件流)
  String write(String name, String text) {
    final file = File('${dir.path}/$name');
    file.writeAsStringSync(text);
    return file.path;
  }

  group('runSqlFile', () {
    test('按顺序执行全部语句', () async {
      final path = write('ok.sql', 'CREATE TABLE a (id int);\n'
          "INSERT INTO a VALUES (1);\nSELECT * FROM a;");
      final log = <String>[];
      final result =
          await runSqlFile(filePath: path, execute: (sql) async => log.add(sql));
      expect(log, [
        'CREATE TABLE a (id int)',
        'INSERT INTO a VALUES (1)',
        'SELECT * FROM a',
      ]);
      expect(result.succeeded, 3);
      expect(result.failed, 0);
      expect(result.ok, isTrue);
    });

    test('无结束符的最后一段文本也执行', () async {
      final path = write('tail.sql', 'SELECT 1;\nSELECT 2');
      final log = <String>[];
      await runSqlFile(filePath: path, execute: (sql) async => log.add(sql));
      expect(log, ['SELECT 1', 'SELECT 2']);
    });

    test('文件开头的 UTF-8 BOM 不作为语句内容', () async {
      final file = File('${dir.path}/bom.sql')
        ..writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode('SELECT 1;')]);
      final log = <String>[];
      await runSqlFile(filePath: file.path, execute: (sql) async => log.add(sql));
      expect(log, ['SELECT 1']);
    });

    test('单条失败默认继续跑完后续语句', () async {
      final path = write('partial.sql', 'SELECT 1; SELECT bad; SELECT 3;');
      final log = <String>[];
      final result = await runSqlFile(
        filePath: path,
        execute: (sql) async {
          if (sql.contains('bad')) throw Exception('syntax error');
          log.add(sql);
        },
      );
      expect(log, ['SELECT 1', 'SELECT 3']);
      expect(result.succeeded, 2);
      expect(result.failed, 1);
      expect(result.ok, isFalse);
      expect(result.stoppedOnError, isFalse);
      expect(result.errors.single, contains('syntax error'));
      expect(result.errors.single, contains('SELECT bad'));
    });

    test('stopOnError 时第一条失败语句即中断', () async {
      final path = write('stop.sql', 'SELECT 1; SELECT bad; SELECT 3;');
      var calls = 0;
      final result = await runSqlFile(
        filePath: path,
        stopOnError: true,
        execute: (sql) async {
          calls++;
          if (sql.contains('bad')) throw Exception('boom');
        },
      );
      expect(calls, 2);
      expect(result.stoppedOnError, isTrue);
      expect(result.succeeded, 1);
      expect(result.failed, 1);
    });

    test('错误摘要条数受 maxErrors 限制', () async {
      final path = write('many_errors.sql', List.filled(10, 'SELECT bad;').join());
      final result = await runSqlFile(
        filePath: path,
        maxErrors: 3,
        execute: (sql) async => throw Exception('e'),
      );
      expect(result.failed, 10);
      expect(result.errors.length, 3);
    });

    test('取消后不再执行后续语句', () async {
      final path = write('cancel.sql', 'SELECT 1; SELECT 2; SELECT 3;');
      var calls = 0;
      final result = await runSqlFile(
        filePath: path,
        execute: (sql) async => calls++,
        isCancelled: () => calls >= 2,
      );
      expect(calls, 2);
      expect(result.cancelled, isTrue);
      expect(result.succeeded, 2);
      expect(result.ok, isFalse);
    });

    test('进度回调携带累计语句数与已读字节', () async {
      final path = write('progress.sql', List.generate(5, (i) => 'SELECT $i;').join());
      final snapshots = <SqlRunProgress>[];
      final result = await runSqlFile(
        filePath: path,
        execute: (sql) async {},
        onProgress: snapshots.add,
        progressEvery: 1,
      );
      expect(snapshots.length, 5);
      expect([for (final s in snapshots) s.executed], [0, 1, 2, 3, 4]);
      expect(snapshots.first.current, 'SELECT 0');
      expect(snapshots.last.totalBytes, File(path).lengthSync());
      expect(snapshots.last.bytesDone, snapshots.last.totalBytes);
      expect(result.succeeded, 5);
    });

    test('progressEvery 节流大文件回调次数', () async {
      final path = write('throttle.sql', 'SELECT 1;\n' * 100);
      var reports = 0;
      await runSqlFile(
        filePath: path,
        execute: (sql) async {},
        onProgress: (_) => reports++,
        progressEvery: 20,
      );
      expect(reports, 5);
    });

    test('单条超长语句跨多个读取块仍然完整', () async {
      // openRead 分块投递,这里刻意造一条远超块大小的语句,验证切分状态
      // 能跨块续接(未闭合引号里的内容不会被误当作分隔符)
      final big = 'x' * 300000;
      final path = write('big.sql', "INSERT INTO t VALUES ('$big');\nSELECT 2;");
      final log = <String>[];
      await runSqlFile(
          filePath: path, execute: (sql) async => log.add(sql));
      expect(log.length, 2);
      expect(log.first, "INSERT INTO t VALUES ('$big')");
    });

    test('文件不存在时给出整体性错误而非抛异常', () async {
      final result = await runSqlFile(
          filePath: '${dir.path}/missing.sql', execute: (sql) async {});
      expect(result.fatalError, contains('无法读取文件'));
      expect(result.executed, 0);
    });

    test('非 UTF-8(GBK)转储直接报错,不静默写坏中文', () async {
      // 「中文」的 GBK 编码不是合法 UTF-8 序列
      final bytes = File('${dir.path}/gbk.sql');
      bytes.writeAsBytesSync([
        ...'SELECT '.codeUnits,
        0xD6, 0xD0, 0xCE, 0xC4, // GBK: 中文
        ...';'.codeUnits,
      ]);
      final result = await runSqlFile(
          filePath: bytes.path, execute: (sql) async {});
      expect(result.fatalError, contains('UTF-8'));
    });

    test('转储里的 DELIMITER 过程体作为一条语句执行', () async {
      final path = write('proc.sql', 'DELIMITER \$\$\n'
          'CREATE PROCEDURE p() BEGIN SELECT 1; END\$\$\n'
          'DELIMITER ;\n'
          'SELECT 2;');
      final log = <String>[];
      final result =
          await runSqlFile(filePath: path, execute: (sql) async => log.add(sql));
      expect(log, ['CREATE PROCEDURE p() BEGIN SELECT 1; END', 'SELECT 2']);
      expect(result.succeeded, 2);
    });
  });
}
