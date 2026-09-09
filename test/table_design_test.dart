import 'package:daro/data/table_design.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DdlBuilder PostgreSQL', () {
    test('完整设计生成 CREATE TABLE + 索引 + 触发器 + 注释', () {
      final d = DesignTable()
        ..name = 'orders'
        ..schema = 'public'
        ..tableComment = '订单表'
        ..fillFactor = '90'
        ..columns.addAll([
          DesignColumn(name: 'id', type: 'BIGSERIAL', notNull: true, primaryKey: true),
          DesignColumn(name: 'user_id', type: 'BIGINT', notNull: true, comment: '用户 ID'),
          DesignColumn(name: 'amount', type: 'DECIMAL', length: '10', decimal: '2', defaultValue: '0'),
          DesignColumn(name: 'status', type: 'VARCHAR', length: '20', notNull: true),
        ])
        ..indexes.add(DesignIndex(name: 'idx_status', columns: 'status', method: 'btree'))
        ..uniqueKeys.add(DesignUniqueKey(name: 'uq_status', columns: 'status'))
        ..checks.add(DesignCheck(name: 'ck_amount', expression: 'amount >= 0'))
        ..foreignKeys.add(DesignForeignKey(
          name: 'fk_user',
          columns: 'user_id',
          refTable: 'users',
          refColumns: 'id',
          onDelete: 'CASCADE',
          onUpdate: 'NO ACTION',
        ))
        ..triggers.add(DesignTrigger(
          name: 'trg_update_ts',
          timing: 'BEFORE',
          insert: true,
          update: true,
          forEach: '行',
          when: 'NEW.status IS NOT NULL',
          function: 'public.update_ts',
          parameters: 'NEW',
        ));

      final stmts = DdlBuilder.buildStatements(d, 'postgresql');
      final sql = stmts.join('\n');

      // CREATE TABLE 主体
      expect(sql, contains('CREATE TABLE "public"."orders" ('));
      expect(sql, contains('"id" BIGSERIAL NOT NULL PRIMARY KEY'));
      expect(sql, contains('"amount" DECIMAL(10,2) DEFAULT 0'));
      expect(sql, contains('WITH (fillfactor = 90)'));
      // 约束内联
      expect(sql, contains('CONSTRAINT "uq_status" UNIQUE ("status")'));
      expect(sql, contains('CONSTRAINT "ck_amount" CHECK (amount >= 0)'));
      expect(sql, contains('CONSTRAINT "fk_user" FOREIGN KEY ("user_id") REFERENCES "public"."users" ("id") ON DELETE CASCADE'));
      // 独立语句
      expect(sql, contains('CREATE INDEX "idx_status" ON "public"."orders" USING btree ("status");'));
      expect(sql, contains('CREATE TRIGGER "trg_update_ts" BEFORE INSERT OR UPDATE ON "public"."orders" FOR EACH ROW WHEN (NEW.status IS NOT NULL) EXECUTE FUNCTION "public"."update_ts"(NEW);'));
      expect(sql, contains('COMMENT ON TABLE "public"."orders" IS \'订单表\';'));
      expect(sql, contains('COMMENT ON COLUMN "public"."orders"."user_id" IS \'用户 ID\';'));

      // 语句拆分:CREATE TABLE / INDEX / TRIGGER / COMMENT TABLE / COMMENT COLUMN
      expect(stmts.length, greaterThanOrEqualTo(5));
    });

    test('空名约束自动命名 + 多列主键表级约束', () {
      final d = DesignTable()
        ..name = 't'
        ..columns.addAll([
          DesignColumn(name: 'a', type: 'INT', primaryKey: true),
          DesignColumn(name: 'b', type: 'INT', primaryKey: true),
        ])
        ..uniqueKeys.add(DesignUniqueKey(columns: 'b'));
      final sql = DdlBuilder.buildPreview(d, 'postgresql');
      expect(sql, contains('PRIMARY KEY ("a", "b")'));
      expect(sql, contains('CONSTRAINT "uq_t_b" UNIQUE ("b")'));
      expect(sql, contains('CREATE TABLE "t" ('));
    });

    test('可延迟 / 延迟 子句', () {
      final d = DesignTable()
        ..name = 't'
        ..columns.add(DesignColumn(name: 'a', type: 'INT'))
        ..foreignKeys.add(DesignForeignKey(
          columns: 'a',
          refTable: 'r',
          refColumns: 'id',
          deferrable: 'YES',
          deferred: 'YES',
        ));
      final sql = DdlBuilder.buildPreview(d, 'postgresql');
      expect(sql, contains('DEFERRABLE INITIALLY DEFERRED'));
    });
  });

  group('DdlBuilder MySQL', () {
    test('内联注释与反引号标识符', () {
      final d = DesignTable()
        ..name = 'user'
        ..tableComment = '用户表'
        ..columns.addAll([
          DesignColumn(name: 'id', type: 'BIGINT', notNull: true, primaryKey: true, comment: '主键'),
          DesignColumn(name: 'name', type: 'VARCHAR', length: '255'),
        ])
        ..indexes.add(DesignIndex(name: 'idx_name', columns: 'name', unique: true));
      final sql = DdlBuilder.buildPreview(d, 'mysql');
      expect(sql, contains('CREATE TABLE `user` ('));
      expect(sql, contains('`id` BIGINT NOT NULL PRIMARY KEY COMMENT \'主键\''));
      expect(sql, contains(') COMMENT = \'用户表\';'));
      expect(sql, contains('CREATE UNIQUE INDEX `idx_name` ON `user` (`name`);'));
      // MySQL 不生成 COMMENT ON
      expect(sql, isNot(contains('COMMENT ON')));
    });
  });

  group('DdlBuilder 校验', () {
    test('空表名 / 空列名校验', () {
      expect(DdlBuilder.validate(DesignTable()).ok, isFalse);
      final d = DesignTable()
        ..columns.add(DesignColumn(name: '  '));
      expect(DdlBuilder.validate(d).ok, isFalse);
      final ok = DesignTable()
        ..columns.add(DesignColumn(name: 'a', type: 'INT'));
      expect(DdlBuilder.validate(ok).ok, isTrue);
    });
  });
}
