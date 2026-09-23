/// 新建表设计器的数据模型与按数据库方言生成 DDL 的工具。
///
/// 模型描述 pgAdmin 风格表设计器各标签页采集的内容:
/// 字段 / 索引 / 外键 / 唯一键 / 检查 / 排除 / 规则 / 触发器 / 选项 / 注释。
/// [DdlBuilder] 将 [DesignTable] 转换为目标数据库类型(连接类型 id)的
/// CREATE TABLE 及其关联语句;SQL 预览标签与「保存」共用同一生成逻辑,
/// 保证预览即所见、保存即所写。
library;

/// PostgreSQL 家族类型 id(触发器 / 规则 / 排除约束等仅此家族生成 DDL)
const Set<String> kPgLikeTypes = {
  'postgresql',
  'aliyun-rds-postgres',
  'aliyun-polardb-postgres',
  'aliyun-oceanbase-postgres',
};

/// MySQL / MariaDB 家族类型 id
const Set<String> kMysqlLikeTypes = {'mysql', 'mariadb'};

/// SQL Server 家族类型 id
const Set<String> kSqlServerLikeTypes = {'sqlserver', 'aliyun-rds-sqlserver'};

/// 不接受长度 / 精度参数的类型(小写比较)。
/// 「长度」列对类型是信息性展示(如 int8 的 64 位宽),
/// 拼进 DDL 会得到 `int8(64)` 这类非法语句,故 [DesignColumn.fullType] 跳过。
const Set<String> kNoLengthTypes = {
  'bool',
  'boolean',
  'int',
  'int2',
  'int4',
  'int8',
  'integer',
  'smallint',
  'mediumint',
  'bigint',
  'tinyint',
  'serial',
  'smallserial',
  'bigserial',
  'uuid',
  'date',
  'money',
  'text',
  'tinytext',
  'mediumtext',
  'longtext',
  'json',
  'jsonb',
  'xml',
  'bytea',
  'blob',
  'tinyblob',
  'mediumblob',
  'longblob',
  'inet',
  'cidr',
  'macaddr',
  'real',
  'double precision',
  'point',
  'line',
  'lseg',
  'box',
  'path',
  'polygon',
  'circle',
  'tsvector',
  'tsquery',
};

/// MySQL 系类型修饰符(出现在类型名之后,如 `int unsigned` / `decimal(10,2) zerofill`)。
/// 设计器把修饰符与基础类型同存于 [DesignColumn.type],渲染时由 [DesignColumn.fullType]
/// 重新放到长度之后,避免 `unsigned` 被静默丢弃而改变列的符号性。
const Set<String> kTypeModifiers = {'unsigned', 'signed', 'zerofill'};

/// 类型修饰符拆分结果:基础类型名 + 修饰符(小写,空串 = 无)。
typedef TypeModifierSplit = ({String base, String modifier});

/// 从类型名中分离修饰符:`int unsigned` → `(base: int, modifier: unsigned)`。
/// 大小写不敏感,基础类型名保留原样(供 DDL 输出)。
TypeModifierSplit splitTypeModifier(String type) {
  final parts = type.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  final mods = <String>[];
  final words = <String>[];
  for (final p in parts) {
    if (kTypeModifiers.contains(p.toLowerCase())) {
      mods.add(p.toLowerCase());
    } else {
      words.add(p);
    }
  }
  return (base: words.join(' '), modifier: mods.join(' '));
}

/// 整数类型的位宽(仅用于「长度」列的信息性展示;不参与 DDL 渲染)。
/// 返回 null 表示该类型有真实的长度 / 精度语义。
String? bitWidthOf(String type) {
  switch (splitTypeModifier(type).base.toLowerCase()) {
    case 'int2':
    case 'smallint':
    case 'smallserial':
      return '16';
    case 'tinyint':
      return '8';
    case 'mediumint':
      return '24';
    case 'int':
    case 'int4':
    case 'integer':
    case 'serial':
      return '32';
    case 'int8':
    case 'bigint':
    case 'bigserial':
      return '64';
    default:
      return null;
  }
}

/// 整数类型作为 IDENTITY 序列上限时的 MAXVALUE(空串 = 无法确定,留空由服务端取默认)。
String kIdentityMaxValue(String type) {
  switch (splitTypeModifier(type).base.toLowerCase()) {
    case 'int2':
    case 'smallint':
    case 'smallserial':
    case 'tinyint':
      return '32767';
    case 'int':
    case 'int4':
    case 'integer':
    case 'serial':
    case 'mediumint':
      return '2147483647';
    case 'int8':
    case 'bigint':
    case 'bigserial':
      return '9223372036854775807';
    default:
      return '';
  }
}

/// 字段(列)设计。类型以「基础类型 + 长度 + 小数点」分段录入,
/// 渲染 DDL 时拼为 `base(len[,decimal])`;长度 / 小数点留空则只输出基础类型。
/// 属于 [kNoLengthTypes] 的类型(如 int8 / text / uuid)本身无长度参数:
/// 其「长度」仅作信息性展示(位宽),不进入 [fullType]。
/// IDENTITY(界面「虚拟类型」)由 [identityMode] 及其序列选项描述。
class DesignColumn {
  DesignColumn({
    this.name = '',
    this.type = 'varchar',
    this.length = '255',
    this.decimal = '',
    this.notNull = false,
    this.primaryKey = false,
    this.autoIncrement = false,
    this.comment = '',
    this.defaultValue = '',
    this.collation = '',
    this.dimension = '',
    this.identityMode = '',
    this.identityIncrement = '',
    this.identityMinValue = '',
    this.identityMaxValue = '',
    this.identityStart = '',
    this.identityCache = '',
    this.identityCycle = false,
  });

  /// 列名
  String name;

  /// 基础类型名(如 varchar / int / decimal)
  String type;

  /// 长度(如 varchar(255) 的 255;非数值类型可留空)
  String length;

  /// 小数点精度(如 decimal(10,2) 的 2)
  String decimal;

  /// 是否 NOT NULL
  bool notNull;

  /// 是否主键
  bool primaryKey;

  /// 列注释
  String comment;

  /// 默认值(字符串需自行加引号,与既有建表约定一致)
  String defaultValue;

  /// 排序规则
  String collation;

  /// 维度(数组类型维数,PostgreSQL;生成 DDL 时拼为 `base[dim]`)
  String dimension;

  /// 自增(仅 MySQL / MariaDB 生成 AUTO_INCREMENT)
  bool autoIncrement;

  /// IDENTITY 模式:空(无) / `ALWAYS` / `BY DEFAULT`(界面「虚拟类型」)
  /// PostgreSQL 生成 GENERATED … AS IDENTITY;MySQL 降级为 AUTO_INCREMENT;
  /// SQL Server 生成 IDENTITY(seed, increment);SQLite / Access 忽略。
  String identityMode;

  /// IDENTITY 序列选项(空 = 不输出该子句,交由数据库默认)
  String identityIncrement;
  String identityMinValue;
  String identityMaxValue;
  String identityStart;
  String identityCache;

  /// IDENTITY 是否循环(CYCLE)
  bool identityCycle;

  /// 是否已启用 IDENTITY
  bool get hasIdentity => identityMode.trim().isNotEmpty;

  /// 渲染到 DDL 的完整类型文本。
  ///
  /// [type] 允许携带 MySQL 修饰符(如 `int unsigned`):修饰符渲染在长度
  /// 之后(`int(11) unsigned`),否则会得到非法的 `int unsigned(11)`。
  String get fullType {
    final mod = splitTypeModifier(type);
    final t = mod.base;
    if (t.isEmpty) return '';
    final tail = mod.modifier.isEmpty ? '' : ' ${mod.modifier}';
    // 无长度参数的类型:长度 / 小数点仅作界面信息展示,不拼接
    if (kNoLengthTypes.contains(t.toLowerCase())) return '$t$tail';
    final len = length.trim();
    final dec = decimal.trim();
    if (len.isEmpty) return dec.isEmpty ? '$t$tail' : '$t($dec)$tail';
    return dec.isEmpty ? '$t($len)$tail' : '$t($len,$dec)$tail';
  }

  /// 深拷贝:「设计表」以原始快照为基线生成 ALTER 差异,不能与编辑中的对象共享引用
  DesignColumn copy() => DesignColumn(
        name: name,
        type: type,
        length: length,
        decimal: decimal,
        notNull: notNull,
        primaryKey: primaryKey,
        autoIncrement: autoIncrement,
        comment: comment,
        defaultValue: defaultValue,
        collation: collation,
        dimension: dimension,
        identityMode: identityMode,
        identityIncrement: identityIncrement,
        identityMinValue: identityMinValue,
        identityMaxValue: identityMaxValue,
        identityStart: identityStart,
        identityCache: identityCache,
        identityCycle: identityCycle,
      );
}

/// 索引字段项(对应「选择数据表字段」弹窗的一行)。
///
/// 各选项留空即不输出对应子句(交由数据库默认),因此未用过弹窗的既有设计
/// 数据(含驱动反查结果)生成的 DDL 与从前完全一致。
/// 子句仅 PostgreSQL 家族输出;其余类型按裸字段名渲染。
class DesignIndexColumn {
  DesignIndexColumn({
    this.name = '',
    this.collationSchema = '',
    this.collation = '',
    this.opClassSchema = '',
    this.opClass = '',
    this.order = '',
    this.nullsOrder = '',
  });

  /// 字段名
  String name;

  /// 排序规则模式(排序规则所在 schema,界面「排序规则模式」)
  String collationSchema;

  /// 排序规则(界面「排序规则」)
  String collation;

  /// 运算符类别模式(opclass 所在 schema,界面「运算符类别模式」)
  String opClassSchema;

  /// 运算符类别(界面「运算符类别」)
  String opClass;

  /// 排序顺序:空 / ASC / DESC(界面「排序顺序」)
  String order;

  /// Nulls 排序:空 / FIRST / LAST(界面「Nulls 排序」)
  String nullsOrder;

  /// 是否携带任何需要落进 DDL 的选项
  bool get hasOptions =>
      collation.trim().isNotEmpty ||
      opClass.trim().isNotEmpty ||
      order.trim().isNotEmpty ||
      nullsOrder.trim().isNotEmpty;

  DesignIndexColumn copy() => DesignIndexColumn(
        name: name,
        collationSchema: collationSchema,
        collation: collation,
        opClassSchema: opClassSchema,
        opClass: opClass,
        order: order,
        nullsOrder: nullsOrder,
      );
}

/// 索引设计。字段以逗号分隔(支持多列),索引方法留空用数据库默认。
class DesignIndex {
  DesignIndex({
    this.name = '',
    this.columns = '',
    this.method = '',
    this.unique = false,
    this.concurrent = false,
    this.comment = '',
    this.tablespace = '',
    this.fillFactor = '',
  });

  String name;
  String columns;
  String method;
  bool unique;
  bool concurrent;
  String comment;
  String tablespace;
  String fillFactor;

  /// 索引字段项(由「选择数据表字段」弹窗写入)。非空时 DDL 按本列表输出
  /// 每项的 COLLATE / 运算符类别 / 排序顺序 / Nulls 排序;为空时按 [columns] 输出裸字段名。
  final List<DesignIndexColumn> columnItems = [];

  List<String> get columnList =>
      columns.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  /// 弹窗确认后把字段项回写成逗号串(网格「字段」格与差异比较都以 [columns] 为准)
  void applyColumnItems() {
    columns = columnItems
        .map((e) => e.name.trim())
        .where((e) => e.isNotEmpty)
        .join(', ');
  }

  DesignIndex copy() => DesignIndex(
        name: name,
        columns: columns,
        method: method,
        unique: unique,
        concurrent: concurrent,
        comment: comment,
        tablespace: tablespace,
        fillFactor: fillFactor,
      )..columnItems.addAll(columnItems.map((e) => e.copy()));
}

/// 外键设计。
class DesignForeignKey {
  DesignForeignKey({
    this.name = '',
    this.columns = '',
    this.refSchema = '',
    this.refTable = '',
    this.refColumns = '',
    this.onDelete = 'NO ACTION',
    this.onUpdate = 'NO ACTION',
    this.matchAll = false,
    this.deferrable = '',
    this.deferred = '',
    this.comment = '',
  });

  String name;
  String columns;
  String refSchema;
  String refTable;
  String refColumns;

  /// 删除时行为:NO ACTION / RESTRICT / CASCADE / SET NULL / SET DEFAULT
  String onDelete;

  /// 更新时行为:同上
  String onUpdate;

  /// 是否符合全部(MATCH FULL;仅 PostgreSQL 生成)
  bool matchAll;

  /// 可延迟:空 / YES / NO
  String deferrable;

  /// 延迟:空 / YES / NO
  String deferred;

  /// 约束注释(仅 PostgreSQL 生成 COMMENT ON CONSTRAINT)
  String comment;

  List<String> get columnList =>
      columns.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  List<String> get refColumnList =>
      refColumns.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  DesignForeignKey copy() => DesignForeignKey(
        name: name,
        columns: columns,
        refSchema: refSchema,
        refTable: refTable,
        refColumns: refColumns,
        onDelete: onDelete,
        onUpdate: onUpdate,
        matchAll: matchAll,
        deferrable: deferrable,
        deferred: deferred,
        comment: comment,
      );
}

/// 唯一键设计。
class DesignUniqueKey {
  DesignUniqueKey({
    this.name = '',
    this.columns = '',
    this.comment = '',
    this.tablespace = '',
    this.fillFactor = '',
    this.deferrable = '',
    this.deferred = '',
  });

  String name;
  String columns;
  String comment;
  String tablespace;
  String fillFactor;
  String deferrable;
  String deferred;

  List<String> get columnList =>
      columns.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  DesignUniqueKey copy() => DesignUniqueKey(
        name: name,
        columns: columns,
        comment: comment,
        tablespace: tablespace,
        fillFactor: fillFactor,
        deferrable: deferrable,
        deferred: deferred,
      );
}

/// 检查约束设计。
class DesignCheck {
  DesignCheck({this.name = '', this.expression = '', this.comment = ''});

  String name;
  String expression;
  String comment;

  DesignCheck copy() => DesignCheck(
      name: name, expression: expression, comment: comment);
}

/// 排除约束设计(仅 PostgreSQL 家族生成 EXCLUDE USING ...)。
class DesignExclude {
  DesignExclude({
    this.name = '',
    this.columns = '',
    this.method = 'gist',
    this.comment = '',
  });

  String name;
  String columns;
  String method;
  String comment;

  DesignExclude copy() =>
      DesignExclude(name: name, columns: columns, method: method, comment: comment);
}

/// 规则设计(仅 PostgreSQL 家族生成 CREATE RULE)。
class DesignRule {
  DesignRule({this.name = '', this.event = 'INSERT', this.statement = '', this.comment = ''});

  String name;

  /// 事件:INSERT / UPDATE / DELETE / SELECT
  String event;
  String statement;
  String comment;

  DesignRule copy() => DesignRule(
      name: name, event: event, statement: statement, comment: comment);
}

/// 触发器设计。触发函数 / 参数 / 当 为 PostgreSQL 形态;
/// 生成 DDL 仅 PostgreSQL 家族,其余类型在 SQL 预览中以注释说明。
class DesignTrigger {
  DesignTrigger({
    this.name = '',
    this.forEach = '行',
    this.timing = 'BEFORE',
    this.insert = false,
    this.update = false,
    this.delete = false,
    this.truncate = false,
    this.updateColumns = '',
    this.enable = true,
    this.comment = '',
    this.when = '',
    this.function = '',
    this.parameters = '',
    this.deferrable = '',
    this.deferred = '',
  });

  String name;

  /// 行 / 语句(FOR EACH ROW / FOR EACH STATEMENT)
  String forEach;

  /// BEFORE / AFTER / INSTEAD OF
  String timing;

  bool insert;
  bool update;
  bool delete;
  bool truncate;

  /// 更新字段(UPDATE OF c1, c2)
  String updateColumns;
  bool enable;
  String comment;

  /// WHEN 条件(不带 WHEN 关键字)
  String when;

  /// 触发函数(PostgreSQL 形态)
  String function;

  /// 函数参数(如 NEW.id, 空则不输出括号)
  String parameters;

  /// 可延迟(界面「约束」子页):YES 生成 CREATE CONSTRAINT TRIGGER … DEFERRABLE
  String deferrable;

  /// 延迟:仅在 [deferrable] 为 YES 时生成 INITIALLY DEFERRED(否则 PG 语法非法)
  String deferred;

  DesignTrigger copy() => DesignTrigger(
        name: name,
        forEach: forEach,
        timing: timing,
        insert: insert,
        update: update,
        delete: delete,
        truncate: truncate,
        updateColumns: updateColumns,
        enable: enable,
        comment: comment,
        when: when,
        function: function,
        parameters: parameters,
        deferrable: deferrable,
        deferred: deferred,
      );
}

/// 设计器下拉候选:由驱动从数据库系统目录读出的可选项(仍可手输)。
///
/// 只承载候选文本,不参与 DDL 生成;驱动没有对应系统目录时返回
/// [DesignCandidates.empty],界面退化为纯输入框。
class DesignCandidates {
  const DesignCandidates({
    this.collations = const [],
    this.opClasses = const [],
    this.tablespaces = const [],
  });

  /// 排序规则名(`pg_collation` / 各库等价目录)
  final List<String> collations;

  /// 运算符类别名(`pg_opclass`)
  final List<String> opClasses;

  /// 表空间名(`pg_tablespace`)
  final List<String> tablespaces;

  static const DesignCandidates empty = DesignCandidates();
}

/// 新建表设计器的完整设计数据。
class DesignTable {
  DesignTable();

  /// 表名(默认 Untitled,与参考工具一致,保存前可改)
  String name = 'Untitled';

  /// 目标模式(由打开设计器时的树上下文决定,PostgreSQL 等有模式层的类型使用)
  String? schema;

  final List<DesignColumn> columns = [];
  final List<DesignIndex> indexes = [];
  final List<DesignForeignKey> foreignKeys = [];
  final List<DesignUniqueKey> uniqueKeys = [];
  final List<DesignCheck> checks = [];
  final List<DesignExclude> excludes = [];
  final List<DesignRule> rules = [];
  final List<DesignTrigger> triggers = [];

  /// 表注释(注释标签页)
  String tableComment = '';

  /// 选项:填充因子(%) / 表空间(PostgreSQL 等生成 WITH / TABLESPACE)
  String fillFactor = '';
  String tablespace = '';

  /// 表选项(仅新建表生成,均为 PostgreSQL 家族专属):不记录(UNLOGGED) /
  /// 所有者(补一条 ALTER … OWNER TO) / 继承自(INHERITS) / 集群(CLUSTER … USING)。
  bool unlogged = false;
  String owner = '';

  /// 父表列表(逗号分隔,可带 schema 前缀)
  String inherits = '';

  /// 集群索引名
  String cluster = '';

  /// 主键约束名。新建模式留空(由 DDL 按各方言约定命名);「设计表」模式
  /// 由驱动反查填入真名——ALTER 删主键必须按真名 DROP CONSTRAINT。
  String pkName = '';

  /// 深拷贝为一份独立快照(用作「设计表」的原始基线)。
  /// 列表与元素均重新构造,编辑中的 [columns] 变化不会污染基线。
  DesignTable snapshot() {
    final s = DesignTable()
      ..name = name
      ..schema = schema
      ..tableComment = tableComment
      ..fillFactor = fillFactor
      ..tablespace = tablespace
      ..unlogged = unlogged
      ..owner = owner
      ..inherits = inherits
      ..cluster = cluster
      ..pkName = pkName;
    s.columns.addAll(columns.map((e) => e.copy()));
    s.indexes.addAll(indexes.map((e) => e.copy()));
    s.foreignKeys.addAll(foreignKeys.map((e) => e.copy()));
    s.uniqueKeys.addAll(uniqueKeys.map((e) => e.copy()));
    s.checks.addAll(checks.map((e) => e.copy()));
    s.excludes.addAll(excludes.map((e) => e.copy()));
    s.rules.addAll(rules.map((e) => e.copy()));
    s.triggers.addAll(triggers.map((e) => e.copy()));
    return s;
  }
}

/// 校验结果:ok 为是否通过,error 携带原因。
class DesignValidate {
  const DesignValidate(this.ok, [this.error]);
  final bool ok;
  final String? error;
}

/// 按数据库类型方言生成建表 DDL 的工具。
/// 标识符引用 / 默认值规则与 AppState 既有建表逻辑保持一致。
class DdlBuilder {
  DdlBuilder._();

  static bool isPgLike(String typeId) => kPgLikeTypes.contains(typeId);
  static bool isMysqlLike(String typeId) => kMysqlLikeTypes.contains(typeId);
  static bool isSqlServerLike(String typeId) => kSqlServerLikeTypes.contains(typeId);

  /// 标识符引用:PostgreSQL / SQLite 用双引号,SQL Server / Access 用方括号,
  /// MySQL / MariaDB 用反引号。
  static String ident(String typeId, String name) {
    switch (typeId) {
      case 'postgresql':
      case 'aliyun-rds-postgres':
      case 'aliyun-polardb-postgres':
      case 'aliyun-oceanbase-postgres':
      case 'sqlite':
        return '"${name.replaceAll('"', '""')}"';
      case 'sqlserver':
      case 'aliyun-rds-sqlserver':
      case 'access':
        return '[${name.replaceAll(']', ']]')}]';
      default: // mysql / mariadb
        return '`${name.replaceAll('`', '``')}`';
    }
  }

  /// 带模式限定的标识符;模式为空或无模式层的类型退化为普通标识符。
  static String qualified(String typeId, String? schema, String name) {
    final id = ident(typeId, name);
    if (schema == null || schema.isEmpty) return id;
    if (isPgLike(typeId) || typeId == 'sqlite' || isSqlServerLike(typeId) || typeId == 'access') {
      return '${ident(typeId, schema)}.$id';
    }
    return id;
  }

  /// 单引号字符串字面量
  static String lit(String s) => "'${s.replaceAll("'", "''")}'";

  /// DEFAULT 值智能渲染:数字 / NULL / 布尔 / 关键字 / 函数调用(含括号)/
  /// 已自带引号的值原样输出;其余按字符串字面量加引号(自动转义内部单引号)。
  static String _defaultLiteral(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return '';
    if (_looksRawDefault(v)) return v;
    return lit(v);
  }

  static bool _looksRawDefault(String v) {
    if (v.startsWith("'") && v.endsWith("'")) return true; // 用户已自行加引号
    if (v.startsWith('"') && v.endsWith('"')) return true;
    if (RegExp(
      r'^(null|true|false|current_timestamp|current_date|current_time|current_user|session_user|localtime|localtimestamp)\b',
      caseSensitive: false,
    ).hasMatch(v)) {
      return true;
    }
    if (RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)$').hasMatch(v)) return true; // 数字
    if (v.contains('(') || v.startsWith('(')) return true; // 函数调用 / 表达式
    // 位串 / 十六进制 / 字符集 introducer 形式的字面量:`b'1'` / `x'FF'` / `N'abc'`
    if (RegExp(r"^(?:[bBxXnN]|_[a-zA-Z0-9]+)?'").hasMatch(v)) return true;
    return false;
  }

  /// 校验设计数据;不合规返回原因,可通过时 ok=true。
  static DesignValidate validate(DesignTable d) {
    final tableName = d.name.trim();
    if (tableName.isEmpty) return const DesignValidate(false, '表名不能为空');
    if (d.columns.isEmpty) return const DesignValidate(false, '至少需要一列');
    for (var i = 0; i < d.columns.length; i++) {
      final c = d.columns[i];
      if (c.name.trim().isEmpty) return const DesignValidate(false, '存在未命名的列,请补全列名');
      if (c.fullType.isEmpty) {
        return DesignValidate(false, '第 ${i + 1} 列的「类型」不能为空');
      }
      if (c.hasIdentity) {
        const labels = ['递增', '最小', '最大', '开始值', '缓存'];
        final values = [
          c.identityIncrement,
          c.identityMinValue,
          c.identityMaxValue,
          c.identityStart,
          c.identityCache,
        ];
        for (var k = 0; k < labels.length; k++) {
          final v = values[k].trim();
          if (v.isEmpty) continue; // 留空 = 交由数据库取默认
          if (!RegExp(r'^[+-]?\d+$').hasMatch(v)) {
            return DesignValidate(false, '第 ${i + 1} 列的「${labels[k]}」必须是整数');
          }
        }
      }
    }
    final seenCols = <String>{};
    for (final c in d.columns) {
      if (!seenCols.add(c.name.trim().toLowerCase())) {
        return DesignValidate(false, '存在重复的列名: ${c.name.trim()}');
      }
    }
    for (final fk in d.foreignKeys) {
      if (fk.columnList.isEmpty) {
        return DesignValidate(false, '外键「${_nameOr(fk.name, '未命名')}」未指定字段');
      }
      if (fk.refTable.trim().isEmpty) {
        return DesignValidate(false, '外键「${_nameOr(fk.name, '未命名')}」未指定被引用的表');
      }
      if (fk.refColumnList.isEmpty) {
        return DesignValidate(false, '外键「${_nameOr(fk.name, '未命名')}」未指定被引用的字段');
      }
    }
    for (final idx in d.indexes) {
      if (idx.columnList.isEmpty) {
        return DesignValidate(false, '索引「${_nameOr(idx.name, '未命名')}」未指定字段');
      }
    }
    for (final uk in d.uniqueKeys) {
      if (uk.columnList.isEmpty) {
        return DesignValidate(false, '唯一键「${_nameOr(uk.name, '未命名')}」未指定字段');
      }
    }
    for (final ck in d.checks) {
      if (ck.expression.trim().isEmpty) {
        return DesignValidate(false, '检查「${_nameOr(ck.name, '未命名')}」未指定条件');
      }
    }
    for (final tr in d.triggers) {
      if (tr.name.trim().isEmpty) return const DesignValidate(false, '存在未命名的触发器');
      if (tr.function.trim().isEmpty) {
        return DesignValidate(false, '触发器「${tr.name}」未指定触发函数');
      }
    }
    return const DesignValidate(true);
  }

  static String _nameOr(String name, String fallback) => name.trim().isEmpty ? fallback : name.trim();

  /// 生成完整建表脚本(按语句拆分,便于逐条执行 / 预览)。
  static List<String> buildStatements(DesignTable d, String typeId) {
    final stmts = <String>[];
    stmts.add(buildCreateTable(d, typeId));

    for (final idx in d.indexes) {
      stmts.add(buildCreateIndex(d, typeId, idx));
    }
    for (final rule in d.rules) {
      if (isPgLike(typeId)) stmts.add(buildCreateRule(d, typeId, rule));
    }
    for (final tr in d.triggers) {
      if (isPgLike(typeId)) {
        stmts.add(buildCreateTrigger(d, typeId, tr));
        if (!tr.enable) {
          stmts.add('ALTER TABLE ${_qualifiedTable(d, typeId)} DISABLE TRIGGER ${ident(typeId, tr.name.trim())};');
        }
      }
    }
    // 表所有者 / 集群:PG 无内联子句,按 Navicat 做法补独立语句(集群需索引已建好)
    if (isPgLike(typeId) && d.owner.trim().isNotEmpty) {
      stmts.add('ALTER TABLE ${_qualifiedTable(d, typeId)} OWNER TO ${ident(typeId, d.owner.trim())};');
    }
    if (isPgLike(typeId) && d.cluster.trim().isNotEmpty) {
      stmts.add('CLUSTER ${_qualifiedTable(d, typeId)} USING ${ident(typeId, d.cluster.trim())};');
    }
    // 注释:MySQL / MariaDB 已内联进 CREATE TABLE,其余类型(仅 PostgreSQL)生成 COMMENT ON
    if (!isMysqlLike(typeId)) {
      if (d.tableComment.trim().isNotEmpty) {
        stmts.add('COMMENT ON TABLE ${_qualifiedTable(d, typeId)} IS ${lit(d.tableComment.trim())};');
      }
      for (final c in d.columns) {
        if (c.comment.trim().isNotEmpty) {
          stmts.add('COMMENT ON COLUMN ${_qualifiedTable(d, typeId)}.${ident(typeId, c.name.trim())} IS ${lit(c.comment.trim())};');
        }
      }
      if (isPgLike(typeId)) {
        for (final fk in d.foreignKeys) {
          if (fk.comment.trim().isEmpty) continue;
          stmts.add('COMMENT ON CONSTRAINT ${ident(typeId, _fkName(fk, d))} '
              'ON ${_qualifiedTable(d, typeId)} IS ${lit(fk.comment.trim())};');
        }
        // 索引 / 唯一键注释:PG 无内联子句,靠 COMMENT ON 补独立语句
        for (final idx in d.indexes) {
          if (idx.comment.trim().isEmpty) continue;
          stmts.add('COMMENT ON INDEX '
              '${qualified(typeId, d.schema, _indexName(idx, d))} '
              'IS ${lit(idx.comment.trim())};');
        }
        for (final uk in d.uniqueKeys) {
          if (uk.comment.trim().isEmpty) continue;
          stmts.add('COMMENT ON CONSTRAINT '
              '${ident(typeId, _uniqueName(uk, d))} '
              'ON ${_qualifiedTable(d, typeId)} IS ${lit(uk.comment.trim())};');
        }
        // 检查 / 排除约束同为 pg_constraint 对象,注释走 COMMENT ON CONSTRAINT
        for (final ck in d.checks) {
          if (ck.comment.trim().isEmpty) continue;
          stmts.add('COMMENT ON CONSTRAINT '
              '${ident(typeId, _checkName(ck, d))} '
              'ON ${_qualifiedTable(d, typeId)} IS ${lit(ck.comment.trim())};');
        }
        for (final ex in d.excludes) {
          if (ex.comment.trim().isEmpty) continue;
          stmts.add('COMMENT ON CONSTRAINT '
              '${ident(typeId, _excludeName(ex, d))} '
              'ON ${_qualifiedTable(d, typeId)} IS ${lit(ex.comment.trim())};');
        }
      }
    }
    return stmts;
  }

  /// 生成「SQL 预览」文本(语句以换行拼接)
  static String buildPreview(DesignTable d, String typeId) =>
      buildStatements(d, typeId).join('\n');

  static String _qualifiedTable(DesignTable d, String typeId) =>
      qualified(typeId, d.schema, d.name.trim());

  // ── CREATE TABLE ─────────────────────────────────────────────

  /// 单列定义片段(不含缩进):`"id" int8 GENERATED ... AS IDENTITY (...) NOT NULL DEFAULT ...`。
  ///
  /// CREATE TABLE 内联列、ALTER TABLE `ADD COLUMN` 与 `MODIFY COLUMN` 共用本方法,
  /// 避免同一方言的列语法在两条路径上各自维护而漂移。
  /// [inlinePrimaryKey] 为 true 时内联 `PRIMARY KEY`(单列主键情形);
  /// [inlineComment] 为 false 时不输出 MySQL 的列内联注释。
  static String columnDefSql(DesignColumn c, String typeId,
      {bool inlinePrimaryKey = false, bool inlineComment = true}) {
    var typeText = c.fullType;
    // PostgreSQL 数组维度:base[len][dim]
    final dim = c.dimension.trim();
    if (dim.isNotEmpty && isPgLike(typeId)) typeText += '[$dim]';
    final buf = StringBuffer('${ident(typeId, c.name.trim())} $typeText');
    if (c.collation.trim().isNotEmpty &&
        (isPgLike(typeId) || isMysqlLike(typeId))) {
      buf.write(' COLLATE ${ident(typeId, c.collation.trim())}');
    }
    // IDENTITY 子句:PG 语法要求位于列约束(NOT NULL / DEFAULT)之前
    final identity = _identityClause(c, typeId);
    if (identity.isNotEmpty) buf.write(' $identity');
    if (c.notNull) buf.write(' NOT NULL');
    if (c.defaultValue.trim().isNotEmpty) {
      buf.write(' DEFAULT ${_defaultLiteral(c.defaultValue.trim())}');
    }
    // MySQL / MariaDB 自增(需配合键使用,交由用户保证);
    // 「虚拟类型」在该方言下降级为 AUTO_INCREMENT,与手工勾选等价
    if (isMysqlLike(typeId) && (c.autoIncrement || c.hasIdentity)) {
      buf.write(' AUTO_INCREMENT');
    }
    if (inlinePrimaryKey) buf.write(' PRIMARY KEY');
    if (inlineComment && isMysqlLike(typeId) && c.comment.trim().isNotEmpty) {
      buf.write(' COMMENT ${lit(c.comment.trim())}');
    }
    return buf.toString();
  }

  /// 唯一键约束片段(不含缩进);无字段时返回空串。
  /// [d] 仅用于自动命名(`uq_<表名>_<首列>`)。
  static String uniqueKeyClause(DesignUniqueKey uk, DesignTable d, String typeId) {
    final cols = uk.columnList;
    if (cols.isEmpty) return '';
    final name = uk.name.trim().isEmpty
        ? 'uq_${d.name.trim()}_${cols.first}'
        : uk.name.trim();
    final buf = StringBuffer(
        'CONSTRAINT ${ident(typeId, name)} UNIQUE (${cols.map((n) => ident(typeId, n)).join(', ')})');
    if (isPgLike(typeId)) buf.write(_deferrableClause(uk.deferrable, uk.deferred));
    return buf.toString();
  }

  /// 检查约束片段(不含缩进);无条件时返回空串。
  /// [autoSuffix] 用于无名检查的序号兜底命名(与 CREATE 路径一致)。
  static String checkClause(DesignCheck ck, DesignTable d, String typeId,
      {int autoSuffix = 1}) {
    if (ck.expression.trim().isEmpty) return '';
    final name = ck.name.trim().isEmpty
        ? 'ck_${d.name.trim()}_$autoSuffix'
        : ck.name.trim();
    return 'CONSTRAINT ${ident(typeId, name)} CHECK (${ck.expression.trim()})';
  }

  /// 外键约束片段(不含缩进);信息不全时返回空串。
  static String foreignKeyClause(
      DesignForeignKey fk, DesignTable d, String typeId) {
    final cols = fk.columnList;
    final refCols = fk.refColumnList;
    if (cols.isEmpty || fk.refTable.trim().isEmpty || refCols.isEmpty) return '';
    final name = fk.name.trim().isEmpty
        ? 'fk_${d.name.trim()}_${cols.first}'
        : fk.name.trim();
    final refTable = fk.refSchema.trim().isNotEmpty
        ? qualified(typeId, fk.refSchema.trim(), fk.refTable.trim())
        : qualified(typeId, d.schema, fk.refTable.trim());
    final buf = StringBuffer(
        'CONSTRAINT ${ident(typeId, name)} FOREIGN KEY (${cols.map((n) => ident(typeId, n)).join(', ')}) REFERENCES $refTable (${refCols.map((n) => ident(typeId, n)).join(', ')})');
    if (isPgLike(typeId) && fk.matchAll) buf.write(' MATCH FULL');
    final od = fk.onDelete.trim().toUpperCase();
    if (od.isNotEmpty && od != 'NO ACTION') buf.write(' ON DELETE $od');
    final ou = fk.onUpdate.trim().toUpperCase();
    if (ou.isNotEmpty && ou != 'NO ACTION') buf.write(' ON UPDATE $ou');
    if (isPgLike(typeId)) buf.write(_deferrableClause(fk.deferrable, fk.deferred));
    return buf.toString();
  }

  /// 主键列名清单(按 [pkOrdinals] 的列序)。
  static List<String> pkColumnNames(DesignTable d) => [
        for (final c in d.columns)
          if (c.primaryKey) c.name.trim(),
      ];

  static String buildCreateTable(DesignTable d, String typeId) {
    final lines = <String>[];
    final pkCols = pkColumnNames(d);

    for (final c in d.columns) {
      lines.add('  ${columnDefSql(c, typeId,
          inlinePrimaryKey: c.primaryKey && pkCols.length == 1)}');
    }

    // 表级约束:多列主键 / 唯一键 / 检查 / 排除(PG) / 外键
    if (pkCols.length > 1) {
      lines.add('  PRIMARY KEY (${pkCols.map((n) => ident(typeId, n)).join(', ')})');
    }
    var checkNo = 0;
    for (final uk in d.uniqueKeys) {
      final clause = uniqueKeyClause(uk, d, typeId);
      if (clause.isEmpty) continue;
      lines.add('  $clause');
    }
    for (final ck in d.checks) {
      final clause = checkClause(ck, d, typeId, autoSuffix: ++checkNo);
      if (clause.isEmpty) continue;
      lines.add('  $clause');
    }
    for (final ex in d.excludes) {
      if (!isPgLike(typeId)) continue;
      if (ex.columns.trim().isEmpty) continue;
      final name = _excludeName(ex, d);
      final method = ex.method.trim().isEmpty ? 'gist' : ex.method.trim();
      lines.add('  CONSTRAINT ${ident(typeId, name)} EXCLUDE USING $method (${ex.columns.trim()})');
    }
    for (final fk in d.foreignKeys) {
      final clause = foreignKeyClause(fk, d, typeId);
      if (clause.isEmpty) continue;
      lines.add('  $clause');
    }

    // 表选项(PostgreSQL / SQL Server 的 WITH + TABLESPACE;MySQL 表注释内联)
    final suffix = <String>[];
    final ff = d.fillFactor.trim();
    if (ff.isNotEmpty) {
      if (isPgLike(typeId)) suffix.add('WITH (fillfactor = $ff)');
      if (isSqlServerLike(typeId)) suffix.add('WITH (FILLFACTOR = $ff)');
    }
    final ts = d.tablespace.trim();
    if (ts.isNotEmpty && isPgLike(typeId)) suffix.add('TABLESPACE ${ident(typeId, ts)}');
    if (isMysqlLike(typeId) && d.tableComment.trim().isNotEmpty) {
      suffix.add('COMMENT = ${lit(d.tableComment.trim())}');
    }
    final tail = suffix.isEmpty ? '' : ' ${suffix.join(' ')}';
    // UNLOGGED 位于关键字前,INHERITS 位于字段列表后、WITH 前(PG 语法顺序)
    final unlogged = d.unlogged && isPgLike(typeId) ? 'UNLOGGED ' : '';
    final inherits =
        isPgLike(typeId) && d.inherits.trim().isNotEmpty ? ' INHERITS (${_inheritRefs(d, typeId)})' : '';

    return 'CREATE ${unlogged}TABLE ${_qualifiedTable(d, typeId)} '
        '(\n${lines.join(',\n')}\n)$inherits$tail;';
  }

  /// INHERITS 父表引用:逗号分隔,单项可带 `schema.table` 前缀
  static String _inheritRefs(DesignTable d, String typeId) {
    return d.inherits.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).map((e) {
      final parts = e.split('.');
      if (parts.length < 2) return ident(typeId, e);
      final table = parts.removeLast().trim();
      return '${parts.map((s) => ident(typeId, s.trim())).join('.')}.${ident(typeId, table)}';
    }).join(', ');
  }

  /// 主键序号(列 → 在 PRIMARY KEY 中的顺序,1 起)。
  /// 界面「键」列的 🔑n 与表级 `PRIMARY KEY (...)` 列序共用本结果,保证一致。
  static Map<DesignColumn, int> pkOrdinals(DesignTable d) {
    final map = <DesignColumn, int>{};
    var n = 0;
    for (final c in d.columns) {
      if (c.primaryKey) map[c] = ++n;
    }
    return map;
  }

  /// IDENTITY 子句(按方言):PostgreSQL 完整生成 GENERATED … AS IDENTITY
  /// 及其序列选项(仅输出非空项);SQL Server 生成 IDENTITY(seed,increment);
  /// MySQL / MariaDB 由 AUTO_INCREMENT 分支承担,SQLite / Access 不生成。
  static String _identityClause(DesignColumn c, String typeId) {
    final mode = c.identityMode.trim().toUpperCase();
    if (mode.isEmpty) return '';
    if (isPgLike(typeId)) {
      final kw = mode == 'ALWAYS' ? 'ALWAYS' : 'BY DEFAULT';
      final opts = <String>[
        if (c.identityIncrement.trim().isNotEmpty) 'INCREMENT BY ${c.identityIncrement.trim()}',
        if (c.identityMinValue.trim().isNotEmpty) 'MINVALUE ${c.identityMinValue.trim()}',
        if (c.identityMaxValue.trim().isNotEmpty) 'MAXVALUE ${c.identityMaxValue.trim()}',
        if (c.identityStart.trim().isNotEmpty) 'START WITH ${c.identityStart.trim()}',
        if (c.identityCache.trim().isNotEmpty) 'CACHE ${c.identityCache.trim()}',
        if (c.identityCycle) 'CYCLE',
      ];
      final base = 'GENERATED $kw AS IDENTITY';
      return opts.isEmpty ? base : '$base (${opts.join(' ')})';
    }
    if (isSqlServerLike(typeId)) {
      final seed = c.identityStart.trim().isEmpty ? '1' : c.identityStart.trim();
      final inc = c.identityIncrement.trim().isEmpty ? '1' : c.identityIncrement.trim();
      return 'IDENTITY($seed,$inc)';
    }
    return '';
  }

  /// 可延迟 / 延迟 子句(仅 PostgreSQL):DEFERRABLE / NOT DEFERRABLE + INITIALLY DEFERRED
  static String _deferrableClause(String deferrable, String deferred) {
    final def = deferrable.trim().toUpperCase();
    final dff = deferred.trim().toUpperCase();
    final buf = StringBuffer();
    if (def == 'YES') {
      buf.write(' DEFERRABLE');
    } else if (def == 'NO') {
      buf.write(' NOT DEFERRABLE');
    }
    if (dff == 'YES') {
      buf.write(' INITIALLY DEFERRED');
    } else if (dff == 'NO') {
      buf.write(' INITIALLY IMMEDIATE');
    }
    return buf.toString();
  }

  // ── CREATE INDEX ─────────────────────────────────────────────

  static String buildCreateIndex(DesignTable d, String typeId, DesignIndex idx) {
    final cols = idx.columnList;
    // 无名项统一走 `_indexName`(它对空字段做了兼容,不重复实现)
    final name = _indexName(idx, d);
    final buf = StringBuffer('CREATE ');
    final method = idx.method.trim();
    final lowerMethod = method.toLowerCase();
    // MySQL 的 FULLTEXT / SPATIAL 是**索引类型关键字**,必须紧跟 CREATE 之后;
    // 尾部 USING 只接受 BTREE / HASH,写成 `... USING fulltext` 会 1064。
    final typeKeyword =
        isMysqlLike(typeId) && (lowerMethod == 'fulltext' || lowerMethod == 'spatial')
            ? lowerMethod
            : null;
    if (typeKeyword != null) {
      // MySQL 语法里 UNIQUE 与 FULLTEXT/SPATIAL 互斥,取类型关键字
      buf.write('${typeKeyword.toUpperCase()} ');
    } else if (idx.unique) {
      buf.write('UNIQUE ');
    }
    buf.write('INDEX ');
    if (idx.concurrent && isPgLike(typeId)) buf.write('CONCURRENTLY ');
    buf.write('${ident(typeId, name)} ON ${_qualifiedTable(d, typeId)}');
    // MySQL 的 `USING method` 位于字段列表之后,PG / SQL Server 位于之前
    if (method.isNotEmpty && !isMysqlLike(typeId)) buf.write(' USING $method');
    buf.write(' (${_indexColumnsSql(idx, cols, typeId)})');
    if (typeKeyword == null && method.isNotEmpty && isMysqlLike(typeId)) {
      buf.write(' USING $method');
    }
    final ff = idx.fillFactor.trim();
    if (ff.isNotEmpty) {
      if (isPgLike(typeId)) buf.write(' WITH (fillfactor = $ff)');
      if (isSqlServerLike(typeId)) buf.write(' WITH (FILLFACTOR = $ff)');
    }
    final ts = idx.tablespace.trim();
    if (ts.isNotEmpty && isPgLike(typeId)) buf.write(' TABLESPACE ${ident(typeId, ts)}');
    // MySQL 家族的索引注释内联在 CREATE INDEX 的 index_option 里
    final idxComment = idx.comment.trim();
    if (idxComment.isNotEmpty && isMysqlLike(typeId)) {
      buf.write(' COMMENT ${lit(idxComment)}');
    }
    return '$buf;';
  }

  /// 索引字段列表 → DDL。弹窗写入了 [DesignIndex.columnItems] 时逐项输出选项,
  /// 否则按逗号串输出裸字段名(驱动反查结果与手输内容走这条路径)。
  static String _indexColumnsSql(DesignIndex idx, List<String> cols, String typeId) {
    if (idx.columnItems.isEmpty) return cols.map((n) => ident(typeId, n)).join(', ');
    return idx.columnItems.map((e) => indexColumnSql(e, typeId)).join(', ');
  }

  /// 单个索引字段项 → DDL。PG 语法顺序:
  /// `字段 [COLLATE 排序规则] [运算符类别] [ASC|DESC] [NULLS FIRST|LAST]`;
  /// 非 PG 类型忽略全部选项(不生成非法子句)。
  static String indexColumnSql(DesignIndexColumn c, String typeId) {
    final name = ident(typeId, c.name.trim());
    if (!isPgLike(typeId)) return name;
    final parts = <String>[name];
    final collation = c.collation.trim();
    if (collation.isNotEmpty) {
      parts.add('COLLATE ${qualified(typeId, c.collationSchema.trim(), collation)}');
    }
    final opClass = c.opClass.trim();
    if (opClass.isNotEmpty) {
      parts.add(qualified(typeId, c.opClassSchema.trim(), opClass));
    }
    final order = c.order.trim().toUpperCase();
    if (order == 'ASC' || order == 'DESC') parts.add(order);
    final nulls = c.nullsOrder.trim().toUpperCase();
    if (nulls == 'FIRST' || nulls == 'LAST') parts.add('NULLS $nulls');
    return parts.join(' ');
  }

  // ── CREATE RULE(仅 PostgreSQL) ───────────────────────────────

  static String buildCreateRule(DesignTable d, String typeId, DesignRule rule) {
    final name = rule.name.trim().isEmpty
        ? 'rule_${d.name.trim()}_${rule.event.trim().toLowerCase()}'
        : rule.name.trim();
    final event = rule.event.trim().isEmpty ? 'INSERT' : rule.event.trim().toUpperCase();
    final stmt = rule.statement.trim().isEmpty ? 'NOTHING' : rule.statement.trim();
    return 'CREATE RULE ${ident(typeId, name)} AS ON $event TO ${_qualifiedTable(d, typeId)} DO INSTEAD $stmt;';
  }

  // ── CREATE TRIGGER(仅 PostgreSQL) ────────────────────────────

  static String buildCreateTrigger(DesignTable d, String typeId, DesignTrigger tr) {
    final events = <String>[
      if (tr.insert) 'INSERT',
      if (tr.update) 'UPDATE',
      if (tr.delete) 'DELETE',
      if (tr.truncate) 'TRUNCATE',
    ];
    final eventsText = events.isEmpty ? 'INSERT' : events.join(' OR ');
    final updateOf = tr.updateColumns.trim().isNotEmpty
        ? ' OF ${tr.updateColumns.split(',').map((n) => ident(typeId, n.trim())).join(', ')}'
        : '';
    final buf = StringBuffer('CREATE ');
    // 可延迟的触发器在 PG 里只能以约束触发器形式创建
    final deferAble = isPgLike(typeId) && tr.deferrable.trim().toUpperCase() == 'YES';
    if (deferAble) buf.write('CONSTRAINT ');
    buf.write('TRIGGER ${ident(typeId, tr.name.trim())} ');
    buf.write('${tr.timing.trim().toUpperCase()} $eventsText$updateOf ON ${_qualifiedTable(d, typeId)}');
    // DEFERRABLE 子句必须在 FOR EACH 之前(PG 语法)
    if (deferAble) {
      buf.write(' DEFERRABLE');
      if (tr.deferred.trim().toUpperCase() == 'YES') buf.write(' INITIALLY DEFERRED');
    }
    buf.write(tr.forEach.trim() == '语句' ? ' FOR EACH STATEMENT' : ' FOR EACH ROW');
    if (tr.when.trim().isNotEmpty) buf.write(' WHEN (${tr.when.trim()})');
    final fn = tr.function.trim();
    final params = tr.parameters.trim();
    buf.write(' EXECUTE FUNCTION ${_pgFunctionRef(fn, params)}');
    return '$buf;';
  }

  /// 触发函数引用:函数名可能带模式前缀,参数为空时不输出括号。
  static String _pgFunctionRef(String function, String params) {
    final parts = function.trim().split('.');
    String name;
    String? schema;
    if (parts.length >= 2) {
      schema = parts.sublist(0, parts.length - 1).join('.');
      name = parts.last.trim();
    } else {
      name = function.trim();
    }
    final quotedName = '"${name.replaceAll('"', '""')}"';
    final ref = schema == null || schema.isEmpty
        ? quotedName
        : '"${schema.replaceAll('"', '""')}".$quotedName';
    return params.isEmpty ? ref : '$ref($params)';
  }

  // ── 「设计表」保存:原始快照 vs 目标设计 → ALTER 差异 ────────

  /// 名称配对用的键(去空格 + 小写)
  static String _nameKey(String n) => n.trim().toLowerCase();

  static bool _sameText(String a, String b) => a.trim() == b.trim();

  static bool _sameList(List<String> a, List<String> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => a[i] == b[i]).every((e) => e);

  /// 列的类型文本(含 PostgreSQL 数组维度),用于差异比较与 TYPE 子句输出
  static String _columnTypeSql(DesignColumn c, String typeId) {
    var t = c.fullType;
    final dim = c.dimension.trim();
    if (dim.isNotEmpty && isPgLike(typeId)) t += '[$dim]';
    return t;
  }

  /// 列属性签名(不含列名):两侧签名相同即该列无需 ALTER。
  /// MySQL 的列注释内联在列定义里,故计入签名;其余方言走独立的注释语句。
  static String _columnSignature(DesignColumn c, String typeId) => [
        _columnTypeSql(c, typeId),
        c.collation.trim().toLowerCase(),
        c.notNull ? 'notnull' : 'null',
        c.defaultValue.trim(),
        c.identityMode.trim().toUpperCase(),
        c.identityIncrement.trim(),
        c.identityMinValue.trim(),
        c.identityMaxValue.trim(),
        c.identityStart.trim(),
        c.identityCache.trim(),
        c.identityCycle ? 'cycle' : '',
        c.autoIncrement ? 'auto_increment' : '',
        if (isMysqlLike(typeId)) c.comment.trim(),
      ].join('|');

  /// 索引配对名(无名项按 CREATE 路径的自动命名规则补齐)
  static String _indexName(DesignIndex idx, DesignTable d) {
    if (idx.name.trim().isNotEmpty) return idx.name.trim();
    final cols = idx.columnList;
    return 'idx_${d.name.trim()}_${cols.isEmpty ? 'x' : cols.first}';
  }

  static String _indexSignature(DesignIndex e, String typeId) =>
      '${e.columns}|${e.method}|${e.unique}|${e.concurrent}|${e.fillFactor}|${e.tablespace}'
      // 弹窗的逐字段选项计入签名:改排序顺序 / 运算符类别应触发重建索引
      '|${e.columnItems.map((c) => '${c.name}:${c.collationSchema}.${c.collation}'
          ':${c.opClassSchema}.${c.opClass}:${c.order}:${c.nullsOrder}').join('/')}'
      // MySQL 家族的注释内联在 CREATE INDEX 里,只能靠重建生效;PG 有
      // COMMENT ON INDEX(见注释段),不计入签名以免无谓重建
      '${isMysqlLike(typeId) ? '|${e.comment.trim()}' : ''}';

  static String _uniqueSignature(DesignUniqueKey e) =>
      '${e.columns}|${e.deferrable}|${e.deferred}|${e.fillFactor}|${e.tablespace}';

  static String _fkSignature(DesignForeignKey e) =>
      '${e.columns}|${e.refSchema}|${e.refTable}|${e.refColumns}|${e.onDelete}|${e.onUpdate}|${e.matchAll}|${e.deferrable}|${e.deferred}';

  static String _uniqueName(DesignUniqueKey uk, DesignTable d) {
    if (uk.name.trim().isNotEmpty) return uk.name.trim();
    final cols = uk.columnList;
    return 'uq_${d.name.trim()}_${cols.isEmpty ? 'x' : cols.first}';
  }

  static String _checkName(DesignCheck ck, DesignTable d) =>
      ck.name.trim().isEmpty ? 'ck_${d.name.trim()}_${_nameKey(ck.expression)}' : ck.name.trim();

  static String _excludeName(DesignExclude ex, DesignTable d) =>
      ex.name.trim().isEmpty
          ? 'ex_${d.name.trim()}_${ex.columns.trim().split(',').first.trim()}'
          : ex.name.trim();

  /// 同名配对的注释是否发生了变更(非 PG 方言无对应语法时用于阻断提示)。
  static bool _hasCommentLoss<T>(
    List<T> target,
    List<T> original,
    String Function(T) nameOf,
    String Function(T) commentOf,
  ) {
    final orig = <String, T>{
      for (final o in original) nameOf(o).toLowerCase(): o,
    };
    for (final t in target) {
      final o = orig[nameOf(t).toLowerCase()];
      if (!_sameText(o == null ? '' : commentOf(o), commentOf(t))) return true;
    }
    return false;
  }

  static String _fkName(DesignForeignKey fk, DesignTable d) {
    if (fk.name.trim().isNotEmpty) return fk.name.trim();
    final cols = fk.columnList;
    return 'fk_${d.name.trim()}_${cols.isEmpty ? 'x' : cols.first}';
  }

  /// SQL Server 的裸对象名(schema.table,不加引号;sp_rename 要求此形式)
  static String _rawSqlServerTable(DesignTable d) {
    final schema = d.schema?.trim();
    return '${schema == null || schema.isEmpty ? 'dbo' : schema}.${d.name.trim()}';
  }

  /// SQL Server:按列反查并删除默认值约束。
  /// 未显式命名的默认值约束由服务端生成随机后缀名,无法预测,
  /// 故用一可重入批次在库内查找真名后动态 DROP。
  static String _sqlServerDropDefaultSql(DesignTable d, String column) {
    final t = _rawSqlServerTable(d).replaceAll("'", "''");
    final c = column.trim().replaceAll("'", "''");
    return "DECLARE @dc nvarchar(260) = (SELECT dc.name FROM sys.default_constraints dc "
        "JOIN sys.columns c ON c.object_id = dc.parent_object_id "
        "AND c.column_id = dc.parent_column_id "
        "WHERE dc.parent_object_id = OBJECT_ID(N'$t') AND c.name = N'$c'); "
        "IF @dc IS NOT NULL EXEC(N'ALTER TABLE $t DROP CONSTRAINT [' + @dc + N']');";
  }

  /// 注释语句(PostgreSQL / SQL Server;MySQL 表注释合入 ALTER 动作)
  static String _commentValue(String v) =>
      v.trim().isEmpty ? 'NULL' : lit(v.trim());

  /// 各方言主键约束名的约定形式(反查不到真实名字时的兜底)。
  ///
  /// MySQL / MariaDB 的主键固定名为 `PRIMARY`;PostgreSQL 为 `<表名>_pkey`;
  /// SQL Server 未显式命名时由服务端生成随机后缀,无法预测,故返回空串
  /// (调用方按 `sys.key_constraints` 反查真名,不猜)。
  static String defaultPkName(String dialect, String table) {
    if (isMysqlLike(dialect)) return 'PRIMARY';
    if (isPgLike(dialect)) return '${table}_pkey';
    return '';
  }

  /// 删除索引语句(各方言形式不同)
  static String _dropIndexSql(DesignTable d, String typeId, String name) {
    final tbl = _qualifiedTable(d, typeId);
    if (isSqlServerLike(typeId)) {
      return 'DROP INDEX IF EXISTS ${ident(typeId, name)} ON $tbl;';
    }
    if (isMysqlLike(typeId)) {
      return 'ALTER TABLE $tbl DROP INDEX ${ident(typeId, name)};';
    }
    return 'DROP INDEX IF EXISTS ${qualified(typeId, d.schema, name)};';
  }

  /// 生成「设计表」的变更语句:比较 [original](打开时的反查快照)与 [target]
  /// (界面当前值),只输出必要的 ALTER 语句;无差异返回空列表。
  ///
  /// 列配对策略:按列名(忽略大小写)匹配;同序号且双方都无同名配对的
  /// 「删+增」判定为重命名。语句顺序:表重命名 → 索引/约束删除 → 列重命名 →
  /// 删列 → 加列 → 改列 → 主键重建 → 索引/约束新增 → 注释。
  /// MySQL 把所有列与主键动作合并为单条 `ALTER TABLE`(单次扫表,并避开
  /// 「AUTO_INCREMENT 列必须是键」的逐步限制)。
  static List<String> buildAlterStatements(
      DesignTable target, DesignTable original, String typeId) {
    final isPg = isPgLike(typeId);
    final isMysql = isMysqlLike(typeId);
    final tbl = _qualifiedTable(target, typeId);

    final head = <String>[];
    final drops = <String>[];
    final colSqls = <String>[]; // PostgreSQL / SQL Server 的逐条列级语句
    final mysqlActions = <String>[]; // MySQL 合并为单条 ALTER 的动作片段
    final adds = <String>[];
    final comments = <String>[];

    // 1. 表重命名:其后语句一律以新名限定
    if (!_sameText(original.name, target.name)) {
      final oldRef = _qualifiedTable(original, typeId);
      final bare = ident(typeId, target.name.trim());
      if (isPg) {
        head.add('ALTER TABLE $oldRef RENAME TO $bare;');
      } else if (isMysql) {
        head.add('RENAME TABLE $oldRef TO $bare;');
      } else {
        head.add('EXEC sp_rename ${lit(_rawSqlServerTable(original))}, '
            '${lit(target.name.trim())}, ${lit('OBJECT')};');
      }
    }

    // 2. 列配对
    final origByName = <String, DesignColumn>{
      for (final c in original.columns) _nameKey(c.name): c,
    };
    final targByName = <String, DesignColumn>{
      for (final c in target.columns) _nameKey(c.name): c,
    };
    final added = <DesignColumn>[
      for (final c in target.columns)
        if (!origByName.containsKey(_nameKey(c.name))) c,
    ];
    final removed = <DesignColumn>[
      for (final o in original.columns)
        if (!targByName.containsKey(_nameKey(o.name))) o,
    ];
    final renameOf = <DesignColumn, DesignColumn>{}; // 目标列 -> 原列
    final targetOf = <DesignColumn, DesignColumn>{}; // 原列 -> 目标列
    final usedAdded = <DesignColumn>{};
    final usedRemoved = <DesignColumn>{};
    final n = original.columns.length < target.columns.length
        ? original.columns.length
        : target.columns.length;
    for (var i = 0; i < n; i++) {
      final o = original.columns[i];
      final t = target.columns[i];
      if (removed.contains(o) &&
          added.contains(t) &&
          !usedRemoved.contains(o) &&
          !usedAdded.contains(t)) {
        usedRemoved.add(o);
        usedAdded.add(t);
        renameOf[t] = o;
        targetOf[o] = t;
      }
    }
    for (final o in original.columns) {
      if (!targetOf.containsKey(o)) {
        final t = targByName[_nameKey(o.name)];
        if (t != null) targetOf[o] = t;
      }
    }
    final pureAdded =
        <DesignColumn>[for (final c in added) if (!usedAdded.contains(c)) c];
    final pureRemoved =
        <DesignColumn>[for (final o in removed) if (!usedRemoved.contains(o)) o];

    // 3. 索引 / 唯一键 / 外键 / 检查:先删后增(避开列被约束引用而删除失败)
    void diffByName<T>(
      List<T> olds,
      List<T> news,
      String Function(T) nameOf,
      String Function(T) sigOf,
      void Function(T) onDrop,
      void Function(T) onAdd,
    ) {
      final oldMap = <String, T>{for (final e in olds) nameOf(e).toLowerCase(): e};
      final newMap = <String, T>{for (final e in news) nameOf(e).toLowerCase(): e};
      for (final e in olds) {
        final m = newMap[nameOf(e).toLowerCase()];
        if (m == null || sigOf(m) != sigOf(e)) onDrop(e);
      }
      for (final e in news) {
        final m = oldMap[nameOf(e).toLowerCase()];
        if (m == null || sigOf(m) != sigOf(e)) onAdd(e);
      }
    }

    diffByName<DesignIndex>(original.indexes, target.indexes,
        (e) => _indexName(e, target), (e) => _indexSignature(e, typeId),
        (e) => drops.add(_dropIndexSql(target, typeId, _indexName(e, original))),
        (e) => adds.add(buildCreateIndex(target, typeId, e)));
    diffByName<DesignUniqueKey>(original.uniqueKeys, target.uniqueKeys,
        (e) => _uniqueName(e, target), _uniqueSignature, (e) {
      final name = _uniqueName(e, original);
      drops.add('ALTER TABLE $tbl DROP '
          '${isMysql ? 'INDEX' : 'CONSTRAINT'} ${ident(typeId, name)};');
    }, (e) {
      final clause = uniqueKeyClause(e, target, typeId);
      if (clause.isNotEmpty) adds.add('ALTER TABLE $tbl ADD $clause;');
    });
    diffByName<DesignForeignKey>(original.foreignKeys, target.foreignKeys,
        (e) => _fkName(e, target), _fkSignature, (e) {
      final name = _fkName(e, original);
      drops.add('ALTER TABLE $tbl '
          '${isMysql ? 'DROP FOREIGN KEY' : 'DROP CONSTRAINT'} ${ident(typeId, name)};');
    }, (e) {
      final clause = foreignKeyClause(e, target, typeId);
      if (clause.isNotEmpty) adds.add('ALTER TABLE $tbl ADD $clause;');
    });
    diffByName<DesignCheck>(original.checks, target.checks,
        (e) => _checkName(e, target), (e) => e.expression.trim(), (e) {
      final name = _checkName(e, original);
      drops.add('ALTER TABLE $tbl DROP CONSTRAINT ${ident(typeId, name)};');
    }, (e) {
      final clause = checkClause(e, target, typeId);
      if (clause.isNotEmpty) adds.add('ALTER TABLE $tbl ADD $clause;');
    });

    // 4a. 列重命名(PG / SQL Server;MySQL 由 CHANGE COLUMN 一并完成)
    if (!isMysql) {
      for (final entry in renameOf.entries) {
        final o = entry.value;
        final t = entry.key;
        if (isPg) {
          colSqls.add('ALTER TABLE $tbl RENAME COLUMN '
              '${ident(typeId, o.name.trim())} TO ${ident(typeId, t.name.trim())};');
        } else {
          colSqls.add('EXEC sp_rename '
              '${lit('${_rawSqlServerTable(target)}.${o.name.trim()}')}, '
              '${lit(t.name.trim())}, ${lit('COLUMN')};');
        }
      }
    }

    // 4b. 删列(被重命名占用的列已在 renameOf 中配对,不会进入本分支)
    for (final o in pureRemoved) {
      final col = ident(typeId, o.name.trim());
      if (isMysql) {
        mysqlActions.add('DROP COLUMN $col');
      } else {
        colSqls.add('ALTER TABLE $tbl DROP COLUMN $col;');
      }
    }

    // 4c. 加列(列序位置仅 MySQL 能表达)
    for (var i = 0; i < target.columns.length; i++) {
      final t = target.columns[i];
      if (!pureAdded.contains(t)) continue;
      final def = columnDefSql(t, typeId);
      if (isMysql) {
        mysqlActions.add('ADD COLUMN $def${_mysqlPositionSql(target, i, typeId)}');
      } else {
        colSqls.add('ALTER TABLE $tbl ADD COLUMN $def;');
      }
    }

    // 4d. 改列
    for (var i = 0; i < target.columns.length; i++) {
      final t = target.columns[i];
      final o = renameOf[t] ?? origByName[_nameKey(t.name)];
      if (o == null) continue; // 新增列已由 4c 承担
      final changed = _columnSignature(o, typeId) != _columnSignature(t, typeId);
      final moved = original.columns.indexOf(o) != i;
      if (!changed && !(isMysql && moved)) continue;
      if (isMysql) {
        final def = columnDefSql(t, typeId);
        final pos = moved ? _mysqlPositionSql(target, i, typeId) : '';
        mysqlActions.add(renameOf.containsKey(t)
            ? 'CHANGE COLUMN ${ident(typeId, o.name.trim())} $def$pos'
            : 'MODIFY COLUMN $def$pos');
      } else {
        colSqls.addAll(_alterColumnDiffSqls(o, t, target, tbl, typeId));
      }
    }

    // 5. 主键重建(列序或集合变化时)
    final oldPk = <String>[
      for (final o in original.columns) //
        if (o.primaryKey && targetOf[o] != null) _nameKey(targetOf[o]!.name),
    ];
    final newPk = [for (final name in pkColumnNames(target)) _nameKey(name)];
    if (!_sameList(oldPk, newPk)) {
      final oldPkName = original.pkName.trim().isNotEmpty
          ? original.pkName.trim()
          : defaultPkName(typeId, original.name.trim());
      final newPkName = target.pkName.trim().isNotEmpty
          ? target.pkName.trim()
          : (isPg || isMysql
              ? defaultPkName(typeId, target.name.trim())
              : 'PK_${target.name.trim()}');
      if (oldPk.isNotEmpty) {
        if (isMysql) {
          mysqlActions.add('DROP PRIMARY KEY');
        } else if (oldPkName.isNotEmpty) {
          colSqls.add('ALTER TABLE $tbl DROP CONSTRAINT ${ident(typeId, oldPkName)};');
        }
      }
      if (newPk.isNotEmpty) {
        final cols = pkColumnNames(target).map((e) => ident(typeId, e)).join(', ');
        if (isMysql) {
          mysqlActions.add('ADD PRIMARY KEY ($cols)');
        } else {
          colSqls.add('ALTER TABLE $tbl ADD CONSTRAINT '
              '${ident(typeId, newPkName)} PRIMARY KEY ($cols);');
        }
      }
    }

    // 6. 注释(MySQL 表注释作为 ALTER 动作,需先于合并语句采集)
    if (isMysql) {
      if (!_sameText(original.tableComment, target.tableComment)) {
        mysqlActions.add('COMMENT = ${lit(target.tableComment.trim())}');
      }
    } else if (isPg) {
      if (!_sameText(original.tableComment, target.tableComment)) {
        comments.add('COMMENT ON TABLE $tbl IS '
            '${_commentValue(target.tableComment)};');
      }
      for (final t in target.columns) {
        // 新增列无原列可比:注释非空即需补 COMMENT(否则用户填的注释会静默丢失)
        final o = renameOf[t] ?? origByName[_nameKey(t.name)];
        if (_sameText(o?.comment ?? '', t.comment)) continue;
        comments.add('COMMENT ON COLUMN $tbl.${ident(typeId, t.name.trim())} IS '
            '${_commentValue(t.comment)};');
      }
      // 外键注释:按约束名配对(未动过的约束不会进入本循环,原注释也不会被覆写)
      final origFkByName = <String, DesignForeignKey>{
        for (final o in original.foreignKeys) _nameKey(_fkName(o, target)): o,
      };
      for (final t in target.foreignKeys) {
        final name = _fkName(t, target);
        final o = origFkByName[_nameKey(name)];
        if (_sameText(o?.comment ?? '', t.comment)) continue;
        comments.add('COMMENT ON CONSTRAINT ${ident(typeId, name)} ON $tbl IS '
            '${_commentValue(t.comment)};');
      }
      // 索引注释:同上按索引名配对(结构变更重建的索引也已覆盖注释)
      final origIdxByName = <String, DesignIndex>{
        for (final o in original.indexes) _nameKey(_indexName(o, target)): o,
      };
      for (final t in target.indexes) {
        final name = _indexName(t, target);
        final o = origIdxByName[_nameKey(name)];
        if (_sameText(o?.comment ?? '', t.comment)) continue;
        comments.add('COMMENT ON INDEX '
            '${qualified(typeId, target.schema, name)} IS '
            '${_commentValue(t.comment)};');
      }
      // 唯一键约束注释
      final origUqByName = <String, DesignUniqueKey>{
        for (final o in original.uniqueKeys) _nameKey(_uniqueName(o, target)): o,
      };
      for (final t in target.uniqueKeys) {
        final name = _uniqueName(t, target);
        final o = origUqByName[_nameKey(name)];
        if (_sameText(o?.comment ?? '', t.comment)) continue;
        comments.add('COMMENT ON CONSTRAINT ${ident(typeId, name)} ON $tbl IS '
            '${_commentValue(t.comment)};');
      }
      // 检查约束注释
      final origCkByName = <String, DesignCheck>{
        for (final o in original.checks) _nameKey(_checkName(o, target)): o,
      };
      for (final t in target.checks) {
        final name = _checkName(t, target);
        final o = origCkByName[_nameKey(name)];
        if (_sameText(o?.comment ?? '', t.comment)) continue;
        comments.add('COMMENT ON CONSTRAINT ${ident(typeId, name)} ON $tbl IS '
            '${_commentValue(t.comment)};');
      }
      // 排除约束注释(结构变更已被 alterUnsupported 拦住,只会走到这里)
      final origExByName = <String, DesignExclude>{
        for (final o in original.excludes) _nameKey(_excludeName(o, target)): o,
      };
      for (final t in target.excludes) {
        final name = _excludeName(t, target);
        final o = origExByName[_nameKey(name)];
        if (_sameText(o?.comment ?? '', t.comment)) continue;
        comments.add('COMMENT ON CONSTRAINT ${ident(typeId, name)} ON $tbl IS '
            '${_commentValue(t.comment)};');
      }
    } else {
      void emitProp(String? oldVal, String newVal, String? column) {
        if (_sameText(oldVal ?? '', newVal)) return;
        final schema = target.schema?.trim();
        final levels = column == null
            ? "'SCHEMA', ${lit(schema ?? 'dbo')}, 'TABLE', ${lit(target.name.trim())}"
            : "'SCHEMA', ${lit(schema ?? 'dbo')}, "
                "'TABLE', ${lit(target.name.trim())}, "
                "'COLUMN', ${lit(column)}";
        final fn = newVal.trim().isEmpty
            ? 'sp_dropextendedproperty'
            : ((oldVal ?? '').trim().isEmpty
                ? 'sp_addextendedproperty'
                : 'sp_updateextendedproperty');
        // 位置形式:第一个参数是属性名,第二个是值(删除时无值)
        final args = newVal.trim().isEmpty
            ? lit('MS_Description')
            : '${lit('MS_Description')}, ${lit(newVal.trim())}';
        comments.add('EXEC $fn $args, $levels;');
      }

      emitProp(original.tableComment, target.tableComment, null);
      for (final t in target.columns) {
        // 同上:新增列的注释走 sp_addextendedproperty(原无属性)
        final o = renameOf[t] ?? origByName[_nameKey(t.name)];
        emitProp(o?.comment, t.comment, t.name.trim());
      }
    }

    final stmts = <String>[...head, ...drops];
    if (isMysql) {
      if (mysqlActions.isNotEmpty) {
        stmts.add('ALTER TABLE $tbl ${mysqlActions.join(', ')};');
      }
    } else {
      stmts.addAll(colSqls);
    }
    stmts.addAll(adds);
    stmts.addAll(comments);
    // 表所有者变更:PG 无内联子句,补一条 ALTER … OWNER TO。
    // 「结构同步」的「比较所有者」勾选时 _forTarget 会保留源侧所有者,差异由此落地;
    // 设计表流程里两侧所有者都取自实表,相等 → 不产生语句。
    if (isPg &&
        target.owner.trim().isNotEmpty &&
        !_sameText(original.owner, target.owner)) {
      stmts
          .add('ALTER TABLE $tbl OWNER TO ${ident(typeId, target.owner.trim())};');
    }
    return stmts;
  }

  /// MySQL 列位置子句(重排列序靠它表达)
  static String _mysqlPositionSql(DesignTable d, int index, String typeId) {
    if (index == 0) return ' FIRST';
    final prev = d.columns[index - 1].name.trim();
    return prev.isEmpty ? '' : ' AFTER ${ident(typeId, prev)}';
  }

  /// PostgreSQL / SQL Server 的单列属性变更语句集。
  ///
  /// 注:SQL Server 的计算列(Computed)无法用 ALTER COLUMN 重写,由服务端
  /// 报错并原样回显;此处不做猜测性屏蔽。
  static List<String> _alterColumnDiffSqls(
      DesignColumn o, DesignColumn t, DesignTable target, String tbl, String typeId) {
    final out = <String>[];
    final col = ident(typeId, t.name.trim());
    final oldType = _columnTypeSql(o, typeId);
    final newType = _columnTypeSql(t, typeId);
    if (isPgLike(typeId)) {
      final oldColl = o.collation.trim();
      final newColl = t.collation.trim();
      if (oldType != newType || oldColl != newColl) {
        final collate = newColl.isEmpty ? '' : ' COLLATE ${ident(typeId, newColl)}';
        out.add('ALTER TABLE $tbl ALTER COLUMN $col TYPE $newType$collate '
            'USING $col::$newType;');
      }
      if (o.notNull != t.notNull) {
        out.add('ALTER TABLE $tbl ALTER COLUMN $col '
            '${t.notNull ? 'SET NOT NULL' : 'DROP NOT NULL'};');
      }
      if (!_sameText(o.defaultValue, t.defaultValue)) {
        final v = t.defaultValue.trim();
        out.add(v.isEmpty
            ? 'ALTER TABLE $tbl ALTER COLUMN $col DROP DEFAULT;'
            : 'ALTER TABLE $tbl ALTER COLUMN $col SET DEFAULT ${_defaultLiteral(v)};');
      }
      if (_identitySignature(o) != _identitySignature(t)) {
        // 序列选项无法定点 ALTER(需知道内部序列名),统一 DROP 后重建;
        // 代价是该列的当前序列值重置(与 Navicat 的重建策略一致)。
        out.add('ALTER TABLE $tbl ALTER COLUMN $col DROP IDENTITY IF EXISTS;');
        final clause = _identityClause(t, typeId);
        if (clause.isNotEmpty) {
          out.add('ALTER TABLE $tbl ALTER COLUMN $col ADD $clause;');
        }
      }
      return out;
    }
    // SQL Server
    if (oldType != newType || o.notNull != t.notNull) {
      // 排序规则必须随 ALTER COLUMN 一起重写:该语法不带 COLLATE 时回退到
      // 数据库默认排序规则,已有显式排序规则的列会被静默改掉
      final coll = t.collation.trim();
      out.add('ALTER TABLE $tbl ALTER COLUMN $col $newType'
          '${coll.isEmpty ? '' : ' COLLATE $coll'} '
          '${t.notNull ? 'NOT NULL' : 'NULL'};');
    }
    if (!_sameText(o.defaultValue, t.defaultValue)) {
      out.add(_sqlServerDropDefaultSql(target, t.name.trim()));
      final v = t.defaultValue.trim();
      if (v.isNotEmpty) {
        final name = 'DF_${target.name.trim()}_${t.name.trim()}';
        out.add('ALTER TABLE $tbl ADD CONSTRAINT ${ident(typeId, name)} '
            'DEFAULT ${_defaultLiteral(v)} FOR $col;');
      }
    }
    return out;
  }

  static String _identitySignature(DesignColumn c) => [
        c.identityMode.trim().toUpperCase(),
        c.identityIncrement.trim(),
        c.identityMinValue.trim(),
        c.identityMaxValue.trim(),
        c.identityStart.trim(),
        c.identityCache.trim(),
        c.identityCycle ? 'cycle' : '',
      ].join('|');

  /// 「SQL 预览」在编辑模式下的文本(无变更时输出单行注释)
  static String alterPreview(
          DesignTable target, DesignTable original, String typeId) =>
      buildAlterStatements(target, original, typeId).join('\n');

  /// 是否存在待应用的变更(用于禁用「保存」与提示)。
  /// 不单独实现比较,直接复用差异生成,避免两处判定口径不一致。
  static bool hasChanges(DesignTable target, DesignTable original, String typeId) =>
      buildAlterStatements(target, original, typeId).isNotEmpty;

  /// 编辑模式下无法用 ALTER 表达的变更;返回 null = 可保存。
  ///
  /// 原则:宁可阻断保存并说明原因,也不静默丢弃用户的修改。
  static String? alterUnsupported(
      DesignTable target, DesignTable original, String typeId) {
    if (!isPgLike(typeId) && !isMysqlLike(typeId) && !isSqlServerLike(typeId)) {
      return '当前数据库类型不支持编辑已有表结构';
    }
    if (target.triggers.length != original.triggers.length ||
        !_sameSigList(
            target.triggers.map((e) => '${e.name}|${e.function}|${e.timing}').toList(),
            original.triggers.map((e) => '${e.name}|${e.function}|${e.timing}').toList())) {
      return '触发器 / 规则 / 排除约束暂不支持在「设计表」中修改';
    }
    if (target.rules.length != original.rules.length ||
        !_sameSigList(
            target.rules.map((e) => '${e.name}|${e.statement}').toList(),
            original.rules.map((e) => '${e.name}|${e.statement}').toList())) {
      return '触发器 / 规则 / 排除约束暂不支持在「设计表」中修改';
    }
    if (target.excludes.length != original.excludes.length ||
        !_sameSigList(
            target.excludes.map((e) => '${e.name}|${e.columns}').toList(),
            original.excludes.map((e) => '${e.name}|${e.columns}').toList())) {
      return '触发器 / 规则 / 排除约束暂不支持在「设计表」中修改';
    }
    // 索引注释:PG 走 COMMENT ON INDEX、MySQL 内联进 CREATE INDEX(已计入索引
    // 签名),SQL Server 的扩展属性不覆盖索引层次 → 只能阻断提示
    if (isSqlServerLike(typeId) &&
        _hasCommentLoss(target.indexes, original.indexes,
            (e) => _indexName(e, target), (e) => e.comment)) {
      return '索引注释暂仅支持 PostgreSQL / MySQL 在「设计表」中修改';
    }
    // 唯一键 / 检查约束注释:除 PG 的 COMMENT ON CONSTRAINT 外其它方言无对应语法
    if (!isPgLike(typeId) &&
        (_hasCommentLoss(target.uniqueKeys, original.uniqueKeys,
            (e) => _uniqueName(e, target), (e) => e.comment) ||
            _hasCommentLoss(
                target.checks, original.checks, (e) => _checkName(e, target), (e) => e.comment))) {
      return '唯一键 / 检查约束注释暂仅支持 PostgreSQL 在「设计表」中修改';
    }
    if (!_sameText(target.tablespace, original.tablespace) ||
        !_sameText(target.fillFactor, original.fillFactor)) {
      return '表空间 / 填充因子暂不支持在「设计表」中修改';
    }
    if (!isMysqlLike(typeId)) {
      // 列序调整:PG / SQL Server 无对应语法(不做隐式表重建)
      final tIndex = <String, int>{
        for (var i = 0; i < target.columns.length; i++) //
          _nameKey(target.columns[i].name): i,
      };
      for (var i = 0; i < original.columns.length; i++) {
        final j = tIndex[_nameKey(original.columns[i].name)];
        if (j != null && j != i) {
          return '${isPgLike(typeId) ? 'PostgreSQL' : 'SQL Server'} 不支持调整已有列的顺序';
        }
      }
    }
    if (isSqlServerLike(typeId)) {
      final tMap = <String, DesignColumn>{
        for (final c in target.columns) _nameKey(c.name): c,
      };
      for (final o in original.columns) {
        final t = tMap[_nameKey(o.name)];
        if (t != null && _identitySignature(o) != _identitySignature(t)) {
          return 'SQL Server 不支持修改已有列的 IDENTITY 属性(请删除该列后重新添加)';
        }
      }
      final oldPk = [
        for (final o in original.columns) //
          if (o.primaryKey) _nameKey(o.name),
      ];
      final newPk = [for (final name in pkColumnNames(target)) _nameKey(name)];
      if (!_sameList(oldPk, newPk) && original.pkName.trim().isEmpty) {
        return '未能读取该表的主键约束名,无法重建主键';
      }
    }
    return null;
  }

  static bool _sameSigList(List<String> a, List<String> b) =>
      _sameList(a.toList()..sort(), b.toList()..sort());
}
