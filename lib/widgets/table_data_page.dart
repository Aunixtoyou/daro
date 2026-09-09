import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../app/app_state.dart';
import '../theme/app_theme.dart';
import 'data_export_wizard.dart';

/// 表格行高 / 列宽(文件级常量,供页面与数据行共用)
const double _rowHeight = 28.0;
const double _colWidth = 150.0;

/// 最左列(空白选中列)宽度:窄列,点击选中整行后显示指向右侧的箭头
const double _numberColWidth = 22.0;

/// "显示"菜单的三种行显示模式
enum _NullFilter { all, onlyNull, nonNull }

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

  /// 服务端排序状态(ORDER BY)
  int? _sortCol;
  bool _sortAsc = true;

  /// 服务端筛选状态(WHERE):按某列的值筛选
  int? _filterCol;
  String? _filterValue;

  /// 显示模式:全部 / 仅含 NULL 行 / 仅不含 NULL 行(下推 WHERE)
  _NullFilter _nullFilter = _NullFilter.all;

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
        _sortCol = null;
        _filterCol = null;
        _filterValue = null;
        _nullFilter = _NullFilter.all;
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

  /// 筛选 WHERE 片段(不含 WHERE 关键字;无筛选返回 null)
  String? get _whereSql {
    final columns = _columns;
    if (columns == null) return null;
    final parts = <String>[];
    final filterCol = _filterCol;
    if (filterCol != null && _filterValue != null && filterCol < columns.length) {
      final ident = _ident(_typeId, columns[filterCol]);
      // 对 NULL 单元格筛选"等于 NULL"时下推为 IS NULL(与展示语义一致)
      final v = _filterValue!;
      parts.add(v == 'NULL' ? '$ident IS NULL' : "$ident = '${_literal(v)}'");
    }
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
  String? get _orderSql {
    final columns = _columns;
    final sortCol = _sortCol;
    if (columns == null || sortCol == null || sortCol >= columns.length) {
      return null;
    }
    return '${_ident(_typeId, columns[sortCol])} ${_sortAsc ? 'ASC' : 'DESC'}';
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
      _reportStatus();
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

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
      _reportStatus();
      return;
    }
    setState(() {
      _page = page;
      _selected = null;
      _selectedCol = null;
    });
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
    _reportStatus();
  }

  /// 单击单元格:进入就地编辑(同时选中该单元格);row 为当前页内行号
  void _startEdit(int row, int col) {
    final pageData = _pageData;
    if (pageData == null || row >= pageData.rows.length) return;
    // 已在编辑该格:本次点击仅用于在编辑器内定位光标,无需重建
    if (_editing == (row, col)) return;
    setState(() {
      _editing = (row, col);
      _selected = row;
      _selectedCol = col;
    });
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
    _reportStatus();
  }

  /// 选中单个单元格(点击单元格)
  void _selectCell(int row, int col) {
    // 点击正在编辑的单元格:仅定位光标,不抢焦点——
    // 抢焦点会让编辑器失焦提交,导致第二次点击退出编辑模式
    final editing = _editing;
    final isEditingCell =
        editing != null && editing.$1 == row && editing.$2 == col;
    if (!isEditingCell) _pageFocusNode.requestFocus();
    if (_selected == row && _selectedCol == col) return;
    setState(() {
      _selected = row;
      _selectedCol = col;
    });
    _reportStatus();
  }

  // ── 排序 / 筛选(下推服务端 SQL,变更后重载) ──────────────

  void _sortBy(int? col, bool asc) {
    if (_sortCol == col && _sortAsc == asc) return;
    _applyViewChange(() {
      _sortCol = col;
      _sortAsc = asc;
    });
  }

  void _filterByValue(int col, String value) {
    if (_filterCol == col && _filterValue == value) return;
    _applyViewChange(() {
      _filterCol = col;
      _filterValue = value;
    });
  }

  void _clearFilter() {
    if (_filterCol == null) return;
    _applyViewChange(() {
      _filterCol = null;
      _filterValue = null;
    });
  }

  void _setNullFilter(_NullFilter mode) {
    if (_nullFilter == mode) return;
    _applyViewChange(() => _nullFilter = mode);
  }

  void _clearAllView() {
    if (_sortCol == null &&
        _filterCol == null &&
        _nullFilter == _NullFilter.all) {
      return;
    }
    _applyViewChange(() {
      _sortCol = null;
      _filterCol = null;
      _filterValue = null;
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

  // ── 单元格右键菜单 ─────────────────────────────────────

  /// 数据行右键:在光标处弹出单元格菜单(作用于命中的行 + 列);
  /// row 为当前页内行号
  void _onCellContext(int row, int col, Offset position) {
    final pageData = _pageData;
    if (pageData == null || row >= pageData.rows.length) return;
    if (col < 0 || col >= pageData.rows[row].length) return;
    showContextMenu(
      context,
      items: _buildCellMenu(row, col),
      position: position,
    );
  }

  List<MenuModel> _buildCellMenu(int row, int col) {
    final pageData = _pageData!;
    final rows = pageData.rows;
    final cell = rows[row][col];
    final column = _columns![col];
    final hasView = _sortCol != null ||
        _filterCol != null ||
        _nullFilter != _NullFilter.all;
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
      ]),
      MenuItem(text: '筛选', children: [
        MenuItem(
            text: '等于 "${_ellipsize(cell)}"',
            onPressed: () => _filterByValue(col, cell)),
        if (_filterCol != null)
          MenuItem(text: '清除筛选', onPressed: _clearFilter),
      ]),
      MenuItem(
          text: '移除所有排序及筛选',
          enabled: hasView,
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
          Expanded(
            child: () {
              if (_loading) {
                return _centerHint(
                  t,
                  const Spinner(size: 18),
                  '正在加载 ${widget.table} ...',
                );
              }
              if (_error != null) {
                return _centerHint(
                  t,
                  Icon(Icons.error_outline, size: 18, color: t.mutedForeground),
                  '加载失败: $_error',
                  action: Button(
                    text: '重试',
                    onPressed: _load,
                  ),
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
            }(),
          ),
          _bottomBar(t),
        ],
        ),
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

  /// 居中提示(加载 / 错误 / 空数据)
  Widget _centerHint(
    AppPalette t,
    Widget icon,
    String message, {
    Widget? action,
  }) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              style: TextStyle(fontSize: 12.5, color: t.mutedForeground),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (action != null) ...[const SizedBox(width: 12), action],
        ],
      ),
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
    // 首次渲染或列数变化时按默认宽度铺一份列宽,之后由拖表头边框维护
    var widths = _columnWidths;
    if (widths == null || widths.length != columns.length) {
      widths = List.filled(columns.length, _colWidth);
      _columnWidths = widths;
    }
    final grid = DataGridView(
      columns: [
        for (final column in columns)
          DataGridViewColumn(title: column),
      ],
      columnWidths: widths,
      onColumnResize: (index, newWidth) {
        setState(() {
          _columnWidths![index] = newWidth;
        });
      },
      // 拖表头标题即按该列排序(向右=升序、向左=降序),下推 ORDER BY 重载
      sortColumn: _sortCol,
      sortAscending: _sortAsc,
      onHeaderSort: _sortBy,
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
      selectedCell: _selected != null && _selectedCol != null && _selected! < visibleRows
          ? (_selected!, _selectedCol!)
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
      // 网格行号即当前页内行号
      onRowSelected: _selectRow,
      onCellSelected: _selectCell,
      onCellTap: _startEdit,
      onCellContext: _onCellContext,
      editingCell:
          _editing != null && _editing!.$1 < visibleRows
              ? (_editing!.$1, _editing!.$2)
              : null,
      cellBuilder: (row, col) {
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
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: _numberColWidth +
            widths.fold<double>(0, (a, b) => a + b),
        child: grid,
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
