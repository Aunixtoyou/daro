import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../app/app_state.dart';
import '../data/cell_value_view.dart';
import '../data/db_data.dart';
import '../data/table_view.dart';
import '../theme/app_theme.dart';
import 'data_export_wizard.dart';

/// 表格行高 / 列宽(文件级常量,供页面与数据行共用)
const double _rowHeight = 28.0;
const double _colWidth = 150.0;

/// 最左列(空白选中列)宽度:窄列,点击选中整行后显示指向右侧的箭头
const double _numberColWidth = 22.0;

/// 工具面板(筛选 & 排序 / 列 / 单元格编辑器)标签行高度。
/// 取 32 而非 26:base-ui 控件高 28(DesktopTokens.controlHeight),
/// 容器比控件矮会在 debug 下报 RenderFlex overflow
const double _toolTabsHeight = 32.0;

/// 面板标题条高度(同样要放得下 28px 的 Button / IconBtn)
const double _panelHeaderHeight = 30.0;

/// 列面板宽度范围(拖分隔条调整)
const double _columnPanelMinWidth = 132.0;
const double _columnPanelMaxWidth = 320.0;

/// 单元格编辑器高度范围(拖分隔条调整)
const double _cellEditorMinHeight = 96.0;
const double _cellEditorMaxHeight = 460.0;

/// 筛选面板条件区:每缩进一层(一个括号分组)的宽度
const double _filterIndentWidth = 18.0;

/// 条件区各列固定宽:启用开关 / 列名下拉 / 运算符下拉 / 行尾控件。
/// 排序行用同一组宽度,让两个小节的控件纵向对齐
const double _filterCheckWidth = 28.0;
const double _filterColumnWidth = 132.0;
const double _filterOperatorWidth = 88.0;
const double _filterTrailingWidth = 112.0;
const double _filterGap = 6.0;

/// "显示"菜单的三种行显示模式
enum _NullFilter { all, onlyNull, nonNull }

/// 筛选面板右上的「创建工具 / 文本」单选:条件的录入方式。
///
/// 两者是**两份独立草稿**,切回来不会丢:构建树始终保留,[text] 的输入框内容
/// 也始终保留;点「应用」时只有当前选中的那份下推 SQL。
enum _FilterSource {
  /// 创建工具:可视化条件树(含括号分组)
  builder('创建工具'),

  /// 文本:手写 `WHERE` 片段,原文逐字下推(不做转义或重组)
  text('文本');

  const _FilterSource(this.label);

  final String label;
}

/// 页面顶部的三个工具面板(可同时开启,各自独立停靠)
enum _ToolPanel {
  /// 筛选 & 排序:顶部横带,编辑筛选准则与排序准则
  filter('筛选 & 排序'),

  /// 列:左侧竖栏,勾选要显示的列
  columns('列'),

  /// 单元格编辑器:底部面板,多视图查看 / 编辑选中单元格
  cellEditor('单元格编辑器');

  const _ToolPanel(this.label);

  final String label;
}

/// 一页的表数据:拉取时的原始行(组装 UPDATE/DELETE 的 WHERE 依据)+
/// 可编辑副本(承载本地增删改)+ 行标识(>=0 为全局行号,<0 为本地新增行)
class _PageState {
  _PageState({
    required this.originals,
    required this.rows,
    required this.rowIds,
  });

  final List<List<String>> originals;
  final List<List<String>> rows;
  final List<int> rowIds;
}

/// 表数据浏览页:双击表后打开,通过真实驱动做**服务端分页**——
/// `COUNT(*)` 得到全表总数,每页用 `LIMIT 页大小 OFFSET 页*页大小` 查询,
/// 排序 / 筛选同样下推到 SQL(`ORDER BY` / `WHERE`),分页针对全表而非已取数据。
/// 已访问页缓存在内存,翻页往返不丢失未保存的本地修改;
/// 单元格双击进入就地编辑(Enter/失焦提交,Esc 取消),
/// 底部工具栏左侧为 添加/删除/确认/取消/刷新/停止,
/// 右侧为记录区间 + 输入跳页分页控件(◀ 输入框 ▶)与页大小设置。
class TableDataPage extends StatefulWidget {
  const TableDataPage({
    super.key,
    required this.table,
    required this.connection,
    required this.database,
    this.schema,
  });

  final String table;

  /// 所属连接名
  final String connection;

  /// 所属数据库
  final String database;

  /// 所属模式(PostgreSQL / SQL Server 等有模式层的类型;无模式层为 null)
  final String? schema;

  @override
  State<TableDataPage> createState() => _TableDataPageState();
}

class _TableDataPageState extends State<TableDataPage> {
  /// 页大小可选项(设置齿轮下拉菜单;选择后直接成为查询的 LIMIT)
  static const _pageSizeOptions = [10, 25, 50, 100, 500];

  /// 异步加载状态
  bool _loading = false;
  String? _error;

  /// 加载代次:标签切换 / 停止时防止旧请求返回覆盖新表数据
  int _loadGeneration = 0;

  /// 列名(首次加载取得,各页共用)
  List<String>? _columns;

  /// 列名 → 数据类型文本(如 `varchar(20)`),供表头第二行展示;
  /// null = 尚未取得,空 map = 该表无可读类型信息(视图 / 权限不足等)
  Map<String, String>? _columnTypes;

  /// 列宽(拖表头边框调整;列数变化时重置为默认宽度)
  List<double>? _columnWidths;

  /// 全表总数(null 表示未知,尚未执行统计):
  /// 按需 COUNT 模式——打开表 / 翻页 / 输入页码都不聚合,
  /// 仅「跳尾页」时执行一次 COUNT(*) 计算页码;
  /// 任何一页取回的行数不足页大小时总数也精确可知(offset + 行数)
  int? _totalRows;

  /// 当前连接的类型 id(驱动标识符引用规则)
  String _typeId = '';

  /// 分页状态:_page 为 0-based;_pageData 为当前页数据;
  /// _selected 为当前页内的视图行号(0-based),_selectedCol 为选中列
  /// (null 表示整行选中,非 null 表示单元格选中)
  int _pageSize = 100;
  int _page = 0;
  _PageState? _pageData;

  /// 选中态:_selected 为当前页内视图行号(0-based),
  /// _selectedCol 为选中列(null 表示整行选中,非 null 表示单元格选中)
  int? _selected;
  int? _selectedCol;

  /// 访问过的页缓存(页号 → 页数据):翻页往返秒开且保留本地修改;
  /// 排序 / 筛选 / 页大小变更 / 刷新时整体失效
  final Map<int, _PageState> _pageCache = {};

  /// 已下推到 SQL 的排序准则(列表顺序 = `ORDER BY` 优先级);空 = 无排序
  final List<SortCriterion> _sorts = [];

  /// 已下推到 SQL 的筛选条件树;空 = 无筛选
  final List<FilterNode> _filters = [];

  /// 「文本」模式下已下推的 WHERE 原文(逐字下推,与构建树互不覆盖)
  String _appliedWhereText = '';

  /// 已应用的筛选取自构建树还是文本框
  _FilterSource _appliedSource = _FilterSource.builder;

  /// 筛选面板里的**草稿**:面板编辑的是它,点「应用筛选 & 排序」才下推。
  /// 与 [_filters] / [_sorts] 分开,避免"改了还没点应用,翻页却已经生效"。
  List<FilterNode> _draftFilters = [];

  List<SortCriterion> _draftSorts = [];

  /// 草稿的录入方式(面板右上单选)
  _FilterSource _draftSource = _FilterSource.builder;

  /// 「文本」草稿:控制器即唯一来源(与下面的值输入框同一套路,
  /// 输入时只 [_touchDraft] 不 setState)
  final TextEditingController _whereTextController = TextEditingController();

  /// 面板里当前选中的条件行 id:决定 ↑↓ 与 +/O+ 挂在哪一行
  int? _selectedFilterId;

  /// 草稿准则的值输入控制器(准则 id → 控制器),删行时一并释放
  final Map<int, TextEditingController> _valueControllers = {};

  /// 草稿修订号:输入框每敲一个字就要刷新「未应用」提示点,
  /// 但整体重建(含数据网格)代价太大,故只让提示区监听它
  final ValueNotifier<int> _draftRevision = ValueNotifier<int>(0);

  /// 准则 id 分配器
  int _nextCriterionId = 1;

  /// 显示模式:全部 / 仅含 NULL 行 / 仅不含 NULL 行(下推 WHERE)
  _NullFilter _nullFilter = _NullFilter.all;

  // ── 工具面板(筛选 & 排序 / 列 / 单元格编辑器) ────────────

  /// 已展开的工具面板(可同时展开,与 Navicat 一致)
  final Set<_ToolPanel> _openPanels = {};

  /// 列面板宽度 / 单元格编辑器高度(拖分隔条调整)
  double _columnPanelWidth = 170;
  double _cellEditorHeight = 200;

  /// 列显示开关(与 [_columns] 等长;null = 全部显示)
  List<bool>? _columnVisible;

  /// 列面板的搜索文本(只过滤面板里的列清单,不影响网格)
  String _columnSearch = '';

  /// 单元格编辑器:当前视图页签 / 文本内容 / 已绑定的单元格(数据列下标)
  CellViewMode _cellView = CellViewMode.text;
  final TextEditingController _cellController = TextEditingController();
  (int, int)? _cellEditorCell;

  /// 正在编辑的单元格(页内行, 列);null 表示无编辑
  (int, int)? _editing;

  /// 是否存在已提交但未确认的本地修改(联动确认/取消按钮)
  bool _dirty = false;

  /// 已删除的原始行:全局行号 → 原始行值(组装 DELETE 的 WHERE 条件)
  final Map<int, List<String>> _deletedOriginals = {};

  /// 本地新增行的行号计数器(递减分配负数行号)
  int _nextNewId = -1;

  /// 保存进行中
  bool _saving = false;

  /// 状态栏消息(保存成功 / 失败提示)
  String? _statusMessage;

  /// 页面焦点锚点:点击单元格/行时把焦点移到这里,
  /// 供 Del 键判断焦点是否在表数据页内(避免在左侧搜索框按 Del 误删)
  final FocusNode _pageFocusNode = FocusNode();

  /// 数据网格双向滚动控制器:横向供外层 SingleChildScrollView 浏览宽表,
  /// 纵向供 DataGridView 内部 ListView 浏览多行;二者各挂一条可见 ScrollBar
  final ScrollController _hScrollController = ScrollController();
  final ScrollController _vScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _load();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _pageFocusNode.dispose();
    _hScrollController.dispose();
    _vScrollController.dispose();
    for (final controller in _valueControllers.values) {
      controller.dispose();
    }
    _cellController.dispose();
    _whereTextController.dispose();
    _draftRevision.dispose();
    super.dispose();
  }

  /// Ctrl+S 快速保存修改(全局监听,不受焦点位置影响;
  /// 非活动标签的表数据页会被销毁,同一时刻只有一个实例响应)
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    // Ctrl+S 快速保存
    if (HardwareKeyboard.instance.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyS) {
      debugPrint('[TableData] Ctrl+S: dirty=$_dirty, saving=$_saving');
      if (_saving) return true;
      _applyEdits();
      return true;
    }
    // Del:整行选中(未选列)→ 确认后删除行;单元格选中 → 清空为 NULL
    if (event.logicalKey == LogicalKeyboardKey.delete) {
      if (_editing != null) return false; // 编辑器中 Del 删字符
      if (!_focusInPage) return false; // 焦点不在页面(如左侧搜索框)
      _deleteKey();
      return true;
    }
    return false;
  }

  /// 焦点是否在本页面子树内
  bool get _focusInPage {
    var node = FocusManager.instance.primaryFocus;
    while (node != null) {
      if (node == _pageFocusNode) return true;
      node = node.parent;
    }
    return false;
  }

  /// Del 键:整行选中 → 删除行(带确认);单元格选中 → 清空该格为 NULL
  void _deleteKey() {
    final sel = _selected;
    final pageData = _pageData;
    if (pageData == null || sel == null || sel >= pageData.rows.length) return;
    final col = _selectedCol;
    if (col == null) {
      _deleteRowAt(sel);
      return;
    }
    if (col < pageData.rows[sel].length) _setCell(sel, col, 'NULL');
  }

  /// 标签切换时 Selector 会复用同类型 widget 的 State(不重新 initState),
  /// 必须在这里感知表/连接上下文变化重新加载,否则一直停在旧状态
  @override
  void didUpdateWidget(TableDataPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed = oldWidget.table != widget.table ||
        oldWidget.connection != widget.connection ||
        oldWidget.database != widget.database ||
        oldWidget.schema != widget.schema;
    if (changed) {
      setState(() {
        _columns = null;
        _columnTypes = null;
        _columnWidths = null;
        _totalRows = null;
        _typeId = '';
        _pageData = null;
        _pageCache.clear();
        _deletedOriginals.clear();
        _nextNewId = -1;
        _error = null;
        _editing = null;
        _dirty = false;
        _sorts.clear();
        _filters.clear();
        _appliedWhereText = '';
        _appliedSource = _FilterSource.builder;
        _selectedFilterId = null;
        _resetDrafts();
        _nullFilter = _NullFilter.all;
        // 列集与当前表强相关:可见列开关、列搜索、单元格编辑器绑定一并重置
        _columnVisible = null;
        _columnSearch = '';
        _cellEditorCell = null;
        _cellController.clear();
      });
      _load();
    }
  }

  String get _tabKey => OpenTab(
        TabType.table,
        widget.table,
        null,
        widget.connection,
        widget.database,
        widget.schema,
      ).key;

  // ── 服务端 SQL 组装 ────────────────────────────────────

  /// 已应用状态的筛选片段(不含关键字):构建树按条件树组装,「文本」模式逐字
  /// 下推用户原文(整体包一层,免得其中的 OR 被后面的 `AND` 抢走优先级)
  String? get _appliedFilterSql {
    final columns = _columns;
    if (columns == null) return null;
    if (_appliedSource == _FilterSource.text) {
      final text = _appliedWhereText.trim();
      return text.isEmpty ? null : '($text)';
    }
    return buildWhereClause(
      criteria: _filters,
      columns: columns,
      ident: (column) => _ident(_typeId, column),
    );
  }

  /// 筛选 WHERE 片段(不含 WHERE 关键字;无筛选返回 null),
  /// 再与"显示模式"的下推条件 `AND` 在一起
  String? get _whereSql {
    final columns = _columns;
    if (columns == null) return null;
    final parts = <String>[];
    final filterSql = _appliedFilterSql;
    if (filterSql != null) parts.add(filterSql);
    switch (_nullFilter) {
      case _NullFilter.all:
        break;
      case _NullFilter.onlyNull:
        parts.add(
            '(${columns.map((c) => '${_ident(_typeId, c)} IS NULL').join(' OR ')})');
      case _NullFilter.nonNull:
        parts.add(
            '(${columns.map((c) => '${_ident(_typeId, c)} IS NOT NULL').join(' AND ')})');
    }
    return parts.isEmpty ? null : parts.join(' AND ');
  }

  /// 排序 ORDER BY 片段(不含关键字;无排序返回 null)
  String? get _orderSql => buildOrderByClause(
        criteria: _sorts,
        columns: _columns ?? const [],
        ident: (column) => _ident(_typeId, column),
      );

  /// 主排序列(数据列下标;无排序返回 null):网格列头指示箭头与「保存数据为」
  /// 都只认第一条准则
  int? get _sortCol => _sorts.isEmpty ? null : _sorts.first.columnIndex;

  bool get _sortAsc => _sorts.isEmpty || _sorts.first.ascending;

  /// 视图是否已变更(排序 / 筛选 / 显示模式任一非默认):
  /// 决定「移除所有排序及筛选」是否可点
  bool get _hasView =>
      _sorts.isNotEmpty ||
      _filters.isNotEmpty ||
      _appliedWhereText.trim().isNotEmpty ||
      _nullFilter != _NullFilter.all;

  /// 网格实际渲染的数据列下标(列面板隐藏的列不参与渲染)
  List<int> get _visibleCols =>
      visibleColumnIndexes(_columnVisible, _columns?.length ?? 0);

  /// 网格列下标 → 数据列下标(越界时原样返回,由调用方兜底)
  int _dataColOf(int gridCol) {
    final cols = _visibleCols;
    return gridCol >= 0 && gridCol < cols.length ? cols[gridCol] : gridCol;
  }

  /// 数据列下标 → 网格列下标(该列当前被隐藏时返回 null)
  int? _gridColOf(int? dataCol) {
    if (dataCol == null) return null;
    final index = _visibleCols.indexOf(dataCol);
    return index < 0 ? null : index;
  }

  /// 组装本次页查询的完整 SQL(记录到该 tab 的 SQL 历史)
  String _buildSelectSql(String typeId, {required int limit, required int offset}) {
    final where = _whereSql;
    final order = _orderSql;
    return 'SELECT * FROM ${_qualified(typeId, widget.schema, widget.table)}'
        '${where != null ? ' WHERE $where' : ''}'
        '${order != null ? ' ORDER BY $order' : ''}'
        ' LIMIT $limit OFFSET $offset';
  }

  // ── 加载 / 翻页 ────────────────────────────────────────

  /// 完整加载:只取第 0 页数据,清空页缓存与本地修改。
  /// 不执行 COUNT(按需 COUNT 模式);首页不足一页时总数精确可知。
  /// 用于首次打开 / 刷新 / 排序筛选变更 / 页大小变更 / 保存成功后
  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final app = context.read<AppState>();
    final connName = widget.connection;
    final conn = app.connections
        .where((c) => c.name == connName)
        .firstOrNull;
    if (conn == null) {
      setState(() => _error = '连接 "$connName" 不存在');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _typeId = conn.typeId;
      final preview = await app.connectionManager.previewTable(
        conn,
        widget.database,
        widget.table,
        limit: _pageSize,
        offset: 0,
        schema: widget.schema,
        where: _whereSql,
        orderBy: _orderSql,
      );
      if (!mounted || generation != _loadGeneration) return;
      // 记录本次执行的 SQL 到该 tab 的历史
      app.recordSql(_tabKey, _buildSelectSql(conn.typeId, limit: _pageSize, offset: 0));
      setState(() {
        _columns = preview.columns;
        // 首页不足一页 → 总数精确 = 行数;满页 → 保持原已知总数或未知
        if (preview.rows.length < _pageSize) {
          _totalRows = preview.rows.length;
        }
        _page = 0;
        _pageCache.clear();
        _deletedOriginals.clear();
        _nextNewId = -1;
        _dirty = false;
        _editing = null;
        _selected = null;
        _selectedCol = null;
        _loading = false;
        _pageData = _PageState(
          originals: [for (final r in preview.rows) List<String>.of(r)],
          rows: [for (final r in preview.rows) List<String>.of(r)],
          rowIds: [for (var i = 0; i < preview.rows.length; i++) i],
        );
      });
      _syncCellEditor();
      _reportStatus();
      if (_columnTypes == null) _loadColumnTypes(conn, generation);
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 异步拉取列类型(表头第二行展示用):不阻塞数据渲染,返回后仅重建表头。
  /// 失败(视图无结构 / 权限不足等)降级为空 map,即不显示类型行。
  Future<void> _loadColumnTypes(
      ConnectionInfo conn, int generation) async {
    Map<String, String> types;
    try {
      final defs = await context
          .read<AppState>()
          .connectionManager
          .describeTable(conn, widget.database, widget.table,
              schema: widget.schema);
      types = {for (final d in defs) d.name: d.type};
    } catch (_) {
      types = const {};
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() => _columnTypes = types);
  }

  /// 类型文本 → 表头副标题前的小字形:数值族 '#',文本族 'abc',其余不画。
  /// 类型名来自各驱动元数据,格式繁多(`varchar(20)`、`bigint unsigned`、
  /// `decimal(10,2)`…),按词根匹配;`\b` 保证 int 不会误中 point / datetime。
  static String? _typeGlyph(String? type) {
    if (type == null || type.isEmpty) return null;
    final t = type.toLowerCase();
    if (_numericTypeRe.hasMatch(t)) return '#';
    if (_textTypeRe.hasMatch(t)) return 'abc';
    return null;
  }

  static final _numericTypeRe = RegExp(
      r'\b(int|integer|bigint|smallint|tinyint|mediumint|serial|decimal|'
      r'numeric|float|double|real|money|smallmoney|number|fixed|bool)\w*\b');
  static final _textTypeRe = RegExp(
      r'\b(char|varchar|nchar|nvarchar|character|text|tinytext|mediumtext|'
      r'longtext|ntext|citext|clob|enum|set|string|uuid)\w*\b');

  /// 拉取第 [page] 页数据并设为当前页。
  /// 返回该页实际行数(0 表示越界空页,未改动 _pageData;负值表示失败)。
  /// 行数不足页大小时顺带推得精确总数(offset + 行数),无需 COUNT
  Future<int> _fetchPage(int page) async {
    final app = context.read<AppState>();
    final conn = app.connections
        .where((c) => c.name == widget.connection)
        .firstOrNull;
    if (conn == null || _columns == null) return -1;
    final generation = ++_loadGeneration;
    setState(() => _loading = true);
    try {
      final preview = await app.connectionManager.previewTable(
        conn,
        widget.database,
        widget.table,
        limit: _pageSize,
        offset: page * _pageSize,
        schema: widget.schema,
        where: _whereSql,
        orderBy: _orderSql,
      );
      if (!mounted || generation != _loadGeneration) return -1;
      app.recordSql(_tabKey,
          _buildSelectSql(conn.typeId, limit: _pageSize, offset: page * _pageSize));
      final count = preview.rows.length;
      if (count > 0) {
        setState(() {
          // 页内行数不足页大小 → 该页为末页,总数精确 = offset + 行数
          if (count < _pageSize) {
            _totalRows = page * _pageSize + count;
          }
          _pageData = _PageState(
            originals: [for (final r in preview.rows) List<String>.of(r)],
            rows: [for (final r in preview.rows) List<String>.of(r)],
            rowIds: [
              for (var i = 0; i < count; i++) page * _pageSize + i
            ],
          );
          _loading = false;
        });
      } else {
        // 越界空页:不动 _pageData,由调用方回退页码
        setState(() => _loading = false);
      }
      _reportStatus();
      return count;
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return -1;
      setState(() {
        _loading = false;
        _statusMessage = '分页加载失败: $e';
      });
      return -1;
    }
  }

  /// 停止:作废进行中的加载(代次失效),保留已有数据
  void _stop() {
    _loadGeneration++;
    setState(() => _loading = false);
  }

  // ── 分页 / 记录位置 ─────────────────────────────────────

  /// 总页数;总数未知时返回 1(仅用于已知总数的钳制,勿用于未知态)
  int get _pageCount {
    final total = _totalRows;
    if (total == null || total <= 0) return 1;
    return (total / _pageSize).ceil();
  }

  /// 当前页在全局行数据中的区间 [start, end)(end 以实际行数为准,
  /// 末页可能不足一页;本地新增行可能比总数多一行)
  (int, int) get _pageRange {
    final start = _page * _pageSize;
    final end = start + (_pageData?.rows.length ?? 0);
    return (start, end);
  }

  /// 上报分页 / 记录位置到 AppState,状态栏显示"第 xx 条记录（共 xx 条）于第 x 页"
  void _reportStatus() {
    final total = _totalRows;
    final (start, end) = _pageRange;
    final pageData = _pageData;
    final record = _selected != null && pageData != null && _selected! < pageData.rows.length
        ? start + _selected! + 1
        : ((total ?? end) > 0 ? end : 0);
    context.read<AppState>().updateTableStatus(
          _tabKey,
          TablePageStatus(
            totalRows: total,
            currentRecord: record,
            page: _page + 1,
            pageSize: _pageSize,
          ),
        );
  }

  /// 翻页:缓存当前页 → 命中缓存直接恢复(保留本地修改),未命中则拉取;
  /// 越界空页或失败回退到原页。相邻向后越界(下一页探到空页)时
  /// 总数恰为上一页末边界,顺带推得精确总数
  Future<void> _goPage(int page) async {
    if (page == _page || page < 0) return;
    // 总数已知时按总页数钳制(未知时由拉取结果判断越界)
    final total = _totalRows;
    if (total != null && page >= _pageCount) return;
    final oldPage = _page;
    final pageData = _pageData;
    if (pageData != null) _pageCache[oldPage] = pageData;
    final cached = _pageCache[page];
    if (cached != null) {
      setState(() {
        _page = page;
        _pageData = cached;
        _selected = null;
        _selectedCol = null;
        _statusMessage = null;
      });
      _syncCellEditor();
      _reportStatus();
      return;
    }
    setState(() {
      _page = page;
      _selected = null;
      _selectedCol = null;
    });
    _syncCellEditor();
    final fetched = await _fetchPage(page);
    if (!mounted) return;
    if (fetched > 0) {
      setState(() => _statusMessage = null);
      return;
    }
    if (fetched <= 0) {
      // 越界空页(0)或失败(-1):回退到原页
      _pageCache.remove(page);
      setState(() {
        _page = oldPage;
        // 相邻下一页探空 → 上一页满页 + 本页空,总数恰为 page * 页大小
        if (fetched == 0 &&
            page == oldPage + 1 &&
            _pageData?.rows.length == _pageSize) {
          _totalRows = page * _pageSize;
          _statusMessage = '已是最后一页';
        } else if (fetched == 0) {
          _statusMessage = '第 ${page + 1} 页不存在';
        }
      });
      _reportStatus();
    }
  }

  /// 跳尾页:执行一次 COUNT(*) 计算末页页码(按需 COUNT 的唯一入口),
  /// 其余翻页 / 输入跳页均不聚合
  Future<void> _goLastPage() async {
    final app = context.read<AppState>();
    final conn = app.connections
        .where((c) => c.name == widget.connection)
        .firstOrNull;
    if (conn == null) return;
    final total = await app.connectionManager.countTable(
      conn,
      widget.database,
      widget.table,
      schema: widget.schema,
      where: _whereSql,
    );
    if (!mounted) return;
    app.recordSql(
      _tabKey,
      'SELECT COUNT(*) FROM ${_qualified(conn.typeId, widget.schema, widget.table)}'
      '${_whereSql != null ? ' WHERE $_whereSql' : ''}',
    );
    setState(() => _totalRows = total);
    final lastPage = total <= 0 ? 0 : (total / _pageSize).ceil() - 1;
    await _goPage(lastPage);
  }

  /// 更改页大小:直接成为查询的 LIMIT;会丢弃未保存的修改(需确认)
  Future<void> _setPageSize(int size) async {
    if (size == _pageSize) return;
    if (!await _confirmDiscardDirty()) return;
    setState(() => _pageSize = size);
    await _load();
  }

  /// 刷新:重拉总数与当前数据;有未保存修改时先确认
  Future<void> _refresh() async {
    if (!await _confirmDiscardDirty()) return;
    await _load();
  }

  /// 执行会丢弃未保存修改的操作前确认(dirty 时弹窗,取消则中止)
  Future<bool> _confirmDiscardDirty() async {
    if (!_dirty) return true;
    final result = await MessageBox.show(
      context,
      title: '放弃未保存的修改',
      message: '当前有未保存的修改，继续将丢弃这些修改。\n是否继续？',
      type: MessageBoxType.question,
      buttons: MessageBoxButtons.okCancel,
    );
    return result == MessageBoxResult.ok;
  }

  // ── 本地行操作 ──────────────────────────────────────────

  /// 添加:当前页末尾追加一条空记录并选中
  void _addRow() {
    final pageData = _pageData;
    final columns = _columns;
    if (pageData == null || columns == null) return;
    setState(() {
      // originals 同步占位,保持 rows / originals / rowIds 三数组等长
      // (新增行走 INSERT 分支,originals 内容不参与组装)
      pageData.rows.add(List.filled(columns.length, ''));
      pageData.originals.add(List.filled(columns.length, ''));
      pageData.rowIds.add(_nextNewId);
      _nextNewId--;
      _dirty = true;
      _editing = null;
      _selected = pageData.rows.length - 1;
      _selectedCol = null;
    });
    _reportStatus();
  }

  /// 删除:移除当前选中记录(_selected 为当前页内行号)
  void _deleteRow() {
    final sel = _selected;
    final pageData = _pageData;
    if (pageData == null || sel == null || sel >= pageData.rows.length) return;
    _deleteRowAt(sel);
  }

  /// 删除指定行(右键菜单 / 工具栏 / Del 键共用);先弹确认对话框
  Future<void> _deleteRowAt(int row) async {
    final pageData = _pageData;
    if (pageData == null || row >= pageData.rows.length) return;
    final result = await MessageBox.show(
      context,
      title: '删除记录',
      message: '确定要删除第 ${_page * _pageSize + row + 1} 行记录吗?\n'
          '删除后点击「确认修改」或 Ctrl+S 才会写入数据库。',
      type: MessageBoxType.question,
      buttons: MessageBoxButtons.okCancel,
    );
    if (result != MessageBoxResult.ok || !mounted) return;
    final id = pageData.rowIds[row];
    setState(() {
      // 原始行:记录原始值用于组装 DELETE;新增行:直接丢弃即可
      if (id >= 0) {
        _deletedOriginals[id] = List<String>.of(pageData.originals[row]);
      }
      _dirty = true;
      _editing = null;
      pageData.rows.removeAt(row);
      pageData.rowIds.removeAt(row);
      pageData.originals.removeAt(row);
      _selected = null;
      _selectedCol = null;
    });
    _syncCellEditor();
    _reportStatus();
  }

  /// 单击单元格:进入就地编辑(同时选中该单元格);row 为当前页内行号,
  /// col 为网格列下标(隐藏列后与数据列不同,入口处换算)
  void _startEdit(int row, int col) {
    final pageData = _pageData;
    if (pageData == null || row >= pageData.rows.length) return;
    final dataCol = _dataColOf(col);
    // 已在编辑该格:本次点击仅用于在编辑器内定位光标,无需重建
    if (_editing == (row, dataCol)) return;
    setState(() {
      _editing = (row, dataCol);
      _selected = row;
      _selectedCol = dataCol;
    });
    _syncCellEditor();
    _reportStatus();
  }

  /// 取消当前单元格编辑(不提交)
  void _cancelEdit() {
    if (_editing == null) return;
    setState(() => _editing = null);
  }

  /// 结束编辑:值有变化则写回行数据并标记 dirty
  void _finishEdit(int row, int col, String value) {
    if (_editing != (row, col)) return;
    final pageData = _pageData;
    if (pageData == null ||
        row >= pageData.rows.length ||
        col >= pageData.rows[row].length) {
      setState(() => _editing = null);
      return;
    }
    final changed = pageData.rows[row][col] != value;
    setState(() {
      if (changed) {
        pageData.rows[row][col] = value;
        _dirty = true;
      }
      _editing = null;
    });
  }

  /// 确认修改:组装 DELETE / UPDATE / INSERT SQL 并执行,写回数据库。
  /// 遍历所有访问过的页(当前页 + 缓存页)对比原始行,保证翻页后的修改不遗漏
  Future<void> _applyEdits() async {
    final pageData = _pageData;
    final columns = _columns;
    final hasChanges = _dirty;
    if (pageData == null || columns == null || !hasChanges) {
      setState(() {
        _dirty = false;
        _statusMessage = '没有需要保存的修改';
      });
      return;
    }
    final app = context.read<AppState>();
    final conn = app.connectionByName(widget.connection);
    if (conn == null) {
      setState(() => _statusMessage = '连接 "${widget.connection}" 不存在');
      return;
    }
    setState(() {
      _saving = true;
      _statusMessage = null;
      // 结束就地编辑(值已通过 onChanged 实时写入 _rows),
      // 避免保存后刷新时编辑器悬在旧数据上
      _editing = null;
    });
    final tableIdent = _qualified(_typeId, widget.schema, widget.table);
    final errors = <String>[];
    var affectedCount = 0;

    // 用全部原始列值定位行(NULL 用 IS NULL)
    String whereOf(List<String> original) {
      final conditions = <String>[];
      for (var c = 0; c < columns.length; c++) {
        final colIdent = _ident(_typeId, columns[c]);
        if (original[c] == 'NULL') {
          conditions.add('$colIdent IS NULL');
        } else {
          conditions.add('$colIdent = \'${_literal(original[c])}\'');
        }
      }
      return conditions.join(' AND ');
    }

    Future<void> run(String sql) async {
      debugPrint('[TableData] SQL: $sql');
      await app.connectionManager.runQuery(
        conn, sql, database: widget.database, limit: 1,
      );
      app.recordSql(_tabKey, sql);
      affectedCount++;
    }

    // 1) 删除的原始行 → DELETE
    for (final entry in _deletedOriginals.entries) {
      final sql = 'DELETE FROM $tableIdent WHERE ${whereOf(entry.value)}';
      try {
        await run(sql);
      } catch (e) {
        errors.add('删除第 ${entry.key + 1} 行: $e');
      }
    }

    // 2) 修改 / 新增 → 遍历所有访问过的页(当前页 + 缓存页)
    final pages = <_PageState>[
      ..._pageCache.values,
      if (!_pageCache.containsKey(_page)) pageData,
    ];
    for (final p in pages) {
      for (var i = 0; i < p.rows.length; i++) {
        final id = p.rowIds[i];
        if (id < 0) {
          // 新增行 → INSERT(全空行跳过;值 'NULL' 写为 NULL)
          final current = p.rows[i];
          if (current.every((v) => v.isEmpty)) continue;
          final cols = columns.map((c) => _ident(_typeId, c)).join(', ');
          final vals = current
              .map((v) => v == 'NULL' ? 'NULL' : '\'${_literal(v)}\'')
              .join(', ');
          final sql = 'INSERT INTO $tableIdent ($cols) VALUES ($vals)';
          try {
            await run(sql);
          } catch (e) {
            errors.add('新增行: $e');
          }
        } else if (_deletedOriginals.containsKey(id)) {
          continue; // 行已删除
        } else {
          // 原始行 → 对比原始值,有变更则 UPDATE(仅变更列)
          final current = p.rows[i];
          final original = p.originals[i];
          final sets = <String>[];
          for (var c = 0; c < columns.length; c++) {
            if (current[c] != original[c]) {
              // 值为 'NULL' 时写 SQL NULL 关键字(与 INSERT / WHERE 语义一致)
              final v = current[c] == 'NULL'
                  ? 'NULL'
                  : '\'${_literal(current[c])}\'';
              sets.add('${_ident(_typeId, columns[c])} = $v');
            }
          }
          if (sets.isEmpty) continue;
          final sql =
              'UPDATE $tableIdent SET ${sets.join(', ')} WHERE ${whereOf(original)}';
          try {
            await run(sql);
          } catch (e) {
            errors.add('更新第 ${id + 1} 行: $e');
          }
        }
      }
    }

    setState(() {
      _saving = false;
      if (errors.isEmpty) {
        _dirty = false;
        _statusMessage = '已保存 $affectedCount 行修改';
      } else {
        _statusMessage = '保存失败: ${errors.join('; ')}';
      }
    });
    // 成功后重新加载,让总数与当前页与数据库同步(新增行变为真实行,删除行消失)
    if (errors.isEmpty && mounted) {
      await _load();
    }
  }

  /// 取消修改:丢弃所有本地修改,按数据库当前状态重拉当前页
  Future<void> _discardEdits() async {
    if (!_dirty) return;
    setState(() {
      _pageCache.clear();
      _deletedOriginals.clear();
      _nextNewId = -1;
      _dirty = false;
      _editing = null;
      _selected = null;
      _selectedCol = null;
    });
    _syncCellEditor();
    await _fetchPage(_page);
  }

  /// 选中整行(点击最左空白列)
  void _selectRow(int index) {
    _pageFocusNode.requestFocus();
    if (_selected == index && _selectedCol == null) return;
    setState(() {
      _selected = index;
      _selectedCol = null;
    });
    _syncCellEditor();
    _reportStatus();
  }

  /// 选中单个单元格(点击单元格);col 为网格列下标
  void _selectCell(int row, int col) {
    // 点击正在编辑的单元格:仅定位光标,不抢焦点——
    // 抢焦点会让编辑器失焦提交,导致第二次点击退出编辑模式
    final dataCol = _dataColOf(col);
    final editing = _editing;
    final isEditingCell =
        editing != null && editing.$1 == row && editing.$2 == dataCol;
    if (!isEditingCell) _pageFocusNode.requestFocus();
    if (_selected == row && _selectedCol == dataCol) return;
    setState(() {
      _selected = row;
      _selectedCol = dataCol;
    });
    _syncCellEditor();
    _reportStatus();
  }

  // ── 排序 / 筛选(下推服务端 SQL,变更后重载) ──────────────
  //
  // 筛选面板编辑的是**草稿**([_draftFilters] / [_draftSorts]),点
  // 「应用筛选 & 排序」才写进已应用状态并重载 —— 这样"改了还没应用"时翻页
  // 仍按旧条件走,不会静默生效。右键菜单的「筛选 / 排序」直接改草稿并立即应用,
  // 与 Navicat 一致:右键筛出的条件会出现在筛选面板里。

  /// 草稿与已应用状态是否一致(决定「应用」是否可点 / 标签上的小圆点)
  bool get _draftDirty =>
      !sameFilters(_draftFilters, _filters) ||
      !sameSorts(_draftSorts, _sorts) ||
      _draftSource != _appliedSource ||
      _whereTextController.text != _appliedWhereText;

  /// 通知「未应用的更改」提示区刷新(输入框 onChanged 调用,
  /// 只重建那一点 UI,不动数据网格)
  void _touchDraft() => _draftRevision.value++;

  /// 用已应用状态重建草稿与值控制器(换表 / 应用 / 清除后调用)
  void _resetDrafts() {
    for (final controller in _valueControllers.values) {
      controller.dispose();
    }
    _valueControllers.clear();
    _draftFilters = copyFilterTree(_filters);
    _draftSorts = [for (final s in _sorts) s.copy()];
    for (final criterion in flattenFilterNodes(_draftFilters)) {
      _valueControllers[criterion.id] =
          TextEditingController(text: criterion.value);
    }
    _draftSource = _appliedSource;
    _whereTextController.text = _appliedWhereText;
  }

  /// 释放一个节点名下的值控制器(传入分组则连整棵子树一起释放)
  void _dropValueControllers(FilterNode node) {
    for (final criterion in flattenFilterNodes([node])) {
      _valueControllers.remove(criterion.id)?.dispose();
    }
  }

  /// 应用草稿:把草稿写进已应用状态并重载(丢弃未保存的行修改需先确认)
  Future<void> _applyDraft() async {
    if (!_draftDirty) return;
    final filters = copyFilterTree(_draftFilters);
    final sorts = [for (final s in _draftSorts) s.copy()];
    final source = _draftSource;
    final whereText = _whereTextController.text;
    await _applyViewChange(() {
      _filters
        ..clear()
        ..addAll(filters);
      _sorts
        ..clear()
        ..addAll(sorts);
      _appliedSource = source;
      _appliedWhereText = whereText;
    });
  }

  /// 拖列头 / 右键排序:排序准则替换成这一条
  /// (网格列头一次只能表达一列,故不走"追加多列"路径;col 为 null = 取消排序)
  Future<void> _sortBy(int? col, bool asc) async {
    if (col == null) {
      if (_draftSorts.isEmpty) return;
      _draftSorts = [];
      await _applyDraft();
      return;
    }
    final existing = _draftSorts.length == 1 ? _draftSorts.first : null;
    if (existing != null && existing.columnIndex == col) {
      // 复用原准则(保持 id 不变,重复点同一方向时不会误判成"有改动")
      existing.ascending = asc;
    } else {
      _draftSorts = [
        SortCriterion(id: _nextCriterionId++, columnIndex: col, ascending: asc),
      ];
    }
    await _applyDraft();
  }

  /// 右键「筛选 → <运算符>」:把条件并入草稿并立即应用。
  /// 同列同运算符时只改值,避免反复右键堆出一串重复条件
  Future<void> _filterByOperator(int col, String cell, FilterOperator op) async {
    _upsertDraftFilter(col, op, cell);
    // 自动展开筛选面板,让用户看见条件落到了哪里
    setState(() => _openPanels.add(_ToolPanel.filter));
    await _applyDraft();
  }

  /// 右键「筛选 → 更多筛选...」:展开面板并在根层末尾新增一条针对该列的空白条件
  void _openFilterPanelFor(int column) {
    final criterion = FilterCriterion(
      id: _nextCriterionId++,
      columnIndex: column,
      operator: FilterOperator.eq,
    );
    _valueControllers[criterion.id] = TextEditingController();
    setState(() {
      _draftFilters = [..._draftFilters, criterion];
      _draftSource = _FilterSource.builder;
      _selectedFilterId = criterion.id;
      _openPanels.add(_ToolPanel.filter);
    });
  }

  /// 把一条条件并入草稿:同列同运算符则改值并启用,否则追加到根层末尾
  void _upsertDraftFilter(int column, FilterOperator op, String value) {
    final text = op.isUnary ? '' : value;
    // 右键筛出的条件进条件树,故录入方式一并切回「创建工具」——
    // 停在「文本」时应用的是原文,条件树里的改动不会生效
    _draftSource = _FilterSource.builder;
    final existing = flattenFilterNodes(_draftFilters)
        .where((f) => f.columnIndex == column && f.operator == op)
        .firstOrNull;
    if (existing != null) {
      existing
        ..value = text
        ..enabled = true;
      _valueControllers[existing.id]?.text = text;
      _selectedFilterId = existing.id;
      return;
    }
    final criterion = FilterCriterion(
      id: _nextCriterionId++,
      columnIndex: column,
      operator: op,
      value: text,
    );
    _valueControllers[criterion.id] = TextEditingController(text: text);
    _draftFilters = [..._draftFilters, criterion];
    _selectedFilterId = criterion.id;
  }

  /// 清除全部筛选条件(条件树与「文本」原文一起清;右键菜单)
  Future<void> _clearFilter() async {
    if (_draftFilters.isEmpty && _whereTextIsBlank) return;
    for (final criterion in flattenFilterNodes(_draftFilters)) {
      _valueControllers.remove(criterion.id)?.dispose();
    }
    _draftFilters = [];
    _selectedFilterId = null;
    _whereTextController.clear();
    await _applyDraft();
  }

  bool get _whereTextIsBlank => _whereTextController.text.trim().isEmpty;

  void _setNullFilter(_NullFilter mode) {
    if (_nullFilter == mode) return;
    _applyViewChange(() => _nullFilter = mode);
  }

  Future<void> _clearAllView() async {
    if (_draftFilters.isEmpty &&
        _draftSorts.isEmpty &&
        _whereTextIsBlank &&
        !_hasView) {
      return;
    }
    for (final criterion in flattenFilterNodes(_draftFilters)) {
      _valueControllers.remove(criterion.id)?.dispose();
    }
    _draftFilters = [];
    _draftSorts = [];
    _selectedFilterId = null;
    _whereTextController.clear();
    await _applyViewChange(() {
      _filters.clear();
      _sorts.clear();
      _appliedWhereText = '';
      _appliedSource = _FilterSource.builder;
      _nullFilter = _NullFilter.all;
    });
  }

  /// 应用排序 / 筛选状态变更并重载(丢弃未保存修改需先确认);
  /// 变更后回到第 0 页
  Future<void> _applyViewChange(VoidCallback mutate) async {
    if (!await _confirmDiscardDirty()) return;
    setState(() {
      mutate();
      _selected = null;
      _selectedCol = null;
    });
    await _load();
  }

  // ── 筛选面板(编辑草稿,点「应用」才下推) ────────────────

  /// 一条空白草稿条件(默认第一列 + 等于),同时建好它的值控制器
  FilterCriterion _newDraftCriterion(int column) {
    final criterion = FilterCriterion(
      id: _nextCriterionId++,
      columnIndex: column,
      operator: FilterOperator.eq,
    );
    _valueControllers[criterion.id] = TextEditingController();
    return criterion;
  }

  /// 标题旁的 `+`:在根层末尾追加一条条件
  void _addFilterCriterion() {
    final columns = _columns;
    if (columns == null || columns.isEmpty) return;
    final criterion = _newDraftCriterion(0);
    setState(() {
      insertFilterNode(_draftFilters, null, criterion);
      _selectedFilterId = criterion.id;
    });
  }

  /// 行尾的 `+`:在该节点之后追加一条同级条件
  void _addCriterionAfter(FilterNode node) {
    final columns = _columns;
    if (columns == null || columns.isEmpty) return;
    final criterion = _newDraftCriterion(0);
    setState(() {
      insertFilterNode(_draftFilters, node.id, criterion);
      _selectedFilterId = criterion.id;
    });
  }

  /// 行尾的 `O+`:在该节点之后追加一个括号分组(组内先放一条空条件,
  /// 免得出现点开却没有可填位置的死组)
  void _addGroupAfter(FilterNode node) {
    final columns = _columns;
    if (columns == null || columns.isEmpty) return;
    final group = FilterGroup(
      id: _nextCriterionId++,
      children: [_newDraftCriterion(0)],
    );
    setState(() {
      insertFilterNode(_draftFilters, node.id, group);
      _selectedFilterId = group.id;
    });
  }

  /// 删除一个节点(分组连子树一起删)
  void _removeFilterNode(FilterNode node) {
    _dropValueControllers(node);
    setState(() {
      removeFilterNode(_draftFilters, node.id);
      if (_selectedFilterId == node.id) _selectedFilterId = null;
    });
    _touchDraft();
  }

  /// ↑ / ↓:把选中节点在本层上移 / 下移一格(不跨层,分组整体移动)
  void _moveSelectedFilter(bool up) {
    final id = _selectedFilterId;
    if (id == null) return;
    if (moveFilterNode(_draftFilters, id, up: up)) {
      setState(() {});
      _touchDraft();
    }
  }

  /// 切换「创建工具 / 文本」。
  ///
  /// 切到文本且输入框为空时,用当前条件树生成的片段预填,让用户在已有条件上
  /// 改;已经手写过内容就不覆盖 —— 两份草稿各自保留,切回来不会丢。
  void _setFilterSource(_FilterSource source) {
    if (_draftSource == source) return;
    final columns = _columns;
    if (source == _FilterSource.text &&
        _whereTextIsBlank &&
        columns != null) {
      _whereTextController.text = buildWhereClause(
            criteria: _draftFilters,
            columns: columns,
            ident: (column) => _ident(_typeId, column),
          ) ??
          '';
    }
    setState(() => _draftSource = source);
    _touchDraft();
  }

  void _addSortCriterion() {
    final columns = _columns;
    if (columns == null || columns.isEmpty) return;
    setState(() => _draftSorts = [
          ..._draftSorts,
          SortCriterion(id: _nextCriterionId++, columnIndex: 0),
        ]);
  }

  void _removeSortCriterion(SortCriterion criterion) {
    setState(() => _draftSorts = [
          for (final s in _draftSorts)
            if (!identical(s, criterion)) s,
        ]);
  }

  // ── 列面板(只影响显示,不重载数据) ─────────────────────

  /// 列可见性开关:不允许把最后一列也关掉(空网格无从恢复)
  void _toggleColumnVisible(int index, bool visible) {
    final columns = _columns;
    if (columns == null || index < 0 || index >= columns.length) return;
    final flags = List<bool>.of(_columnVisible ?? List.filled(columns.length, true));
    if (flags.length != columns.length) return;
    if (!visible && flags.where((f) => f).length <= 1) return;
    setState(() {
      flags[index] = visible;
      _columnVisible = flags;
    });
  }

  /// 全选 / 全不选(全不选时保留第一列,避免网格无列可渲染)
  void _setAllColumnsVisible(bool visible) {
    final columns = _columns;
    if (columns == null || columns.isEmpty) return;
    setState(() {
      final flags = List.filled(columns.length, visible);
      if (!visible) flags[0] = true;
      _columnVisible = flags;
    });
  }

  // ── 筛选 & 排序面板(顶部横带) ────────────────────────────

  /// 面板小节标题:名称 + 右侧操作
  Widget _panelSectionHeader(
    AppPalette t,
    String title, {
    required List<Widget> trailing,
  }) {
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.2,
            decoration: TextDecoration.none,
            fontWeight: FontWeight.w600,
            color: t.foreground,
            fontFamilyFallback: chineseFontFamilyFallback,
          ),
        ),
        const SizedBox(width: 10),
        ...trailing,
      ],
    );
  }

  /// 面板内的灰字提示(对应 Navicat 的「点击 + 以添加排序准则」)
  Widget _panelHint(AppPalette t, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, top: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          decoration: TextDecoration.none,
          color: t.mutedForeground,
          fontFamilyFallback: chineseFontFamilyFallback,
        ),
      ),
    );
  }

  Widget _panelIconButton(IconData icon, String tooltip, VoidCallback? onTap) {
    return IconBtn(
      icon: icon,
      iconSize: 15,
      tooltip: tooltip,
      onTap: onTap,
    );
  }

  /// 筛选 & 排序面板:编辑草稿,点「应用筛选 & 排序」才下推 SQL 并重载。
  ///
  /// 条件区是一棵**可嵌套的条件树**:每层最后一条的行尾放 `+` / `O+`
  /// (追加同级条件 / 追加括号分组),其余行放它与下一条的连接词;
  /// 分组占 `(` / `)` 两行,组内缩进一层。
  Widget _filterPanel(AppPalette t) {
    final columns = _columns;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: ConstrainedBox(
        // 条件多时面板自身滚动,不挤压下面的数据网格
        constraints: const BoxConstraints(maxHeight: 260),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _filterHeader(t),
              ..._filterBody(t, columns),
              const SizedBox(height: 12),
              _panelSectionHeader(
                t,
                '排序方式',
                trailing: [
                  _panelIconButton(Icons.add, '添加排序准则', _addSortCriterion),
                  const SizedBox(width: 8),
                  if (_draftSorts.isEmpty)
                    _panelHint(t, '点击 + 以添加排序准则'),
                ],
              ),
              for (final criterion in _draftSorts)
                if (columns != null) _sortRow(t, columns, criterion),
              const SizedBox(height: 12),
              _applyRow(t),
            ],
          ),
        ),
      ),
    );
  }

  /// 条件区主体:列信息未就绪时给提示,「文本」模式给输入框,
  /// 「创建工具」模式把条件树从根层起逐行铺开
  List<Widget> _filterBody(AppPalette t, List<String>? columns) {
    if (columns == null) return [_panelHint(t, '正在读取列信息 …')];
    if (_draftSource == _FilterSource.text) return [_whereTextBox(t)];
    if (_draftFilters.isEmpty) {
      return [
        _panelHint(t, '点击 + 添加筛选条件；选中一行后可在其行尾追加同级条件（+）或括号分组（O+）')
      ];
    }
    return [
      for (var i = 0; i < _draftFilters.length; i++)
        ..._filterNodeRows(
          t,
          columns,
          _draftFilters[i],
          level: 0,
          isLast: i == _draftFilters.length - 1,
        ),
    ];
  }

  /// 「筛选」标题行:标题 + ↑↓(在本层移动选中行) + 右侧「创建工具 / 文本」单选
  Widget _filterHeader(AppPalette t) {
    final id = _selectedFilterId;
    final selected = id == null ? null : findFilterNode(_draftFilters, id);
    final siblings =
        selected == null ? null : filterSiblings(_draftFilters, selected.id);
    final position = selected == null || siblings == null
        ? -1
        : siblings.indexOf(selected);
    return _panelSectionHeader(
      t,
      '筛选',
      trailing: [
        _panelIconButton(Icons.add, '添加筛选条件', _addFilterCriterion),
        _panelIconButton(
          Icons.arrow_upward,
          '上移选中条件',
          position > 0 ? () => _moveSelectedFilter(true) : null,
        ),
        _panelIconButton(
          Icons.arrow_downward,
          '下移选中条件',
          position >= 0 && position < (siblings?.length ?? 0) - 1
              ? () => _moveSelectedFilter(false)
              : null,
        ),
        const Spacer(),
        for (final source in _FilterSource.values)
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: RadioButton<_FilterSource>(
              value: source,
              groupValue: _draftSource,
              label: source.label,
              onChanged: (_) => _setFilterSource(source),
            ),
          ),
      ],
    );
  }

  /// 一个节点在面板上占的行:条件一行;分组是 `(` + 子节点行 + `)`
  List<Widget> _filterNodeRows(
    AppPalette t,
    List<String> columns,
    FilterNode node, {
    required int level,
    required bool isLast,
  }) {
    return switch (node) {
      final FilterCriterion criterion => [
          _criterionRow(t, columns, criterion,
              level: level, isLast: isLast),
        ],
      final FilterGroup group => [
          _groupEdgeRow(t, group,
              level: level, isLast: isLast, opening: true),
          for (var i = 0; i < group.children.length; i++)
            ..._filterNodeRows(
              t,
              columns,
              group.children[i],
              level: level + 1,
              isLast: i == group.children.length - 1,
            ),
          _groupEdgeRow(t, group,
              level: level, isLast: isLast, opening: false),
        ],
    };
  }

  /// 一条条件行:☑ 列 运算符 值 [行尾]
  Widget _criterionRow(
    AppPalette t,
    List<String> columns,
    FilterCriterion criterion, {
    required int level,
    required bool isLast,
  }) {
    final unary = criterion.operator.isUnary;
    return _filterRowShell(
      t: t,
      id: criterion.id,
      level: level,
      children: [
        SizedBox(
          width: _filterCheckWidth,
          child: CheckBox(
            value: criterion.enabled,
            onChanged: (value) {
              setState(() => criterion.enabled = value ?? false);
              _touchDraft();
            },
          ),
        ),
        const SizedBox(width: _filterGap),
        SizedBox(
          width: _filterColumnWidth,
          child: ComboBox<int>(
            items: [for (var i = 0; i < columns.length; i++) i],
            value: criterion.columnIndex < columns.length
                ? criterion.columnIndex
                : null,
            itemToString: (index) => columns[index],
            onChanged: (index) {
              if (index == null) return;
              setState(() => criterion.columnIndex = index);
              _touchDraft();
            },
          ),
        ),
        const SizedBox(width: _filterGap),
        SizedBox(
          width: _filterOperatorWidth,
          child: ComboBox<FilterOperator>(
            items: FilterOperator.values,
            value: criterion.operator,
            itemToString: (op) => op.label,
            onChanged: (op) {
              if (op == null) return;
              setState(() {
                criterion.operator = op;
                if (op.isUnary) criterion.value = '';
              });
              if (op.isUnary) _valueControllers[criterion.id]?.clear();
              _touchDraft();
            },
          ),
        ),
        const SizedBox(width: _filterGap),
        // 值输入框吃掉剩余宽度:窄窗口下不撑破整行(MinWidth 兜底不塌)
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 80),
            child: Input(
              controller: _valueControllers[criterion.id],
              // 空值在设计图里就是 <?> 占位,填了才生成条件
              hint: unary ? '（无需值）' : '<?>',
              enabled: criterion.enabled && !unary,
              // 只改草稿:不 setState,避免每敲一个字重建整个页面
              onChanged: (value) {
                criterion.value = value;
                _touchDraft();
              },
            ),
          ),
        ),
        const SizedBox(width: _filterGap),
        _filterRowTrailing(t, criterion,
            append: isLast, showJoin: !isLast),
      ],
    );
  }

  /// 分组的首尾行。
  ///
  /// `(` 行带整组的启用开关,分组不是本层最后一条时连接词也写在它上面；
  /// `)` 行则在本组是最后一条时承载 `+` / `O+`（往本层追加）。
  Widget _groupEdgeRow(
    AppPalette t,
    FilterGroup group, {
    required int level,
    required bool isLast,
    required bool opening,
  }) {
    return _filterRowShell(
      t: t,
      id: group.id,
      level: level,
      children: [
        SizedBox(
          width: _filterCheckWidth,
          child: opening
              ? CheckBox(
                  value: group.enabled,
                  onChanged: (value) {
                    setState(() => group.enabled = value ?? false);
                    _touchDraft();
                  },
                )
              : null,
        ),
        const SizedBox(width: _filterGap),
        SizedBox(
          width: _filterColumnWidth + _filterGap + _filterOperatorWidth,
          child: Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              opening ? '(' : ')',
              style: TextStyle(
                fontSize: 14,
                height: 1.2,
                decoration: TextDecoration.none,
                fontWeight: FontWeight.w400,
                color: t.foreground,
              ),
            ),
          ),
        ),
        const Expanded(child: SizedBox.shrink()),
        _filterRowTrailing(t, group,
            append: isLast && !opening, showJoin: opening && !isLast),
      ],
    );
  }

  /// 条件区一行的外壳:按层缩进 + 整行点选 + 选中行铺淡蓝底
  Widget _filterRowShell({
    required AppPalette t,
    required int id,
    required int level,
    required List<Widget> children,
  }) {
    return Listener(
      // 按下即选中,不等抬手:与网格行同一套零延迟交互
      onPointerDown: (_) {
        if (_selectedFilterId == id) return;
        setState(() => _selectedFilterId = id);
      },
      child: Container(
        padding: EdgeInsets.only(
          left: level * _filterIndentWidth,
          top: _filterGap,
        ),
        color: _selectedFilterId == id ? t.treeSelectedBg : null,
        child: Row(children: children),
      ),
    );
  }

  /// 行尾控件:[append] 时是本层追加按钮(`+` 条件 / `O+` 分组),[showJoin] 时
  /// 是与下一条的连接词;选中行再挂一个删除按钮(非选中行保持设计图的干净)。
  Widget _filterRowTrailing(
    AppPalette t,
    FilterNode node, {
    required bool append,
    required bool showJoin,
  }) {
    return SizedBox(
      width: _filterTrailingWidth,
      child: Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (append) ...[
              _miniButton(t, Icons.add, '在此条件后添加同级条件',
                  () => _addCriterionAfter(node)),
              _miniButton(t, Icons.add_circle_outline, '在此条件后添加括号分组',
                  () => _addGroupAfter(node)),
            ] else if (showJoin)
              SizedBox(
                width: 64,
                child: ComboBox<FilterJoin>(
                  items: FilterJoin.values,
                  value: node.join,
                  itemToString: (join) => join.label,
                  onChanged: (join) {
                    if (join == null) return;
                    setState(() => node.join = join);
                    _touchDraft();
                  },
                ),
              ),
            if (_selectedFilterId == node.id)
              _miniButton(
                t,
                Icons.close,
                node is FilterGroup ? '删除分组' : '删除条件',
                () => _removeFilterNode(node),
              ),
          ],
        ),
      ),
    );
  }

  /// 行尾的小方框图标按钮(设计图里的 + / O+ / ×)
  Widget _miniButton(
      AppPalette t, IconData icon, String tooltip, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: IconBtn(
        icon: icon,
        iconSize: 13,
        size: const Size(22, 22),
        outline: true,
        color: t.accent,
        tooltip: tooltip,
        onTap: onTap,
      ),
    );
  }

  /// 「文本」模式:直接写 `WHERE` 片段(不含关键字),原文逐字下推。
  ///
  /// 从「创建工具」切过来时若输入框为空,会先填入条件树当前生成的片段,
  /// 便于在已有条件上改而不是从零重写。
  Widget _whereTextBox(AppPalette t) {
    return Padding(
      padding: const EdgeInsets.only(top: _filterGap),
      child: Textarea(
        controller: _whereTextController,
        hint: "不含 WHERE 关键字，例如：id > 100 AND name LIKE '集团%'",
        minLines: 3,
        maxLines: 8,
        style: TextStyle(
          fontFamily: 'Consolas',
          fontFamilyFallback: chineseFontFamilyFallback,
          fontSize: 12,
          height: 1.4,
          decoration: TextDecoration.none,
          fontWeight: FontWeight.w400,
          color: t.foreground,
        ),
        onChanged: (_) => _touchDraft(),
      ),
    );
  }

  /// 底部动作行:主按钮 + 有未应用改动时的灰字(设计图的「已编辑准则」)
  Widget _applyRow(AppPalette t) {
    return Row(
      children: [
        Button(
          text: '应用筛选 & 排序',
          variant: ButtonVariant.primary,
          // 草稿与已应用一致时无需重查数据
          onPressed: _draftDirty ? _applyDraft : null,
        ),
        const SizedBox(width: 10),
        ValueListenableBuilder<int>(
          valueListenable: _draftRevision,
          builder: (context, _, __) => _draftDirty
              ? Text(
                  '已编辑准则',
                  style: TextStyle(
                    fontSize: 12,
                    decoration: TextDecoration.none,
                    fontWeight: FontWeight.w400,
                    color: t.mutedForeground,
                    fontFamilyFallback: chineseFontFamilyFallback,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// 单条排序准则:列 + 方向 + 删除(顺序即 SQL 里的优先级)
  Widget _sortRow(
    AppPalette t,
    List<String> columns,
    SortCriterion criterion,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: _filterGap),
      child: Row(
        children: [
          const SizedBox(width: _filterCheckWidth),
          SizedBox(
            width: _filterColumnWidth,
            child: ComboBox<int>(
              items: [for (var i = 0; i < columns.length; i++) i],
              value: criterion.columnIndex < columns.length
                  ? criterion.columnIndex
                  : null,
              itemToString: (index) => columns[index],
              onChanged: (index) {
                if (index == null) return;
                setState(() => criterion.columnIndex = index);
                _touchDraft();
              },
            ),
          ),
          const SizedBox(width: _filterGap),
          SizedBox(
            width: _filterOperatorWidth,
            child: ComboBox<bool>(
              items: const [true, false],
              value: criterion.ascending,
              itemToString: (asc) => asc ? '升序' : '降序',
              onChanged: (asc) {
                if (asc == null) return;
                setState(() => criterion.ascending = asc);
                _touchDraft();
              },
            ),
          ),
          const Expanded(child: SizedBox.shrink()),
          SizedBox(
            width: _filterTrailingWidth,
            child: Align(
              alignment: Alignment.centerRight,
              child: _miniButton(t, Icons.close, '删除排序准则',
                  () => _removeSortCriterion(criterion)),
            ),
          ),
        ],
      ),
    );
  }

  // ── 列面板(左侧停靠) ───────────────────────────────────

  /// 列面板:勾选要显示的列 + 搜索 + 全选 / 全不选。
  /// 只影响渲染(网格只铺可见列),不重查数据
  Widget _columnPanel(AppPalette t) {
    final columns = _columns;
    final visible = _visibleCols;
    final keyword = _columnSearch.trim().toLowerCase();
    final matches = <int>[
      if (columns != null)
        for (var i = 0; i < columns.length; i++)
          if (keyword.isEmpty || columns[i].toLowerCase().contains(keyword)) i,
    ];
    return Container(
      color: t.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: _panelHeaderHeight,
            color: t.secondary,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                Text(
                  columns == null ? '列' : '列 (${visible.length}/${columns.length})',
                  style: TextStyle(
                    fontSize: 12,
                    decoration: TextDecoration.none,
                    color: t.mutedForeground,
                    fontFamilyFallback: chineseFontFamilyFallback,
                  ),
                ),
                const Spacer(),
                _panelIconButton(Icons.done_all, '显示所有列',
                    () => _setAllColumnsVisible(true)),
                _panelIconButton(Icons.remove_done, '只保留第一列',
                    () => _setAllColumnsVisible(false)),
              ],
            ),
          ),
          Expanded(
            child: columns == null
                ? _panelHint(t, '正在加载列信息 ...')
                // 搜索命中列的下标(不能靠 itemBuilder 返回空盒子过滤:
                // 配了 itemExtent 的空盒子仍占一整行高度,列表会出现空档)
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: matches.length,
                    itemExtent: 22,
                    itemBuilder: (context, position) {
                      final index = matches[position];
                      final name = columns[index];
                      final checked = _columnVisible == null ||
                          index >= _columnVisible!.length ||
                          _columnVisible![index];
                      return Listener(
                        // 按下即切换(无需等 tap 判定,零延迟)
                        onPointerDown: (_) =>
                            _toggleColumnVisible(index, !checked),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Row(
                            children: [
                              SizedBox(
                                width: 22,
                                child: CheckBox(
                                  value: checked,
                                  onChanged: (value) => _toggleColumnVisible(
                                      index, value ?? true),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  name,
                                  softWrap: false,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.1,
                                    decoration: TextDecoration.none,
                                    fontWeight: FontWeight.w400,
                                    color: checked
                                        ? t.foreground
                                        : t.mutedForeground,
                                    fontFamilyFallback:
                                        chineseFontFamilyFallback,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          // 搜索框在面板底部(与 Navicat 一致)
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.border)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Row(
              children: [
                Text(
                  '搜索',
                  style: TextStyle(
                    fontSize: 12,
                    decoration: TextDecoration.none,
                    color: t.mutedForeground,
                    fontFamilyFallback: chineseFontFamilyFallback,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Input(
                    hint: '列名',
                    onChanged: (value) =>
                        setState(() => _columnSearch = value),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 单元格编辑器(底部停靠) ─────────────────────────────

  /// 单元格编辑器:文本 / 十六进制 / 图像 / 网页 四种视图;
  /// 文本视图可改值并「应用」写回本地行(仍需「确认修改」落库)
  Widget _cellEditor(AppPalette t) {
    final cell = _cellEditorCell;
    final columns = _columns;
    final title = cell == null
        ? '未选中单元格'
        : '${columns != null && cell.$2 < columns.length ? columns[cell.$2] : '列 ${cell.$2 + 1}'}'
            '  ·  第 ${_page * _pageSize + cell.$1 + 1} 行';
    return Container(
      color: t.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: _panelHeaderHeight,
            color: t.secondary,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Text(
                  '单元格编辑器 · $title',
                  style: TextStyle(
                    fontSize: 12,
                    decoration: TextDecoration.none,
                    color: t.mutedForeground,
                    fontFamilyFallback: chineseFontFamilyFallback,
                  ),
                ),
                const Spacer(),
                Button(
                  text: '应用',
                  onPressed: cell == null || _cellView != CellViewMode.text
                      ? null
                      : _applyCellEditor,
                ),
                const SizedBox(width: 6),
                Button(
                  text: '撤销',
                  onPressed: cell == null || _cellView != CellViewMode.text
                      ? null
                      : _revertCellEditor,
                ),
              ],
            ),
          ),
          Expanded(
            child: TabControl(
              initialIndex: _cellView.index,
              onChanged: (index) =>
                  setState(() => _cellView = CellViewMode.values[index]),
              tabBarColor: t.background,
              selectedTabColor: t.surface,
              hoverTabColor: t.secondary,
              barHeight: 26,
              tabWidth: 76,
              contentPadding: EdgeInsets.zero,
              tabs: [
                TabItem(label: CellViewMode.text.label, child: _cellBodyText(t)),
                TabItem(label: CellViewMode.hex.label, child: _cellBodyHex(t)),
                TabItem(
                    label: CellViewMode.image.label, child: _cellBodyImage(t)),
                TabItem(label: CellViewMode.web.label, child: _cellBodyWeb(t)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 文本视图:可编辑的多行编辑器
  Widget _cellBodyText(AppPalette t) {
    if (_cellEditorCell == null) {
      return Center(child: _panelHint(t, '请先选中一个单元格'));
    }
    return Padding(
      padding: const EdgeInsets.all(4),
      // SizedBox.expand:TabControl 的页面体是 loose Flexible,不给死高度时
      // expands 的 TextField 可能塌成 0 高(面板看起来是空的)
      child: SizedBox.expand(
        child: Textarea(
          controller: _cellController,
          expands: true,
          showBorder: true,
          style: TextStyle(
            fontFamily: 'Consolas',
            fontFamilyFallback: chineseFontFamilyFallback,
            fontSize: 12.5,
            height: 1.4,
            decoration: TextDecoration.none,
            color: t.foreground,
          ),
        ),
      ),
    );
  }

  /// 十六进制视图:只读转储
  Widget _cellBodyHex(AppPalette t) {
    if (_cellEditorCell == null) {
      return Center(child: _panelHint(t, '请先选中一个单元格'));
    }
    final dump = hexDump(_cellEditorValue);
    if (dump.isEmpty) {
      return Center(child: _panelHint(t, '当前单元格为空'));
    }
    return _monoView(t, dump);
  }

  /// 图像视图:识别 base64 编码的图片
  Widget _cellBodyImage(AppPalette t) {
    if (_cellEditorCell == null) {
      return Center(child: _panelHint(t, '请先选中一个单元格'));
    }
    final bytes = decodeBase64Image(_cellEditorValue);
    if (bytes == null) {
      return Center(
        child: _panelHint(t, '当前单元格不是可识别的 base64 图片数据'),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Center(
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
      ),
    );
  }

  /// 网页视图:识别 HTML 源码(只读展示源码,不做浏览器渲染)
  Widget _cellBodyWeb(AppPalette t) {
    if (_cellEditorCell == null) {
      return Center(child: _panelHint(t, '请先选中一个单元格'));
    }
    final value = _cellEditorValue;
    if (!looksLikeHtml(value)) {
      return Center(child: _panelHint(t, '当前单元格内容不是 HTML 网页源码'));
    }
    return _monoView(t, value);
  }

  /// 只读等宽文本视图(十六进制 / 网页源码共用)
  Widget _monoView(AppPalette t, String text) {
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(6),
        child: Text(
          text,
          style: TextStyle(
            fontFamily: 'Consolas',
            fontFamilyFallback: chineseFontFamilyFallback,
            fontSize: 12.5,
            height: 1.35,
            decoration: TextDecoration.none,
            color: t.foreground,
          ),
        ),
      ),
    );
  }

  // ── 工具面板开关 / 拖拽尺寸 ──────────────────────────────


  /// 展开 / 收起某个工具面板(三个面板互不影响,可同时展开)
  void _toggleToolPanel(_ToolPanel panel) {
    setState(() {
      if (!_openPanels.remove(panel)) _openPanels.add(panel);
      // 打开单元格编辑器时立刻把当前选中单元格灌进去
      if (panel == _ToolPanel.cellEditor && _openPanels.contains(panel)) {
        _syncCellEditor(force: true);
      }
    });
  }

  void _resizeColumnPanel(double dx) {
    setState(() => _columnPanelWidth =
        (_columnPanelWidth + dx).clamp(_columnPanelMinWidth, _columnPanelMaxWidth));
  }

  void _resizeCellEditor(double dy) {
    // 面板在网格下方:向上拖(dy<0)变高
    setState(() => _cellEditorHeight =
        (_cellEditorHeight - dy).clamp(_cellEditorMinHeight, _cellEditorMaxHeight));
  }

  // ── 单元格编辑器 ────────────────────────────────────────

  /// 把选中单元格的值灌进编辑器(选中变化时调用;同一格不重复覆盖,
  /// 否则用户在编辑器里改到一半会被已有值冲掉)
  void _syncCellEditor({bool force = false}) {
    final cell = _currentCell;
    if (!force && cell == _cellEditorCell) return;
    _cellEditorCell = cell;
    _cellController.text = cell == null ? '' : _cellValue(cell);
  }

  /// 当前选中单元格(数据列下标);未选单元格 / 选中行内已删除时返回 null
  (int, int)? get _currentCell {
    final row = _selected;
    final col = _selectedCol;
    final pageData = _pageData;
    if (row == null || col == null || pageData == null) return null;
    if (row >= pageData.rows.length || col >= pageData.rows[row].length) {
      return null;
    }
    return (row, col);
  }

  /// 取单元格的显示值(未选返回空串)
  String _cellValue((int, int) cell) {
    final pageData = _pageData;
    if (pageData == null || cell.$1 >= pageData.rows.length) return '';
    final row = pageData.rows[cell.$1];
    return cell.$2 < row.length ? row[cell.$2] : '';
  }

  /// 单元格编辑器的值(未选单元格时为空)
  String get _cellEditorValue =>
      _cellEditorCell == null ? '' : _cellValue(_cellEditorCell!);

  /// 把编辑器文本写回单元格(本地副本,仍需「确认修改」才落库)
  void _applyCellEditor() {
    final cell = _cellEditorCell;
    if (cell == null) return;
    setState(() => _statusMessage = '已写回单元格（点「确认修改」或 Ctrl+S 落库）');
    _setCell(cell.$1, cell.$2, _cellController.text);
  }

  /// 放弃编辑器里的改动,恢复单元格当前值
  void _revertCellEditor() {
    final cell = _cellEditorCell;
    if (cell == null) return;
    _cellController.text = _cellValue(cell);
  }

  // ── 单元格右键菜单 ─────────────────────────────────────

  /// 数据行右键:在光标处弹出单元格菜单(作用于命中的行 + 列);
  /// row 为当前页内行号,col 为**网格列**下标(隐藏列后与数据列不同)
  void _onCellContext(int row, int col, Offset position) {
    final pageData = _pageData;
    if (pageData == null || row >= pageData.rows.length) return;
    final dataCol = _dataColOf(col);
    if (dataCol < 0 || dataCol >= pageData.rows[row].length) return;
    showContextMenu(
      context,
      items: _buildCellMenu(row, dataCol),
      position: position,
    );
  }

  List<MenuModel> _buildCellMenu(int row, int col) {
    final pageData = _pageData!;
    final rows = pageData.rows;
    final cell = rows[row][col];
    final column = _columns![col];
    return [
      MenuItem(
          text: '设置为空白字符串', onPressed: () => _setCell(row, col, '')),
      MenuItem(
          text: '设置为 NULL', onPressed: () => _setCell(row, col, 'NULL')),
      MenuItem(text: '删除 记录', onPressed: () => _deleteRowAt(row)),
      const MenuSeparator(),
      MenuItem(
          text: '复制', shortcut: 'Ctrl+C', onPressed: () => _copyText(cell)),
      MenuItem(text: '复制为', children: [
        MenuItem(
            text: '记录（制表符分隔）',
            onPressed: () => _copyText(rows[row].join('\t'))),
        MenuItem(
            text: '记录（CSV）', onPressed: () => _copyText(_toCsv(rows[row]))),
        MenuItem(
            text: '记录 + 栏位名（CSV）',
            onPressed: () => _copyText(
                '${_toCsv(_columns!)}\n${_toCsv(rows[row])}')),
      ]),
      MenuItem(text: '粘贴', onPressed: () => _pasteToCell(row, col)),
      MenuItem(text: '保存数据为...', onPressed: _openExportWizard),
      const MenuSeparator(),
      MenuItem(text: '排序', children: [
        MenuItem(text: '升序（$column）', onPressed: () => _sortBy(col, true)),
        MenuItem(text: '降序（$column）', onPressed: () => _sortBy(col, false)),
        if (_sortCol != null)
          MenuItem(text: '取消排序', onPressed: () => _sortBy(null, true)),
        const MenuSeparator(),
        MenuItem(
            text: '更多排序...',
            onPressed: () => setState(() {
                  _openPanels.add(_ToolPanel.filter);
                  _addSortCriterion();
                })),
      ]),
      // 列显示:与左侧「列」面板同源(勾选状态是同一份 _columnVisible)
      MenuItem(text: '列', children: [
        MenuItem(
            text: '隐藏「$column」',
            enabled: _visibleCols.length > 1,
            onPressed: () => _toggleColumnVisible(col, false)),
        MenuItem(text: '显示所有列', onPressed: () => _setAllColumnsVisible(true)),
        const MenuSeparator(),
        MenuItem(
            text: '列面板...',
            onPressed: () => setState(() => _openPanels.add(_ToolPanel.columns))),
      ]),
      MenuItem(
          text: '单元格编辑器',
          onPressed: () => _toggleToolPanel(_ToolPanel.cellEditor)),
      // 筛选子菜单:每个运算符一项,值取当前单元格(一元运算符不带值),
      // 命中后并入筛选面板的草稿并立即应用
      MenuItem(text: '筛选', children: [
        for (final op in FilterOperator.values)
          MenuItem(
            text: op.isUnary
                ? op.label
                : '${op.label} "${_ellipsize(cell)}"',
            onPressed: () => _filterByOperator(col, cell, op),
          ),
        const MenuSeparator(),
        MenuItem(
            text: '更多筛选...', onPressed: () => _openFilterPanelFor(col)),
        if (_filters.isNotEmpty)
          MenuItem(text: '清除筛选', onPressed: _clearFilter),
      ]),
      MenuItem(
          text: '移除所有排序及筛选',
          enabled: _hasView,
          onPressed: _clearAllView),
      MenuItem(text: '显示', children: [
        MenuItem(
            text: '全部记录', onPressed: () => _setNullFilter(_NullFilter.all)),
        MenuItem(
            text: '仅含 NULL 值的记录',
            onPressed: () => _setNullFilter(_NullFilter.onlyNull)),
        MenuItem(
            text: '仅不含 NULL 值的记录',
            onPressed: () => _setNullFilter(_NullFilter.nonNull)),
      ]),
      const MenuSeparator(),
      MenuItem(text: '刷新', onPressed: _refresh),
    ];
  }

  /// 「保存数据为...」:打开导出向导并带入当前视图的筛选与排序,
  /// 使导出内容与屏幕所见一致(服务端数据,不含未确认的本地修改)。
  Future<void> _openExportWizard() async {
    final app = context.read<AppState>();
    final conn = app.connectionByName(widget.connection);
    if (conn == null) {
      if (!mounted) return;
      await MessageBox.show(
        context,
        title: '保存数据为',
        message: '连接「${widget.connection}」已不存在,请先打开连接。',
        type: MessageBoxType.error,
        okText: '知道了',
      );
      return;
    }
    final columns = _columns;
    final sortCol = _sortCol;
    final hasSort =
        columns != null && sortCol != null && sortCol < columns.length;
    await showDataExportWizard(
      context,
      app: app,
      conn: conn,
      database: widget.database,
      table: widget.table,
      schema: widget.schema,
      presetWhere: _whereSql,
      presetSortColumn: hasSort ? columns[sortCol] : null,
      presetSortAscending: _sortAsc,
    );
  }

  /// 修改单元格值(本地副本,标记待确认)
  void _setCell(int row, int col, String value) {
    final pageData = _pageData;
    if (pageData == null ||
        row >= pageData.rows.length ||
        col >= pageData.rows[row].length) {
      return;
    }
    setState(() {
      if (pageData.rows[row][col] != value) {
        pageData.rows[row][col] = value;
        _dirty = true;
      }
    });
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// CSV 转义:含逗号/引号/换行的字段加引号并双写引号
  String _toCsv(List<String> fields) {
    return fields.map((f) {
      if (f.contains(',') || f.contains('"') || f.contains('\n')) {
        return '"${f.replaceAll('"', '""')}"';
      }
      return f;
    }).join(',');
  }

  Future<void> _pasteToCell(int row, int col) async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    // 只取首行(避免多行内容拆进多个单元格)
    _setCell(row, col, text.split('\n').first.trimRight());
  }

  /// 菜单项文本过长时截断
  String _ellipsize(String text) {
    return text.length > 16 ? '${text.substring(0, 15)}…' : text;
  }

  // ── 构建 ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final total = _totalRows;
    return Focus(
      focusNode: _pageFocusNode,
      child: Container(
      color: t.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleBar(
            t,
            '${widget.table} @ ${widget.connection}.${widget.database}'
            '${total == null ? '  ·  行数未知' : total > 0 ? '  ·  $total 行' : ''}',
          ),
          _toolTabs(t),
          if (_openPanels.contains(_ToolPanel.filter)) _filterPanel(t),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 列面板:左侧停靠,勾选显示哪些列(只影响渲染,不重查数据)
                if (_openPanels.contains(_ToolPanel.columns)) ...[
                  SizedBox(width: _columnPanelWidth, child: _columnPanel(t)),
                  Splitter(
                    showHairline: false,
                    showHoverHighlight: false,
                    onDrag: _resizeColumnPanel,
                  ),
                ],
                Expanded(child: _content(t)),
              ],
            ),
          ),
          // 单元格编辑器:底部整宽面板(左列面板之上,与 Navicat 一致)
          if (_openPanels.contains(_ToolPanel.cellEditor)) ...[
            Splitter(
              orientation: Axis.vertical,
              showHairline: false,
              showHoverHighlight: false,
              onDrag: _resizeCellEditor,
            ),
            SizedBox(height: _cellEditorHeight, child: _cellEditor(t)),
          ],
          _bottomBar(t),
        ],
        ),
      ),
    );
  }

  /// 内容区:加载中 / 出错 / 无数据 / 数据网格
  Widget _content(AppPalette t) {
    if (_loading) {
      return Empty(
        icon: const Spinner(size: 20),
        title: '正在加载 ${widget.table} ...',
        compact: true,
        maxWidth: 520,
      );
    }
    if (_error != null) {
      return Empty(
        icon: const Icon(Icons.error_outline),
        title: '读取 ${widget.table} 失败',
        description: _error,
        action: Button(
          text: '重试',
          onPressed: _load,
        ),
        compact: true,
        maxWidth: 520,
      );
    }
    if (_pageData == null || _columns == null) {
      // 表无数据:内容区留白,不展示空态提示
      return Container(color: t.background);
    }
    final (start, end) = _pageRange;
    // 空数据时 visibleRows = 0,DataGridView 仅渲染表头;
    // 双层滚动(垂直 + 水平)由 _buildDataGrid 负责
    return _buildDataGrid(t, _columns!, start, end);
  }

  // ── 工具标签行(筛选 & 排序 / 列 / 单元格编辑器) ──────────

  /// 工具面板图标:黑色线稿 + 蓝色强调,不随选中态换色
  CustomPainter _toolPanelIconPainter(_ToolPanel panel,
      {required Color ink, required Color accent}) {
    switch (panel) {
      case _ToolPanel.cellEditor:
        return _CellEditorIconPainter(line: ink, accent: accent);
      case _ToolPanel.filter:
        return _FilterSortIconPainter(line: ink, accent: accent);
      case _ToolPanel.columns:
        return _ColumnsIconPainter(line: ink, accent: accent);
    }
  }

  /// 三个工具面板的开关:自绘 Toggle 按钮(按下即切换,无动画无特效),
  /// 与 Navicat 的功能区页签对应;面板可同时展开
  Widget _toolTabs(AppPalette t) {
    return Container(
      height: _toolTabsHeight,
      decoration: BoxDecoration(
        color: t.background,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        children: [
          for (final panel in _ToolPanel.values)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Toggle(
                selected: _openPanels.contains(panel),
                variant: ToggleVariant.outline,
                size: ToggleSize.small,
                onChanged: (_) => _toggleToolPanel(panel),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CustomPaint(
                      size: const Size(16, 16),
                      painter: _toolPanelIconPainter(
                          panel, ink: bodyTextColor(context), accent: t.accent),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      panel.label,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.1,
                        decoration: TextDecoration.none,
                        fontWeight: FontWeight.w400,
                        color: bodyTextColor(context),
                        fontFamilyFallback: chineseFontFamilyFallback,
                      ),
                    ),
                    // 筛选 & 排序有未应用的改动时点一个提示点
                    if (panel == _ToolPanel.filter)
                      ValueListenableBuilder<int>(
                        valueListenable: _draftRevision,
                        builder: (context, _, __) => _draftDirty
                            ? Container(
                                margin: const EdgeInsets.only(left: 5),
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  color: Color(0xffe8a33d),
                                  shape: BoxShape.circle,
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),
            ),
          // 提示文字吃掉剩余宽度:窗口窄时省略而不是撑破整行
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: ValueListenableBuilder<int>(
                valueListenable: _draftRevision,
                builder: (context, _, __) => !(_hasView || _draftDirty)
                    ? const SizedBox.shrink()
                    : Text(
                        _draftDirty ? '筛选 / 排序有未应用的更改' : '已应用筛选 / 排序',
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(fontSize: 12, color: t.mutedForeground),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 底部工具栏:左侧 添加/删除/确认/取消/刷新/停止,
  /// 右侧 记录区间 + 输入跳页分页控件 + 页大小设置。
  /// 总数未知(未统计)时记录区间与分页控件照常显示,"共 N 条/页"显示为 ?
  Widget _bottomBar(AppPalette t) {
    final ready = _pageData != null;
    final total = _totalRows;
    final (start, end) = _pageRange;
    // 已加载且有数据(总数未知 null 也算)才显示分页区;确认 0 条时不显示
    final showPager = ready && total != 0;
    return ToolStrip(
      borderOnTop: true,
      openUpward: true,
      items: [
        ToolStripButton(
          icon: Icons.add,
          tooltip: '添加记录',
          enabled: ready,
          onPressed: _addRow,
        ),
        ToolStripButton(
          icon: Icons.remove,
          tooltip: '删除选中记录',
          enabled: ready && _selected != null,
          onPressed: _deleteRow,
        ),
        ToolStripButton(
          icon: _saving ? Icons.hourglass_empty : Icons.check,
          tooltip: _saving ? '保存中...' : '确认修改',
          enabled: ready && _dirty && !_saving,
          onPressed: _saving ? null : _applyEdits,
        ),
        ToolStripButton(
          icon: Icons.close,
          tooltip: '取消修改',
          enabled: ready && _dirty,
          onPressed: _discardEdits,
        ),
        const ToolStripSeparator(),
        ToolStripButton(
          icon: Icons.refresh,
          tooltip: '刷新',
          enabled: ready && !_loading,
          onPressed: _refresh,
        ),
        ToolStripButton(
          icon: Icons.pause_circle_outline,
          tooltip: '停止',
          enabled: _loading,
          onPressed: _stop,
        ),
      ],
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_statusMessage != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                _statusMessage!,
                style: TextStyle(
                  fontSize: 12,
                  color: _statusMessage!.startsWith('保存失败')
                      ? const Color(0xffd93025)
                      : t.mutedForeground,
                ),
              ),
            ),
          if (showPager)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '第 ${start + 1}-$end 条 / 共 ${total ?? '?'} 条',
                style: TextStyle(fontSize: 12, color: t.mutedForeground),
              ),
            ),
          if (showPager)
            PageNavigator(
              pageCount: total == null ? null : _pageCount,
              currentPage: _page,
              onPageChanged: _goPage,
              onGoLast: _goLastPage,
            ),
        ],
      ),
      trailingItems: [
        ToolStripDropDownButton(
          icon: Icons.settings,
          tooltip: '页大小设置',
          enabled: ready,
          items: [
            for (final size in _pageSizeOptions)
              ToolStripDropDownEntry(
                text: size == _pageSize ? '$size 条/页 ✓' : '$size 条/页',
                onPressed: () => _setPageSize(size),
              ),
          ],
        ),
      ],
    );
  }

  /// 表信息标题行:表名 @ 连接.数据库
  Widget _titleBar(AppPalette t, String text) {
    return Container(
      height: 28,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 12),
      color: t.secondary,
      child: Text(
        text,
        style: TextStyle(fontSize: 12.5, color: t.mutedForeground),
      ),
    );
  }

  /// 数据网格:复用 base-ui [DataGridView](行号列 / 单元格选中 / 双击编辑 /
  /// 右键菜单内建,交互零延迟)。纵向由 DataGridView 内部 ListView.builder
  /// 虚拟化(只构建可见行,与页大小无关),横向由外层 SingleChildScrollView
  /// 负责浏览;DataGridView 高度取外层有界约束(视口高),不按页内容撑高。
  Widget _buildDataGrid(
    AppPalette t,
    List<String> columns,
    int start,
    int end,
  ) {
    final pageData = _pageData!;
    final rows = pageData.rows;
    final visibleRows = end - start;
    // 可见列(数据列下标):列面板隐藏的列不参与渲染
    final cols = _visibleCols;
    // 列宽按**数据列**保存:隐藏 / 恢复某列时其它列宽度不跳变
    var widths = _columnWidths;
    if (widths == null || widths.length != columns.length) {
      widths = List.filled(columns.length, _colWidth);
      _columnWidths = widths;
    }
    final gridWidths = [for (final i in cols) widths[i]];
    final selectedCol = _gridColOf(_selectedCol);
    final editingCol = _gridColOf(_editing?.$2);
    // 网格行高内即当前页内行号;列下标一律走 cols 换算
    final grid = DataGridView(
      columns: [
        for (final i in cols)
          DataGridViewColumn(
            title: columns[i],
            subtitle: _columnTypes?[columns[i]],
            subtitleGlyph: _typeGlyph(_columnTypes?[columns[i]]),
          ),
      ],
      columnWidths: gridWidths,
      onColumnResize: (index, newWidth) {
        if (index < 0 || index >= cols.length) return;
        setState(() {
          _columnWidths![cols[index]] = newWidth;
        });
      },
      // 拖表头标题即按该列排序(向右=升序、向左=降序),下推 ORDER BY 重载
      sortColumn: _gridColOf(_sortCol),
      sortAscending: _sortAsc,
      onHeaderSort: (gridCol, ascending) =>
          _sortBy(_dataColOf(gridCol), ascending),
      rowCount: visibleRows,
      // 行号(选中)列:选中行显示指向右侧的箭头(类似 Excel 行头指针)
      showRowNumbers: true,
      rowNumberWidth: _numberColWidth,
      rowNumberBuilder: (row, rowSelected) => rowSelected
          ? Icon(Icons.play_arrow, size: 14, color: t.accentForeground)
          : const SizedBox.shrink(),
      selectedRow:
          _selected != null && _selectedCol == null && _selected! < visibleRows
              ? _selected
              : null,
      selectedCell: _selected != null &&
              selectedCol != null &&
              _selected! < visibleRows
          ? (_selected!, selectedCol)
          : null,
      selectedTextColor: t.accentForeground,
      rowHeight: _rowHeight,
      headerColor: t.secondary,
      headerFontSize: 12,
      gridLineColor: t.gridLine,
      rowHoverColor: Color.alphaBlend(
        t.foreground.withValues(alpha: 0.06),
        t.background,
      ),
      tokens: t.toDesktopTokens(),
      verticalScrollController: _vScrollController,
      // 网格行号即当前页内行号
      onRowSelected: _selectRow,
      onCellSelected: _selectCell,
      onCellTap: _startEdit,
      onCellContext: _onCellContext,
      editingCell: _editing != null &&
              editingCol != null &&
              _editing!.$1 < visibleRows
          ? (_editing!.$1, editingCol)
          : null,
      cellBuilder: (row, gridCol) {
        if (gridCol < 0 || gridCol >= cols.length) {
          return const SizedBox.shrink();
        }
        final col = cols[gridCol];
        // 正在编辑的单元格:就地编辑器(Enter / 失焦提交,Esc 取消)
        if (_editing?.$1 == row && _editing!.$2 == col) {
          return InlineEditor(
            initialValue: rows[row][col],
            onChanged: (value) => _setCell(row, col, value),
            onCommit: (value) => _finishEdit(row, col, value),
            onCancel: _cancelEdit,
            height: _rowHeight,
            contentPadding: EdgeInsets.zero,
          );
        }
        return Text(
          rows[row][col],
          style: TextStyle(
            fontSize: 12.5,
            decoration: TextDecoration.none,
            fontWeight: FontWeight.w400,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        );
      },
    );

    // 高度交给外层 Expanded 提供的有界约束 → DataGridView 内部 ListView.builder
    // 恢复虚拟化,只构建可见行。此前按 visibleRows 撑满整页高度会让 ListView
    // 视口等于全页,整页单元格全部物化为真实 widget(500 行 × 30 列 ≈ 15 万
    // render object),是设置分页大小后内存暴涨的根因。列宽可由用户拖拽调整,
    // 超宽由水平滚动承接,超长由网格自身纵向滚动承接。
    return ScrollBar(
      controller: _hScrollController,
      orientation: ScrollBarOrientation.horizontal,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _hScrollController,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: _numberColWidth +
              gridWidths.fold<double>(0, (a, b) => a + b),
          child: ScrollBar(
            controller: _vScrollController,
            child: grid,
          ),
        ),
      ),
    );
  }

  // ── SQL 标识符 / 字面量(与驱动引用规则一致) ───────────────

  /// 按数据库类型选择标识符引用方式(避免表名/列名与关键字冲突)
  String _ident(String typeId, String name) {
    switch (typeId) {
      case 'postgresql':
      case 'sqlite':
        return '"${name.replaceAll('"', '""')}"';
      case 'sqlserver':
      case 'access':
        return '[${name.replaceAll(']', ']]')}]';
      default: // mysql / mariadb 等
        return '`${name.replaceAll('`', '``')}`';
    }
  }

  /// 带模式限定的表标识符("schema"."table" / [schema].[table]);
  /// 无模式层类型或 [schema] 为空时退化为普通标识符
  String _qualified(String typeId, String? schema, String name) {
    final ident = _ident(typeId, name);
    if (schema == null || schema.isEmpty) return ident;
    switch (typeId) {
      case 'postgresql':
      case 'sqlite':
      case 'sqlserver':
      case 'access':
        return '${_ident(typeId, schema)}.$ident';
      default: // mysql / mariadb:Database 即 Schema
        return ident;
    }
  }

  /// 转义字符串字面量中的单引号(翻倍)
  String _literal(String value) => value.replaceAll("'", "''");
}

// ── 工具面板图标(16x16 自绘线稿,黑色线稿 + 蓝色强调) ──────

/// 单元格编辑器:方框 + 右上斜放的铅笔
class _CellEditorIconPainter extends CustomPainter {
  const _CellEditorIconPainter({required this.line, required this.accent});
  final Color line;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    // 右下留缺口给铅笔,方框不画满
    final frame = Path()
      ..addRRect(RRect.fromRectAndRadius(
          const Rect.fromLTWH(1.2, 5.2, 9.6, 9.6), const Radius.circular(1.6)));
    canvas.drawPath(
      frame,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = line,
    );
    // 铅笔:笔身(圆头描边模拟胶囊) + 笔尖三角,整体 45° 斜放
    final pencil = Path()
      ..moveTo(8.0, 8.0)
      ..lineTo(12.6, 3.4);
    canvas.drawPath(
      pencil,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round
        ..color = accent,
    );
    canvas.drawPath(
      Path()
        ..moveTo(6.6, 9.4)
        ..lineTo(8.0, 8.0)
        ..lineTo(9.4, 6.6)
        ..close(),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round
        ..color = accent,
    );
  }

  @override
  bool shouldRepaint(_CellEditorIconPainter old) =>
      old.line != line || old.accent != accent;
}

/// 筛选 & 排序:左侧漏斗 + 右侧递减排序条
class _FilterSortIconPainter extends CustomPainter {
  const _FilterSortIconPainter({required this.line, required this.accent});
  final Color line;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final funnel = Path()
      ..moveTo(1.4, 2.4)
      ..lineTo(9.4, 2.4)
      ..lineTo(6.4, 6.4)
      ..lineTo(6.4, 10.4)
      ..lineTo(4.4, 8.9)
      ..lineTo(4.4, 6.4)
      ..close();
    canvas.drawPath(
      funnel,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round
        ..color = accent,
    );
    final bars = Paint()
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = line;
    canvas.drawLine(const Offset(11.0, 3.0), const Offset(15.0, 3.0), bars);
    canvas.drawLine(const Offset(11.8, 7.0), const Offset(15.0, 7.0), bars);
    canvas.drawLine(const Offset(12.6, 11.0), const Offset(15.0, 11.0), bars);
  }

  @override
  bool shouldRepaint(_FilterSortIconPainter old) =>
      old.line != line || old.accent != accent;
}

/// 列:蓝色外框 + 两条黑色列分隔线
class _ColumnsIconPainter extends CustomPainter {
  const _ColumnsIconPainter({required this.line, required this.accent});
  final Color line;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(1.6, 2.4, 12.8, 11.2), const Radius.circular(1.4)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = accent,
    );
    final dividers = Paint()
      ..strokeWidth = 1.4
      ..color = line;
    canvas.drawLine(const Offset(5.9, 2.4), const Offset(5.9, 13.6), dividers);
    canvas.drawLine(const Offset(10.1, 2.4), const Offset(10.1, 13.6), dividers);
  }

  @override
  bool shouldRepaint(_ColumnsIconPainter old) =>
      old.line != line || old.accent != accent;
}
