import 'package:flutter_test/flutter_test.dart';

import 'package:daro/data/table_view.dart';

/// 模拟 MySQL 的反引号引用(其余方言同理,引用规则由调用方注入)
String _mysqlIdent(String name) => '`${name.replaceAll('`', '``')}`';

/// 模拟 PostgreSQL / SQL Server 的方括号引用
String _bracketIdent(String name) => '[${name.replaceAll(']', ']]')}]';

/// [join] = 本条与**下一条**之间的连接方式(最后一条的 join 不参与 SQL)
FilterCriterion _filter(
  int column,
  FilterOperator op, {
  String value = '',
  bool enabled = true,
  int id = 0,
  FilterJoin join = FilterJoin.and,
}) =>
    FilterCriterion(
      id: id,
      columnIndex: column,
      operator: op,
      value: value,
      enabled: enabled,
      join: join,
    );

SortCriterion _sort(int column, {bool ascending = true, int id = 0}) =>
    SortCriterion(id: id, columnIndex: column, ascending: ascending);

void main() {
  group('buildWhereClause 组装筛选条件', () {
    const columns = ['userid', 'appid', 'login_times'];

    test('单条等于条件不加括号', () {
      final sql = buildWhereClause(
        criteria: [_filter(0, FilterOperator.eq, value: '93716897')],
        columns: columns,
        ident: _mysqlIdent,
      );
      expect(sql, "`userid` = '93716897'");
    });

    test('多条条件默认按「且」连接并整体加括号(外层还要 AND 显示模式条件)', () {
      final sql = buildWhereClause(
        criteria: [
          _filter(0, FilterOperator.gte, value: '10'),
          _filter(1, FilterOperator.startsWith, value: 'wx'),
        ],
        columns: columns,
        ident: _mysqlIdent,
      );
      expect(sql, "(`userid` >= '10' AND `appid` LIKE 'wx%')");
    });

    test('连接词取自**上一条**准则(写在上一条行尾),逐条可不同', () {
      final sql = buildWhereClause(
        criteria: [
          // userid = 1 AND appid = 2 OR login_times = 3
          _filter(0, FilterOperator.eq, value: '1', join: FilterJoin.and),
          _filter(1, FilterOperator.eq, value: '2', id: 1, join: FilterJoin.or),
          _filter(2, FilterOperator.eq, value: '3', id: 2, join: FilterJoin.or),
        ],
        columns: columns,
        ident: _mysqlIdent,
      );
      // 末条的 join 后面没有条件,不参与 SQL
      expect(
        sql,
        "(`userid` = '1' AND `appid` = '2' OR `login_times` = '3')",
      );
    });

    test('全部「或」连接', () {
      final sql = buildWhereClause(
        criteria: [
          _filter(0, FilterOperator.eq, value: '1', join: FilterJoin.or),
          _filter(0, FilterOperator.eq, value: '2', id: 1),
        ],
        columns: columns,
        ident: _mysqlIdent,
      );
      expect(sql, "(`userid` = '1' OR `userid` = '2')");
    });

    test('被停用的条件不留下多余连接词', () {
      final sql = buildWhereClause(
        criteria: [
          // 第一条用「或」连下一条,但中间那条被停用 → userid OR login_times
          _filter(0, FilterOperator.eq, value: '1', join: FilterJoin.or),
          _filter(
              1,
              FilterOperator.eq,
              value: '2',
              id: 1,
              enabled: false,
              join: FilterJoin.or),
          _filter(2, FilterOperator.eq, value: '3', id: 2),
        ],
        columns: columns,
        ident: _mysqlIdent,
      );
      expect(sql, "(`userid` = '1' OR `login_times` = '3')");
    });

    test('各运算符的 SQL 形态', () {
      String sqlOf(FilterOperator op, String value) => buildWhereClause(
            criteria: [_filter(0, op, value: value)],
            columns: columns,
            ident: _mysqlIdent,
          )!;

      expect(sqlOf(FilterOperator.ne, '5'), "`userid` <> '5'");
      expect(sqlOf(FilterOperator.gt, '5'), "`userid` > '5'");
      expect(sqlOf(FilterOperator.lte, '5'), "`userid` <= '5'");
      expect(sqlOf(FilterOperator.contains, 'abc'), "`userid` LIKE '%abc%'");
      expect(
          sqlOf(FilterOperator.notContains, 'abc'), "`userid` NOT LIKE '%abc%'");
      expect(sqlOf(FilterOperator.endsWith, 'abc'), "`userid` LIKE '%abc'");
      expect(sqlOf(FilterOperator.isNull, ''), '`userid` IS NULL');
      expect(sqlOf(FilterOperator.isNotNull, ''), '`userid` IS NOT NULL');
    });

    test('值恰好是 NULL 时按 IS NULL / IS NOT NULL 处理', () {
      expect(
        buildWhereClause(
          criteria: [_filter(0, FilterOperator.eq, value: 'NULL')],
          columns: columns,
          ident: _mysqlIdent,
        ),
        '`userid` IS NULL',
      );
      expect(
        buildWhereClause(
          criteria: [_filter(0, FilterOperator.ne, value: 'NULL')],
          columns: columns,
          ident: _mysqlIdent,
        ),
        '`userid` IS NOT NULL',
      );
    });

    test('值为空串时比较空串(LIKE 也照常拼 %%)', () {
      expect(
        buildWhereClause(
          criteria: [_filter(1, FilterOperator.eq, value: '')],
          columns: columns,
          ident: _mysqlIdent,
        ),
        "`appid` = ''",
      );
      expect(
        buildWhereClause(
          criteria: [_filter(1, FilterOperator.contains, value: '')],
          columns: columns,
          ident: _mysqlIdent,
        ),
        "`appid` LIKE '%%'",
      );
    });

    test('单引号翻倍转义,避免注入 / 语法错误', () {
      final sql = buildWhereClause(
        criteria: [_filter(1, FilterOperator.eq, value: "o'brien")],
        columns: columns,
        ident: _mysqlIdent,
      );
      expect(sql, "`appid` = 'o''brien'");
    });

    test('停用的条件不参与 SQL', () {
      expect(
        buildWhereClause(
          criteria: [_filter(0, FilterOperator.eq, value: '1', enabled: false)],
          columns: columns,
          ident: _mysqlIdent,
        ),
        isNull,
      );
    });

    test('列下标越界的条件跳过(换表后残留的准则)', () {
      expect(
        buildWhereClause(
          criteria: [
            _filter(9, FilterOperator.eq, value: '1'),
            _filter(0, FilterOperator.eq, value: '2'),
          ],
          columns: columns,
          ident: _mysqlIdent,
        ),
        "`userid` = '2'",
      );
    });

    test('无有效条件返回 null(调用方据此不拼 WHERE)', () {
      expect(
        buildWhereClause(
          criteria: const [],
          columns: columns,
          ident: _mysqlIdent,
        ),
        isNull,
      );
    });

    test('标识符引用规则由调用方注入(SQL Server 方括号)', () {
      final sql = buildWhereClause(
        criteria: [_filter(2, FilterOperator.eq, value: '3')],
        columns: columns,
        ident: _bracketIdent,
      );
      expect(sql, "[login_times] = '3'");
    });
  });

  group('FilterJoin 枚举', () {
    test('面板显示名与 SQL 关键字各自独立', () {
      expect(FilterJoin.and.label, '且');
      expect(FilterJoin.and.sql, 'AND');
      expect(FilterJoin.or.label, '或');
      expect(FilterJoin.or.sql, 'OR');
    });
  });

  group('buildOrderByClause 组装排序', () {
    const columns = ['userid', 'appid', 'login_times'];

    test('单列升序', () {
      expect(
        buildOrderByClause(
          criteria: [_sort(0)],
          columns: columns,
          ident: _mysqlIdent,
        ),
        '`userid` ASC',
      );
    });

    test('多列按列表顺序输出,顺序即优先级', () {
      expect(
        buildOrderByClause(
          criteria: [_sort(2, ascending: false), _sort(0, id: 1)],
          columns: columns,
          ident: _mysqlIdent,
        ),
        '`login_times` DESC, `userid` ASC',
      );
    });

    test('越界列跳过;全部无效时返回 null', () {
      expect(
        buildOrderByClause(
          criteria: [_sort(7)],
          columns: columns,
          ident: _mysqlIdent,
        ),
        isNull,
      );
      expect(
        buildOrderByClause(
          criteria: const [],
          columns: columns,
          ident: _mysqlIdent,
        ),
        isNull,
      );
    });
  });

  group('visibleColumnIndexes 可见列', () {
    test('null / 长度不符时全部可见', () {
      expect(visibleColumnIndexes(null, 3), [0, 1, 2]);
      // 列集变化后残留的旧开关:按全部显示兜底,不能把列全藏了
      expect(visibleColumnIndexes([true, false], 3), [0, 1, 2]);
    });

    test('按开关挑出可见列', () {
      expect(visibleColumnIndexes([true, false, true, false], 4), [0, 2]);
    });

    test('全部隐藏时退回全部显示(空网格无从恢复)', () {
      expect(visibleColumnIndexes([false, false], 2), [0, 1]);
    });

    test('零列返回空序列', () {
      expect(visibleColumnIndexes([true], 0), isEmpty);
    });
  });

  group('草稿与已应用状态的等价判断', () {
    test('逐条按内容比较,不看列表身份', () {
      final a = [_filter(0, FilterOperator.eq, value: '1', id: 3)];
      final b = [_filter(0, FilterOperator.eq, value: '1', id: 3)];
      final c = [_filter(0, FilterOperator.eq, value: '2', id: 3)];
      expect(sameFilters(a, b), isTrue);
      expect(sameFilters(a, c), isFalse);
      expect(sameFilters(a, const []), isFalse);
    });

    test('只改连接词也算有改动(否则「应用」按钮不会亮)', () {
      final a = [_filter(0, FilterOperator.eq, value: '1', id: 3)];
      final b = [
        _filter(0, FilterOperator.eq, value: '1', id: 3, join: FilterJoin.or),
      ];
      expect(sameFilters(a, b), isFalse);
    });

    test('排序准则比较含方向与顺序', () {
      final a = [_sort(0, id: 1), _sort(1, ascending: false, id: 2)];
      final b = [_sort(0, id: 1), _sort(1, ascending: false, id: 2)];
      final reversed = [_sort(1, ascending: false, id: 2), _sort(0, id: 1)];
      expect(sameSorts(a, b), isTrue);
      expect(sameSorts(a, reversed), isFalse);
    });

    test('copy 出的准则与原准则等价且互不影响', () {
      final origin = _filter(0, FilterOperator.eq, value: '1', id: 5);
      final copy = origin.copy()..value = '2';
      expect(origin.value, '1');
      expect(copy.value, '2');
      expect(copy.id, 5);
      expect(copy == origin, isFalse);
    });

    test('copy 保留连接词', () {
      final origin = _filter(0, FilterOperator.eq, value: '1', id: 5);
      expect(origin.copy().join, FilterJoin.and);
      final or = _filter(
          0, FilterOperator.eq, value: '1', id: 6, join: FilterJoin.or);
      expect(or.copy().join, FilterJoin.or);
    });
  });
}
