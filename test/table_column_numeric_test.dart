import 'package:daro/widgets/table_data_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// 数值列右对齐的判定入口：与表头的 `#` 标记同一套词根，两者不能各判各的。
void main() {
  test('数值族类型判为数值列(右对齐)', () {
    for (final t in [
      'int(11)',
      'bigint unsigned',
      'decimal(10,2)',
      'double precision',
      'real',
      'serial',
      'NUMBER(10)',
    ]) {
      expect(columnIsNumeric(t), isTrue, reason: t);
    }
  });

  test('文本 / 日期 / 未知类型不右对齐', () {
    for (final t in [
      'varchar(64)',
      'text',
      'uuid',
      'date',
      'timestamp',
      'interval',
      'jsonb',
      '',
      null,
    ]) {
      expect(columnIsNumeric(t), isFalse, reason: '$t');
    }
  });
}
