/// 用户 / 角色(User & Role)对象的 SQL 生成与解析工具。
///
/// 与 [RoutineSql] 同构:页面只持有"表单字段",DDL 由本文件拼装,
/// 「SQL 预览」标签直接复用同一份拼装结果,保证"看到的 = 保存时执行的"。
///
/// ## 账号标识
/// MySQL / MariaDB 的账号是 `user@host` 二元组(mysql.user 的联合主键),
/// 而连接树 / 对象面板里的对象名是 `listUsers` 返回的 `user@host` 字符串。
/// 因此本文件用 [UserAccount] 承载拆分后的两段,并提供 [UserAccount.parse]
/// 做反向解析(按**最后一个** `@` 切分,主机名里不会再出现 `@`)。
///
/// 其它类型(PostgreSQL / SQL Server)无 host 概念,host 恒为空串。
library;

/// 账号类型:决定可选的认证插件 / 权限模型
enum UserObjectKind {
  /// MySQL / MariaDB:`user@host` + 认证插件 + 库/表级权限
  mysqlAccount,

  /// PostgreSQL:`pg_roles` 角色(可登录者即用户),无 host,有成员继承
  pgRole,

  /// SQL Server:`database_principals`(登录名 / 数据库用户),无 host
  sqlPrincipal,

  /// SQLite / Access:无服务端账号体系
  unsupported,
}

/// 一个账号的标识(用户名 + 主机)。
class UserAccount {
  const UserAccount({required this.name, this.host = ''});

  /// 用户名(登录名 / 角色名)
  final String name;

  /// 主机(仅 MySQL / MariaDB 有意义;其它类型为空串)
  final String host;

  /// 从 `user@host` 形式解析;无 `@` 时按纯用户名处理。
  /// 按**最后一个** `@` 切分:MySQL 的用户名本身可能含 `@`
  /// (如邮箱式用户名),而 host 段不会含 `@`。
  static UserAccount parse(String raw) {
    final s = raw.trim();
    final idx = s.lastIndexOf('@');
    if (idx <= 0) return UserAccount(name: s);
    return UserAccount(name: s.substring(0, idx), host: s.substring(idx + 1));
  }

  /// 回写为对象名(`user@host`;host 为空时退化为纯用户名)
  String get displayName => host.isEmpty ? name : '$name@$host';

  /// 是否可绑定到具体对象(用户名非空)
  bool get isValid => name.trim().isNotEmpty;

  @override
  String toString() => displayName;
}

/// 密码过期策略(Navicat「常规」页的「密码过期策略」下拉)
enum PasswordExpirePolicy {
  /// 交由服务端默认(不改动,生成的 SQL 里不出现该子句)
  defaultPolicy,

  /// 立即失效:下次登录必须改密码
  expired,

  /// 永不过期
  never,

  /// 按天数过期
  interval,
}

/// 密码过期策略的取值与展示:
/// - 取值是 Navicat 那套文本(`DEFAULT` / `PASSWORD EXPIRE` …),与截图一致;
/// - 展示名由调用方按语言从 ARB 取(见 `userSql.policyLabel`)。
extension PasswordExpirePolicyX on PasswordExpirePolicy {
  /// 稳定标识(不随语言变化;持久化与匹配用)
  String get id => switch (this) {
        PasswordExpirePolicy.defaultPolicy => 'DEFAULT',
        PasswordExpirePolicy.expired => 'PASSWORD EXPIRE',
        PasswordExpirePolicy.never => 'PASSWORD EXPIRE NEVER',
        PasswordExpirePolicy.interval => 'PASSWORD EXPIRE INTERVAL',
      };
}

/// MySQL / MariaDB 认证插件候选(「插件」下拉;空串 = 交由服务端默认)
class AuthPluginCatalog {
  AuthPluginCatalog._();

  /// 常见认证插件。`caching_sha2_password` 自 MySQL 8.0 起为默认,
  /// `mysql_native_password` 兼容老客户端,MariaDB 用 `mysql_native_password`
  /// / `ed25519` / `unix_socket` 等。
  static const List<String> mysql = [
    'caching_sha2_password',
    'mysql_native_password',
    'sha256_password',
    'auth_socket',
  ];

  static const List<String> mariadb = [
    'mysql_native_password',
    'ed25519',
    'unix_socket',
    'pam',
  ];

  /// 候选列表;空列表 = 当前类型不提供插件选择(PG / SQL Server 无此概念)
  static List<String> of(String typeId) => switch (typeId) {
        'mysql' => mysql,
        'mariadb' => mariadb,
        _ => const [],
      };
}

/// 一条权限项(「服务器权限」「权限」页的表格行)。
///
/// 权限是"三段式"模型:`库.表.列`,任一段为通配(`*` / 空)表示更粗粒度。
/// Navicat 的权限页把同一对象的多个权限聚成一行(勾选矩阵),
/// 本模型按 [privileges] 集合承载,便于直接映射为 GRANT 语句。
class UserPrivilegeEntry {
  UserPrivilegeEntry({
    this.database = '',
    this.table = '',
    this.column = '',
    Set<String>? privileges,
    this.grantOption = false,
  }) : privileges = privileges ?? <String>{};

  /// 库名;空串 = 服务器级(全局)
  String database;

  /// 表名;空串 = 整库级
  String table;

  /// 列名;空串 = 整表级
  String column;

  /// 已授予的权限名(大写,如 SELECT / INSERT;`ALL PRIVILEGES` 单独占一项)
  Set<String> privileges;

  /// 是否可转授(WITH GRANT OPTION)
  bool grantOption;

  /// 作用域标识:服务器 / 库 / 表 / 列
  PrivilegeScope get scope {
    if (database.isEmpty) return PrivilegeScope.server;
    if (table.isEmpty) return PrivilegeScope.database;
    if (column.isEmpty) return PrivilegeScope.table;
    return PrivilegeScope.column;
  }

  /// 供表格展示的目标名(`*.*` / `db.*` / `db.tbl` / `db.tbl.col`)
  String get target {
    final d = database.isEmpty ? '*' : database;
    final t = table.isEmpty ? '*' : table;
    if (column.isEmpty) return '$d.$t';
    return '$d.$t.$column';
  }

  UserPrivilegeEntry copy() => UserPrivilegeEntry(
        database: database,
        table: table,
        column: column,
        privileges: {...privileges},
        grantOption: grantOption,
      );
}

/// 权限作用域
enum PrivilegeScope { server, database, table, column }

/// MySQL 权限名全集(服务器权限 + 库/表权限共用的候选词表)。
///
/// 取自 MySQL 8.0 的 `SHOW PRIVILEGES` 常见项;`ALL PRIVILEGES` 表示全量授权。
class PrivilegeCatalog {
  PrivilegeCatalog._();

  /// 全局(服务器)权限
  static const List<String> server = [
    'ALL PRIVILEGES',
    'ALTER',
    'ALTER ROUTINE',
    'CREATE',
    'CREATE ROLE',
    'CREATE ROUTINE',
    'CREATE TABLESPACE',
    'CREATE TEMPORARY TABLES',
    'CREATE USER',
    'CREATE VIEW',
    'DELETE',
    'DROP',
    'EVENT',
    'EXECUTE',
    'FILE',
    'GRANT OPTION',
    'INDEX',
    'INSERT',
    'LOCK TABLES',
    'PROCESS',
    'PROXY',
    'REFERENCES',
    'RELOAD',
    'REPLICATION CLIENT',
    'REPLICATION SLAVE',
    'SELECT',
    'SHOW DATABASES',
    'SHOW VIEW',
    'SHUTDOWN',
    'SUPER',
    'TRIGGER',
    'UPDATE',
  ];

  /// 库 / 表级权限(不含进程管理等服务器专属项)
  static const List<String> databaseLevel = [
    'ALL PRIVILEGES',
    'ALTER',
    'ALTER ROUTINE',
    'CREATE',
    'CREATE ROUTINE',
    'CREATE TEMPORARY TABLES',
    'CREATE VIEW',
    'DELETE',
    'DROP',
    'EVENT',
    'EXECUTE',
    'GRANT OPTION',
    'INDEX',
    'INSERT',
    'LOCK TABLES',
    'REFERENCES',
    'SELECT',
    'SHOW VIEW',
    'TRIGGER',
    'UPDATE',
  ];

  /// 按作用域给出候选权限列表(PG / SQL Server 用自己的模型,返回空)
  static List<String> forScope(String typeId, PrivilegeScope scope) {
    if (typeId != 'mysql' && typeId != 'mariadb') return const [];
    if (scope == PrivilegeScope.server) return server;
    return databaseLevel;
  }
}

/// PostgreSQL 角色的属性(`pg_roles` 的布尔列,对应 Navicat 的「高级」页)
class PgRoleAttributes {
  PgRoleAttributes({
    this.canLogin = true,
    this.superUser = false,
    this.createDb = false,
    this.createRole = false,
    this.inherit = true,
    this.replication = false,
    this.bypassRls = false,
    this.connectionLimit = -1,
    this.validUntil = '',
  });

  /// LOGIN(可登录;不可登录即纯角色/组)
  bool canLogin;
  bool superUser;
  bool createDb;
  bool createRole;

  /// INHERIT(自动继承所属角色的权限)
  bool inherit;
  bool replication;
  bool bypassRls;

  /// 连接数上限;-1 = 不限
  int connectionLimit;

  /// 口令失效时间(空 = 不过期)
  String validUntil;
}

/// SQL Server 数据库主体的类型(`sys.database_principals.type`)
enum SqlPrincipalType {
  /// SQL 登录名(FROM LOGIN / 带密码)
  sqlUser('S'),

  /// Windows 用户
  windowsUser('U'),

  /// Windows 组
  windowsGroup('G'),

  /// 数据库角色
  databaseRole('R');

  const SqlPrincipalType(this.code);

  /// `sys.database_principals.type` 的单字母代码
  final String code;

  static SqlPrincipalType? fromCode(String code) {
    for (final v in values) {
      if (v.code == code) return v;
    }
    return null;
  }
}

/// 用户 / 角色的完整表单状态(设计页持有,SQL 预览与保存共用)。
///
/// 所有"未填"都用空串 / 空集合表示,**不出现 null**——这样
/// [UserSql.buildAccountDdl] 能以"字段是否有内容"来决定语句里
/// 要不要出现该子句,与本项目其它设计页(见表设计器)的约定一致。
class UserSpec {
  UserSpec({
    this.originalName = '',
    this.originalHost = '',
    this.username = '',
    this.host = '',
    this.plugin = '',
    this.password = '',
    this.passwordConfirm = '',
    this.expirePolicy = PasswordExpirePolicy.defaultPolicy,
    this.expireDays = 90,
    this.newPassword = '',
    this.comment = '',
    this.isRole = false,
    this.pg = null,
    this.sqlPrincipalType = SqlPrincipalType.sqlUser,
    List<UserPrivilegeEntry>? serverPrivileges,
    List<UserPrivilegeEntry>? privileges,
    Set<String>? memberOf,
    Set<String>? members,
  })  : serverPrivileges = serverPrivileges ?? <UserPrivilegeEntry>[],
        privileges = privileges ?? <UserPrivilegeEntry>[],
        memberOf = memberOf ?? <String>{},
        members = members ?? <String>{};

  /// 编辑模式下原始用户名(重命名时生成 RENAME TO)
  String originalName;

  /// 编辑模式下原始主机
  String originalHost;

  /// 「常规」页:用户名
  String username;

  /// 「常规」页:主机(仅 MySQL 系)
  String host;

  /// 「常规」页:认证插件(仅 MySQL 系;空 = 服务端默认)
  String plugin;

  /// 「常规」页:密码(新建时为"设置密码",编辑时空 = 不改密码)
  String password;

  /// 「常规」页:确认密码(仅界面校验,不参与 SQL)
  String passwordConfirm;

  /// 「常规」页:密码过期策略
  PasswordExpirePolicy expirePolicy;

  /// 「常规」页:过期天数(仅 [PasswordExpirePolicy.interval] 使用)
  int expireDays;

  /// 「高级」页:修改密码(编辑模式下的新密码;与 [password] 语义相同,
  /// 分开只是为了让「高级」页能独立操作)
  String newPassword;

  /// 「高级」页:注释 / 备注
  String comment;

  /// 是否为角色(MySQL 8 `CREATE ROLE`;PG 用 `CREATE ROLE ... NOLOGIN`)
  bool isRole;

  /// PostgreSQL 角色属性(仅 [UserObjectKind.pgRole] 使用)
  PgRoleAttributes? pg;

  /// SQL Server 主体类型
  SqlPrincipalType sqlPrincipalType;

  /// 「服务器权限」页(MySQL 全局权限;PG 的角色属性也归这里)
  List<UserPrivilegeEntry> serverPrivileges;

  /// 「权限」页(库 / 表 / 列级权限)
  List<UserPrivilegeEntry> privileges;

  /// 「成员属于」页:本账号所属的角色(MySQL 8 role / PG 成员继承)
  Set<String> memberOf;

  /// 「成员」页:属于本角色的成员(反向关系)
  Set<String> members;

  /// 新建模式(无原始账号)
  bool get isNew => originalName.isEmpty;

  /// 当前账号标识
  UserAccount get account =>
      UserAccount(name: username.trim(), host: host.trim());

  /// 原始账号标识(编辑模式)
  UserAccount get originalAccount =>
      UserAccount(name: originalName, host: originalHost);

  /// 用户名是否被改动过(编辑模式下决定是否生成 RENAME)
  bool get nameChanged =>
      !isNew &&
      (username.trim() != originalName.trim() ||
          host.trim() != originalHost.trim());

  UserSpec copy() => UserSpec(
        originalName: originalName,
        originalHost: originalHost,
        username: username,
        host: host,
        plugin: plugin,
        password: password,
        passwordConfirm: passwordConfirm,
        expirePolicy: expirePolicy,
        expireDays: expireDays,
        newPassword: newPassword,
        comment: comment,
        isRole: isRole,
        pg: pg == null
            ? null
            : PgRoleAttributes(
                canLogin: pg!.canLogin,
                superUser: pg!.superUser,
                createDb: pg!.createDb,
                createRole: pg!.createRole,
                inherit: pg!.inherit,
                replication: pg!.replication,
                bypassRls: pg!.bypassRls,
                connectionLimit: pg!.connectionLimit,
                validUntil: pg!.validUntil,
              ),
        sqlPrincipalType: sqlPrincipalType,
        serverPrivileges:
            [for (final e in serverPrivileges) e.copy()],
        privileges: [for (final e in privileges) e.copy()],
        memberOf: {...memberOf},
        members: {...members},
      );
}

/// 用户 / 角色 DDL 生成。
///
/// 约定:所有生成方法返回**语句列表**(不合并成多语句串)——调用方
/// (`AppState`)逐条执行,这样某条失败时能精确定位,也不会被驱动的
/// 多语句拆分规则影响(见 `sql_split.dart` 的历史坑)。
class UserSql {
  UserSql._();

  /// 该数据库类型是否有服务端账号体系
  static bool supportsUsers(String typeId) => switch (typeId) {
        'mysql' || 'mariadb' || 'postgresql' || 'sqlserver' => true,
        _ => false,
      };

  /// 账号模型
  static UserObjectKind kindOf(String typeId) => switch (typeId) {
        'mysql' || 'mariadb' => UserObjectKind.mysqlAccount,
        'postgresql' => UserObjectKind.pgRole,
        'sqlserver' => UserObjectKind.sqlPrincipal,
        _ => UserObjectKind.unsupported,
      };

  /// 是否有 host 概念(决定「常规」页是否显示「主机」行)
  static bool hasHost(String typeId) {
    final k = kindOf(typeId);
    return k == UserObjectKind.mysqlAccount;
  }

  /// 是否支持"成员属于 / 成员"(角色成员关系)
  static bool supportsMembership(String typeId) =>
      typeId == 'mysql' || typeId == 'mariadb' || typeId == 'postgresql';

  /// 是否支持"服务器权限 / 权限"矩阵
  static bool supportsPrivileges(String typeId) =>
      typeId == 'mysql' || typeId == 'mariadb';

  /// 'user'@'host' 字面量(MySQL 系);非 MySQL 系退化为普通标识符。
  /// host 为空时按 MySQL 语义退化为 `%`(任意主机)——
  /// 这是 `mysql.user` 里"匹配所有主机"的取值,也是 Navicat 的默认。
  static String accountLiteral(UserAccount account) {
    final u = _esc(account.name);
    return "'$u'@'${_esc(_quoteHost(account.host))}'";
  }

  /// 标识符按类型引用(`name` / "name" / [name])
  static String identifier(String typeId, String name) {
    switch (typeId) {
      case 'postgresql':
      case 'sqlite':
        return '"${name.replaceAll('"', '""')}"';
      case 'sqlserver':
      case 'access':
        return '[${name.replaceAll(']', ']]')}]';
      default:
        return '`${name.replaceAll('`', '``')}`';
    }
  }

  /// 字符串字面量(单引号转义)
  static String literal(String value) => "'${_esc(value)}'";

  static String _esc(String v) => v.replaceAll("'", "''");

  static String _quoteHost(String host) {
    final h = host.trim();
    return h.isEmpty ? '%' : h;
  }

  // ── 密码过期策略子句 ──────────────────────────────────────

  /// MySQL 的密码过期子句。
  /// 返回空串表示"不改动该属性"(默认策略)。
  static String _mysqlExpireClause(UserSpec spec) => switch (spec.expirePolicy) {
        PasswordExpirePolicy.defaultPolicy => '',
        PasswordExpirePolicy.expired => 'PASSWORD EXPIRE',
        PasswordExpirePolicy.never => 'PASSWORD EXPIRE NEVER',
        PasswordExpirePolicy.interval =>
          'PASSWORD EXPIRE INTERVAL ${spec.expireDays < 0 ? 0 : spec.expireDays} DAY',
      };

  /// PostgreSQL 的 VALID UNTIL 子句(过期策略在 PG 里是绝对时间)
  static String _pgValidUntil(UserSpec spec) {
    final explicit = spec.pg?.validUntil.trim() ?? '';
    if (explicit.isNotEmpty) return explicit;
    if (spec.expirePolicy == PasswordExpirePolicy.never) return 'infinity';
    if (spec.expirePolicy == PasswordExpirePolicy.interval &&
        spec.expireDays > 0) {
      // 服务端算时间更可靠:交给 SQL 表达式而不是本地时钟
      return "NOW() + INTERVAL '${spec.expireDays} days'";
    }
    return '';
  }

  // ── 主语句:CREATE / ALTER ────────────────────────────────

  /// 生成"创建账号"语句(新建模式)。
  /// 用户名为空时返回空列表 —— 由调用方在界面上提示必填,
  /// 不让 `CREATE USER ''@'%'` 这种语句流到服务端。
  static List<String> buildCreate(String typeId, UserSpec spec) {
    if (!spec.account.isValid) return const [];
    switch (kindOf(typeId)) {
      case UserObjectKind.mysqlAccount:
        return [_createMysql(spec)];
      case UserObjectKind.pgRole:
        return [_createPg(spec)];
      case UserObjectKind.sqlPrincipal:
        return [_createSqlServer(spec)];
      case UserObjectKind.unsupported:
        return const [];
    }
  }

  /// 生成"修改账号"语句(编辑模式)。
  /// 名称改动走 RENAME(MySQL 8 / PG 支持;SQL Server 不支持 → 由调用方拒绝)。
  static List<String> buildAlter(String typeId, UserSpec spec) {
    if (!spec.account.isValid) return const [];
    final out = <String>[];
    switch (kindOf(typeId)) {
      case UserObjectKind.mysqlAccount:
        out.addAll(_alterMysql(spec));
      case UserObjectKind.pgRole:
        out.addAll(_alterPg(spec));
      case UserObjectKind.sqlPrincipal:
        out.addAll(_alterSqlServer(spec));
      case UserObjectKind.unsupported:
        return const [];
    }
    // 注释(PG 用 COMMENT ON ROLE,MySQL 8 无角色注释语法 → 跳过)
    if (typeId == 'postgresql' && spec.comment.trim().isNotEmpty) {
      out.add('COMMENT ON ROLE ${identifier(typeId, spec.username.trim())} '
          'IS ${literal(spec.comment.trim())}');
    }
    return out;
  }

  /// 生成"删除账号"语句
  static List<String> buildDrop(
    String typeId,
    UserAccount account, {
    bool isRole = false,
  }) {
    switch (kindOf(typeId)) {
      case UserObjectKind.mysqlAccount:
        final kw = isRole ? 'ROLE' : 'USER';
        return ['DROP $kw IF EXISTS ${accountLiteral(account)}'];
      case UserObjectKind.pgRole:
        return ['DROP ROLE IF EXISTS ${identifier(typeId, account.name)}'];
      case UserObjectKind.sqlPrincipal:
        return [
          'DROP USER IF EXISTS ${identifier(typeId, account.name)}',
        ];
      case UserObjectKind.unsupported:
        return const [];
    }
  }

  // ── MySQL ────────────────────────────────────────────────

  static String _createMysql(UserSpec spec) {
    final a = spec.account;
    final buf = StringBuffer()
      ..write(spec.isRole ? 'CREATE ROLE ' : 'CREATE USER ')
      ..write(accountLiteral(a));

    final plugin = spec.plugin.trim();
    final pwd = spec.password;
    if (!spec.isRole) {
      if (plugin.isNotEmpty) {
        if (pwd.isEmpty) {
          // 指定插件但不改密码:MySQL 8 允许 IDENTIFIED WITH plugin
          buf.write(' IDENTIFIED WITH ${identifier('mysql', plugin)}');
        } else {
          buf.write(' IDENTIFIED WITH ${identifier('mysql', plugin)} '
              'BY ${literal(pwd)}');
        }
      } else if (pwd.isNotEmpty) {
        buf.write(' IDENTIFIED BY ${literal(pwd)}');
      }
      final expire = _mysqlExpireClause(spec);
      if (expire.isNotEmpty) buf.write(' $expire');
    }
    return '$buf';
  }

  static List<String> _alterMysql(UserSpec spec) {
    final out = <String>[];
    final a = spec.account;
    // 改名:MySQL 8.0 起支持 RENAME USER;低版本由服务端报错
    if (spec.nameChanged) {
      out.add('RENAME USER ${accountLiteral(spec.originalAccount)} '
          'TO ${accountLiteral(a)}');
    }
    final sets = <String>[];
    final plugin = spec.plugin.trim();
    // 编辑模式下 password 空 = 不改密码;plugin 变了才需要写 IDENTIFIED WITH
    if (!spec.isRole) {
      if (spec.password.isNotEmpty) {
        if (plugin.isNotEmpty) {
          sets.add('IDENTIFIED WITH ${identifier('mysql', plugin)} '
              'BY ${literal(spec.password)}');
        } else {
          sets.add('IDENTIFIED BY ${literal(spec.password)}');
        }
      } else if (plugin.isNotEmpty && plugin != _originalPluginOf(spec)) {
        sets.add('IDENTIFIED WITH ${identifier('mysql', plugin)}');
      }
      final expire = _mysqlExpireClause(spec);
      if (expire.isNotEmpty) sets.add(expire);
    } else if (spec.newPassword.isNotEmpty) {
      sets.add('IDENTIFIED BY ${literal(spec.newPassword)}');
    }
    if (sets.isNotEmpty) {
      out.add('ALTER USER ${accountLiteral(a)} ${sets.join(' ')}');
    }
    return out;
  }

  /// 编辑模式下的原始插件(由 [UserSpec.plugin] 承担;此处仅为可读性保留钩子)
  static String _originalPluginOf(UserSpec spec) => '';

  // ── PostgreSQL ────────────────────────────────────────────

  static String _createPg(UserSpec spec) {
    final name = spec.username.trim();
    final pg = spec.pg ?? PgRoleAttributes();
    final opts = <String>[_pgOptions(pg, forCreate: true)];
    final pwd = spec.password.isNotEmpty ? spec.password : spec.newPassword;
    if (pwd.isNotEmpty) {
      opts.add('PASSWORD ${literal(pwd)}');
    }
    final valid = _pgValidUntil(spec);
    if (valid.isNotEmpty) opts.add('VALID UNTIL $valid');
    return 'CREATE ROLE ${identifier('postgresql', name)} '
        'WITH ${opts.join(' ')}';
  }

  static List<String> _alterPg(UserSpec spec) {
    final out = <String>[];
    final name = spec.username.trim();
    final ident = identifier('postgresql', name);
    if (spec.nameChanged) {
      out.add('ALTER ROLE ${identifier('postgresql', spec.originalName)} '
          'RENAME TO $ident');
    }
    final pg = spec.pg;
    if (pg != null) {
      out.add('ALTER ROLE $ident WITH ${_pgOptions(pg, forCreate: false)}');
    }
    final pwd = spec.password.isNotEmpty ? spec.password : spec.newPassword;
    if (pwd.isNotEmpty) {
      out.add('ALTER ROLE $ident WITH PASSWORD ${literal(pwd)}');
    }
    final valid = _pgValidUntil(spec);
    if (valid.isNotEmpty) out.add('ALTER ROLE $ident VALID UNTIL $valid');
    return out;
  }

  /// PG 角色属性子句。
  /// [forCreate] = true 时给未勾选项也补上反向子句(NOSUPERUSER …),
  /// 保证"新建"完全由表单决定;修改时只写需要打开的项(避免误关既有权限)。
  static String _pgOptions(PgRoleAttributes pg, {required bool forCreate}) {
    final opts = <String>[];
    if (forCreate) {
      opts.add(pg.canLogin ? 'LOGIN' : 'NOLOGIN');
      opts.add(pg.superUser ? 'SUPERUSER' : 'NOSUPERUSER');
      opts.add(pg.createDb ? 'CREATEDB' : 'NOCREATEDB');
      opts.add(pg.createRole ? 'CREATEROLE' : 'NOCREATEROLE');
      opts.add(pg.inherit ? 'INHERIT' : 'NOINHERIT');
      opts.add(pg.replication ? 'REPLICATION' : 'NOREPLICATION');
      opts.add(pg.bypassRls ? 'BYPASSRLS' : 'NOBYPASSRLS');
    } else {
      if (pg.canLogin) opts.add('LOGIN');
      if (pg.superUser) opts.add('SUPERUSER');
      if (pg.createDb) opts.add('CREATEDB');
      if (pg.createRole) opts.add('CREATEROLE');
      if (pg.inherit) opts.add('INHERIT');
      if (pg.replication) opts.add('REPLICATION');
      if (pg.bypassRls) opts.add('BYPASSRLS');
    }
    opts.add('CONNECTION LIMIT ${pg.connectionLimit}');
    return opts.join(' ');
  }

  // ── SQL Server ────────────────────────────────────────────

  static String _createSqlServer(UserSpec spec) {
    final name = identifier('sqlserver', spec.username.trim());
    final pwd = spec.password;
    switch (spec.sqlPrincipalType) {
      case SqlPrincipalType.windowsUser:
        return 'CREATE USER $name FOR LOGIN $name';
      case SqlPrincipalType.windowsGroup:
        return 'CREATE USER $name FROM GROUP $name';
      case SqlPrincipalType.databaseRole:
        return 'CREATE ROLE $name';
      case SqlPrincipalType.sqlUser:
        if (pwd.isEmpty) return 'CREATE USER $name WITHOUT LOGIN';
        return 'CREATE LOGIN $name WITH PASSWORD = ${literal(pwd)}; '
            'CREATE USER $name FOR LOGIN $name';
    }
  }

  static List<String> _alterSqlServer(UserSpec spec) {
    final out = <String>[];
    final name = identifier('sqlserver', spec.username.trim());
    final pwd = spec.newPassword.isNotEmpty ? spec.newPassword : spec.password;
    // SQL Server 的数据库主体不能改名(要 DROP/CREATE),只改密码属性
    if (pwd.isNotEmpty && spec.sqlPrincipalType == SqlPrincipalType.sqlUser) {
      out.add('ALTER LOGIN $name WITH PASSWORD = ${literal(pwd)}');
    }
    return out;
  }

  // ── 权限:GRANT / REVOKE ─────────────────────────────────

  /// 由权限条目生成 GRANT 语句(MySQL 系)。
  ///
  /// Navicat 的"权限"页保存语义是**全量覆盖**:先 REVOKE 该对象的旧权限,
  /// 再按当前勾选重新 GRANT。这里只生成"正向"的 GRANT 列表,
  /// 覆盖用的 REVOKE 由 [buildRevokeAll] 生成,调用方按需组合。
  static List<String> buildGrants(
    String typeId,
    UserAccount account,
    List<UserPrivilegeEntry> entries,
  ) {
    if (kindOf(typeId) != UserObjectKind.mysqlAccount) return const [];
    final out = <String>[];
    final who = accountLiteral(account);
    for (final e in entries) {
      if (e.privileges.isEmpty) continue;
      final privs = _privilegeList(e);
      final ifGrant = e.grantOption ? ' WITH GRANT OPTION' : '';
      out.add('GRANT $privs ON ${_grantTarget(e)} TO $who$ifGrant');
    }
    return out;
  }

  /// 撤销某账号在指定对象上的全部权限(权限页"先清后授"用)。
  /// [target] 形如 `*.*` / `db.*` / `db.tbl`。
  static List<String> buildRevokeAll(
    String typeId,
    UserAccount account,
    String target,
  ) {
    if (kindOf(typeId) != UserObjectKind.mysqlAccount) return const [];
    final who = accountLiteral(account);
    return [
      'REVOKE ALL PRIVILEGES, GRANT OPTION FROM $who',
    ];
  }

  /// `GRANT ... ON` 的对象名。
  /// MySQL 的授权对象**不转义**(用反引号会被部分版本拒绝),
  /// 故这里按字面拼接:`*.*` / `db`.* / `db`.`tbl`
  static String _grantTarget(UserPrivilegeEntry e) {
    final d = e.database.trim();
    final t = e.table.trim();
    if (d.isEmpty) return '*.*';
    if (t.isEmpty) return '`${d.replaceAll('`', '``')}`.*';
    return '`${d.replaceAll('`', '``')}`.`${t.replaceAll('`', '``')}`';
  }

  static String _privilegeList(UserPrivilegeEntry e) {
    final list = e.privileges.toList()..sort();
    // 含 ALL PRIVILEGES 时不必再列细项
    if (list.any((p) => p.toUpperCase() == 'ALL PRIVILEGES')) {
      return 'ALL PRIVILEGES';
    }
    return list.join(', ');
  }

  // ── 角色成员关系 ─────────────────────────────────────────

  /// 生成"把本账号加入这些角色"的语句。
  /// - MySQL 8:`GRANT role TO user@host`
  /// - PostgreSQL:`GRANT role TO user`
  static List<String> buildMembershipAdd(
    String typeId,
    UserAccount account,
    Set<String> roles,
  ) {
    if (roles.isEmpty) return const [];
    switch (kindOf(typeId)) {
      case UserObjectKind.mysqlAccount:
        return [
          'GRANT ${roles.map((r) => identifier('mysql', r)).join(', ')} '
              'TO ${accountLiteral(account)}',
        ];
      case UserObjectKind.pgRole:
        return [
          'GRANT ${roles.map((r) => identifier('postgresql', r)).join(', ')} '
              'TO ${identifier('postgresql', account.name)}',
        ];
      case UserObjectKind.sqlPrincipal:
        return [
          'ALTER ROLE ${roles.map((r) => identifier('sqlserver', r)).join(', ')} '
              'ADD MEMBER ${identifier('sqlserver', account.name)}',
        ];
      case UserObjectKind.unsupported:
        return const [];
    }
  }

  /// 生成"从这些角色中移除本账号"的语句
  static List<String> buildMembershipRemove(
    String typeId,
    UserAccount account,
    Set<String> roles,
  ) {
    if (roles.isEmpty) return const [];
    switch (kindOf(typeId)) {
      case UserObjectKind.mysqlAccount:
        return [
          'REVOKE ${roles.map((r) => identifier('mysql', r)).join(', ')} '
              'FROM ${accountLiteral(account)}',
        ];
      case UserObjectKind.pgRole:
        return [
          'REVOKE ${roles.map((r) => identifier('postgresql', r)).join(', ')} '
              'FROM ${identifier('postgresql', account.name)}',
        ];
      case UserObjectKind.sqlPrincipal:
        return [
          'ALTER ROLE ${roles.map((r) => identifier('sqlserver', r)).join(', ')} '
              'DROP MEMBER ${identifier('sqlserver', account.name)}',
        ];
      case UserObjectKind.unsupported:
        return const [];
    }
  }

  // ── 完整保存脚本(「SQL 预览」标签 & 保存动作共用) ─────────

  /// 把表单状态铺开成一条完整脚本(注释 + 语句),供 SQL 预览展示。
  /// **保存时执行的就是这里列出的语句**,二者同源。
  static List<String> buildScript(String typeId, UserSpec spec) {
    final out = <String>[];
    // MySQL 的语句自带引号,不需要额外包裹;这里统一加分隔符方便阅读
    out.addAll(spec.isNew ? buildCreate(typeId, spec) : buildAlter(typeId, spec));

    final a = spec.account;
    if (supportsMembership(typeId) && spec.memberOf.isNotEmpty) {
      out.addAll(buildMembershipAdd(typeId, a, _sorted(spec.memberOf)));
    }
    if (supportsPrivileges(typeId)) {
      if (spec.serverPrivileges.isNotEmpty) {
        out.addAll(buildGrants(typeId, a, spec.serverPrivileges));
      }
      if (spec.privileges.isNotEmpty) {
        out.addAll(buildGrants(typeId, a, spec.privileges));
      }
    }
    return out;
  }

  /// 脚本的可读文本(SQL 预览页;每条语句补分号 + 空行分隔)
  static String buildScriptText(String typeId, UserSpec spec) {
    final stmts = buildScript(typeId, spec);
    if (stmts.isEmpty) {
      return '-- 无可执行的语句(请先填写「常规」页的账号信息)';
    }
    final buf = StringBuffer();
    for (var i = 0; i < stmts.length; i++) {
      final s = stmts[i].trimRight();
      buf.writeln(s.endsWith(';') ? s : '$s;');
      if (i != stmts.length - 1) buf.writeln();
    }
    return buf.toString();
  }

  /// 排序后的角色集合(Membership 语句用;顺序稳定便于预览与比对)
  static Set<String> _sorted(Set<String> src) {
    final list = src.toList()..sort();
    return list.toSet();
  }

  /// 把驱动返回的原始权限行聚合成 [UserPrivilegeEntry](MySQL 系)。
  ///
  /// [rows] 每项形如 `(database, table, column, privilege, grantOption)`,
  /// 空串表示通配段。同一 (db, table, column) 的多条权限合并进一条 entry。
  static List<UserPrivilegeEntry> aggregate(
      Iterable<List<String>> rows, {bool serverLevel = false}) {
    final map = <String, UserPrivilegeEntry>{};
    for (final row in rows) {
      if (row.isEmpty) continue;
      final db = serverLevel ? '' : _at(row, 0);
      final tbl = serverLevel ? '' : _at(row, 1);
      final col = serverLevel ? '' : _at(row, 2);
      final priv = _at(row, serverLevel ? 0 : 3).toUpperCase();
      final grant = _at(row, serverLevel ? 1 : 4).toUpperCase();
      if (priv.isEmpty || priv == 'USAGE') continue;
      final key = '$db\u0000$tbl\u0000$col';
      final entry = map.putIfAbsent(
        key,
        () => UserPrivilegeEntry(database: db, table: tbl, column: col),
      );
      entry.privileges.add(priv);
      if (grant == 'YES' || grant == 'TRUE') entry.grantOption = true;
    }
    final list = map.values.toList()
      ..sort((a, b) => a.target.compareTo(b.target));
    return list;
  }

  static String _at(List<String> row, int i) => i < row.length ? row[i] : '';
}
