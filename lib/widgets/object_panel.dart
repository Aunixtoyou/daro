import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/app_state.dart';
import '../app/connection_manager.dart';
import '../data/db_data.dart';
import '../data/db_types.dart';
import '../data/drivers/db_driver.dart';
import '../data/routine_sql.dart';
import '../theme/app_theme.dart';
import 'data_export_wizard.dart';
import 'data_import_wizard.dart';
import 'function_wizard_dialog.dart';
import 'object_category_icon.dart';
import 'table_context_menu.dart';

// 中部对象面板:展示当前浏览数据库中的对象(表 / 视图 / 函数,由
// objectCategory 决定),单击选中、双击表 / 视图打开数据页。
// 数据来源:连接树单击库或分组节点 → AppState.objectContext →
// ConnectionManager 拉取的对象列表(懒加载)。未选择库时显示空态提示。
// 性能优化:
//   1. 垂直 ListView.builder + itemExtent 只构建可见行(懒加载)
//   2. 每行通过 Row 横向排列各列对应项,保持列优先顺序
//   3. Selector 精确重建每个表项,选中操作不触发全面板重建
//   4. GestureDetector 替代 InkWell 消除 Material 墨水动画开销
//   5. const TableIcon 共享同一 CustomPaint 实例,避免重复分配
class ObjectPanel extends StatefulWidget {
  const ObjectPanel({super.key});

  @override
  State<ObjectPanel> createState() => _ObjectPanelState();
}

class _ObjectPanelState extends State<ObjectPanel> {
  /// 订阅 ConnectionManager:表列表加载完成后重建面板
  ConnectionManager? _listenedManager;

  /// 工具栏搜索框输入文本(小写),用于过滤当前分类的对象列表
  String _objectSearchText = '';

  /// 上一次对象浏览上下文键,用于检测切换时重置搜索
  String _lastContextKey = '';

  void _onManagerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final manager = context.read<AppState>().connectionManager;
    if (_listenedManager != manager) {
      _listenedManager?.removeListener(_onManagerChanged);
      _listenedManager = manager;
      manager.addListener(_onManagerChanged);
    }
  }

  @override
  void dispose() {
    _listenedManager?.removeListener(_onManagerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    // 布局模式(网格/列表)变化时才重建
    final grid = context.select<AppState, bool>((a) => a.objectGridLayout);
    // 对象浏览上下文变化时重建(未选择库 → 空态)
    final (connection, database, schema) = context.select<AppState, (String?, String?, String?)>(
        (a) => (a.objectConnection, a.objectDatabase, a.objectSchema));
    // 浏览分类(表 / 视图 / 函数 / 查询 / 备份)变化时重建
    final category =
        context.select<AppState, ObjectCategory>((a) => a.objectCategory);

    if (connection == null || database == null) {
      // 未选择数据库:操作栏整体禁用(保留全部操作位但灰显不可点),
      // 内容区直接留白,不展示任何数据或空态提示
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDisabledToolbar(t, category),
          Expanded(child: _blank(t)),
        ],
      );
    }

    // 切换连接 / 库 / 模式 / 分类时重置搜索文本(_ToolbarSearch 通过 Key 重建,
    // 其内部 controller / 展开态随之清空,与此处重置保持一致)
    final contextKey = '$connection|$database|$schema|$category';
    if (contextKey != _lastContextKey) {
      _lastContextKey = contextKey;
      _objectSearchText = '';
    }

    final app = context.read<AppState>();

    // 当前连接的数据库类型 id(用于按类型区分"新建表"按钮行为:
    // MySQL 系无下拉;PostgreSQL 系点击主体建常规表、箭头下拉 常规/外部/分区)
    String? typeId;
    for (final conn in app.connections) {
      if (conn.name == connection) {
        typeId = conn.typeId;
        break;
      }
    }

    final state = app.connectionManager
        .tableStateOf(connection, database, schema: schema);

    // 有模式层(PostgreSQL / SQL Server)时,库级(schema==null)不是有效的
    // 对象展示层——表归属于具体模式,需展开并选择模式后才展示数据
    if (typeId != null &&
        kSchemaLayerTypes.contains(typeId) &&
        schema == null) {
      // 有模式层但未选模式:内容区留白,不展示数据或提示
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDisabledToolbar(t, category),
          Expanded(child: _blank(t)),
        ],
      );
    }

    // 上下文已设置但对象列表尚未加载(数据库 / 模式未打开):
    // 不展示任何数据,操作栏整体禁用——单击节点 ≠ 打开节点
    if (state.status == LoadStatus.idle) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDisabledToolbar(t, category),
          Expanded(child: _blank(t)),
        ],
      );
    }

    // 顶部工具栏(含新增按钮) + 内容区:列表展示时工具栏固定一行
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 工具栏随选中态变化重建:打开 / 设计按钮的可用性依赖当前选中表
        ValueListenableBuilder<Set<String>>(
          valueListenable: app.selectionNotifier,
          builder: (context, selected, _) => _buildToolbar(
            t,
            category,
            typeId,
            selected,
            connection,
            database,
            schema,
          ),
        ),
        Expanded(
          child: _buildContent(
            t,
            app,
            connection,
            database,
            schema,
            state,
            category,
            grid,
          ),
        ),
      ],
    );
  }

  /// 顶部工具栏:按当前对象分类(表 / 视图 / 函数 / 用户 / 查询)展示
  /// 打开/设计/新建/删除/导入/导出等操作,图标使用语义强调色。
  /// 具体 DDL 能力尚未实现,点击后弹出占位提示。
  Widget _buildToolbar(
    AppPalette t,
    ObjectCategory category,
    String? typeId,
    Set<String> selected,
    String connection,
    String database,
    String? schema,
  ) {
    final app = context.read<AppState>();
    final c = AppColors.of(context);
    final label = category.label;
    // 只有表 / 视图 / 函数 / 过程有"设计"语义
    final canDesign = switch (category) {
      ObjectCategory.table ||
      ObjectCategory.view ||
      ObjectCategory.function ||
      ObjectCategory.procedure => true,
      _ => false,
    };
    // 选中态门控:打开表需要至少选中一项;设计需精确选中一个对象
    final hasSelection = selected.isNotEmpty;
    final singleSelection = selected.length == 1;
    final canDesignEnabled = singleSelection && canDesign;

    // 导入 / 导出向导目前只对表有意义,且要求精确选中一张表(目标唯一)
    final canImportExport = category == ObjectCategory.table &&
        singleSelection &&
        app.connectionManager.isConnected(connection);
    final transferTable = canImportExport ? selected.single : null;

    // 例程分类(函数 / 过程)支持「新建函数 / 新建过程」向导
    final isRoutine = category == ObjectCategory.function ||
        category == ObjectCategory.procedure;

    final stripTokens = _toolbarTokens(t);

    return ToolStrip(
      tokens: stripTokens,
      trailing: ExpandableSearch(
        key: ValueKey('$connection|$database|$category'),
        tokens: stripTokens,
        onChanged: (v) => setState(() => _objectSearchText = v.toLowerCase()),
      ),
      items: [
        // 打开:表 / 视图 / 实体化视图打开数据页;函数 / 过程打开设计页;
        // 查询打开已保存查询到编辑页
        ToolStripButton(
          icon: Icons.folder_open_outlined,
          iconColor: c.iconWarning,
          text: '打开$label',
          enabled: hasSelection,
          onPressed: hasSelection
              ? () {
                  if (category == ObjectCategory.table ||
                      category == ObjectCategory.view ||
                      category == ObjectCategory.materializedView) {
                    for (final name in selected) {
                      app.openTable(
                        name,
                        connection: connection,
                        database: database,
                        schema: schema,
                        select: false,
                      );
                    }
                  } else if (category == ObjectCategory.function ||
                      category == ObjectCategory.procedure) {
                    for (final name in selected) {
                      app.designRoutine(
                        name,
                        connection: connection,
                        database: database,
                        category: category,
                        schema: schema,
                      );
                    }
                  } else if (category == ObjectCategory.query) {
                    for (final name in selected) {
                      final q = app.savedQueryOf(
                        name,
                        connection: connection,
                        database: database,
                      );
                      if (q != null) app.openSavedQuery(q);
                    }
                  } else {
                    _showStub('打开$label');
                  }
                }
              : null,
        ),
        if (canDesign)
          ToolStripButton(
            icon: Icons.edit_outlined,
            iconColor: c.iconPrimary,
            text: '设计$label',
            enabled: canDesignEnabled,
            onPressed: canDesignEnabled
                ? () {
                    final name = selected.single;
                    if (category == ObjectCategory.table) {
                      app.designTable(
                        name,
                        connection: connection,
                        database: database,
                        schema: schema,
                      );
                    } else {
                      app.designRoutine(
                        name,
                        connection: connection,
                        database: database,
                        category: category,
                        schema: schema,
                      );
                    }
                  }
                : null,
          ),
        // 新建表:随数据库类型表现不同
        // - PostgreSQL 系:分离式按钮,点击主体 = 新建常规表,箭头下拉
        //   展示 常规 / 外部 / 分区 三种
        // - 其它(MySQL 等):普通按钮,点击直接新建表,无下拉选项
        if (category == ObjectCategory.table)
          const {
            'postgresql',
            'aliyun-rds-postgres',
            'aliyun-polardb-postgres',
            'aliyun-oceanbase-postgres',
          }.contains(typeId)
              ? ToolStripDropDownButton(
                  icon: Icons.add_circle_outline,
                  iconColor: c.iconSuccess,
                  text: '新建$label',
                  onPressed: () =>
                      app.newTableDesigner(connection: connection, database: database, schema: schema),
                  items: [
                    ToolStripDropDownEntry(
                      text: '常规',
                      onPressed: () => app.newTableDesigner(
                          connection: connection, database: database, schema: schema),
                    ),
                    ToolStripDropDownEntry(
                      text: '外部',
                      onPressed: () => _showStub('新建外部表'),
                    ),
                    ToolStripDropDownEntry(
                      text: '分区',
                      onPressed: () => _showStub('新建分区表'),
                    ),
                  ],
                )
              : ToolStripButton(
                  icon: Icons.add_circle_outline,
                  iconColor: c.iconSuccess,
                  text: '新建$label',
                  onPressed: () =>
                      app.newTableDesigner(connection: connection, database: database, schema: schema),
                )
        else if (category == ObjectCategory.query)
          // 新建查询:直接打开查询编辑页(自动关联当前连接 / 库)
          ToolStripButton(
            icon: Icons.add_circle_outline,
            iconColor: c.iconSuccess,
            text: '新建查询',
            onPressed: () => app.newQuery(),
          )
        else if (isRoutine)
          // 新建函数 / 新建过程:打开函数向导(两步:类型 + 名称 → 参数)。
          // 类型支持过程时用下拉二选一,否则直接进入向导(初始分类固定)
          RoutineSql.supportsProcedure(typeId ?? '')
              ? ToolStripDropDownButton(
                  icon: Icons.add_circle_outline,
                  iconColor: c.iconSuccess,
                  text: category == ObjectCategory.procedure ? '新建过程' : '新建函数',
                  onPressed: () => showFunctionWizard(
                    context,
                    app: app,
                    connection: connection,
                    database: database,
                    schema: schema,
                    initialCategory: category,
                  ),
                  items: [
                    ToolStripDropDownEntry(
                      text: '新建函数',
                      onPressed: () => showFunctionWizard(
                        context,
                        app: app,
                        connection: connection,
                        database: database,
                        schema: schema,
                        initialCategory: ObjectCategory.function,
                      ),
                    ),
                    ToolStripDropDownEntry(
                      text: '新建过程',
                      onPressed: () => showFunctionWizard(
                        context,
                        app: app,
                        connection: connection,
                        database: database,
                        schema: schema,
                        initialCategory: ObjectCategory.procedure,
                      ),
                    ),
                  ],
                )
              : ToolStripButton(
                  icon: Icons.add_circle_outline,
                  iconColor: c.iconSuccess,
                  text: '新建$label',
                  onPressed: () => showFunctionWizard(
                    context,
                    app: app,
                    connection: connection,
                    database: database,
                    schema: schema,
                    initialCategory: category,
                  ),
                )
        else
          ToolStripButton(
            icon: Icons.add_circle_outline,
            iconColor: c.iconSuccess,
            text: '新建$label',
            onPressed: () => _showStub('新建$label'),
          ),
        // 删除:查询分类删除本地已保存的查询(确认后执行);
        // 其余对象分类走真实 DDL(DROP)删除
        ToolStripButton(
          icon: Icons.remove_circle_outline,
          iconColor: const Color(0xFFDC2626),
          text: '删除$label',
          enabled: hasSelection,
          onPressed: hasSelection
              ? () {
                  if (category == ObjectCategory.query) {
                    _deleteQueries(selected, connection, database);
                  } else if (category == ObjectCategory.backup) {
                    _showStub('删除$label');
                  } else {
                    _deleteObjects(category, selected.toList(),
                        connection: connection,
                        database: database,
                        schema: schema);
                  }
                }
              : null,
        ),
        if (category == ObjectCategory.table) ...[
          ToolStripButton(
            icon: Icons.file_download_outlined,
            iconColor: c.iconSuccess,
            text: '导入向导',
            enabled: canImportExport,
            onPressed: canImportExport
                ? () => _openImportWizard(transferTable!, connection, database, schema)
                : null,
          ),
          ToolStripButton(
            icon: Icons.file_upload_outlined,
            iconColor: const Color(0xFFE9A23B),
            text: '导出向导',
            enabled: canImportExport,
            onPressed: canImportExport
                ? () => _openExportWizard(transferTable!, connection, database, schema)
                : null,
          ),
        ],
      ],
    );
  }

  /// 无数据库上下文时显示的工具栏:保留正常工具栏的全部操作位,
  /// 但每个按钮均禁用(灰显不可点),符合「数据库未打开时整个操作栏禁用」的预期。
  /// 分类按钮的文案 / 布局与正常工具栏保持一致(查询分类的新建按钮为「新建查询」)。
  Widget _buildDisabledToolbar(AppPalette t, ObjectCategory category) {
    final c = AppColors.of(context);
    final label = category.label;
    // 与正常工具栏一致:仅表 / 视图 / 函数 / 过程有「设计」语义;导入 / 导出仅对表有意义
    final canDesign = switch (category) {
      ObjectCategory.table ||
      ObjectCategory.view ||
      ObjectCategory.function ||
      ObjectCategory.procedure => true,
      _ => false,
    };
    final canImportExport = category == ObjectCategory.table;
    final newText = category == ObjectCategory.query ? '新建查询' : '新建$label';
    return ToolStrip(
      tokens: _toolbarTokens(t),
      items: [
        ToolStripButton(
          icon: Icons.folder_open_outlined,
          iconColor: c.iconWarning,
          text: '打开$label',
          enabled: false,
        ),
        if (canDesign)
          ToolStripButton(
            icon: Icons.edit_outlined,
            iconColor: c.iconPrimary,
            text: '设计$label',
            enabled: false,
          ),
        ToolStripButton(
          icon: Icons.add_circle_outline,
          iconColor: c.iconSuccess,
          text: newText,
          enabled: false,
        ),
        ToolStripButton(
          icon: Icons.remove_circle_outline,
          iconColor: const Color(0xFFDC2626),
          text: '删除$label',
          enabled: false,
        ),
        if (canImportExport) ...[
          ToolStripButton(
            icon: Icons.file_download_outlined,
            iconColor: c.iconSuccess,
            text: '导入向导',
            enabled: false,
          ),
          ToolStripButton(
            icon: Icons.file_upload_outlined,
            iconColor: const Color(0xFFE9A23B),
            text: '导出向导',
            enabled: false,
          ),
        ],
      ],
    );
  }

  /// 对象面板工具栏的 tokens:背景对齐顶部标题栏背景(t.surface),并据此
  /// 派生 hover/pressed(暗色提亮、亮色加深),使整条与标题栏视觉一致。
  DesktopTokens _toolbarTokens(AppPalette t) {
    final isDark = t.surface.computeLuminance() < 0.5;
    final hoverBlend =
        isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.08);
    final pressedBlend =
        isDark ? Colors.white.withValues(alpha: 0.14) : Colors.black.withValues(alpha: 0.14);
    return t.toDesktopTokens().copyWith(
      controlColor: t.surface,
      controlHoverColor: Color.alphaBlend(hoverBlend, t.surface),
      controlPressedColor: Color.alphaBlend(pressedBlend, t.surface),
    );
  }

  /// 「导入向导」入口:把 CSV / JSON 文件导入选中的表
  Future<void> _openImportWizard(
    String table,
    String connection,
    String database,
    String? schema,
  ) async {
    final app = context.read<AppState>();
    final conn = app.connectionByName(connection);
    if (conn == null) return;
    await showDataImportWizard(
      context,
      app: app,
      conn: conn,
      database: database,
      table: table,
      schema: schema,
    );
  }

  /// 「导出向导」入口:把选中的表导出为 CSV / SQL / JSON 文件
  Future<void> _openExportWizard(
    String table,
    String connection,
    String database,
    String? schema,
  ) async {
    final app = context.read<AppState>();
    final conn = app.connectionByName(connection);
    if (conn == null) return;
    await showDataExportWizard(
      context,
      app: app,
      conn: conn,
      database: database,
      table: table,
      schema: schema,
    );
  }

  /// 占位提示:未实现的功能统一弹窗告知用户。
  void _showStub(String action) {
    MessageBox.show(
      context,
      title: action,
      message: '$action 功能开发中,敬请期待',
      okText: '知道了',
    );
  }

  /// 删除选中的已保存查询(确认后执行,并清空面板选中)
  Future<void> _deleteQueries(
    Set<String> selected,
    String connection,
    String database,
  ) async {
    final message = selected.length == 1
        ? '确定要删除查询「${selected.single}」吗?\n删除后可重新保存,打开着的查询页不受影响。'
        : '确定要删除选中的 ${selected.length} 个查询吗?';
    final result = await MessageBox.show(
      context,
      title: '删除查询',
      message: message,
      type: MessageBoxType.warning,
      buttons: MessageBoxButtons.okCancel,
      okText: '删除',
    );
    if (result != MessageBoxResult.ok || !mounted) return;
    final app = context.read<AppState>();
    for (final name in selected) {
      app.deleteSavedQuery(name, connection: connection, database: database);
    }
    app.clearObjectSelection();
  }

  /// 删除选中对象(表 / 视图 / 实体化视图 / 函数 / 过程):确认后 DROP 并刷新列表。
  /// 失败项弹窗提示,其余照常刷新。
  Future<void> _deleteObjects(
    ObjectCategory category,
    List<String> names, {
    required String connection,
    required String database,
    String? schema,
  }) async {
    final label = category.label;
    final message = names.length == 1
        ? '确定要删除$label「${names.single}」吗?\n此操作会永久删除该对象,且不可恢复。'
        : '确定要删除选中的 ${names.length} 个$label吗?\n此操作会永久删除这些对象,且不可恢复。';
    final result = await MessageBox.show(
      context,
      title: '删除$label',
      message: message,
      type: MessageBoxType.warning,
      buttons: MessageBoxButtons.okCancel,
      okText: '删除',
    );
    if (result != MessageBoxResult.ok || !mounted) return;
    final app = context.read<AppState>();
    final failed = await app.dropObjects(
      category,
      names,
      connection: connection,
      database: database,
      schema: schema,
    );
    if (!mounted) return;
    app.clearObjectSelection();
    if (failed.isNotEmpty) {
      MessageBox.show(
        context,
        title: '删除$label',
        message: '删除失败:${failed.join(', ')}\n请检查连接状态或对象是否存在。',
        type: MessageBoxType.error,
        okText: '知道了',
      );
    }
  }

  /// 内容区:按加载状态渲染(加载中 / 错误重试 / 空态 / 网格或列表)
  Widget _buildContent(
    AppPalette t,
    AppState app,
    String connection,
    String database,
    String? schema,
    TableListState state,
    ObjectCategory category,
    bool grid,
  ) {
    // 查询分类:列表来自本地已保存查询(不依赖驱动的加载状态,
    // 无需等待库对象列表拉取)
    if (category == ObjectCategory.query) {
      return _renderItems(
        t,
        app,
        [
          for (final q in app.savedQueriesOf(connection, database)) q.name,
        ],
        category,
        grid,
      );
    }
    switch (state.status) {
      case LoadStatus.idle:
      case LoadStatus.loading:
        return _stateView(
          t,
          icon: const Spinner(size: 20),
          title: '正在加载 $database 的对象列表 ...',
        );
      case LoadStatus.error:
        return _stateView(
          t,
          icon: const Icon(Icons.error_outline),
          title: '打开 $database 失败',
          description: state.error,
          action: Button(
            text: '重试',
            onPressed: () => _retryAll(app, connection, database, schema),
          ),
        );
      case LoadStatus.loaded:
        break;
    }

    // 分类级降级:某一类对象单独读取失败(典型如「角色」要读 mysql.user /
    // pg_roles,生产只读账号普遍无权限),表与视图仍可用 —— 只在本分类内
    // 提示原因并可重试,不再让整个库显示为加载失败
    final categoryError = state.categoryErrorOf(category);
    if (categoryError != null) {
      return _stateView(
        t,
        icon: const Icon(Icons.error_outline),
        title: '${category.label}列表读取失败',
        description: categoryError,
        action: Button(
          text: '重试',
          onPressed: () => _retryAll(app, connection, database, schema),
        ),
      );
    }

    // 当前分类的子项列表(查询分类已在上方提前返回,不会走到这里);
    // 列表字段空安全兑底:热重载后旧实例的 views/functions 可能为 null
    final rawItems = switch (category) {
      ObjectCategory.table => state.tables ?? const <String>[],
      ObjectCategory.view => state.views ?? const <String>[],
      ObjectCategory.materializedView => state.materializedViews ?? const <String>[],
      ObjectCategory.function => state.functions ?? const <String>[],
      ObjectCategory.procedure => state.procedures ?? const <String>[],
      ObjectCategory.user => state.users ?? const <String>[],
      ObjectCategory.query => const <String>[],
      ObjectCategory.backup => const <String>[],
    };
    if (rawItems.isEmpty) {
      return _blank(t);
    }

    return _renderItems(
      t,
      app,
      rawItems,
      category,
      grid,
    );
  }

  /// 搜索过滤 + 网格 / 列表渲染(表与查询面板共用);过滤后无匹配时留白
  Widget _renderItems(
    AppPalette t,
    AppState app,
    List<String> rawItems,
    ObjectCategory category,
    bool grid,
  ) {
    // 应用搜索过滤(_objectSearchText 已小写,子串匹配)
    final items = _objectSearchText.isEmpty
        ? rawItems
        : rawItems
            .where((n) => n.toLowerCase().contains(_objectSearchText))
            .toList();
    if (items.isEmpty) {
      // 无匹配(或分类为空):留白,不展示空态提示
      return _blank(t);
    }

    // 回写顺序列表供 Shift 范围选择(与可见项一致)
    app.setObjectTables(items);

    return grid
        ? _buildGrid(t, items, category)
        : _buildList(t, items, category);
  }

  /// 按连接名取 ConnectionInfo(重试时需要)
  ConnectionInfo _connOf(AppState app, String connection) {
    return app.connections.firstWhere((c) => c.name == connection);
  }

  /// 多列网格(详细布局,默认):按列优先排布,与设计稿一致
  Widget _buildGrid(AppPalette t, List<String> items, ObjectCategory category) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const itemWidth = 210.0;
        const itemHeight = 28.0;

        final cols = (constraints.maxWidth / itemWidth).floor().clamp(1, 8);

        final rows = (items.length / cols).ceil();

        return Container(
          color: t.background,
          child: ListView.builder(
            // ignore: deprecated_member_use
            cacheExtent: 500,
            itemExtent: itemHeight,
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
            itemCount: rows,
            itemBuilder: (context, rowIndex) {
              return Row(
                children: [
                  for (int col = 0; col < cols; col++)
                    _buildCell(
                      context,
                      col,
                      rows,
                      rowIndex,
                      items,
                      itemWidth,
                      category,
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// 单列列表:每行一个对象(图标 + 名称),行高与网格单元格一致
  Widget _buildList(AppPalette t, List<String> items, ObjectCategory category) {
    return Container(
      color: t.background,
      child: ListView.builder(
        itemExtent: 28,
        itemCount: items.length,
        itemBuilder: (context, index) =>
            _buildObjectItem(context, items[index], category),
      ),
    );
  }

  Widget _buildCell(
    BuildContext context,
    int col,
    int rows,
    int rowIndex,
    List<String> items,
    double itemWidth,
    ObjectCategory category,
  ) {
    final index = col * rows + rowIndex;

    // 空白补位
    if (index >= items.length) {
      return SizedBox(
        width: itemWidth,
        height: 28,
      );
    }

    return SizedBox(
      width: itemWidth,
      child: RepaintBoundary(
        child: _buildObjectItem(context, items[index], category),
      ),
    );
  }

  /// 内容区状态视图(加载中 / 错误):复用 base-ui 的 [Empty]。
  /// 手绘 `Row(mainAxisSize.min)` + `Flexible(Text)` 会把整行撑到容器全宽,
  /// 长错误文本被挤成一行省略号、重试按钮贴到右缘甚至被裁掉;[Empty] 的
  /// `maxWidth` 让文本在固定宽度内换行居中,按钮紧随其下。
  Widget _stateView(
    AppPalette t, {
    required Widget icon,
    required String title,
    String? description,
    Widget? action,
  }) {
    return Container(
      color: t.background,
      child: Empty(
        icon: icon,
        title: title,
        description: description,
        action: action,
        compact: true,
        maxWidth: 520,
      ),
    );
  }

  /// 重新拉取当前库 / 模式的全部对象列表(整体失败与单分类降级共用入口)
  void _retryAll(
      AppState app, String connection, String database, String? schema) {
    final connInfo = _connOf(app, connection);
    if (schema == null) {
      app.connectionManager.retryExpandDatabase(connInfo, database);
    } else {
      app.connectionManager.retryExpandSchema(connInfo, database, schema);
    }
  }

  /// 空白内容区:无数据时直接留白,不展示任何数据或空态提示
  Widget _blank(AppPalette t) => Container(color: t.background);
}

/// 对象实例图标尺寸:与连接树分组节点图标共用 [kObjectIconSize]
/// (db_types.dart 定义,调整时只改一处)
const double _objectIconSize = kObjectIconSize;

/// 对象实例图标:与对应分组节点同源的自绘 SVG(assets/icons/ui/*);
/// 尺寸与连接树分组节点图标一致(单一数据源 ObjectCategoryIcon)
Widget _objectItemIcon(BuildContext context, ObjectCategory category) =>
    ObjectCategoryIcon(category: category, size: _objectIconSize);

/// 单个表项:ValueListenableBuilder 监听按项独立通知器,仅重建变化的 1~2 项;
/// 行交互(选中 PointerDown 零延迟 / 双击独立手势 / hover)由 base-ui 的
/// [ListItem] 承担,不再自绘手势与状态。
Widget _buildObjectItem(
  BuildContext context,
  String name,
  ObjectCategory category,
) {
  final t = Tokens.of(context);
  final app = context.read<AppState>();
  final notifier = app.itemNotifierFor(name);

  return ValueListenableBuilder<bool>(
      valueListenable: notifier,
      builder: (context, selected, _) {
        // 选中走 Listener.onPointerDown:一旦注册 onDoubleTap,
        // 手势竞技场会被 DoubleTapGestureRecognizer hold 住约 300ms,
        // onTap 必须等竞技场解决后才触发,这就是单击卡顿的来源
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            app.selectTable(name);
            // 右键表实例 → 表上下文菜单(打开 / 删除 / 清空 / 设计 / 转储SQL / 复制重命名);
            // 右键函数 / 过程 → 例程菜单(设计 / 删除)。
            // 仅当面板已关联连接与库时弹出(正常浏览对象时必然满足)
            if (event.buttons == kSecondaryMouseButton &&
                app.objectConnection != null &&
                app.objectDatabase != null) {
              ConnectionInfo? conn;
              for (final c in app.connections) {
                if (c.name == app.objectConnection) {
                  conn = c;
                  break;
                }
              }
              if (conn != null) {
                if (category == ObjectCategory.table) {
                  showTableContextMenu(
                    context: context,
                    app: app,
                    conn: conn,
                    database: app.objectDatabase!,
                    table: name,
                    schema: app.objectSchema,
                    position: event.position,
                  );
                } else if (category == ObjectCategory.function ||
                    category == ObjectCategory.procedure) {
                  showRoutineContextMenu(
                    context: context,
                    app: app,
                    category: category,
                    conn: conn,
                    database: app.objectDatabase!,
                    name: name,
                    schema: app.objectSchema,
                    position: event.position,
                  );
                }
              }
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 双击:表 / 视图 / 实体化视图打开数据页;函数 / 过程打开设计页
            onDoubleTap: switch (category) {
              ObjectCategory.table ||
              ObjectCategory.view ||
              ObjectCategory.materializedView => () => app.openTable(
                    name,
                    connection: app.objectConnection!,
                    database: app.objectDatabase!,
                    schema: app.objectSchema,
                  ),
              ObjectCategory.function ||
              ObjectCategory.procedure => () => app.designRoutine(
                    name,
                    connection: app.objectConnection!,
                    database: app.objectDatabase!,
                    category: category,
                    schema: app.objectSchema,
                  ),
              _ => null,
            },
            child: SizedBox(
              height: 28,
              child: ColoredBox(
                color: selected ? t.treeSelectedBg : Colors.transparent,
                child: Row(
                  children: [
                    const SizedBox(width: 10),
                    // 对象实例图标:与对应分组节点同源的 PNG
                    _objectItemIcon(context, category),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: t.foreground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
}

/// 对象面板工具栏最右侧的可展开搜索框(base-ui [ExpandableSearch]):
/// 收起时是放大镜图标按钮,点击展开为输入框(自动聚焦);
/// 清空内容并失焦或点关闭按钮时收起。输入经 [ExpandableSearch.onChanged] 上抛。
