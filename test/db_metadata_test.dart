import 'package:daro/data/db_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

/// 跨驱动元数据折算纯函数:驱动只负责取数,方言差异集中在此,
/// 故可脱离真实数据库逐条核对(这些规则直接决定「设计表」回显是否正确)。
void main() {
  group('splitColumnType', () {
    test('带长度 / 精度的类型拆分为三段', () {
      expect(splitColumnType('varchar(255)'),
          (type: 'varchar', length: '255', decimal: ''));
      expect(splitColumnType('decimal(10,2)'),
          (type: 'decimal', length: '10', decimal: '2'));
      expect(splitColumnType('bit(3)'),
          (type: 'bit', length: '3', decimal: ''));
    });

    test('MySQL 修饰符留在类型名内', () {
      expect(splitColumnType('int(11) unsigned'),
          (type: 'int unsigned', length: '11', decimal: ''));
      expect(splitColumnType('decimal(10,2) unsigned zerofill'),
          (type: 'decimal unsigned zerofill', length: '10', decimal: '2'));
      expect(splitColumnType('int unsigned'),
          (type: 'int unsigned', length: '', decimal: ''));
    });

    test('无长度 / 空参数 / 残缺参数', () {
      expect(splitColumnType('text'), (type: 'text', length: '', decimal: ''));
      expect(splitColumnType('double precision'),
          (type: 'double precision', length: '', decimal: ''));
      expect(splitColumnType('numeric(10, )'),
          (type: 'numeric', length: '10', decimal: ''));
      expect(splitColumnType(''), (type: '', length: '', decimal: ''));
      expect(splitColumnType('   '), (type: '', length: '', decimal: ''));
    });

    test('含引号的参数(enum / set)整体保留在类型名', () {
      expect(splitColumnType("enum('a','b')"),
          (type: "enum('a','b')", length: '', decimal: ''));
    });

    test('括号不在末尾时不拆分(保留原样,避免误解析)', () {
      expect(splitColumnType('timestamp(3) without time zone'),
          (type: 'timestamp(3) without time zone', length: '', decimal: ''));
    });

    test('大小写原样保留(交由 baseTypeOf 归一)', () {
      expect(splitColumnType(' CHARACTER VARYING(50) '),
          (type: 'CHARACTER VARYING', length: '50', decimal: ''));
    });
  });

  group('baseTypeOf', () {
    test('PostgreSQL 长名映射为设计器下拉候选', () {
      expect(baseTypeOf('character varying', 'postgresql'), 'varchar');
      expect(baseTypeOf('integer', 'postgresql'), 'int4');
      expect(baseTypeOf('bigint', 'postgresql'), 'int8');
      expect(baseTypeOf('timestamp without time zone', 'postgresql'),
          'timestamp');
      expect(baseTypeOf('timestamp with time zone', 'postgresql'), 'timestamptz');
      expect(baseTypeOf('bit varying', 'postgresql'), 'varbit');
      expect(baseTypeOf('CHARACTER VARYING(50)', 'postgresql'), 'varchar');
    });

    test('云厂商 PG 变体同样走别名表', () {
      expect(baseTypeOf('integer', 'aliyun-polardb-postgres'), 'int4');
    });

    test('非 PG 方言不改类型名', () {
      expect(baseTypeOf('bigint', 'mysql'), 'bigint');
      expect(baseTypeOf('int unsigned', 'mysql'), 'int unsigned');
      expect(baseTypeOf('int(11) unsigned', 'mariadb'), 'int unsigned');
      expect(baseTypeOf('NCHAR(10)', 'sqlserver'), 'nchar');
      expect(baseTypeOf('text', 'sqlite'), 'text');
    });
  });

  group('normaliseDefault', () {
    test('PostgreSQL:剥 ::类型 与包裹括号', () {
      expect(normaliseDefault("'abc'::character varying", 'postgresql'), "'abc'");
      expect(normaliseDefault('0::integer', 'postgresql'), '0');
      expect(normaliseDefault("((now()))", 'postgresql'), 'now()');
      expect(
          normaliseDefault(
              "'2020-01-01 00:00:00'::timestamp without time zone", 'postgresql'),
          "'2020-01-01 00:00:00'");
    });

    test('PostgreSQL:序列 / NULL 特例', () {
      // nextval 由 identity 建模承载,不再重复写 DEFAULT
      expect(normaliseDefault("nextval('t_id_seq'::regclass)", 'postgresql'),
          isNull);
      expect(
          normaliseDefault("currval('s'::regclass)", 'postgresql'), isNull);
      expect(normaliseDefault('NULL::integer', 'postgresql'), 'NULL');
    });

    test('MySQL 原样保留', () {
      expect(normaliseDefault('CURRENT_TIMESTAMP', 'mysql'), 'CURRENT_TIMESTAMP');
      expect(normaliseDefault("'abc'", 'mysql'), "'abc'");
      expect(normaliseDefault("b'1'", 'mysql'), "b'1'");
      expect(normaliseDefault('NULL', 'mysql'), 'NULL');
    });

    test('SQL Server:脱掉服务端包裹的括号', () {
      expect(normaliseDefault('((1))', 'sqlserver'), '1');
      expect(normaliseDefault('(getdate())', 'sqlserver'), 'getdate()');
      expect(normaliseDefault("((N'x'))", 'sqlserver'), "N'x'");
      expect(normaliseDefault('((0))', 'aliyun-rds-sqlserver'), '0');
    });

    test('空值统一为空串(= 无默认值)', () {
      expect(normaliseDefault('', 'postgresql'), '');
      expect(normaliseDefault(null, 'mysql'), '');
      expect(normaliseDefault('   ', 'sqlserver'), '');
    });
  });

  group('lengthFromBytes', () {
    test('nvarchar / nchar 按双字节折半', () {
      expect(lengthFromBytes(4000, 'nvarchar'), 2000);
      expect(lengthFromBytes(10, 'nchar'), 5);
    });

    test('char / varchar / binary 字节数即长度', () {
      expect(lengthFromBytes(50, 'varchar'), 50);
      expect(lengthFromBytes(50, 'char'), 50);
      expect(lengthFromBytes(128, 'varbinary'), 128);
    });

    test('-1(max)/ 0 / null 与非字符类型返回 null', () {
      expect(lengthFromBytes(-1, 'varchar'), isNull);
      expect(lengthFromBytes(0, 'char'), isNull);
      expect(lengthFromBytes(null, 'varchar'), isNull);
      expect(lengthFromBytes(8, 'int'), isNull);
      expect(lengthFromBytes(8, 'int unsigned'), isNull);
      expect(lengthFromBytes(8, 'datetime2'), isNull);
    });
  });

  group('stripRedundantParens', () {
    test('成对的外层括号反复剥除', () {
      expect(stripRedundantParens('((a > 0))'), 'a > 0');
      expect(stripRedundantParens('( (1) )'), '1');
      expect(stripRedundantParens('  a  '), 'a');
    });

    test('非整体包裹的括号保持原样', () {
      expect(stripRedundantParens('(a) + (b)'), '(a) + (b)');
      expect(stripRedundantParens('((1) + (2))'), '(1) + (2)');
      // 字符串字面量内的括号不参与配对判断
      expect(stripRedundantParens("'((x))'"), "'((x))'");
      expect(stripRedundantParens("('a' + 'b')"), "'a' + 'b'");
    });
  });
}
