import 'package:flutter_test/flutter_test.dart';

import 'package:daro/data/result_grid_layout.dart';

/// 假测量:按字符数折算宽度(等宽假字体),便于断言用整数比较
double _fakeMeasure(String text, bool isHeader) =>
    text.length * 7.0 + (isHeader ? 5.0 : 0.0);

void main() {
  group('autoColumnWidths 按内容定宽', () {
    test('长文本列拿到放得下的宽度,不再是固定 150', () {
      final rows = [
        ['Index Scan using tag_pkey on tag b  (cost=0.15..8.17 rows=1)'],
        ['  Index Cond: ((id = 1) AND (id > 0))'],
      ];
      final widths = autoColumnWidths(
        columns: ['QUERY PLAN'],
        rows: rows,
        measureText: _fakeMeasure,
      );
      // 最长内容 58 字 × 7 + 内边距(8×2)+ 余量 8 = 430 → 撞 420 上限
      expect(widths.single, kAutoColumnMaxWidth);
      // 关键:远超旧的固定 150 列宽
      expect(widths.single, greaterThan(150.0));
    });

    test('列头比内容长时按列头定宽', () {
      final widths = autoColumnWidths(
        columns: ['very_long_column_name'],
        rows: [
          ['1']
        ],
        measureText: _fakeMeasure,
      );
      // 列头 21 字 × 7 + 5 + 24 = 176
      expect(widths.single, closeTo(176.0, 0.001));
    });

    test('超宽内容封顶 maxWidth,短内容 / 空串取 minWidth', () {
      final widths = autoColumnWidths(
        columns: ['w', 'n'],
        rows: [
          ['x' * 500, ''],
        ],
        measureText: _fakeMeasure,
      );
      expect(widths[0], kAutoColumnMaxWidth);
      // 列头 'n' 只有 12 宽,加内边距也撑不到 minWidth → 抬到下限
      expect(widths[1], kAutoColumnMinWidth);
    });

    test('只采样前 40 行:第 41 行之后的长内容不参与定宽', () {
      final rows = <List<String>>[
        for (var i = 0; i < kAutoColumnSampleRows; i++) ['a'],
        ['b' * 300],
      ];
      final widths = autoColumnWidths(
        columns: ['c'],
        rows: rows,
        measureText: _fakeMeasure,
      );
      // 采样范围内最长只有 1 字 → minWidth,未被第 41 行顶到上限
      expect(widths.single, kAutoColumnMinWidth);
    });

    test('单个单元格最多量 64 字(超长文本不逐字排版)', () {
      final measured = <String>[];
      autoColumnWidths(
        columns: ['c'],
        rows: [
          ['x' * 1000]
        ],
        measureText: (text, isHeader) {
          measured.add(text);
          return _fakeMeasure(text, isHeader);
        },
      );
      expect(measured.map((t) => t.length), everyElement(lessThanOrEqualTo(64)));
    });

    test('残缺行(行比列短)不越界', () {
      final widths = autoColumnWidths(
        columns: ['aaa', 'bbbbbbbbbbbb', 'c'],
        rows: [
          ['1'],
        ],
        measureText: _fakeMeasure,
      );
      // 三列都只看得到「列头」(第二行缺列按空单元格处理,不能越界取值)
      expect(widths.length, 3);
      expect(widths[0], kAutoColumnMinWidth);
      expect(widths[1], closeTo(12 * 7.0 + 5 + 24, 0.001));
      expect(widths[2], kAutoColumnMinWidth);
    });

    test('零行结果只按列头定宽(空表也要露出表头)', () {
      final widths = autoColumnWidths(
        columns: ['id', 'name'],
        rows: const [],
        measureText: _fakeMeasure,
      );
      expect(widths.length, 2);
      // id: 列头 2 字 → 2×7+5+24 = 43 → 抬到 minWidth
      expect(widths[0], kAutoColumnMinWidth);
      expect(widths[1], closeTo(4 * 7.0 + 5 + 24, 0.001));
    });
  });

  group('fillPanelWidth 把空余宽度补给最后一列', () {
    test('单列结果铺满面板(QUERY PLAN 因此能整行显示)', () {
      final filled = fillPanelWidth(
        const [400.0],
        viewportWidth: 900,
        leadingWidth: 44,
      );
      // 900 - 44(行号列) - 1(边框余量)
      expect(filled.single, 855.0);
    });

    test('多列时只加在最后一列,其它列不动', () {
      final filled = fillPanelWidth(
        const [100.0, 100.0, 100.0],
        viewportWidth: 500,
        leadingWidth: 44,
      );
      expect(filled.sublist(0, 2), [100.0, 100.0]);
      // 500 - 44(行号列) - 1(边框余量) - 300(三列之和)
      expect(filled.last, 100.0 + 155.0);
    });

    test('列宽之和已超出面板宽度时原样返回(交给横向滚动)', () {
      final filled = fillPanelWidth(
        const [400.0, 400.0],
        viewportWidth: 500,
        leadingWidth: 44,
      );
      expect(filled, [400.0, 400.0]);
    });

    test('宽度未知 / 非法时不改动', () {
      expect(fillPanelWidth(const [], viewportWidth: 800), isEmpty);
      expect(
        fillPanelWidth(const [120.0], viewportWidth: double.infinity),
        [120.0],
      );
    });

    test('不改写入参(纯函数)', () {
      const input = [400.0];
      fillPanelWidth(input, viewportWidth: 900);
      expect(input, [400.0]);
    });
  });
}
