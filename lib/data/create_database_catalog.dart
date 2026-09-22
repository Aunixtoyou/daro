/// 「新建数据库」对话框里下拉框的候选项来源(目前仅 PostgreSQL)。
///
/// Navicat 风格的新建库窗口把「所有者 / 模板 / 表空间」做成下拉选择,值来自
/// 服务端系统表。这里集中放查询 SQL、解析函数与**离线兜底常量**:
/// 连接不可用 / 权限不足 / 查询失败时用兜底值填充,保证对话框始终可用。
library;

import 'db_create_options.dart';

/// PostgreSQL 扩展(name + 用途说明)
class PgExtensionInfo {
  const PgExtensionInfo(this.name, [this.comment = '']);

  /// 扩展名,直接用于 `CREATE EXTENSION "<name>"`
  final String name;

  /// 用途说明(列表右侧展示)
  final String comment;
}

/// 新建库对话框的下拉候选集合
class DatabaseCreateCatalog {
  const DatabaseCreateCatalog({
    required this.owners,
    required this.templates,
    required this.tablespaces,
    required this.extensions,
    this.loadedFromServer = false,
  });

  /// 所有者候选(pg_roles 中可登录的角色;兜底 = 当前连接用户名)
  final List<String> owners;

  /// 模板候选(pg_database 中 datistemplate = true 的库)
  final List<String> templates;

  /// 表空间候选(pg_tablespace)
  final List<String> tablespaces;

  /// 可用扩展(pg_available_extensions)
  final List<PgExtensionInfo> extensions;

  /// 是否成功从服务端加载(失败时为兜底值,UI 据此提示)
  final bool loadedFromServer;

  /// 离线兜底:值全部来自内置常量,所有者取当前连接用户名。
  factory DatabaseCreateCatalog.fallback({String? username}) {
    final owners = <String>{
      if (username != null && username.trim().isNotEmpty) username.trim(),
      'postgres',
    }.toList()
      ..sort();
    return DatabaseCreateCatalog(
      owners: owners,
      templates: kPgTemplates,
      tablespaces: kPgTablespaceFallback,
      extensions: kPgCommonExtensions,
    );
  }
}

/// 所有者:可登录角色(含超级用户;pg_user 视图也可,但 pg_roles 更全)
const kPgOwnerCatalogSql =
    'SELECT rolname FROM pg_roles WHERE rolcanlogin ORDER BY rolname';

/// 模板:标记为模板的库(template0 / template1 及其它自定义模板)
const kPgTemplateCatalogSql =
    'SELECT datname FROM pg_database WHERE datistemplate ORDER BY datname';

/// 表空间
const kPgTablespaceCatalogSql =
    'SELECT spcname FROM pg_tablespace ORDER BY spcname';

/// 可用扩展(pg_available_extensions 视图:name / default_version / comment)
const kPgExtensionCatalogSql =
    "SELECT name, COALESCE(comment, '') FROM pg_available_extensions ORDER BY name";

/// 表空间兜底值(PG 自带两个表空间恒存在)
const kPgTablespaceFallback = <String>['pg_default', 'pg_global'];

/// 常用扩展兜底列表(离线 / 权限不足时展示;按名称排序)
const kPgCommonExtensions = <PgExtensionInfo>[
  PgExtensionInfo('btree_gin', 'GIN 索引的 B-tree 操作符类'),
  PgExtensionInfo('btree_gist', 'GiST 索引的 B-tree 操作符类'),
  PgExtensionInfo('citext', '大小写不敏感的字符串类型'),
  PgExtensionInfo('cube', '多维立方体类型'),
  PgExtensionInfo('dblink', '跨库连接查询'),
  PgExtensionInfo('earthdistance', '地球表面距离计算'),
  PgExtensionInfo('hstore', '键值对存储类型'),
  PgExtensionInfo('intarray', '整型数组操作函数'),
  PgExtensionInfo('isn', '国际标准编号类型(ISBN/EAN/UPC)'),
  PgExtensionInfo('ltree', '树形标签路径类型'),
  PgExtensionInfo('pg_stat_statements', 'SQL 语句执行统计'),
  PgExtensionInfo('pg_trgm', '三元组模糊匹配与相似度'),
  PgExtensionInfo('pgcrypto', '加密与摘要函数'),
  PgExtensionInfo('plpgsql', 'PL/pgSQL 过程语言(默认已安装)'),
  PgExtensionInfo('postgres_fdw', '访问外部 PostgreSQL 数据源'),
  PgExtensionInfo('tablefunc', '交叉表与层次查询函数'),
  PgExtensionInfo('unaccent', '去除重音符号的文本搜索词典'),
  PgExtensionInfo('uuid-ossp', 'UUID 生成函数'),
  PgExtensionInfo('xml2', 'XPath / XSLT 相关函数'),
];

/// 取查询结果的第一列(PG 元数据查询都是单列名列表)
List<String> firstColumnOf(List<List<String>> rows) {
  final out = <String>[];
  for (final row in rows) {
    if (row.isEmpty) continue;
    final v = row.first.trim();
    if (v.isNotEmpty && v != 'NULL') out.add(v);
  }
  return out;
}

/// 解析扩展查询结果(两列:name / comment)
List<PgExtensionInfo> parseExtensionRows(List<List<String>> rows) {
  final out = <PgExtensionInfo>[];
  for (final row in rows) {
    if (row.isEmpty) continue;
    final name = row.first.trim();
    if (name.isEmpty || name == 'NULL') continue;
    final comment = row.length > 1 ? row[1].trim() : '';
    out.add(PgExtensionInfo(
      name,
      comment == 'NULL' ? '' : comment,
    ));
  }
  return out;
}
