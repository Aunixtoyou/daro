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

    test('FULLTEXT / SPATIAL 是索引类型关键字,不落成尾部 USING', () {
      final d = DesignTable()
        ..name = 'enter_car'
        ..columns.addAll([
          DesignColumn(name: 'plate', type: 'VARCHAR', length: '64'),
          DesignColumn(name: 'geo', type: 'GEOMETRY'),
          DesignColumn(name: 'start_time', type: 'DATETIME'),
          DesignColumn(name: 'flags', type: 'INT'),
        ])
        ..indexes.addAll([
          DesignIndex(name: 'ft_plate', columns: 'plate', method: 'fulltext'),
          DesignIndex(name: 'sp_geo', columns: 'geo', method: 'SPATIAL'),
          DesignIndex(name: 'ix_time', columns: 'start_time', method: 'btree'),
          DesignIndex(name: 'ix_flags', columns: 'flags', method: 'hash'),
        ]);

      final sql = DdlBuilder.buildStatements(d, 'mysql').join('\n');
      expect(sql, contains('CREATE FULLTEXT INDEX `ft_plate` ON `enter_car` (`plate`);'));
      expect(sql, contains('CREATE SPATIAL INDEX `sp_geo` ON `enter_car` (`geo`);'));
      expect(sql, isNot(contains('USING fulltext')));
      expect(sql, isNot(contains('USING SPATIAL')));
      expect(sql, contains('CREATE INDEX `ix_time` ON `enter_car` (`start_time`) USING btree;'));
      expect(sql, contains('CREATE INDEX `ix_flags` ON `enter_car` (`flags`) USING hash;'));
    });
  });

  group('DdlBuilder IDENTITY(虚拟类型)', () {
    test('PostgreSQL 生成 GENERATED … AS IDENTITY 及序列选项', () {
      final d = DesignTable()
        ..name = 'configs'
        ..schema = 'public'
        ..columns.addAll([
          DesignColumn(
            name: 'id',
            type: 'int8',
            length: '64',
            notNull: true,
            primaryKey: true,
            identityMode: 'BY DEFAULT',
            identityIncrement: '1',
            identityMinValue: '1',
            identityMaxValue: '9223372036854775807',
            identityStart: '1',
            identityCache: '1',
          ),
          DesignColumn(name: 'name', type: 'varchar', length: '32', notNull: true),
        ]);
      final sql = DdlBuilder.buildPreview(d, 'postgresql');
      expect(
        sql,
        contains('"id" int8 GENERATED BY DEFAULT AS IDENTITY '
            '(INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1) '
            'NOT NULL'),
      );
      // int8 的「长度」是位宽信息,不拼进类型
      expect(sql, isNot(contains('int8(64)')));
      expect(sql, contains('"name" varchar(32) NOT NULL'));
    });

    test('CYCLE 输出 / 留空项不输出 / 无选项时省略括号', () {
      String build({bool cycle = false, String cache = ''}) {
        final d = DesignTable()
          ..name = 't'
          ..columns.add(DesignColumn(
            name: 'id',
            type: 'int4',
            identityMode: 'ALWAYS',
            identityIncrement: '2',
            identityCache: cache,
            identityCycle: cycle,
          ));
        return DdlBuilder.buildPreview(d, 'postgresql');
      }

      expect(
        build(cycle: true, cache: '5'),
        contains('GENERATED ALWAYS AS IDENTITY (INCREMENT BY 2 CACHE 5 CYCLE)'),
      );
      expect(
        build(),
        contains('GENERATED ALWAYS AS IDENTITY (INCREMENT BY 2)'),
      );
      final bare = DesignTable()
        ..name = 't'
        ..columns.add(DesignColumn(name: 'id', type: 'int4', identityMode: 'ALWAYS'));
      final sql = DdlBuilder.buildPreview(bare, 'postgresql');
      expect(sql, contains('GENERATED ALWAYS AS IDENTITY'));
      expect(sql, isNot(contains('IDENTITY (')));
    });

    test('MySQL 降级 AUTO_INCREMENT / SQL Server IDENTITY(seed,inc) / SQLite 忽略', () {
      DesignTable design() => DesignTable()
        ..name = 't'
        ..columns.add(DesignColumn(
          name: 'id',
          type: 'int',
          notNull: true,
          identityMode: 'BY DEFAULT',
          identityStart: '10',
          identityIncrement: '2',
        ));

      expect(DdlBuilder.buildPreview(design(), 'mysql'),
          contains('`id` int NOT NULL AUTO_INCREMENT'));
      expect(DdlBuilder.buildPreview(design(), 'sqlserver'),
          contains('[id] int IDENTITY(10,2) NOT NULL'));
      final lite = DdlBuilder.buildPreview(design(), 'sqlite');
      expect(lite, isNot(contains('IDENTITY')));
      expect(lite, isNot(contains('AUTO_INCREMENT')));
    });

    test('主键序号按列序推导', () {
      final a = DesignColumn(name: 'a', type: 'int', primaryKey: true);
      final b = DesignColumn(name: 'b', type: 'int');
      final c = DesignColumn(name: 'c', type: 'int', primaryKey: true);
      final d = DesignTable()
        ..name = 't'
        ..columns.addAll([a, b, c]);
      final ordinals = DdlBuilder.pkOrdinals(d);
      expect(ordinals[a], 1);
      expect(ordinals[b], isNull);
      expect(ordinals[c], 2);
    });
  });

  group('DdlBuilder 类型渲染', () {
    test('无长度参数的类型不拼接长度 / 小数点', () {
      expect(DesignColumn(type: 'int8', length: '64', decimal: '2').fullType, 'int8');
      expect(DesignColumn(type: 'varchar', length: '32').fullType, 'varchar(32)');
      expect(DesignColumn(type: 'decimal', length: '10', decimal: '2').fullType,
          'decimal(10,2)');
      expect(DesignColumn(type: 'VARCHAR', length: '20').fullType, 'VARCHAR(20)');
      // 新列默认:类型与长度分段录入
      expect(DesignColumn().fullType, 'varchar(255)');
    });

    test('IDENTITY 上限按类型给出', () {
      expect(kIdentityMaxValue('int2'), '32767');
      expect(kIdentityMaxValue('serial'), '2147483647');
      expect(kIdentityMaxValue('int8'), '9223372036854775807');
      expect(kIdentityMaxValue('varchar'), '');
      expect(bitWidthOf('int8'), '64');
      expect(bitWidthOf('varchar'), isNull);
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

    test('IDENTITY 序列项必须是整数', () {
      final d = DesignTable()
        ..columns.add(DesignColumn(
          name: 'id',
          type: 'int8',
          identityMode: 'BY DEFAULT',
          identityIncrement: 'x',
        ));
      final r = DdlBuilder.validate(d);
      expect(r.ok, isFalse);
      expect(r.error, contains('递增'));
      // 留空 = 交由数据库默认,不报错
      final okTable = DesignTable()
        ..columns.add(DesignColumn(name: 'id', type: 'int8', identityMode: 'BY DEFAULT'));
      expect(DdlBuilder.validate(okTable).ok, isTrue);
    });
  });

  group('DdlBuilder 索引字段项(「选择数据表字段」弹窗)', () {
    DesignTable oneCol() => DesignTable()
      ..name = 't'
      ..columns.add(DesignColumn(name: 'c', type: 'varchar', length: '32'));

    test('PostgreSQL 输出 COLLATE / 运算符类别 / 排序顺序 / Nulls 排序', () {
      final d = oneCol()
        ..indexes.add(DesignIndex(name: 'idx_c', columns: 'c')
          ..columnItems.add(DesignIndexColumn(
            name: 'c',
            collation: 'C',
            order: 'DESC',
            nullsOrder: 'FIRST',
          )));
      final sql = DdlBuilder.buildPreview(d, 'postgresql');
      expect(
        sql,
        contains('CREATE INDEX "idx_c" ON "t" ("c" COLLATE "C" DESC NULLS FIRST);'),
      );
    });

    test('排序规则 / 运算符类别的模式前缀按限定名输出', () {
      final d = oneCol()
        ..indexes.add(DesignIndex(name: 'idx_c', columns: 'c')
          ..columnItems.add(DesignIndexColumn(
            name: 'c',
            collationSchema: 'pg_catalog',
            collation: 'C',
            opClassSchema: 'public',
            opClass: 'varchar_pattern_ops',
          )));
      final sql = DdlBuilder.buildPreview(d, 'postgresql');
      expect(
        sql,
        contains('("c" COLLATE "pg_catalog"."C" "public"."varchar_pattern_ops");'),
      );
    });

    test('非 PostgreSQL 忽略字段项选项(只输出裸字段名)', () {
      final d = oneCol()
        ..indexes.add(DesignIndex(name: 'idx_c', columns: 'c')
          ..columnItems.add(DesignIndexColumn(name: 'c', collation: 'C', order: 'DESC')));
      expect(DdlBuilder.buildPreview(d, 'mysql'), contains('CREATE INDEX `idx_c` ON `t` (`c`);'));
    });

    test('字段项确认后回写逗号串', () {
      final idx = DesignIndex(columns: 'a');
      idx.columnItems.addAll([
        DesignIndexColumn(name: 'b'),
        DesignIndexColumn(name: 'a'),
      ]);
      idx.applyColumnItems();
      expect(idx.columns, 'b, a');
      expect(idx.columnList, ['b', 'a']);
    });

    test('copy 深拷贝字段项(快照基线不被后续编辑污染)', () {
      final idx = DesignIndex(name: 'i', columns: 'c')
        ..columnItems.add(DesignIndexColumn(name: 'c', order: 'ASC'));
      final dup = idx.copy();
      dup.columnItems.first.order = 'DESC';
      expect(idx.columnItems.first.order, 'ASC');
    });
  });

  group('DdlBuilder 表选项(不记录 / 所有者 / 继承 / 集群)', () {
    DesignTable opts() => DesignTable()
      ..name = 't'
      ..schema = 'public'
      ..columns.add(DesignColumn(name: 'a', type: 'int'))
      ..unlogged = true
      ..inherits = 'public.base, other'
      ..owner = 'postgres'
      ..cluster = 'idx_a'
      ..indexes.add(DesignIndex(name: 'idx_a', columns: 'a'));

    test('PostgreSQL 生成 UNLOGGED + INHERITS,并各补一条 OWNER TO / CLUSTER', () {
      final stmts = DdlBuilder.buildStatements(opts(), 'postgresql');
      expect(
        stmts.first,
        'CREATE UNLOGGED TABLE "public"."t" (\n  "a" int\n) INHERITS ("public"."base", "other");',
      );
      expect(stmts, contains('ALTER TABLE "public"."t" OWNER TO "postgres";'));
      expect(stmts, contains('CLUSTER "public"."t" USING "idx_a";'));
    });

    test('MySQL / SQLite 不生成这些子句', () {
      final sql = DdlBuilder.buildPreview(opts(), 'mysql');
      expect(sql, isNot(contains('UNLOGGED')));
      expect(sql, isNot(contains('INHERITS')));
      expect(sql, isNot(contains('OWNER TO')));
      expect(sql, isNot(contains('CLUSTER')));
    });

    test('留空时与从前一致(无多余子句)', () {
      final d = DesignTable()
        ..name = 't'
        ..columns.add(DesignColumn(name: 'a', type: 'int'));
      final stmts = DdlBuilder.buildStatements(d, 'postgresql');
      expect(stmts.length, 1);
      expect(stmts.first, startsWith('CREATE TABLE "t" ('));
    });
  });

  group('DdlBuilder 约束触发器 / 外键注释', () {
    DesignTable base() => DesignTable()
      ..name = 't'
      ..columns.add(DesignColumn(name: 'a', type: 'int'));

    test('可延迟 + 延迟 生成 CREATE CONSTRAINT TRIGGER … DEFERRABLE INITIALLY DEFERRED', () {
      final d = base()
        ..triggers.add(DesignTrigger(
          name: 'trg',
          timing: 'AFTER',
          insert: true,
          function: 'trg_fn',
          deferrable: 'YES',
          deferred: 'YES',
        ));
      expect(
        DdlBuilder.buildPreview(d, 'postgresql'),
        contains('CREATE CONSTRAINT TRIGGER "trg" AFTER INSERT ON "t" '
            'DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "trg_fn";'),
      );
    });

    test('未置可延迟时不输出 INITIALLY DEFERRED(PG 语法要求两者搭配)', () {
      final d = base()
        ..triggers.add(DesignTrigger(
          name: 'trg',
          timing: 'AFTER',
          insert: true,
          function: 'trg_fn',
          deferred: 'YES',
        ));
      final sql = DdlBuilder.buildPreview(d, 'postgresql');
      expect(sql, isNot(contains('CONSTRAINT TRIGGER')));
      expect(sql, isNot(contains('DEFERRABLE')));
    });

    test('外键注释生成 COMMENT ON CONSTRAINT(仅 PostgreSQL)', () {
      final d = base()
        ..foreignKeys.add(DesignForeignKey(
          name: 'fk_a',
          columns: 'a',
          refTable: 'r',
          refColumns: 'id',
          comment: '级联到用户表',
        ));
      expect(
        DdlBuilder.buildPreview(d, 'postgresql'),
        contains('COMMENT ON CONSTRAINT "fk_a" ON "t" IS \'级联到用户表\';'),
      );
      expect(DdlBuilder.buildPreview(d, 'mysql'), isNot(contains('COMMENT ON')));
    });

    test('索引 / 唯一键 / 检查 / 排除 注释:PG 生成 COMMENT ON,MySQL 索引注释内联', () {
      final d = base()
        ..indexes.add(DesignIndex(name: 'idx_a', columns: 'a', comment: 'A 索引'))
        ..uniqueKeys.add(DesignUniqueKey(name: 'uq_a', columns: 'a', comment: 'A 唯一'))
        ..checks.add(DesignCheck(name: 'ck_a', expression: 'a > 0', comment: 'A 为正'))
        ..excludes.add(DesignExclude(name: 'ex_a', columns: 'a with =', comment: 'A 排重'));
      final pgSql = DdlBuilder.buildPreview(d, 'postgresql');
      expect(pgSql, contains('COMMENT ON INDEX "idx_a" IS \'A 索引\';'));
      expect(pgSql, contains('COMMENT ON CONSTRAINT "uq_a" ON "t" IS \'A 唯一\';'));
      expect(pgSql, contains('COMMENT ON CONSTRAINT "ck_a" ON "t" IS \'A 为正\';'));
      expect(pgSql, contains('COMMENT ON CONSTRAINT "ex_a" ON "t" IS \'A 排重\';'));

      // MySQL 只有索引注释能内联进 CREATE INDEX,不会多生 COMMENT ON 语句
      d
        ..uniqueKeys.clear()
        ..checks.clear()
        ..excludes.clear();
      final mySql = DdlBuilder.buildPreview(d, 'mysql');
      expect(mySql, contains('CREATE INDEX `idx_a` ON `t` (`a`) COMMENT \'A 索引\';'));
      expect(mySql, isNot(contains('COMMENT ON')));
    });
  });
}
