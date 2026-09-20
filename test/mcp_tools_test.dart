/// MCP 工具层单测:钉死简报 §8 的验收不变量。
///
/// 这些用例的价值在于「**默认安全**」——每一条都对应一个如果做错了就会
/// 让 agent 拿到不该拿到的能力的场景:未启用 / 未授权 / 未列进 allowlist
/// 的工具必须在**服务端**被拒,而不是只在设置页藏起来;密码永不外泄;
/// 超时的连接实例绝不带着未finish 的语句回池。
///
/// 假驱动不连真库(见 `mcp_fakes.dart`),因此这里跑得和纯函数一样快,
/// 也只有 `_guarded` 的超时用例需要真等一秒。
import 'dart:convert';

import 'package:daro/data/db_data.dart';
import 'package:daro/data/table_design.dart';
import 'package:daro/mcp/mcp_policy.dart';
import 'package:daro/mcp/mcp_pool.dart';
import 'package:daro/mcp/mcp_tools.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mcp_fakes.dart';

void main() {
  group('默认安全:判定链在服务端强校验', () {
    test('策略未启用:一切工具都回 SERVICE_DISABLED,不建驱动', () async {
      final h = Harness(policy: enabledPolicy(enabled: false));
      final err = await h.err('daro_list_connections');
      expect(err['code'], 'SERVICE_DISABLED');
      expect(h.spy.created, isEmpty);
    });

    test('allowlist 未勾的工具:列表里隐藏,调用同样被拒(服务端不靠 UI)', () async {
      final h = Harness(policy: enabledPolicy(tools: ['daro_list_connections']));
      final listed = await h.service.toolDefinitions();
      expect(listed.map((t) => t['name']), ['daro_list_connections']);

      final err = await h.err('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT 1'});
      expect(err['code'], 'TOOL_NOT_ALLOWED');
      expect(h.spy.created, isEmpty, reason: '被拒的调用不该已经握手');
    });

    test('「连接不存在」与「未授权」合并为同一码,不给 agent 探测连接名', () async {
      final h = Harness(
        policy: enabledPolicy(scopeAll: false, names: ['a']),
        conns: [fakeConn('a'), fakeConn('b')],
      );
      final unknown = await h.err('daro_list_databases', {'connection': 'nope'});
      final unauthorized =
          await h.err('daro_list_databases', {'connection': 'b'});
      expect(unknown['code'], 'CONNECTION_NOT_VISIBLE');
      expect(unauthorized['code'], unknown['code']);
    });

    test('库范围外的库:DATABASE_OUT_OF_SCOPE', () async {
      final h = Harness(
        policy: enabledPolicy(rules: [
          McpConnectionRule(
            connection: 'a',
            databaseScope: McpDatabaseScope.only(['db_a']),
          ),
        ]),
      );
      final err = await h.err('daro_execute_query',
          {'connection': 'a', 'database': 'secret', 'sql': 'SELECT 1'});
      expect(err['code'], 'DATABASE_OUT_OF_SCOPE');
      expect(h.spy.created, isEmpty);
    });

    test('无驱动类型:list_connections 标 supported:false,调用回 DRIVER_UNSUPPORTED',
        () async {
      final h = Harness(
        policy: enabledPolicy(scopeAll: false, names: ['a', 'ora']),
        conns: [fakeConn('a'), fakeConn('ora', typeId: 'oracle', password: '')],
      );
      final payload = await h.ok('daro_list_connections');
      final items = payload['connections'] as List;
      expect(
        items.firstWhere((e) => (e as Map)['name'] == 'ora'),
        containsPair('supported', false),
      );

      final err = await h.err('daro_list_databases', {'connection': 'ora'});
      expect(err['code'], 'DRIVER_UNSUPPORTED');
      expect(err['retryable'], isFalse);
      expect(h.spy.created, isEmpty, reason: 'P5:不支持的类型不能占池位');
    });

    test('D7:任何返回里都不出现密码原文', () async {
      final h = Harness(
        policy: enabledPolicy(scopeAll: false, names: ['a']),
        conns: [fakeConn('a', password: 'sup3r-s3cret')],
      );
      final payload = await h.ok('daro_list_connections');
      expect(jsonEncode(payload), isNot(contains('sup3r-s3cret')));
      expect(
        jsonEncode(payload),
        contains('"username":"root"'),
        reason: '定位信息要保留,agent 才知道选哪条连接',
      );
    });

    test('缺少必填参数:INVALID_PARAMS(不落到驱动)', () async {
      final h = Harness();
      final err = await h.err('daro_execute_query', {'connection': 'a'});
      expect(err['code'], 'INVALID_PARAMS');
      expect(h.spy.created, isEmpty);
    });
  });

  group('执行模式与语句分类(D6 白名单)', () {
    test('只读档:SELECT 放行,INSERT 被 MODE_DENIED', () async {
      final h = Harness();
      final ok = await h.ok(
          'daro_execute_query', {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT 1'});
      expect(ok['columns'], ['ok']);

      final err = await h.err('daro_execute_query', {
        'connection': 'a',
        'database': 'db_a',
        'sql': "INSERT INTO t VALUES (1, 'x')",
      });
      expect(err['code'], 'MODE_DENIED');
      expect(h.driver.executedSql, ['SELECT 1'], reason: '被拒的写入不能到引擎');
    });

    test('数据读写档:全表 UPDATE 回 WHERE_TOO_BROAD(提示补 WHERE 而非换档)',
        () async {
      final h = Harness(policy: enabledPolicy(defaultMode: McpMode.readWrite));
      for (final sql in [
        'UPDATE t SET a = 1',
        'DELETE FROM t',
        'UPDATE t SET a = 1 WHERE 1 = 1',
        'DELETE FROM t WHERE TRUE',
      ]) {
        final err = await h.err(
            'daro_execute_query', {'connection': 'a', 'database': 'db_a', 'sql': sql});
        expect(err['code'], 'WHERE_TOO_BROAD', reason: sql);
      }
      expect(h.spy.created, isEmpty, reason: '被拒的写入不该建连,更不该到引擎');
    });

    test('数据读写档:带有效 WHERE 的写入放行,并回 affectedRows', () async {
      final h = Harness(policy: enabledPolicy(defaultMode: McpMode.readWrite));
      final payload = await h.ok('daro_execute_query', {
        'connection': 'a',
        'database': 'db_a',
        'sql': 'UPDATE t SET a = 1 WHERE id = 2',
      });
      expect(payload['affectedRows'], 7);
      expect(payload['rowCapApplied'], true, reason: '非 SELECT 谈不上封顶');
    });

    test('认不出的语句按完全访问处理:readWrite 拒、full 放行', () async {
      final rw = Harness(policy: enabledPolicy(defaultMode: McpMode.readWrite));
      final err =
          await rw.err('daro_execute_query', {'connection': 'a', 'database': 'db_a', 'sql': 'CALL pr_sync()'});
      expect(err['code'], 'MODE_DENIED');

      final full = Harness(policy: enabledPolicy(defaultMode: McpMode.full));
      await full.ok('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'CALL pr_sync()'});
    });

    test('连接级模式覆盖优先于全局默认(按库/按连接收紧)', () async {
      final h = Harness(
        policy: enabledPolicy(
          defaultMode: McpMode.full,
          rules: [McpConnectionRule(connection: 'a', mode: McpMode.readonly)],
        ),
      );
      final err = await h.err('daro_execute_query', {
        'connection': 'a',
        'database': 'db_a',
        'sql': 'TRUNCATE TABLE t',
      });
      expect(err['code'], 'MODE_DENIED');
    });
  });

  group('行数夹取与服务端封顶(P1)', () {
    test('max_rows 越界夹到硬上限,缺省用策略默认值', () async {
      final h = Harness(policy: enabledPolicy(maxRows: 50, hardRowCap: 1000));
      await h.ok('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT * FROM t', 'max_rows': 5000});
      expect(h.driver.lastLimit, 1000);

      await h.ok('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT * FROM t'});
      expect(h.driver.lastLimit, 50);

      await h.ok('daro_execute_query', {
        'connection': 'a',
        'database': 'db_a',
        'sql': 'SELECT * FROM t',
        'max_rows': 5000,
        'offset': 200,
      });
      expect(h.driver.lastOffset, 200);
    });

    test('自带 LIMIT 的 SELECT:rowCapApplied:false + ROW_CAP_NOT_APPLIED 警告',
        () async {
      final h = Harness();
      final payload = await h.ok('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT * FROM t LIMIT 5'});
      expect(payload['rowCapApplied'], isFalse);
      expect(payload['warnings'], ['ROW_CAP_NOT_APPLIED']);
    });

    test('无 LIMIT 的 SELECT:封顶生效,无警告', () async {
      final h = Harness();
      final payload = await h.ok('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT * FROM t'});
      expect(payload['rowCapApplied'], isTrue);
      expect(payload['warnings'], isNull);
    });

    test('SQL Server 走驱动内流式封顶:自带 FETCH 封顶也算已生效', () async {
      final h = Harness(conns: [fakeConn('a', typeId: 'sqlserver')]);
      // `FETCH NEXT` 是 sql_row_cap 的 blocker:若按 MySQL 的判定会给 false,
      // 而 SQL Server 驱动在取数层(odbcQueryCapped)已经封顶,不该误报。
      final payload = await h.ok('daro_execute_query', {
        'connection': 'a',
        'database': 'db_a',
        'sql': 'SELECT * FROM t ORDER BY id OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY'
      });
      expect(payload['rowCapApplied'], isTrue);
      expect(payload['warnings'], isNull);
    });
  });

  group('超时与尽力取消(P1/P2)', () {
    test('无会话 id(SQLite):cancelAttempted:false,实例销毁不回池', () async {
      var delay = const Duration(milliseconds: 1400);
      final h = Harness(
        policy: enabledPolicy(timeouts: const McpTimeouts(readonlySecs: 1)),
        conns: [fakeConn('a', typeId: 'sqlite', password: '')],
      );
      h.spy.tune = (d) => d.executeDelay = delay;
      final err = await h.err('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT pg_sleep(9)'});
      expect(err['code'], 'QUERY_TIMEOUT');
      expect(err['cancelAttempted'], isFalse);
      expect(err['retryable'], isFalse, reason: '没取消成功就别催 agent 重跑');
      expect(err['message'], contains('1 秒'));

      delay = Duration.zero;
      expect(h.pool.activeCount, 0, reason: '超时实例必须已出池');
      await h.ok('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT 1'});
      expect(h.spy.connectCountOf('a'), 2, reason: '下家拿到全新实例,不是那条挂死的');
    });

    test('有会话 id(MySQL):尽力 killSession,cancelAttempted:true 且可重试',
        () async {
      final h = Harness(
        policy: enabledPolicy(timeouts: const McpTimeouts(readonlySecs: 1)),
      );
      h.spy.tune = (d) {
        d.sessionId = 4242;
        d.executeDelay = const Duration(milliseconds: 1400);
      };
      final err = await h.err('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT SLEEP(9)'});
      expect(err['cancelAttempted'], isTrue);
      expect(err['retryable'], isTrue);
      expect(h.driver.killCount, 1);
      expect(h.driver.closeCount, 1);
    });

    test('取消本身失败(kill 无权限):cancelAttempted:false 并带上原因', () async {
      final h = Harness(
        policy: enabledPolicy(timeouts: const McpTimeouts(readonlySecs: 1)),
      );
      h.spy.tune = (d) {
        d.sessionId = 7;
        d.executeDelay = const Duration(milliseconds: 1400);
        d.throwOnKill = 'ACCESS DENIED killing query';
      };
      final err = await h.err('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT SLEEP(9)'});
      expect(err['code'], 'QUERY_TIMEOUT');
      expect(err['cancelAttempted'], isFalse);
      expect(err['cancelReason'], contains('ACCESS DENIED'));
      expect(h.driver.killCount, 1);
      // P2:取消成不成功都不回池 —— 状态未知的连接不能交给下家。
      expect(h.pool.activeCount, 0);
    });

    test('元数据读取同样受超时守卫(不只是 executeQuery)', () async {
      final h = Harness(
        policy: enabledPolicy(timeouts: const McpTimeouts(readonlySecs: 1)),
      );
      h.spy.overrides['a'] = (name) => _SlowListDriver(name);
      final err = await h.err('daro_list_tables', {'connection': 'a', 'database': 'db_a'});
      expect(err['code'], 'QUERY_TIMEOUT');
    });
  });

  group('引擎错误与基础设施错误分诊', () {
    test('语法错:作为工具结果回 DATABASE_ERROR 原文,连接健康则回池(不赔握手)',
        () async {
      final h = Harness();
      h.spy.tune = (d) =>
          d.throwOnExecute = "Unknown column 'x' in 'field list'";
      final out = await h.service.callTool('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT x FROM t'});
      expect(out.isError, isTrue);
      final err = out.payload['error'] as Map;
      expect(err['code'], 'DATABASE_ERROR');
      expect(err['message'], contains("Unknown column 'x'"));

      h.driver.throwOnExecute = null;
      await h.ok('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT 1'});
      expect(h.spy.connectCountOf('a'), 1, reason: '同一条连接还在池里');
    });

    test('报错同时连接已断:实例销毁,下家重连', () async {
      final h = Harness();
      h.spy.tune = (d) {
        d.throwOnExecute = 'Lost connection to MySQL server';
        d.breaksConnectionOnExecute = true;
      };
      await h.err('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT 1'});
      expect(h.pool.activeCount, 0);

      h.spy.tune = null;
      await h.ok('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT 1'});
      expect(h.spy.connectCountOf('a'), 2);
    });

    test('连接级失败(握手挂):CONNECTION_FAILED 且可重试', () async {
      final h = Harness();
      h.spy.overrides['a'] = (name) => FakeDriver(name)..throwOnConnect = true;
      final err = await h.err('daro_list_databases', {'connection': 'a'});
      expect(err['code'], 'CONNECTION_FAILED');
      expect(err['retryable'], isTrue);
    });
  });

  group('密码路径(P3)', () {
    test('未保存密码 + deny:PASSWORD_REQUIRED,绝不接受 agent 代传', () async {
      final h = Harness(
        policy: enabledPolicy(passwordPrompt: McpPasswordPrompt.deny),
        conns: [fakeConn('a', password: '')],
      );
      final err = await h.err('daro_list_databases',
          {'connection': 'a', 'password': 'agent-guessed'});
      expect(err['code'], 'PASSWORD_REQUIRED');
      expect(err['hint'], contains('绝不要'));
      expect(h.spy.created, isEmpty);
    });

    test('策略是 deny 时即使宿主有弹窗也不许问人(权限由 daro 说了算)', () async {
      final h = Harness(
        policy: enabledPolicy(passwordPrompt: McpPasswordPrompt.deny),
        conns: [fakeConn('a', password: '')],
      );
      // 弹窗「答应」并真的把密码补进连接:deny 档必须压根不走到这一步。
      h.askPassword = (conn) async {
        h.conns = [fakeConn('a', password: 'typed-by-human')];
        return true;
      };
      final err = await h.err('daro_list_databases', {'connection': 'a'});
      expect(err['code'], 'PASSWORD_REQUIRED');
      expect(h.promptedFor, isNull, reason: 'deny 档下不该弹过密码窗');
      expect(h.spy.created, isEmpty);
    });

    test('宿主没有弹窗能力(stdio 宿主)时同样回 PASSWORD_REQUIRED', () async {
      final h = Harness(
        policy: enabledPolicy(passwordPrompt: McpPasswordPrompt.askInApp),
        conns: [fakeConn('a', password: '')],
        hostHasDialog: false,
      );
      final err = await h.err('daro_list_databases', {'connection': 'a'});
      expect(err['code'], 'PASSWORD_REQUIRED');
      expect(h.spy.created, isEmpty);
    });

    test('askInApp 且人已补录:补齐后的密码生效,只驱动一次', () async {
      final h = Harness(
        policy: enabledPolicy(passwordPrompt: McpPasswordPrompt.askInApp),
        conns: [fakeConn('a', password: '')],
      );
      h.askPassword = (conn) async {
        h.promptedFor = conn.name;
        h.conns = [fakeConn('a', password: 'typed-by-human')];
        return true;
      };
      final payload = await h.ok('daro_list_databases', {'connection': 'a'});
      expect(payload['databases'], ['db_a', 'db_b', 'secret']);
      expect(h.promptedFor, 'a');
      expect(h.spy.created.length, 1);
    });

    test('askInApp 但人取消 / 补录后密码仍为空:都回 PASSWORD_REQUIRED', () async {
      final cancelled = Harness(
        policy: enabledPolicy(passwordPrompt: McpPasswordPrompt.askInApp),
        conns: [fakeConn('a', password: '')],
      );
      cancelled.askPassword = (conn) async => false;
      expect(
          (await cancelled.err('daro_list_databases', {'connection': 'a'}))['code'],
          'PASSWORD_REQUIRED');

      final stillEmpty = Harness(
        policy: enabledPolicy(passwordPrompt: McpPasswordPrompt.askInApp),
        conns: [fakeConn('a', password: '')],
      );
      stillEmpty.askPassword = (conn) async => true;
      final err = await stillEmpty.err('daro_list_databases', {'connection': 'a'});
      expect(err['code'], 'PASSWORD_REQUIRED');
      expect(err['message'], contains('保存密码'));
    });
  });

  group('元数据工具的载荷', () {
    test('list_databases 按库范围过滤后再返回', () async {
      final h = Harness(
        policy: enabledPolicy(rules: [
          McpConnectionRule(
              connection: 'a', databaseScope: McpDatabaseScope.only(['db_a'])),
        ]),
      );
      final payload = await h.ok('daro_list_databases', {'connection': 'a'});
      expect(payload['databases'], ['db_a']);
      expect(h.driver.usedDatabases, isEmpty, reason: '列库不该切换运行上下文');
    });

    test('list_tables 带注释与行数估算;kind=view 列视图', () async {
      final h = Harness();
      final payload = await h.ok('daro_list_tables',
          {'connection': 'a', 'database': 'db_a'});
      expect(payload['tables'], [
        {'name': 'users', 'comment': '用户表', 'estimatedRows': 120},
        {'name': 'orders'},
      ]);
      final views = await h.ok('daro_list_tables',
          {'connection': 'a', 'database': 'db_a', 'kind': 'view'});
      expect((views['tables'] as List).single['name'], 'v_users');
      expect(views['kind'], 'view');
    });

    test('describe_table:结构反查失败时降级为只回列定义', () async {
      final h = Harness();
      final degraded = await h.ok('daro_describe_table',
          {'connection': 'a', 'database': 'db_a', 'table': 'users'});
      expect(degraded['columns'], [
        {'name': 'id', 'type': 'int', 'nullable': false, 'primaryKey': true},
        {'name': 'name', 'type': 'varchar(255)', 'nullable': true, 'primaryKey': false, 'comment': '姓名'},
      ]);
      expect(degraded.containsKey('indexes'), isFalse);

      h.driver.design = DesignTable()
        ..indexes.add(DesignIndex(name: 'idx_name', columns: 'name'))
        ..foreignKeys.add(DesignForeignKey(
            name: 'fk_u', columns: 'id', refTable: 'accounts', refColumns: 'id'));
      final fullPayload = await h.ok('daro_describe_table',
          {'connection': 'a', 'database': 'db_a', 'table': 'users'});
      expect(fullPayload['indexes'], [
        {'name': 'idx_name', 'columns': ['name']}
      ]);
      expect((fullPayload['foreignKeys'] as List).single['references'],
          'accounts(id)');
    });

    test('preview_table:nullColumns 消除 "NULL" 歧义,count 才额外全表计数', () async {
      final h = Harness();
      final payload = await h.ok('daro_preview_table',
          {'connection': 'a', 'database': 'db_a', 'table': 'users', 'limit': 2});
      expect(payload['nullColumns'], [
        [1],
        []
      ]);
      expect(payload['truncated'], isTrue);
      expect(payload.containsKey('totalRows'), isFalse);

      final counted = await h.ok('daro_preview_table', {
        'connection': 'a',
        'database': 'db_a',
        'table': 'users',
        'count': true
      });
      expect(counted['totalRows'], 12345);
    });

    test('get_schema_context 有预算:超出截断并标 truncated', () async {
      final h = Harness();
      h.spy.tune = (d) =>
          d.tables = [for (var i = 0; i < 300; i++) 'table_number_$i'];
      final payload = await h.ok('daro_get_schema_context',
          {'connection': 'a', 'database': 'db_a'});
      expect(payload['truncated'], isTrue);
      expect(payload['tablesTotal'], 300);
      expect(payload['tablesIncluded'] as int, lessThan(300));
      expect((payload['context'] as String).length, lessThanOrEqualTo(6000));
    });

    test('有模式层的类型:借出时定位到请求的模式(E4 不串上下文)', () async {
      final h = Harness(conns: [fakeConn('a', typeId: 'postgresql')]);
      await h.ok('daro_list_tables',
          {'connection': 'a', 'database': 'db_a', 'schema': 'reporting'});
      expect(h.driver.usedDatabases, ['db_a']);
      expect(h.driver.usedSchemas, ['reporting']);
    });

    test('list_routines / get_routine_source 按 kind 分派', () async {
      final h = Harness();
      final routines = await h.ok('daro_list_routines',
          {'connection': 'a', 'database': 'db_a', 'kind': 'function'});
      expect(routines['functions'], [
        {'name': 'fn_new_id'}
      ]);
      expect(routines.containsKey('procedures'), isFalse);

      final src = await h.ok('daro_get_routine_source', {
        'connection': 'a',
        'database': 'db_a',
        'name': 'v_users',
        'kind': 'view'
      });
      expect(src['definition'], startsWith('CREATE VIEW'));

      final bad = await h.err('daro_get_routine_source', {
        'connection': 'a',
        'database': 'db_a',
        'name': 'x',
        'kind': 'trigger'
      });
      expect(bad['code'], 'INVALID_PARAMS');
    });
  });

  group('UI 桥(D9)', () {
    test('open_table 转交宿主;宿主没有桥时如实报错', () async {
      String? opened;
      final h = Harness(onOpenTable: (c, d, t) async => opened = '$c/$d/$t');
      final payload = await h.ok('daro_open_table',
          {'connection': 'a', 'database': 'db_a', 'table': 'users'});
      expect(payload['opened'], isTrue);
      expect(opened, 'a/db_a/users');

      final noBridge = Harness();
      final err = await noBridge.err('daro_open_table',
          {'connection': 'a', 'database': 'db_a', 'table': 'users'});
      expect(err['code'], 'INTERNAL_ERROR');
    });

    test('open_table 也过库范围判定', () async {
      final h = Harness(
        policy: enabledPolicy(rules: [
          McpConnectionRule(
              connection: 'a', databaseScope: McpDatabaseScope.only(['db_a'])),
        ]),
        onOpenTable: (c, d, t) async {},
      );
      final err = await h.err(
          'daro_open_table', {'connection': 'a', 'database': 'secret', 'table': 't'});
      expect(err['code'], 'DATABASE_OUT_OF_SCOPE');
    });
  });

  group('审计与「改权限不必重启」', () {
    test('每次调用落一行事件:被拒的调用也记错误码与判定上下文', () async {
      final h = Harness();
      await h.err('daro_execute_query', {
        'connection': 'a',
        'database': 'db_a',
        'sql': 'UPDATE t SET a = 1 WHERE id = 2',
      });
      final denied = h.events.single;
      expect(denied['tool'], 'daro_execute_query');
      expect(denied['mode'], 'readonly');
      expect(denied['sqlClass'], 'scopedWrite');
      expect(denied['error'], 'MODE_DENIED');
      expect(denied['ok'], isFalse);
      expect(denied['ms'], isA<int>());

      h.events.clear();
      await h.ok('daro_execute_query',
          {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT 1'});
      final ok = h.events.single;
      expect(ok['ok'], isTrue);
      expect(ok['error'], isNull);
      expect(ok['rows'], 1);
      expect(ok['limit'], 100);

      h.events.clear();
      await h.err('daro_list_databases', {'connection': 'ghost'});
      expect(h.events.single['error'], 'CONNECTION_NOT_VISIBLE');
    });

    test('sqlDigest 只存摘要:超长语句不进审计日志', () async {
      final h = Harness(policy: enabledPolicy(defaultMode: McpMode.full));
      await h.ok('daro_execute_query', {
        'connection': 'a',
        'database': 'db_a',
        'sql': 'SELECT "${'x' * 500}"',
      });
      expect((h.events.single['sqlDigest'] as String).length, lessThanOrEqualTo(201));
    });

    test('策略每次调用重读盘:关档后同一条写入立刻被拒', () async {
      final h = Harness(policy: enabledPolicy(defaultMode: McpMode.readWrite));
      await h.ok('daro_execute_query', {
        'connection': 'a',
        'database': 'db_a',
        'sql': 'UPDATE t SET a = 1 WHERE id = 2'
      });

      h.policy = enabledPolicy(defaultMode: McpMode.readonly);
      final err = await h.err('daro_execute_query', {
        'connection': 'a',
        'database': 'db_a',
        'sql': 'UPDATE t SET a = 1 WHERE id = 2'
      });
      expect(err['code'], 'MODE_DENIED');
    });
  });
}

/// 一条会挂死的列表驱动(验证超时守卫覆盖元数据调用)。
class _SlowListDriver extends FakeDriver {
  _SlowListDriver(super.label);

  @override
  Future<List<String>> listTables(String database, {String? schema}) async {
    await Future.delayed(const Duration(milliseconds: 1400));
    return super.listTables(database, schema: schema);
  }
}

/// 工具层测试台:策略与连接都是**可变字段**,每次调用现读 ——
/// 这样「改权限不必重启客户端」这条定稿语义能被真的测到。
class Harness {
  Harness({
    McpPolicy? policy,
    List<ConnectionInfo>? conns,
    Future<void> Function(String connection, String database, String table)?
        onOpenTable,
    bool hostHasDialog = true,
  }) {
    if (policy != null) this.policy = policy;
    if (conns != null) this.conns = conns;
    service = McpToolService(McpToolDeps(
      loadPolicy: () async => this.policy,
      loadConnections: () async => this.conns,
      pool: pool,
      // 宿主侧「有没有弹窗能力」与策略「允不允许问」是两回事:
      // 这里默认注入弹窗替身,让策略成为唯一决定方。
      requestPassword: hostHasDialog
          ? (conn) async {
              promptedFor = conn.name;
              final handler = askPassword;
              return handler == null ? true : await handler(conn);
            }
          : null,
      openTableBridge: onOpenTable,
      audit: events.add,
    ));
  }

  McpPolicy policy = enabledPolicy();
  List<ConnectionInfo> conns = [fakeConn('a')];

  late final DriverFactorySpy spy = DriverFactorySpy();
  late final McpDriverPool pool = McpDriverPool(driverFactory: spy.call);
  late final McpToolService service;
  final List<Map<String, dynamic>> events = [];

  /// 宿主弹窗的替身;返回 false = 人取消
  Future<bool> Function(ConnectionInfo conn)? askPassword;
  String? promptedFor;

  /// 连接 a 最近一次被创建的假驱动。
  FakeDriver get driver => spy.listOf('a').last;

  /// 断言成功并返回 payload。
  Future<Map<String, dynamic>> ok(
      String tool, [Map<String, dynamic> args = const {}]) async {
    final out = await service.callTool(tool, args);
    expect(out.isError, isFalse,
        reason: '$tool 意外失败: ${jsonEncode(out.payload)}');
    return out.payload;
  }

  /// 断言失败并返回错误四元组。
  Future<Map<String, dynamic>> err(
      String tool, [Map<String, dynamic> args = const {}]) async {
    final out = await service.callTool(tool, args);
    expect(out.isError, isTrue,
        reason: '$tool 本应被拒,却成功了: ${jsonEncode(out.payload)}');
    return (out.payload['error'] as Map).cast<String, dynamic>();
  }
}


