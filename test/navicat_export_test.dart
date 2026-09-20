import 'package:daro/data/db_data.dart';
import 'package:daro/data/navicat_export.dart';
import 'package:daro/data/navicat_import.dart';
import 'package:flutter_test/flutter_test.dart';

/// 各 ConnType 的属性名称序列,逐字取自本机 Navicat Premium 16/17 真实导出的
/// connections.ncx(同类型 373/2/3/1 条里属性顺序完全一致)。
/// 导出文件必须保持同样的顺序与集合,否则不能算「和 Navicat 一致」。
const _mysqlOrder = [
  'ConnectionName', 'ProjectUUID', 'ConnType', 'ServiceProvider', 'Host',
  'Port', 'UserName', 'Password', 'SavePassword', 'SettingsSavePath',
  'SessionLimit', 'InitialSessionQueries', 'ClientDriverVersion',
  'ClientCharacterSet', 'ClientEncoding', 'Keepalive', 'UseConnectionTimeout',
  'ConnectionTimeoutSeconds', 'UseReadTimeout', 'UseWriteTimeout',
  'WriteTimeoutSeconds', 'Encoding', 'MySQLCharacterSet', 'Compression',
  'AutoConnect', 'NamedPipe', 'UseAdvanced', 'SSL', 'SSH', 'HTTP',
  'Compatibility', 'Remarks',
];

const _pgOrder = [
  'ConnectionName', 'ProjectUUID', 'ConnType', 'ServiceProvider', 'Host',
  'Port', 'Database', 'UserName', 'Password', 'SavePassword',
  'HostTypePreference', 'SettingsSavePath', 'ConnectionParameters',
  'SessionLimit', 'InitialSessionQueries', 'Keepalive', 'AutoConnect',
  'ClientDriverEncoding', 'ClientEncoding', 'UseAdvanced', 'SSL', 'SSH',
  'HTTP', 'Remarks',
];

const _mssqlOrder = [
  'ConnectionName', 'ProjectUUID', 'ConnType', 'ServiceProvider', 'Host',
  'Port', 'PortSpecified', 'Database', 'MSSQLAuthenMode',
  'MSSQLAuthenWindowsDomain', 'UserName', 'Password', 'SavePassword',
  'SettingsSavePath', 'ConnectionParameters', 'SessionLimit',
  'InitialSessionQueries', 'TimeoutReconnection', 'UseConnectionTimeout',
  'UseExecutionTimeout', 'TrustServerCertificate', 'AutoConnect',
  'UseAdvanced', 'UseEncryption', 'NativeClientDriver', 'SSH', 'Remarks',
];

const _sqliteOrder = [
  'ConnectionName', 'ProjectUUID', 'ConnType', 'ServiceProvider',
  'DatabaseFileName', 'UserName', 'Password', 'SavePassword',
  'SettingsSavePath', 'SessionLimit', 'InitialSessionQueries', 'AutoConnect',
  'SQLiteEncrypt', 'SQLiteEncryptPassword', 'SQLiteSaveEncryptPassword',
  'CipherName', 'CipherLegacyPageSize', 'HTTP', 'Remarks',
];

const _root = r'C:\Users\test\Documents\Navicat';

const _mysql = ConnectionInfo(
  name: '账套库',
  typeId: 'mysql',
  host: '10.0.0.11',
  port: '3306',
  username: 'root',
  password: 'p@ssw0rd-mysql',
  isLive: true,
);

const _pg = ConnectionInfo(
  name: '业务库',
  typeId: 'postgresql',
  host: 'pg.example.com',
  port: '5432',
  username: 'postgres',
  password: 'Test@1234',
  database: 'appdb',
  isLive: true,
);

const _mssql = ConnectionInfo(
  name: 'SQLEXPRESS',
  typeId: 'sqlserver',
  host: r'localhost\SQLEXPRESS',
  port: '',
  username: 'sa',
  password: 'A-str Very Long Passw0rd!',
  database: 'master',
  isLive: true,
);

const _mssqlWindows = ConnectionInfo(
  name: '本机实例',
  typeId: 'sqlserver',
  host: r'.\SQLEXPRESS',
  port: '',
  username: '',
  authMethod: 'windows',
  isLive: true,
);

const _sqlite = ConnectionInfo(
  name: 'orderdb',
  typeId: 'sqlite',
  port: '',
  username: '',
  host: r'C:\data\orderdb.db',
  database: r'C:\data\orderdb.db',
  isLive: true,
);

String _xml(List<ConnectionInfo> conns, {bool passwords = true}) =>
    buildNavicatNcx(conns, includePasswords: passwords, settingsSaveRoot: _root)
        .xml;

/// 取出第 n 条 `<Connection>` 的属性名(按出现顺序)
List<String> _attrNames(String xml, int index) {
  final line =
      xml.split('\r\n').where((l) => l.startsWith('\t<Connection')).toList();
  return RegExp(r'(\w+)="').allMatches(line[index]).map((m) => m.group(1)!).toList();
}

/// 取出某条连接里指定属性的值
String _attr(String xml, int index, String key) {
  final line =
      xml.split('\r\n').where((l) => l.startsWith('\t<Connection')).toList();
  final m = RegExp('$key="([^"]*)"').firstMatch(line[index]);
  return m?.group(1) ?? '';
}

void main() {
  group('属性模板与 Navicat 实测一致', () {
    test('MySQL / PostgreSQL / SQL Server / SQLite 四种顺序逐字对齐', () {
      final xml = _xml([_mysql, _pg, _mssql, _sqlite]);
      expect(_attrNames(xml, 0), _mysqlOrder);
      expect(_attrNames(xml, 1), _pgOrder);
      expect(_attrNames(xml, 2), _mssqlOrder);
      expect(_attrNames(xml, 3), _sqliteOrder);
    });

    test('MariaDB 按 MySQL 模板导出(Navicat 两者共用同一套属性)', () {
      final xml = _xml([_mysql.copyWith(typeId: 'mariadb', name: 'maria')]);
      expect(_attrNames(xml, 0), _mysqlOrder);
      expect(_attr(xml, 0, 'ConnType'), 'MYSQL');
    });

    test('Navicat 没有的类型跳过并说明原因', () {
      final r = buildNavicatNcx(
        [_mysql, _mysql.copyWith(typeId: 'access', name: '油站数据')],
        includePasswords: true,
        settingsSaveRoot: _root,
      );
      expect(r.exported, ['账套库']);
      expect(r.skipped.single.$1, '油站数据');
      expect(r.skipped.single.$2, contains('Access'));
    });
  });

  group('密码', () {
    test('勾选导出密码:密文能被同一套常量解回明文', () {
      final xml = _xml([_mysql, _pg, _mssql]);
      for (final (i, plain) in [
        (0, 'p@ssw0rd-mysql'),
        (1, 'Test@1234'),
        (2, 'A-str Very Long Passw0rd!'),
      ]) {
        final cipher = _attr(xml, i, 'Password');
        expect(cipher, matches(RegExp(r'^[0-9A-F]+$')), reason: '应为大写十六进制');
        expect(decryptNavicatPassword(cipher).password, plain);
      }
    });

    test('不勾选导出密码:Password 留空且 SavePassword=false', () {
      final xml = _xml([_mysql, _pg], passwords: false);
      for (final i in [0, 1]) {
        expect(_attr(xml, i, 'Password'), '');
        expect(_attr(xml, i, 'SavePassword'), 'false');
      }
    });

    test('空口令还原成「未保存」形态;Windows 验证例外按实测写空串密文', () {
      // 真实文件里 65 条没保存口令的 MySQL 连接都是 Password="" + SavePassword="false"
      final mysqlEmpty = _xml([_mysql.copyWith(password: '')]);
      expect(_attr(mysqlEmpty, 0, 'Password'), '');
      expect(_attr(mysqlEmpty, 0, 'SavePassword'), 'false');
      // Windows 验证不需要口令,Navicat 实测(SQLEXPRESS 行)写的是空串密文
      final win = _xml([_mssqlWindows]);
      expect(_attr(win, 0, 'Password'), 'E191AF42327478CC5F143EF279EC4D81');
      expect(_attr(win, 0, 'SavePassword'), 'true');
      expect(_attr(win, 0, 'MSSQLAuthenMode'), 'WINDOWS');
    });

    test('存了口令的连接 SavePassword=true', () {
      final xml = _xml([_mysql, _mssql]);
      expect(_attr(xml, 0, 'SavePassword'), 'true');
      expect(_attr(xml, 1, 'SavePassword'), 'true');
    });

    test('SQLite 口令走 SQLiteEncryptPassword,Password 恒为空', () {
      final keyed = _sqlite.copyWith(password: 'filekey');
      expect(_attr(_xml([_sqlite]), 0, 'Password'), '');
      expect(_attr(_xml([_sqlite]), 0, 'SQLiteEncrypt'), 'false');
      expect(_attr(_xml([keyed]), 0, 'SQLiteEncrypt'), 'true');
      expect(
          decryptNavicatPassword(
                  _attr(_xml([keyed]), 0, 'SQLiteEncryptPassword'))
              .password,
          'filekey');
    });
  });

  group('导出→导入 往返', () {
    test('四类连接的寻址信息和口令都能原样读回', () {
      final ncx = NavicatNcx.parse(_xml([_mysql, _pg, _mssql, _sqlite]));
      final back = ncx.connections.map((e) => e.toConnection()).toList();

      expect(back[0].typeId, 'mysql');
      expect(back[0].host, '10.0.0.11');
      expect(back[0].port, '3306');
      expect(back[0].username, 'root');
      expect(back[0].password, 'p@ssw0rd-mysql');

      expect(back[1].database, 'appdb');
      expect(back[1].password, 'Test@1234');

      expect(back[2].typeId, 'sqlserver');
      expect(back[2].host, r'localhost\SQLEXPRESS');
      // SQL Server 不写端口:导出补 Navicat 默认值,读回时按表单约定清空
      expect(back[2].port, '');
      expect(back[2].password, 'A-str Very Long Passw0rd!');

      expect(back[3].typeId, 'sqlite');
      expect(back[3].host, r'C:\data\orderdb.db');
      expect(back[3].database, r'C:\data\orderdb.db');
    });

    test('端口留空时按类型补默认值,不写空端口', () {
      final xml = _xml([_mysql.copyWith(port: ''), _pg.copyWith(port: '')]);
      expect(_attr(xml, 0, 'Port'), '3306');
      expect(_attr(xml, 1, 'Port'), '5432');
    });
  });

  // Navicat 原生 .ncx 没有分组字段(实测本机 378 条连接的导出文件里无任何
  // group/folder 属性),daro 用私有属性 Group 承载:只保证 daro↔daro 往返,
  // 未分组时必须与不带分组时逐字节一致。
  group('分组(私有属性 Group)', () {
    test('未分组的连接不写 Group 属性', () {
      expect(_attrNames(_xml([_mysql, _sqlite]), 0), isNot(contains('Group')));
      expect(_attrNames(_xml([_mysql, _sqlite]), 1), isNot(contains('Group')));
    });

    test('带分组时 Group 追加在实测模板末尾,既有属性顺序不动', () {
      final xml = _xml([_mysql.copyWith(group: '生产')]);
      expect(_attrNames(xml, 0), [..._mysqlOrder, 'Group']);
      expect(_attr(xml, 0, 'Group'), '生产');
    });

    test('分组名两侧空白导出时裁掉', () {
      final xml = _xml([_mysql.copyWith(group: '  生产  ')]);
      expect(_attr(xml, 0, 'Group'), '生产');
    });

    test('分组名里的 XML 特殊字符同样转义并读回', () {
      final xml = _xml([_mysql.copyWith(group: 'a&b<c>"d"')]);
      expect(xml, contains('Group="a&amp;b&lt;c&gt;&quot;d&quot;"'));
      expect(NavicatNcx.parse(xml).connections.single.group, 'a&b<c>"d"');
    });

    test('导出→导入往返保留分组;不带 Group 的文件读成未分组', () {
      final back = NavicatNcx.parse(
          _xml([_mysql.copyWith(group: '客户现场'), _pg]));
      expect(back.connections[0].group, '客户现场');
      expect(back.connections[0].toConnection().group, '客户现场');
      expect(back.connections[1].group, '');
      expect(back.connections[1].toConnection().group, '');
    });
  });

  group('文件形制', () {
    test('声明 / 根节点 / 制表符缩进 / CRLF / 结尾空行与 Navicat 一致', () {
      final xml = _xml([_mysql]);
      final bytes = xml.codeUnits;
      expect(xml.startsWith('<?xml version="1.0" encoding="UTF-8"?>\r\n'
          '<Connections Ver="1.5">\r\n\t<Connection'), isTrue);
      expect(xml.endsWith('/>\r\n</Connections>\r\n\r\n'), isTrue);
      // 全文只用 CRLF,不混入裸 LF
      expect(bytes.where((b) => b == 0x0a).length,
          bytes.where((b) => b == 0x0d).length);
    });

    test('名称里的 XML 特殊字符被转义且能正确读回', () {
      final tricky = _mysql.copyWith(name: 'a&b<c>"d"');
      final xml = _xml([tricky]);
      expect(xml, contains('ConnectionName="a&amp;b&lt;c&gt;&quot;d&quot;"'));
      expect(NavicatNcx.parse(xml).connections.single.name, 'a&b<c>"d"');
    });

    test('SettingsSavePath 按 Navicat 的目录形制回填', () {
      final xml = _xml([_mysql, _pg, _mssql, _sqlite]);
      expect(_attr(xml, 0, 'SettingsSavePath'),
          r'C:\Users\test\Documents\Navicat\MySQL\Servers\账套库');
      expect(_attr(xml, 2, 'SettingsSavePath'),
          r'C:\Users\test\Documents\Navicat\SQL Server\Servers\SQLEXPRESS');
    });
  });
}
