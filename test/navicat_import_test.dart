import 'dart:convert';
import 'dart:typed_data';

import 'package:daro/data/navicat_import.dart';
import 'package:flutter_test/flutter_test.dart';

/// Navicat 密码解密的基准向量。
///
/// 密文由 Navicat 内置常量(AES-128-CBC,key=`libcckeylibcckey`,
/// iv=`libcciv libcciv `)对**测试专用假口令**加密得到,
/// 不含任何真实环境口令;空串密文则与本机真实导出文件里的空密码连接一致。
const _libccVectors = <String, String>{
  '': 'E191AF42327478CC5F143EF279EC4D81',
  'Test@1234': 'ACCD060DF11B61DB7730FA7791F5B178',
  'p@ssw0rd-mysql': 'D079CE5CDFD2DBB3DE1C9AD758B6989F',
  'A-str Very Long Passw0rd!':
      '07FBC0BFBCADE8812E5A741E5395F0EFBE5CE18EB291B0EF02FBFBFD1EFDE98D',
  '密@码abc': 'E1A665FFE48BC7F17E732A86D452AA44',
};

const _ncxFixture = '''
<?xml version="1.0" encoding="UTF-8"?>
<Connections Ver="1.5">
	<Connection ConnectionName="demo_mysql" ProjectUUID="" ConnType="MYSQL" ServiceProvider="Default" Host="db.example.com" Port="3306" UserName="root" Password="D079CE5CDFD2DBB3DE1C9AD758B6989F" SavePassword="true" Encoding="65001" SSL="false" SSH="false" Remarks=""/>
	<Connection ConnectionName="demo_pg" ConnType="POSTGRESQL" Host="pg.example.com" Port="5432" Database="appdb" UserName="postgres" Password="ACCD060DF11B61DB7730FA7791F5B178" SavePassword="true"/>
	<Connection ConnectionName="demo_mssql_win" ConnType="SQLSERVER" Host="localhost\\SQLEXPRESS" Port="1433" Database="master" MSSQLAuthenMode="WINDOWS" UserName="" Password="E191AF42327478CC5F143EF279EC4D81" SavePassword="true"/>
	<Connection ConnectionName="demo_lite" ConnType="SQLITE" DatabaseFileName="C:\\tmp\\orderdb.db" UserName="" Password="" SavePassword="true" SQLiteEncrypt="false"/>
	<Connection ConnectionName="demo_oracle" ConnType="ORACLE" Host="ora.example.com" Port="1521" Database="ORCL" UserName="scott" Password="ACCD060DF11B61DB7730FA7791F5B178" SavePassword="true"/>
	<Connection ConnectionName="demo_no_save" ConnType="MYSQL" Host="legacy.example.com" Port="3306" UserName="app" Password="" SavePassword="false"/>
	<Connection ConnectionName="demo_old_fmt" ConnType="MYSQL" Host="old.example.com" Port="3306" UserName="app" Password="414243444546474" SavePassword="true"/>
	<Connection ConnectionName="a&amp;b" ConnType="MYSQL" Host="ent.example.com" Port="3306" UserName="u" Password="" SavePassword="false"/>
</Connections>
''';

void main() {
  group('AES-128-CBC 原语', () {
    test('与 FIPS-197 官方向量一致(零 IV 单块即 ECB 解密)', () {
      final key = Uint8List(16);
      final iv = Uint8List(16);
      final ct = _hex('66e94bd4ef8a2c3b884cfa59ca342b2e');
      expect(aesCbcDecrypt(key, iv, ct), _hex('00000000000000000000000000000000'));
    });

    test('加密→解密往返保持任意长度明文(解密结果含 PKCS#7 填充)', () {
      final key = Uint8List.fromList(utf8.encode(kNavicatLibccKey));
      final iv = Uint8List.fromList(utf8.encode(kNavicatLibccIv));
      for (final len in [0, 1, 15, 16, 17, 32, 33]) {
        final plain = Uint8List.fromList(
            List<int>.generate(len, (i) => 0x21 + (i % 0x5d)));
        final back = aesCbcDecrypt(key, iv, aesCbcEncrypt(key, iv, plain));
        expect(back.length, len + (16 - len % 16), reason: 'len=$len');
        expect(back.sublist(0, len), plain, reason: 'len=$len');
      }
    });
  });

  group('Navicat Password 解密', () {
    test('基准向量逐个还原', () {
      _libccVectors.forEach((plain, cipher) {
        final r = decryptNavicatPassword(cipher);
        expect(r.state, NavicatPasswordState.decrypted, reason: cipher);
        expect(r.password, plain, reason: cipher);
      });
    });

    test('小写十六进制同样可解(Navicat 实际写大写)', () {
      final r = decryptNavicatPassword(
          _libccVectors['Test@1234']!.toLowerCase());
      expect(r.password, 'Test@1234');
    });

    test('未保存密码 / 本就不需要密码 两种情形区分开', () {
      expect(decryptNavicatPassword('', saved: false).state,
          NavicatPasswordState.notSaved);
      expect(decryptNavicatPassword('').state, NavicatPasswordState.noPassword);
    });

    test('旧版 Blowfish 等解不出的密文判为 undecryptable,不产出半成品明文', () {
      for (final bad in [
        '414243444546474', // 奇数长度
        'zz79CE5CDFD2DBB3DE1C9AD758B6989F', // 非十六进制
        '00112233445566778899aabbcc', // 14 字节:不是 16 的整数倍
        'D079CE5CDFD2DBB3DE1C9AD758B69890', // 改动末字节 → 填充非法
        'Ymxvd2Zpc2ggbGVnYWN5IHBhc3N3b3Jk', // 旧版 Base64 形态
      ]) {
        expect(decryptNavicatPassword(bad).state,
            NavicatPasswordState.undecryptable,
            reason: bad);
      }
    });
  });

  group('NCX 解析与映射', () {
    final ncx = NavicatNcx.parse(_ncxFixture);
    NavicatConnection entry(String name) =>
        ncx.connections.firstWhere((e) => e.name == name);

    test('读出全部连接并保留导出格式版本', () {
      expect(ncx.connections.length, 8);
      expect(ncx.formatVersion, '1.5');
    });

    test('MySQL:host:port + 用户名 + 解密后的密码', () {
      final e = entry('demo_mysql');
      final c = e.toConnection();
      expect(e.typeId, 'mysql');
      expect(e.isSupported, isTrue);
      expect(c.host, 'db.example.com');
      expect(c.port, '3306');
      expect(c.username, 'root');
      expect(e.passwordState, NavicatPasswordState.decrypted);
      expect(c.password, 'p@ssw0rd-mysql');
      // NCX 的 MySQL 连接不带默认库(与新建连接表单一致:空则连上后列全部库)
      expect(c.database, '');
    });

    test('PostgreSQL:带默认库', () {
      final e = entry('demo_pg');
      final c = e.toConnection();
      expect(c.host, 'pg.example.com');
      expect(c.port, '5432');
      expect(c.database, 'appdb');
      expect(c.password, 'Test@1234');
    });

    test('SQL Server Windows 身份验证:authMethod=windows 且不落端口', () {
      final e = entry('demo_mssql_win');
      final c = e.toConnection();
      expect(c.typeId, 'sqlserver');
      expect(c.authMethod, 'windows');
      // 表单约定:SQL Server 不写端口(含命名实例时按 host 寻址)
      expect(c.port, '');
      expect(c.host, r'localhost\SQLEXPRESS');
      // 空密码密文解出空串:Windows 验证本就不用密码
      expect(e.passwordState, NavicatPasswordState.decrypted);
      expect(c.password, '');
    });

    test('SQLite:文件路径同时落到 host 与 database(读取端约定)', () {
      final e = entry('demo_lite');
      final c = e.toConnection();
      expect(e.isFileBased, isTrue);
      expect(c.host, r'C:\tmp\orderdb.db');
      expect(c.database, r'C:\tmp\orderdb.db');
      expect(c.port, '');
      expect(e.passwordState, NavicatPasswordState.noPassword);
    });

    test('未实现的引擎标为不可导入', () {
      expect(entry('demo_oracle').isSupported, isFalse);
    });

    test('未保存密码与解不出的密文都提示需手填', () {
      final unsaved = entry('demo_no_save');
      final legacy = entry('demo_old_fmt');
      expect(unsaved.passwordState, NavicatPasswordState.notSaved);
      expect(unsaved.needsManualPassword, isTrue);
      expect(legacy.passwordState, NavicatPasswordState.undecryptable);
      expect(legacy.needsManualPassword, isTrue);
      // 不写假密码
      expect(legacy.toConnection().password, '');
    });

    test('XML 实体在属性值里正确还原', () {
      expect(ncx.connections.last.name, 'a&b');
    });

    test('所有连接标为真实连接(走驱动加载元数据)', () {
      for (final e in ncx.connections) {
        expect(e.toConnection().isLive, isTrue);
      }
    });

    test('格式不符时给出中文原因', () {
      expect(() => NavicatNcx.parse('<NotNavicat/>'),
          throwsA(isA<FormatException>()));
      expect(() => NavicatNcx.parse('not xml at all'),
          throwsA(isA<FormatException>()));
      expect(() => NavicatNcx.parse('<Connections></Connections>'),
          throwsA(isA<FormatException>()));
    });
  });
}

Uint8List _hex(String s) => Uint8List.fromList(
    List<int>.generate(s.length ~/ 2, (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16)));
