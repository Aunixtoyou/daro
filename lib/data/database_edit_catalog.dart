/// 「编辑数据库」对话框的数据来源:读取某个 PostgreSQL 库的当前属性、注释,
/// 以及该库的可用 / 已安装扩展清单。
///
/// 与 [create_database_catalog.dart](建库前的候选下拉)对称:这里读的是**已存在
/// 库的现状**,用于回填表单并做「改动前后差异 → DDL」的比较基准。
///
/// 两类查询的落点不同,决定了调用方怎么执行:
/// - `pg_database` / `pg_roles` / `pg_tablespace` 是**集群级共享目录**,在任意库
///   的会话里都能查全,不必切换运行上下文;
/// - `pg_available_extensions` / `pg_extension` 是**每库一张视图**(扩展装在
///   具体库里),必须在目标库上下文中查询。
library;

import 'create_database_catalog.dart';
import 'table_design.dart';

/// 一个库的当前属性(可改的进表单,不可改的只做展示)
class PgDatabaseProps {
  const PgDatabaseProps({
    required this.name,
    this.owner = '',
    this.tablespace = '',
    this.connectionLimit = -1,
    this.allowConnections = true,
    this.isTemplate = false,
    this.comment = '',
    this.encoding = '',
    this.lcCollate = '',
    this.lcCtype = '',
  });

  /// 库名:建库后不可改(本对话框不提供 RENAME),只读展示
  final String name;

  /// 所有者角色名(`pg_database.datdba` 对应的 rolname)
  final String owner;

  /// 表空间名(`dattablespace`)
  final String tablespace;

  /// 连接上限,`-1` = 无限制(`datconnlimit`)
  final int connectionLimit;

  /// 是否允许连接(`datallowconn`)
  final bool allowConnections;

  /// 是否模板库(`datistemplate`)
  final bool isTemplate;

  /// 库注释(`shobj_description(oid, 'pg_database')`),无注释为空串
  final String comment;

  // ── 以下三项建库后不可修改,仅展示 ──────────────────────────────────────

  /// 编码(`pg_encoding_to_char(datencoding)`)
  final String encoding;

  /// 排序规则 `LC_COLLATE`(ICU 库上可能为空)
  final String lcCollate;

  /// 字符分类 `LC_CTYPE`
  final String lcCtype;

  /// 读取失败时的占位值:表单退回连接用户名,不阻塞对话框打开
  static PgDatabaseProps unknown(String name, {String owner = ''}) =>
      PgDatabaseProps(name: name, owner: owner);
}

/// 编辑库对话框的一次完整读取结果
class DatabaseEditSnapshot {
  const DatabaseEditSnapshot({
    required this.props,
    required this.owners,
    required this.tablespaces,
    required this.availableExtensions,
    required this.installedExtensions,
    this.loadedFromServer = false,
    this.extensionsLoaded = false,
  });

  /// 库的当前属性(表单初始值 + 差异比较基准)
  final PgDatabaseProps props;

  /// 所有者候选(`pg_roles` 中可登录角色)
  final List<String> owners;

  /// 表空间候选(`pg_tablespace`)
  final List<String> tablespaces;

  /// **未安装**的可用扩展(名称 / 可装版本 / 说明),左侧「可用」列表
  final List<PgExtensionInfo> availableExtensions;

  /// 已安装扩展(名称 / 当前版本 / 说明),右侧「已安装」列表
  final List<PgExtensionInfo> installedExtensions;

  /// 库属性是否真从服务端读到(false = 表单值不可信,保存按钮应禁用)
  final bool loadedFromServer;

  /// 扩展清单是否读到(false = 扩展页显示空态提示而非空列表)
  final bool extensionsLoaded;
}

/// 服务端版本探测:PostgreSQL 18(180000)把 `pg_database.datencoding` 改名成了
/// `encoding`,库属性查询必须据此切换列名(实测本机 18.3,其余列不变)。
const kPgServerVersionSql =
    "SELECT current_setting('server_version_num')::int8";

/// 解析 [kPgServerVersionSql] 的结果;读不到返回 null(按旧版列名拼查询)。
int? parseServerVersion(List<List<String>> rows) {
  if (rows.isEmpty || rows.first.isEmpty) return null;
  return int.tryParse(rows.first.first.trim());
}

/// `pg_database.datencoding` → `encoding` 的改名起始版本。
const kPgEncodingColumnRenamedVersion = 180000;

/// 库属性 + 注释:`pg_database` 是共享目录,在任意库的会话里都能查到全集群。
///
/// 逐列 `COALESCE` 成文本,是为了让 [parseDatabasePropsRow] 只处理非空字符串
/// (驱动的取值链把 NULL 也当文本读)。`datcollate` / `datctype` 在 ICU 库上
/// 允许为 NULL,故必须兜底。
///
/// [pg18Plus] 只影响一个列名:实测 PG 18.3 的 `pg_attribute` 显示,这一代只把
/// `datencoding` 改名成 `encoding`,`datdba` / `dattablespace` / `datconnlimit` /
/// `datallowconn` / `datistemplate` / `datcollate` / `datctype` 全部保持原样。
String pgDatabasePropsSql(String database, {required bool pg18Plus}) {
  final encoding = pg18Plus ? 'encoding' : 'datencoding';
  return '''
SELECT COALESCE(r.rolname, ''),
       COALESCE(t.spcname, ''),
       d.datconnlimit::text,
       CASE WHEN d.datallowconn THEN '1' ELSE '0' END,
       CASE WHEN d.datistemplate THEN '1' ELSE '0' END,
       COALESCE(pg_catalog.shobj_description(d.oid, 'pg_database'), ''),
       COALESCE(pg_catalog.pg_encoding_to_char(d.$encoding), ''),
       COALESCE(d.datcollate, ''),
       COALESCE(d.datctype, '')
FROM pg_catalog.pg_database d
LEFT JOIN pg_catalog.pg_roles r ON r.oid = d.datdba
LEFT JOIN pg_catalog.pg_tablespace t ON t.oid = d.dattablespace
WHERE d.datname = ${DdlBuilder.lit(database)}''';
}

/// 未安装的可用扩展(「可用」列表:`installed_version` 为 NULL 即该库尚未装)
const kPgAvailableExtensionsSql =
    'SELECT name, default_version, COALESCE(comment, \'\') '
    'FROM pg_catalog.pg_available_extensions '
    'WHERE installed_version IS NULL ORDER BY name';

/// 已安装扩展(「已安装」列表:版本取 `pg_extension.extversion`,
/// 说明从 `pg_available_extensions` 左连过来 —— 已删包的扩展只有名字)
const kPgInstalledExtensionsSql =
    'SELECT e.extname, e.extversion, COALESCE(a.comment, \'\') '
    'FROM pg_catalog.pg_extension e '
    'LEFT JOIN pg_catalog.pg_available_extensions a ON a.name = e.extname '
    'ORDER BY e.extname';

/// 解析 [pgDatabasePropsSql] 的单行结果;列数不足(服务端版本差异)返回 null。
PgDatabaseProps? parseDatabasePropsRow(List<List<String>> rows, String name) {
  if (rows.isEmpty) return null;
  final r = rows.first;
  if (r.length < 9) return null;
  return PgDatabaseProps(
    name: name,
    owner: r[0],
    tablespace: r[1],
    connectionLimit: int.tryParse(r[2]) ?? -1,
    allowConnections: r[3] == '1',
    isTemplate: r[4] == '1',
    comment: r[5],
    encoding: r[6],
    lcCollate: r[7],
    lcCtype: r[8],
  );
}

/// 解析三列扩展查询结果:name / version / comment(见上面两条扩展 SQL)
List<PgExtensionInfo> parseExtensionVersionRows(List<List<String>> rows) {
  final out = <PgExtensionInfo>[];
  for (final row in rows) {
    if (row.isEmpty) continue;
    final name = row.first.trim();
    if (name.isEmpty || name == 'NULL') continue;
    String at(int i) =>
        row.length > i ? row[i].trim() : ''; // 缺列按空处理,不让整页列表消失
    final comment = at(2);
    out.add(PgExtensionInfo(
      name,
      comment == 'NULL' ? '' : comment,
      at(1) == 'NULL' ? '' : at(1),
    ));
  }
  return out;
}
