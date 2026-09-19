import 'dart:async';

import 'package:daro/app/app_state.dart';
import 'package:daro/app/connection_manager.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:flutter_test/flutter_test.dart';

/// 生产环境常见形态:账号能 `SHOW DATABASES` 列出所有库,但读不了服务器级的
/// mysql.user / pg_roles(1142 SELECT command denied)。
/// 过去展开库时 6 类对象共用一个 try,最后一条 listUsers 抛错就把
/// 已经拉到的表 / 视图 / 函数全部丢弃并把整个库标记为加载失败,
/// 表现为「能列出数据库、却打不开库看表」。
class _FakeDriver implements DatabaseDriver {
  _FakeDriver({this.failing = const {ObjectCategory.user}});

  /// 抛出权限错误的分类(模拟只读账号无权限)
  final Set<ObjectCategory> failing;

  /// close() 被调用次数:分类级降级不应丢弃整条连接
  int closeCount = 0;

  Object? _maybeFail(ObjectCategory category) {
    if (!failing.contains(category)) return null;
    throw StateError(
        "MySQLServerException [1142]: SELECT command denied to user "
        "'prod_nd'@'10.0.0.8' for table '${category.name}'");
  }

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<void> close() async => closeCount++;

  @override
  Future<void> useDatabase(String database) async {}

  @override
  Future<List<String>> listSchemas(String database) async => const [];

  @override
  Future<List<String>> listDatabases() async => const ['bfin'];

  @override
  Future<List<String>> listTables(String database, {String? schema}) {
    final error = _maybeFail(ObjectCategory.table);
    return error == null
        ? Future.value(const ['acct_bill', 'acct_pay'])
        : Future.error(error);
  }

  @override
  Future<List<String>> listViews(String database, {String? schema}) {
    final error = _maybeFail(ObjectCategory.view);
    return error == null ? Future.value(const ['v_bill']) : Future.error(error);
  }

  @override
  Future<List<String>> listMaterializedViews(String database,
      {String? schema}) {
    final error = _maybeFail(ObjectCategory.materializedView);
    return error == null ? Future.value(const []) : Future.error(error);
  }

  @override
  Future<List<String>> listFunctions(String database, {String? schema}) {
    final error = _maybeFail(ObjectCategory.function);
    return error == null ? Future.value(const ['fn_fee']) : Future.error(error);
  }

  @override
  Future<List<String>> listProcedures(String database, {String? schema}) {
    final error = _maybeFail(ObjectCategory.procedure);
    return error == null ? Future.value(const ['pr_settle']) : Future.error(error);
  }

  @override
  Future<List<String>> listUsers(String database) {
    final error = _maybeFail(ObjectCategory.user);
    return error == null
        ? Future.value(const ['prod_nd@10.%'])
        : Future.error(error);
  }

  @override
  Future<Map<String, int>> listTableRowEstimates(String database,
          {String? schema}) async =>
      const {'a': 3};

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 表列表查询可挂起的驱动:用于观察「重载进行中」界面看到的状态
class _GatedDriver extends _FakeDriver {
  _GatedDriver() : super(failing: const {});

  /// 驱动当前返回的表列表
  List<String> tables = const ['a', 'b'];

  /// true 时下一次 listTables 挂起,直到 [release]
  bool hold = false;

  Completer<void>? _release;

  @override
  Future<List<String>> listTables(String database, {String? schema}) async {
    if (hold) {
      final completer = _release = Completer<void>();
      await completer.future;
    }
    return tables;
  }

  @override
  Future<int> countTable(String database, String table,
          {String? schema, String? where}) async =>
      7;

  void release() {
    _release?.complete();
    _release = null;
  }
}

ConnectionInfo get _conn => const ConnectionInfo(
      name: 'c',
      typeId: 'mysql',
      host: 'h',
      port: '3306',
      username: 'prod_nd',
      isLive: true,
    );

void main() {
  group('展开库:分类级降级', () {
    test('角色读取被拒(1142)不影响表 / 视图 / 函数 / 过程展示', () async {
      final manager = ConnectionManager();
      final driver = _FakeDriver();
      manager.attachDriverForTest('c', driver);

      await manager.expandDatabase(_conn, 'bfin');
      final state = manager.tableStateOf('c', 'bfin');

      // 库正常打开:表列表可用
      expect(state.status, LoadStatus.loaded);
      expect(state.error, isNull);
      expect(state.tables, ['acct_bill', 'acct_pay']);
      expect(state.views, ['v_bill']);
      expect(state.functions, ['fn_fee']);
      expect(state.procedures, ['pr_settle']);

      // 失败的那一类单独降级:列表置空 + 记录原因(而不是谎报「没有角色」)
      expect(state.users, isNull);
      expect(state.categoryErrorOf(ObjectCategory.user), contains('1142'));
      expect(state.categoryErrorOf(ObjectCategory.table), isNull);

      // 连接仍然可用:不因单类失败丢弃驱动
      expect(driver.closeCount, 0);
    });

    test('重试后权限恢复即清除该分类的降级错误', () async {
      final manager = ConnectionManager();
      manager.attachDriverForTest('c', _FakeDriver());
      await manager.expandDatabase(_conn, 'bfin');
      expect(
        manager.tableStateOf('c', 'bfin').categoryErrorOf(ObjectCategory.user),
        isNotNull,
      );

      // 换一台「有权限」的驱动后整库重载(retryExpandDatabase 会重置为 idle)
      manager.attachDriverForTest('c', _FakeDriver(failing: const {}));
      await manager.retryExpandDatabase(_conn, 'bfin');
      final state = manager.tableStateOf('c', 'bfin');

      expect(state.status, LoadStatus.loaded);
      expect(state.categoryErrors, isEmpty);
      expect(state.users, ['prod_nd@10.%']);
    });

    test('表列表本身失败才算整库不可用:置错并丢弃连接', () async {
      final manager = ConnectionManager();
      final driver = _FakeDriver(failing: {ObjectCategory.table});
      manager.attachDriverForTest('c', driver);

      await manager.expandDatabase(_conn, 'bfin');
      final state = manager.tableStateOf('c', 'bfin');

      expect(state.status, LoadStatus.error);
      expect(state.error, contains('1142'));
      expect(state.categoryErrors ?? const {}, isEmpty);
      expect(driver.closeCount, 1);
    });

    test('多类同时失败:各自记录原因,成功的分类不受影响', () async {
      final manager = ConnectionManager();
      manager.attachDriverForTest(
        'c',
        _FakeDriver(failing: {ObjectCategory.user, ObjectCategory.function}),
      );

      await manager.expandDatabase(_conn, 'bfin');
      final state = manager.tableStateOf('c', 'bfin');

      expect(state.status, LoadStatus.loaded);
      expect(state.tables, ['acct_bill', 'acct_pay']);
      expect(state.functions, isNull);
      expect(state.users, isNull);
      expect(state.categoryErrorOf(ObjectCategory.function), contains('1142'));
      expect(state.categoryErrorOf(ObjectCategory.user), contains('1142'));
      expect(state.categoryErrorOf(ObjectCategory.procedure), isNull);
    });
  });

  group('对象列表重载:不闪白', () {
    test('已加载时重载期间保留旧列表,新列表就绪后一次性替换且只通知一次',
        () async {
      final manager = ConnectionManager();
      final driver = _GatedDriver();
      manager.attachDriverForTest('c', driver);
      await manager.expandDatabase(_conn, 'bfin');
      final state = manager.tableStateOf('c', 'bfin');
      expect(state.tables, ['a', 'b']);

      driver.hold = true;
      driver.tables = const ['a', 'b', 'c_copy'];
      var notified = 0;
      manager.addListener(() => notified++);

      final reloading = manager.refreshDatabase(_conn, 'bfin');
      await pumpEventQueue();

      // 重载进行中:面板仍是旧列表。置空 + 退到 idle 会让它闪白一次,
      // 顺带丢掉滚动位置与选中项
      expect(state.status, LoadStatus.loaded);
      expect(state.tables, ['a', 'b']);
      expect(notified, 0);

      driver.release();
      await reloading;

      expect(state.status, LoadStatus.loaded);
      expect(state.tables, ['a', 'b', 'c_copy']);
      expect(notified, 1);
    });

    test('列表原本未加载时仍走整重载,拉完即为新列表', () async {
      final manager = ConnectionManager();
      final driver = _GatedDriver();
      driver.tables = const ['x', 'y'];
      manager.attachDriverForTest('c', driver);

      await manager.refreshDatabase(_conn, 'bfin');
      final state = manager.tableStateOf('c', 'bfin');

      expect(state.status, LoadStatus.loaded);
      expect(state.tables, ['x', 'y']);
    });

    test('静默重载后结构版本号 +1、估算行数随重载刷新且不留空档', () async {
      final manager = ConnectionManager();
      manager.attachDriverForTest('c', _GatedDriver());
      await manager.expandDatabase(_conn, 'bfin');
      final state = manager.tableStateOf('c', 'bfin');
      expect(state.rowEstimates, {'a': 3});
      final revision = state.revision ?? 0;

      await manager.refreshDatabase(_conn, 'bfin');

      expect(state.revision, revision + 1);
      expect(state.rowEstimates, {'a': 3});
    });
  });
}
