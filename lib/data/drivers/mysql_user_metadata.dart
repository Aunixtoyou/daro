/// MySQL / MariaDB 的账号元数据读取:把 `mysql.*` 系统表里取回的行
/// 映射为设计页的表单模型([UserSpec])与权限行。
///
/// 抽成共享函数的理由与 [db_metadata] 一致:MySQL 与 MariaDB 两张驱动的
/// 用户模型完全一致(同样的 `mysql.user` / `mysql.db` / `mysql.tables_priv`),
/// 方言差异集中在「角色是否存在」一处(MariaDB 无 `mysql.role_edges`)。
/// 驱动只负责"执行 SQL 拿行",这里的纯函数负责"行 → 模型"。
library;

import '../user_sql.dart';

/// MySQL / MariaDB 账号元数据读取(不直接持有连接,由调用方传"执行器")。
///
/// [executor] 接收 SQL 返回 `List<Map<String, String>>`(列名 → 值),
/// 由各驱动用自己的连接实现。
class MysqlUserMetadata {
  const MysqlUserMetadata({required this.executor, required this.isMariaDb});

  /// 执行 SQL 并返回行(列名 → 值;null 已折成空串)
  final Future<List<Map<String, String>>> Function(String sql) executor;

  /// 是否为 MariaDB:决定「密码过期策略」与「角色」两处的可用性
  final bool isMariaDb;

  /// 该版本是否有角色概念(MariaDB 10.0.5+ 有角色,但无 `mysql.role_edges`
  /// 这张表——它用 `mysql.roles_mapping`;为稳妥起见按 MariaDB 不支持处理,
  /// 由界面隐藏「成员属于 / 成员」页)
  bool get supportsRoles => !isMariaDb;

  /// 读取账号详情(「常规」「高级」页初值)。
  ///
  /// `mysql.user` 的列按 MySQL 版本增删,故用 `SELECT *` 取全部列再按列名挑,
  /// 避免硬编码列名导致低版本 / MariaDB 报 "Unknown column"。
  Future<UserSpec?> read(String database, String account) async {
    final a = UserAccount.parse(account);
    if (!a.isValid) return null;
    final rows = await executor(
      'SELECT * FROM mysql.user WHERE User = ${_lit(a.name)} '
      "AND Host = ${_lit(a.host)}",
    );
    if (rows.isEmpty) return null;
    final row = rows.first;

    final expirePolicy = _policyOf(row);
    final spec = UserSpec(
      originalName: a.name,
      originalHost: a.host,
      username: a.name,
      host: a.host,
      plugin: _col(row, 'plugin'),
      expirePolicy: expirePolicy,
      expireDays: _intOf(_col(row, 'password_lifetime')),
      // 密码不读回(mysql.user 里是哈希,回填无意义且会误导);
      // 编辑模式下密码留空 = 不改密码
      password: '',
      comment: _col(row, 'User_comment'),
      isRole: _isRole(row),
    );
    return spec;
  }

  /// 读取服务器级权限(`mysql.user` 的 `*_priv` 布尔列)。
  /// 价值形如 `Y` / `N`(旧版)或 `Y` / `` (部分列),统一按"是否 Y"判定。
  Future<List<List<String>>> readServerPrivileges(
      String database, String account) async {
    final a = UserAccount.parse(account);
    if (!a.isValid) return const [];
    final rows = await executor(
      'SELECT * FROM mysql.user WHERE User = ${_lit(a.name)} '
      "AND Host = ${_lit(a.host)}",
    );
    if (rows.isEmpty) return const [];
    final row = rows.first;
    final out = <List<String>>[];
    // 只取以 _priv 结尾的列:这正是 MySQL 的全局权限列命名约定
    final keys = row.keys.where((k) => k.endsWith('_priv')).toList()..sort();
    // grant_priv 单独处理:它是"可转授"而不是一项权限
    final grant = _yes(_col(row, 'grant_priv'));
    for (final key in keys) {
      if (key == 'grant_priv') continue;
      if (!_yes(row[key])) continue;
      final priv = _privNameFromColumn(key);
      if (priv.isEmpty) continue;
      out.add([priv, grant ? 'YES' : 'NO']);
    }
    // 无任何权限但有 GRANT OPTION:仍然是一条有效信息
    if (out.isEmpty && grant) out.add(['GRANT OPTION', 'YES']);
    return out;
  }

  /// 读取库 / 表级权限(`mysql.db` + `mysql.tables_priv`)。
  /// 返回行形如 `(database, table, column, privilege, grantOption)`,
  /// 供 [UserSql.aggregate] 聚合。
  Future<List<List<String>>> readDatabasePrivileges(
      String database, String account) async {
    final a = UserAccount.parse(account);
    if (!a.isValid) return const [];
    final who = 'User = ${_lit(a.name)} AND Host = ${_lit(a.host)}';
    final out = <List<String>>[];

    // 库级:mysql.db 的 Db 列 + 各项 *_priv
    final dbRows = await executor('SELECT * FROM mysql.db WHERE $who');
    for (final row in dbRows) {
      final db = _col(row, 'Db');
      if (db.isEmpty) continue;
      final grant = _yes(_col(row, 'grant_priv'));
      for (final key in row.keys.toList()..sort()) {
        if (!key.endsWith('_priv') || key == 'grant_priv') continue;
        if (!_yes(row[key])) continue;
        final priv = _privNameFromColumn(key);
        if (priv.isEmpty) continue;
        out.add([db, '', '', priv, grant ? 'YES' : 'NO']);
      }
    }

    // 表级:mysql.tables_priv 的 Table_priv 是 SET 列(逗号分隔多权限)
    final tblRows = await executor('SELECT * FROM mysql.tables_priv WHERE $who');
    for (final row in tblRows) {
      final db = _col(row, 'Db');
      final tbl = _col(row, 'Table_name');
      if (db.isEmpty || tbl.isEmpty) continue;
      final grant = _yes(_col(row, 'grant_priv'));
      for (final priv in _splitSet(_col(row, 'Table_priv'))) {
        out.add([db, tbl, '', priv, grant ? 'YES' : 'NO']);
      }
    }

    // 列级:mysql.columns_priv 的 Column_priv 同上是 SET 列
    final colRows = await executor('SELECT * FROM mysql.columns_priv WHERE $who');
    for (final row in colRows) {
      final db = _col(row, 'Db');
      final tbl = _col(row, 'Table_name');
      final col = _col(row, 'Column_name');
      if (db.isEmpty || tbl.isEmpty || col.isEmpty) continue;
      for (final priv in _splitSet(_col(row, 'Column_priv'))) {
        out.add([db, tbl, col, priv, 'NO']);
      }
    }
    return out;
  }

  /// 读取该账号所属的角色(「成员属于」页已勾选项)。
  /// MariaDB 无 `mysql.role_edges`,返回空列表。
  Future<List<String>> readUserRoles(String database, String account) async {
    if (!supportsRoles) return const [];
    final a = UserAccount.parse(account);
    if (!a.isValid) return const [];
    try {
      final rows = await executor(
        'SELECT FROM_USER, FROM_HOST FROM mysql.role_edges '
        "WHERE TO_USER = ${_lit(a.name)} AND TO_HOST = ${_lit(a.host)}",
      );
      return [
        for (final r in rows)
          if (_col(r, 'FROM_USER').isNotEmpty)
            '${_col(r, 'FROM_USER')}@${_col(r, 'FROM_HOST').isEmpty ? '%' : _col(r, 'FROM_HOST')}',
      ];
    } catch (_) {
      // 权限不足 / 版本无此表:降级为"无角色",不阻断整个设计页
      return const [];
    }
  }

  /// 读取属于该角色的成员(「成员」页)。
  Future<List<String>> readRoleMembers(String database, String account) async {
    if (!supportsRoles) return const [];
    final a = UserAccount.parse(account);
    if (!a.isValid) return const [];
    try {
      final rows = await executor(
        'SELECT TO_USER, TO_HOST FROM mysql.role_edges '
        "WHERE FROM_USER = ${_lit(a.name)} AND FROM_HOST = ${_lit(a.host)}",
      );
      return [
        for (final r in rows)
          if (_col(r, 'TO_USER').isNotEmpty)
            '${_col(r, 'TO_USER')}@${_col(r, 'TO_HOST').isEmpty ? '%' : _col(r, 'TO_HOST')}',
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 可授予的角色候选(「成员属于」页的候选列表):
  /// MySQL 8 把角色也放在 `mysql.user` 里,靠 `is_role` 列区分。
  Future<List<String>> listRoles(String database) async {
    if (!supportsRoles) return const [];
    try {
      final rows = await executor(
        "SELECT User, Host FROM mysql.user WHERE is_role = 'Y' "
        'ORDER BY User, Host',
      );
      return [
        for (final r in rows)
          if (_col(r, 'User').isNotEmpty)
            '${_col(r, 'User')}@${_col(r, 'Host').isEmpty ? '%' : _col(r, 'Host')}',
      ];
    } catch (_) {
      return const [];
    }
  }

  // ── 行解析小工具 ────────────────────────────────────────

  /// `mysql.user.is_role`(MySQL 8+)判断;MariaDB 无此列 → false
  bool _isRole(Map<String, String> row) => _yes(_col(row, 'is_role'));

  /// 密码过期策略:`password_expired` = Y → 已过期;
  /// `password_lifetime` 为 NULL → 用默认;0 → 永不过期;N → 按天。
  /// MySQL 用 NULL 表达"跟随全局默认",驱动读到的是空串,无法与"列不存在"
  /// 区分,故这里把"两列都读不到"当作默认策略。
  PasswordExpirePolicy _policyOf(Map<String, String> row) {
    if (_yes(_col(row, 'password_expired'))) {
      return PasswordExpirePolicy.expired;
    }
    final raw = _col(row, 'password_lifetime');
    if (raw.isEmpty) return PasswordExpirePolicy.defaultPolicy;
    final days = int.tryParse(raw);
    if (days == null) return PasswordExpirePolicy.defaultPolicy;
    return days == 0 ? PasswordExpirePolicy.never : PasswordExpirePolicy.interval;
  }

  int _intOf(String raw) {
    final v = int.tryParse(raw);
    return (v == null || v <= 0) ? 90 : v;
  }

  /// `Y` / `YES` / `1` 视为真
  bool _yes(String? v) {
    final s = (v ?? '').trim().toUpperCase();
    return s == 'Y' || s == 'YES' || s == '1' || s == 'TRUE';
  }

  /// `Select_priv` → `SELECT`;`Grant_priv` → `GRANT OPTION`;
  /// `Repl_slave_priv` → `REPLICATION SLAVE`
  String _privNameFromColumn(String column) {
    final base = column.endsWith('_priv')
        ? column.substring(0, column.length - '_priv'.length)
        : column;
    if (base.isEmpty) return '';
    switch (base.toLowerCase()) {
      case 'grant':
        return 'GRANT OPTION';
      case 'repl_slave':
        return 'REPLICATION SLAVE';
      case 'repl_client':
        return 'REPLICATION CLIENT';
      case 'create_tmp_table':
        return 'CREATE TEMPORARY TABLES';
      case 'show_db':
        return 'SHOW DATABASES';
      default:
        // 单段词直接大写;多段按空格分开再各自大写(如 alter_routine)
        return base
            .split('_')
            .where((p) => p.isNotEmpty)
            .map((p) => p.toUpperCase())
            .join(' ');
    }
  }

  /// `mysql.tables_priv.Table_priv` 是 SET 列,取值形如 `Select,Insert`
  List<String> _splitSet(String raw) {
    if (raw.trim().isEmpty) return const [];
    return [
      for (final p in raw.split(','))
        if (p.trim().isNotEmpty) p.trim().toUpperCase(),
    ];
  }

  /// 单引号转义
  String _lit(String v) => "'${v.replaceAll("'", "''")}'";

  /// 列名取值:大小写无关(系统表列名在 MySQL / MariaDB 间大小写不一致),
  /// 缺失 / null 一律折成空串 —— 这样调用方不必到处写 `?? ''`。
  static String _col(Map<String, String> row, String name) =>
      row[name] ?? row[name.toLowerCase()] ?? '';

  /// `Select_priv` → `SELECT` 等列名到权限名的折算,供外部(测试 /
  /// 权限页候选)复用同一套规则。
  static String privilegeNameOfColumn(String column) =>
      const MysqlUserMetadata(executor: _never, isMariaDb: false)
          ._privNameFromColumn(column);
}

Future<List<Map<String, String>>> _never(String sql) async => const [];
