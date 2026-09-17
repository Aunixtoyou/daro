/// 表数据视图(筛选 / 排序 / 列显示)的纯逻辑。
///
/// 表数据页把筛选与排序**下推到服务端 SQL**(`WHERE` / `ORDER BY`),分页针对
/// 全表而非已取回的数据;这里只做「准则模型 → SQL 片段」的组装与可见列计算,
/// 不碰 UI、不碰驱动,便于单测。
///
/// 标识符引用规则(`` ` `` / `"` / `[]`)随数据库类型而变,故以 [ident] 回调注入;
/// 字面量转义与数据库无关(单引号翻倍),在本文件内统一处理。
library;

/// 筛选运算符:标签直接用作面板下拉的选项文字
enum FilterOperator {
  eq('等于'),
  ne('不等于'),
  gt('大于'),
  gte('大于等于'),
  lt('小于'),
  lte('小于等于'),
  contains('包含'),
  notContains('不包含'),
  startsWith('开头是'),
  endsWith('结尾是'),
  isNull('为空'),
  isNotNull('不为空');

  const FilterOperator(this.label);

  /// 面板 / 右键菜单中的显示名
  final String label;

  /// 一元运算符:不需要值输入框
  bool get isUnary => this == isNull || this == isNotNull;

  /// 按 `LIKE` 模式匹配的运算符(值会被包进 `%`)
  bool get isPattern =>
      this == contains ||
      this == notContains ||
      this == startsWith ||
      this == endsWith;
}

/// 相邻两条筛选准则之间的连接方式(面板上的「且 / 或」)
enum FilterJoin {
  and('且', 'AND'),
  or('或', 'OR');

  const FilterJoin(this.label, this.sql);

  /// 面板上的显示名
  final String label;

  /// 拼进 `WHERE` 的关键字
  final String sql;
}

/// 一条筛选准则:列 + 运算符 + 值 + 连接词。
///
/// [enabled] 为 false 时该条不参与 SQL(面板上临时停用,不必删掉重加)。
class FilterCriterion {
  FilterCriterion({
    required this.id,
    required this.columnIndex,
    required this.operator,
    this.value = '',
    this.enabled = true,
    this.join = FilterJoin.and,
  });

  /// 面板内唯一标识:值输入框的控制器按它作键,增删行时不会串台
  final int id;

  /// 数据列下标(不是网格列下标;列面板隐藏列后两者不同)
  int columnIndex;

  FilterOperator operator;

  String value;

  bool enabled;

  /// 本条件与**下一条**条件之间的连接方式(面板上写在本条行尾)。
  ///
  /// 之所以挂在"上一条"上而不是"下一条"上,是为了让选择框所在的那一行恰好就是
  /// 它影响的那一行 —— 见 `table_data_page.dart` 的 `_filterRow`。
  /// 最后一条的 [join] 不参与 SQL(后面没有条件可连)。
  FilterJoin join;

  /// 深拷贝:草稿与已应用状态互不影响
  FilterCriterion copy() => FilterCriterion(
        id: id,
        columnIndex: columnIndex,
        operator: operator,
        value: value,
        enabled: enabled,
        join: join,
      );

  @override
  bool operator ==(Object other) =>
      other is FilterCriterion &&
      other.id == id &&
      other.columnIndex == columnIndex &&
      other.operator == operator &&
      other.value == value &&
      other.enabled == enabled &&
      other.join == join;

  @override
  int get hashCode =>
      Object.hash(id, columnIndex, operator, value, enabled, join);

  @override
  String toString() =>
      'FilterCriterion(#$id, col=$columnIndex, ${operator.name}, "$value", '
      'enabled=$enabled, ${join.name})';
}

/// 一条排序准则:[buildOrderByClause] 按列表顺序输出,故**顺序即优先级**。
class SortCriterion {
  SortCriterion({
    required this.id,
    required this.columnIndex,
    this.ascending = true,
  });

  final int id;

  /// 数据列下标
  int columnIndex;

  /// true = ASC,false = DESC
  bool ascending;

  SortCriterion copy() =>
      SortCriterion(id: id, columnIndex: columnIndex, ascending: ascending);

  @override
  bool operator ==(Object other) =>
      other is SortCriterion &&
      other.id == id &&
      other.columnIndex == columnIndex &&
      other.ascending == ascending;

  @override
  int get hashCode => Object.hash(id, columnIndex, ascending);

  @override
  String toString() =>
      'SortCriterion(#$id, col=$columnIndex, ${ascending ? 'ASC' : 'DESC'})';
}

/// 转义字符串字面量中的单引号(翻倍)。各数据库通用写法。
String sqlLiteral(String value) => value.replaceAll("'", "''");

/// 组装 `WHERE` 片段(不含关键字);无有效准则时返回 null。
///
/// - [criteria] 中 `enabled == false` 的跳过;
/// - 列下标越界的跳过(重建连接 / 换表后残留的准则);
/// - 条件之间的连接词取**前一条有效准则**的 [FilterCriterion.join](面板上就写在
///   那一条的行尾);被跳过的准则不会留下多余的连接词;
/// - 超过一条时整体加括号 —— 外层还要与「显示模式」等条件继续 `AND`,
///   不加括号会改变优先级。
///
/// 混合「且 / 或」时按 SQL 自身的优先级求值(`AND` 优先于 `OR`),与手写 SQL 一致;
/// 面板会把实际片段显示出来,便于核对。
String? buildWhereClause({
  required List<FilterCriterion> criteria,
  required List<String> columns,
  required String Function(String column) ident,
}) {
  final buffer = StringBuffer();
  // 上一条**已收集**条件留下的连接词(被跳过的准则不给连接词)
  FilterJoin? connector;
  var count = 0;
  for (final criterion in criteria) {
    if (!criterion.enabled) continue;
    if (criterion.columnIndex < 0 || criterion.columnIndex >= columns.length) {
      continue;
    }
    final condition =
        _conditionSql(criterion, columns[criterion.columnIndex], ident);
    if (condition == null) continue;
    if (count > 0) buffer.write(' ${connector!.sql} ');
    buffer.write(condition);
    connector = criterion.join;
    count++;
  }
  if (count == 0) return null;
  final sql = buffer.toString();
  return count == 1 ? sql : '($sql)';
}

/// 组装 `ORDER BY` 片段(不含关键字);无有效准则时返回 null
String? buildOrderByClause({
  required List<SortCriterion> criteria,
  required List<String> columns,
  required String Function(String column) ident,
}) {
  final parts = <String>[];
  for (final criterion in criteria) {
    if (criterion.columnIndex < 0 || criterion.columnIndex >= columns.length) {
      continue;
    }
    parts.add('${ident(columns[criterion.columnIndex])} '
        '${criterion.ascending ? 'ASC' : 'DESC'}');
  }
  return parts.isEmpty ? null : parts.join(', ');
}

/// 单条准则 → 条件表达式。
///
/// 值为字面量字符串 `NULL` 时按 SQL NULL 处理(与右键「筛选 → 等于 NULL」的
/// 语义一致,也和表数据页里用 `NULL` 占位空值的约定对齐)。
String? _conditionSql(
  FilterCriterion criterion,
  String column,
  String Function(String column) ident,
) {
  final col = ident(column);
  final value = criterion.value;
  final isNullLiteral = value == 'NULL';
  switch (criterion.operator) {
    case FilterOperator.eq:
      return isNullLiteral ? '$col IS NULL' : "$col = '${sqlLiteral(value)}'";
    case FilterOperator.ne:
      return isNullLiteral
          ? '$col IS NOT NULL'
          : "$col <> '${sqlLiteral(value)}'";
    case FilterOperator.gt:
      return "$col > '${sqlLiteral(value)}'";
    case FilterOperator.gte:
      return "$col >= '${sqlLiteral(value)}'";
    case FilterOperator.lt:
      return "$col < '${sqlLiteral(value)}'";
    case FilterOperator.lte:
      return "$col <= '${sqlLiteral(value)}'";
    case FilterOperator.contains:
      return "$col LIKE '%${sqlLiteral(value)}%'";
    case FilterOperator.notContains:
      return "$col NOT LIKE '%${sqlLiteral(value)}%'";
    case FilterOperator.startsWith:
      return "$col LIKE '${sqlLiteral(value)}%'";
    case FilterOperator.endsWith:
      return "$col LIKE '%${sqlLiteral(value)}'";
    case FilterOperator.isNull:
      return '$col IS NULL';
    case FilterOperator.isNotNull:
      return '$col IS NOT NULL';
  }
}

/// 网格实际渲染的数据列下标序列。
///
/// [visible] 为 null 或长度与列数不符(列集变化后残留)时视为全部显示;
/// 全部被隐藏时同样退回全部显示 —— 空网格里没有任何列头,用户无从恢复。
List<int> visibleColumnIndexes(List<bool>? visible, int columnCount) {
  if (columnCount <= 0) return const [];
  if (visible == null || visible.length != columnCount) {
    return [for (var i = 0; i < columnCount; i++) i];
  }
  final indexes = <int>[];
  for (var i = 0; i < columnCount; i++) {
    if (visible[i]) indexes.add(i);
  }
  return indexes.isEmpty ? [for (var i = 0; i < columnCount; i++) i] : indexes;
}

/// 两份筛选准则是否等价(逐条按内容比较,不看列表身份)
bool sameFilters(List<FilterCriterion> a, List<FilterCriterion> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 两份排序准则是否等价
bool sameSorts(List<SortCriterion> a, List<SortCriterion> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
