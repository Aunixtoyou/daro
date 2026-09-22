import 'package:flutter_test/flutter_test.dart';

import 'package:daro/data/create_database_catalog.dart';
import 'package:daro/data/db_create_options.dart';

void main() {
  group('buildCreateDatabaseSql - PostgreSQL', () {
    test('只有库名时输出单行语句,不附加任何子句', () {
      final sql = buildCreateDatabaseSql(
        'postgresql',
        const CreateDatabaseOptions(name: 'demo'),
      );
      expect(sql, 'CREATE DATABASE "demo"');
    });

    test('名称中的双引号被转义', () {
      final sql = buildCreateDatabaseSql(
        'postgresql',
        const CreateDatabaseOptions(name: 'we"ird'),
      );
      expect(sql, 'CREATE DATABASE "we""ird"');
    });

    test('输出全部已指定的子句', () {
      final sql = buildCreateDatabaseSql(
        'postgresql',
        const CreateDatabaseOptions(
          name: 'demo',
          owner: 'postgres',
          template: 'template0',
          encoding: 'UTF8',
          lcCollate: 'en_US.utf8',
          lcCtype: 'en_US.utf8',
          tablespace: 'pg_default',
          connectionLimit: 10,
        ),
      );
      expect(sql, contains('CREATE DATABASE "demo"'));
      expect(sql, contains('WITH OWNER = "postgres"'));
      expect(sql, contains('TEMPLATE = "template0"'));
      expect(sql, contains("ENCODING = 'UTF8'"));
      expect(sql, contains("LC_COLLATE = 'en_US.utf8'"));
      expect(sql, contains("LC_CTYPE = 'en_US.utf8'"));
      expect(sql, contains('TABLESPACE = "pg_default"'));
      expect(sql, contains('CONNECTION LIMIT = 10'));
      // 默认值不输出
      expect(sql.contains('ALLOW_CONNECTIONS'), isFalse);
      expect(sql.contains('IS_TEMPLATE'), isFalse);
    });

    test('布尔项与默认值不同时才输出', () {
      final sql = buildCreateDatabaseSql(
        'postgresql',
        const CreateDatabaseOptions(
          name: 'demo',
          allowConnections: false,
          isTemplate: true,
          connectionLimit: kPgConnectionLimitUnlimited,
        ),
      );
      expect(sql, contains('ALLOW_CONNECTIONS = false'));
      expect(sql, contains('IS_TEMPLATE = true'));
      // -1 = 无限制,与服务端默认一致,不输出
      expect(sql.contains('CONNECTION LIMIT'), isFalse);
    });

    test('注释与扩展不进建库语句(由 post 语句负责)', () {
      final sql = buildCreateDatabaseSql(
        'postgresql',
        const CreateDatabaseOptions(
          name: 'demo',
          extensions: ['uuid-ossp'],
          comment: '测试库',
        ),
      );
      expect(sql.contains('CREATE EXTENSION'), isFalse);
      expect(sql.contains('COMMENT ON'), isFalse);
    });
  });

  group('buildCreateDatabasePostSql', () {
    test('PostgreSQL 生成扩展与注释语句', () {
      final sqls = buildCreateDatabasePostSql(
        'postgresql',
        const CreateDatabaseOptions(
          name: 'demo',
          extensions: ['uuid-ossp', 'pg_trgm'],
          comment: "it's a demo",
        ),
      );
      expect(sqls, [
        'CREATE EXTENSION IF NOT EXISTS "uuid-ossp"',
        'CREATE EXTENSION IF NOT EXISTS "pg_trgm"',
        'COMMENT ON DATABASE "demo" IS \'it\'\'s a demo\'',
      ]);
    });

    test('无扩展无注释时为空列表', () {
      final sqls = buildCreateDatabasePostSql(
        'postgresql',
        const CreateDatabaseOptions(name: 'demo'),
      );
      expect(sqls, isEmpty);
    });

    test('其它数据库类型恒为空(不支持扩展 / 库注释)', () {
      for (final type in ['mysql', 'mariadb', 'sqlserver', 'sqlite']) {
        expect(
          buildCreateDatabasePostSql(
            type,
            const CreateDatabaseOptions(
              name: 'demo',
              extensions: ['whatever'],
              comment: 'x',
            ),
          ),
          isEmpty,
          reason: type,
        );
      }
    });
  });

  group('其它数据库类型(SQL 生成保持原状)', () {
    test('MySQL 带字符集与排序规则', () {
      final sql = buildCreateDatabaseSql(
        'mysql',
        const CreateDatabaseOptions(
          name: 'demo',
          charset: 'utf8mb4',
          collation: 'utf8mb4_general_ci',
        ),
      );
      expect(sql, 'CREATE DATABASE `demo` CHARACTER SET utf8mb4 '
          'COLLATE utf8mb4_general_ci');
    });

    test('SQL Server 只输出排序规则;空串表示服务器默认', () {
      expect(
        buildCreateDatabaseSql(
          'sqlserver',
          const CreateDatabaseOptions(name: 'demo', collation: 'Chinese_PRC_CI_AS'),
        ),
        'CREATE DATABASE [demo] COLLATE Chinese_PRC_CI_AS',
      );
      expect(
        buildCreateDatabaseSql(
          'sqlserver',
          const CreateDatabaseOptions(name: 'demo', collation: ''),
        ),
        'CREATE DATABASE [demo]',
      );
    });

    test('MySQL 忽略 PostgreSQL 专有字段', () {
      final sql = buildCreateDatabaseSql(
        'mysql',
        const CreateDatabaseOptions(
          name: 'demo',
          tablespace: 'pg_default',
          isTemplate: true,
        ),
      );
      expect(sql, 'CREATE DATABASE `demo`');
    });
  });

  test('buildCreateDatabaseScript 拼接建库与建库后语句', () {
    final script = buildCreateDatabaseScript(
      'postgresql',
      const CreateDatabaseOptions(
        name: 'demo',
        extensions: ['uuid-ossp'],
        comment: 'hi',
      ),
    );
    final lines = script.split('\n\n');
    expect(lines.length, 3);
    expect(lines.every((l) => l.endsWith(';')), isTrue);
  });

  group('候选列表解析', () {
    test('firstColumnOf 过滤空值与 NULL', () {
      expect(
        firstColumnOf([
          ['postgres'],
          [''],
          ['NULL'],
          ['app_user'],
        ]),
        ['postgres', 'app_user'],
      );
    });

    test('parseExtensionRows 取 name + comment', () {
      final list = parseExtensionRows([
        ['plpgsql', 'PL/pgSQL procedural language'],
        ['uuid-ossp', ''],
        ['', 'ignored'],
      ]);
      expect(list.length, 2);
      expect(list.first.name, 'plpgsql');
      expect(list.first.comment, 'PL/pgSQL procedural language');
      expect(list.last.comment, '');
    });

    test('兜底目录永远含 postgres 与两个模板', () {
      final c = DatabaseCreateCatalog.fallback(username: 'app');
      expect(c.owners, containsAll(['app', 'postgres']));
      expect(c.templates, kPgTemplates);
      expect(c.tablespaces, kPgTablespaceFallback);
      expect(c.loadedFromServer, isFalse);
    });
  });
}
