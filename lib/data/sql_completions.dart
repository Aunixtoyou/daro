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
/// [detail] 为右侧灰色标注(列的数据类型、函数分类等);
/// [comment] 为列注释(仅 SqlPromptKind.column 使用,来自 ColumnDef.comment)。
class SqlPrompt extends CodePrompt {
  const SqlPrompt({
    required super.word,
    required this.kind,
    this.detail = '',
    this.comment = '',
  });

  final SqlPromptKind kind;
  final String detail;
  final String comment;

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

// ────────────────────────────────────────────────────────────
// 表别名解析(FROM / JOIN / UPDATE 的 `AS` 别名 → 实际表名)
// ────────────────────────────────────────────────────────────

/// 限定名:schema.table,可作为表引用
final RegExp _sqlQualifiedName =
    RegExp(r'^[A-Za-z_][A-Za-z0-9_$]*(?:\.[A-Za-z_][A-Za-z0-9_$]*)*$');

/// 裸标识符(不含 `.`):可作为别名
final RegExp _sqlPlainName = RegExp(r'^[A-Za-z_][A-Za-z0-9_$]*$');

/// 词法切分 token:限定名 / 数字 / 单个符号(空白自动跳过)
final RegExp _sqlToken =
    RegExp(r'[A-Za-z_][A-Za-z0-9_$]*(?:\.[A-Za-z_][A-Za-z0-9_$]*)*|\d+|\S');

/// FROM / JOIN / UPDATE 之后的一处表引用:实际表名(unqualified)+ 可选别名
typedef _TableRef = ({String table, String? alias});

/// 扫描 SQL 中 `FROM` / `JOIN` / `UPDATE` 之后的表引用,返回 (表名, 别名?) 列表。
///
/// 支持:
/// - 带 `AS`(`FROM tag AS b`)与省略 `AS`(`FROM tag b`)两种写法
/// - schema 限定表名(`FROM public.tag AS b` → table=`tag`)
/// - 逗号分隔的多表(`FROM a t1, b t2`)
/// - 无别名引用(`FROM tag` → alias=null)
///
/// 字符串字面量 / 注释先剥离,SQL 保留字(WHERE、ORDER 等)不会被误判为别名。
List<_TableRef> _scanTableRefs(String sql) {
  final refs = <_TableRef>[];
  final tokens = [
    for (final match in _sqlToken.allMatches(_stripSqlLiterals(sql)))
      match.group(0)!,
  ];
  for (var i = 0; i < tokens.length; i++) {
    final head = tokens[i].toUpperCase();
    if (head != 'FROM' && head != 'JOIN' && head != 'UPDATE') continue;
    var j = i + 1;
    var first = true;
    while (j < tokens.length) {
      // FROM 之后允许逗号分隔的多表:`FROM a, b`
      if (!first) {
        if (tokens[j] != ',') break;
        j++;
      }
      first = false;
      if (j >= tokens.length || !_sqlQualifiedName.hasMatch(tokens[j])) break;
      final table = _unqualified(tokens[j]);
      j++;
      // 可选 `AS`;省略时下一个非保留标识符即别名
      String? alias;
      if (j < tokens.length && tokens[j].toUpperCase() == 'AS') j++;
      if (j < tokens.length &&
          _sqlPlainName.hasMatch(tokens[j]) &&
          !kSqlKeywords.contains(tokens[j].toUpperCase())) {
        alias = tokens[j];
        j++;
      }
      refs.add((table: table, alias: alias));
    }
  }
  return refs;
}

/// 解析 SQL 中的「表别名 → 实际表名」映射(键为小写别名)。
///
/// 仅收录显式写了别名的引用(`FROM tag AS b` / `FROM tag b`);
/// 无别名引用不产生映射(裸表名本身即可作为前缀)。
Map<String, String> parseTableAliases(String sql) {
  final aliases = <String, String>{};
  for (final ref in _scanTableRefs(sql)) {
    if (ref.alias != null) {
      aliases.putIfAbsent(ref.alias!.toLowerCase(), () => ref.table);
    }
  }
  return aliases;
}

/// 解析 SQL 作用域内引用的全部表名(FROM / JOIN / UPDATE 之后,含无别名引用),
/// 大小写按原始写法去重。用于「裸列名」补全:即使没写 `表名.` 前缀,
/// 只要该表出现在当前语句的 FROM 子句里,它的列也应进入候选。
Set<String> parseReferencedTables(String sql) {
  return {for (final ref in _scanTableRefs(sql)) ref.table};
}

/// 剥离字符串字面量与注释(替换为空白,便于后续词法切分)
String _stripSqlLiterals(String sql) {
  final buffer = StringBuffer();
  var i = 0;
  while (i < sql.length) {
    final ch = sql[i];
    if (ch == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      // 行注释:吃到行尾
      while (i < sql.length && sql[i] != '\n') {
        buffer.write(' ');
        i++;
      }
    } else if (ch == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
      // 块注释:吃到 `*/`
      while (i < sql.length) {
        if (sql[i] == '*' && i + 1 < sql.length && sql[i + 1] == '/') {
          buffer.write('  ');
          i += 2;
          break;
        }
        buffer.write(' ');
        i++;
      }
    } else if (ch == "'" || ch == '"' || ch == '`') {
      // 字符串字面量 / 引号标识符:整体剥离
      buffer.write(' ');
      i++;
      while (i < sql.length) {
        if (sql[i] == ch) {
          // 成对单引号转义(`''`)仍属字面量内部
          if (ch == "'" && i + 1 < sql.length && sql[i + 1] == "'") {
            buffer.write('  ');
            i += 2;
            continue;
          }
          buffer.write(' ');
          i++;
          break;
        }
        buffer.write(' ');
        i++;
      }
    } else {
      buffer.write(ch);
      i++;
    }
  }
  return buffer.toString();
}

/// 取限定名的最后一段(`public.tag` → `tag`)
String _unqualified(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? name : name.substring(dot + 1);
}

/// schema 感知的 SQL 自动补全构建器(查询编辑页使用)。
///
/// - 普通输入:SQL 关键字 + 内置函数 + 当前运行上下文库的表 / 视图 / 函数
/// - 「表名.」/「别名.」后:该表的列名(懒加载,走 [ConnectionManager.describeTable])
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
    this.sqlTextOf,
  }) : _describeTableImpl = describeTableImpl;

  /// 完整 SQL 文本提供者(解析 `FROM ... AS 别名` 用)。
  ///
  /// 别名可能声明在光标所在行之外(如美化为多行后),故需整篇文本;
  /// 未设置时退化为仅解析当前行。查询页在 initState 接入编辑控制器。
  String Function()? sqlTextOf;

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

  /// 列缓存建立时对应的表结构版本(TableListState.revision);
  /// 与当前版本不一致(如 ALTER 后 refreshDatabase)时清空列缓存重新拉取
  int? _columnCacheRevision;

  /// 别名映射缓存:按整篇 SQL 文本缓存,避免每次按键重复解析
  String? _aliasCacheKey;
  Map<String, String> _aliasCache = const {};

  /// 作用域表集合缓存:按整篇 SQL 文本缓存 FROM/JOIN 引用的表名
  String? _scopeCacheKey;
  Set<String> _scopeTables = const {};

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
    _columnCacheRevision = null;
  }

  @override
  CodeAutocompleteEditingValue? build(
    BuildContext context,
    CodeLine codeLine,
    CodeLineSelection selection,
  ) {
    // 表结构版本变化(如 ALTER 后 refreshDatabase):清空列缓存,本次重新懒加载
    final state = _tableState();
    if (state != null) {
      final rev = state.revision ?? 0;
      if (_columnCacheRevision != rev) {
        _columnCache.clear();
        _loadingColumns.clear();
        _columnCacheRevision = rev;
      }
    }

    // 预热整篇 SQL 引用的表结构(含无别名):键入「别名.」或裸列名时列已就绪
    final documentSql = sqlTextOf?.call();
    if (documentSql != null) _prewarmScopeColumns(documentSql);

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

    final prompts = owner != null
        ? _columnPromptsOf(owner, input, codeLine)
        : _wordPrompts(input);
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

  /// 「表名.」/「别名.」列补全:大小写不敏感解析,列懒加载
  List<SqlPrompt> _columnPromptsOf(
      String owner, String input, CodeLine codeLine) {
    final table = _tableOfOwner(owner, codeLine);
    if (table == null) return const [];
    final key = _columnCacheKey(table);
    final cached = _columnCache[key];
    if (cached == null) {
      _loadColumns(table, key);
      return const [];
    }
    return _filter(cached, input);
  }

  /// 解析「限定名」对应的实际表:先按表 / 视图名匹配,
  /// 未命中再按 `FROM / JOIN / UPDATE` 的表别名解析(`FROM tag AS b` 中的 `b`)。
  String? _tableOfOwner(String owner, CodeLine codeLine) {
    final direct = _resolveTable(owner);
    if (direct != null) return direct;
    final sql = sqlTextOf?.call() ?? codeLine.text;
    if (sql.isEmpty) return null;
    final aliased = _aliasesOf(sql)[owner.toLowerCase()];
    return aliased == null ? null : _resolveTable(aliased);
  }

  /// 别名映射(按整篇 SQL 文本缓存,避免每次按键重复解析)
  Map<String, String> _aliasesOf(String sql) {
    if (_aliasCacheKey != sql) {
      _aliasCacheKey = sql;
      _aliasCache = parseTableAliases(sql);
    }
    return _aliasCache;
  }

  /// 作用域表集合(按整篇 SQL 文本缓存):FROM/JOIN 引用的全部表名
  Set<String> _referencedTablesOf(String sql) {
    if (sql.isEmpty) return const {};
    if (_scopeCacheKey != sql) {
      _scopeCacheKey = sql;
      _scopeTables = parseReferencedTables(sql);
    }
    return _scopeTables;
  }

  /// 列缓存的 key:"连接|库|模式|表"
  String _columnCacheKey(String table) =>
      '${_conn?.name}|$_database|$_schema|$table';

  /// 预热整篇 SQL 引用的表结构(含无别名):键入「别名.」或裸列名的瞬间
  /// 列已就绪,无需等待第一次懒加载(失败的表会在缓存中留空,不重复请求)
  void _prewarmScopeColumns(String sql) {
    if (sql.isEmpty) return;
    for (final table in _referencedTablesOf(sql)) {
      final canonical = _resolveTable(table);
      if (canonical == null) continue;
      final key = _columnCacheKey(canonical);
      if (_columnCache.containsKey(key)) continue;
      _loadColumns(canonical, key);
    }
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
            comment: column.comment,
          ),
      ];
    } catch (_) {
      // 加载失败缓存为空列表,避免每次按键都重新请求
      _columnCache[key] = const [];
    } finally {
      _loadingColumns.remove(key);
    }
  }

  /// 普通输入补全:作用域列在前,schema 对象(表/视图/函数)次之,
  /// 内置函数再次,关键字最后
  List<SqlPrompt> _wordPrompts(String input) {
    if (input.isEmpty) return const [];
    final result = <SqlPrompt>[];

    // 裸列名补全:当前语句 FROM/JOIN 引用了哪些表,就把它们的列也列出来,
    // 无需写 `表名.` 前缀(无别名同样生效)。列结构由 _prewarmScopeColumns
    // 预热;尚未就绪(首轮加载中)时本轮跳过,继续输入后下一轮生效。
    final scopeSql = sqlTextOf?.call() ?? '';
    final addedColumns = <String>{};
    for (final table in _referencedTablesOf(scopeSql)) {
      final canonical = _resolveTable(table);
      if (canonical == null) continue;
      final cached = _columnCache[_columnCacheKey(canonical)];
      if (cached == null) continue;
      for (final col in cached) {
        if (addedColumns.add(col.word.toLowerCase()) &&
            _matchWord(col.word, input)) {
          result.add(col);
        }
      }
    }

    // schema 对象:复用连接树缓存,未加载时异步触发(幂等)
    final state = _tableState();
    if (state == null) {
      _ensureSchemaLoaded();
    } else {
      for (final table in (state.tables ?? const <String>[])) {
        if (_matchWord(table, input)) {
          result.add(SqlPrompt(
            word: table,
            kind: SqlPromptKind.table,
            comment: state.tableComments?[table] ?? '',
          ));
        }
      }
      for (final view in (state.views ?? const <String>[])) {
        if (_matchWord(view, input)) {
          result.add(SqlPrompt(
            word: view,
            kind: SqlPromptKind.view,
            comment: state.viewComments?[view] ?? '',
          ));
        }
      }
      for (final fn in (state.functions ?? const <String>[])) {
        if (_matchWord(fn, input)) {
          result.add(SqlPrompt(
            word: fn,
            kind: SqlPromptKind.function,
            comment: state.functionComments?[fn] ?? '',
          ));
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
