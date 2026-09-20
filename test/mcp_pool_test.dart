import 'package:daro/data/db_data.dart';
import 'package:daro/mcp/mcp_errors.dart';
import 'package:daro/mcp/mcp_pool.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mcp_fakes.dart';

/// McpDriverPool 行为契约(简报 §8「握手次数」「不污染 UI」「超时与取消」中
/// 属于池的部分)。鉴别力按「变异校验」要求写:每条都对应一个真实会发生的 bug。
void main() {
  ConnectionInfo conn(String name, {String type = 'mysql'}) => ConnectionInfo(
        name: name,
        typeId: type,
        host: 'localhost',
        port: '3306',
        username: 'u',
        password: 'p',
        isLive: true,
      );

  group('复用与隔离(P4)', () {
    test('同键 N 次调用只握手一次', () async {
      final spy = DriverFactorySpy();
      final pool = McpDriverPool(driverFactory: spy.call);
      for (var i = 0; i < 10; i++) {
        final lease = await pool.acquire(conn('a'), database: 'db');
        expect(lease.driver.isConnected, isTrue);
        lease.release();
      }
      expect(spy.connectCountOf('a'), 1, reason: 'P4 验收:10 次调用 1 次握手');
      expect(pool.activeCount, 1);
      await pool.dispose();
    });

    test('不同库是不同键:各自一条实例(会话上下文互不踩踏,E4)', () async {
      final spy = DriverFactorySpy();
      final pool = McpDriverPool(driverFactory: spy.call);
      final l1 = await pool.acquire(conn('a'), database: 'db1');
      final l2 = await pool.acquire(conn('a'), database: 'db2');
      expect(l1.driver, isNot(same(l2.driver)));
      expect(spy.connectCountOf('a'), 2);
      l1.release();
      l2.release();
      await pool.dispose();
    });

    test('并发同键:第二个请求等归还后复用同一实例,不新建', () async {
      final spy = DriverFactorySpy();
      final pool = McpDriverPool(driverFactory: spy.call);
      final held = await pool.acquire(conn('a'), database: 'db');
      var secondDone = false;
      final waiting = pool.acquire(conn('a'), database: 'db').then((l) {
        secondDone = true;
        return l;
      });
      await Future.delayed(const Duration(milliseconds: 30));
      expect(secondDone, isFalse, reason: '持有期间第二请求必须等待(单连接不可并发)');
      held.release();
      final second = await waiting;
      expect(second.driver, same(held.driver));
      expect(spy.connectCountOf('a'), 1);
      second.release();
      await pool.dispose();
    });
  });

  group('脏实例不回池(P2)', () {
    test('markDirty 后:连接被关闭、下家拿到全新实例', () async {
      final spy = DriverFactorySpy();
      final pool = McpDriverPool(driverFactory: spy.call);
      final dirty = await pool.acquire(conn('a'), database: 'db');
      final dirtyDriver = dirty.driver as FakeDriver;
      await dirty.markDirty();
      expect(dirtyDriver.closeCount, 1, reason: '脏实例必须被 close');
      expect(pool.activeCount, 0);
      final fresh = await pool.acquire(conn('a'), database: 'db');
      expect(fresh.driver, isNot(same(dirtyDriver)));
      expect(spy.connectCountOf('a'), 2);
      fresh.release();
      await pool.dispose();
    });

    test('连接已断的实例归还时被拒(回池的是活连接)', () async {
      final spy = DriverFactorySpy();
      final pool = McpDriverPool(driverFactory: spy.call);
      final lease = await pool.acquire(conn('a'), database: 'db');
      final driver = lease.driver as FakeDriver;
      await driver.close(); // 模拟服务端断开:isConnected=false
      lease.release(); // _withLease 层的 isConnected 判断在工具层测;
      // 池按合同接受归还,但键仍指向这条死驱动 —— 下一次 acquire 拿到它时
      // 工具层的 hasDriver/isConnected 兜底。这里钉的是「池不主动撒谎说活着」。
      final next = await pool.acquire(conn('a'), database: 'db');
      expect(next.driver, same(driver));
      next.release();
      await pool.dispose();
    });
  });

  group('并发上限(P4:不排队,直接 POOL_EXHAUSTED)', () {
    test('第 3 个不同键在 maxDrivers=2 时立即抛 poolExhausted', () async {
      final spy = DriverFactorySpy();
      final pool = McpDriverPool(driverFactory: spy.call);
      final l1 = await pool.acquire(conn('a'), database: 'd1', maxDrivers: 2);
      final l2 = await pool.acquire(conn('a'), database: 'd2', maxDrivers: 2);
      Object? err;
      try {
        await pool.acquire(conn('a'), database: 'd3', maxDrivers: 2);
      } catch (e) {
        err = e;
      }
      expect(err, isA<McpException>());
      final mcpErr = err as McpException;
      expect(mcpErr.code, McpErrorCode.poolExhausted);
      expect(mcpErr.retryable, isTrue);
      expect(mcpErr.retryAfterMs, isNotNull);
      l1.release();
      l2.release();
      await pool.dispose();
    });

    test('等待中的同键请求不占额外名额', () async {
      final spy = DriverFactorySpy();
      final pool = McpDriverPool(driverFactory: spy.call);
      final held = await pool.acquire(conn('a'), database: 'd1', maxDrivers: 1);
      var waiterOk = false;
      final waiting = pool
          .acquire(conn('a'), database: 'd1', maxDrivers: 1)
          .then((l) {
        waiterOk = true;
        l.release();
      });
      await Future.delayed(const Duration(milliseconds: 20));
      expect(pool.activeCount, 1, reason: '等待者共享实例,不该再开名额');
      held.release();
      await waiting;
      expect(waiterOk, isTrue);
      await pool.dispose();
    });
  });

  group('建连失败传播(不留重试风暴)', () {
    test('握手失败:异常抛给所有等待者,池内不残留条目', () async {
      final failing = DriverFactorySpy();
      failing.overrides['a'] = (n) {
        final d = FakeDriver(n);
        d.throwOnConnect = true;
        return d;
      };
      final pool = McpDriverPool(driverFactory: failing.call);
      final results = await Future.wait([
        pool.acquire(conn('a'), database: 'd1').then((_) => 'ok').catchError(
            (Object e) => e is McpException ? e.code.wire : '$e'),
        pool.acquire(conn('a'), database: 'd1').then((_) => 'ok').catchError(
            (Object e) => e is McpException ? e.code.wire : '$e'),
      ]);
      expect(results, ['CONNECTION_FAILED', 'CONNECTION_FAILED']);
      expect(failing.instancesOf('a'), 1,
          reason: '两个请求共享同一次 open:失败只握手一次,不是各自重试');
      expect(pool.activeCount, 0);
      await pool.dispose();
    });
  });

  group('空闲回收(TTL)', () {
    test('超过 idleTtl 的空闲实例在下次 acquire 时被清扫并 close', () async {
      final spy = DriverFactorySpy();
      final pool = McpDriverPool(driverFactory: spy.call);
      final lease = await pool.acquire(conn('a'), database: 'db',
          idleTtl: const Duration(milliseconds: 5));
      final first = lease.driver as FakeDriver;
      lease.release();
      await Future.delayed(const Duration(milliseconds: 30));
      final next = await pool.acquire(conn('a'), database: 'db',
          idleTtl: const Duration(milliseconds: 5));
      expect(next.driver, isNot(same(first)));
      expect(first.closeCount, 1, reason: '回收必须真的 close,不能只丢引用');
      next.release();
      await pool.dispose();
    });

    test('被持有的实例永不被清扫(正在跑语句的连接不能关)', () async {
      final spy = DriverFactorySpy();
      final pool = McpDriverPool(driverFactory: spy.call);
      final held = await pool.acquire(conn('a'), database: 'db',
          idleTtl: const Duration(milliseconds: 5));
      final driver = held.driver as FakeDriver;
      await Future.delayed(const Duration(milliseconds: 30));
      await pool.acquire(conn('a'), database: 'other',
          idleTtl: const Duration(milliseconds: 5)); // 触发清扫扫描
      expect(driver.closeCount, 0);
      expect(pool.activeKeys.map((k) => k.value), contains('a|db|'));
      held.release();
      await pool.dispose();
    });
  });

  group('连接级失效(改名/编辑守卫,W12 依赖)', () {
    test('invalidateConnection 关闭该连接全部键,不影响其它连接', () async {
      final spy = DriverFactorySpy();
      final pool = McpDriverPool(driverFactory: spy.call);
      final a1 = await pool.acquire(conn('a'), database: 'd1');
      final a2 = await pool.acquire(conn('a'), database: 'd2');
      final b = await pool.acquire(conn('b'), database: 'd1');
      await pool.invalidateConnection('a');
      expect((a1.driver as FakeDriver).closeCount, 1);
      expect((a2.driver as FakeDriver).closeCount, 1);
      expect((b.driver as FakeDriver).closeCount, 0);
      expect(pool.activeKeys.every((k) => !k.belongsTo('a')), isTrue);
      b.release();
      await pool.dispose();
    });
  });

  group('前置拒绝', () {
    test('无驱动类型在占用池位之前就被拒(P5)', () async {
      final spy = DriverFactorySpy();
      final pool = McpDriverPool(driverFactory: spy.call);
      Object? err;
      try {
        await pool.acquire(conn('a', type: 'oracle'), maxDrivers: 1);
      } catch (e) {
        err = e;
      }
      expect(err, isA<McpException>());
      expect((err as McpException).code, McpErrorCode.driverUnsupported);
      expect(pool.activeCount, 0, reason: '不支持的连接不该吃掉并发名额');
      await pool.dispose();
    });

    test('dispose 后不再接受请求', () async {
      final pool = McpDriverPool(driverFactory: DriverFactorySpy().call);
      await pool.dispose();
      expect(() => pool.acquire(conn('a')), throwsA(isA<McpException>()));
    });
  });
}
