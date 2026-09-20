import 'package:daro/data/column_clipboard.dart';
import 'package:daro/data/table_design.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DesignColumn col(
          {String name = '',
          String type = 'varchar',
          String length = '255',
          String decimal = '',
          bool notNull = false,
          bool primaryKey = false,
          String comment = ''}) =>
      DesignColumn(
        name: name,
        type: type,
        length: length,
        decimal: decimal,
        notNull: notNull,
        primaryKey: primaryKey,
        comment: comment,
      );

  group('ColumnRowClipboard.encode', () {
    test('每行 7 格、Tab 分隔,列序同「字段」网格表头', () {
      final text = ColumnRowClipboard.encode([
        col(
            name: 'id',
            type: 'int8',
            length: '',
            notNull: true,
            primaryKey: true),
        col(name: 'note', comment: '备注'),
      ]);
      expect(text.split('\n'), [
        'id\tint8\t\t\t1\tPRI\t',
        'note\tvarchar\t255\t\t\t\t备注',
      ]);
    });

    test('空列表得到空串', () {
      expect(ColumnRowClipboard.encode(const []), '');
    });
  });

  group('ColumnRowClipboard.parse', () {
    test('encode → parse 往返保真', () {
      final src = [
        col(name: 'id', type: 'int8', length: '', notNull: true, primaryKey: true),
        col(name: 'price', type: 'decimal', length: '10', decimal: '2'),
        col(name: 'note', comment: '备注'),
      ];
      final back = ColumnRowClipboard.parse(ColumnRowClipboard.encode(src));
      expect(back.length, 3);
      expect(
          back.map((c) => '${c.name}|${c.type}|${c.length}|${c.decimal}'
              '|${c.notNull}|${c.primaryKey}|${c.comment}'),
          src.map((c) => '${c.name}|${c.type}|${c.length}|${c.decimal}'
              '|${c.notNull}|${c.primaryKey}|${c.comment}'));
    });

    test('单元格里的 Tab / 换行折成空格,不破坏一行一字段的分行', () {
      final text =
          ColumnRowClipboard.encode([col(name: 'a\tb', comment: '第一行\n第二行')]);
      expect(text.split('\n').length, 1);
      final rows = ColumnRowClipboard.parse(text);
      expect(rows.single.name, 'a b');
      expect(rows.single.comment, '第一行 第二行');
    });

    test('类型格自带长度参数时拆回长度 / 小数点', () {
      final rows = ColumnRowClipboard.parse('amount\tdecimal(10,2)');
      expect(rows.single.type, 'decimal');
      expect(rows.single.length, '10');
      expect(rows.single.decimal, '2');
    });

    test('长度格已填时优先于类型括号里的长度', () {
      final rows = ColumnRowClipboard.parse('price\tvarchar(64)\t128');
      expect(rows.single.length, '128');
    });

    test('只有一格按「列名清单」处理,类型取网格默认', () {
      final rows = ColumnRowClipboard.parse('id\nname\nremark');
      expect(rows.map((c) => c.name), ['id', 'name', 'remark']);
      expect(rows.first.type, 'varchar');
    });

    test('空行与全空文本不产出字段', () {
      expect(ColumnRowClipboard.parse(''), isEmpty);
      expect(ColumnRowClipboard.parse('\r\n \n\t\t\t\r\n'), isEmpty);
    });

    test('Windows 换行与「不是 null / 键」的多种写法都能识别', () {
      final rows = ColumnRowClipboard.parse(
          'id\tint8\t\t\tTRUE\t🔑\t主键\r\nflag\ttinyint\t1\t\tx\t\t');
      expect(rows.first.notNull, isTrue);
      expect(rows.first.primaryKey, isTrue);
      expect(rows.first.comment, '主键');
      expect(rows.last.notNull, isTrue);
      expect(rows.last.primaryKey, isFalse);
    });

    test('列数不足时缺的列留空而不报错', () {
      final rows = ColumnRowClipboard.parse('id\tint8');
      expect(rows.single.name, 'id');
      expect(rows.single.comment, '');
      expect(rows.single.notNull, isFalse);
    });
  });

  group('ColumnRowClipboard.isBlank', () {
    test('新建表预置的未录入行为空行', () {
      expect(ColumnRowClipboard.isBlank(DesignColumn()), isTrue);
    });

    test('填了任一格即不再是空行', () {
      expect(ColumnRowClipboard.isBlank(col(name: 'x')), isFalse);
      expect(ColumnRowClipboard.isBlank(col(comment: 'x')), isFalse);
      expect(ColumnRowClipboard.isBlank(col(primaryKey: true)), isFalse);
      expect(ColumnRowClipboard.isBlank(col(notNull: true)), isFalse);
    });
  });
}
