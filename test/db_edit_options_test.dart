import 'package:daro/data/database_edit_catalog.dart';
import 'package:daro/data/db_edit_options.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「编辑数据库」的差异语句生成与目录解析:纯函数层。
///
/// SQL 预览页与「确定」按钮共用 [buildEditDatabaseStatements],所以这里钉住的
/// 就是实际会打到服务端的语句。**只改动的字段才出语句**是本功能的核心约定:
/// 打开对话框直接点确定必须什么都不执行。
void main() {
  PgDatabaseProps current({
    String name = 'demo',
    String owner = 'postgres',
    String tablespace = 'pg_default',
    int connectionLimit = -1,
    bool allowConnections = true,
    bool isTemplate = false,
    String comment = '',
  }) =>
      PgDatabaseProps(
        name: name,
        owner: owner,
        tablespace: tablespace,
        connectionLimit: connectionLimit,
        allowConnections: allowConnections,
        isTemplate: isTemplate,
        comment: comment,
      );

  group('库级语句', () {
    test('表单与现状一致时不生成任何语句', () {
      final c = current();
      final sqls = buildDatabaseLevelEditStatements(
        typeId: 'postgresql',
        current: c,
        form: DatabaseEditForm(
          owner: c.owner,
          tablespace: c.tablespace,
          connectionLimit: c.connectionLimit,
          allowConnections: c.allowConnections,
          isTemplate: c.isTemplate,
          comment: c.comment,
        ),
      );
      expect(sqls, isEmpty);
    });

    test('只改所有者时其它子句不出现', () {
      final sqls = buildDatabaseLevelEditStatements(
        typeId: 'postgresql',
        current: current(),
        form: DatabaseEditForm(owner: 'app_owner'),
      );
      expect(sqls, ['ALTER DATABASE "demo" OWNER TO "app_owner"']);
    });

    test('所有者留空不生成 OWNER TO(避免打出 OWNER TO "")', () {
      final sqls = buildDatabaseLevelEditStatements(
        typeId: 'postgresql',
        current: current(),
        form: DatabaseEditForm(owner: '   '),
      );
      expect(sqls, isEmpty);
    });

    test('表空间相同则不生成 SET TABLESPACE(移动表空间代价极高)', () {
      final sqls = buildDatabaseLevelEditStatements(
        typeId: 'postgresql',
        current: current(tablespace: 'fast_ssd'),
        form: DatabaseEditForm(tablespace: 'fast_ssd'),
      );
      expect(sqls, isEmpty);
    });

    test('连接限制 / 允许连接 / 是否模板 各自独立成句', () {
      final sqls = buildDatabaseLevelEditStatements(
        typeId: 'postgresql',
        current: current(),
        form: const DatabaseEditForm(
          connectionLimit: 100,
          allowConnections: false,
          isTemplate: true,
        ),
      );
      expect(sqls, [
        'ALTER DATABASE "demo" WITH CONNECTION LIMIT 100',
        'ALTER DATABASE "demo" WITH ALLOW_CONNECTIONS false',
        'ALTER DATABASE "demo" WITH IS_TEMPLATE true',
      ]);
    });

    test('注释改动走 COMMENT ON DATABASE,清空写成 IS NULL', () {
      expect(
        buildDatabaseLevelEditStatements(
          typeId: 'postgresql',
          current: current(comment: '旧注释'),
          form: const DatabaseEditForm(comment: "订单'库"),
        ),
        ["COMMENT ON DATABASE \"demo\" IS '订单''库'"],
      );
      expect(
        buildDatabaseLevelEditStatements(
          typeId: 'postgresql',
          current: current(comment: '旧注释'),
          form: const DatabaseEditForm(comment: '   '),
        ),
        ['COMMENT ON DATABASE "demo" IS NULL'],
      );
    });

    test('库名 / 角色名里的双引号按标识符规则转义', () {
      final sqls = buildDatabaseLevelEditStatements(
        typeId: 'postgresql',
        current: current(name: 'we"ird'),
        form: DatabaseEditForm(owner: 'r"ole'),
      );
      expect(sqls, ['ALTER DATABASE "we""ird" OWNER TO "r""ole"']);
    });
  });

  group('扩展语句', () {
    test('卸载排在安装前,让先撤后装能一次跑通', () {
      final sqls = buildExtensionEditStatements(
        'postgresql',
        const DatabaseEditForm(
          installExtensions: ['pg_trgm'],
          uninstallExtensions: ['hstore'],
        ),
      );
      expect(sqls, [
        'DROP EXTENSION IF EXISTS "hstore"',
        'CREATE EXTENSION IF NOT EXISTS "pg_trgm"',
      ]);
    });

    test('空白扩展名跳过', () {
      expect(
        buildExtensionEditStatements(
          'postgresql',
          const DatabaseEditForm(installExtensions: ['', '  ']),
        ),
        isEmpty,
      );
    });
  });

  group('聚合与预览', () {
    test('扩展改动也算改动:仅移扩展时库级语句为空但整体非空', () {
      final c = current();
      final form = const DatabaseEditForm(installExtensions: ['citext']);
      expect(buildDatabaseLevelEditStatements(
          typeId: 'postgresql', current: c, form: form), isEmpty);
      expect(
        buildEditDatabaseStatements(typeId: 'postgresql', current: c, form: form),
        ['CREATE EXTENSION IF NOT EXISTS "citext"'],
      );
    });

    test('预览脚本每行一条带分号,无改动时给出说明', () {
      final form = const DatabaseEditForm(installExtensions: ['citext']);
      expect(
        buildEditDatabaseScript(
            typeId: 'postgresql', current: current(), form: form),
        'CREATE EXTENSION IF NOT EXISTS "citext";',
      );
      expect(
        buildEditDatabaseScript(
            typeId: 'postgresql', current: current(), form: const DatabaseEditForm()),
        '-- 没有需要执行的改动',
      );
    });
  });

  group('目录查询与解析', () {
    test('PG 18 起编码列改名 encoding,其余列保持 dat 前缀', () {
      final modern = pgDatabasePropsSql("o'b", pg18Plus: true);
      final legacy = pgDatabasePropsSql('demo', pg18Plus: false);
      expect(modern, contains('d.encoding'));
      expect(modern, isNot(contains('datencoding')));
      expect(legacy, contains('d.datencoding'));
      // 两版都仍依赖的列
      for (final sql in [modern, legacy]) {
        expect(sql, allOf(contains('d.datconnlimit'), contains('d.datdba'),
            contains('d.dattablespace')));
      }
      // 库名里的单引号必须转义,否则查询被截断
      expect(modern, contains("WHERE d.datname = 'o''b'"));
    });

    test('属性行:九列齐才认,少列返回 null 让对话框禁用保存', () {
      final full = [
        ['postgres', 'pg_default', '-1', '1', '0', '注释', 'UTF8', 'C', 'C']
      ];
      final props = parseDatabasePropsRow(full, 'demo')!;
      expect(props.name, 'demo');
      expect(props.owner, 'postgres');
      expect(props.tablespace, 'pg_default');
      expect(props.connectionLimit, -1);
      expect(props.allowConnections, isTrue);
      expect(props.isTemplate, isFalse);
      expect(props.comment, '注释');
      expect(props.encoding, 'UTF8');
      expect(parseDatabasePropsRow([], 'demo'), isNull);
      expect(
        parseDatabasePropsRow([
          ['postgres', 'pg_default', '-1']
        ], 'demo'),
        isNull,
      );
    });

    test('属性行:连接限制非数字按无限制处理,布尔只认 1', () {
      final props = parseDatabasePropsRow([
        ['postgres', 'pg_default', 'NULL', '0', '1', '', '', '', '']
      ], 'demo')!;
      expect(props.connectionLimit, -1);
      expect(props.allowConnections, isFalse);
      expect(props.isTemplate, isTrue);
      expect(props.lcCollate, isEmpty);
    });

    test('版本探测:空结果与非数字都返回 null', () {
      expect(parseServerVersion([
        ['180003']
      ]), 180003);
      expect(parseServerVersion([]), isNull);
      expect(parseServerVersion([
        ['']
      ]), isNull);
    });

    test('扩展行:三列 name/version/comment,缺列按空处理不丢行', () {
      final list = parseExtensionVersionRows([
        ['pg_trgm', '1.6', '三元组模糊匹配'],
        ['no_comment', '1.0'],
        ['nulls', 'NULL', 'NULL'],
        const [],
        ['', '1.0', 'x'],
      ]);
      expect(list.map((e) => e.name), ['pg_trgm', 'no_comment', 'nulls']);
      expect(list.first.version, '1.6');
      expect(list.first.comment, '三元组模糊匹配');
      expect(list[1].comment, '');
      expect(list[2].version, '');
      expect(list[2].comment, '');
    });
  });
}
