/// MCP 专用驱动实例池(简报 §6 W4 / 痛点 P4)。
///
/// 为什么必须存在:agent 一轮对话连打 10 个工具,若每次新建驱动就是 10 次
/// TCP+TLS+认证握手(握手超时本身就定在 10s),慢到不可用;若复用连接树上
/// 那条长连接,`useDatabase` 会把用户查询页的运行上下文带偏
/// (本仓在 `schema_sync.dart` 付过学费)。所以 MCP 用**自己的池**:
/// - 键 = `连接名|数据库|模式`,同键复用、串行执行(单条连接无法并发查询);
/// - 空闲超过 `idleTtl` 在每次 acquire 时惰性清扫(不起定时器,策略改动即时生效);
/// - 实例数达 `maxDrivers` 时**直接抛 poolExhausted,不排队**
///   (排队会让 agent 等到 QUERY_TIMEOUT 还拿不到真因);
/// - 超时 / 取消失败 / 连接级错误的实例经 [Lease.markDirty] 销毁,**绝不回池**
///   (P2:不能把一条仍在跑语句的连接交给下一个请求)。
///
/// ⚠️ 本文件禁止 import package:flutter(CI 卡死,见 tool/check_mcp_purity.dart)。
library;

import 'dart:async';

import '../data/db_data.dart';
import '../data/drivers/db_driver.dart';
import 'mcp_errors.dart';

/// 池键:`连接名|数据库|模式`。空值统一摊平成空串,保证同一目标算出同一个键。
class McpPoolKey {
  const McpPoolKey(this.connection, [this.database = '', this.schema = '']);

  final String connection;
  final String database;
  final String schema;

  String get value => '$connection|$database|$schema';

  /// 该键是否属于某连接(改名守卫 / 编辑连接时按连接整体失效)。
  bool belongsTo(String connectionName) => connection == connectionName;

  @override
  String toString() => value;
}

/// 借出凭证:每个 lease 必须二选一收尾 —— [release] 回池 / [markDirty] 销毁。
class Lease {
  Lease._(this.key, this.driver, this._pool);

  final McpPoolKey key;
  final DatabaseDriver driver;

  /// 借用方自由标注的连接类型 id(池不解读):工具层据此区分
  /// 「服务端封顶走 LIMIT 改写还是流式游标」这类引擎差异。
  String? typeId;

  final McpDriverPool _pool;
  bool _settled = false;

  /// 正常归还:实例回池,空闲计时从此刻起算。
  void release() {
    if (_settled) return;
    _settled = true;
    _pool._release(this);
  }

  /// 脏实例销毁:close 后从池移除,不交给下一个请求(超时/取消失败/连接断裂)。
  Future<void> markDirty() async {
    if (_settled) return;
    _settled = true;
    await _pool._discard(this);
  }
}

/// 驱动工厂(测试注入假驱动;生产即 `createDriver`)。
typedef PoolDriverFactory = DatabaseDriver? Function(ConnectionInfo conn);

class McpDriverPool {
  McpDriverPool({PoolDriverFactory? driverFactory})
      : _factory = driverFactory ?? createDriver;

  final PoolDriverFactory _factory;

  final _entries = <String, _PoolEntry>{};
  bool _closed = false;

  /// 当前实例数(含正在握手的)。设置页 / 状态栏展示用。
  int get activeCount => _entries.length;

  /// 池内活动键(改名守卫要检测「该名字有活驱动」)。
  List<McpPoolKey> get activeKeys => [for (final e in _entries.values) e.key];

  /// 借一个**已定位好运行上下文**(useDatabase / useSchema)的驱动实例。
  ///
  /// [conn] 必须是最终形态(密码已补齐)—— 池不知道弹窗流程的存在。
  /// `maxDrivers` / `idleTtl` 由调用方从**当次重读的策略**传入:
  /// 池自己不存策略,天然满足「改权限不必重启客户端」。
  /// 失败以 [McpException] 抛出:`driverUnsupported` / `connectionFailed` /
  /// `poolExhausted`。
  Future<Lease> acquire(
    ConnectionInfo conn, {
    String database = '',
    String? schema,
    int maxDrivers = 8,
    Duration idleTtl = const Duration(minutes: 10),
  }) async {
    // 驱动可用性在占用池位之前判:不支持的类型不该消耗并发额度(P5)。
    if (!hasDriver(conn)) {
      throw McpException(
        McpErrorCode.driverUnsupported,
        message: 'daro 当前不支持 ${conn.typeId} 类型的驱动',
      );
    }
    final key = McpPoolKey(conn.name, database, schema ?? '');
    while (true) {
      if (_closed) throw McpException.internal('MCP 驱动池已关闭');
      _sweepIdle(idleTtl);
      final entry = _entries[key.value] ?? _createEntry(key, conn, maxDrivers);
      try {
        return await _take(entry, key);
      } on _EntryGone {
        // 等待期间实例被归还给别人又抢走 / 被销毁 / 被驱逐:
        // 回循环顶部重新要。open 失败不走这条路(直接把异常抛给全部等待者),
        // 因此这里不存在「失败→重建→再失败」的重试风暴。
        continue;
      }
    }
  }

  _PoolEntry _createEntry(McpPoolKey key, ConnectionInfo conn, int maxDrivers) {
    if (_entries.length >= maxDrivers) {
      throw McpException(
        McpErrorCode.poolExhausted,
        message: 'MCP 专用连接数已达上限($maxDrivers)',
        retryable: true,
        retryAfterMs: 2000,
      );
    }
    final entry = _PoolEntry(key);
    _entries[key.value] = entry;
    entry.opening = _open(entry, conn);
    return entry;
  }

  /// 等实例就绪后借出;若正被别的请求持有,等它的归还/销毁信号。
  /// Dart 单 isolate:`idle` 的检查与翻转之间没有 await,借出是原子的;
  /// 竞争失败的等待者拿到的必然是新 completer(_take 借出时更换)。
  Future<Lease> _take(_PoolEntry entry, McpPoolKey key) async {
    final opening = entry.opening;
    if (opening != null) {
      // 建连异常在这里传播给每一个 await 同一次 open 的请求。
      await opening;
    }
    if (!entry.alive) throw const _EntryGone();
    if (!entry.idle || entry.driver == null) {
      final released = await entry.released.future;
      if (!released || !entry.alive) throw const _EntryGone();
    }
    if (!entry.idle || entry.driver == null) throw const _EntryGone();
    entry.idle = false;
    entry.released = Completer<bool>();
    return Lease._(key, entry.driver!, this);
  }

  Future<void> _open(_PoolEntry entry, ConnectionInfo conn) async {
    final driver = _factory(conn);
    if (driver == null) {
      // createDriver 认不出的 typeId(与 hasDriver 双保险)。
      _entries.remove(entry.key.value);
      throw McpException(
        McpErrorCode.driverUnsupported,
        message: 'daro 当前不支持 ${conn.typeId} 类型的驱动',
      );
    }
    try {
      await driver.connect();
      if (conn.database.isNotEmpty && conn.database != entry.key.database) {
        await driver.useDatabase(conn.database);
      }
      if (entry.key.database.isNotEmpty) {
        await driver.useDatabase(entry.key.database);
      }
      if (kUseSchemaTypes.contains(conn.typeId)) {
        await driver.useSchema(entry.key.schema.isEmpty ? null : entry.key.schema);
      }
    } catch (e) {
      await _closeQuietly(driver);
      _entries.remove(entry.key.value);
      throw McpException(
        McpErrorCode.connectionFailed,
        message: '连接失败: $e',
        retryable: true,
      );
    }
    entry.driver = driver;
    entry.idle = true;
    entry.touch();
  }

  /// 归还:回池并刷新空闲起点,唤醒等待者。
  void _release(Lease lease) {
    final entry = _entries[lease.key.value];
    if (entry == null || entry.driver != lease.driver) return; // 已被丢弃
    entry.idle = true;
    entry.touch();
    if (!entry.released.isCompleted) entry.released.complete(true);
  }

  /// 销毁脏实例(超时 / 取消失败 / 连接级错误后调用)。
  Future<void> _discard(Lease lease) async {
    final entry = _entries.remove(lease.key.value);
    if (entry == null) return;
    if (entry.driver == lease.driver) {
      await _closeQuietly(lease.driver);
      entry.driver = null;
    }
    entry.notifyGone();
  }

  /// 空闲回收:TTL 从最后一次归还起算;被持有或建连中的键**永不清扫**
  /// (不能关掉正在跑语句的连接,也不能掐断等待者)。
  void _sweepIdle(Duration idleTtl) {
    if (_entries.isEmpty) return;
    final now = DateTime.now();
    final doomed = <_PoolEntry>[];
    for (final e in _entries.values) {
      if (e.idle && e.driver != null && now.difference(e.lastUsed) > idleTtl) {
        doomed.add(e);
      }
    }
    for (final e in doomed) {
      _entries.remove(e.key.value);
      unawaited(_closeQuietly(e.driver!));
      e.notifyGone();
    }
  }

  /// 连接被删除 / 改名 / 编辑配置后:丢弃该连接的全部实例。
  /// 等待中的请求因 [_EntryGone] 重试,用新配置重新握手。
  Future<void> invalidateConnection(String connectionName) async {
    final doomed =
        _entries.values.where((e) => e.key.belongsTo(connectionName)).toList();
    for (final e in doomed) {
      _entries.remove(e.key.value);
      if (e.driver != null) await _closeQuietly(e.driver!);
      e.notifyGone();
    }
  }

  /// 停服 / 退出时清空全部实例。
  Future<void> dispose() async {
    _closed = true;
    final all = _entries.values.toList();
    _entries.clear();
    for (final e in all) {
      if (e.driver != null) await _closeQuietly(e.driver!);
      e.notifyGone();
    }
  }

  /// 关闭驱动,带 3 秒看门狗:半断的连接的 close() 也可能挂死,
  /// 不能让它卡住清扫/销毁循环 —— 超时即弃,残骸交给 GC。
  Future<void> _closeQuietly(DatabaseDriver driver) async {
    try {
      await driver.close().timeout(const Duration(seconds: 3));
    } catch (_) {
      // 关不上就当它已经死了。
    }
  }
}

/// 一个池键:实例 + 忙闲 + 空闲起点 + 建连状态 + 归还/销毁信号。
class _PoolEntry {
  _PoolEntry(this.key);

  final McpPoolKey key;
  DatabaseDriver? driver;
  Future<void>? opening;

  /// 是否空闲可借。初始 true 无妨:driver 为 null 时借出逻辑先等 open。
  bool idle = true;

  /// 最近一次归还(或刚建好)时刻,TTL 起算点。
  DateTime lastUsed = DateTime.now();

  /// 是否仍在池中。
  bool alive = true;

  /// 每次借出时更换;等待者 await 的是**自己借之前那一次**的信号:
  /// true = 归还(可尝试再借),false = 实例没了(调用方重试)。
  Completer<bool> released = Completer<bool>();

  void touch() => lastUsed = DateTime.now();

  void notifyGone() {
    alive = false;
    if (!released.isCompleted) released.complete(false);
  }
}

/// 等待期间实例被抢走/销毁/驱逐 —— acquire 的重试循环消化它。
class _EntryGone implements Exception {
  const _EntryGone();
}
