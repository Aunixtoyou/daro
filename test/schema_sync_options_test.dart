import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:daro/data/schema_sync.dart';
import 'package:daro/data/table_design.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「结构同步 → 选项」(比对选项)重构后的数据层回归测试(离线假驱动)。
///
/// 钉住三件事:
/// 1. 开关**真的生效** —— 把子块开关关掉后,那一类差异不该再算差异;
/// 2. 开关**恰好只作用于它管的那一块** —— 关「比较索引」不该顺手把主键也忽略;
/// 3. 序列是新增的对象类别,比对 / 新建 / 重建 / 「比较序列最后值」都要对。
///
/// 开关的作用点有两个,测的时候要分清(见 `schema_sync.dart::_diffTable`):
/// * 「什么算差异」→ 比对前用 `_stripByOptions` 把两侧**同时**裁掉该子块;
/// * 「新建的对象长什么样」→ 用**源的完整定义**,子块开关不参与
///   (否则取消「比较主键」会建出没有主键的表)。

// ─────────────────────────── 脚手架 ───────────────────────────

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

/// 有模式层的类型才有 schema(MySQL 的模式就是库,留空)。
String? _schemaOf(String typeId) => switch (typeId) {
      'postgresql' => 'public',
      'sqlserver' => 'dbo',
      _ => null,
    };

/// 一张两列的表;`pk` 决定有没有主键,`indexes` / `owner` 用于子块开关测试。
DesignTable _table(
  String name, {
  bool pk = true,
  List<DesignIndex> indexes = const [],
  String owner = '',
}) {
  final t = DesignTable()
    ..name = name
    ..schema = 'public';
  t.columns.add(DesignColumn(
      name: 'id', type: 'int4', length: '', primaryKey: pk));
  t.columns.add(DesignColumn(name: 'label', type: 'varchar', length: '64'));
  if (pk) t.pkName = '${name}_pkey';
  t.indexes.addAll(indexes);
  t.owner = owner;
  return t;
}

DesignIndex _index(String name, String column) =>
    DesignIndex(name: name, columns: column);

/// 序列定义:驱动侧把系统目录参数重建成一条 `CREATE SEQUENCE`。
SequenceDef _seq(String schema, String name,
        {String increment = '1', String? lastValue}) =>
    SequenceDef(
      createSql: 'CREATE SEQUENCE "$schema"."$name" '
          'INCREMENT BY $increment START WITH 1',
      increment: increment,
      lastValue: lastValue,
    );

/// 假驱动:表 / 序列清单与结构都由构造参数决定;某名字不在 map 里即「该侧没有」。
///
/// [typeId] 用来复刻真实驱动的口径:**只有 [kSequenceTypes] 里的类型**才有独立
/// 序列对象(mysql 的自增是列属性,不是能同步的对象),其余一律返回空清单 ——
/// 否则测「MySQL 下序列类别开着也不产出差异」就成了自欺(因为序号是注入的)。
class _Fake implements DatabaseDriver {
  _Fake({
    required this.typeId,
    this.tables = const {},
    this.sequences = const {},
    this.failOn,
  });

  final String typeId;
  final Map<String, DesignTable?> tables;
  final Map<String, SequenceDef> sequences;

  /// 命中该子串的 DDL 抛错 —— 测「遇错即停 / 继续跑完」两种部署口径用。
  final String? failOn;

  bool get _hasSequences => kSequenceTypes.contains(typeId);

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
  @override
  Future<List<String>> listSequences(String database, {String? schema}) async =>
      _hasSequences ? sequences.keys.toList() : const [];
  @override
  Future<DesignTable?> readTableDesign(String database, String table,
          {String? schema}) async =>
      tables[table];
  @override
  Future<SequenceDef?> readSequence(String database, String name,
          {String? schema}) async =>
      _hasSequences ? sequences[name] : null;
  @override
  Future<QueryResult> executeQuery(String sql,
      {int limit = 1000, int offset = 0}) async {
    if (failOn != null && sql.contains(failOn!)) {
      throw Exception('模拟执行失败');
    }
    return QueryResult(columns: const [], rows: const []);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<SyncPlan> _compare({
  String typeId = 'postgresql',
  Map<String, DesignTable?> src = const {},
  Map<String, DesignTable?> tgt = const {},
  Map<String, SequenceDef> srcSeqs = const {},
  Map<String, SequenceDef> tgtSeqs = const {},
  SyncOptions? options,
}) {
  final schema = _schemaOf(typeId);
  return compareSchemaSync(
    source: SyncEndpoint(
        connection: _conn('src_conn', typeId), database: 'src_db', schema: schema),
    target: SyncEndpoint(
        connection: _conn('tgt_conn', typeId), database: 'tgt_db', schema: schema),
    driverFactory: (conn) => conn.name == 'src_conn'
        ? _Fake(typeId: typeId, tables: src, sequences: srcSeqs)
        : _Fake(typeId: typeId, tables: tgt, sequences: tgtSeqs),
    options: options ?? SyncOptions(),
  );
}

/// 取一个对象(不按 kind 过滤时传 null);找不到直接失败并列出实际内容。
SyncObject _obj(SyncPlan plan, SyncObjectKind? kind, String name) {
  for (final o in plan.objects) {
    if ((kind == null || o.kind == kind) &&
        o.name.toLowerCase() == name.toLowerCase()) {
      return o;
    }
  }
    fail('差异表里没有「$name」:${plan.objects.map((o) => '${o.kind.label}/${o.name}').join(', ')}');
}

/// 把 [plan] 勾选的对象部署到目标(同一个假驱动跑完全部对象)。
///
/// [failOn] 命中的 DDL 抛错;[stopOnError] 对应界面上的「遇到错误时继续」**没勾**。
Future<DeployReport> _deploy(
  SyncPlan plan, {
  bool stopOnError = false,
  String? failOn,
  String typeId = 'postgresql',
}) =>
    deploySchemaSync(
      target: SyncEndpoint(
          connection: _conn('tgt_conn', typeId),
          database: 'tgt_db',
          schema: _schemaOf(typeId)),
      selected: plan.selected,
      driverFactory: (_) => _Fake(typeId: typeId, failOn: failOn),
      stopOnError: stopOnError,
    );

void main() {
  group('SyncOptions:默认值对齐参考工具', () {
    test('对象类别与表子块默认全开;级联删除默认关;序列最后值默认开', () {
      final o = SyncOptions();
      expect(
          [
            o.tables,
            o.views,
            o.functions,
            o.sequences,
            o.indexes,
            o.triggers,
            o.rules,
            o.owners,
          ],
          everyElement(isTrue),
          reason: '对象类别与表的其余子块默认都要比');
      expect(
          [o.primaryKeys, o.foreignKeys, o.uniqueKeys, o.checks, o.excludes],
          everyElement(isTrue),
          reason: '「比较表」下面的五个子项默认都要比');
      expect(o.cascadeDrop, isFalse,
          reason: '级联删除会连带删掉依赖对象,默认必须关,要开得用户自己勾');
      expect(o.sequenceLastValue, isTrue);
    });

    test('函数开关同时涵盖过程(参考工具的列表里没有单独的过程项)', () {
      final o = SyncOptions()..functions = false;
      expect(o.enabledOf(SyncObjectKind.function), isFalse);
      expect(o.enabledOf(SyncObjectKind.procedure), isFalse);
      expect(o.enabledOf(SyncObjectKind.sequence), isTrue, reason: '别误伤序列');
    });
  });

  group('SyncOptions:序列化 / 拷贝', () {
    test('toJson → loadJson 往返:15 个开关一个不丢', () {
      final a = SyncOptions()
        ..tables = false
        ..views = false
        ..functions = false
        ..sequences = false
        ..indexes = false
        ..triggers = false
        ..rules = false
        ..owners = false
        ..primaryKeys = false
        ..foreignKeys = false
        ..uniqueKeys = false
        ..checks = false
        ..excludes = false
        ..cascadeDrop = true
        ..sequenceLastValue = false;

      expect(a.toJson().length, 15, reason: '新增开关忘了加进 toJson 会在这里露馅');
      final b = SyncOptions()..loadJson(a.toJson());
      expect(b.toJson(), a.toJson());
    });

    test('loadJson:缺键 / 类型不对的键保留当前值(老配置文件不该把新开关清成 false)', () {
      final o = SyncOptions()
        ..tables = false
        ..views = false
        ..sequences = false;
      // 老配置文件里既没有 sequences,也可能有手改坏的类型
      o.loadJson({'tables': 'yes', 'views': 1});
      expect(o.tables, isFalse, reason: '字符串不是 bool,应保留当前值');
      expect(o.views, isFalse, reason: '数字不是 bool,应保留当前值');
      expect(o.sequences, isFalse, reason: '缺键应保留当前值');
      expect(o.cascadeDrop, isFalse, reason: '缺键保留默认值');
    });

    test('copy() 是深拷贝:弹窗里改副本不影响主弹窗持有的原对象', () {
      final original = SyncOptions();
      final draft = original.copy()
        ..tables = false
        ..cascadeDrop = true;
      expect(original.tables, isTrue);
      expect(original.cascadeDrop, isFalse);
      expect(draft.tables, isFalse);
      expect(draft.cascadeDrop, isTrue);
    });
  });

  group('表子块开关:关了就不算差异,且只作用于自己那一块', () {
    test('比较索引:关掉后源侧多出的索引不再算差异;开着则判「修改」', () async {
      final src = {'t': _table('t', indexes: [_index('ix_label', 'label')])};
      final tgt = {'t': _table('t')};

      final on = await _compare(src: src, tgt: tgt);
      final obj = _obj(on, SyncObjectKind.table, 't');
      expect(obj.action, SyncAction.alter);
      expect(obj.statements.join('\n'), contains('CREATE INDEX'));

      final off = await _compare(
          src: src, tgt: tgt, options: SyncOptions()..indexes = false);
      expect(_obj(off, SyncObjectKind.table, 't').action, SyncAction.none);
    });

    test('比较主键:关掉后「目标没有主键」不再算差异', () async {
      final src = {'t': _table('t', pk: true)};
      final tgt = {'t': _table('t', pk: false)};

      final on = await _compare(src: src, tgt: tgt);
      final obj = _obj(on, SyncObjectKind.table, 't');
      expect(obj.action, SyncAction.alter);
      expect(obj.statements.join('\n'), contains('PRIMARY KEY'));

      final off = await _compare(
          src: src, tgt: tgt, options: SyncOptions()..primaryKeys = false);
      expect(_obj(off, SyncObjectKind.table, 't').action, SyncAction.none);
    });

    test('比较所有者:关掉后所有者差异不算差异,开着才生成 ALTER … OWNER TO', () async {
      final src = {'t': _table('t', owner: 'src_role')};
      final tgt = {'t': _table('t', owner: 'tgt_role')};

      final on = await _compare(src: src, tgt: tgt);
      final obj = _obj(on, SyncObjectKind.table, 't');
      expect(obj.action, SyncAction.alter);
      expect(obj.statements.join('\n'), contains('OWNER TO "src_role"'));

      final off = await _compare(
          src: src, tgt: tgt, options: SyncOptions()..owners = false);
      expect(_obj(off, SyncObjectKind.table, 't').action, SyncAction.none,
          reason: '所有者是实例级设置,关掉后应完全跨库不搬运');
    });

    test('新建表用源的完整定义:子块开关不影响「新建出来的表长什么样」', () async {
      // 目标为空库 → 判「新建」;此时取消「比较主键 / 比较索引」也照建
      final src = {
        't': _table('t', pk: true, indexes: [_index('ix_label', 'label')]),
      };
      final plan = await _compare(
        src: src,
        tgt: {},
        options: SyncOptions()
          ..primaryKeys = false
          ..indexes = false,
      );
      final obj = _obj(plan, SyncObjectKind.table, 't');
      final ddl = obj.statements.join('\n');
      expect(obj.action, SyncAction.create);
      expect(ddl, contains('PRIMARY KEY'),
          reason: '子块开关只决定「什么算差异」,不该建出没主键的表');
      expect(ddl, contains('CREATE INDEX'));
    });

    test('比较表:关掉后表整个不参与比对', () async {
      final plan = await _compare(
        src: {'t': _table('t')},
        tgt: {},
        options: SyncOptions()..tables = false,
      );
      expect(plan.objects, isEmpty);
    });

    test('比较序列:关掉后序列整个不参与比对', () async {
      final plan = await _compare(
        srcSeqs: {'seq_a': _seq('public', 'seq_a')},
        options: SyncOptions()..sequences = false,
      );
      expect(plan.objects, isEmpty);
    });
  });

  group('级联删除', () {
    test('默认关:DROP 不带 CASCADE', () async {
      final plan = await _compare(tgt: {'t': _table('t')});
      final obj = _obj(plan, SyncObjectKind.table, 't');
      expect(obj.action, SyncAction.drop);
      expect(obj.statements.single, 'DROP TABLE IF EXISTS "public"."t"');
    });

    test('勾上「用级联删除」:PG 的 DROP 带 CASCADE', () async {
      final plan = await _compare(
          tgt: {'t': _table('t')}, options: SyncOptions()..cascadeDrop = true);
      expect(_obj(plan, SyncObjectKind.table, 't').statements.single,
          'DROP TABLE IF EXISTS "public"."t" CASCADE');
    });

    test('MySQL 即使勾了也不带 CASCADE(语法上就没有这个子句)', () async {
      final plan = await _compare(
        typeId: 'mysql',
        tgt: {'t': _table('t')},
        options: SyncOptions()..cascadeDrop = true,
      );
      final sql = _obj(plan, SyncObjectKind.table, 't').statements.single;
      expect(sql, 'DROP TABLE IF EXISTS `t`');
      expect(sql, isNot(contains('CASCADE')));
    });
  });

  group('序列:比对口径与部署语句', () {
    test('目标没有该序列 → 新建,并按「比较序列最后值」补一条 RESTART', () async {
      final srcSeqs = {'seq_a': _seq('public', 'seq_a', lastValue: '100')};

      final on = await _compare(srcSeqs: srcSeqs);
      final obj = _obj(on, SyncObjectKind.sequence, 'seq_a');
      expect(obj.action, SyncAction.create);
      expect(obj.statements, [
        'CREATE SEQUENCE "public"."seq_a" INCREMENT BY 1 START WITH 1',
        // 比的是「下一次要发出去的值」= 最后值 + 增量,不是最后值本身(会撞号)
        'ALTER SEQUENCE "public"."seq_a" RESTART WITH 101',
      ]);

      final off = await _compare(
          srcSeqs: srcSeqs,
          options: SyncOptions()..sequenceLastValue = false);
      expect(_obj(off, SyncObjectKind.sequence, 'seq_a').statements, [
        'CREATE SEQUENCE "public"."seq_a" INCREMENT BY 1 START WITH 1',
      ]);
    });

    test('参数相同、只有分发位置不同 → 只发 RESTART,不重建(重建会打断使用中的序列)',
        () async {
      final plan = await _compare(
        srcSeqs: {'seq_a': _seq('public', 'seq_a', lastValue: '100')},
        tgtSeqs: {'seq_a': _seq('public', 'seq_a', lastValue: '500')},
      );
      final obj = _obj(plan, SyncObjectKind.sequence, 'seq_a');
      expect(obj.action, SyncAction.alter);
      expect(obj.statements, ['ALTER SEQUENCE "public"."seq_a" RESTART WITH 101']);
    });

    test('位置也一致 → 无操作', () async {
      final plan = await _compare(
        srcSeqs: {'seq_a': _seq('public', 'seq_a', lastValue: '100')},
        tgtSeqs: {'seq_a': _seq('public', 'seq_a', lastValue: '100')},
      );
      expect(_obj(plan, SyncObjectKind.sequence, 'seq_a').action,
          SyncAction.none);
    });

    test('未取过值的一侧(lastValue 为空)→ 不比最后值,不凭空造差异', () async {
      final plan = await _compare(
        srcSeqs: {'seq_a': _seq('public', 'seq_a', lastValue: '100')},
        tgtSeqs: {'seq_a': _seq('public', 'seq_a')},
      );
      expect(_obj(plan, SyncObjectKind.sequence, 'seq_a').action,
          SyncAction.none);
    });

    test('参数不同 → DROP + CREATE 重建,并补 RESTART;勾了级联删除则 DROP 带 CASCADE',
        () async {
      final plan = await _compare(
        srcSeqs: {'seq_a': _seq('public', 'seq_a', lastValue: '100')},
        tgtSeqs: {
          'seq_a': _seq('public', 'seq_a', increment: '5', lastValue: '100'),
        },
        options: SyncOptions()..cascadeDrop = true,
      );
      final obj = _obj(plan, SyncObjectKind.sequence, 'seq_a');
      expect(obj.action, SyncAction.alter);
      expect(obj.statements, [
        'DROP SEQUENCE IF EXISTS "public"."seq_a" CASCADE',
        'CREATE SEQUENCE "public"."seq_a" INCREMENT BY 1 START WITH 1',
        'ALTER SEQUENCE "public"."seq_a" RESTART WITH 101',
      ]);
    });

    test('目标独有的序列 → 删除', () async {
      final plan = await _compare(tgtSeqs: {'seq_b': _seq('public', 'seq_b')});
      final obj = _obj(plan, SyncObjectKind.sequence, 'seq_b');
      expect(obj.action, SyncAction.drop);
      expect(obj.statements, ['DROP SEQUENCE IF EXISTS "public"."seq_b"']);
    });

    test('MySQL 没有独立序列对象 → 类别启用了也不产出任何序列差异', () async {
      final plan = await _compare(
          typeId: 'mysql', srcSeqs: {'seq_a': _seq('public', 'seq_a')});
      expect(plan.errors, isEmpty);
      expect(
          plan.objects.where((o) => o.kind == SyncObjectKind.sequence), isEmpty);
    });
  });

  group('SyncDeployOptions:部署选项(只影响执行,与比对无关)', () {
    test('默认两项都不勾(对齐参考工具的「部署选项」弹窗)', () {
      final o = SyncDeployOptions();
      expect(o.continueOnError, isFalse);
      expect(o.logQueries, isFalse);
    });

    test('toJson → loadJson 往返;缺键 / 类型不对保留当前值', () {
      final o = SyncDeployOptions()
        ..continueOnError = true
        ..logQueries = true;
      expect(o.toJson(), {'continueOnError': true, 'logQueries': true});

      final back = SyncDeployOptions();
      back.loadJson(o.toJson());
      expect(back.continueOnError, isTrue);
      expect(back.logQueries, isTrue);

      // 老配置文件里没有这一块:不能因为缺键就把开关清成 false
      final legacy = SyncDeployOptions()
        ..continueOnError = true
        ..logQueries = true;
      legacy.loadJson(const {});
      expect(legacy.continueOnError, isTrue);
      expect(legacy.logQueries, isTrue);

      // 类型不对(字符串 / 数字)同样保留
      legacy.loadJson(const {'continueOnError': 'yes', 'logQueries': 1});
      expect(legacy.continueOnError, isTrue);
      expect(legacy.logQueries, isTrue);
    });

    test('copy() 是深拷贝:弹窗里改副本不影响主弹窗持有的原对象', () {
      final o = SyncDeployOptions();
      final c = o.copy()
        ..continueOnError = true
        ..logQueries = true;
      expect(o.continueOnError, isFalse);
      expect(o.logQueries, isFalse);
      expect(c.continueOnError, isTrue);
      expect(c.logQueries, isTrue);
    });
  });

  group('部署口径:遇错即停 vs 继续跑完', () {
    /// 两张目标侧没有的表 → 两条 CREATE TABLE,都用 'TABLE' 命中失败注入。
    /// 首个失败时剩下那张必然记「未执行」,与差异表的排列顺序无关。
    Future<SyncPlan> plan() =>
        _compare(src: {'t_a': _table('t_a'), 't_b': _table('t_b')});

    test('不注入错误:两个对象都成功', () async {
      final report = await _deploy(await plan());
      expect(report.allOk, isTrue);
      expect(report.successCount, 2);
    });

    test('「遇到错误时继续」没勾(默认):首个失败即中止,其余记「未执行」', () async {
      final report = await _deploy(await plan(),
          stopOnError: true, failOn: 'CREATE TABLE');
      expect(report.successCount, 0);
      expect(report.failureCount, 2);
      expect(
        report.items.where((e) => e.error!.contains('未执行')),
        hasLength(1),
        reason: '首个失败后剩下的对象应记「未执行(前序对象失败,已停止)」',
      );
    });

    test('勾上「遇到错误时继续」:跑完全部对象,失败都是真失败(没有「未执行」)', () async {
      final report = await _deploy(await plan(), failOn: 'CREATE TABLE');
      expect(report.successCount, 0);
      expect(report.failureCount, 2);
      expect(report.items.where((e) => e.error!.contains('未执行')), isEmpty);
      for (final e in report.items) {
        expect(e.error, contains('模拟执行失败'));
      }
    });
  });
}
