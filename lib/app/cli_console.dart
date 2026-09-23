/// 命令列界面的会话模型:提示符、续行缓冲、输入历史与输出行。
///
/// SQL 执行走注入的 [CliConsole.executor](由页面用 ConnectionManager 提供),
/// 本类因此不依赖 BuildContext 与真实数据库,可单测。
///
/// 输出文本刻意采用各引擎官方客户端的英文回显(`N rows in set` / `Query OK` /
/// `ERROR:`):命令行列是「客户端输出」而不是界面文案,不参与三语翻译,
/// 也与用户在自己终端里看到的形状一致。
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../data/drivers/db_driver.dart';
import '../data/sql_split.dart';

/// 输出行分类:决定命令行列里用什么颜色
enum CliLineKind { input, output, error, info }

/// 命令行列的一行文本
class CliLine {
  const CliLine(this.text, this.kind);

  final String text;
  final CliLineKind kind;
}

/// 单元格最长显示宽度,超出截断加省略号(命令行不换行,否则表格框线会错位)
const int kCliCellWidth = 40;

/// 把结果集排成 MySQL 客户端那种加框线的文本表格。
/// 单元格内的换行折成空格,过宽截断,保证框线对齐。
String formatResultTable(QueryResult result, {int maxCellWidth = kCliCellWidth}) {
  final columns = result.columns;
  final cut = <String>[
    for (final c in columns) _clipCell(c, maxCellWidth),
  ];
  final widths = [for (final c in cut) c.runes.length];
  for (final row in result.rows) {
    for (var i = 0; i < columns.length; i++) {
      final w = _clipCell(i < row.length ? row[i] : '', maxCellWidth).runes.length;
      if (w > widths[i]) widths[i] = w;
    }
  }

  final buffer = StringBuffer()..writeln(_border(widths));
  buffer.writeln(_row(cut, widths));
  buffer.writeln(_border(widths));
  for (final row in result.rows) {
    final cells = <String>[
      for (var i = 0; i < columns.length; i++)
        _clipCell(i < row.length ? row[i] : '', maxCellWidth),
    ];
    buffer.writeln(_row(cells, widths));
  }
  buffer.write(_border(widths));
  return buffer.toString();
}

String _border(List<int> widths) {
  final buffer = StringBuffer('+');
  for (final w in widths) {
    buffer
      ..write('-')
      ..write('-' * w)
      ..write('-+');
  }
  return buffer.toString();
}

String _row(List<String> cells, List<int> widths) {
  final buffer = StringBuffer('|');
  for (var i = 0; i < cells.length; i++) {
    final pad = ' ' * (widths[i] - cells[i].runes.length);
    buffer
      ..write(' ')
      ..write(cells[i])
      ..write(pad)
      ..write(' |');
  }
  return buffer.toString();
}

String _clipCell(String text, int maxWidth) {
  final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (oneLine.runes.length <= maxWidth) return oneLine;
  return '${String.fromCharCodes(oneLine.runes.take(maxWidth))}…';
}

/// 命令列界面会话:见文件头。
class CliConsole extends ChangeNotifier {
  CliConsole({
    required this.database,
    required this.typeId,
    required this.executor,
    this.rowLimit = 1000,
    this.maxHistory = 200,
    this.maxLines = 3000,
  });

  /// 会话所在库(提示符取它)
  final String database;

  /// 连接类型 id:决定提示符风格(PostgreSQL 家族 `库名=#`,其余 `库名>`)
  final String typeId;

  /// 执行一条语句:由页面注入,失败直接抛异常
  final Future<QueryResult> Function(String sql) executor;

  /// 单条语句最多取回多少行(交给驱动下推 LIMIT,不拉整表)
  final int rowLimit;

  /// 输入历史上限与输出行上限(超出丢最早的,避免长会话把内存吃满)
  final int maxHistory;
  final int maxLines;

  static const String _delimiter = ';';

  final List<CliLine> _lines = [];
  final List<String> _history = [];

  /// 未闭合的续行文本(不含结束符的半截语句)
  String _pending = '';

  bool _busy = false;
  bool _disposed = false;

  /// 历史游标:-1 表示没在翻历史,下一次按 ↑ 从最新一条开始
  int _historyIndex = -1;

  List<CliLine> get lines => UnmodifiableListView(_lines);
  List<String> get history => UnmodifiableListView(_history);
  bool get busy => _busy;
  bool get awaitingContinuation => _pending.isNotEmpty;

  /// 主提示符,如 `datawalk_dev=# `
  String get prompt =>
      '$database${kUseSchemaTypes.contains(typeId) ? '=#' : '>'} ';

  /// 续行提示符:与主提示符等宽,便于区分「正在续的那一行」
  String get continuationPrompt => '${' ' * (prompt.length - 3)}-> ';

  /// 追加一行(供页面在连接失败等场合回显)
  void append(String text, [CliLineKind kind = CliLineKind.output]) {
    _appendLines(text, kind);
  }

  /// 清空输出(标签右键「清空」用)
  void clear() {
    _lines.clear();
    _pending = '';
    _notify();
  }

  /// 提交一行输入。
  ///
  /// 只有整段缓冲以结束符收尾才切分执行:字符串与注释里的分号
  /// 由 [splitSqlStatements] 的词法状态机处理,不会提前触发。
  /// 未收尾则留在续行缓冲里,等下一行继续拼。
  Future<void> submit(String raw) async {
    if (_busy) return;
    final line = raw.trim();
    if (line.isEmpty) {
      if (_pending.isNotEmpty) {
        _pending = '';
        _appendLines('已取消未完成的输入语句', CliLineKind.info);
      }
      return;
    }

    final echo = _pending.isNotEmpty ? continuationPrompt : prompt;
    _appendLines('$echo$raw', CliLineKind.input);
    _pending = '$_pending$raw\n';
    if (!_pending.trimRight().endsWith(_delimiter)) {
      _notify();
      return;
    }

    final script = _pending;
    _pending = '';
    await _runScript(script);
  }

  Future<void> _runScript(String script) async {
    final statements = splitSqlStatements(script);
    if (statements.isEmpty) {
      _notify();
      return;
    }
    _busy = true;
    _historyIndex = -1;
    for (final stmt in statements) {
      _remember(stmt);
      final sw = Stopwatch()..start();
      QueryResult result;
      try {
        result = await executor(stmt);
      } catch (e) {
        if (_disposed) return;
        _busy = false;
        _appendLines('ERROR: $e', CliLineKind.error);
        return;
      }
      if (_disposed) return;
      final ms = sw.elapsedMilliseconds;
      if (result.isSelect) {
        _appendLines(formatResultTable(result), CliLineKind.output);
        final n = result.rows.length;
        _appendLines(
          '$n${result.truncated ? '+' : ''} ${n == 1 ? 'row' : 'rows'} in set ($ms ms)',
          CliLineKind.output,
        );
      } else {
        _appendLines(
          result.affectedRows > 0
              ? 'Query OK, ${result.affectedRows} rows affected ($ms ms)'
              : 'Query OK ($ms ms)',
          CliLineKind.output,
        );
      }
    }
    _busy = false;
    _notify();
  }

  void _remember(String stmt) {
    if (_history.isNotEmpty && _history.last == stmt) return;
    _history.add(stmt);
    if (_history.length > maxHistory) {
      _history.removeRange(0, _history.length - maxHistory);
    }
  }

  /// ↑ / ↓ 翻历史。返回要写进输入框的文本,无可翻时返回 null(保持原文)。
  /// 到底(最新一条之后)时清空输入框。
  String? recallHistory({required bool backwards}) {
    if (_history.isEmpty) return null;
    if (backwards) {
      _historyIndex = _historyIndex < 0
          ? _history.length - 1
          : (_historyIndex - 1).clamp(0, _history.length - 1);
    } else {
      if (_historyIndex < 0) return null;
      if (_historyIndex >= _history.length - 1) {
        _historyIndex = -1;
        return '';
      }
      _historyIndex++;
    }
    return _history[_historyIndex];
  }

  void _appendLines(String text, CliLineKind kind) {
    for (final line in text.split('\n')) {
      _lines.add(CliLine(line, kind));
    }
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
