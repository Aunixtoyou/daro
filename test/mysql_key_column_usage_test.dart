import 'package:daro/data/drivers/mysql_driver.dart';
import 'package:flutter_test/flutter_test.dart';

/// `information_schema.KEY_COLUMN_USAGE` 归组的离线回归。
///
/// 线上现象:结构同步部署 `tc_etc` 报 1060 Duplicate column name 'channel_id',
/// 生成的 DDL 里 `UNIQUE (\`channel_id\`, \`channel_id\`)` 与
/// `FOREIGN KEY (\`channel_id\`, \`channel_id\`)` 都多出一份列。根因是归组只按
/// 约束名建 map,而 MySQL 的索引名与外键约束名是两套命名空间,同名可共存。
List<String> row(String name, String col,
        {String refTable = '', String refCol = '', String ord = '1'}) =>
    [name, col, refTable, refCol, ord];

void main() {
  group('parseMysqlKeyColumnUsage', () {
    test('同名的 UNIQUE 与 FOREIGN KEY 各归各桶', () {
      final kcu = parseMysqlKeyColumnUsage([
        row('PRIMARY', 'etc_id'),
        row('channel_id', 'channel_id'), // UNIQUE 自带索引行
        row('channel_id', 'channel_id', refTable: 'tc_entrance_channel',
            refCol: 'entrance_channel_id'), // FK 行
      ]);

      expect(kcu.localColumns('PRIMARY'), 'etc_id');
      expect(kcu.localColumns('channel_id'), 'channel_id');
      expect(kcu.fkColumns('channel_id'), 'channel_id');
      expect(kcu.fkRefColumns('channel_id'), 'entrance_channel_id');
    });

    test('多列约束按行序拼接,引用列按位置对齐', () {
      final kcu = parseMysqlKeyColumnUsage([
        row('uq_a', 'a', ord: '1'),
        row('uq_a', 'b', ord: '2'),
        row('fk_a', 'x', refTable: 't', refCol: 'px', ord: '1'),
        row('fk_a', 'y', refTable: 't', refCol: 'py', ord: '2'),
      ]);

      expect(kcu.localColumns('uq_a'), 'a, b');
      expect(kcu.fkColumns('fk_a'), 'x, y');
      expect(kcu.fkRefColumns('fk_a'), 'px, py');
    });

    test('同桶同名同序号的重复行只计一次', () {
      final kcu = parseMysqlKeyColumnUsage([
        row('fk_a', 'x', refTable: 't', refCol: 'px'),
        row('fk_a', 'x', refTable: 't', refCol: 'px'), // 引用侧索引的重复行
        row('uq_b', 'c'),
        row('uq_b', 'c'),
      ]);

      expect(kcu.fkColumns('fk_a'), 'x');
      expect(kcu.fkRefColumns('fk_a'), 'px');
      expect(kcu.localColumns('uq_b'), 'c');
    });

    test('表达式索引行(本表列为空)不占位,空约束名整行忽略', () {
      final kcu = parseMysqlKeyColumnUsage([
        row('uq_e', ''),
        row('', 'orphan'),
        row('uq_e', 'e', ord: '2'),
      ]);

      expect(kcu.localCols['uq_e'], ['e']);
      expect(kcu.localCols.containsKey(''), isFalse);
    });
  });
}
