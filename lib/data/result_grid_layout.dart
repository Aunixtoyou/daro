/// 结果网格列宽计算(纯逻辑,文本测量由调用方注入)。
///
/// 起因:PostgreSQL 的 `EXPLAIN` 输出是「一行一条计划文本」(列名 QUERY PLAN),
/// 固定列宽会把计划截成 `Index Scan using p...` / `Index Cond: ((id > ...`,
/// 而面板右侧还空着一大片 —— 计划完全读不出来。
/// 这里按内容定宽,并把面板空余宽度补给最后一列,长文本能整行显示、面板不留缺口。
///
/// 测量与渲染必须用同一套字体 / 字号 / 内边距,否则算出的宽度和实际排版对不上。
library;

/// 自适应列宽档位:窄列不给空串留大块空白,超宽列不独占整个面板
/// (超出的部分仍可拖列头边框继续加宽)
const double kAutoColumnMinWidth = 56.0;
const double kAutoColumnMaxWidth = 420.0;

/// 内容采样行数:文本测量是真实布局,结果集可能上千行 × 上百列,
/// 取前若干行已足够代表该列宽度,避免一次测量卡住界面
const int kAutoColumnSampleRows = 40;

/// 内边距之外的额外余量(列边框 + 抗度量误差)
const double kAutoColumnSlack = 8.0;

/// 单列测量的文本上限:列宽本就有上限,量前 [kMeasureCharLimit] 字即可
const int kMeasureCharLimit = 64;

/// 返回每列「放下最长内容」所需宽度(含左右内边距),夹在 [minWidth] /
/// [maxWidth] 之间。
///
/// [measureText] 返回单行文本的渲染宽度,入参 `(text, isHeader)`:
/// 数据单元格与列头的字体可能不同,故分开测量、取更大者。
List<double> autoColumnWidths({
  required List<String> columns,
  required List<List<String>> rows,
  required double Function(String text, bool isHeader) measureText,
  double paddingX = 8.0,
  double minWidth = kAutoColumnMinWidth,
  double maxWidth = kAutoColumnMaxWidth,
  int sampleRows = kAutoColumnSampleRows,
}) {
  final widths = <double>[];
  final sampled = rows.length < sampleRows ? rows.length : sampleRows;
  for (var col = 0; col < columns.length; col++) {
    var width = measureText(_sample(columns[col]), true);
    for (var row = 0; row < sampled; row++) {
      final cells = rows[row];
      // 行比列短(驱动返回的残缺行)时按空单元格处理,不能让测量越界
      if (col >= cells.length) continue;
      final cellWidth = measureText(_sample(cells[col]), false);
      if (cellWidth > width) width = cellWidth;
    }
    final padded = width + paddingX * 2 + kAutoColumnSlack;
    widths.add(padded < minWidth
        ? minWidth
        : (padded > maxWidth ? maxWidth : padded));
  }
  return widths;
}

/// 列宽之和不足面板宽度时,把空余宽度补给最后一列(Navicat / Excel 惯例)。
///
/// 单列结果(如 QUERY PLAN)因此铺满面板;列宽之和已超过面板宽度时原样返回,
/// 由外层横向滚动承接。[leadingWidth] 为行号列等前置固定宽度。
List<double> fillPanelWidth(
  List<double> widths, {
  required double viewportWidth,
  double leadingWidth = 0,
}) {
  final fitted = List<double>.of(widths);
  if (fitted.isEmpty || !viewportWidth.isFinite) return fitted;
  final avail = viewportWidth - leadingWidth - 1;
  var sum = 0.0;
  for (final w in fitted) {
    sum += w;
  }
  if (sum < avail) fitted[fitted.length - 1] += avail - sum;
  return fitted;
}

/// 测量采样文本:截断位置避开代理对,免得把 emoji 之类切成半个字符
String _sample(String value, {int limit = kMeasureCharLimit}) {
  if (value.length <= limit) return value;
  var cut = limit;
  final unit = value.codeUnitAt(cut - 1);
  if (unit >= 0xd800 && unit <= 0xdbff) cut += 1;
  return value.substring(0, cut);
}
