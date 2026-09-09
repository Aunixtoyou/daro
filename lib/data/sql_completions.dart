import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';

import '../app/connection_manager.dart';
import 'db_data.dart';
import 'drivers/db_driver.dart';

/// SQL 关键字:美化 SQL(大写化)与补全提示共用一份,避免两处维护
const Set<String> kSqlKeywords = {
  'SELECT',
  'FROM',
  'WHERE',
  'AND',
  'OR',
  'NOT',
  'NULL',
  'IS',
  'IN',
  'LIKE',
  'AS',
  'ON',
  'JOIN',
  'LEFT',
  'RIGHT',
  'INNER',
  'OUTER',
  'CROSS',
  'FULL',
  'GROUP',
  'BY',
  'ORDER',
  'HAVING',
  'LIMIT',
  'OFFSET',
  'UNION',
  'ALL',
  'DISTINCT',
  'INSERT',
  'INTO',
  'VALUES',
  'UPDATE',
  'SET',
  'DELETE',
  'CREATE',
  'TABLE',
  'DROP',
  'ALTER',
  'ADD',
  'COLUMN',
  'INDEX',
  'VIEW',
  'WITH',
  'CASE',
  'WHEN',
  'THEN',
  'ELSE',
  'END',
  'EXISTS',
  'BETWEEN',
  'ASC',
  'DESC',
  'PRIMARY',
  'KEY',
  'FOREIGN',
  'REFERENCES',
  'DEFAULT',
  'UNIQUE',
  'RETURNING',
  'EXPLAIN',
  'TRUNCATE',
  'DATABASE',
  'SCHEMA',
  'GRANT',
  'REVOKE',
  'TRIGGER',
  'PROCEDURE',
  'FUNCTION',
  'CASCADE',
  'CONSTRAINT',
  'CHECK',
  'AUTO_INCREMENT',
  'IF',
  'USING',
  'CAST',
  'TRUE',
  'FALSE',
};

/// 常用 SQL 函数补全提示(word + 分类说明)
const List<SqlPrompt> kSqlFunctionPrompts = [
  // 聚合
  SqlPrompt(word: 'COUNT', kind: SqlPromptKind.function, detail: '聚合'),
  SqlPrompt(word: 'SUM', kind: SqlPromptKind.function, detail: '聚合'),
  SqlPrompt(word: 'AVG', kind: SqlPromptKind.function, detail: '聚合'),
  SqlPrompt(word: 'MIN', kind: SqlPromptKind.function, detail: '聚合'),
  SqlPrompt(word: 'MAX', kind: SqlPromptKind.function, detail: '聚合'),
  SqlPrompt(word: 'GROUP_CONCAT', kind: SqlPromptKind.function, detail: '聚合'),
  SqlPrompt(word: 'STRING_AGG', kind: SqlPromptKind.function, detail: '聚合'),
  // 字符串
  SqlPrompt(word: 'CONCAT', kind: SqlPromptKind.function, detail: '字符串'),
  SqlPrompt(word: 'CONCAT_WS', kind: SqlPromptKind.function, detail: '字符串'),
  SqlPrompt(word: 'SUBSTRING', kind: SqlPromptKind.function, detail: '字符串'),
  SqlPrompt(word: 'SUBSTR', kind: SqlPromptKind.function, detail: '字符串'),
  SqlPrompt(word: 'LENGTH', kind: SqlPromptKind.function, detail: '字符串'),
  SqlPrompt(word: 'CHAR_LENGTH', kind: SqlPromptKind.function, detail: '字符串'),
  SqlPrompt(word: 'UPPER', kind: SqlPromptKind.function, detail: '字符串'),
  SqlPrompt(word: 'LOWER', kind: SqlPromptKind.function, detail: '字符串'),
  SqlPrompt(word: 'TRIM', kind: SqlPromptKind.function, detail: '字符串'),
  SqlPrompt(word: 'REPLACE', kind: SqlPromptKind.function, detail: '字符串'),
  SqlPrompt(word: 'LEFT', kind: SqlPromptKind.function, detail: '字符串'),
  SqlPrompt(word: 'RIGHT', kind: SqlPromptKind.function, detail: '字符串'),
  SqlPrompt(word: 'INSTR', kind: SqlPromptKind.function, detail: '字符串'),
  SqlPrompt(word: 'LOCATE', kind: SqlPromptKind.function, detail: '字符串'),
  // 日期时间
  SqlPrompt(word: 'NOW', kind: SqlPromptKind.function, detail: '日期'),
  SqlPrompt(word: 'CURDATE', kind: SqlPromptKind.function, detail: '日期'),
  SqlPrompt(word: 'CURTIME', kind: SqlPromptKind.function, detail: '日期'),
  SqlPrompt(word: 'CURRENT_DATE', kind: SqlPromptKind.function, detail: '日期'),
  SqlPrompt(word: 'CURRENT_TIMESTAMP', kind: SqlPromptKind.function, detail: '日期'),
  SqlPrompt(word: 'DATE_FORMAT', kind: SqlPromptKind.function, detail: '日期'),
  SqlPrompt(word: 'DATEDIFF', kind: SqlPromptKind.function, detail: '日期'),
  SqlPrompt(word: 'DATE_ADD', kind: SqlPromptKind.function, detail: '日期'),
  SqlPrompt(word: 'DATE_SUB', kind: SqlPromptKind.function, detail: '日期'),
  SqlPrompt(word: 'EXTRACT', kind: SqlPromptKind.function, detail: '日期'),
  // 数值
  SqlPrompt(word: 'ABS', kind: SqlPromptKind.function, detail: '数值'),
  SqlPrompt(word: 'ROUND', kind: SqlPromptKind.function, detail: '数值'),
  SqlPrompt(word: 'FLOOR', kind: SqlPromptKind.function, detail: '数值'),
  SqlPrompt(word: 'CEIL', kind: SqlPromptKind.function, detail: '数值'),
  SqlPrompt(word: 'MOD', kind: SqlPromptKind.function, detail: '数值'),
  SqlPrompt(word: 'RAND', kind: SqlPromptKind.function, detail: '数值'),
  // 控制流 / 转换
  SqlPrompt(word: 'COALESCE', kind: SqlPromptKind.function, detail: '控制流'),
  SqlPrompt(word: 'NULLIF', kind: SqlPromptKind.function, detail: '控制流'),
  SqlPrompt(word: 'IFNULL', kind: SqlPromptKind.function, detail: '控制流'),
  SqlPrompt(word: 'IF', kind: SqlPromptKind.function, detail: '控制流'),
  SqlPrompt(word: 'CAST', kind: SqlPromptKind.function, detail: '转换'),
  SqlPrompt(word: 'CONVERT', kind: SqlPromptKind.function, detail: '转换'),
  // 窗口函数
  SqlPrompt(word: 'ROW_NUMBER', kind: SqlPromptKind.function, detail: '窗口'),
  SqlPrompt(word: 'RANK', kind: SqlPromptKind.function, detail: '窗口'),
  SqlPrompt(word: 'DENSE_RANK', kind: SqlPromptKind.function, detail: '窗口'),
  SqlPrompt(word: 'LAG', kind: SqlPromptKind.function, detail: '窗口'),
  SqlPrompt(word: 'LEAD', kind: SqlPromptKind.function, detail: '窗口'),
];

/// 补全提示项类型(驱动补全面板的小图标与标注)
enum SqlPromptKind { keyword, function, table, view, column }

/// SQL 补全提示词:关键字 / 函数 / 表 / 视图 / 列。
///
/// 插入内容始终为 [word] 本身(函数不带参数占位,SQL 中占位符反而碍事);
/// [detail] 为右侧灰色标注(列的数据类型、函数分类等)。
class SqlPrompt extends CodePrompt {
  const SqlPrompt({
    required super.word,
    required this.kind,
    this.detail = '',
  });

  final SqlPromptKind kind;
  final String detail;

  @override
  CodeAutocompleteResult get autocomplete => CodeAutocompleteResult.fromWord(word);

  @override
  bool match(String input) => _matchWord(word, input);
}

/// 大小写不敏感的前缀匹配(输入完整词时不再提示)
bool _matchWord(String word, String input) {
  if (input.isEmpty) return true;
  final w = word.toLowerCase();
  final i = input.toLowerCase();
  return w != i && w.startsWith(i);
}

/// schema 感知的 SQL 自动补全构建器(查询编辑页使用)。
///
/// - 普通输入:SQL 关键字 + 内置函数 + 当前运行上下文库的表 / 视图 / 函数
/// - 「表名.」后:该表的列名(懒加载,走 [ConnectionManager.describeTable])
/// - 引号字符串内不提示
///
/// schema 数据复用连接树已缓存的 [TableListState];未加载时异步触发
/// [ConnectionManager.expandDatabase](幂等),用户继续输入后下一轮生效。
class SqlPromptsBuilder implements CodeAutocompletePromptsBuilder {
  SqlPromptsBuilder({
    Future<List<ColumnDef>> Function(
      ConnectionManager manager,
      ConnectionInfo conn,
      String database,
      String table,
    )? describeTableImpl,
  }) : _describeTableImpl = describeTableImpl;

  /// 列结构加载钩子(测试注入 mock;缺省走 [ConnectionManager.describeTable])
  final Future<List<ColumnDef>> Function(
    ConnectionManager manager,
    ConnectionInfo conn,
    String database,
    String table,
  )? _describeTableImpl;

  ConnectionManager? _manager;
  ConnectionInfo? _conn;
  String? _database;
  String? _schema;

  /// 列提示缓存:"连接|库|模式|表" → 列提示(加载失败缓存为空,避免反复请求)
  final Map<String, List<SqlPrompt>> _columnCache = {};

  /// 正在加载列的缓存 key(防止重复请求)
  final Set<String> _loadingColumns = {};

  /// 查询页运行上下文(连接/库/模式)变化时刷新数据源并清列缓存
  void updateContext(ConnectionManager? manager, ConnectionInfo? conn,
      String? database, {String? schema}) {
    if (identical(_manager, manager) &&
        identical(_conn, conn) &&
        _database == database &&
        _schema == schema) {
      return;
    }
    _manager = manager;
    _conn = conn;
    _database = database;
    _schema = schema;
    _columnCache.clear();
    _loadingColumns.clear();
  }

  @override
  CodeAutocompleteEditingValue? build(
    BuildContext context,
    CodeLine codeLine,
    CodeLineSelection selection,
  ) {
    final text = codeLine.text;
    final extent = selection.extentOffset.clamp(0, text.length);
    if (extent == 0) return null;
    final before = text.substring(0, extent);

    // 提取光标前正在输入的标识符(支持数字,比 re_editor 默认的字母+下划线宽)
    final wordMatch = RegExp(r'[A-Za-z0-9_$]*$').firstMatch(before)!;
    final input = wordMatch.group(0)!;
    final beforeWord = before.substring(0, before.length - input.length);

    // 「表名.」前缀:点前是标识符则进入列补全
    String? owner;
    if (beforeWord.endsWith('.')) {
      final ownerMatch = RegExp(r'([A-Za-z0-9_$]+)\.$').firstMatch(beforeWord);
      owner = ownerMatch?.group(1);
    }
    if (input.isEmpty && owner == null) return null;
    // 行内引号未闭合(光标在字符串字面量内)不提示
    if (_insideStringLiteral(before)) return null;

    final prompts =
        owner != null ? _columnPromptsOf(owner, input) : _wordPrompts(input);
    if (prompts.isEmpty) return null;
    return CodeAutocompleteEditingValue(
      input: input,
      prompts: prompts,
      index: 0,
    );
  }

  /// 光标前行内是否存在未闭合的引号(单/双/反引号)
  bool _insideStringLiteral(String before) {
    var quote = false;
    var charQuote = false;
    for (var i = 0; i < before.length; i++) {
      final ch = before[i];
      if (ch == r"'" || ch == '"') {
        quote = !quote;
      } else if (ch == '`') {
        charQuote = !charQuote;
      }
    }
    return quote || charQuote;
  }

  /// 「表名.」列补全:表名大小写不敏感解析,列懒加载
  List<SqlPrompt> _columnPromptsOf(String owner, String input) {
    final table = _resolveTable(owner);
    if (table == null) return const [];
    final key = '${_conn?.name}|$_database|$_schema|$table';
    final cached = _columnCache[key];
    if (cached == null) {
      _loadColumns(table, key);
      return const [];
    }
    return _filter(cached, input);
  }

  /// 在当前库的表 / 视图中解析表名(大小写不敏感),返回规范名
  String? _resolveTable(String name) {
    final lower = name.toLowerCase();
    for (final t in _tableList()) {
      if (t.toLowerCase() == lower) return t;
    }
    return null;
  }

  /// 当前库的表 + 视图(未加载返回空)
  List<String> _tableList() {
    final state = _tableState();
    if (state == null) return const [];
    return [...(state.tables ?? const []), ...(state.views ?? const [])];
  }

  TableListState? _tableState() {
    final manager = _manager;
    final conn = _conn;
    final db = _database;
    if (manager == null || conn == null || db == null || !hasDriver(conn)) {
      return null;
    }
    // 所选模式非空时取该模式的独立状态;为空取库级(默认模式)状态
    final state = manager.tableStateOf(conn.name, db, schema: _schema);
    return state.status == LoadStatus.loaded ? state : null;
  }

  /// 异步加载某表的列并缓存;结果在用户继续输入后生效
  Future<void> _loadColumns(String table, String key) async {
    final manager = _manager;
    final conn = _conn;
    final db = _database;
    if (manager == null || conn == null || db == null) return;
    if (!hasDriver(conn) || _loadingColumns.contains(key)) return;
    _loadingColumns.add(key);
    try {
      final columns = await (_describeTableImpl?.call(manager, conn, db, table) ??
          manager.describeTable(conn, db, table, schema: _schema));
      _columnCache[key] = [
        for (final column in columns)
          SqlPrompt(
            word: column.name,
            kind: SqlPromptKind.column,
            detail: column.type,
          ),
      ];
    } catch (_) {
      // 加载失败缓存为空列表,避免每次按键都重新请求
      _columnCache[key] = const [];
    } finally {
      _loadingColumns.remove(key);
    }
  }

  /// 普通输入补全:schema 对象(表/视图/函数)在前,内置函数次之,关键字最后
  List<SqlPrompt> _wordPrompts(String input) {
    if (input.isEmpty) return const [];
    final result = <SqlPrompt>[];

    // schema 对象:复用连接树缓存,未加载时异步触发(幂等)
    final state = _tableState();
    if (state == null) {
      _ensureSchemaLoaded();
    } else {
      for (final table in (state.tables ?? const <String>[])) {
        if (_matchWord(table, input)) {
          result.add(SqlPrompt(word: table, kind: SqlPromptKind.table));
        }
      }
      for (final view in (state.views ?? const <String>[])) {
        if (_matchWord(view, input)) {
          result.add(SqlPrompt(word: view, kind: SqlPromptKind.view));
        }
      }
      for (final fn in (state.functions ?? const <String>[])) {
        if (_matchWord(fn, input)) {
          result.add(SqlPrompt(word: fn, kind: SqlPromptKind.function));
        }
      }
    }

    for (final fn in kSqlFunctionPrompts) {
      if (_matchWord(fn.word, input)) result.add(fn);
    }
    for (final keyword in kSqlKeywords) {
      if (_matchWord(keyword, input)) {
        result.add(SqlPrompt(word: keyword, kind: SqlPromptKind.keyword));
      }
    }

    // 提示条目上限,避免超大 schema 拖垮补全面板
    return result.length > 100 ? result.sublist(0, 100) : result;
  }

  /// schema 未加载时异步拉取(连接树展开同款幂等逻辑);
  /// 所选模式非空时拉该模式的对象列表,否则拉库级(默认模式)
  void _ensureSchemaLoaded() {
    final manager = _manager;
    final conn = _conn;
    final db = _database;
    if (manager == null || conn == null || db == null) return;
    if (!hasDriver(conn)) return;
    final schema = _schema;
    if (schema == null) {
      unawaited(manager.expandDatabase(conn, db));
    } else {
      unawaited(manager.expandSchema(conn, db, schema));
    }
  }

  List<SqlPrompt> _filter(List<SqlPrompt> prompts, String input) {
    if (input.isEmpty) return prompts;
    return [
      for (final p in prompts)
        if (_matchWord(p.word, input)) p,
    ];
  }
}
