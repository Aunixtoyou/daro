/// 各数据库类型的连接默认值(端口、用户名)。
///
/// 找不到对应 id 时返回空串,UI 留空让用户手动填。
library;

/// 按数据库类型 id 给出"新建连接"时推荐的端口号。
String defaultPortFor(String dbId) {
  switch (dbId) {
    case 'mysql':
    case 'mariadb':
    case 'aliyun-rds-mysql':
    case 'aliyun-polardb-mysql':
    case 'aliyun-polardb-dist':
      return '3306';
    case 'postgresql':
    case 'aliyun-rds-postgres':
    case 'aliyun-polardb-postgres':
      return '5432';
    case 'sqlserver':
    case 'aliyun-rds-sqlserver':
      return '1433';
    case 'oracle':
    case 'aliyun-oceanbase-oracle':
      return '1521';
    case 'mongodb':
    case 'aliyun-mongodb':
      return '27017';
    case 'redis':
    case 'aliyun-redis':
      return '6379';
    case 'snowflake':
      return '443';
    case 'aliyun-oceanbase-mysql':
      return '2881';
    default:
      return '';
  }
}

/// 按数据库类型 id 给出"新建连接"时推荐的用户名。
/// SQLite / 阿里云系列(走 RAM 鉴权)没有默认用户名,留空让用户填。
String defaultUsernameFor(String dbId) {
  switch (dbId) {
    case 'mysql':
    case 'mariadb':
    case 'aliyun-rds-mysql':
    case 'aliyun-polardb-mysql':
    case 'aliyun-polardb-dist':
      return 'root';
    case 'postgresql':
    case 'aliyun-rds-postgres':
    case 'aliyun-polardb-postgres':
    case 'aliyun-oceanbase-postgres':
      return 'postgres';
    case 'sqlserver':
    case 'aliyun-rds-sqlserver':
      return 'sa';
    case 'oracle':
      return 'sys';
    case 'aliyun-oceanbase-mysql':
      return 'root';
    default:
      return '';
  }
}
