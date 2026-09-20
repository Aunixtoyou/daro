/// MCP 权限策略:**模型 + 判定**(纯函数,不做任何 IO)。
///
/// 设计来源见 `docs/mcp-design-brief.html` §5.1 / §5.3 / §7:
/// - 策略由 daro 桌面端写盘,MCP 宿主**每次请求重新读取**(定稿语义:改权限不必重启客户端);
/// - 策略是**上限**而非授权 —— 数据库账号本身的权限、`hasDriver()` 永远压不过这里;
/// - 判定口径按 D6 定为**白名单**:只有明确只读的语句算只读,分类不出来的一律要求完全访问。
///
/// ⚠️ 本文件(以及整个 `lib/mcp/`)禁止 `import package:flutter` / `dart:ui`,
/// 也不得引入 `lib/data/db_types.dart`、`lib/data/sql_completions.dart`
/// 这两个 lib/data 里唯一带 Flutter 的文件。
/// 该约束由 `tool/check_mcp_purity.dart` 做**传递闭包**校验,已接进 CI。
library;

import 'dart:math';

/// 策略文件格式版本(落盘字段 `schemaVersion`)。
///
/// 只增不减:**升级时不得放大既有规则的权限**(沿用 DBX 的兼容语义)——
/// 旧文件缺该字段时按 [1] 处理即可,因为 v1 的字段全是可选的。
const int kMcpPolicySchemaVersion = 1;

/// 执行模式(对应 daro 设置页「MCP」里的三档能力矩阵)。
enum McpMode {
  /// 只读:查询与元数据读取。
  readonly('readonly', '只读'),

  /// 数据读写:额外允许范围可控的 INSERT / 带有效 WHERE 的 UPDATE / DELETE。
  readWrite('readWrite', '数据读写'),

  /// 完全访问:额外允许全表更新/清空、DDL、无法可靠分类的请求。
  full('full', '完全访问');

  const McpMode(this.wire, this.label);

  /// 落盘用的稳定字符串(**不要**用 [name] 之外的枚举序号,改名会破坏旧策略文件)。
  final String wire;

  /// 界面展示名。
  final String label;

  static McpMode? parse(Object? v) {
    if (v is! String) return null;
    for (final m in McpMode.values) {
      if (m.wire == v) return m;
    }
    return null;
  }
}

/// 语句分类结果,以及它要求的最低执行模式。
enum SqlClass {
  /// 明确只读(查询 / 元数据读取)。
  readOnly('readonly'),

  /// 范围可控的写入(INSERT、带有效 WHERE 的 UPDATE/DELETE)。
  scopedWrite('readWrite'),

  /// 高风险(全表更新/删除、DDL、TRUNCATE、会话/权限类语句、EXPLAIN 写语句)。
  dangerous('full'),

  /// 无法可靠分类(多语句脚本、空语句、不认识的开头)—— 按「需要完全访问」处理。
  unclassifiable('full');

  const SqlClass(this.minimumModeWire);

  /// 该分类要求的最低执行模式字符串(见 [McpMode.wire])。
  final String minimumModeWire;

  McpMode get minimumMode => McpMode.parse(minimumModeWire)!;
}

/// 拒绝原因。宿主侧(步骤 ④ 的 `mcp_errors.dart`)据此映射成线上错误码 +
/// 给 agent 的下一步提示;这里只承载**判定语义**,不掺协议字段。
enum McpDenyReason {
  /// MCP 服务未启用(策略 `enabled == false`)。
  serviceDisabled('MCP 服务未启用'),

  /// 连接不在 allowlist 内。
  connectionNotVisible('该连接未授权给 MCP'),

  /// 请求的库不在该连接的数据库范围内。
  databaseOutOfScope('该数据库不在 MCP 允许范围内'),

  /// 当前生效模式低于语句分类要求的最低模式。
  modeDenied('当前执行模式不允许该操作'),

  /// 工具不在 allowlist 内(服务端每次调用强校验,不只是 UI 隐藏)。
  toolNotAllowed('该工具未开放给 MCP'),

  /// 该连接类型在 daro 里没有可用驱动(痛点 P5)。
  driverUnsupported('daro 当前不支持该数据库类型'),

  /// 连接需要密码但未保存,且宿主无法/未被允许向用户索取(痛点 P3)。
  passwordRequired('该连接未保存密码'),

  /// 专用驱动实例并发已达上限(痛点 P4)。
  poolExhausted('MCP 专用连接数已达上限');

  const McpDenyReason(this.text);

  /// 中文说明(保留给人看的原文,对齐本仓「中文提示保留原始信息」的约定)。
  final String text;
}

/// 判定结论:允许 / 拒绝(带原因)。
class McpVerdict {
  const McpVerdict.allow()
      : allowed = true,
        reason = null;

  const McpVerdict.deny(this.reason) : allowed = false;

  final bool allowed;
  final McpDenyReason? reason;

  /// 拒绝原因文案;允许时返回空串。
  String get message => reason?.text ?? '';

  @override
  String toString() => allowed ? 'allow' : 'deny(${reason!.name})';
}

/// 数据库范围:`all` = 全部库;否则按 [include] 精确名匹配;
/// 两者都空(且 `all == false`)= **不允许访问任何库**。
class McpDatabaseScope {
  const McpDatabaseScope({this.all = true, this.include = const []});

  /// 只允许这几张库。**显式**构造:直接写 `McpDatabaseScope(include: [...])`
  /// 会因 `all` 默认 true 而变成「全部库」——范围看似收紧实则没变。
  const McpDatabaseScope.only(List<String> include)
      : all = false,
        include = include;

  /// 该连接完全不可用(既非全部,也没指定库)。
  const McpDatabaseScope.deny()
      : all = false,
        include = const [];

  final bool all;
  final List<String> include;

  bool allows(String? database) {
    if (all) return true;
    if (database == null || database.isEmpty) return false;
    return include.contains(database);
  }

  Map<String, dynamic> toJson() => {
        'all': all,
        if (!all) 'include': include,
      };

  static McpDatabaseScope fromJson(Map<String, dynamic> json) {
    final all = json['all'] == true;
    final raw = json['include'];
    return McpDatabaseScope(
      all: all,
      include: raw is List ? [for (final e in raw) if (e is String) e] : const [],
    );
  }
}

/// 单个数据库的执行模式覆盖。**模型先落盘,Phase-1 界面不暴露**(定稿 D5:
/// 单库覆盖要求策略文件带「规则版本」才敢做放宽语义,避免旧文件被新默认值放大)。
class McpDatabaseMode {
  const McpDatabaseMode(this.database, this.mode);

  final String database;
  final McpMode mode;

  Map<String, dynamic> toJson() => {'database': database, 'mode': mode.wire};

  static McpDatabaseMode? fromJson(Map<String, dynamic> json) {
    final db = json['database'];
    final mode = McpMode.parse(json['mode']);
    if (db is! String || db.isEmpty || mode == null) return null;
    return McpDatabaseMode(db, mode);
  }
}

/// 连接级规则。
class McpConnectionRule {
  const McpConnectionRule({
    required this.connection,
    this.mode,
    this.databaseScope = const McpDatabaseScope(),
    this.databaseModes = const [],
  });

  /// 连接名即标识(daro 的 `ConnectionInfo` 没有 id,定稿 D10 暂不引入)。
  /// ⚠️ 因此**改名会让规则脱钩** —— 由 [McpPolicy.withRenamedConnection] 兜。
  final String connection;

  /// 该连接的默认执行模式;`null` = 继承 [McpPolicy.defaultMode]。
  final McpMode? mode;

  final McpDatabaseScope databaseScope;
  final List<McpDatabaseMode> databaseModes;

  Map<String, dynamic> toJson() => {
        'connection': connection,
        if (mode != null) 'mode': mode!.wire,
        'databaseScope': databaseScope.toJson(),
        if (databaseModes.isNotEmpty)
          'databaseModes': [for (final m in databaseModes) m.toJson()],
      };

  static McpConnectionRule? fromJson(Map<String, dynamic> json) {
    final name = json['connection'];
    if (name is! String || name.isEmpty) return null;
    final scopeRaw = json['databaseScope'];
    final modesRaw = json['databaseModes'];
    return McpConnectionRule(
      connection: name,
      mode: McpMode.parse(json['mode']),
      databaseScope: scopeRaw is Map<String, dynamic>
          ? McpDatabaseScope.fromJson(scopeRaw)
          : const McpDatabaseScope(),
      databaseModes: modesRaw is List
          ? [
              for (final e in modesRaw)
                // 解析失败(缺 database / mode 认不出)的条目直接丢掉,不抛异常。
                if (e is Map<String, dynamic>) ..._some(McpDatabaseMode.fromJson(e)),
            ]
          : const [],
    );
  }
}

/// 密码缺失时的处置(痛点 P3)。
enum McpPasswordPrompt {
  /// 内嵌宿主:在 daro 里弹密码窗让人补录,人取消才拒绝。
  askInApp('askInApp'),

  /// stdio 宿主/无人值守:直接拒绝,绝不接受 agent 代传密码。
  deny('deny');

  const McpPasswordPrompt(this.wire);
  final String wire;

  static McpPasswordPrompt? parse(Object? v) {
    if (v is! String) return null;
    for (final p in McpPasswordPrompt.values) {
      if (p.wire == v) return p;
    }
    return null;
  }
}

/// 按模式分档的查询超时(痛点 P1:`executeQuery` 接口本身没有 timeout 形参,
/// 必须由 MCP 侧包 `Future.timeout`)。
class McpTimeouts {
  const McpTimeouts({
    this.readonlySecs = 30,
    this.readWriteSecs = 60,
    this.fullSecs = 300,
  });

  final int readonlySecs;
  final int readWriteSecs;
  final int fullSecs;

  Duration forMode(McpMode mode) => Duration(
      seconds: switch (mode) {
        McpMode.readonly => readonlySecs,
        McpMode.readWrite => readWriteSecs,
        McpMode.full => fullSecs,
      });

  Map<String, dynamic> toJson() => {
        'readonly': readonlySecs,
        'readWrite': readWriteSecs,
        'full': fullSecs,
      };

  static McpTimeouts fromJson(Map<String, dynamic> json) {
    int read(String key, int fallback) {
      final v = json[key];
      if (v is! num) return fallback;
      final secs = v.toInt();
      // 0 / 负数视为无效,退回默认值:超时是护栏,不能被配成「永不超时」。
      return secs > 0 ? secs : fallback;
    }

    const d = McpTimeouts();
    return McpTimeouts(
      readonlySecs: read('readonly', d.readonlySecs),
      readWriteSecs: read('readWrite', d.readWriteSecs),
      fullSecs: read('full', d.fullSecs),
    );
  }
}

/// 内嵌 HTTP 宿主设置(定稿 D1:Phase-1 只有这一种宿主)。
class McpHttpSettings {
  const McpHttpSettings({
    this.host = '127.0.0.1',
    this.port = 5225,
    this.token = '',
    this.allowRemote = false,
  });

  final String host;
  final int port;

  /// Bearer Token。空串 = 仅回环监听时免鉴权;绑非回环地址时**必须**非空。
  final String token;

  /// 允许远程访问:还需 [token] 非空 + 精确 Host 白名单(Phase-2)。
  final bool allowRemote;

  /// 是否监听非回环地址(决定鉴权是否强制)。
  bool get isLoopback => host == '127.0.0.1' || host == 'localhost' || host == '::1';

  /// 服务是否可用 —— 绑非回环却没 token 一律视为**未就绪**,宁可不启动。
  bool get isServeable => token.isNotEmpty || isLoopback;

  String get endpoint => 'http://$host:$port/mcp';

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'token': token,
        'allowRemote': allowRemote,
      };

  static McpHttpSettings fromJson(Map<String, dynamic> json) => McpHttpSettings(
        host: json['host'] is String && (json['host'] as String).isNotEmpty
            ? json['host'] as String
            : '127.0.0.1',
        port: json['port'] is num && (json['port'] as num) > 0
            ? (json['port'] as num).toInt()
            : 5225,
        token: json['token'] is String ? json['token'] as String : '',
        allowRemote: json['allowRemote'] == true,
      );
}

/// MCP 权限策略(落盘 `mcp_policy.json`)。
class McpPolicy {
  const McpPolicy({
    this.schemaVersion = kMcpPolicySchemaVersion,
    this.enabled = false,
    this.defaultMode = McpMode.readonly,
    this.connectionScopeAll = true,
    this.connectionNames = const [],
    this.connections = const [],
    this.tools = const [],
    this.maxRows = 100,
    this.hardRowCap = 1000,
    this.timeouts = const McpTimeouts(),
    this.poolIdleTtlSecs = 600,
    this.poolMaxDrivers = 8,
    this.passwordPrompt = McpPasswordPrompt.askInApp,
    this.auditEnabled = true,
    this.http = const McpHttpSettings(),
  });

  /// 全新安装的默认策略:**关闭 + 只读**。用户不主动开,agent 一律连不上。
  const McpPolicy.defaults() : this();

  /// 策略格式版本。升级时**不得**放大既有规则的权限(定稿沿用 DBX 的兼容语义)。
  final int schemaVersion;

  final bool enabled;
  final McpMode defaultMode;

  /// `true` = 所有连接(含以后新增的)都可见;`false` = 仅 [connectionNames]。
  final bool connectionScopeAll;
  final List<String> connectionNames;

  /// 连接级覆盖(执行模式 / 数据库范围)。
  final List<McpConnectionRule> connections;

  /// 工具 allowlist;空列表 = [kMcpPhase1ToolIds] 全选。
  final List<String> tools;

  final int maxRows;
  final int hardRowCap;
  final McpTimeouts timeouts;
  final int poolIdleTtlSecs;
  final int poolMaxDrivers;
  final McpPasswordPrompt passwordPrompt;
  final bool auditEnabled;
  final McpHttpSettings http;

  // ---------------------------------------------------------------- 判定 ----

  /// 服务是否可用:启用 + 宿主就绪。未就绪时**不启动监听**,并在设置页说明原因。
  bool get isServing => enabled && http.isServeable;

  /// 连接是否对 MCP 可见。
  McpVerdict verdictConnection(String connectionName) {
    if (!enabled) return const McpVerdict.deny(McpDenyReason.serviceDisabled);
    if (!connectionScopeAll && !connectionNames.contains(connectionName)) {
      return const McpVerdict.deny(McpDenyReason.connectionNotVisible);
    }
    return const McpVerdict.allow();
  }

  /// 连接是否被显式授权过(改名守卫用得上)。
  bool authorizesConnection(String connectionName) =>
      connectionNames.contains(connectionName) ||
      connections.any((r) => r.connection == connectionName);

  McpConnectionRule? _ruleOf(String connectionName) {
    for (final r in connections) {
      if (r.connection == connectionName) return r;
    }
    return null;
  }

  /// 数据库是否在连接范围内。[database] 为 null 表示「尚未指定库」(如列库请求),
  /// 此时只要连接可见就放行。
  McpVerdict verdictDatabase(String connectionName, String? database) {
    final conn = verdictConnection(connectionName);
    if (!conn.allowed) return conn;
    final rule = _ruleOf(connectionName);
    if (database != null && rule != null && !rule.databaseScope.allows(database)) {
      return const McpVerdict.deny(McpDenyReason.databaseOutOfScope);
    }
    return const McpVerdict.allow();
  }

  /// 生效模式:**单库覆盖 → 连接默认 → 全局默认**(由小到大回退)。
  McpMode effectiveMode(String connectionName, {String? database}) {
    final rule = _ruleOf(connectionName);
    if (rule != null && database != null) {
      for (final m in rule.databaseModes) {
        if (m.database == database) return m.mode;
      }
    }
    return rule?.mode ?? defaultMode;
  }

  /// 工具是否开放(服务端每次调用强校验)。
  bool toolAllowed(String toolId) =>
      tools.isEmpty ? kMcpPhase1ToolIds.contains(toolId) : tools.contains(toolId);

  /// 行数夹取:**越界夹取而非报错**(定稿沿用 DBX 语义)。
  int clampRows(int? requested) {
    final cap = hardRowCap < 1 ? 1 : hardRowCap;
    final want = (requested == null || requested < 1) ? maxRows : requested;
    return want > cap ? cap : want;
  }

  Duration timeoutFor(McpMode mode) => timeouts.forMode(mode);

  /// 组合判定:连接 → 库 → 驱动可用性 → 语句分类 → 模式。
  ///
  /// 语句分类由调用方(宿主)用 `classifySql()` 先算好再传进来 ——
  /// 这样 `mcp_policy.dart` 不依赖 SQL 文本处理,两个文件单向依赖不成环。
  McpVerdict verdictSql(
    String connectionName,
    String? database,
    SqlClass sqlClass, {
    bool driverSupported = true,
  }) {
    final db = verdictDatabase(connectionName, database);
    if (!db.allowed) return db;
    if (!driverSupported) {
      return const McpVerdict.deny(McpDenyReason.driverUnsupported);
    }
    if (_rank(sqlClass.minimumMode) >
        _rank(effectiveMode(connectionName, database: database))) {
      return const McpVerdict.deny(McpDenyReason.modeDenied);
    }
    return const McpVerdict.allow();
  }

  /// 字段级拷贝(设置页逐项改动用)。传 null = 保持原值,与 `ConnectionInfo.copyWith` 同约定。
  McpPolicy copyWith({
    bool? enabled,
    McpMode? defaultMode,
    bool? connectionScopeAll,
    List<String>? connectionNames,
    List<McpConnectionRule>? connections,
    List<String>? tools,
    int? maxRows,
    int? hardRowCap,
    McpTimeouts? timeouts,
    int? poolIdleTtlSecs,
    int? poolMaxDrivers,
    McpPasswordPrompt? passwordPrompt,
    bool? auditEnabled,
    McpHttpSettings? http,
  }) =>
      McpPolicy(
        schemaVersion: schemaVersion,
        enabled: enabled ?? this.enabled,
        defaultMode: defaultMode ?? this.defaultMode,
        connectionScopeAll: connectionScopeAll ?? this.connectionScopeAll,
        connectionNames: connectionNames ?? this.connectionNames,
        connections: connections ?? this.connections,
        tools: tools ?? this.tools,
        maxRows: maxRows ?? this.maxRows,
        hardRowCap: hardRowCap ?? this.hardRowCap,
        timeouts: timeouts ?? this.timeouts,
        poolIdleTtlSecs: poolIdleTtlSecs ?? this.poolIdleTtlSecs,
        poolMaxDrivers: poolMaxDrivers ?? this.poolMaxDrivers,
        passwordPrompt: passwordPrompt ?? this.passwordPrompt,
        auditEnabled: auditEnabled ?? this.auditEnabled,
        http: http ?? this.http,
      );

  /// 改名时迁移策略条目(定稿 D10:不引入 id,靠约定兜)。
  McpPolicy withRenamedConnection(String oldName, String newName) {
    if (oldName == newName) return this;
    return copyWith(
      connectionNames: [
        for (final n in connectionNames) if (n == oldName) newName else n,
      ],
      connections: [
        for (final r in connections)
          if (r.connection == oldName)
            McpConnectionRule(
              connection: newName,
              mode: r.mode,
              databaseScope: r.databaseScope,
              databaseModes: r.databaseModes,
            )
          else
            r,
      ],
    );
  }

  // ------------------------------------------------------------ 序列化 ----

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'enabled': enabled,
        'defaultMode': defaultMode.wire,
        'connectionScopeAll': connectionScopeAll,
        if (!connectionScopeAll) 'connectionNames': connectionNames,
        if (connections.isNotEmpty)
          'connections': [for (final r in connections) r.toJson()],
        if (tools.isNotEmpty) 'tools': tools,
        'maxRows': maxRows,
        'hardRowCap': hardRowCap,
        'queryTimeoutSecs': timeouts.toJson(),
        'poolIdleTtlSecs': poolIdleTtlSecs,
        'poolMaxDrivers': poolMaxDrivers,
        'passwordPrompt': passwordPrompt.wire,
        'audit': {'enabled': auditEnabled},
        'http': http.toJson(),
      };

  /// 宽松解析:缺字段一律回落到默认值,**不抛异常**。
  /// 策略文件坏掉不能阻止应用启动,也不能悄悄放大权限(见 [McpPolicy.defaults])。
  static McpPolicy fromJson(Map<String, dynamic> json) {
    const d = McpPolicy.defaults();
    final mode = McpMode.parse(json['defaultMode']) ?? d.defaultMode;
    final names = json['connectionNames'];
    final conns = json['connections'];
    final toolsRaw = json['tools'];
    final timeoutRaw = json['queryTimeoutSecs'];
    final httpRaw = json['http'];
    final auditRaw = json['audit'];
    final prompt = McpPasswordPrompt.parse(json['passwordPrompt']) ??
        d.passwordPrompt;
    final maxRows = _positiveInt(json['maxRows'], d.maxRows);
    return McpPolicy(
      schemaVersion: _positiveInt(json['schemaVersion'], d.schemaVersion),
      enabled: json['enabled'] == true,
      defaultMode: mode,
      connectionScopeAll: json['connectionScopeAll'] != false,
      connectionNames:
          names is List ? [for (final e in names) if (e is String) e] : const [],
      connections: conns is List
          ? [
              for (final e in conns)
                // 无名规则(缺 connection 字段)丢掉:留着它只会是一条永不命中的死规则。
                if (e is Map<String, dynamic>) ..._some(McpConnectionRule.fromJson(e)),
            ]
          : const [],
      tools: toolsRaw is List ? [for (final e in toolsRaw) if (e is String) e] : const [],
      maxRows: maxRows,
      hardRowCap: max(_positiveInt(json['hardRowCap'], d.hardRowCap), maxRows),
      timeouts: timeoutRaw is Map<String, dynamic>
          ? McpTimeouts.fromJson(timeoutRaw)
          : d.timeouts,
      poolIdleTtlSecs: _positiveInt(json['poolIdleTtlSecs'], d.poolIdleTtlSecs),
      poolMaxDrivers: _positiveInt(json['poolMaxDrivers'], d.poolMaxDrivers),
      passwordPrompt: prompt,
      auditEnabled: auditRaw is Map<String, dynamic>
          ? auditRaw['enabled'] != false
          : d.auditEnabled,
      http:
          httpRaw is Map<String, dynamic> ? McpHttpSettings.fromJson(httpRaw) : d.http,
    );
  }

  static int _positiveInt(Object? v, int fallback) =>
      v is num && v.toInt() > 0 ? v.toInt() : fallback;

  @override
  String toString() =>
      'McpPolicy(enabled: $enabled, defaultMode: ${defaultMode.wire}, '
      'connections: ${connections.length}, scopeAll: $connectionScopeAll)';
}

int _rank(McpMode mode) => mode.index;

/// 把可空的解析结果摊平成集合元素:脏条目(返回 null)丢掉即可,不抛异常。
Iterable<T> _some<T>(T? value) => value == null ? const [] : [value];

/// Phase-1 工具清单(简报 §5.2 的十行 = 11 个工具名,例程那行含 list / get_source 两枚)。
///
/// ⚠️ 这份名单会被 `test/mcp_policy_test.dart` 的快照钉死:工具名是 agent 侧提示词
/// 的一部分,改名等于破坏契约(对齐本仓 `navicat_export_test.dart` 的属性顺序快照)。
const List<String> kMcpPhase1ToolIds = [
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
];

/// 生成 Bearer Token(纯 Dart,`Random.secure`)。
///
/// 不用 `password_hash`/`pointycastle`:这里要的是**本机 HTTP 鉴权用的随机串**,
/// 不是口令哈希,标准库足够,也免得 `lib/mcp` 拖进加密库依赖。
String generateMcpToken({int bytes = 24}) {
  final rnd = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    buf.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}
