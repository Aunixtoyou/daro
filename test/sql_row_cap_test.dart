import 'package:flutter_test/flutter_test.dart';

import 'package:daro/data/sql_row_cap.dart';

void main() {
  group('capSelectSql 应改写', () {
    test('普通 SELECT 追加 LIMIT', () {
      expect(
        capSelectSql('SELECT * FROM t', maxRows: 1001),
        'SELECT * FROM t\nLIMIT 1001',
      );
    });

    test('末尾分号被去掉后再追加', () {
      expect(
        capSelectSql('SELECT * FROM t;', maxRows: 10),
        'SELECT * FROM t\nLIMIT 10',
      );
    });

    test('WITH 开头的只读查询', () {
      expect(
        capSelectSql('WITH x AS (SELECT 1 AS a) SELECT * FROM x', maxRows: 5),
        'WITH x AS (SELECT 1 AS a) SELECT * FROM x\nLIMIT 5',
      );
    });

    test('子查询里已有的 LIMIT 不算顶层,仍可封顶', () {
      expect(
        capSelectSql('SELECT * FROM (SELECT * FROM t LIMIT 1) x', maxRows: 5),
        'SELECT * FROM (SELECT * FROM t LIMIT 1) x\nLIMIT 5',
      );
    });

    test('字符串 / 引用标识符里的 LIMIT 关键字不误判', () {
      expect(
        capSelectSql(
          "SELECT `limit`, 'LIMIT 5' AS s FROM \"tbl LIMIT\" WHERE a = 'x''y'",
          maxRows: 5,
        ),
        contains('\nLIMIT 5'),
      );
    });

    test('注释里的 LIMIT 不误判', () {
      expect(
        capSelectSql(
          'SELECT /* LIMIT 9 */ a FROM t -- LIMIT 8',
          maxRows: 5,
        ),
        'SELECT /* LIMIT 9 */ a FROM t -- LIMIT 8\nLIMIT 5',
      );
    });

    test('PostgreSQL 美元引号内部不误判', () {
      expect(
        capSelectSql("SELECT \$\$ LIMIT 7 \$\$ AS body, 'x' AS y", maxRows: 5),
        contains('\nLIMIT 5'),
      );
    });

    test('UNION / ORDER BY / HAVING 结尾都能追加', () {
      expect(
        capSelectSql(
          'SELECT a FROM t GROUP BY a HAVING count(*) > 1 '
          'UNION SELECT b FROM u ORDER BY 1',
          maxRows: 5,
        ),
        endsWith('\nLIMIT 5'),
      );
    });

    test('MySQL 的 # 行注释在换行处结束', () {
      expect(
        capSelectSql('SELECT a FROM t # 注释\nWHERE b = 1', maxRows: 5),
        endsWith('\nLIMIT 5'),
      );
    });
  });

  group('capSelectSql 不应改写', () {
    test('写语句与 DDL', () {
      for (final sql in [
        'INSERT INTO t VALUES (1)',
        'UPDATE t SET a = 1',
        'DELETE FROM t',
        'CREATE TABLE x AS SELECT * FROM t',
        'DROP TABLE t',
        'CALL p()',
        'SHOW TABLES',
        'EXPLAIN SELECT * FROM t',
        'DESCRIBE t',
      ]) {
        expect(capSelectSql(sql, maxRows: 5), isNull, reason: sql);
      }
    });

    test('已自带封顶', () {
      for (final sql in [
        'SELECT * FROM t LIMIT 10',
        'SELECT * FROM t LIMIT 5, 10',
        'SELECT * FROM t FETCH FIRST 10 ROWS ONLY',
      ]) {
        expect(capSelectSql(sql, maxRows: 5), isNull, reason: sql);
      }
    });

    test('追加 LIMIT 会破坏语法或语义的子句', () {
      for (final sql in [
        'SELECT * FROM t FOR UPDATE',
        'SELECT * FROM t FOR SHARE',
        'SELECT * FROM t LOCK IN SHARE MODE',
        "SELECT * INTO OUTFILE '/tmp/x' FROM t",
        'SELECT * FROM t PROCEDURE ANALYSE()',
      ]) {
        expect(capSelectSql(sql, maxRows: 5), isNull, reason: sql);
      }
    });

    test('WITH 开头的写语句', () {
      expect(
        capSelectSql('WITH d AS (SELECT 1) DELETE FROM t WHERE a = 1',
            maxRows: 5),
        isNull,
      );
    });

    test('顶层分号(多条语句)交给上层切分', () {
      expect(
        capSelectSql('SELECT 1; SELECT 2', maxRows: 5),
        isNull,
      );
    });

    test('词法结构不完整时保守放弃', () {
      for (final sql in [
        "SELECT * FROM t WHERE a = '未闭合",
        'SELECT * FROM t /* 未闭合',
        'SELECT * FROM t)',
        '(SELECT * FROM t)',
        '',
        '   ',
      ]) {
        expect(capSelectSql(sql, maxRows: 5), isNull, reason: sql);
      }
    });

    test('maxRows 非正数时不改写', () {
      expect(capSelectSql('SELECT * FROM t', maxRows: 0), isNull);
      expect(capSelectSql('SELECT * FROM t', maxRows: -1), isNull);
    });
  });
}
