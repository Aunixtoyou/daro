import 'db_metadata.dart';
import 'table_design.dart';

/// 表设计器「字段」网格行 ⇄ 剪贴板文本。
///
/// 格式与数据浏览页「复制记录」一致:一行一个字段、单元格以 Tab 分隔,单元格
/// 顺序同网格表头(名称 / 类型 / 长度 / 小数点 / 不是 null / 键 / 注释)。
/// 因此既能把设计好的几列贴进表格软件,也能在表格软件里排好一批字段再整批粘回
/// 设计器(从 Excel 粘贴天然就是这个格式)。
class ColumnRowClipboard {
  /// 编码为剪贴板文本(空列表得到空串)
  static String encode(List<DesignColumn> columns) => columns
      .map((c) => [
            c.name,
            c.type,
            c.length,
            c.decimal,
            c.notNull ? '1' : '',
            c.primaryKey ? 'PRI' : '',
            c.comment,
          ].map(_cell).join('\t'))
      .join('\n');

  /// 单元格内的 Tab / 换行会破坏「一行一字段、Tab 分隔」的结构,折成空格
  static String _cell(String v) => v.replaceAll(RegExp(r'[\t\r\n]+'), ' ');

  /// 解析剪贴板文本为字段行。
  ///
  /// 只有一格的行按「列名清单」处理(从文本 / 编辑器复制一列字段名的场景),
  /// 其余按 [encode] 的列序取用,缺列留空。类型格允许写成 `varchar(128)`,
  /// 长度 / 小数点会被拆到对应列。
  static List<DesignColumn> parse(String text) {
    final rows = <DesignColumn>[];
    final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    for (final line in lines) {
      final cells = line
          .split('\t')
          .map((c) => c.trim())
          .toList(growable: false);
      if (cells.every((c) => c.isEmpty)) continue;
      if (cells.length == 1) {
        rows.add(DesignColumn(name: cells.first));
        continue;
      }
      // 类型可能自带长度参数(如 varchar(128) / decimal(10,2)),拆回三段
      final type = splitColumnType(cells[1]);
      final length = cells.length > 2 && cells[2].isNotEmpty
          ? cells[2]
          : type.length;
      final decimal = cells.length > 3 && cells[3].isNotEmpty
          ? cells[3]
          : type.decimal;
      rows.add(DesignColumn(
        name: cells[0],
        type: type.type.isEmpty ? 'varchar' : type.type,
        length: length,
        decimal: decimal,
        notNull: cells.length > 4 && _truthy(cells[4]),
        primaryKey: cells.length > 5 && _isKey(cells[5]),
        comment: cells.length > 6 ? cells[6] : '',
      ));
    }
    return rows;
  }

  /// 是否「未录入」的空行(新建表预置的那一行):粘贴时优先占用它而非追加
  static bool isBlank(DesignColumn c) =>
      c.name.trim().isEmpty &&
      c.comment.trim().isEmpty &&
      !c.primaryKey &&
      !c.notNull;

  /// 「不是 null」格:界面复制出的是 1,Excel / 手输可能是 ✓ / TRUE / NOT NULL
  static bool _truthy(String cell) => const {
        '1',
        'true',
        'yes',
        'y',
        'x',
        '✓',
        'not null',
        '是',
      }.contains(cell.toLowerCase());

  /// 「键」格:复制出的是 PRI,也认 Navicat / 表格软件里的钥匙图标与自填标记
  static bool _isKey(String cell) {
    final v = cell.toLowerCase().trim();
    return v.contains('pri') || v.contains('pk') || v.contains('🔑') || v == '1';
  }
}
