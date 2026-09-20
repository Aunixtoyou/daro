/// SQL 语句分类:判定一条语句至少需要哪个执行模式(定稿 D6 的**白名单**口径)。
///
/// 为什么单独成文件:判定要处理注释、字符串、美元引用、永真条件,篇幅不小,
/// 而 `mcp_policy.dart` 承载的是策略模型与回退顺序,两者变更原因不同。
///
/// 三条总原则:
/// 1. **认不出来就当高风险** —— 多语句、空语句、不认识的开头一律 [SqlClass.unclassifiable]
///    (要求完全访问),与 DBX「无法可靠分类的请求需要完全访问」一致;
/// 2. 判定基于**归一化后的文本**:注释剔除、字符串字面量折成 `?`、引号标识符折成 `@`,
///    所以 `WHERE remark = '-- not a comment'` 不会被误当注释,`WHERE name='TRUE'`
///    也不会被误判成永真条件;
/// 3. 永真条件只认**封闭清单**(`TRUE` / `1` / `1=1` / `a=a` / `1<2` …)。
///    清单外的 WHERE 视为有效条件 —— 反过来(把不确定的都当永真)会误伤正常更新。
library;

import 'mcp_policy.dart';

/// 分类 [sql] 需要的最低执行模式。
SqlClass classifySql(String sql) {
  final statements = _splitNormalized(sql);
  // 多语句脚本:一次调用里既可能读也可能写,Phase-1 不拆开判定(定稿 D3:
  // 批量执行是 Phase-2 的 daro_execute_batch)。
  if (statements.length != 1) return SqlClass.unclassifiable;
  return _classifyOne(statements.first);
}

SqlClass _classifyOne(String s) {
  if (s.isEmpty) return SqlClass.unclassifiable;
  final head = _firstWord(s);
  switch (head) {
    // ---------------------------------------------------------- 明确只读 --
    case 'SELECT':
      // `SELECT ... INTO`(PG 建表 / MySQL OUTFILE)与锁定读都会改东西。
      if (_hasClause(s, 'INTO') ||
          _hasClause(s, 'FOR UPDATE') ||
          _hasClause(s, 'LOCK IN SHARE MODE') ||
          _hasClause(s, 'FOR NO KEY UPDATE') ||
          _hasClause(s, 'FOR SHARE') ||
          _hasClause(s, 'FOR KEY SHARE')) {
        return SqlClass.dangerous;
      }
      return SqlClass.readOnly;
    case 'SHOW':
    case 'VALUES':
    case 'LISTEN': // 只建立通知监听,不改数据
      return SqlClass.readOnly;
    case 'DESC':
    case 'DESCRIBE':
      // MySQL 的 `DESC 表` 是元数据读取;`DESCRIBE <语句>` 等价于 EXPLAIN。
      return _looksLikeObjectName(s) ? SqlClass.readOnly : _classifyExplain(s);
    case 'TABLE': // PG 的 `TABLE foo` == SELECT * FROM foo
      return SqlClass.readOnly;
    case 'PRAGMA':
      // 无 `=` 的是读取,有 `=` 的是设置(部分 pragma 会改存储格式)。
      return s.contains('=') ? SqlClass.dangerous : SqlClass.readOnly;
    case 'WITH':
      // `WITH cte AS (...) DELETE/UPDATE/INSERT` 是写语句,必须看内层关键字。
      if (_hasClause(s, 'DELETE')) return _writeClass(s, 'DELETE');
      if (_hasClause(s, 'UPDATE')) return _writeClass(s, 'UPDATE');
      if (_hasClause(s, 'INSERT')) return SqlClass.scopedWrite;
      if (_hasClause(s, 'MERGE')) return SqlClass.dangerous;
      return SqlClass.readOnly;

    // ------------------------------------------------------ 范围可控写入 --
    case 'INSERT':
    case 'REPLACE': // MySQL 的 REPLACE 语义上等同带删除的 INSERT
      return SqlClass.scopedWrite;
    case 'UPDATE':
      return _writeClass(s, 'UPDATE');
    case 'DELETE':
      return _writeClass(s, 'DELETE');
    case 'USE':
      // 只改 MCP 专用实例的会话上下文(与树上长连接隔离),但会换掉池键。
      return SqlClass.scopedWrite;

    // ---------------------------------------------------------- 高风险 ----
    case 'EXPLAIN':
      return _classifyExplain(s);
    case 'ANALYZE': // PG 的统计信息维护(写系统表);EXPLAIN ANALYZE 以 EXPLAIN 开头
    case 'MERGE':
    case 'TRUNCATE':
    case 'DROP':
    case 'CREATE':
    case 'ALTER':
    case 'RENAME':
    case 'GRANT':
    case 'REVOKE':
    case 'VACUUM':
    case 'OPTIMIZE':
    case 'REPAIR':
    case 'CHECKPOINT':
    case 'REFRESH': // 物化视图
    case 'REINDEX':
    case 'CLUSTER':
    case 'KILL':
    case 'SHUTDOWN':
    case 'RESET':
    case 'SET': // PG 的 `SET ROLE` 能提权,会话级语句一律按高风险
    case 'CALL':
    case 'EXEC':
    case 'EXECUTE':
    case 'DO': // PG 匿名块
    case 'COPY': // `COPY ... FROM` 是写,`TO` 能落盘
    case 'LOAD':
    case 'LOCK':
    case 'UNLOCK':
    case 'COMMENT':
    case 'SECURITY':
    case 'DISCARD':
    case 'PREPARE':
    case 'DEALLOCATE':
      return SqlClass.dangerous;
    default:
      return SqlClass.unclassifiable;
  }
}

/// UPDATE / DELETE:没有 WHERE,或 WHERE 是永真条件 → 全表操作,按高风险处理。
SqlClass _writeClass(String s, String keyword) {
  final where = _whereBody(s);
  if (where == null) return SqlClass.dangerous;
  return _isTautology(where) ? SqlClass.dangerous : SqlClass.scopedWrite;
}

/// `EXPLAIN <语句>`:被解释的语句不执行,所以内层是只读就判只读;
/// 内层是写语句(含 `EXPLAIN ANALYZE INSERT` 这种**会真跑**的)一律按高风险。
SqlClass _classifyExplain(String s) {
  final rest = s.replaceFirst(RegExp(r'^(EXPLAIN|DESC|DESCRIBE)\s+'), '');
  if (rest.isEmpty) return SqlClass.unclassifiable;
  return _classifyOne(rest) == SqlClass.readOnly
      ? SqlClass.readOnly
      : SqlClass.dangerous;
}

// ------------------------------------------------------------- 文本处理 ----

/// 归一化 + 按 `;` 拆句,丢掉空白语句。返回的每条语句都是大写、无注释、
/// 字面量折成 `?`、引号标识符折成 `@` 的单行文本。
List<String> _splitNormalized(String sql) {
  final normalized = _normalize(sql);
  return normalized
      .split(';')
      .map((s) => s.trim().replaceAll(RegExp(r'\s+'), ' '))
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
}

/// 剔除注释、把字符串与引号标识符折成占位符、字母统一大写。
///
/// 覆盖:行注释 `--` / `#`(MySQL)、块注释 `/* */`(支持 PG 的嵌套)、
/// 单引号串(`''` 与 `\'` 两种转义)、双引号串/标识符(`""` 转义)、
/// 反引号标识符(MySQL)、美元引用 `$tag$ ... $tag$`(PG)。
String _normalize(String sql) {
  final out = StringBuffer();
  final n = sql.length;
  var i = 0;
  var blockDepth = 0;
  while (i < n) {
    final ch = sql[i];
    if (blockDepth > 0) {
      // 块注释内:只找结束符,其余全部丢弃。
      if (ch == '/' && i + 1 < n && sql[i + 1] == '*') {
        blockDepth++;
        i += 2;
        continue;
      }
      if (ch == '*' && i + 1 < n && sql[i + 1] == '/') {
        blockDepth--;
        i += 2;
        if (blockDepth == 0) out.write(' ');
        continue;
      }
      i++;
      continue;
    }
    // 行注释
    if (ch == '-' && i + 1 < n && sql[i + 1] == '-') {
      final nl = sql.indexOf('\n', i);
      i = nl < 0 ? n : nl;
      continue;
    }
    if (ch == '#') {
      final nl = sql.indexOf('\n', i);
      i = nl < 0 ? n : nl;
      continue;
    }
    if (ch == '/' && i + 1 < n && sql[i + 1] == '*') {
      blockDepth = 1;
      i += 2;
      continue;
    }
    // 单引号字符串 → `?`
    if (ch == "'") {
      i = _skipQuoted(sql, i, "'", out, '?');
      continue;
    }
    // 双引号:MySQL 里是字符串、PG/ANSI 里是标识符;两种情况都折成 `@`
    // (既不会把 `"id" = 1` 当成常量比较,也不会把 `"a,b"` 里的逗号当分隔符)。
    if (ch == '"') {
      i = _skipQuoted(sql, i, '"', out, '@');
      continue;
    }
    if (ch == '`') {
      i = _skipQuoted(sql, i, '`', out, '@');
      continue;
    }
    // PG 美元引用 `$tag$ ... $tag$` / `$$ ... $$`
    if (ch == r'$') {
      final tag = _dollarTagAt(sql, i);
      if (tag != null) {
        final end = sql.indexOf(tag, i + tag.length);
        i = end < 0 ? n : end + tag.length;
        out.write('?');
        continue;
      }
    }
    out.write(ch.toUpperCase());
    i++;
  }
  return out.toString();
}

/// 从 [start] 处(引号字符)跳过一段引号内容,向 [out] 写入 [placeholder],
/// 返回结束位置之后的下标。支持 `''` 双写转义与 `\` 转义。
int _skipQuoted(String sql, int start, String quote, StringBuffer out, String placeholder) {
  final n = sql.length;
  var i = start + 1;
  while (i < n) {
    final c = sql[i];
    if (c == r'\') {
      // 反斜杠转义(MySQL 默认开启;PG 的 standard_conforming_strings 下
      // `\'` 不是转义,但那样 `''` 双写仍然成立 —— 两种走法都不会把
      // 引号误当成结束,顶多多吞一点文本,判定方向保守可接受)。
      i += 2;
      continue;
    }
    if (c == quote) {
      if (i + 1 < n && sql[i + 1] == quote) {
        i += 2;
        continue;
      }
      out.write(placeholder);
      return i + 1;
    }
    i++;
  }
  // 引号未闭合:整段吞到结尾,避免把后面的内容当成语句结构参与判定。
  out.write(placeholder);
  return n;
}

/// 识别 `$tag$` 形式的美元引用起始标记,不是则返回 null。
String? _dollarTagAt(String sql, int i) {
  var j = i + 1;
  while (j < sql.length) {
    final c = sql[j];
    if (c == r'$') return sql.substring(i, j + 1);
    final isIdent = (c == '_') ||
        (c.codeUnitAt(0) >= 'A'.codeUnitAt(0) && c.codeUnitAt(0) <= 'Z'.codeUnitAt(0)) ||
        (c.codeUnitAt(0) >= 'a'.codeUnitAt(0) && c.codeUnitAt(0) <= 'z'.codeUnitAt(0)) ||
        (j > i + 1 &&
            c.codeUnitAt(0) >= '0'.codeUnitAt(0) &&
            c.codeUnitAt(0) <= '9'.codeUnitAt(0));
    if (!isIdent) return null;
    j++;
  }
  return null;
}

/// 首个单词(语句关键字)。
String _firstWord(String s) {
  final m = RegExp(r'^\s*([A-Z_][A-Z0-9_]*)').firstMatch(s);
  return m?.group(1) ?? '';
}

/// `DESC 表名` / `DESCRIBE 表名` 形态(后面不是另一条 DML 关键字)。
bool _looksLikeObjectName(String s) {
  final rest = s.replaceFirst(RegExp(r'^(DESC|DESCRIBE)\s+'), '');
  final head = _firstWord(rest);
  return head.isNotEmpty &&
      !const {'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'WITH', 'VALUES', 'TABLE'}
          .contains(head);
}

/// 是否包含作为**独立词**出现的 [clause](归一化文本已全大写,故直接词边界匹配)。
bool _hasClause(String normalizedUpper, String clause) =>
    RegExp('\\b${RegExp.escape(clause)}\\b').hasMatch(normalizedUpper);

/// 取第一个顶层 `WHERE` 之后的条件文本(截到 GROUP/ORDER/LIMIT 等子句为止)。
/// 没有 WHERE 返回 null。
String? _whereBody(String s) {
  final m = RegExp(r'\bWHERE\b').firstMatch(s);
  if (m == null) return null;
  var body = s.substring(m.end);
  final stop = RegExp(
          r'\b(GROUP|ORDER|HAVING|LIMIT|OFFSET|FETCH|WINDOW|RETURNING|UNION|INTERSECT|EXCEPT|FOR|LOCK)\b')
      .firstMatch(body);
  if (stop != null) body = body.substring(0, stop.start);
  return body.trim();
}

/// 是否为「全表写」的 UPDATE / DELETE(无 WHERE 或 WHERE 永真)。
///
/// 用途:错误码区分 —— 数据读写档下被拦的此类语句返回 `WHERE_TOO_BROAD`
/// (hint 是「补过滤条件」),而不是笼统的 `MODE_DENIED`(hint 是「换档」),
/// 两条对 agent 的下一步指令完全不同。判定与 [_writeClass] 同源。
bool isBroadWrite(String sql) {
  final statements = _splitNormalized(sql);
  if (statements.length != 1) return false;
  final s = statements.first;
  final head = _firstWord(s);
  if (head != 'UPDATE' && head != 'DELETE') return false;
  final where = _whereBody(s);
  return where == null || _isTautology(where);
}

/// 永真条件判定:只认封闭清单,清单外一律当作有效条件。
///
/// 按优先级拆开看(OR 低于 AND):
/// - `A AND B` 恒真 ⟺ 每段都恒真;
/// - `A OR B` 恒真 ⟺ **存在**一个恒真的分支 —— `WHERE x=1 OR 1=1` 会匹配全表,
///   这正是最需要拦的写法,所以不能因为「含 OR」就放过。
/// 带括号的表达式不做结构化解析(需要真语法树),一律视为有效条件(偏保守放行,
/// 与「只拒绝封闭清单里的永真式」的口径一致)。
bool _isTautology(String where) {
  if (where.isEmpty) return true;
  if (where.contains('(') || where.contains(')')) return false;
  for (final orGroup in where.split(RegExp(r'\bOR\b'))) {
    final segments = orGroup.split(RegExp(r'\bAND\b'));
    if (segments.every((seg) => _isTautologySegment(seg.trim()))) return true;
  }
  return false;
}

/// 单个 AND 段是否恒真。只认封闭清单,清单外一律当作有效条件。
bool _isTautologySegment(String seg) {
  if (seg.isEmpty) return true;
  // WHERE TRUE / WHERE 1 / WHERE 'x'(字面量已折成 ?)
  if (seg == 'TRUE' || seg == '1' || seg == '?') return true;
  // WHERE 1=1 / WHERE TRUE=TRUE / WHERE a=a:两侧字面相同才是永真;
  // `a = b`、`STATUS = ?` 是真实比较。
  final eq = RegExp(r'^(\w+|\?)\s*=\s*(\w+|\?)$').firstMatch(seg);
  if (eq != null) return eq.group(1) == eq.group(2);
  // WHERE 1<>0 / WHERE 1<2:数字常量比较,按字面值判真伪。
  final cmp = RegExp(r'^(\d+)\s*(<>|<|>|<=|>=|=)\s*(\d+)$').firstMatch(seg);
  if (cmp != null) {
    final l = int.parse(cmp.group(1)!);
    final r = int.parse(cmp.group(3)!);
    return switch (cmp.group(2)!) {
      '<>' => l != r,
      '<' => l < r,
      '>' => l > r,
      '<=' => l <= r,
      '>=' => l >= r,
      _ => l == r,
    };
  }
  return false;
}
