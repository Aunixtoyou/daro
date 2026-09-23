import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:daro/data/schema_sync.dart';
import 'package:daro/data/table_design.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「结构同步 → 比对」并行化的回归测试(离线假驱动)。
///
/// 比对原来逐对象串行 await,一次线上反馈是「比较数据库慢」。并行化后要钉住:
/// 1. **真的并行了**(同时在读的对象数 > 1),而不只是换了个写法;
/// 2. 并行不打乱差异表顺序(结果按类别 + 名字落位,与完成先后无关);
/// 3. 会话对数**有上限**且用完即关(不能每比一个表就多占一条连接);
/// 4. 首路会话开不出来仍然整体失败;但**多开**被服务器拒掉时只降级不报错;
/// 5. 取消能在对象边界生效,不白跑剩余对象。
///
/// 并发度判定用「同时在读的计数」而非耗时断言:后者在 CI 机器负载下必抖。

ConnectionInfo _conn(String name, String database) => ConnectionInfo(
      name: name,
      typeId: 'postgresql',
      host: '10.255.255.1', // 不可路由:假驱动下永不真正连接
      port: '5432',
      username: 'u',
      password: 'p',
      database: database,
      isLive: true,
    );

DesignTable _table(String name) {
  final t = DesignTable()
    ..name = name
    ..schema = 'public'
    ..pkName = '${name}_pkey';
  t.columns.add(DesignColumn(
      name: 'id', type: 'int4', length: '', primaryKey: true));
  return t;
}

/// 假驱动:可观测「同时在读几个」「开了几路会话」「按什么库名开的会话」。
class _Fake implements DatabaseDriver {
  _Fake(this.tag, this.tables, this.probe, {required String database})
      : _database = database;

  /// src / tgt,用于统计两侧的 connect 次数
  final String tag;
  final Map<String, DesignTable> tables;
  final _Probe probe;
  final String _database;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {
    // 握手时才登记:compareSchemaSync 开头为「类型可否驱动」探测性造的实例永不连接
    probe.connectionDefaults.add(_database);
    probe.connects[tag] = (probe.connects[tag] ?? 0) + 1;
    if (probe.connectBudget >= 0 &&
        probe.connects.values.reduce((a, b) => a + b) > probe.connectBudget) {
      // 复刻「顶到服务器 max_connections」:再开就报 too many connections
      throw Exception('FATAL: sorry, too many connections already');
    }
  }

  @override
  Future<void> close() async {
    probe.closes++;
  }

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
      const [];

  @override
  Future<DesignTable?> readTableDesign(String database, String table,
      {String? schema}) async {
    probe.inFlight++;
    if (probe.inFlight > probe.maxInFlight) probe.maxInFlight = probe.inFlight;
    probe.reads++;
    // 让重叠窗口足够宽:没有并行时这个计数永远回不到 2
    await Future<void>.delayed(const Duration(milliseconds: 30));
    try {
      return tables[table];
    } finally {
      probe.inFlight--;
    }
  }

  @override
  Future<SequenceDef?> readSequence(String database, String name,
          {String? schema}) async =>
      null;
  @override
  Future<QueryResult> executeQuery(String sql,
          {int limit = 1000, int offset = 0}) async =>
      QueryResult(columns: const [], rows: const []);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Probe {
  /// 允许开出的会话总数(超出即「服务器拒绝连接」);-1 = 不限
  int connectBudget = -1;

  /// 每侧的 connect 次数(一路会话 = 源 + 目标各一次)
  final Map<String, int> connects = {'src': 0, 'tgt': 0};
  int closes = 0;
  int reads = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  /// 工厂每次拿到的「连接默认库」—— 决定握手时连到哪个库
  final connectionDefaults = <String>[];
}

/// 用同一批表名跑一次比对;源、目标结构一致时全部应为「无操作」。
Future<SyncPlan> _run(
  List<String> names, {
  int workers = kDefaultCompareWorkers,
  bool Function()? isCancelled,
  void Function(String, int, int)? onProgress,
  int connectBudget = -1,
  String sourceDatabase = 'src_db',
  _Probe? probe,
}) {
  final p = probe ?? _Probe()..connectBudget = connectBudget;
  final srcTables = {for (final n in names) n: _table(n)};
  return compareSchemaSync(
    source: SyncEndpoint(
        connection: _conn('src_conn', 'default_db'),
        database: sourceDatabase,
        schema: 'public'),
    target: SyncEndpoint(
        connection: _conn('tgt_conn', 'default_db'),
        database: 'tgt_db',
        schema: 'public'),
    // 工厂收到的连接名决定身份,库名由 _Side 定位(见 _Probe.connectionDefaults)
    driverFactory: (conn) => _Fake(
        conn.name == 'src_conn' ? 'src' : 'tgt', srcTables, p,
        database: conn.database),
    compareWorkers: workers,
    isCancelled: isCancelled,
    onProgress: onProgress,
    options: SyncOptions()..sequences = false,
  );
}

void main() {
  test('并行:同时比对多个对象,而不是一个接一个排队', () async {
    final names = [for (var a = 0; a < 8; a++) 't$a'];
    final p = _Probe();
    final plan = await _run(names, workers: 4, probe: p);

    expect(plan.errors, isEmpty, reason: '${plan.errors}');
    expect(plan.objects, hasLength(names.length));
    // 串行(含「只并行两侧」)最多 2 路同时在读;4 路会话应稳定越过这个数
    expect(p.maxInFlight, greaterThanOrEqualTo(4),
        reason: '同时在读只有 ${p.maxInFlight} 路 —— 按对象并行没生效');
  });

  test('并行不打乱顺序:差异表仍按名字稳定落位', () async {
    final names = ['m4', 'm1', 'm3', 'm2', 'm7', 'm5', 'm6', 'm8'];
    final plan = await _run(names, workers: 4);
    expect(plan.objects.map((o) => o.name).toList(),
        ['m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'm8']);
    // 结果按索引写回,任何一个对象都不该被漏掉或重复
    expect(plan.objects.map((o) => o.name).toSet(), hasLength(names.length));
    for (final o in plan.objects) {
      expect(o.action, SyncAction.none, reason: '${o.name} 结构一致却判成 ${o.action}');
      expect(o.blocked, isFalse, reason: '${o.name} 被标错:${o.note}');
    }
  });

  test('会话有上限且用完即关:不多占连接、不漏会话', () async {
    final p = _Probe();
    await _run([for (var a = 0; a < 12; a++) 't$a'], workers: 3, probe: p);
    // 12 个对象也只开 3 路;每路 = 源 + 目标各一次 connect
    expect(p.connects['src'], 3);
    expect(p.connects['tgt'], 3);
    expect(p.closes, 6, reason: '有会话没关:线上会攒出僵尸连接');

    // 对象数少于并发度时按需扩容,不开满
    final few = _Probe();
    await _run(['a', 'b'], workers: 4, probe: few);
    expect(few.connects['src'], 2, reason: '两个对象开了四路 = 白握手');
  });

  test('多开被服务器拒掉时降级复用,不整体失败', () async {
    final p = _Probe();
    final plan = await _run(
      [for (var a = 0; a < 6; a++) 't$a'],
      workers: 4,
      // 只够第一路会话(源 + 目标),之后每路握手都被拒
      connectBudget: 2,
      probe: p,
    );
    expect(plan.errors, isEmpty, reason: '${plan.errors}');
    expect(plan.objects, hasLength(6), reason: '降级后必须照样比完全部对象');
    expect(plan.objects.every((o) => !o.blocked), isTrue,
        reason: plan.objects.where((o) => o.blocked).map((o) => o.note).join('|'));
    expect(p.connects.values.reduce((a, b) => a + b), lessThanOrEqualTo(8),
        reason: '被拒后还在按对象逐个重试握手 = 白挨一堆连接错误');
  });

  test('首路会话开不出来:整体失败而不是产出空差异表', () async {
    final plan = await _run(
      ['t1', 't2'],
      connectBudget: 0,
      probe: _Probe(),
    );
    expect(plan.objects, isEmpty);
    expect(plan.errors, isNotEmpty);
    expect(plan.errors.first, contains('too many connections'));
  });

  test('取消:不再领新任务,产出标记为半成品的计划', () async {
    final p = _Probe();
    final plan = await _run(
      [for (var a = 0; a < 8; a++) 't$a'],
      workers: 4,
      isCancelled: () => true,
      probe: p,
    );
    expect(plan.canceled, isTrue);
    expect(p.reads, 0, reason: '取消后还去读结构 = 白等一轮网络往返');
  });

  test('进度回调按对象完成递增到总数(覆盖层进度条据此走满)', () async {
    final seen = <(int, int)>[];
    final plan = await _run(
      [for (var a = 0; a < 5; a++) 't$a'],
      workers: 2,
      onProgress: (stage, done, total) => seen.add((done, total)),
    );
    expect(plan.objects, hasLength(5));
    final tableProgress = seen.where((e) => e.$2 == 5).toList();
    expect(tableProgress.map((e) => e.$1).toList(), [1, 2, 3, 4, 5]);
  });

  test('会话直接开在要比对的库上:省掉 PG 的「先连默认库再重连」', () async {
    final p = _Probe();
    await _run(['t1'], workers: 1, probe: p, sourceDatabase: 'daowei_dev');
    // 连接配置里的默认库是 default_db,而要比对的是 daowei_dev / tgt_db:
    // 握手必须先落在后者,否则 PG 家族会在 useDatabase 时断开重连(每路多一次握手)
    expect(p.connectionDefaults, containsAll(['daowei_dev', 'tgt_db']));
    expect(p.connectionDefaults, isNot(contains('default_db')));
  });
}
