import 'package:dart_odbc/dart_odbc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daro/data/drivers/odbc_query.dart';

/// 假游标:按 [rowCount] 提供行,记录被 `next()` 拉取了多少次。
/// 行数故意远大于 limit,用来钉死「只取 limit + 1 行就停」这一条。
class _FakeCursor implements OdbcCursor {
  _FakeCursor(this.rowCount);

  final int rowCount;
  int nextCalls = 0;
  int closeCalls = 0;

  @override
  Future<CursorResult> next() async {
    // 越界即视为实现把整棵结果集抽干了(修复前的行为)
    nextCalls++;
    if (nextCalls > rowCount) return const CursorDone();
    return CursorItem({
      'id': nextCalls,
      'name': 'row-$nextCalls',
      'note': null,
    });
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

class _FakeOdbc implements IDartOdbc {
  _FakeOdbc(this.cursor);

  final OdbcCursor cursor;
  final List<String> sqls = [];

  @override
  Future<OdbcCursor> executeCursor(String query,
      {List<dynamic>? params}) async {
    sqls.add(query);
    return cursor;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('未预期调用 ${invocation.memberName}');
}

void main() {
  group('odbcQueryCapped', () {
    test('大结果集只取 limit + 1 行即停,并关闭游标', () async {
      final cursor = _FakeCursor(100000);
      final odbc = _FakeOdbc(cursor);

      final r = await odbcQueryCapped(odbc, 'SELECT * FROM big', limit: 1000);

      expect(r.rows.length, 1000);
      // 关键断言:多读 1 行判定「还有更多」后立即停,绝不抽干 10 万行
      expect(cursor.nextCalls, 1001);
      expect(r.moreRows, isTrue);
      expect(cursor.closeCalls, 1);
      expect(r.columns, ['id', 'name', 'note']);
      // 原样下发,不改写用户 SQL(封顶靠停止拉取,不靠拼 TOP)
      expect(odbc.sqls, ['SELECT * FROM big']);
    });

    test('行数正好等于 limit 时不误报「还有更多行」', () async {
      final cursor = _FakeCursor(1000);
      final odbc = _FakeOdbc(cursor);

      final r = await odbcQueryCapped(odbc, 'SELECT * FROM exact', limit: 1000);

      expect(r.rows.length, 1000);
      expect(cursor.nextCalls, 1001);
      expect(r.moreRows, isFalse);
      expect(cursor.closeCalls, 1);
    });

    test('不足 limit 时按实际行数返回,不触发封顶', () async {
      final cursor = _FakeCursor(3);
      final odbc = _FakeOdbc(cursor);

      final r = await odbcQueryCapped(odbc, 'SELECT * FROM small', limit: 1000);

      expect(r.rows.length, 3);
      expect(r.moreRows, isFalse);
      expect(r.columns, ['id', 'name', 'note']);
      expect(cursor.closeCalls, 1);
    });

    test('空结果集(写语句)返回空列与空行', () async {
      final cursor = _FakeCursor(0);
      final odbc = _FakeOdbc(cursor);

      final r = await odbcQueryCapped(odbc, 'DELETE FROM t', limit: 1000);

      expect(r.columns, isEmpty);
      expect(r.rows, isEmpty);
      expect(r.moreRows, isFalse);
      expect(cursor.closeCalls, 1);
    });

    test('真 NULL 与字符串 "NULL" 的展示约定保持一致', () async {
      final cursor = _FakeCursor(1);
      final odbc = _FakeOdbc(cursor);

      final r = await odbcQueryCapped(odbc, 'SELECT * FROM t', limit: 10);

      expect(r.rows.single, ['1', 'row-1', 'NULL']);
    });

    test('游标抛错时仍然关闭(不泄漏语句句柄)', () async {
      final cursor = _ThrowingCursor();
      final odbc = _FakeOdbc(cursor);

      await expectLater(
        odbcQueryCapped(odbc, 'SELECT * FROM boom', limit: 10),
        throwsA(isA<Exception>()),
      );
      expect(cursor.closeCalls, 1);
    });

    test('executeCursor 自身失败时原始异常不被关闭逻辑掩盖', () async {
      final odbc = _FailingOnOpenOdbc();

      await expectLater(
        odbcQueryCapped(odbc, 'SELECT * FROM boom', limit: 10),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('打开游标失败'),
          ),
        ),
      );
    });
  });
}

class _FailingOnOpenOdbc implements IDartOdbc {
  @override
  Future<OdbcCursor> executeCursor(String query,
      {List<dynamic>? params}) async {
    throw Exception('打开游标失败: HY001');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('未预期调用 ${invocation.memberName}');
}

class _ThrowingCursor implements OdbcCursor {
  int closeCalls = 0;

  @override
  Future<CursorResult> next() async => throw Exception('HY001 模拟驱动报错');

  @override
  Future<void> close() async {
    closeCalls++;
  }
}
