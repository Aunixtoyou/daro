/// 新建数据库的选项。不同数据库类型使用不同字段:
///
/// - MySQL / MariaDB:[charset] + [collation](字符集 / 排序规则)
/// - PostgreSQL:[encoding] + [template] + [owner](编码 / 模板 / 拥有者)
/// - SQL Server:[collation](排序规则,可空 = 服务器默认)
/// - SQLite / Access(文件型):单文件即一个库,无独立建库概念,由菜单层禁用
class CreateDatabaseOptions {
  const CreateDatabaseOptions({
    required this.name,
    this.charset,
    this.collation,
    this.encoding,
    this.template,
    this.owner,
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

/// 按数据库类型生成 CREATE DATABASE 语句。
///
/// 标识符引用规则与 AppState._ident 保持一致:
/// PostgreSQL 双引号 / SQL Server 方括号 / MySQL·MariaDB 反引号。
/// 选项为空时不附加对应子句,使用服务器默认值。
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
      final buf = StringBuffer('CREATE DATABASE "${name.replaceAll('"', '""')}"');
      final encoding = o.encoding?.trim() ?? '';
      final template = o.template?.trim() ?? '';
      final owner = o.owner?.trim() ?? '';
      if (encoding.isNotEmpty) {
        buf.write(" ENCODING '${encoding.replaceAll("'", "''")}'");
      }
      if (template.isNotEmpty) buf.write(' TEMPLATE $template');
      if (owner.isNotEmpty) {
        buf.write(' OWNER "${owner.replaceAll('"', '""')}"');
      }
      return buf.toString();
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
