/// 新建数据库的选项。不同数据库类型使用不同字段:
///
/// - MySQL / MariaDB:[charset] + [collation](字符集 / 排序规则)
/// - PostgreSQL:[encoding] + [template] + [owner] + [lcCollate] + [lcCtype]
///   + [tablespace] + [connectionLimit] + [allowConnections] + [isTemplate],
///   建库后可选执行 [extensions] 与 [comment]
/// - SQL Server:[collation](排序规则,可空 = 服务器默认)
/// - SQLite / Access(文件型):单文件即一个库,无独立建库概念,由菜单层禁用
///
/// PostgreSQL 的字段与 `CREATE DATABASE` 的子句一一对应,见
/// [buildCreateDatabaseSql] / [buildCreateDatabasePostSql]。
class CreateDatabaseOptions {
  const CreateDatabaseOptions({
    required this.name,
    this.charset,
    this.collation,
    this.encoding,
    this.template,
    this.owner,
    this.lcCollate,
    this.lcCtype,
    this.tablespace,
    this.connectionLimit,
    this.allowConnections = true,
    this.isTemplate = false,
    this.extensions = const [],
    this.comment,
  });

  /// 数据库名称(必填)
  final String name;

  /// MySQL / MariaDB:字符集,如 utf8mb4
  final String? charset;

  /// MySQL / MariaDB:排序规则,如 utf8mb4_unicode_ci;
  /// SQL Server:排序规则,如 Chinese_PRC_CI_AS(空串 = 服务器默认,不附加 COLLATE)
  final String? collation;

  /// PostgreSQL:编码,如 UTF8 / GB18030
  final String? encoding;

  /// PostgreSQL:模板,template0 / template1
  final String? template;

  /// PostgreSQL:拥有者(可空 = 当前用户)
  final String? owner;

  /// PostgreSQL:排序规则(LC_COLLATE,可空 = 跟随模板)
  final String? lcCollate;

  /// PostgreSQL:字符分类(LC_CTYPE,可空 = 跟随模板)
  final String? lcCtype;

  /// PostgreSQL:表空间(可空 = pg_default)
  final String? tablespace;

  /// PostgreSQL:连接限制(-1 = 无限制;可空视为不输出该子句)
  final int? connectionLimit;

  /// PostgreSQL:是否允许连接(ALLOW_CONNECTIONS,默认 true)
  final bool allowConnections;

  /// PostgreSQL:是否作为模板(IS_TEMPLATE,默认 false)
  final bool isTemplate;

  /// PostgreSQL:建库后在**新库**中执行的 `CREATE EXTENSION`(仅扩展名)
  final List<String> extensions;

  /// PostgreSQL:数据库注释(COMMENT ON DATABASE,空 = 不输出)
  final String? comment;
}

/// MySQL / MariaDB 常用字符集(首项为默认值)
const kMysqlCharsets = <String>[
  'utf8mb4',
  'utf8',
  'gbk',
  'gb2312',
  'big5',
  'latin1',
  'ascii',
];

/// 字符集 → 常用排序规则(首项为默认值;未收录的字符集回退 utf8mb4 列表)
const _mysqlCollations = <String, List<String>>{
  'utf8mb4': [
    'utf8mb4_general_ci',
    'utf8mb4_unicode_ci',
    'utf8mb4_0900_ai_ci',
    'utf8mb4_bin',
  ],
  'utf8': ['utf8_general_ci', 'utf8_unicode_ci', 'utf8_bin'],
  'gbk': ['gbk_chinese_ci', 'gbk_bin'],
  'gb2312': ['gb2312_chinese_ci', 'gb2312_bin'],
  'big5': ['big5_chinese_ci', 'big5_bin'],
  'latin1': ['latin1_swedish_ci', 'latin1_general_ci', 'latin1_bin'],
  'ascii': ['ascii_general_ci', 'ascii_bin'],
};

/// 取某字符集下的常用排序规则(未收录时回退 utf8mb4 的列表)
List<String> mysqlCollationsFor(String charset) =>
    _mysqlCollations[charset] ?? _mysqlCollations['utf8mb4']!;

/// PostgreSQL 常用编码(首项为默认值)
const kPgEncodings = <String>[
  'UTF8',
  'GB18030',
  'GBK',
  'EUC_CN',
  'SQL_ASCII',
  'LATIN1',
  'LATIN2',
  'WIN1250',
  'WIN1251',
  'WIN1252',
  'EUC_JP',
  'EUC_KR',
  'BIG5',
];

/// PostgreSQL 建库模板:template1 为默认;非 UTF8 编码必须用 template0
const kPgTemplates = <String>['template0', 'template1'];

/// SQL Server 常用排序规则(首项空串 = 服务器默认,不附加 COLLATE)
const kSqlServerCollations = <String>[
  '',
  'Chinese_PRC_CI_AS',
  'Chinese_PRC_90_CI_AS',
  'Chinese_PRC_100_CI_AS',
  'Chinese_PRC_CS_AS',
  'SQL_Latin1_General_CP1_CI_AS',
  'Latin1_General_100_CI_AS',
];

/// PostgreSQL 连接限制的「无限制」值(与 `CONNECTION LIMIT` 默认值一致)
const int kPgConnectionLimitUnlimited = -1;

/// 单引号字符串字面量转义(PostgreSQL:'' 表示一个单引号)
String _quoteLiteral(String value) => "'${value.replaceAll("'", "''")}'";

/// 标识符转义并加双引号(PostgreSQL 风格)
String _quotePgIdent(String value) => '"${value.replaceAll('"', '""')}"';

/// 按数据库类型生成 CREATE DATABASE 语句。
///
/// 标识符引用规则与 AppState._ident 保持一致:
/// PostgreSQL 双引号 / SQL Server 方括号 / MySQL·MariaDB 反引号。
/// 选项为空(或等于服务端默认)时不附加对应子句,使用服务器默认值。
String buildCreateDatabaseSql(String typeId, CreateDatabaseOptions o) {
  final name = o.name.trim();
  switch (typeId) {
    case 'mysql':
    case 'mariadb':
      final buf = StringBuffer('CREATE DATABASE `${name.replaceAll('`', '``')}`');
      final charset = o.charset?.trim() ?? '';
      final collation = o.collation?.trim() ?? '';
      if (charset.isNotEmpty) buf.write(' CHARACTER SET $charset');
      if (collation.isNotEmpty) buf.write(' COLLATE $collation');
      return buf.toString();
    case 'postgresql':
      final clauses = <String>[];
      final owner = o.owner?.trim() ?? '';
      final template = o.template?.trim() ?? '';
      final encoding = o.encoding?.trim() ?? '';
      final lcCollate = o.lcCollate?.trim() ?? '';
      final lcCtype = o.lcCtype?.trim() ?? '';
      final tablespace = o.tablespace?.trim() ?? '';
      if (owner.isNotEmpty) clauses.add('OWNER = ${_quotePgIdent(owner)}');
      if (template.isNotEmpty) clauses.add('TEMPLATE = ${_quotePgIdent(template)}');
      if (encoding.isNotEmpty) {
        clauses.add('ENCODING = ${_quoteLiteral(encoding)}');
      }
      if (lcCollate.isNotEmpty) {
        clauses.add('LC_COLLATE = ${_quoteLiteral(lcCollate)}');
      }
      if (lcCtype.isNotEmpty) {
        clauses.add('LC_CTYPE = ${_quoteLiteral(lcCtype)}');
      }
      if (tablespace.isNotEmpty) {
        clauses.add('TABLESPACE = ${_quotePgIdent(tablespace)}');
      }
      // 与默认值相同的布尔项不输出(默认 ALLOW_CONNECTIONS = true / IS_TEMPLATE = false)
      if (!o.allowConnections) clauses.add('ALLOW_CONNECTIONS = false');
      final limit = o.connectionLimit;
      if (limit != null && limit != kPgConnectionLimitUnlimited) {
        clauses.add('CONNECTION LIMIT = $limit');
      }
      if (o.isTemplate) clauses.add('IS_TEMPLATE = true');

      final head = 'CREATE DATABASE ${_quotePgIdent(name)}';
      if (clauses.isEmpty) return head;
      // 多行排版:WITH 后每行一个子句,与 Navicat / pgAdmin 的预览风格一致
      return '$head\n       WITH ${clauses.join('\n            ')}';
    case 'sqlserver':
      final buf = StringBuffer('CREATE DATABASE [${name.replaceAll(']', ']]')}]');
      final collation = o.collation?.trim() ?? '';
      if (collation.isNotEmpty) buf.write(' COLLATE $collation');
      return buf.toString();
    default:
      // 文件型 / 未支持类型不会走到这里(菜单已禁用),兜底裸建
      return 'CREATE DATABASE $name';
  }
}

/// 建库**之后**要执行的语句(可为空列表)。
///
/// 这些语句必须在新库上下文中执行(见 `AppState.createDatabase`):
/// - 扩展:`CREATE EXTENSION IF NOT EXISTS "x"`(PostgreSQL 专有)
/// - 注释:`COMMENT ON DATABASE "x" IS '...'`(PostgreSQL 专有)
///
/// 其它数据库类型暂不支持扩展 / 库注释,恒返回空列表。
List<String> buildCreateDatabasePostSql(
  String typeId,
  CreateDatabaseOptions o,
) {
  if (typeId != 'postgresql') return const [];
  final name = o.name.trim();
  if (name.isEmpty) return const [];
  final ident = _quotePgIdent(name);

  final sqls = <String>[];
  for (final ext in o.extensions) {
    final e = ext.trim();
    if (e.isEmpty) continue;
    sqls.add('CREATE EXTENSION IF NOT EXISTS ${_quotePgIdent(e)}');
  }
  final comment = o.comment?.trim() ?? '';
  if (comment.isNotEmpty) {
    sqls.add('COMMENT ON DATABASE $ident IS ${_quoteLiteral(comment)}');
  }
  return sqls;
}

/// SQL 预览用的完整脚本(建库语句 + 建库后语句,分号结尾)。
String buildCreateDatabaseScript(String typeId, CreateDatabaseOptions o) {
  final parts = <String>[buildCreateDatabaseSql(typeId, o)];
  parts.addAll(buildCreateDatabasePostSql(typeId, o));
  return parts.map((s) => '$s;').join('\n\n');
}
