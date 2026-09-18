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

/// 条件树的节点基类：叶子 [FilterCriterion] 与括号分组 [FilterGroup]。
///
/// [join] 表示本节点与**下一条同级节点**之间的连接词 —— 挂在"上一条"而不是
/// "下一条"上，是为了让面板上连接词下拉所在的那一行，恰好就是它影响的那一行。
/// 同级最后一条的 [join] 不参与 SQL（后面没有节点可连）。
sealed class FilterNode {
  FilterNode({
    required this.id,
    this.enabled = true,
    this.join = FilterJoin.and,
  });

  /// 面板内唯一标识：值输入框的控制器、选中行都按它寻址
  final int id;

  /// 为 false 时该节点（分组则整组）不参与 SQL —— 临时停用，不必删掉重加
  bool enabled;

  FilterJoin join;

  /// 深拷贝：草稿与已应用状态互不影响（id 保持不变）
  FilterNode copy();
}

/// 一条筛选准则：列 + 运算符 + 值。
class FilterCriterion extends FilterNode {
  FilterCriterion({
    required super.id,
    required this.columnIndex,
    required this.operator,
    this.value = '',
    super.enabled,
    super.join,
  });

  /// 数据列下标(不是网格列下标;列面板隐藏列后两者不同)
  int columnIndex;

  FilterOperator operator;

  String value;

  @override
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

/// 一个括号分组：面板上表现为 `(` / `)` 两行，[children] 是组内的同级节点。
///
/// 分组自身也是一个节点，所以它有独立的 [enabled]（整组停用）与 [join]
/// （整组与后一个同级节点的连接词）。
class FilterGroup extends FilterNode {
  FilterGroup({
    required super.id,
    required this.children,
    super.enabled,
    super.join,
  });

  /// 组内节点；列表顺序即 SQL 里的出现顺序
  final List<FilterNode> children;

  @override
  FilterGroup copy() => FilterGroup(
        id: id,
        children: [for (final child in children) child.copy()],
        enabled: enabled,
        join: join,
      );

  @override
  bool operator ==(Object other) =>
      other is FilterGroup &&
      other.id == id &&
      other.enabled == enabled &&
      other.join == join &&
      sameFilters(children, other.children);

  @override
  int get hashCode =>
      Object.hash(id, enabled, join, Object.hashAll(children));

  @override
  String toString() => 'FilterGroup(#$id, $children, enabled=$enabled, '
      '${join.name})';
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

/// 组装 `WHERE` 片段(不含关键字);无有效节点时返回 null。
///
/// - 停用节点、列下标越界的准则(换表后残留)、内容为空的分组都跳过,
///   且**不会**留下多余的连接词;
/// - 同级节点之间的连接词取**前一个已收集节点**的 [FilterNode.join];
/// - 顶层多于一条时整体加括号 —— 外层还要与「显示模式」等条件继续 `AND`,
///   不加括号会改变优先级。
///
/// 混合「且 / 或」时按 SQL 自身的优先级求值(`AND` 优先于 `OR`),与手写 SQL 一致;
/// 需要显式改变优先级就在面板里加括号分组。
String? buildWhereClause({
  required List<FilterNode> criteria,
  required List<String> columns,
  required String Function(String column) ident,
}) =>
    _sequenceSql(criteria, columns, ident, wrap: true);

/// 串接同一层级的节点。[wrap] 为 true 时在收集到多条片段后加括号。
String? _sequenceSql(
  List<FilterNode> nodes,
  List<String> columns,
  String Function(String column) ident, {
  required bool wrap,
}) {
  final buffer = StringBuffer();
  // 上一个**已收集**节点留下的连接词(被跳过的节点不给连接词)
  FilterJoin? connector;
  var count = 0;
  for (final node in nodes) {
    if (!node.enabled) continue;
    final piece = switch (node) {
      final FilterCriterion criterion => _leafSql(criterion, columns, ident),
      final FilterGroup group => _groupSql(group, columns, ident),
    };
    if (piece == null) continue;
    if (count > 0) buffer.write(' ${connector!.sql} ');
    buffer.write(piece);
    connector = node.join;
    count++;
  }
  if (count == 0) return null;
  final sql = buffer.toString();
  return wrap && count > 1 ? '($sql)' : sql;
}

/// 分组 → `( 内部片段 )`。
///
/// 括号**无条件**保留(内部只有一条条件时也不省),否则面板上画着括号、
/// 生成的 SQL 里却没有,用户无从核对优先级。
String? _groupSql(
  FilterGroup group,
  List<String> columns,
  String Function(String column) ident,
) {
  final inner = _sequenceSql(group.children, columns, ident, wrap: false);
  return inner == null ? null : '($inner)';
}

/// 叶子准则 → 条件表达式;列下标越界时返回 null
String? _leafSql(
  FilterCriterion criterion,
  List<String> columns,
  String Function(String column) ident,
) {
  if (criterion.columnIndex < 0 || criterion.columnIndex >= columns.length) {
    return null;
  }
  return _conditionSql(criterion, columns[criterion.columnIndex], ident);
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

/// 两棵筛选条件树是否等价(逐节点按内容比较,不看列表身份)
bool sameFilters(List<FilterNode> a, List<FilterNode> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 深拷贝整棵树(草稿与已应用状态互不影响)
List<FilterNode> copyFilterTree(List<FilterNode> nodes) =>
    [for (final node in nodes) node.copy()];

/// 深度优先展开成叶子条件序列(顺序与 SQL 里的出现顺序一致)
List<FilterCriterion> flattenFilterNodes(List<FilterNode> nodes) {
  final leaves = <FilterCriterion>[];
  for (final node in nodes) {
    switch (node) {
      case final FilterCriterion criterion:
        leaves.add(criterion);
      case final FilterGroup group:
        leaves.addAll(flattenFilterNodes(group.children));
    }
  }
  return leaves;
}

/// 按 id 取节点(含分组内的);不存在返回 null
FilterNode? findFilterNode(List<FilterNode> nodes, int id) {
  for (final node in nodes) {
    if (node.id == id) return node;
    if (node is FilterGroup) {
      final found = findFilterNode(node.children, id);
      if (found != null) return found;
    }
  }
  return null;
}

/// 持有 [id] 的那一层兄弟列表(根层或某个分组内);不存在返回 null
List<FilterNode>? filterSiblings(List<FilterNode> nodes, int id) {
  for (final node in nodes) {
    if (node.id == id) return nodes;
    if (node is FilterGroup) {
      final found = filterSiblings(node.children, id);
      if (found != null) return found;
    }
  }
  return null;
}

/// 在 [afterId] 节点之后插入同级新节点。
///
/// [afterId] 为 null(或已失效)时追加到根层末尾 —— 根层的「末尾追加」入口
/// 就是面板标题旁那个 `+`。
void insertFilterNode(
  List<FilterNode> nodes,
  int? afterId,
  FilterNode node,
) {
  if (afterId == null) {
    nodes.add(node);
    return;
  }
  final siblings = filterSiblings(nodes, afterId);
  if (siblings == null) {
    nodes.add(node);
    return;
  }
  siblings.insert(siblings.indexWhere((n) => n.id == afterId) + 1, node);
}

/// 从树上摘掉 [id] 节点(分组会连子树一起摘掉);返回是否删掉
bool removeFilterNode(List<FilterNode> nodes, int id) {
  final siblings = filterSiblings(nodes, id);
  if (siblings == null) return false;
  siblings.removeWhere((node) => node.id == id);
  return true;
}

/// 把 [id] 节点在本层上移 / 下移一格;已在边界或节点不存在时返回 false
bool moveFilterNode(List<FilterNode> nodes, int id, {required bool up}) {
  final siblings = filterSiblings(nodes, id);
  if (siblings == null) return false;
  final index = siblings.indexWhere((node) => node.id == id);
  final target = up ? index - 1 : index + 1;
  if (target < 0 || target >= siblings.length) return false;
  siblings.insert(target, siblings.removeAt(index));
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
