/// 跨数据库元数据解析:把各驱动从 `information_schema` / 系统视图取回的原始
/// 文本(类型、默认值表达式、字节长度)归一化为 [DesignColumn] 的分段取值。
///
/// 抽成纯函数的目的:驱动只负责「取数 + 映射」,方言折算规则集中一处且可
/// 独立单测,避免 PostgreSQL / MySQL / SQL Server 的差异散落进驱动实现。
library;

import 'table_design.dart';

/// 类型文本拆分结果:类型名 + 长度 + 小数位(空串 = 无)。
///
/// 类型名保留 MySQL 的 `unsigned` / `zerofill` 等修饰符(如 `int unsigned`),
/// 长度与小数位单独返回(如 `decimal(10,2)` → length `10` / decimal `2`)。
typedef SplitColumnType = ({String type, String length, String decimal});

/// PostgreSQL 系统目录返回的类型名 → 设计器「类型」下拉候选
/// (与截图一致地采用 PG 原生短名 int2 / int4 / int8 / bpchar 等)。
const Map<String, String> kPgTypeAliases = {
  'smallint': 'int2',
  'integer': 'int4',
  'bigint': 'int8',
  'character varying': 'varchar',
  'character': 'bpchar',
  'timestamp without time zone': 'timestamp',
  'timestamp with time zone': 'timestamptz',
  'time without time zone': 'time',
  'bit varying': 'varbit',
};

/// 判断某段文本是否为「成对包裹」的括号(去掉后语义不变);
/// SQL Server 的默认值常量普遍写成 `((1))` / `(getdate())`。
bool _wrappedInParens(String v) {
  if (v.length < 2 || !v.startsWith('(') || !v.endsWith(')')) return false;
  var depth = 0;
  var inQuote = false;
  for (var i = 0; i < v.length; i++) {
    final ch = v[i];
    if (ch == "'") {
      // SQL 字符串里的连续两个单引号是转义,不结束字面量
      if (inQuote && i + 1 < v.length && v[i + 1] == "'") {
        i++;
        continue;
      }
      inQuote = !inQuote;
      continue;
    }
    if (inQuote) continue;
    if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
      if (depth == 0) return i == v.length - 1;
    }
  }
  return false;
}

/// 反复剥掉表达式外层成对的括号。
///
/// PostgreSQL 的 `pg_get_constraintdef` 与 SQL Server 的
/// `sys.check_constraints.definition` 都把检查表达式包成 `((a > 0))`,
/// 直接回写进 DDL 语义不变但可读性差,故统一脱壳。
String stripRedundantParens(String expr) {
  var s = expr.trim();
  while (_wrappedInParens(s)) {
    s = s.substring(1, s.length - 1).trim();
  }
  return s;
}

/// 反复剥掉成对的外层括号与尾随的 `::类型` 转换后缀,得到表达式主体。
String _unwrapExpression(String v) {
  var s = stripRedundantParens(v);
  var changed = true;
  while (changed) {
    changed = false;
    // 尾随类型转换:`'abc'::character varying` / `1::bigint` / `x::text[]`
    final cast =
        RegExp(r'::[a-z_][a-z0-9_ ]*(\[[0-9]*\])?$', caseSensitive: false)
            .firstMatch(s);
    if (cast != null && cast.start > 0) {
      s = stripRedundantParens(s.substring(0, cast.start));
      changed = true;
    }
  }
  return s;
}

/// 拆分类型文本为「类型名 / 长度 / 小数位」。
///
/// `varchar(255)` → `(varchar, 255, '')`;`decimal(10,2)` → `(decimal, 10, 2)`;
/// `int(11) unsigned` → `(int unsigned, 11, '')`;`numeric(10, )` → `(numeric, 10, '')`;
/// `text` / `double precision` → 长度与小数位为空;
/// `enum('a','b')` 这类含字面量的类型整体留在类型名里(无法按数字折算)。
SplitColumnType splitColumnType(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return (type: '', length: '', decimal: '');
  // 先摘出尾随修饰符:MySQL 的 `decimal(10,2) unsigned` 形态
  var modifier = '';
  final modMatch = RegExp(
    r'\s+((?:unsigned|signed|zerofill)(?:\s+zerofill)?)$',
    caseSensitive: false,
  ).firstMatch(s);
  if (modMatch != null) {
    modifier = ' ${modMatch.group(1)!.trim().toLowerCase()}';
    s = s.substring(0, modMatch.start).trim();
  }
  final paren = RegExp(r'^(?<base>[^(]+)\((?<args>[^)]*)\)$').firstMatch(s);
  if (paren == null) {
    return (type: '$s$modifier', length: '', decimal: '');
  }
  final base = paren.namedGroup('base')!.trim();
  final args = paren.namedGroup('args')!.trim();
  // 含引号的参数是 enum / set 的字面量列表,整体作为类型保留
  if (args.contains("'")) {
    return (type: '$base($args)$modifier', length: '', decimal: '');
  }
  final parts = args.split(',').map((e) => e.trim()).toList();
  return (
    type: '$base$modifier',
    length: parts.first,
    decimal: parts.length > 1 ? parts[1] : '',
  );
}

/// 归一化为设计器「类型」候选使用的类型名(保留 `unsigned` 等修饰符)。
///
/// [dialect] 为连接类型 id(见 [DdlBuilder.isPgLike]);PostgreSQL 的
/// `character varying` / `integer` 等长名映射为下拉里的 `varchar` / `int4`。
String baseTypeOf(String raw, String dialect) {
  final split = splitColumnType(raw);
  final mod = splitTypeModifier(split.type);
  var base = mod.base.toLowerCase();
  if (DdlBuilder.isPgLike(dialect)) base = kPgTypeAliases[base] ?? base;
  return mod.modifier.isEmpty ? base : '$base ${mod.modifier}';
}

/// 归一化默认值表达式,使其能直接写回 DDL(见 `DdlBuilder` 的 DEFAULT 渲染)。
///
/// 返回 `null` 表示「该默认值不由 DEFAULT 子句承载」:PostgreSQL 的
/// `nextval('t_id_seq'::regclass)`(序列 / IDENTITY)列走 identity 建模,
/// 避免同时输出 DEFAULT 与 IDENTITY。返回空串表示无默认值。
String? normaliseDefault(String? raw, String dialect) {
  final v = (raw ?? '').trim();
  if (v.isEmpty) return '';
  if (DdlBuilder.isPgLike(dialect)) {
    if (v.startsWith('nextval(') || v.startsWith('currval(')) return null;
    if (RegExp(r'^NULL::', caseSensitive: false).hasMatch(v)) return 'NULL';
    return _unwrapExpression(v);
  }
  if (DdlBuilder.isSqlServerLike(dialect)) {
    // SQL Server 的 Unicode 字面量前缀 N 需保留,只剥包裹括号
    final unwrapped = _unwrapExpression(v);
    if (RegExp(r"^N'", caseSensitive: false).hasMatch(unwrapped)) {
      return unwrapped;
    }
    return unwrapped;
  }
  // MySQL / MariaDB:information_schema 已给出可直接回写的字面量
  // (`CURRENT_TIMESTAMP`、`'abc'`、`NULL` 等),原样保留。
  return v;
}

/// SQL Server `sys.columns.max_length` → 字符长度。
///
/// `nchar` / `nvarchar` 按 UTF-16 双字节存储,需折半;`char` / `varchar` /
/// `binary` / `varbinary` 的字节数即长度;其余类型(含 -1 = `max`,由调用方
/// 按字符串 `max` 处理)返回 `null` 表示无长度语义。
int? lengthFromBytes(int? maxLength, String type) {
  if (maxLength == null || maxLength <= 0) return null;
  final t = splitTypeModifier(type).base.toLowerCase();
  switch (t) {
    case 'nchar':
    case 'nvarchar':
      return maxLength ~/ 2;
    case 'char':
    case 'varchar':
    case 'binary':
    case 'varbinary':
      return maxLength;
    default:
      return null;
  }
}

/// 十进制千分位分组:`131072` → `131,072`。
///
/// 详情面板里的原始值一律用逗号分组(与引擎统计的常见展示一致),
/// 不跟随界面语言:数字分组跟随语言会让 `1.234,56` 与 `1,234.56` 混在
/// 同一张表里,反而更难核对。
String formatThousands(int value) {
  final negative = value < 0;
  final digits = value.abs().toString();
  final buf = StringBuffer(negative ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return buf.toString();
}

/// 字节数 → 「人读值 (原始字节数)」,如 `131072` → `128.00 KB (131,072)`。
///
/// 以 1024 进制换算(存储引擎按页分配,给的是二进制倍数);
/// 小于 1 KiB 时保留 `bytes` 单位,与 `0 bytes (0)` 这类空表展示对齐。
/// [null] 表示目录里取不到该值,返回 null 交界面显示占位符 —— 不能显示 0,
/// 那会把「无数据」误呈现成「零字节」。
String? formatByteSize(int? bytes) {
  if (bytes == null) return null;
  if (bytes < 1024) {
    return '$bytes ${bytes == 1 ? 'byte' : 'bytes'} (${formatThousands(bytes)})';
  }
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var v = bytes / 1024;
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(2)} ${units[u]} (${formatThousands(bytes)})';
}

/// 详情面板的时间戳展示:`2026-03-03T14:43:56` → `2026-03-03 14:43:56`。
///
/// 按服务器返回的原样文本显示(不做时区换算):目录里的时间是服务端本地
/// 时间,换成客户端时区反而与 `SHOW CREATE TABLE` 等处的记录对不上。
/// [null] = 目录未记录该时间(如 InnoDB 不维护 UPDATE_TIME),返回 null。
String? formatDetailTimestamp(DateTime? value) {
  if (value == null) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${value.year.toString().padLeft(4, '0')}-${two(value.month)}-'
      '${two(value.day)} ${two(value.hour)}:${two(value.minute)}:'
      '${two(value.second)}';
}
