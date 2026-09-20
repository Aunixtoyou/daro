import 'package:daro/mcp/mcp_policy.dart';
import 'package:daro/mcp/mcp_sql_classify.dart';
import 'package:flutter_test/flutter_test.dart';

/// MCP 策略与语句分类的判定矩阵(简报 §8「默认安全 / 权限不可放宽 / 规模可控」几条
/// 的可执行版本)。这些判定是**纯函数**,不需要真连库,所以覆盖得越严越好 ——
/// 它们是唯一挡在 agent 和用户数据库之间的东西。
void main() {
  group('工具清单快照(改名即破坏 agent 侧契约,对齐 navicat_export_test 的做法)', () {
    test('Phase-1 就是这 11 个工具名,顺序与集合都不许多也不许改', () {
      expect(kMcpPhase1ToolIds, [
        'daro_list_connections',
        'daro_list_databases',
        'daro_list_schemas',
        'daro_list_tables',
        'daro_describe_table',
        'daro_get_schema_context',
        'daro_execute_query',
        'daro_preview_table',
        'daro_list_routines',
        'daro_get_routine_source',
        'daro_open_table',
      ]);
    });
  });

  group('classifySql —— 白名单口径(认不出来就当高风险)', () {
    test('明确只读', () {
      for (final sql in [
        'SELECT * FROM orders LIMIT 10',
        'select id, name from users where created_at > now()',
        'SHOW TABLES',
        'DESC orders',
        'DESCRIBE orders',
        'EXPLAIN SELECT * FROM orders',
        'WITH t AS (SELECT 1 AS a) SELECT * FROM t',
        "SELECT name FROM t WHERE remark = '-- 这不是注释'",
        'SELECT * FROM t /* 行内注释 */ WHERE id = 1',
        'VALUES (1,2)',
        'PRAGMA table_info(t)',
        r'SELECT $$ 分号; 在美元引用里 $$ AS s',
      ]) {
        expect(classifySql(sql), SqlClass.readOnly, reason: sql);
      }
    });

    test('范围可控写入 → 数据读写档', () {
      for (final sql in [
        'INSERT INTO t (a) VALUES (1)',
        'REPLACE INTO t (a) VALUES (1)',
        'UPDATE t SET a = 1 WHERE id = 5',
        'DELETE FROM t WHERE deleted = 0',
        'UPDATE t SET a = 1 WHERE 1 = 2', // 恒假条件:仍是有效过滤,不是全表
        'UPDATE t SET a = 1 WHERE id = 5 AND TRUE', // 有真实条件在场
        'USE other_db',
      ]) {
        expect(classifySql(sql), SqlClass.scopedWrite, reason: sql);
      }
    });

    test('全表更新/删除 → 高风险(永真条件封闭清单)', () {
      for (final sql in [
        'UPDATE t SET a = 1', // 没有 WHERE
        'DELETE FROM t', // 没有 WHERE
        'UPDATE t SET a = 1 WHERE 1 = 1',
        'DELETE FROM t WHERE TRUE',
        'DELETE FROM t WHERE 1',
        'UPDATE t SET a = 1 WHERE TRUE = TRUE',
        'DELETE FROM t WHERE id = id', // 同列自比,恒真(非 NULL 时)
        'UPDATE t SET a = 1 WHERE x = 1 OR 1 = 1', // OR 里有恒真分支 = 全表
        'DELETE FROM t WHERE 1 <> 0',
      ]) {
        expect(classifySql(sql), SqlClass.dangerous, reason: sql);
      }
    });

    test('DDL / 会话 / 维护类 → 高风险', () {
      for (final sql in [
        'CREATE TABLE t (a INT)',
        'ALTER TABLE t ADD COLUMN b INT',
        'DROP TABLE t',
        'TRUNCATE TABLE t',
        'REFRESH MATERIALIZED VIEW mv',
        'VACUUM',
        'GRANT SELECT ON t TO u',
        'SET ROLE r', // PG 提权路径
        'SET SESSION foo = 1',
        'CALL some_proc(1)',
        'MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET t.a = s.a',
        "SELECT * FROM t INTO OUTFILE '/tmp/x.csv'",
        'SELECT * FROM t FOR UPDATE',
        'EXPLAIN ANALYZE DELETE FROM t WHERE id = 1', // ANALYZE 会真执行
        'PRAGMA journal_mode = WAL',
      ]) {
        expect(classifySql(sql), SqlClass.dangerous, reason: sql);
      }
    });

    test('无法可靠分类 → 完全访问', () {
      for (final sql in [
        '', //
        '   ',
        ';',
        'SELECT 1; SELECT 2', // 多语句脚本(批量执行是 Phase-2)
        'FROBNICATE t', // 不认识的关键字
      ]) {
        expect(classifySql(sql), SqlClass.unclassifiable, reason: sql);
      }
    });

    test('尾部分号不算多语句;注释里的分号也不算', () {
      expect(classifySql('SELECT 1;'), SqlClass.readOnly);
      expect(classifySql('SELECT 1 /* ; */ ;'), SqlClass.readOnly);
      expect(classifySql("SELECT ';' AS s"), SqlClass.readOnly);
    });

    test('每个分类要求的最低模式符合定稿的三档矩阵', () {
      expect(SqlClass.readOnly.minimumMode, McpMode.readonly);
      expect(SqlClass.scopedWrite.minimumMode, McpMode.readWrite);
      expect(SqlClass.dangerous.minimumMode, McpMode.full);
      expect(SqlClass.unclassifiable.minimumMode, McpMode.full);
    });
  });

  group('McpPolicy —— 判定', () {
    test('默认策略:关闭 + 只读,任何连接都连不上', () {
      const p = McpPolicy.defaults();
      expect(p.enabled, isFalse);
      expect(p.defaultMode, McpMode.readonly);
      expect(p.isServing, isFalse);
      expect(p.verdictConnection('local-pg').reason, McpDenyReason.serviceDisabled);
    });

    test('连接 allowlist:all=false 时只放行名单内的连接', () {
      const p = McpPolicy(
        enabled: true,
        connectionScopeAll: false,
        connectionNames: ['local-pg'],
      );
      expect(p.verdictConnection('local-pg').allowed, isTrue);
      expect(p.verdictConnection('prod-pg').reason,
          McpDenyReason.connectionNotVisible);
    });

    test('数据库范围:未列出的库返回 databaseOutOfScope(抄 DBX 同名语义)', () {
      const p = McpPolicy(
        enabled: true,
        connections: [
          McpConnectionRule(
            connection: 'local-pg',
            databaseScope:
                McpDatabaseScope(all: false, include: ['app', 'app_test']),
          ),
        ],
      );
      expect(p.verdictDatabase('local-pg', 'app').allowed, isTrue);
      expect(p.verdictDatabase('local-pg', 'postgres').reason,
          McpDenyReason.databaseOutOfScope);
      // 列库请求(还没指定库)只要连接可见就放行
      expect(p.verdictDatabase('local-pg', null).allowed, isTrue);
    });

    test('生效模式回退顺序:单库覆盖 → 连接默认 → 全局默认', () {
      const p = McpPolicy(
        enabled: true,
        defaultMode: McpMode.readonly,
        connections: [
          McpConnectionRule(
            connection: 'dev',
            mode: McpMode.readWrite,
            databaseModes: [McpDatabaseMode('scratch', McpMode.full)],
          ),
        ],
      );
      expect(p.effectiveMode('dev', database: 'scratch'), McpMode.full);
      expect(p.effectiveMode('dev', database: 'app'), McpMode.readWrite);
      expect(p.effectiveMode('dev'), McpMode.readWrite);
      expect(p.effectiveMode('other'), McpMode.readonly);
    });

    test('模式不足时拒绝:只读档跑写语句', () {
      const p = McpPolicy(enabled: true);
      expect(
        p
            .verdictSql('dev', 'app', SqlClass.scopedWrite)
            .reason,
        McpDenyReason.modeDenied);
      expect(p.verdictSql('dev', 'app', SqlClass.readOnly).allowed, isTrue);
    });

    test('驱动不支持(痛点 P5)优先于模式判定', () {
      const p = McpPolicy(enabled: true, defaultMode: McpMode.full);
      expect(
        p
            .verdictSql('dev', 'app', SqlClass.readOnly, driverSupported: false)
            .reason,
        McpDenyReason.driverUnsupported);
    });

    test('工具 allowlist:空 = 全选;非空 = 只放行选中的', () {
      const all = McpPolicy(enabled: true);
      expect(all.toolAllowed('daro_list_tables'), isTrue);
      expect(all.toolAllowed('daro_add_connection'), isFalse); // Phase-1 不存在
      const only = McpPolicy(enabled: true, tools: ['daro_list_connections']);
      expect(only.toolAllowed('daro_list_connections'), isTrue);
      expect(only.toolAllowed('daro_execute_query'), isFalse);
    });

    test('行数夹取:越界夹取而非报错', () {
      const p = McpPolicy(enabled: true);
      expect(p.clampRows(null), 100);
      expect(p.clampRows(0), 100); // 非正数回落默认
      expect(p.clampRows(-5), 100);
      expect(p.clampRows(50), 50);
      expect(p.clampRows(5000), 1000); // 夹到硬上限
    });

    test('超时按模式分档(痛点 P1)', () {
      const p = McpPolicy(enabled: true);
      expect(p.timeoutFor(McpMode.readonly), const Duration(seconds: 30));
      expect(p.timeoutFor(McpMode.readWrite), const Duration(seconds: 60));
      expect(p.timeoutFor(McpMode.full), const Duration(seconds: 300));
    });

    test('绑非回环地址却没 token 时视为未就绪,宁可不启动', () {
      const lan = McpPolicy(
          enabled: true, http: McpHttpSettings(host: '192.168.1.20', token: ''));
      expect(lan.isServing, isFalse);
      const lanWithToken = McpPolicy(
          enabled: true,
          http: McpHttpSettings(host: '192.168.1.20', token: 'abc'));
      expect(lanWithToken.isServing, isTrue);
      const loopback = McpPolicy(enabled: true);
      expect(loopback.isServing, isTrue); // 回环免鉴权可用
    });
  });

  group('McpPolicy —— 落盘往返', () {
    test('toJson → fromJson 完全等价', () {
      const original = McpPolicy(
        schemaVersion: 1,
        enabled: true,
        defaultMode: McpMode.readWrite,
        connectionScopeAll: false,
        connectionNames: ['dev', 'staging'],
        connections: [
          McpConnectionRule(
            connection: 'dev',
            mode: McpMode.readWrite,
            databaseScope: McpDatabaseScope(all: false, include: ['app']),
            databaseModes: [McpDatabaseMode('scratch', McpMode.full)],
          ),
        ],
        tools: ['daro_list_tables', 'daro_execute_query'],
        maxRows: 200,
        hardRowCap: 2000,
        timeouts: McpTimeouts(readonlySecs: 5, readWriteSecs: 10, fullSecs: 20),
        poolIdleTtlSecs: 60,
        poolMaxDrivers: 2,
        passwordPrompt: McpPasswordPrompt.deny,
        auditEnabled: false,
        http: McpHttpSettings(host: '127.0.0.1', port: 6000, token: 't0k'),
      );
      final back = McpPolicy.fromJson(original.toJson());
      expect(back.toJson(), equals(original.toJson()));
      expect(back.effectiveMode('dev', database: 'scratch'), McpMode.full);
      expect(back.clampRows(9999), 2000);
    });

    test('缺字段一律回落默认值,且**不放大权限**', () {
      // 老文件 / 半截文件:没有 enabled 就是没启用。
      final partial = McpPolicy.fromJson({'defaultMode': 'full'});
      expect(partial.enabled, isFalse);
      expect(partial.defaultMode, McpMode.full); // 显式写了就认
      expect(partial.maxRows, 100);
      expect(partial.passwordPrompt, McpPasswordPrompt.askInApp);
    });

    test('脏数据不抛异常:类型错的字段按缺失处理', () {
      final p = McpPolicy.fromJson({
        'enabled': 'yes', // 不是 bool
        'maxRows': -1, // 非正数
        'hardRowCap': 10, // 小于 maxRows → 抬到 maxRows
        'defaultMode': 'nonsense', // 认不出 → 默认档
        'queryTimeoutSecs': {'readonly': 0}, // 0 视为无效,回默认
        'connections': [
          {'connection': ''}, // 无名规则丢掉
          {'connection': 'ok', 'mode': 'full'},
        ],
      });
      expect(p.enabled, isFalse);
      expect(p.maxRows, 100);
      expect(p.hardRowCap, 100);
      expect(p.defaultMode, McpMode.readonly);
      expect(p.timeouts.readonlySecs, 30);
      expect(p.connections.single.connection, 'ok');
    });

    test('枚举按字符串落盘,不按序号(改名/插队都不会悄悄改权限)', () {
      const p = McpPolicy(enabled: true, defaultMode: McpMode.readWrite);
      expect(p.toJson()['defaultMode'], 'readWrite');
    });
  });

  group('McpPolicy —— 改名守卫(痛点 P6,定稿 D10:不引入 id,靠约定兜)', () {
    test('allowlist 与连接级规则一起迁移,不留孤儿授权', () {
      const p = McpPolicy(
        enabled: true,
        connectionScopeAll: false,
        connectionNames: ['dev', 'staging'],
        connections: [
          McpConnectionRule(
            connection: 'dev',
            mode: McpMode.readWrite,
            databaseScope: McpDatabaseScope(all: false, include: ['app']),
          ),
        ],
      );
      final renamed = p.withRenamedConnection('dev', 'dev-2');
      expect(renamed.connectionNames, ['dev-2', 'staging']);
      expect(renamed.authorizesConnection('dev'), isFalse);
      expect(renamed.authorizesConnection('dev-2'), isTrue);
      // 规则本身也跟着走:新名仍是 readWrite + 只允许 app
      expect(renamed.effectiveMode('dev-2'), McpMode.readWrite);
      expect(renamed.verdictDatabase('dev-2', 'postgres').reason,
          McpDenyReason.databaseOutOfScope);
      // 旧名不再被放行(否则改名后留下一条永久无效的授权残留)
      expect(renamed.verdictConnection('dev').reason,
          McpDenyReason.connectionNotVisible);
    });

    test('改成同名不动对象', () {
      const p = McpPolicy(enabled: true, connectionNames: ['dev']);
      expect(identical(p.withRenamedConnection('dev', 'dev'), p), isTrue);
    });
  });

  group('generateMcpToken', () {
    test('长度与随机性(每次不同,只含十六进制)', () {
      final a = generateMcpToken();
      final b = generateMcpToken();
      expect(a.length, 48); // 24 字节 → 48 个十六进制字符
      expect(a, isNot(equals(b)));
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(a), isTrue);
    });
  });
}
