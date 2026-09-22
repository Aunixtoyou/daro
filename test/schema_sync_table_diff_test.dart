import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:daro/data/schema_sync.dart';
import 'package:daro/data/table_design.dart';
import 'package:flutter_test/flutter_test.dart';

/// 结构同步**表级差异**的数据层回归测试(离线假驱动,不碰真实库)。
///
/// 钉住的 bug:源有 N 张表、目标为空库时,期望「N 个新建」,实际却全部落到
/// 「无操作」且 blocked(备注「读取结构失败:Null check operator used on a
/// null value」)。根因在 `_diffTable` 的判定顺序——目标缺失该表时 tgtDesign
/// 天然为 null,却先命中了「某一侧反查失败」分支,该分支去解引用 targetName!
/// 而抛异常,被 _diffOne 的兜底 catch 吞成 blocked + 无操作。
/// 视图 / 函数 / 过程的 `_diffRoutine` 顺序正确,所以只有表受影响。
///
/// 该判定顺序在任何 typeId 分支**之前**,故 mysql / mariadb / postgresql /
/// sqlserver 四种一起中招——下面的方言组各跑一遍,顺带验证 `DdlBuilder` 真能
/// 为每种方言产出本方言标识符的 CREATE / DROP。文件型 sqlite / access 由
/// [structureSyncUnsupported] 在入口拦掉,不参与比对。

/// 各方言的模式与列类型写法(测试里生成的 DDL 要能被该方言接受)
class _Dialect {
  const _Dialect(this.schema, this.idType, this.textType);

  /// 会话模式;MySQL / MariaDB 库即模式,留空
  final String? schema;
  final String idType;
  final String textType;
}

const _dialects = <String, _Dialect>{
  'postgresql': _Dialect('public', 'int4', 'varchar'),
  'sqlserver': _Dialect('dbo', 'int', 'nvarchar'),
  'mysql': _Dialect(null, 'int', 'varchar'),
  'mariadb': _Dialect(null, 'int', 'varchar'),
};

ConnectionInfo _conn(String name, String typeId) => ConnectionInfo(
      name: name,
      typeId: typeId,
      host: '10.255.255.1', // 不可路由:假驱动下永不真正连接
      port: '5432',
      username: 'u',
      password: 'p',
      database: 'default_db',
      isLive: true,
    );

DesignTable _table(String name, String typeId, {String? ref}) {
  final d = _dialects[typeId]!;
  return DesignTable()
    ..name = name
    ..schema = d.schema
    ..columns.add(DesignColumn(
        name: 'id',
        type: d.idType,
        length: '',
        decimal: '',
        primaryKey: true))
    ..columns.add(DesignColumn(name: 'label', type: d.textType, length: '64'))
    ..pkName = '${name}_pkey'
    // 引用另一张表(建表语句里带外键):部署时必须等它先就位
    ..foreignKeys.addAll(ref == null
        ? const []
        : [DesignForeignKey(name: 'fk_${name}_$ref', columns: 'id', refTable: ref)]);
}

Map<String, DesignTable?> _only(String typeId, List<String> names) =>
    {for (final n in names) n: _table(n, typeId)};

/// 假驱动:表清单与「表名 → 反查结果」由构造参数决定;值为 null 表示
/// 该表在清单里但结构读不出来(驱动不支持 / 单表读取失败)。
class _Driver implements DatabaseDriver {
  _Driver(this.tables);

  final Map<String, DesignTable?> tables;

  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> useDatabase(String database) async {}
  @override
  Future<void> useSchema(String? schema) async {}
  @override
  Future<List<String>> listDatabases() async => const ['db'];
  @override
  Future<List<String>> listSchemas(String database) async => const ['public'];
  @override
  Future<List<String>> listTables(String database, {String? schema}) async =>
      tables.keys.toList();
  @override
  Future<List<String>> listViews(String database, {String? schema}) async =>
      const [];
  @override
  Future<List<String>> listFunctions(String database,
      {String? schema}) async =>
      const [];
  @override
  Future<List<String>> listProcedures(String database,
      {String? schema}) async =>
      const [];
  // 序列:本文件不测序列,给空列表。**不能靠 noSuchMethod 兜** —— 它返回
  // null,而该方法声明返回 List,`await` 之后再迭代直接抛,会被
  // compareSchemaSync 收成「读取序列列表失败」,把 errors 非空断言打挂。
  @override
  Future<List<String>> listSequences(String database, {String? schema}) async =>
      const [];
  @override
  Future<DesignTable?> readTableDesign(String database, String table,
          {String? schema}) async =>
      tables[table];
  @override
  Future<QueryResult> executeQuery(String sql,
          {int limit = 1000, int offset = 0}) async =>
      QueryResult(columns: const [], rows: const []);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<SyncPlan> _compare({
  String typeId = 'postgresql',
  required Map<String, DesignTable?> src,
  required Map<String, DesignTable?> tgt,
}) {
  final schema = _dialects[typeId]!.schema;
  return compareSchemaSync(
    source: SyncEndpoint(
        connection: _conn('src_conn', typeId),
        database: 'src_db',
        schema: schema),
    target: SyncEndpoint(
        connection: _conn('tgt_conn', typeId),
        database: 'tgt_db',
        schema: schema),
    driverFactory: (conn) =>
        conn.name == 'src_conn' ? _Driver(src) : _Driver(tgt),
    options: SyncOptions()
      ..views = false
      ..functions = false,
  );
}

void main() {
  group('表级差异:缺失一侧按名字定案', () {
    test('目标为空库 → 源侧每张表都是「新建」并带 CREATE 语句', () async {
      final plan = await _compare(
        src: _only('postgresql', ['users', 'orders']),
        tgt: {},
      );

      expect(plan.errors, isEmpty, reason: '${plan.errors}');
      expect(plan.countOf(SyncAction.create), 2);
      expect(plan.countOf(SyncAction.none), 0);
      for (final o in plan.ofAction(SyncAction.create)) {
        expect(o.blocked, isFalse, reason: '${o.name} 被标错:${o.note}');
        expect(o.note, isNull);
        expect(o.statements, isNotEmpty);
        expect(o.statements.first, contains('CREATE TABLE'));
        // 新建默认勾选,可直接进入部署
        expect(o.selected, isTrue);
      }
    });

    test('源为空库 → 目标侧每张表都是「删除」,且默认不勾选', () async {
      final plan = await _compare(
        src: {},
        tgt: _only('postgresql', ['legacy']),
      );

      expect(plan.errors, isEmpty, reason: '${plan.errors}');
      expect(plan.countOf(SyncAction.drop), 1);
      expect(plan.countOf(SyncAction.none), 0);
      final o = plan.ofAction(SyncAction.drop).single;
      expect(o.blocked, isFalse, reason: o.note);
      expect(o.statements.single, contains('DROP TABLE'));
      expect(o.selected, isFalse, reason: '破坏性操作必须人工确认');
    });

    test('两侧同名同结构 → 无操作;两侧都读不到结构 → 标错而非删除',
        () async {
      final same = await _compare(
        src: _only('postgresql', ['users']),
        tgt: _only('postgresql', ['users']),
      );
      expect(same.countOf(SyncAction.none), 1);
      expect(same.objects.single.blocked, isFalse);

      final unreadable = await _compare(
        src: _only('postgresql', ['users']),
        tgt: {'users': null},
      );
      final o = unreadable.objects.single;
      expect(o.action, SyncAction.none);
      expect(o.blocked, isTrue);
      expect(o.note, contains('目标库读不到'));
      expect(o.statements, isEmpty, reason: '读不到结构不能退化成 DROP 删目标表');
    });
  });

  group('四方言各自产出本方言 DDL', () {
    for (final typeId in _dialects.keys) {
      test('$typeId: 空目标库 → 全部新建;反向 → 全部删除', () async {
        final plan = await _compare(
          typeId: typeId,
          src: _only(typeId, ['users', 'orders']),
          tgt: {},
        );

        expect(plan.errors, isEmpty, reason: '${plan.errors}');
        expect(plan.objects, hasLength(2));
        for (final o in plan.objects) {
          expect(o.action, SyncAction.create,
              reason: '$typeId 下「${o.name}」判成了 ${o.action.label}');
          expect(o.blocked, isFalse, reason: '${o.name} 被标错:${o.note}');
          expect(o.statements, isNotEmpty, reason: '$typeId 没产出 DDL');
          expect(o.sourceDdl, contains('CREATE TABLE'));
          expect(o.targetDdl, isEmpty, reason: '目标侧本不该有该对象的结构');
        }
        // 标识符引号按方言:证明 DDL 不是统一按某一家输出
        final users = plan.objects.firstWhere((o) => o.name == 'users');
        expect(
            users.statements.join('\n'),
            contains(switch (typeId) {
              'postgresql' => '"public"."users"',
              'sqlserver' => '[dbo].[users]',
              _ => '`users`',
            }),
            reason: users.statements.join('\n'));

        final reverse = await _compare(
          typeId: typeId,
          src: {},
          tgt: _only(typeId, ['legacy']),
        );
        final drop = reverse.ofAction(SyncAction.drop).single;
        expect(drop.blocked, isFalse, reason: drop.note ?? '');
        expect(drop.statements.single, contains('DROP TABLE'));
        expect(reverse.countOf(SyncAction.none), 0);
      });
    }
  });

  group('部署顺序按外键依赖', () {
    test('新建:被引用的表排在引用方之前(否则 42P01 关系不存在)', () async {
      final plan = await _compare(
        src: {
          'cameras': _table('cameras', 'postgresql', ref: 'parking_gates'),
          'parking_gates': _table('parking_gates', 'postgresql'),
        },
        tgt: {},
      );

      // 比对页仍按名字序展示(顺序只在部署时校正,不打乱界面)
      expect(plan.objects.map((o) => o.name), ['cameras', 'parking_gates']);
      expect(plan.selected.map((o) => o.name), ['parking_gates', 'cameras'],
          reason: 'cameras 的外键指向 parking_gates,后者必须先建');
      final script = plan.deployScript();
      expect(
          script.indexOf('CREATE TABLE "public"."parking_gates"'),
          lessThan(script.indexOf('CREATE TABLE "public"."cameras"')),
          reason: script);
    });

    test('引用列的主键由后面的 ALTER 才补上:改表也要排在依赖它的新建之前',
        () async {
      // 目标侧 members 的 id 不是主键 → 差异是给 id 补 PRIMARY KEY;
      // field_value(新建)的外键引用 members.id,按名字序它会先执行 → 42830。
      final plan = await _compare(
        src: {
          'field_value': _table('field_value', 'postgresql', ref: 'members'),
          'members': _table('members', 'postgresql'),
        },
        tgt: {
          'members': DesignTable()
            ..name = 'members'
            ..schema = 'public'
            ..columns.add(DesignColumn(name: 'id', type: 'int4'))
            ..columns
                .add(DesignColumn(name: 'label', type: 'varchar', length: '64')),
        },
      );

      expect(plan.ofAction(SyncAction.alter).map((o) => o.name), ['members']);
      expect(plan.selected.map((o) => o.name), ['members', 'field_value'],
          reason: '先把主键补上,再建引用它的表');
    });

    test('循环外键:排序无解也不丢对象、不死循环', () async {
      final plan = await _compare(
        src: {
          'a': _table('a', 'postgresql', ref: 'b'),
          'b': _table('b', 'postgresql', ref: 'a'),
        },
        tgt: {},
      );

      expect(plan.selected, hasLength(2));
      expect(plan.selected.map((o) => o.name), ['a', 'b'],
          reason: '退回到稳定的名字序');
    });

    test('删除:引用方先删', () async {
      final plan = await _compare(
        src: {},
        tgt: {
          'cameras': _table('cameras', 'postgresql', ref: 'parking_gates'),
          'parking_gates': _table('parking_gates', 'postgresql'),
        },
      );
      for (final o in plan.objects) {
        o.selected = true; // 删除默认不勾选,测试里人工勾上
      }

      expect(plan.selected.map((o) => o.name), ['cameras', 'parking_gates'],
          reason: 'cameras 还引用 parking_gates,反过来删会被外键挡住');
    });

    test('非 PostgreSQL 方言同样按依赖排(mysql 内联外键)', () async {
      final plan = await _compare(
        typeId: 'mysql',
        src: {
          'child': _table('child', 'mysql', ref: 'parent'),
          'parent': _table('parent', 'mysql'),
        },
        tgt: {},
      );

      expect(plan.selected.map((o) => o.name), ['parent', 'child']);
    });
  });
}
