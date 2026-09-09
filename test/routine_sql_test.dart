import 'package:daro/app/app_state.dart';
import 'package:daro/data/routine_sql.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RoutineSql 模板生成与解析', () {
    test('PG 过程模板 + 解析回环', () {
      final sql = RoutineSql.buildTemplate(
        typeId: 'postgresql',
        category: ObjectCategory.procedure,
        name: 'test',
        schema: 'public',
        params: [
          RoutineParam(mode: 'IN', name: 'a', type: 'INT'),
          RoutineParam(mode: 'IN', name: 'b', type: 'VARCHAR(50)'),
        ],
      );
      expect(sql, contains('CREATE OR REPLACE PROCEDURE "public"."test"(IN a INT, IN b VARCHAR(50))'));
      expect(sql, contains('LANGUAGE plpgsql'));
      expect(sql, contains(r'AS $BODY$'));

      final p = parseRoutineSql(sql, typeId: 'postgresql', category: ObjectCategory.procedure);
      expect(p, isNotNull);
      expect(p!.signature, 'IN a INT, IN b VARCHAR(50)');
      expect(p.language, 'plpgsql');
      expect(p.securityDefiner, false);
      expect(p.body, contains('Routine body goes here'));

      // 重建
      final rebuilt = RoutineSql.buildWithBody(
        typeId: 'postgresql',
        category: ObjectCategory.procedure,
        name: 'test',
        schema: 'public',
        signature: p.signature,
        body: p.body,
      );
      expect(rebuilt, sql);
    });

    test('PG 函数模板 + SECURITY DEFINER + 注释语句', () {
      final sql = RoutineSql.buildTemplate(
        typeId: 'postgresql',
        category: ObjectCategory.function,
        name: 'fn',
        schema: 'public',
        params: [RoutineParam(mode: 'IN', name: 'x', type: 'integer')],
        returnType: 'integer',
        language: 'plpgsql',
        securityDefiner: true,
      );
      expect(sql, contains('CREATE OR REPLACE FUNCTION "public"."fn"(IN x integer)'));
      expect(sql, contains('RETURNS integer'));
      expect(sql, contains('SECURITY DEFINER'));

      final p = parseRoutineSql(sql, typeId: 'postgresql', category: ObjectCategory.function);
      expect(p, isNotNull);
      expect(p!.returnType, 'integer');
      expect(p.securityDefiner, true);
      expect(p.body, contains('RETURN 0;'));

      final comment = RoutineSql.commentOnSql(
        typeId: 'postgresql',
        category: ObjectCategory.function,
        name: 'fn',
        schema: 'public',
        signature: p.signature,
        comment: "统计 '当月' 数据",
      );
      expect(comment, "COMMENT ON FUNCTION \"public\".\"fn\"(IN x integer) IS '统计 ''当月'' 数据';");
    });

    test('MySQL 过程 / 函数模板 + 解析', () {
      final proc = RoutineSql.buildTemplate(
        typeId: 'mysql',
        category: ObjectCategory.procedure,
        name: 'p',
        schema: null,
        params: [RoutineParam(mode: 'OUT', name: 'cnt', type: 'INT')],
      );
      expect(proc, contains('CREATE PROCEDURE `p`(OUT cnt INT)'));
      final pp = parseRoutineSql(proc, typeId: 'mysql', category: ObjectCategory.procedure);
      expect(pp, isNotNull);
      expect(pp!.signature, 'OUT cnt INT');

      final fn = RoutineSql.buildTemplate(
        typeId: 'mysql',
        category: ObjectCategory.function,
        name: 'f',
        schema: null,
        params: const [],
      );
      expect(fn, contains('CREATE FUNCTION `f`()'));
      expect(fn, contains('RETURNS INT'));
      final fp = parseRoutineSql(fn, typeId: 'mysql', category: ObjectCategory.function);
      expect(fp, isNotNull);
      expect(fp!.returnType, 'INT');
    });

    test('SQL Server 过程 / 函数模板 + 解析', () {
      final proc = RoutineSql.buildTemplate(
        typeId: 'sqlserver',
        category: ObjectCategory.procedure,
        name: 'p',
        schema: 'dbo',
        params: [
          RoutineParam(mode: '', name: 'a', type: 'INT'),
          RoutineParam(mode: 'OUTPUT', name: 'b', type: 'VARCHAR(50)'),
        ],
      );
      expect(proc, contains('CREATE PROCEDURE [dbo].[p]'));
      expect(proc, contains('  @a INT,'));
      expect(proc, contains('  @b VARCHAR(50) OUTPUT'));
      final pp = parseRoutineSql(proc, typeId: 'sqlserver', category: ObjectCategory.procedure);
      expect(pp, isNotNull);
      expect(pp!.signature, '@a INT, @b VARCHAR(50) OUTPUT');

      final fn = RoutineSql.buildTemplate(
        typeId: 'sqlserver',
        category: ObjectCategory.function,
        name: 'f',
        schema: 'dbo',
        params: [RoutineParam(mode: '', name: 'x', type: 'INT')],
      );
      expect(fn, contains('CREATE FUNCTION [dbo].[f]'));
      expect(fn, contains('  (@x INT)'));
      expect(fn, contains('RETURNS INT'));
      final fp = parseRoutineSql(fn, typeId: 'sqlserver', category: ObjectCategory.function);
      expect(fp, isNotNull);
      expect(fp!.returnType, 'INT');
    });

    test('SQL Server 签名生成(@ 前缀 / OUTPUT)', () {
      final sig = RoutineSql.signature('sqlserver', [
        RoutineParam(mode: '', name: 'a', type: 'INT'),
        RoutineParam(mode: 'OUTPUT', name: 'b', type: 'VARCHAR(50)'),
      ]);
      expect(sig, '@a INT, @b VARCHAR(50) OUTPUT');
    });
  });
}
