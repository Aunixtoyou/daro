/// MCP 工具层(简报 §5.2:Phase-1 十行 11 个工具,逐条映射 daro 现成 API)。
///
/// 职责边界:
/// - **每次调用重读策略**(loadPolicy 回调)—— 改权限不必重启 MCP 客户端是定稿语义;
/// - 判定链:enabled → 工具 allowlist(服务端强校验,不只是 UI 隐藏)→
///   连接可见性 → 库范围 → 驱动可用性(P5)→ 密码(P3)→ 语句分类 → 模式;
/// - 执行经 [McpDriverPool] 专用实例,**不碰连接树的长连接**(E4);
/// - 超时 + 尽力取消(P1/P2,[_guarded]):到点回 `QUERY_TIMEOUT` 带
///   `cancelAttempted`;超时的实例一律销毁不回池;
/// - 失败一律 [McpException] 四元组;数据库自身的报错(语法错、表不存在)
///   作为**工具执行结果**(isError + DATABASE_ERROR)返回原文 —— agent 能据此
///   改 SQL,这与「该换连接/该问用户」的基础设施错误是两类信息。
///
/// ⚠️ 本文件禁止 import package:flutter(见 tool/check_mcp_purity.dart);
/// 策略读取、连接解析、密码弹窗、UI 桥(daro_open_table)全部由宿主注入。
library;

import 'dart:async';

import '../data/db_data.dart';
import '../data/drivers/db_driver.dart';
import '../data/sql_row_cap.dart';
import '../data/table_design.dart';
import 'mcp_errors.dart';
import 'mcp_policy.dart';
import 'mcp_pool.dart';
import 'mcp_sql_classify.dart';

/// 工具调用结果:payload 会被协议层 JSON 编码进 `content[0].text`。
class McpToolOutcome {
  const McpToolOutcome(this.payload, {this.isError = false});

  final Map<String, dynamic> payload;
  final bool isError;
}

/// 宿主注入的依赖包(全部是回调 —— lib/mcp 零 Flutter 依赖的关键)。
class McpToolDeps {
  const McpToolDeps({
    required this.loadPolicy,
    required this.loadConnections,
    required this.pool,
    this.requestPassword,
    this.openTableBridge,
    this.audit,
  });

  /// 当次调用**重新读盘**的策略。
  final Future<McpPolicy> Function() loadPolicy;

  /// 当前全部连接(app 内存态,经宿主转发;含未保存进磁盘的会话密码)。
  final Future<List<ConnectionInfo>> Function() loadConnections;

  final McpDriverPool pool;

  /// 空密码连接向用户索取密码(P3 / W14):宿主弹 daro 密码子窗,
  /// 人补录后返回 true。策略为 deny 或宿主无交互面时不注入。
  final Future<bool> Function(ConnectionInfo conn)? requestPassword;

  /// UI 桥(D9):在 daro 里打开表标签页。内嵌宿主接 AppState,其余为 null。
  final Future<void> Function(
      String connection, String database, String table)? openTableBridge;

  /// 审计事件(每次工具调用一行,宿主落 JSONL)。
  final void Function(Map<String, dynamic> event)? audit;
}

/// 数据库引擎自身抛出的执行错误(语法 / 对象不存在 / 库内权限)——
/// 与基础设施类 [McpException] 分开:前者进工具结果,后者进错误契约。
class DatabaseCallException implements Exception {
  DatabaseCallException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 封顶走驱动内流式游标(odbcQueryCapped)、不经过 sql_row_cap 改写的引擎:
/// 对这些引擎服务端封顶恒生效,`rowCapApplied` 不适用 LIMIT 改写判定。
const _streamingCapTypes = {'sqlserver', 'access'};

class McpToolService {
  McpToolService(this._deps);

  final McpToolDeps _deps;

  // ------------------------------------------------------ tools/list 定义 ----

  /// 完整工具定义(不过滤;allowlist 过滤见 [toolDefinitions])。
  ///
  /// description 里刻意复述了错误码 hint 的关键句(§5.3「写进工具 description
  /// 与错误响应两处」):agent 常在第一次调用前就把 description 读进上下文。
  static const List<Map<String, dynamic>> allToolDefinitions = [
    {
      'name': 'daro_list_connections',
      'description':
          '列出已授权给 MCP 的数据库连接。每条带 supported(是否有可用驱动)与 '
              'passwordMissing(是否需要先让用户在 daro 里保存密码);选连接时先看这两个位,'
              '不要拿不支持的连接反复试。不回显密码。',
      'inputSchema': {'type': 'object', 'properties': {}, 'required': []},
    },
    {
      'name': 'daro_list_databases',
      'description': '列出某连接下允许访问的数据库(已按 MCP 数据库范围过滤)。',
      'inputSchema': {
        'type': 'object',
        'properties': {'connection': _connProp},
        'required': ['connection'],
      },
    },
    {
      'name': 'daro_list_schemas',
      'description':
          '列出某库下的模式(schema)。仅 PostgreSQL / SQL Server 等有模式层的类型返回非空;'
              'MySQL / SQLite 返回空列表属正常。',
      'inputSchema': {
        'type': 'object',
        'properties': {'connection': _connProp, 'database': _dbProp},
        'required': ['connection', 'database'],
      },
    },
    {
      'name': 'daro_list_tables',
      'description': '列出表或视图(含注释与行数估算)。kind=view 列视图。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'connection': _connProp,
          'database': _dbProp,
          'schema': _schemaProp,
          'kind': {
            'type': 'string',
            'enum': ['table', 'view'],
            'description': '默认 table',
          },
        },
        'required': ['connection', 'database'],
      },
    },
    {
      'name': 'daro_describe_table',
      'description': '表结构:列(类型/可空/主键/默认值/注释) + 索引 + 外键。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'connection': _connProp,
          'database': _dbProp,
          'schema': _schemaProp,
          'table': {'type': 'string', 'description': '表名'},
        },
        'required': ['connection', 'database', 'table'],
      },
    },
    {
      'name': 'daro_get_schema_context',
      'description':
          '紧凑的库结构上下文(一表一行、列类型缩写),一次喂给 agent 写 SQL 用;'
              '有字符预算,超出截断并标 truncated。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'connection': _connProp,
          'database': _dbProp,
          'schema': _schemaProp,
          'tables': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '只看这几张表;省略则按预算尽量铺开',
          },
        },
        'required': ['connection', 'database'],
      },
    },
    {
      'name': 'daro_execute_query',
      'description':
          '执行 SQL 并返回结果。只读白名单(SELECT/SHOW/EXPLAIN/DESCRIBE/WITH…SELECT)'
              '在只读档可跑;INSERT/UPDATE/DELETE 需要数据读写档且 UPDATE/DELETE 必须带'
              '有效 WHERE(WHERE TRUE / 1=1 / 无 WHERE 会被 WHERE_TOO_BROAD 拒绝);'
              '认不出的语句按完全访问处理。max_rows 越界夹取不报错;'
              'rowCapApplied=false 表示该语句未被服务端封顶,行数少不代表是全量。'
              '超时后 cancelAttempted=false 时服务端可能仍在执行,勿立即重跑同一语句;'
              'SQLite/Access 本地文件库无法中途取消。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'connection': _connProp,
          'database': _dbProp,
          'schema': _schemaProp,
          'sql': {
            'type': 'string',
            'description': '单条语句(多语句一律按完全访问处理)'
          },
          'max_rows': {
            'type': 'integer',
            'description': '期望行数上限;缺省用策略默认值,超硬上限自动夹取',
          },
          'offset': {'type': 'integer', 'description': '跳过前 N 行(分页续取)'},
        },
        'required': ['connection', 'database', 'sql'],
      },
    },
    {
      'name': 'daro_preview_table',
      'description':
          '预览表数据(服务端分页)。值为字符串,SQL NULL 显示为 "NULL";'
              'nullColumns 给出每行真 NULL 的列下标以消除歧义。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'connection': _connProp,
          'database': _dbProp,
          'schema': _schemaProp,
          'table': {'type': 'string'},
          'limit': {'type': 'integer', 'description': '行数,受策略夹取'},
          'where': {'type': 'string', 'description': 'WHERE 片段(不含关键字)'},
          'orderBy': {'type': 'string', 'description': 'ORDER BY 片段(不含关键字)'},
          'count': {
            'type': 'boolean',
            'description': '是否额外 COUNT(*) 全表(大表慎用)'
          },
        },
        'required': ['connection', 'database', 'table'],
      },
    },
    {
      'name': 'daro_list_routines',
      'description': '列出函数与存储过程(带注释)。SQLite/Access 返回空属正常。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'connection': _connProp,
          'database': _dbProp,
          'schema': _schemaProp,
          'kind': {
            'type': 'string',
            'enum': ['function', 'procedure', 'all'],
            'description': '默认 all',
          },
        },
        'required': ['connection', 'database'],
      },
    },
    {
      'name': 'daro_get_routine_source',
      'description': '取视图/函数/存储过程的 CREATE 定义文本。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'connection': _connProp,
          'database': _dbProp,
          'schema': _schemaProp,
          'name': {'type': 'string'},
          'kind': {
            'type': 'string',
            'enum': ['view', 'function', 'procedure'],
          },
        },
        'required': ['connection', 'database', 'name', 'kind'],
      },
    },
    {
      'name': 'daro_open_table',
      'description':
          '在 daro 桌面界面里打开某张表的标签页(结果太大时比把行塞进上下文更好)。'
              '仅当 daro 应用在运行时可用。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'connection': _connProp,
          'database': _dbProp,
          'table': {'type': 'string'},
        },
        'required': ['connection', 'database', 'table'],
      },
    },
  ];

  static const _connProp = {
    'type': 'string',
    'description': '连接名(见 daro_list_connections)',
  };
  static const _dbProp = {
    'type': 'string',
    'description': '数据库名(见 daro_list_databases)',
  };
  static const _schemaProp = {
    'type': 'string',
    'description': '模式名,可省略(仅有模式层的类型需要)',
  };

  /// 按当次策略过滤后的工具列表(UI 隐藏 ≠ 授权,[callTool] 里再强判一次)。
  Future<List<Map<String, dynamic>>> toolDefinitions() async {
    final policy = await _deps.loadPolicy();
    return [
      for (final t in allToolDefinitions)
        if (policy.toolAllowed(t['name'] as String)) t,
    ];
  }

  // ---------------------------------------------------------- 调用入口 ----

  /// tools/call 入口:任何异常都在这里收敛成契约格式,
  /// 保证外泄给 agent 的只有四元组,没有中文堆栈(P5 的验收点)。
  Future<McpToolOutcome> callTool(String name, Map<String, dynamic> args) async {
    final started = DateTime.now();
    final event = <String, dynamic>{
      'tool': name,
      'ts': started.toIso8601String(),
      'connection': args['connection'],
      'database': args['database'],
    };
    McpToolOutcome outcome;
    try {
      outcome = await _dispatch(name, args, event);
    } on McpException catch (e) {
      event['error'] = e.code.wire;
      outcome = McpToolOutcome({'error': e.toJson()}, isError: true);
    } on DatabaseCallException catch (e) {
      event['error'] = 'DATABASE_ERROR';
      outcome = McpToolOutcome({
        'error': {
          'code': 'DATABASE_ERROR',
          'message': e.message,
          'retryable': false,
          'hint': '数据库引擎拒绝了该语句;按 message 修正语句本身(对象名/语法/权限),'
              '与 MCP 权限设置无关',
        }
      }, isError: true);
    } catch (e) {
      event['error'] = 'INTERNAL';
      outcome =
          McpToolOutcome({'error': McpException.internal('$e').toJson()},
              isError: true);
    }
    event['ok'] = !outcome.isError;
    event['ms'] = DateTime.now().difference(started).inMilliseconds;
    _deps.audit?.call(event);
    return outcome;
  }

  Future<McpToolOutcome> _dispatch(
      String name, Map<String, dynamic> args, Map<String, dynamic> event) async {
    final policy = await _deps.loadPolicy();
    if (!policy.enabled) {
      throw McpException(McpErrorCode.serviceDisabled,
          message: McpDenyReason.serviceDisabled.text);
    }
    if (!policy.toolAllowed(name)) {
      throw McpException(McpErrorCode.toolNotAllowed,
          message: '工具 $name 未开放给 MCP');
    }
    switch (name) {
      case 'daro_list_connections':
        return _listConnections(policy, event);

      case 'daro_list_databases':
        return _withDriver(policy, args, event, (d, ctx) async {
          final all = await d.listDatabases();
          final rules = policy.connections
              .where((r) => r.connection == ctx.connection)
              .toList();
          final scope = rules.isEmpty ? null : rules.first.databaseScope;
          return _ok({
            'databases':
                scope == null || scope.all ? all : all.where(scope.allows).toList(),
          });
        }, takesDatabase: false);

      case 'daro_list_schemas':
        return _withDriver(policy, args, event, (d, ctx) async =>
            _ok({'database': ctx.database, 'schemas': await d.listSchemas(ctx.database)}));

      case 'daro_list_tables':
        return _withDriver(policy, args, event, (d, ctx) async {
          final schema = ctx.schema;
          final kind = _argOpt(args, 'kind') ?? 'table';
          final isView = kind == 'view';
          final names = isView
              ? await d.listViews(ctx.database, schema: schema)
              : await d.listTables(ctx.database, schema: schema);
          final comments = isView
              ? await _optional(() => d.listViewComments(ctx.database, schema: schema))
              : await _optional(
                  () => d.listTableComments(ctx.database, schema: schema));
          final estimates = isView
              ? const <String, int>{}
              : await _optional(
                  () => d.listTableRowEstimates(ctx.database, schema: schema));
          return _ok({
            'kind': kind,
            'tables': [
              for (final t in names)
                {
                  'name': t,
                  if ((comments[t] ?? '').isNotEmpty) 'comment': comments[t],
                  if (estimates[t] != null) 'estimatedRows': estimates[t],
                },
            ],
          });
        });

      case 'daro_describe_table':
        return _withDriver(policy, args, event, (d, ctx) async {
          final table = _argString(args, 'table');
          final columns =
              await d.describeTable(ctx.database, table, schema: ctx.schema);
          DesignTable? design;
          try {
            design =
                await d.readTableDesign(ctx.database, table, schema: ctx.schema);
          } catch (_) {
            // 结构反查失败不影响列定义本身(与查询页的降级一致)
          }
          return _ok({
            'table': table,
            'columns': [
              for (final c in columns)
                {
                  'name': c.name,
                  'type': c.type,
                  'nullable': c.nullable,
                  'primaryKey': c.primaryKey,
                  if (c.defaultValue != null) 'default': c.defaultValue,
                  if (c.comment.isNotEmpty) 'comment': c.comment,
                },
            ],
            if (design != null)
              'indexes': [
                for (final i in design.indexes)
                  {
                    'name': i.name,
                    'columns': i.columnList,
                    if (i.unique) 'unique': true,
                    if (i.method.isNotEmpty) 'method': i.method,
                  },
              ],
            if (design != null)
              'foreignKeys': [
                for (final f in design.foreignKeys)
                  {
                    'name': f.name,
                    'columns': f.columnList,
                    'references':
                        '${f.refSchema.isEmpty ? '' : '${f.refSchema}.'}${f.refTable}(${f.refColumns})',
                    'onDelete': f.onDelete,
                    'onUpdate': f.onUpdate,
                  },
              ],
          });
        });

      case 'daro_get_schema_context':
        return _schemaContext(policy, args, event);

      case 'daro_execute_query':
        return _executeQuery(policy, args, event);

      case 'daro_preview_table':
        return _withDriver(policy, args, event, (d, ctx) async {
          final table = _argString(args, 'table');
          final limit = policy.clampRows(_argInt(args, 'limit'));
          final where = _argOpt(args, 'where');
          final preview = await d.previewTable(ctx.database, table,
              limit: limit,
              schema: ctx.schema,
              where: where,
              orderBy: _argOpt(args, 'orderBy'));
          event['rows'] = preview.rows.length;
          return _ok({
            'table': table,
            'columns': preview.columns,
            'rows': preview.rows,
            'nullColumns': [
              for (var r = 0; r < preview.rows.length; r++)
                [
                  for (var c = 0; c < preview.columns.length; c++)
                    if (preview.isNullAt(r, c)) c,
                ],
            ],
            'truncated': preview.truncated,
            if (args['count'] == true)
              'totalRows':
                  await d.countTable(ctx.database, table, schema: ctx.schema, where: where),
          });
        });

      case 'daro_list_routines':
        return _withDriver(policy, args, event, (d, ctx) async {
          final kind = _argOpt(args, 'kind') ?? 'all';
          final out = <String, dynamic>{'database': ctx.database};
          if (kind == 'all' || kind == 'function') {
            final names = await d.listFunctions(ctx.database, schema: ctx.schema);
            final comments = await _optional(
                () => d.listFunctionComments(ctx.database, schema: ctx.schema));
            out['functions'] = [
              for (final f in names)
                {
                  'name': f,
                  if ((comments[f] ?? '').isNotEmpty) 'comment': comments[f],
                },
            ];
          }
          if (kind == 'all' || kind == 'procedure') {
            out['procedures'] = await d.listProcedures(ctx.database, schema: ctx.schema);
          }
          return _ok(out);
        });

      case 'daro_get_routine_source':
        return _withDriver(policy, args, event, (d, ctx) async {
          final kind = _argString(args, 'kind');
          if (kind != 'view' && kind != 'function' && kind != 'procedure') {
            throw McpException.invalidParams('kind 必须是 view / function / procedure');
          }
          final name = _argString(args, 'name');
          final definition =
              await d.getDefinition(ctx.database, name, kind, schema: ctx.schema);
          return _ok({
            'name': name,
            'kind': kind,
            'definition': definition,
            if (definition == null) 'note': '该引擎/对象没有可读定义文本(如 SQLite 的函数)',
          });
        });

      case 'daro_open_table':
        return _openTable(policy, args, event);

      default:
        throw McpException.invalidParams('未知工具: $name');
    }
  }

  // ------------------------------------------------------------ 各工具 ----

  Future<McpToolOutcome> _listConnections(
      McpPolicy policy, Map<String, dynamic> event) async {
    final connections = await _deps.loadConnections();
    final items = <Map<String, dynamic>>[];
    for (final conn in connections) {
      if (!policy.verdictConnection(conn.name).allowed) continue;
      // D7:任何模式都不回显 password。username/host/port 是 agent 选连接需要的定位信息。
      items.add({
        'name': conn.name,
        'typeId': conn.typeId,
        'host': conn.host,
        'port': conn.port,
        'username': conn.username,
        if (conn.group.isNotEmpty) 'group': conn.group,
        'supported': hasDriver(conn),
        'passwordMissing': connectionNeedsPassword(conn) && conn.password.isEmpty,
      });
    }
    event['rows'] = items.length;
    return _ok({'connections': items});
  }

  Future<McpToolOutcome> _schemaContext(
      McpPolicy policy, Map<String, dynamic> args, Map<String, dynamic> event) async {
    const budgetChars = 6000;
    return _withDriver(policy, args, event, (d, ctx) async {
      final wanted = args['tables'];
      final tables = wanted is List && wanted.isNotEmpty
          ? [for (final t in wanted) if (t is String) t]
          : await d.listTables(ctx.database, schema: ctx.schema);
      final sb = StringBuffer();
      var truncated = false;
      var included = 0;
      for (final t in tables) {
        String line;
        try {
          final cols = await d.describeTable(ctx.database, t, schema: ctx.schema);
          line = '$t(${cols.map((c) => '${c.name}:${_abbrevType(c.type)}'
              '${c.primaryKey ? '*' : ''}').join(', ')})';
        } catch (_) {
          line = '$t(?)'; // 单表读列失败不阻断整个上下文
        }
        if (sb.length + line.length + 1 > budgetChars) {
          truncated = true;
          break;
        }
        sb.writeln(line);
        included++;
      }
      if (included < tables.length) truncated = true;
      event['rows'] = included;
      return _ok({
        'database': ctx.database,
        'context': sb.toString(),
        'tablesIncluded': included,
        'tablesTotal': tables.length,
        'truncated': truncated,
        if (truncated)
          'note': '超出预算被截断;需要完整结构时对感兴趣的表调 daro_describe_table',
      });
    });
  }

  Future<McpToolOutcome> _executeQuery(
      McpPolicy policy, Map<String, dynamic> args, Map<String, dynamic> event) async {
    final sql = _argString(args, 'sql');
    final connName = _argString(args, 'connection');
    final database = _argString(args, 'database');
    final cls = classifySql(sql);
    final mode = policy.effectiveMode(connName, database: database);
    // 判定**之前**就记:被拒的调用同样要留「当时是什么档、语句被分成哪类」,
    // 否则审计日志里只有一串错误码,回看时说不清是哪条规则拦的。
    event.addAll({'mode': mode.wire, 'sqlClass': cls.name});
    final verdict = policy.verdictSql(connName, database, cls);
    if (!verdict.allowed) {
      // 写档下被拦的全表 UPDATE/DELETE 给 WHERE_TOO_BROAD(「补过滤」),
      // 与一般 MODE_DENIED(「换档」)的下一步指令不同(D6 细化)。
      if (verdict.reason == McpDenyReason.modeDenied &&
          mode == McpMode.readWrite &&
          isBroadWrite(sql)) {
        throw McpException(McpErrorCode.whereTooBroad,
            message: McpDenyReason.modeDenied.text);
      }
      throw mcpExceptionForVerdict(verdict)!;
    }
    final limit = policy.clampRows(_argInt(args, 'max_rows'));
    final offset = _argInt(args, 'offset') ?? 0;
    event.addAll({
      'limit': limit,
      // 审计只存语句摘要:整条 INSERT 的数据可能含敏感内容。
      'sqlDigest': sql.length > 200 ? '${sql.substring(0, 200)}…' : sql,
    });

    return _withLease(policy, args, event, mode, (lease, d) async {
      final result = await d.executeQuery(sql, limit: limit, offset: offset);
      // P1:封顶不是无条件的 —— sql_row_cap 的 _blockers 命中即不改写。
      // agent 必须知道「行数少不代表全量」。
      final capApplicable = cls == SqlClass.readOnly && result.isSelect;
      final streamingCap = _streamingCapTypes.contains(lease.typeId);
      final rowCapApplied = !capApplicable ||
          streamingCap ||
          capSelectSql(sql, maxRows: limit + 1, offset: offset) != null;
      event['rows'] = result.rows.length;
      return _ok({
        if (result.isSelect) ...{
          'columns': result.columns,
          'rows': result.rows,
          'rowCount': result.rows.length,
          'truncated': result.truncated,
        } else ...{
          'affectedRows': result.affectedRows,
        },
        'rowCapApplied': rowCapApplied,
        if (capApplicable && !rowCapApplied) 'warnings': ['ROW_CAP_NOT_APPLIED'],
      });
    });
  }

  Future<McpToolOutcome> _openTable(
      McpPolicy policy, Map<String, dynamic> args, Map<String, dynamic> event) async {
    final bridge = _deps.openTableBridge;
    if (bridge == null) {
      throw McpException(McpErrorCode.internal,
          message: '当前宿主没有 UI 桥(仅 daro 内嵌宿主支持 daro_open_table)');
    }
    final connName = _argString(args, 'connection');
    final database = _argString(args, 'database');
    final table = _argString(args, 'table');
    final verdict = policy.verdictDatabase(connName, database);
    if (!verdict.allowed) throw mcpExceptionForVerdict(verdict)!;
    await bridge(connName, database, table);
    return _ok({'opened': true, 'connection': connName, 'table': table});
  }

  // ------------------------------------------------- 连接/驱动公共流程 ----

  /// 「判定 → 取专用驱动 → 超时守卫执行 → 归还」的公共流程。
  /// [takesDatabase] 为 false 时该工具不接受 database(如列库)。
  Future<McpToolOutcome> _withDriver(
      McpPolicy policy,
      Map<String, dynamic> args,
      Map<String, dynamic> event,
      Future<McpToolOutcome> Function(DatabaseDriver d, _Ctx ctx) body,
      {bool takesDatabase = true}) async {
    final connName = _argString(args, 'connection');
    final database =
        takesDatabase ? _argString(args, 'database') : _argOpt(args, 'database');
    final verdict = database == null
        ? policy.verdictConnection(connName)
        : policy.verdictDatabase(connName, database);
    if (!verdict.allowed) throw mcpExceptionForVerdict(verdict)!;
    final mode = policy.effectiveMode(connName, database: database);
    return _withLease(policy, args, event, mode, (lease, d) {
      return body(d, _Ctx(connName, database ?? '', _argOpt(args, 'schema')));
    });
  }

  Future<McpToolOutcome> _withLease(McpPolicy policy, Map<String, dynamic> args,
      Map<String, dynamic> event, McpMode mode,
      Future<McpToolOutcome> Function(Lease lease, DatabaseDriver d) body) async {
    final lease = await _acquireFor(policy, args);
    try {
      final out = await _guarded(lease, policy.timeoutFor(mode), event,
          (d) => body(lease, d));
      lease.release();
      return out;
    } catch (e) {
      // 超时路径 _guarded 已 markDirty(settle 后 release/markDirty 都是 no-op);
      // 其余错误:连接还健康就回池,已断开就销毁
      // (语法错误不该让下家赔一次握手 —— P4 与 P2 的分界)。
      if (lease.driver.isConnected) {
        lease.release();
      } else {
        await lease.markDirty();
      }
      rethrow;
    }
  }

  /// 连接解析 → 可见性/驱动/密码前置 → 池借出。
  Future<Lease> _acquireFor(McpPolicy policy, Map<String, dynamic> args) async {
    final connName = _argString(args, 'connection');
    final database = _argOpt(args, 'database') ?? '';
    final schema = _argOpt(args, 'schema');
    final verdict = policy.verdictConnection(connName);
    if (!verdict.allowed) throw mcpExceptionForVerdict(verdict)!;
    var conn = await _resolveConnection(connName);
    if (!hasDriver(conn)) {
      throw McpException(McpErrorCode.driverUnsupported,
          message: 'daro 当前不支持 ${conn.typeId} 类型的连接');
    }
    if (connectionNeedsPassword(conn) && conn.password.isEmpty) {
      conn = await _supplyPassword(policy, conn);
    }
    final lease = await _deps.pool.acquire(
      conn,
      database: database,
      schema: schema,
      maxDrivers: policy.poolMaxDrivers,
      idleTtl: Duration(seconds: policy.poolIdleTtlSecs),
    );
    lease.typeId = conn.typeId;
    return lease;
  }

  Future<ConnectionInfo> _resolveConnection(String name) async {
    for (final c in await _deps.loadConnections()) {
      if (c.name == name) return c;
    }
    // 「不存在」与「未授权」合并为同一码:不给 agent 探测哪些连接名存在的机会。
    throw McpException(McpErrorCode.connectionNotVisible,
        message: '连接 $name 不存在或未授权给 MCP');
  }

  Future<ConnectionInfo> _supplyPassword(
      McpPolicy policy, ConnectionInfo conn) async {
    if (policy.passwordPrompt == McpPasswordPrompt.deny ||
        _deps.requestPassword == null) {
      throw McpException(McpErrorCode.passwordRequired,
          message: '连接 ${conn.name} 未保存密码');
    }
    // 宿主侧弹窗自带 120s 上限;这里再包一层是防宿主忘了(人不在,agent 干等)。
    bool granted;
    try {
      granted = await _deps
          .requestPassword!(conn)
          .timeout(const Duration(seconds: 121));
    } catch (_) {
      granted = false;
    }
    if (!granted) {
      throw McpException(McpErrorCode.passwordRequired,
          message: '用户未提供连接 ${conn.name} 的密码(取消或超时)');
    }
    final fresh = await _resolveConnection(conn.name);
    if (connectionNeedsPassword(fresh) && fresh.password.isEmpty) {
      throw McpException(McpErrorCode.passwordRequired,
          message: '密码未生效,请让用户在 daro 里对该连接勾选保存密码后重试');
    }
    return fresh;
  }

  /// P1/P2:语句超时 + 尽力带外取消 + 脏实例销毁。**所有**驱动调用都过这道
  /// 守卫(元数据读取同样能挂死,不只是 executeQuery)。
  Future<T> _guarded<T>(Lease lease, Duration timeout,
      Map<String, dynamic> event, Future<T> Function(DatabaseDriver d) body) async {
    final driver = lease.driver;
    int? sessionId;
    try {
      sessionId =
          await driver.serverSessionId().timeout(const Duration(seconds: 5));
    } catch (_) {
      // 拿不到会话 id 不阻断执行,只是到点没法取消。
    }
    try {
      return await body(driver).timeout(timeout);
    } on TimeoutException {
      var cancelAttempted = false;
      String? cancelReason;
      if (sessionId != null) {
        try {
          await driver.killSession(sessionId).timeout(const Duration(seconds: 5));
          cancelAttempted = true;
        } catch (e) {
          cancelReason = '$e';
        }
      } else {
        cancelReason = '该引擎无服务端会话(SQLite/Access 本地文件型),无法中途取消';
      }
      // P2:无论取消成败,这条连接一律不回池(可能仍在跑语句 / 状态未知)。
      await lease.markDirty();
      event['timeout'] = true;
      throw McpException(
        McpErrorCode.queryTimeout,
        message: '查询超过 ${timeout.inSeconds} 秒未返回',
        retryable: cancelAttempted,
        details: {
          'cancelAttempted': cancelAttempted,
          if (cancelReason != null) 'cancelReason': cancelReason,
        },
      );
    } on McpException {
      rethrow;
    } catch (e) {
      // 引擎执行错误:连接已断则销毁,健康则回池(语法错误不该赔一次握手)。
      if (!driver.isConnected) await lease.markDirty();
      throw DatabaseCallException('$e');
    }
  }
}

class _Ctx {
  const _Ctx(this.connection, this.database, this.schema);
  final String connection;
  final String database;
  final String? schema;
}

// ------------------------------------------------------------- 辅助 ----

McpToolOutcome _ok(Map<String, dynamic> payload) => McpToolOutcome(payload);

Future<Map<String, V>> _optional<V>(
    Future<Map<String, V>> Function() query) async {
  try {
    return await query();
  } catch (_) {
    return <String, V>{};
  }
}

/// 列类型缩写(供 get_schema_context 省预算):`varchar(255)` → `vc(255)`。
String _abbrevType(String type) {
  final m = RegExp(r'^([A-Za-z ]+?)\s*(\(.+\))?$').firstMatch(type.trim());
  if (m == null) return type;
  final base = m.group(1)!.toLowerCase().replaceAll(' ', '');
  const map = {
    'character varying': 'vc',
    'varchar': 'vc',
    'character': 'char',
    'integer': 'int',
    'bigint': 'int8',
    'smallint': 'int2',
    'timestamp without time zone': 'ts',
    'timestamp with time zone': 'tstz',
    'double precision': 'f8',
    'numeric': 'dec',
    'boolean': 'bool',
  };
  final short = map[base] ?? base;
  return m.group(2) == null ? short : '$short${m.group(2)}';
}

String _argString(Map<String, dynamic> args, String key) {
  final v = _argOpt(args, key);
  if (v == null) throw McpException.invalidParams('缺少参数 $key');
  return v;
}

String? _argOpt(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null || (v is String && v.isEmpty)) return null;
  if (v is! String) {
    throw McpException.invalidParams('参数 $key 必须是字符串');
  }
  return v;
}

int? _argInt(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is num) return v.toInt();
  throw McpException.invalidParams('参数 $key 必须是整数');
}
