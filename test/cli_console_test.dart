import 'package:daro/app/cli_console.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用固定应答脚本驱动一个命令列会话:每次执行按顺序取一条,
/// 命中 [failOn] 的语句抛异常(模拟服务端报错)。
({CliConsole console, List<String> executed}) _session({
  String database = 'testdb',
  String typeId = 'mysql',
  List<QueryResult> results = const [],
  Set<String> failOn = const {},
}) {
  final executed = <String>[];
  final queue = List<QueryResult>.of(results);
  final console = CliConsole(
    database: database,
    typeId: typeId,
    executor: (sql) async {
      executed.add(sql);
      if (failOn.contains(sql)) throw StateError('syntax error at "$sql"');
      if (queue.isEmpty) return const QueryResult(columns: [], rows: []);
      return queue.removeAt(0);
    },
  );
  return (console: console, executed: executed);
}

/// 会话输出拼成一段文本,便于按行断言
String _dump(CliConsole console) =>
    console.lines.map((l) => l.text).join('\n');

QueryResult _select(List<String> columns, List<List<String>> rows,
        {bool moreRows = false}) =>
    QueryResult(columns: columns, rows: rows, limit: 1000, moreRows: moreRows);

void main() {
  group('提示符', () {
    test('PostgreSQL 家族用「库名=#」,其余用「库名>」', () {
      expect(_session(database: 'datawalk_dev', typeId: 'postgresql')
              .console
              .prompt,
          'datawalk_dev=# ');
      expect(_session(database: 'shop', typeId: 'mysql').console.prompt,
          'shop> ');
    });

    test('续行提示符与主提示符等宽', () {
      final console =
          _session(database: 'datawalk_dev', typeId: 'postgresql').console;
      expect(console.continuationPrompt.length, console.prompt.length);
      expect(console.continuationPrompt, endsWith('-> '));
    });
  });

  group('提交与续行', () {
    test('未以分号收尾的输入留在缓冲里,不执行', () async {
      final s = _session();
      await s.console.submit('SELECT 1');
      expect(s.executed, isEmpty);
      expect(s.console.awaitingContinuation, isTrue);
      expect(_dump(s.console), contains('SELECT 1'));
    });

    test('续行补齐分号后整段执行', () async {
      final s = _session();
      await s.console.submit('SELECT id,');
      await s.console.submit('name FROM t;');
      expect(s.executed, ['SELECT id,\nname FROM t']);
      expect(s.console.awaitingContinuation, isFalse);
    });

    test('续行期间空行取消未完成的语句', () async {
      final s = _session();
      await s.console.submit('SELECT');
      await s.console.submit('');
      expect(s.executed, isEmpty);
      expect(s.console.awaitingContinuation, isFalse);
      expect(_dump(s.console), contains('已取消未完成的输入语句'));
    });

    test('字符串里的分号不会提前触发执行', () async {
      final s = _session();
      await s.console.submit("SELECT 'a;b';");
      expect(s.executed, ["SELECT 'a;b'"]);
    });

    test('一行写多条语句时逐条执行', () async {
      final s = _session();
      await s.console.submit('SELECT 1; SELECT 2;');
      expect(s.executed, ['SELECT 1', 'SELECT 2']);
    });

    test('语句报错后停止后续语句,并以 ERROR 行回显', () async {
      final s = _session(failOn: {'BAD'});
      await s.console.submit('BAD; SELECT 2;');
      expect(s.executed, ['BAD']);
      expect(_dump(s.console), contains('ERROR:'));
      expect(
        s.console.lines.last.kind,
        CliLineKind.error,
      );
      expect(s.console.busy, isFalse);
    });
  });

  group('结果回显', () {
    test('结果集排成带框线的表格,列宽取最宽单元格', () async {
      final s = _session(
        results: [
          _select(['id', 'name'], [
            ['1', 'a'],
            ['2', 'NULL'],
          ]),
        ],
      );
      await s.console.submit('SELECT * FROM t;');
      expect(
        _dump(s.console),
        contains('''
+----+------+
| id | name |
+----+------+
| 1  | a    |
| 2  | NULL |
+----+------+'''),
      );
      expect(_dump(s.console), contains('2 rows in set'));
    });

    test('单行结果用单数 row', () async {
      final s = _session(results: [_select(['c'], [['1']])]);
      await s.console.submit('SELECT 1;');
      expect(_dump(s.console), contains('1 row in set'));
    });

    test('达到行数上限时摘要带 + 号', () async {
      final s = _session(
        results: [
          _select(['c'], [
            for (var i = 0; i < 1000; i++) ['$i']
          ], moreRows: true)
        ],
      );
      await s.console.submit('SELECT * FROM big;');
      expect(_dump(s.console), contains('1000+ rows in set'));
    });

    test('写操作回显受影响行数', () async {
      final s = _session();
      await s.console.submit('DELETE FROM t;');
      expect(_dump(s.console), contains('Query OK'));
    });

    test('超长单元格截断加省略号,内嵌换行折成空格', () {
      final text = formatResultTable(
        _select(['note'], [
          ['x' * 60],
          ['a\nb'],
        ]),
        maxCellWidth: 10,
      );
      expect(text, contains('${'x' * 10}…'));
      expect(text.split('\n').length, 6); // 上下框 + 表头框 + 表头 + 两行数据
      expect(text, isNot(contains('a\nb')));
    });
  });

  group('输入历史', () {
    test('↑ 从最近一条往前翻,↓ 回到最新之后时清空输入', () async {
      final s = _session();
      await s.console.submit('SELECT 1;');
      await s.console.submit('SELECT 2;');
      expect(s.console.recallHistory(backwards: true), 'SELECT 2');
      expect(s.console.recallHistory(backwards: true), 'SELECT 1');
      expect(s.console.recallHistory(backwards: true), 'SELECT 1');
      expect(s.console.recallHistory(backwards: false), 'SELECT 2');
      expect(s.console.recallHistory(backwards: false), '');
    });

    test('连续相同的语句只记一条', () async {
      final s = _session();
      await s.console.submit('SELECT 1;');
      await s.console.submit('SELECT 1;');
      expect(s.console.history, ['SELECT 1']);
    });

    test('历史为空时翻动返回 null', () {
      expect(_session().console.recallHistory(backwards: true), isNull);
    });
  });

  test('输出行数封顶时丢弃最早的行', () async {
    final console = CliConsole(
      database: 'testdb',
      typeId: 'mysql',
      maxLines: 5,
      executor: (_) async => _select(['c'], [
        for (var i = 0; i < 20; i++) ['$i']
      ]),
    );
    await console.submit('SELECT * FROM t;');
    expect(console.lines.length, 5);
    expect(console.lines.first.text, '| 17 |');
    expect(console.lines.last.text, startsWith('20 rows in set'));
  });
}
