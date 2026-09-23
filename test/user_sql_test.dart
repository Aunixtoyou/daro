import 'package:flutter_test/flutter_test.dart';

import 'package:daro/data/user_sql.dart';

void main() {
  group('UserAccount', () {
    test('parse 按最后一个 @ 切分', () {
      expect(UserAccount.parse('root@localhost').name, 'root');
      expect(UserAccount.parse('root@localhost').host, 'localhost');
      // 用户名含 @ 时仍能正确拆出 host
      expect(UserAccount.parse('a@b@10.0.0.1').name, 'a@b');
      expect(UserAccount.parse('a@b@10.0.0.1').host, '10.0.0.1');
      // 无 host
      expect(UserAccount.parse('postgres').name, 'postgres');
      expect(UserAccount.parse('postgres').host, '');
      expect(UserAccount.parse('postgres').displayName, 'postgres');
    });

    test('displayName 往返一致', () {
      for (final raw in ['root@localhost', 'root@%', 'postgres']) {
        expect(UserAccount.parse(raw).displayName, raw);
      }
    });
  });

  group('能力矩阵', () {
    test('支持用户的类型', () {
      for (final t in ['mysql', 'mariadb', 'postgresql', 'sqlserver']) {
        expect(UserSql.supportsUsers(t), isTrue, reason: t);
      }
      for (final t in ['sqlite', 'access']) {
        expect(UserSql.supportsUsers(t), isFalse, reason: t);
      }
    });

    test('只有 MySQL 系有 host 概念', () {
      expect(UserSql.hasHost('mysql'), isTrue);
      expect(UserSql.hasHost('mariadb'), isTrue);
      expect(UserSql.hasHost('postgresql'), isFalse);
      expect(UserSql.hasHost('sqlserver'), isFalse);
    });

    test('只有 MySQL 系有权限矩阵与插件', () {
      expect(UserSql.supportsPrivileges('mysql'), isTrue);
      expect(UserSql.supportsPrivileges('postgresql'), isFalse);
      expect(AuthPluginCatalog.of('mysql'), isNotEmpty);
      expect(AuthPluginCatalog.of('mariadb'), isNotEmpty);
      expect(AuthPluginCatalog.of('postgresql'), isEmpty);
    });
  });

  group('MySQL 新建', () {
    test('用户名 + 主机 + 密码', () {
      final spec = UserSpec(
        username: 'app',
        host: 'localhost',
        password: 'p@ss',
      );
      expect(
        UserSql.buildCreate('mysql', spec),
        ["CREATE USER 'app'@'localhost' IDENTIFIED BY 'p@ss'"],
      );
    });

    test('host 为空时退化为 % 通配', () {
      final spec = UserSpec(username: 'app', password: 'x');
      expect(
        UserSql.buildCreate('mysql', spec),
        ["CREATE USER 'app'@'%' IDENTIFIED BY 'x'"],
      );
    });

    test('指定插件', () {
      final spec = UserSpec(
        username: 'app',
        host: '%',
        plugin: 'caching_sha2_password',
        password: 'x',
      );
      expect(
        UserSql.buildCreate('mysql', spec),
        ["CREATE USER 'app'@'%' IDENTIFIED WITH `caching_sha2_password` BY 'x'"],
      );
    });

    test('密码过期策略', () {
      expect(
        UserSql.buildCreate(
          'mysql',
          UserSpec(
            username: 'a',
            host: '%',
            password: 'x',
            expirePolicy: PasswordExpirePolicy.never,
          ),
        ),
        ["CREATE USER 'a'@'%' IDENTIFIED BY 'x' PASSWORD EXPIRE NEVER"],
      );
      expect(
        UserSql.buildCreate(
          'mysql',
          UserSpec(
            username: 'a',
            host: '%',
            password: 'x',
            expirePolicy: PasswordExpirePolicy.interval,
            expireDays: 30,
          ),
        ),
        [
          "CREATE USER 'a'@'%' IDENTIFIED BY 'x' "
              'PASSWORD EXPIRE INTERVAL 30 DAY',
        ],
      );
      // DEFAULT = 不改动该属性,语句里不出现子句
      expect(
        UserSql.buildCreate(
          'mysql',
          UserSpec(username: 'a', host: '%', password: 'x'),
        ).single,
        isNot(contains('PASSWORD EXPIRE')),
      );
    });

    test('创建角色不带密码 / 过期子句', () {
      final spec = UserSpec(
        username: 'readonly',
        host: '%',
        isRole: true,
        password: 'ignored',
      );
      expect(
        UserSql.buildCreate('mysql', spec),
        ["CREATE ROLE 'readonly'@'%'"],
      );
    });

    test('密码里的单引号被转义', () {
      final spec = UserSpec(username: 'a', host: '%', password: "it's");
      expect(UserSql.buildCreate('mysql', spec).single,
          contains("'it''s'"));
    });
  });

  group('MySQL 编辑', () {
    test('改名生成 RENAME USER', () {
      final spec = UserSpec(
        originalName: 'old',
        originalHost: '%',
        username: 'new',
        host: '%',
      );
      final stmts = UserSql.buildAlter('mysql', spec);
      expect(stmts, isNotEmpty);
      expect(stmts.first, "RENAME USER 'old'@'%' TO 'new'@'%'");
    });

    test('密码为空时不改密码', () {
      final spec = UserSpec(
        originalName: 'a',
        originalHost: '%',
        username: 'a',
        host: '%',
      );
      expect(UserSql.buildAlter('mysql', spec), isEmpty);
    });

    test('改密码生成 ALTER USER', () {
      final spec = UserSpec(
        originalName: 'a',
        originalHost: '%',
        username: 'a',
        host: '%',
        password: 'newpw',
      );
      expect(
        UserSql.buildAlter('mysql', spec),
        ["ALTER USER 'a'@'%' IDENTIFIED BY 'newpw'"],
      );
    });

    test('改名 + 改密码两条语句', () {
      final spec = UserSpec(
        originalName: 'a',
        originalHost: '%',
        username: 'b',
        host: '%',
        password: 'pw',
      );
      final stmts = UserSql.buildAlter('mysql', spec);
      expect(stmts.length, 2);
      expect(stmts[0], contains('RENAME USER'));
      expect(stmts[1], contains('ALTER USER'));
    });
  });

  group('PostgreSQL', () {
    test('新建角色带属性', () {
      final spec = UserSpec(
        username: 'app',
        password: 'pw',
        pg: PgRoleAttributes(superUser: true, createDb: true, inherit: true),
      );
      final sql = UserSql.buildCreate('postgresql', spec).single;
      expect(sql, startsWith('CREATE ROLE "app" WITH '));
      expect(sql, contains('LOGIN'));
      expect(sql, contains('SUPERUSER'));
      expect(sql, contains('CREATEDB'));
      expect(sql, contains('INHERIT'));
      expect(sql, contains("PASSWORD 'pw'"));
      expect(sql, contains('CONNECTION LIMIT -1'));
    });

    test('NOLOGIN 角色(纯组)', () {
      final spec = UserSpec(
        username: 'grp',
        isRole: true,
        pg: PgRoleAttributes(canLogin: false),
      );
      expect(UserSql.buildCreate('postgresql', spec).single,
          contains('NOLOGIN'));
    });

    test('过期策略转为 VALID UNTIL 表达式', () {
      final spec = UserSpec(
        username: 'a',
        password: 'p',
        expirePolicy: PasswordExpirePolicy.never,
      );
      expect(UserSql.buildCreate('postgresql', spec).single,
          contains('VALID UNTIL infinity'));

      final spec2 = UserSpec(
        username: 'a',
        password: 'p',
        expirePolicy: PasswordExpirePolicy.interval,
        expireDays: 60,
      );
      expect(UserSql.buildCreate('postgresql', spec2).single,
          contains("VALID UNTIL NOW() + INTERVAL '60 days'"));
    });

    test('编辑生成 ALTER ROLE(改名 / 属性 / 密码)', () {
      final spec = UserSpec(
        originalName: 'old',
        username: 'new',
        password: 'pw',
        pg: PgRoleAttributes(canLogin: true, createDb: true),
      );
      final stmts = UserSql.buildAlter('postgresql', spec);
      expect(stmts[0], 'ALTER ROLE "old" RENAME TO "new"');
      expect(stmts.any((s) => s.contains('CREATEDB')), isTrue);
      expect(stmts.any((s) => s.contains("PASSWORD 'pw'")), isTrue);
    });

    test('注释生成 COMMENT ON ROLE', () {
      final spec = UserSpec(
        originalName: 'a',
        username: 'a',
        comment: '应用账号',
      );
      expect(
        UserSql.buildAlter('postgresql', spec),
        contains('COMMENT ON ROLE "a" IS \'应用账号\''),
      );
    });

    test('删除用 DROP ROLE', () {
      expect(
        UserSql.buildDrop('postgresql', const UserAccount(name: 'a')),
        ['DROP ROLE IF EXISTS "a"'],
      );
    });
  });

  group('SQL Server', () {
    test('SQL 登录名建的语句含 CREATE LOGIN + CREATE USER', () {
      final spec = UserSpec(username: 'app', password: 'pw');
      final sql = UserSql.buildCreate('sqlserver', spec).single;
      expect(sql, contains('CREATE LOGIN [app] WITH PASSWORD'));
      expect(sql, contains('CREATE USER [app] FOR LOGIN [app]'));
    });

    test('无密码 = WITHOUT LOGIN', () {
      expect(
        UserSql.buildCreate('sqlserver', UserSpec(username: 'app')).single,
        'CREATE USER [app] WITHOUT LOGIN',
      );
    });

    test('Windows 用户 / 组 / 数据库角色', () {
      expect(
        UserSql.buildCreate(
          'sqlserver',
          UserSpec(
            username: 'DOM\\u',
            sqlPrincipalType: SqlPrincipalType.windowsUser,
          ),
        ).single,
        r'CREATE USER [DOM\u] FOR LOGIN [DOM\u]',
      );
      expect(
        UserSql.buildCreate(
          'sqlserver',
          UserSpec(
            username: 'DOM\\g',
            sqlPrincipalType: SqlPrincipalType.windowsGroup,
          ),
        ).single,
        r'CREATE USER [DOM\g] FROM GROUP [DOM\g]',
      );
      expect(
        UserSql.buildCreate(
          'sqlserver',
          UserSpec(
            username: 'role1',
            isRole: true,
            sqlPrincipalType: SqlPrincipalType.databaseRole,
          ),
        ).single,
        'CREATE ROLE [role1]',
      );
    });

    test('成员关系用 ALTER ROLE ADD/DROP MEMBER', () {
      expect(
        UserSql.buildMembershipAdd(
          'sqlserver',
          const UserAccount(name: 'app'),
          {'r1'},
        ),
        ['ALTER ROLE [r1] ADD MEMBER [app]'],
      );
      expect(
        UserSql.buildMembershipRemove(
          'sqlserver',
          const UserAccount(name: 'app'),
          {'r1'},
        ),
        ['ALTER ROLE [r1] DROP MEMBER [app]'],
      );
    });
  });

  group('权限 GRANT / 成员关系', () {
    test('库级权限', () {
      final entries = [
        UserPrivilegeEntry(
          database: 'shop',
          privileges: {'SELECT', 'INSERT'},
        ),
      ];
      expect(
        UserSql.buildGrants('mysql', const UserAccount(name: 'a', host: '%'), entries),
        ['GRANT INSERT, SELECT ON `shop`.* TO \'a\'@\'%\''],
      );
    });

    test('表级 + WITH GRANT OPTION', () {
      final entries = [
        UserPrivilegeEntry(
          database: 'shop',
          table: 'orders',
          privileges: {'SELECT'},
          grantOption: true,
        ),
      ];
      expect(
        UserSql.buildGrants('mysql', const UserAccount(name: 'a', host: '%'), entries),
        ['GRANT SELECT ON `shop`.`orders` TO \'a\'@\'%\' WITH GRANT OPTION'],
      );
    });

    test('服务器级 = *.*', () {
      final entries = [
        UserPrivilegeEntry(privileges: {'PROCESS'}),
      ];
      expect(
        UserSql.buildGrants('mysql', const UserAccount(name: 'a', host: '%'), entries),
        ['GRANT PROCESS ON *.* TO \'a\'@\'%\''],
      );
    });

    test('含 ALL PRIVILEGES 时不再列细项', () {
      final entries = [
        UserPrivilegeEntry(
          database: 'shop',
          privileges: {'ALL PRIVILEGES', 'SELECT'},
        ),
      ];
      expect(
        UserSql.buildGrants('mysql', const UserAccount(name: 'a', host: '%'), entries),
        ['GRANT ALL PRIVILEGES ON `shop`.* TO \'a\'@\'%\''],
      );
    });

    test('空权限集不生成语句', () {
      expect(
        UserSql.buildGrants(
          'mysql',
          const UserAccount(name: 'a', host: '%'),
          [UserPrivilegeEntry(database: 'shop')],
        ),
        isEmpty,
      );
    });

    test('非 MySQL 系不生成权限语句', () {
      expect(
        UserSql.buildGrants(
          'postgresql',
          const UserAccount(name: 'a'),
          [
            UserPrivilegeEntry(
              database: 'shop',
              privileges: {'SELECT'},
            )
          ],
        ),
        isEmpty,
      );
    });

    test('PG 成员关系', () {
      expect(
        UserSql.buildMembershipAdd(
          'postgresql',
          const UserAccount(name: 'app'),
          {'grp'},
        ),
        ['GRANT "grp" TO "app"'],
      );
      expect(
        UserSql.buildMembershipRemove(
          'postgresql',
          const UserAccount(name: 'app'),
          {'grp'},
        ),
        ['REVOKE "grp" FROM "app"'],
      );
    });
  });

  group('权限聚合', () {
    test('同一目标的多个权限合并成一条', () {
      final rows = [
        ['shop', 'orders', '', 'SELECT', 'NO'],
        ['shop', 'orders', '', 'INSERT', 'YES'],
        ['shop', '', '', 'DROP', 'NO'],
      ];
      final entries = UserSql.aggregate(rows);
      expect(entries.length, 2);
      final orders = entries.firstWhere((e) => e.table == 'orders');
      expect(orders.privileges, {'SELECT', 'INSERT'});
      expect(orders.grantOption, isTrue);
      expect(orders.scope, PrivilegeScope.table);
      expect(orders.target, 'shop.orders');
    });

    test('服务器级聚合(行内无 db/table/col)', () {
      final rows = [
        ['PROCESS', 'NO'],
        ['SUPER', 'YES'],
      ];
      final entries = UserSql.aggregate(rows, serverLevel: true);
      expect(entries.single.privileges, {'PROCESS', 'SUPER'});
      expect(entries.single.scope, PrivilegeScope.server);
      expect(entries.single.target, '*.*');
    });

    test('USAGE 被过滤(MySQL 的"无权限"占位)', () {
      final rows = [
        ['shop', '', '', 'USAGE', 'NO'],
      ];
      expect(UserSql.aggregate(rows), isEmpty);
    });
  });

  group('SQL 预览 = 保存脚本', () {
    test('新建的完整脚本含建号 + 成员 + 权限', () {
      final spec = UserSpec(
        username: 'app',
        host: '%',
        password: 'pw',
        memberOf: {'readonly'},
        serverPrivileges: [
          UserPrivilegeEntry(privileges: {'PROCESS'}),
        ],
        privileges: [
          UserPrivilegeEntry(database: 'shop', privileges: {'SELECT'}),
        ],
      );
      final stmts = UserSql.buildScript('mysql', spec);
      expect(stmts.length, 4);
      expect(stmts[0], startsWith('CREATE USER'));
      expect(stmts[1], contains('GRANT `readonly` TO'));
      expect(stmts[2], contains('GRANT PROCESS ON *.*'));
      expect(stmts[3], contains('GRANT SELECT ON `shop`.*'));
    });

    test('预览文本每条语句带分号', () {
      final spec = UserSpec(
        username: 'app',
        host: '%',
        password: 'pw',
        privileges: [
          UserPrivilegeEntry(database: 'shop', privileges: {'SELECT'}),
        ],
      );
      final text = UserSql.buildScriptText('mysql', spec);
      expect(text, contains("CREATE USER 'app'@'%' IDENTIFIED BY 'pw';"));
      expect(text, contains('GRANT SELECT ON `shop`.* TO \'app\'@\'%\';'));
    });

    test('无内容时给出占位注释', () {
      expect(
        UserSql.buildScriptText('mysql', UserSpec()),
        contains('-- 无可执行的语句'),
      );
    });
  });

  group('语法细节', () {
    test('标识符按类型引用', () {
      expect(UserSql.identifier('mysql', 'a'), '`a`');
      expect(UserSql.identifier('postgresql', 'a'), '"a"');
      expect(UserSql.identifier('sqlserver', 'a'), '[a]');
      // 内含引用符时加倍转义
      expect(UserSql.identifier('postgresql', 'a"b'), '"a""b"');
      expect(UserSql.identifier('sqlserver', 'a]b'), '[a]]b]');
    });

    test('字面量转义单引号', () {
      expect(UserSql.literal("a'b"), "'a''b'");
    });

    test('unsupported 类型不生成任何语句', () {
      final spec = UserSpec(username: 'a');
      expect(UserSql.buildCreate('sqlite', spec), isEmpty);
      expect(UserSql.buildAlter('access', spec), isEmpty);
      expect(
        UserSql.buildDrop('sqlite', const UserAccount(name: 'a')),
        isEmpty,
      );
    });
  });
}
