/// SELECT 语句的服务端行数封顶。
///
/// 为什么 MySQL / PostgreSQL / SQLite 驱动不能照搬 SQL Server 那套流式游标:
/// 这三个包都是把结果集**整体**读进内存才交回调用方 —— `mysql_client` 的
/// `rowsStream` 只是 `Stream.fromIterable(已物化的 rows)`,`postgres` 的
/// `Result` 是个 `List<ResultRow>`,`sqlite3` 的 `select()` 返回 `ResultSet`
/// (同样是 List)。在调用方 `break` 毫无意义:数据那时已经全进了内存,
/// 而且服务端已经把整棵结果集发了过来。
///
/// 唯一能同时封住**内存**与**等待时间**的办法,是把行数上限写进 SQL,
/// 让存储引擎取满就停。这与 Navicat「最大记录数」的做法一致。
///
/// 追加 `LIMIT` 会改变语义或语法的场景一律不改写(返回 null),
/// 宁可退回旧行为也不能把用户的语句改坏。
library;

/// 出现即拒绝追加 LIMIT 的顶层关键字。
///
/// - `LIMIT` / `FETCH`:用户已自带封顶,再追加是语法错误
/// - `INTO`:`SELECT ... INTO OUTFILE` / PG 的 `SELECT ... INTO 新表`(写操作)
/// - `FOR` / `LOCK`:`FOR UPDATE` / `LOCK IN SHARE MODE` 必须排在 LIMIT 之后
/// - `PROCEDURE`:`SELECT ... PROCEDURE ANALYSE()`
/// - `INSERT` / `UPDATE` / `DELETE`:`WITH cte AS (...) DELETE FROM ...`
///   这类以 WITH 开头的写语句
const Set<String> _blockers = {
  'LIMIT',
  'FETCH',
  'INTO',
  'FOR',
  'LOCK',
  'PROCEDURE',
  'INSERT',
  'UPDATE',
  'DELETE',
};

/// 语句开头(顶层第一个关键字)允许的值:只有只读查询才配封顶
const Set<String> _capableHeads = {'SELECT', 'WITH'};

/// 若 [sql] 是一条可安全追加封顶的只读 SELECT,返回改写后的语句
/// (末尾追加 `\nLIMIT [maxRows]`);否则返回 null 表示**不要改写**。
///
/// 顶层判定按词法扫描:字符串 / 引用标识符 / 行注释 / 块注释(PG 嵌套)/
/// 美元引号内部一律不算顶层,括号深度大于 0 的关键字也忽略 ——
/// 所以 `SELECT * FROM (SELECT ... LIMIT 1) t` 仍可安全封顶。
/// 扫描遇到顶层分号(多条语句)、括号不配对或未闭合的结构时直接放弃。
String? capSelectSql(String sql, {required int maxRows}) {
  if (maxRows <= 0) return null;
  // 查询编辑页已按语句切分,这里再兜一层:去掉末尾分号
  var body = sql.trim();
  while (body.endsWith(';')) {
    body = body.substring(0, body.length - 1).trimRight();
  }
  if (body.isEmpty) return null;

  final words = _topLevelWords(body);
  if (words == null || words.isEmpty) return null;
  if (!_capableHeads.contains(words.first)) return null;
  for (final word in words) {
    if (_blockers.contains(word)) return null;
  }
  // 以换行起始:语句若以 `-- 行注释` 收尾,用空格追加会被注释吞掉
  return '$body\nLIMIT $maxRows';
}

/// 扫描 [sql] 的顶层关键字(大写)。
/// 返回 null 表示不可改写:出现顶层分号、括号不配对,或结尾有未闭合的
/// 字符串 / 块注释 / 美元引号(此时后续文本无法可靠判定,保守放弃)。
List<String>? _topLevelWords(String sql) {
  final words = <String>[];
  var depth = 0;
  var i = 0;
  String? quoteClose; // 未闭合的引号结构闭合符
  var blockDepth = 0; // /* */ 嵌套深度
  String? dollarTag; // 未闭合的 PostgreSQL 美元引号定界符

  while (i < sql.length) {
    final ch = sql[i];

    if (blockDepth > 0) {
      // 块注释:PostgreSQL 允许 /* */ 嵌套
      if (ch == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
        blockDepth++;
        i += 2;
      } else if (ch == '*' && i + 1 < sql.length && sql[i + 1] == '/') {
        blockDepth--;
        i += 2;
      } else {
        i++;
      }
      continue;
    }

    if (dollarTag != null) {
      final j = sql.indexOf(r'$', i);
      if (j < 0) return null;
      if (sql.startsWith(dollarTag, j)) {
        i = j + dollarTag.length;
        dollarTag = null;
      } else {
        i = j + 1;
      }
      continue;
    }

    if (quoteClose != null) {
      final close = quoteClose;
      final j = sql.indexOf(close, i);
      if (j < 0) return null; // 未闭合:保守放弃
      if (j + 1 < sql.length && sql[j + 1] == close) {
        // 双写定界符是转义,结构仍未闭合
        i = j + 2;
      } else {
        i = j + 1;
        quoteClose = null;
      }
      continue;
    }

    if (ch == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      // 行注释:注释内容不是生效 SQL,且封顶以换行起始追加,不会被吞掉,
      // 故找不到换行时按「到语句末尾」处理即可
      final nl = sql.indexOf('\n', i);
      i = nl < 0 ? sql.length : nl + 1;
      continue;
    }

    if (ch == '#') {
      // MySQL 行注释
      final nl = sql.indexOf('\n', i);
      i = nl < 0 ? sql.length : nl + 1;
      continue;
    }

    if (ch == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
      blockDepth = 1;
      i += 2;
      continue;
    }

    if (ch == r'$') {
      final tag = _dollarTagAt(sql, i);
      if (tag != null) {
        dollarTag = tag;
        i += tag.length;
        continue;
      }
      i++;
      continue;
    }

    if (ch == "'" || ch == '"' || ch == '`' || ch == '[') {
      quoteClose = ch == '[' ? ']' : ch;
      i++;
      continue;
    }

    if (ch == ';') {
      if (depth == 0) return null; // 多条语句:交给上层切分后再来
      i++;
      continue;
    }

    if (ch == '(') {
      depth++;
      i++;
      continue;
    }
    if (ch == ')') {
      if (depth == 0) return null; // 括号不配对
      depth--;
      i++;
      continue;
    }

    if (_isWordChar(ch.codeUnitAt(0))) {
      var j = i;
      while (j < sql.length && _isWordChar(sql[j].codeUnitAt(0))) {
        j++;
      }
      if (depth == 0) words.add(sql.substring(i, j).toUpperCase());
      i = j;
      continue;
    }

    i++;
  }

  if (blockDepth > 0 || dollarTag != null || quoteClose != null) return null;
  return words;
}

/// 标识符字符:字母、数字、下划线,以及 MySQL 允许的 `$`
bool _isWordChar(int c) =>
    (c >= 0x41 && c <= 0x5A) || // A-Z
    (c >= 0x61 && c <= 0x7A) || // a-z
    (c >= 0x30 && c <= 0x39) || // 0-9
    c == 0x5F ||
    c == 0x24;

/// [sql] 的 [i] 处若是 PostgreSQL 美元引号起始($$ 或 $tag$),返回定界符本身。
/// 标签不能以数字开头,故 `$1` 这类占位参数不会被误判。
String? _dollarTagAt(String sql, int i) {
  final j = i + 1;
  if (j >= sql.length) return null;
  if (sql[j] == r'$') return r'$$';
  if (!_isIdentStart(sql[j].codeUnitAt(0))) return null;
  var k = j;
  while (k < sql.length && _isTagChar(sql[k].codeUnitAt(0))) {
    k++;
  }
  return (k < sql.length && sql[k] == r'$') ? sql.substring(i, k + 1) : null;
}

/// 美元引号标签的字符集:字母、数字、下划线(**不含** `$`,
/// 否则会把闭合定界符一起吃掉)
bool _isTagChar(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
    (c >= 0x30 && c <= 0x39) || c == 0x5F;

/// 标识符首字母(不能是数字)
bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;
