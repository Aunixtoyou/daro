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

/// 字段(列)设计。类型以「基础类型 + 长度 + 小数点」分段录入,
/// 渲染 DDL 时拼为 `base(len[,decimal])`;长度 / 小数点留空则只输出基础类型。
class DesignColumn {
  DesignColumn({
    this.name = '',
    this.type = 'VARCHAR(255)',
    this.length = '',
    this.decimal = '',
    this.notNull = false,
    this.primaryKey = false,
    this.autoIncrement = false,
    this.comment = '',
    this.defaultValue = '',
    this.collation = '',
    this.dimension = '',
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

  /// 渲染到 DDL 的完整类型文本
  String get fullType {
    final t = type.trim();
    if (t.isEmpty) return '';
    final len = length.trim();
    final dec = decimal.trim();
    if (len.isEmpty) return dec.isEmpty ? t : '$t($dec)';
    return dec.isEmpty ? '$t($len)' : '$t($len,$dec)';
  }
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

  List<String> get columnList =>
      columns.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
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

  List<String> get columnList =>
      columns.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  List<String> get refColumnList =>
      refColumns.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
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
}

/// 检查约束设计。
class DesignCheck {
  DesignCheck({this.name = '', this.expression = '', this.comment = ''});

  String name;
  String expression;
  String comment;
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
}

/// 规则设计(仅 PostgreSQL 家族生成 CREATE RULE)。
class DesignRule {
  DesignRule({this.name = '', this.event = 'INSERT', this.statement = '', this.comment = ''});

  String name;

  /// 事件:INSERT / UPDATE / DELETE / SELECT
  String event;
  String statement;
  String comment;
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
    }
    return stmts;
  }

  /// 生成「SQL 预览」文本(语句以换行拼接)
  static String buildPreview(DesignTable d, String typeId) =>
      buildStatements(d, typeId).join('\n');

  static String _qualifiedTable(DesignTable d, String typeId) =>
      qualified(typeId, d.schema, d.name.trim());

  // ── CREATE TABLE ─────────────────────────────────────────────

  static String buildCreateTable(DesignTable d, String typeId) {
    final lines = <String>[];
    final pkCols = [
      for (final c in d.columns)
        if (c.primaryKey) c.name.trim(),
    ];

    for (final c in d.columns) {
      final name = c.name.trim();
      var typeText = c.fullType;
      // PostgreSQL 数组维度:base[len][dim]
      final dim = c.dimension.trim();
      if (dim.isNotEmpty && isPgLike(typeId)) typeText += '[$dim]';
      final buf = StringBuffer('  ${ident(typeId, name)} $typeText');
      if (c.collation.trim().isNotEmpty && isPgLike(typeId)) {
        buf.write(' COLLATE ${ident(typeId, c.collation.trim())}');
      }
      if (c.notNull) buf.write(' NOT NULL');
      if (c.defaultValue.trim().isNotEmpty) {
        buf.write(' DEFAULT ${_defaultLiteral(c.defaultValue.trim())}');
      }
      // MySQL / MariaDB 自增(需配合键使用,交由用户保证)
      if (isMysqlLike(typeId) && c.autoIncrement) buf.write(' AUTO_INCREMENT');
      // 单列主键内联 PRIMARY KEY;多列主键由表级约束承担
      if (c.primaryKey && pkCols.length == 1) buf.write(' PRIMARY KEY');
      if (isMysqlLike(typeId) && c.comment.trim().isNotEmpty) {
        buf.write(' COMMENT ${lit(c.comment.trim())}');
      }
      lines.add(buf.toString());
    }

    // 表级约束:多列主键 / 唯一键 / 检查 / 排除(PG) / 外键
    if (pkCols.length > 1) {
      lines.add('  PRIMARY KEY (${pkCols.map((n) => ident(typeId, n)).join(', ')})');
    }
    var checkNo = 0;
    for (final uk in d.uniqueKeys) {
      final cols = uk.columnList;
      if (cols.isEmpty) continue;
      final name = uk.name.trim().isEmpty
          ? 'uq_${d.name.trim()}_${cols.first}'
          : uk.name.trim();
      var buf = StringBuffer('  CONSTRAINT ${ident(typeId, name)} UNIQUE (${cols.map((n) => ident(typeId, n)).join(', ')})');
      if (isPgLike(typeId)) buf.write(_deferrableClause(uk.deferrable, uk.deferred));
      lines.add(buf.toString());
    }
    for (final ck in d.checks) {
      if (ck.expression.trim().isEmpty) continue;
      final name = ck.name.trim().isEmpty
          ? 'ck_${d.name.trim()}_${++checkNo}'
          : ck.name.trim();
      lines.add('  CONSTRAINT ${ident(typeId, name)} CHECK (${ck.expression.trim()})');
    }
    for (final ex in d.excludes) {
      if (!isPgLike(typeId)) continue;
      if (ex.columns.trim().isEmpty) continue;
      final name = ex.name.trim().isEmpty
          ? 'ex_${d.name.trim()}_${ex.columns.trim().split(',').first.trim()}'
          : ex.name.trim();
      final method = ex.method.trim().isEmpty ? 'gist' : ex.method.trim();
      lines.add('  CONSTRAINT ${ident(typeId, name)} EXCLUDE USING $method (${ex.columns.trim()})');
    }
    for (final fk in d.foreignKeys) {
      final cols = fk.columnList;
      final refCols = fk.refColumnList;
      if (cols.isEmpty || fk.refTable.trim().isEmpty || refCols.isEmpty) continue;
      final name = fk.name.trim().isEmpty
          ? 'fk_${d.name.trim()}_${cols.first}'
          : fk.name.trim();
      final refTable = fk.refSchema.trim().isNotEmpty
          ? qualified(typeId, fk.refSchema.trim(), fk.refTable.trim())
          : qualified(typeId, d.schema, fk.refTable.trim());
      var buf = StringBuffer('  CONSTRAINT ${ident(typeId, name)} FOREIGN KEY (${cols.map((n) => ident(typeId, n)).join(', ')}) REFERENCES $refTable (${refCols.map((n) => ident(typeId, n)).join(', ')})');
      if (isPgLike(typeId) && fk.matchAll) buf.write(' MATCH FULL');
      final od = fk.onDelete.trim().toUpperCase();
      if (od.isNotEmpty && od != 'NO ACTION') buf.write(' ON DELETE $od');
      final ou = fk.onUpdate.trim().toUpperCase();
      if (ou.isNotEmpty && ou != 'NO ACTION') buf.write(' ON UPDATE $ou');
      if (isPgLike(typeId)) buf.write(_deferrableClause(fk.deferrable, fk.deferred));
      lines.add(buf.toString());
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

    return 'CREATE TABLE ${_qualifiedTable(d, typeId)} (\n${lines.join(',\n')}\n)$tail;';
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
    final name = idx.name.trim().isEmpty
        ? 'idx_${d.name.trim()}_${cols.first}'
        : idx.name.trim();
    final buf = StringBuffer('CREATE ');
    if (idx.unique) buf.write('UNIQUE ');
    buf.write('INDEX ');
    if (idx.concurrent && isPgLike(typeId)) buf.write('CONCURRENTLY ');
    buf.write('${ident(typeId, name)} ON ${_qualifiedTable(d, typeId)}');
    if (idx.method.trim().isNotEmpty) buf.write(' USING ${idx.method.trim()}');
    buf.write(' (${cols.map((n) => ident(typeId, n)).join(', ')})');
    final ff = idx.fillFactor.trim();
    if (ff.isNotEmpty) {
      if (isPgLike(typeId)) buf.write(' WITH (fillfactor = $ff)');
      if (isSqlServerLike(typeId)) buf.write(' WITH (FILLFACTOR = $ff)');
    }
    final ts = idx.tablespace.trim();
    if (ts.isNotEmpty && isPgLike(typeId)) buf.write(' TABLESPACE ${ident(typeId, ts)}');
    return '$buf;';
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
    final buf = StringBuffer('CREATE TRIGGER ${ident(typeId, tr.name.trim())} ');
    buf.write('${tr.timing.trim().toUpperCase()} $eventsText$updateOf ON ${_qualifiedTable(d, typeId)}');
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
}
