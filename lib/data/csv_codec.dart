/// CSV 行编解码(RFC 4180 风格)。
///
/// 编码用于导出向导;解码为**增量式**解析器,供导入向导边读文件边出行,
/// 避免把整个文件读进内存。分隔符 / 引号 / 行尾均可配置,
/// 以适配 Excel 导出的 `;` 分隔文件与制表符文本。
library;

/// 分隔风格:导出编码与导入解码共用
class DelimitedStyle {
  const DelimitedStyle({
    this.delimiter = ',',
    this.quote = '"',
    this.eol = '\r\n',
    this.nullAs = '',
  });

  /// 字段分隔符(单字符)
  final String delimiter;

  /// 字段引号字符(单字符)
  final String quote;

  /// 行尾序列
  final String eol;

  /// NULL 的输出文本;导入时该文本(以及空串,见导入选项)视为 NULL
  final String nullAs;

  /// 常用预设:标准逗号 CSV
  static const standard = DelimitedStyle();

  /// 常用预设:Excel 中文区域常用的分号分隔
  static const semicolon = DelimitedStyle(delimiter: ';');

  /// 常用预设:制表符分隔(TSV)
  static const tab = DelimitedStyle(delimiter: '\t');

  /// 分隔符对应的展示名(向导选项标签)
  static String delimiterLabel(String d) => switch (d) {
        ',' => '逗号 (,)',
        ';' => '分号 (;)',
        '\t' => '制表符 (Tab)',
        '|' => '竖线 (|)',
        _ => '自定义 ($d)',
      };
}

/// 把一行编码为 CSV 文本(不含行尾)。
///
/// [nullFlags] 非空时按位标记真 NULL(输出 [DelimitedStyle.nullAs],
/// 且不受 [quoteAll] 影响加引号,保证导入方能识别空值);
/// 含分隔符 / 引号 / 换行的值一律加引号,内部引号按双写转义。
String csvEncodeRow(
  List<String> cells,
  DelimitedStyle style, {
  bool quoteAll = false,
  List<bool>? nullFlags,
}) {
  final delim = style.delimiter;
  final q = style.quote;
  final buf = StringBuffer();
  for (var i = 0; i < cells.length; i++) {
    if (i > 0) buf.write(delim);
    final isNull = nullFlags != null && i < nullFlags.length && nullFlags[i];
    final raw = isNull ? style.nullAs : cells[i];
    final needsQuote = isNull
        ? style.nullAs.isNotEmpty && _containsSpecial(raw, delim, q)
        : quoteAll || _containsSpecial(raw, delim, q);
    if (!needsQuote) {
      buf.write(raw);
    } else {
      buf
        ..write(q)
        ..write(raw.replaceAll(q, '$q$q'))
        ..write(q);
    }
  }
  return buf.toString();
}

bool _containsSpecial(String v, String delim, String quote) {
  if (v.contains(delim)) return true;
  if (v.contains(quote)) return true;
  if (v.contains('\n') || v.contains('\r')) return true;
  // 首尾空白需要引号才能保真
  return v.isNotEmpty && (v.startsWith(' ') || v.endsWith(' '));
}

/// 增量 CSV 解析器:分块喂入文本,输出已完整成形的行。
///
/// 引号内的换行不会产生「断行」,这是与逐行 split 的本质区别。
class CsvStreamDecoder {
  CsvStreamDecoder(this.style);

  final DelimitedStyle style;

  /// 当前字段缓冲
  final _field = StringBuffer();

  /// 已解析出但尚未取走的行
  final _pending = <List<String>>[];

  /// 是否正处于引号包裹的字段内
  bool _inQuotes = false;

  /// 上一字符是否为引号内的转义引号(双写),用于跳过其闭合判定
  bool _quoteEscaped = false;

  /// 本次 feed 结束时是否处于行尾 CR 之后(用于把 CRLF 当作一个换行)
  bool _afterCr = false;

  /// 是否已读取过 UTF-8 BOM(BOM 只可能在文件开头出现一次)
  bool _bomChecked = false;

  /// 当前行已积累的字段
  final _row = <String>[];

  /// 喂入一段文本,返回本次新解析出的完整行
  /// (行尾尚未出现的半行会留在内部,直到 [flush])。
  List<List<String>> feed(String text) {
    _pending.clear();
    if (!_bomChecked) {
      // 把首个 chunk 前可能出现的 BOM 去掉(Windows Excel 导出常带)
      if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
        text = text.substring(1);
      }
      _bomChecked = true;
    }
    for (var i = 0; i < text.length; i++) {
      _advance(text[i]);
    }
    return List<List<String>>.from(_pending);
  }

  /// 文件结束时调用:把未以换行收尾的最后一行吐出。
  /// 文件正常以换行结尾时解析状态已处于新行开头,此时不产出空行。
  List<List<String>> flush() {
    _pending.clear();
    if (_field.isEmpty && _row.isEmpty) return const [];
    _endField();
    _endRow();
    return List<List<String>>.from(_pending);
  }

  void _advance(String ch) {
    // CRLF:CR 已经结束了行,紧随的 LF 视为同一换行的一部分
    if (_afterCr) {
      _afterCr = false;
      if (ch == '\n') return;
    }
    if (_inQuotes) {
      if (_quoteEscaped) {
        _quoteEscaped = false;
        if (ch == style.quote) {
          // 双写引号:第二个引号属于内容
          _field.write(style.quote);
          return;
        }
        // 单引号后接其它字符:引号字段结束,当前字符按非引号语境处理
        _inQuotes = false;
      } else if (ch == style.quote) {
        _quoteEscaped = true;
        return;
      } else {
        _field.write(ch);
        return;
      }
    }

    if (ch == style.quote) {
      // 仅当字段尚未积累内容时才视为引号字段起始(容忍 Excel 的
      // 非标准写法:字段中途出现裸引号时按普通字符处理)
      if (_field.isEmpty) {
        _inQuotes = true;
      } else {
        _field.write(ch);
      }
      return;
    }
    if (ch == style.delimiter) {
      _endField();
      return;
    }
    if (ch == '\n' || ch == '\r') {
      _endField();
      _endRow();
      _afterCr = ch == '\r';
      return;
    }
    _field.write(ch);
  }

  void _endField() {
    _row.add(_field.toString());
    _field.clear();
  }

  void _endRow() {
    if (_row.isEmpty) return;
    _pending.add(List<String>.from(_row));
    _row.clear();
  }
}
