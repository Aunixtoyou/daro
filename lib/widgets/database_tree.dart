import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:base_ui_flutter/base_ui_flutter.dart';
import '../app/app_state.dart';
import '../app/connection_manager.dart';
import '../data/db_data.dart';
import '../data/db_types.dart';
import '../data/drivers/db_driver.dart';
import '../pages/connection_dialog_page.dart';
import '../theme/app_theme.dart';
import 'create_database_dialog.dart';
import 'create_schema_dialog.dart';
import 'function_wizard_dialog.dart';
import 'object_category_icon.dart';
import 'rename_schema_dialog.dart';
import 'sql_file_run_dialog.dart';
import 'table_context_menu.dart';

class DatabaseTree extends StatefulWidget {
  const DatabaseTree({super.key});

  @override
  State<DatabaseTree> createState() => _DatabaseTreeState();
}

class _DatabaseTreeState extends State<DatabaseTree> {
  /// 树节点图标尺寸(连接/库/模式/分组):与对象面板共用 [kObjectIconSize]
  static const double _treeIconSize = kObjectIconSize;

  /// 对象行图标尺寸(表/视图/函数):原 13px,累计调大 10% ×3
  static const double _objectIconSize = 17.3;

  /// 展开节点 key 集合:连接名 / "连接名|库" / "连接名|库|模式"。
  /// 分组(表 / 视图 / 函数 / 用户 / 查询)不可展开,不入此集合。
  final Set<String> _expanded = {};

  /// 已打开节点 key 集合:记录曾通过 SQL 获取过下级数据的节点。
  /// 折叠不清除;右键「关闭」库 / 模式或关闭连接时清除(节点回到灰色未打开态,
  /// 再次打开需重新拉取)。用于控制箭头显隐与灰色态。
  final Set<String> _opened = {};

  final ValueNotifier<String?> _selectedNode = ValueNotifier<String?>(null);

  final _searchController = TextEditingController();

  /// 订阅 ConnectionManager:真实连接的库/表列表加载完成后重建树
  ConnectionManager? _listenedManager;

  /// 订阅 AppState:Ribbon 按钮点击后展开祖先并选中分组节点
  AppState? _listenedApp;

  void _onManagerChanged() {
    if (mounted) setState(() {});
  }

  /// Ribbon 快速切换时:仅联动选中当前上下文库对应的分组节点,
  /// 不改动树的展开状态——连接/库/模式/分组保持用户原有的展开/折叠,
  /// 分组子树(对象列表)也不强制展开。数据加载仍触发,展开后即可见。
  void _onTreeNavigate() {
    final app = _listenedApp;
    if (app == null) return;
    final conn = app.objectConnection;
    final db = app.objectDatabase;
    if (conn == null || db == null) return;
    final schema = app.objectSchema;
    final category = app.objectCategory;
    // 分组节点 key 随层级变化:有模式层时为 连接|库|模式|分类,否则 连接|库|分类
    _selectedNode.value = schema == null
        ? '$conn|$db|${category.name}'
        : '$conn|$db|$schema|${category.name}';
    // 仅联动高亮分组节点,不触发任何加载——数据加载由展开(打开)树节点驱动;
    // 库/模式未打开时分组节点本就不可见,选中无视觉效果也不报错
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.read<AppState>();
    final manager = app.connectionManager;
    if (_listenedManager != manager) {
      _listenedManager?.removeListener(_onManagerChanged);
      _listenedManager = manager;
      manager.addListener(_onManagerChanged);
    }
    if (_listenedApp != app) {
      _listenedApp?.treeNavigate.removeListener(_onTreeNavigate);
      _listenedApp = app;
      app.treeNavigate.addListener(_onTreeNavigate);
    }
  }

  void _toggle(String key) => setState(() {
        _expanded.contains(key) ? _expanded.remove(key) : _expanded.add(key);
      });

  /// 折叠全部节点(底栏「折叠全部」按钮,无展开节点时按钮禁用)
  void _collapseAll() => setState(() => _expanded.clear());

  /// 统一展开 / 收起:连接 / 库 / 模式节点,单击箭头或双击整行都走此逻辑,
  /// 切换其子树展开状态,并在「首次展开」时懒加载下一级数据。
  /// 分组节点(表 / 视图 / 函数 / 用户 / 查询)不需要「打开」功能——
  /// 父级(库 / 模式)展开后其下对象行始终可见(见 _groupRows),不走这里。
  /// 叶子节点(表 / 视图 / 函数等)不在此列,各自另有双击行为。
  void _toggleNode({
    required AppState app,
    required ConnectionInfo conn,
    required NodeKind kind,
    required String key,
    String? database,
    String? schema,
  }) {
    final willExpand = !_expanded.contains(key);
    _toggle(key);
    if (!willExpand) return; // 收起时无需加载
    // 标记为已打开(曾通过 SQL 获取过下级数据)
    _opened.add(key);
    // 状态栏记录打开操作
    app.logTreeAction(switch (kind) {
      NodeKind.connection => '已打开连接「${conn.name}」',
      NodeKind.database => '已打开数据库「$database」',
      NodeKind.schema => '已打开模式「$schema」',
      _ => '已打开',
    });
    switch (kind) {
      case NodeKind.connection:
        if (hasDriver(conn)) app.connectionManager.expandConnection(conn);
      case NodeKind.database:
        if (database != null) {
          app.connectionManager.expandDatabase(conn, database);
        }
      case NodeKind.schema:
        if (database != null && schema != null) {
          app.connectionManager.expandSchema(conn, database, schema);
        }
      case NodeKind.tableGroup:
      case NodeKind.table:
        // 分组 / 叶子不可展开(分组对象行随父级展开始终可见),仅保留 case 满足穷尽
        break;
    }
  }

  void _selectNode(String key) => _selectedNode.value = key;

  /// 切换分组节点展开/折叠并在状态栏记录日志(分组打开/关闭=展开/折叠)
  void _toggleGroup(AppState app, String groupKey, String label, bool wasExpanded) {
    _toggle(groupKey);
    app.logTreeAction(wasExpanded ? '已关闭「$label」' : '已打开「$label」');
  }

  // ── 连接节点右键菜单:打开 / 关闭 / 新建库 / 编辑 / 复制 / 删除 ──

  /// 右键连接节点:弹出上下文菜单。
  /// 菜单项按需构建(连接配置在右键时才能确定),用 showContextMenu 程序化弹出
  void _showConnectionMenu(
    BuildContext context,
    AppState app,
    ConnectionInfo conn,
    Offset position,
  ) {
    final connected = app.connectionManager.isConnected(conn.name);
    showContextMenu(
      context,
      position: position,
      items: [
        if (!connected)
          MenuItem(
            text: '打开连接',
            onPressed: () => _openConnectionNode(app, conn),
          )
        else
          MenuItem(
            text: '关闭连接',
            onPressed: () => _closeConnectionNode(app, conn),
          ),
        MenuItem(
          text: '新建数据库',
          // 需连接处于打开状态(驱动已建立)才可建库;
          // 文件型数据库(SQLite / Access)无独立库概念,不支持建库
          enabled: connected && !_isFileBasedType(conn),
          onPressed: () => _createDatabaseNode(app, conn),
        ),
        MenuSeparator(),
        MenuItem(text: '编辑连接', onPressed: () => _editConnectionNode(app, conn)),
        MenuItem(text: '复制连接', onPressed: () => app.copyConnection(conn)),
        MenuSeparator(),
        MenuItem(text: '删除连接', onPressed: () => _deleteConnectionNode(app, conn)),
      ],
    );
  }

  /// 文件型数据库(SQLite / Access):单文件即一个库,无「新建数据库」概念
  static bool _isFileBasedType(ConnectionInfo conn) =>
      conn.typeId == 'sqlite' || conn.typeId == 'access';

  /// 「关闭连接」:断开服务器连接并清空该连接在树中的元数据
  /// (连接配置保留);再次展开节点时自动重连并懒加载。
  /// 同时清理树内选中 / 详情选中;若该连接正被中部对象页浏览,
  /// 同步清空对象上下文(面板回到禁用空态)。
  Future<void> _closeConnectionNode(AppState app, ConnectionInfo conn) async {
    setState(() {
      _expanded.removeWhere(
          (k) => k == conn.name || k.startsWith('${conn.name}|'));
      // 关闭连接时清除已打开状态,再次打开需要重新获取数据
      _opened.removeWhere(
          (k) => k == conn.name || k.startsWith('${conn.name}|'));
      final sel = _selectedNode.value;
      if (sel == conn.name || (sel != null && sel.startsWith('${conn.name}|'))) {
        _selectedNode.value = null;
      }
      final detail = app.detailSelection.value;
      if (detail != null && detail.connection == conn.name) {
        app.detailSelection.value = null;
      }
    });
    if (app.objectConnection == conn.name) {
      app.clearObjectContext();
    }
    app.logTreeAction('已关闭连接「${conn.name}」');
    await app.connectionManager.disconnect(conn.name);
  }

  /// 「新建数据库」:弹出名称输入对话框,成功后库列表已刷新(树无需额外动作)
  Future<void> _createDatabaseNode(AppState app, ConnectionInfo conn) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => CreateDatabaseDialog(connection: conn),
    );
  }

  // ── 数据库节点右键菜单:打开 / 新建模式 / 删除 / 新建查询 / 转储SQL ──

  /// 右键数据库节点:弹出上下文菜单。
  /// 服务器操作(新建模式 / 删除 / 转储)需连接处于打开状态;
  /// 打开与新建查询仅依赖本地上下文。
  /// 注意:建表入口不在库节点——表属于具体模式(无模式层类型为库本身),
  /// 「新建表」在「表」分组节点右键菜单中提供。
  void _showDatabaseMenu(
    BuildContext context,
    AppState app,
    ConnectionInfo conn,
    String database,
    Offset position,
  ) {
    final isOpen = app.connectionManager.isConnected(conn.name);
    final dbKey = '${conn.name}|$database';
    final isExpanded = _expanded.contains(dbKey);
    // 「打开/关闭」菜单项按打开状态(_opened)显隐,与图标状态保持一致:
    // 打开过 = 显示「关闭」,未打开 = 显示「打开」,与是否折叠无关
    final isOpened = _opened.contains(dbKey);
    showContextMenu(
      context,
      position: position,
      items: [
        if (!isOpened)
          MenuItem(
            text: '打开',
            onPressed: () => _openDatabaseNode(app, conn, database),
          )
        else
          MenuItem(
            text: '关闭',
            onPressed: () => _closeDatabaseNode(app, conn, dbKey, database),
          ),
        // 仅支持模式层的类型(PostgreSQL / SQL Server)可新建模式;
        // 需连接存活且数据库已打开(展开),否则模式列表未加载
        if (kSchemaLayerTypes.contains(conn.typeId))
          MenuItem(
            text: '新建模式',
            enabled: isOpen && isExpanded,
            onPressed: () => _createSchemaNode(app, conn, database),
          ),
        MenuItem(
          text: '删除',
          // 文件型数据库(SQLite / Access)的库节点即文件本身,不可删除
          enabled: isOpen && !_isFileBasedType(conn),
          onPressed: () => _deleteDatabaseNode(app, conn, database),
        ),
        MenuSeparator(),
        MenuItem(text: '新建查询', onPressed: () => _newQueryNode(app, conn, database)),
        // 转储SQL:仅无模式层类型(MySQL 等,database 即 schema)在数据库节点提供;
        // 有模式层的类型(PG / SQL Server)在模式节点右键提供
        if (!kSchemaLayerTypes.contains(conn.typeId)) ...[
          MenuSeparator(),
          MenuItem(
            text: '转储SQL文件',
            enabled: isOpen,
            children: [
              MenuItem(text: '仅结构', onPressed: () => _dumpDatabaseNode(app, conn, database)),
            ],
          ),
          // 还原侧入口:与转储配对,把 .sql 脚本逐条执行到该库
          MenuItem(
            text: '运行SQL文件',
            enabled: isOpen,
            onPressed: () => showRunSqlFileDialog(
              context,
              app: app,
              conn: conn,
              database: database,
            ),
          ),
        ],
      ],
    );
  }

  /// 「新建模式」:仅模式层类型(PostgreSQL / SQL Server)可用,
  /// 成功后模式列表已刷新(树通过 manager 监听重建)
  Future<void> _createSchemaNode(
      AppState app, ConnectionInfo conn, String database) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => CreateSchemaDialog(
        connection: conn,
        database: database,
      ),
    );
  }

  // ── 模式节点右键菜单:打开模式 / 关闭模式 / 编辑模式 / 删除模式 ──

  /// 右键模式节点:弹出上下文菜单。
  /// 「打开模式」仅在当前折叠时显示,「关闭模式」仅在当前展开时显示
  /// (按 _expanded 当前展开状态判断,保证菜单操作始终可用);
  /// 编辑模式(仅 PostgreSQL 家族支持重命名)与删除模式需连接处于打开状态
  void _showSchemaMenu(
    BuildContext context,
    AppState app,
    ConnectionInfo conn,
    String database,
    String schema,
    Offset position,
  ) {
    final key = '${conn.name}|$database|$schema';
    final connected = app.connectionManager.isConnected(conn.name);
    // 「打开/关闭」菜单项按打开状态(_opened)显隐,与图标状态保持一致:
    // 打开过 = 显示「关闭模式」,未打开 = 显示「打开模式」,与是否折叠无关
    final isOpened = _opened.contains(key);
    showContextMenu(
      context,
      position: position,
      items: [
        if (isOpened)
          MenuItem(
            text: '关闭模式',
            onPressed: () =>
                _closeSchemaNode(app, conn, database, key, schema),
          )
        else
          MenuItem(
            text: '打开模式',
            onPressed: () => _openSchemaNode(app, conn, database, schema),
          ),
        MenuSeparator(),
        // SQL Server 无 ALTER SCHEMA RENAME 语法,编辑模式仅 PostgreSQL 家族展示
        if (kRenameSchemaTypes.contains(conn.typeId))
          MenuItem(
            text: '编辑模式',
            enabled: connected,
            onPressed: () => _renameSchemaNode(app, conn, database, schema),
          ),
        MenuItem(
          text: '删除模式',
          enabled: connected,
          onPressed: () => _deleteSchemaNode(app, conn, database, schema),
        ),
        MenuSeparator(),
        MenuItem(
          text: '转储SQL文件',
          enabled: connected,
          children: [
            MenuItem(text: '仅结构', onPressed: () => _dumpSchemaNode(app, conn, database, schema)),
          ],
        ),
        // 还原侧入口:与转储配对,执行上下文定位到该模式
        MenuItem(
          text: '运行SQL文件',
          enabled: connected,
          onPressed: () => showRunSqlFileDialog(
            context,
            app: app,
            conn: conn,
            database: database,
            schema: schema,
          ),
        ),
      ],
    );
  }

  /// 「打开模式」:选中模式节点、同步对象页上下文并展开加载对象
  void _openSchemaNode(
      AppState app, ConnectionInfo conn, String database, String schema) {
    final key = '${conn.name}|$database|$schema';
    _selectNode(key);
    app.detailSelection.value = SelectedNode(
      NodeKind.schema,
      schema,
      connection: conn.name,
      database: database,
    );
    app.setObjectContext(conn.name, database, schema: schema);
    if (!_expanded.contains(key)) {
      setState(() {
        _expanded.add(key);
        _opened.add(key);
      });
      app.logTreeAction('已打开模式「$schema」');
      app.connectionManager.expandSchema(conn, database, schema);
    }
  }

  /// 「关闭模式」:折叠模式节点及其子树,并清理该模式的对象数据——
  /// 清除已打开状态(节点回到灰色未打开态)、管理器对象缓存与树内选中 /
  /// 详情选中,再次打开时重新从数据库拉取。
  /// 若该模式正被中部对象页浏览,同步清空对象上下文(面板回到禁用空态)。
  void _closeSchemaNode(
      AppState app, ConnectionInfo conn, String database, String key, String schema) {
    setState(() {
      _expanded.removeWhere((k) => k == key || k.startsWith('$key|'));
      _opened.removeWhere((k) => k == key || k.startsWith('$key|'));
      final sel = _selectedNode.value;
      if (sel == key || (sel != null && sel.startsWith('$key|'))) {
        _selectedNode.value = null;
      }
      final detail = app.detailSelection.value;
      if (detail != null &&
          detail.connection == conn.name &&
          detail.database == database &&
          detail.schema == schema) {
        app.detailSelection.value = null;
      }
    });
    app.connectionManager.clearSchemaState(conn.name, database, schema);
    if (app.objectConnection == conn.name &&
        app.objectDatabase == database &&
        app.objectSchema == schema) {
      app.clearObjectContext();
    }
    app.logTreeAction('已关闭模式「$schema」');
  }

  /// 「编辑模式」:打开重命名对话框(ALTER SCHEMA ... RENAME TO)
  Future<void> _renameSchemaNode(
      AppState app, ConnectionInfo conn, String database, String schema) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => RenameSchemaDialog(
        connection: conn,
        database: database,
        schema: schema,
      ),
    );
  }

  /// 「删除模式」:确认后 DROP SCHEMA;顺带清理树中该模式子树的展开 / 选中状态
  Future<void> _deleteSchemaNode(
      AppState app, ConnectionInfo conn, String database, String schema) async {
    final result = await MessageBox.show(
      context,
      title: '删除模式',
      message: '确定要删除模式「$schema」吗?\n'
          '此操作会永久删除该模式及其全部对象,且不可恢复。',
      type: MessageBoxType.warning,
      buttons: MessageBoxButtons.okCancel,
      okText: '删除',
    );
    if (result != MessageBoxResult.ok || !mounted) return;
    final key = '${conn.name}|$database|$schema';
    setState(() {
      _expanded.removeWhere((k) => k == key || k.startsWith('$key|'));
      final sel = _selectedNode.value;
      if (sel == key || (sel != null && sel.startsWith('$key|'))) {
        _selectedNode.value = null;
      }
    });
    final outcome = await app.dropSchema(conn, database, schema);
    if (!mounted) return;
    if (!outcome.ok) {
      MessageBox.show(
        context,
        title: '删除模式',
        message: '删除失败:\n${outcome.error}',
        type: MessageBoxType.error,
        okText: '知道了',
      );
    }
  }

  /// 「打开」:展开库节点、加载对象列表并同步中部对象页上下文
  void _openDatabaseNode(AppState app, ConnectionInfo conn, String database) {
    final key = '${conn.name}|$database';
    _selectNode(key);
    app.detailSelection.value =
        SelectedNode(NodeKind.database, database, connection: conn.name, database: database);
    app.setObjectContext(conn.name, database);
    if (!_expanded.contains(key)) {
      setState(() {
        _expanded.add(key);
        _opened.add(key);
      });
      app.logTreeAction('已打开数据库「$database」');
      app.connectionManager.expandDatabase(conn, database);
    }
  }

  /// 「关闭」:折叠库节点及其子树,并清理该库的子树数据——
  /// 清除已打开状态(节点回到灰色未打开态)、管理器缓存(模式 / 对象列表)
  /// 与树内选中 / 详情选中,再次打开时重新从数据库拉取。
  /// 若该库正被中部对象页浏览,同步清空对象上下文(面板回到禁用空态)。
  void _closeDatabaseNode(
      AppState app, ConnectionInfo conn, String key, String database) {
    setState(() {
      _expanded.removeWhere((k) => k == key || k.startsWith('$key|'));
      _opened.removeWhere((k) => k == key || k.startsWith('$key|'));
      final sel = _selectedNode.value;
      if (sel == key || (sel != null && sel.startsWith('$key|'))) {
        _selectedNode.value = null;
      }
      final detail = app.detailSelection.value;
      if (detail != null &&
          detail.connection == conn.name &&
          detail.database == database) {
        app.detailSelection.value = null;
      }
    });
    app.connectionManager.clearDatabaseState(conn.name, database);
    if (app.objectConnection == conn.name && app.objectDatabase == database) {
      app.clearObjectContext();
    }
    app.logTreeAction('已关闭数据库「$database」');
  }

  // ── 分组节点右键菜单:表分组的新建表 ──

  /// 右键分组节点:仅「表」分组提供「新建表」。
  /// 打开/关闭由单击分组完成,不占菜单项。
  void _showGroupMenu(
    BuildContext context,
    AppState app,
    ConnectionInfo conn,
    String database,
    String? schema,
    Offset position,
  ) {
    showContextMenu(
      context,
      position: position,
      items: [
        MenuItem(
          text: '新建表',
          enabled: app.connectionManager.isConnected(conn.name),
          onPressed: () => _createTableNode(app, conn, database, schema: schema),
        ),
      ],
    );
  }

  /// 「新建表」:在当前库 / 模式上下文打开表设计器标签页
  void _createTableNode(
      AppState app, ConnectionInfo conn, String database,
      {String? schema}) {
    app.setObjectContext(conn.name, database, schema: schema);
    app.newTableDesigner(connection: conn.name, database: database, schema: schema);
  }

  /// 右键函数 / 过程分组节点:「新建函数 / 新建过程」(进入函数向导)。
  /// 打开/关闭由单击分组完成,不占菜单项。
  void _showRoutineGroupMenu(
    BuildContext context,
    AppState app,
    ConnectionInfo conn,
    String database,
    String? schema,
    Offset position, {
    required ObjectCategory category,
  }) {
    final isOpen = app.connectionManager.isConnected(conn.name);
    showContextMenu(
      context,
      position: position,
      items: [
        MenuItem(
          text: '新建函数',
          enabled: isOpen,
          onPressed: () => showFunctionWizard(
            context,
            app: app,
            connection: conn.name,
            database: database,
            schema: schema,
            initialCategory: ObjectCategory.function,
          ),
        ),
        MenuItem(
          text: '新建过程',
          enabled: isOpen,
          onPressed: () => showFunctionWizard(
            context,
            app: app,
            connection: conn.name,
            database: database,
            schema: schema,
            initialCategory: ObjectCategory.procedure,
          ),
        ),
      ],
    );
  }

  /// 「删除」:确认后 DROP DATABASE;顺带清理树中该库子树的展开 / 选中状态
  Future<void> _deleteDatabaseNode(
      AppState app, ConnectionInfo conn, String database) async {
    final result = await MessageBox.show(
      context,
      title: '删除数据库',
      message: '确定要删除数据库「$database」吗?\n'
          '此操作会永久删除该数据库及其所有数据,且不可恢复。',
      type: MessageBoxType.warning,
      buttons: MessageBoxButtons.okCancel,
      okText: '删除',
    );
    if (result != MessageBoxResult.ok || !mounted) return;
    final key = '${conn.name}|$database';
    setState(() {
      _expanded.removeWhere((k) => k == key || k.startsWith('$key|'));
      final sel = _selectedNode.value;
      if (sel == key || (sel != null && sel.startsWith('$key|'))) {
        _selectedNode.value = null;
      }
    });
    final outcome = await app.dropDatabase(conn, database);
    if (!mounted) return;
    if (!outcome.ok) {
      MessageBox.show(
        context,
        title: '删除数据库',
        message: '删除失败:\n${outcome.error}',
        type: MessageBoxType.error,
        okText: '知道了',
      );
    }
  }

  /// 「新建查询」:把对象浏览上下文切到该库并打开查询编辑页
  void _newQueryNode(AppState app, ConnectionInfo conn, String database) {
    app.setObjectContext(conn.name, database);
    app.newQuery();
  }

  /// 「转储SQL文件 → 仅结构」:选择保存位置,生成结构 DDL 并落盘
  Future<void> _dumpDatabaseNode(
      AppState app, ConnectionInfo conn, String database) async {
    final location = await getSaveLocation(
      acceptedTypeGroups: [XTypeGroup(label: 'SQL 文件', extensions: ['sql'])],
      suggestedName: '${database}_structure.sql',
      confirmButtonText: '保存',
    );
    if (location == null || !mounted) return;

    final sql = await app.dumpDatabaseStructure(conn, database);
    if (sql == null || !mounted) {
      MessageBox.show(
        context,
        title: '转储SQL文件',
        message: '结构读取失败:\n数据库不可用或连接已断开,请先打开连接重试。',
        type: MessageBoxType.error,
        okText: '知道了',
      );
      return;
    }

    try {
      final file = File(location.path);
      await file.writeAsString(sql);
    } catch (e) {
      if (!mounted) return;
      MessageBox.show(
        context,
        title: '转储SQL文件',
        message: '文件写入失败:\n$e',
        type: MessageBoxType.error,
        okText: '知道了',
      );
      return;
    }
    if (!mounted) return;
    MessageBox.show(
      context,
      title: '转储SQL文件',
      message: '已导出「$database」结构(仅结构,不含数据)到:\n${location.path}',
      type: MessageBoxType.info,
      okText: '知道了',
    );
  }

  /// 「转储SQL文件 → 仅结构」(模式级):选择保存位置,生成该模式下结构 DDL 并落盘
  Future<void> _dumpSchemaNode(
      AppState app, ConnectionInfo conn, String database, String schema) async {
    final location = await getSaveLocation(
      acceptedTypeGroups: [XTypeGroup(label: 'SQL 文件', extensions: ['sql'])],
      suggestedName: '${schema}_structure.sql',
      confirmButtonText: '保存',
    );
    if (location == null || !mounted) return;

    final sql = await app.dumpDatabaseStructure(conn, database, schema: schema);
    if (sql == null || !mounted) {
      MessageBox.show(
        context,
        title: '转储SQL文件',
        message: '结构读取失败:\n数据库不可用或连接已断开,请先打开连接重试。',
        type: MessageBoxType.error,
        okText: '知道了',
      );
      return;
    }

    try {
      final file = File(location.path);
      await file.writeAsString(sql);
    } catch (e) {
      if (!mounted) return;
      MessageBox.show(
        context,
        title: '转储SQL文件',
        message: '文件写入失败:\n$e',
        type: MessageBoxType.error,
        okText: '知道了',
      );
      return;
    }
    if (!mounted) return;
    MessageBox.show(
      context,
      title: '转储SQL文件',
      message: '已导出「$schema」模式结构(仅结构,不含数据)到:\n${location.path}',
      type: MessageBoxType.info,
      okText: '知道了',
    );
  }


  /// 「打开连接」:真实连接服务器并获取数据库信息(非仅展开树)。
  /// 即使节点已展开 / 已有库列表缓存,也强制重新通信刷新;
  /// 驱动不存活自动重连。成功树中显示最新库列表,失败弹窗明确报错。
  Future<void> _openConnectionNode(AppState app, ConnectionInfo conn) async {
    _selectNode(conn.name);
    if (!_expanded.contains(conn.name)) {
      setState(() => _expanded.add(conn.name));
    }
    if (!hasDriver(conn)) {
      MessageBox.show(
        context,
        title: '打开连接',
        message: '连接「${conn.name}」的数据库类型(${conn.typeId})暂不支持,无法打开。',
        type: MessageBoxType.warning,
        okText: '知道了',
      );
      return;
    }
    final (ok, message) =
        await app.connectionManager.forceExpandConnection(conn);
    if (!mounted) return;
    if (ok) {
      // 连接成功后标记为已打开并记录日志
      setState(() => _opened.add(conn.name));
      app.logTreeAction('已打开连接「${conn.name}」');
    } else {
      MessageBox.show(
        context,
        title: '打开连接',
        message: '连接「${conn.name}」失败:\n$message',
        type: MessageBoxType.error,
        okText: '知道了',
      );
    }
  }

  /// 「编辑连接」:以现有配置预填连接向导;确认后更新连接。
  /// 名称变化时迁移展开 / 选中状态,并重新加载元数据(参数可能已变)
  Future<void> _editConnectionNode(AppState app, ConnectionInfo conn) async {
    final result = await showDialog<ConnectionInfo>(
      context: context,
      builder: (_) => ConnectionDialogPage(initial: conn),
    );
    if (result == null || !mounted) return;
    final updated = await app.updateConnection(conn, result);
    if (updated == null || !mounted) return;
    if (updated.name != conn.name) {
      _migrateConnectionKeys(conn.name, updated.name);
      // 右侧详情面板跟随的选中节点同步迁移
      final detail = app.detailSelection.value;
      if (detail != null && detail.connection == conn.name) {
        app.detailSelection.value = SelectedNode(
          detail.kind,
          detail.name,
          connection: updated.name,
          database: detail.database,
          schema: detail.schema,
        );
      }
    }
    if (_expanded.contains(updated.name) && hasDriver(updated)) {
      app.connectionManager.expandConnection(updated);
    }
  }

  /// 连接改名后:迁移该连接子树的展开状态与选中状态到新名前缀
  void _migrateConnectionKeys(String oldName, String newName) {
    final prefix = '$oldName|';
    setState(() {
      final renamed = <String>{
        for (final k in _expanded)
          if (k.startsWith(prefix)) newName + k.substring(oldName.length),
      };
      _expanded
        ..removeWhere((k) => k == oldName || k.startsWith(prefix))
        ..addAll(renamed);
      final sel = _selectedNode.value;
      if (sel == oldName) {
        _selectedNode.value = newName;
      } else if (sel != null && sel.startsWith(prefix)) {
        _selectedNode.value = newName + sel.substring(oldName.length);
      }
    });
  }

  /// 「删除连接」:确认后删除并断开驱动;顺带清理树中该连接的展开状态
  Future<void> _deleteConnectionNode(AppState app, ConnectionInfo conn) async {
    final result = await MessageBox.show(
      context,
      title: '删除连接',
      message: '确定要删除连接「${conn.name}」吗?\n'
          '已打开的该连接标签页仍会保留,但将无法继续访问。',
      type: MessageBoxType.warning,
      buttons: MessageBoxButtons.okCancel,
      okText: '删除',
    );
    if (result != MessageBoxResult.ok || !mounted) return;
    setState(() {
      _expanded.removeWhere((k) => k == conn.name || k.startsWith('${conn.name}|'));
      if (_selectedNode.value == conn.name) _selectedNode.value = null;
    });
    await app.removeConnection(conn);
  }

  @override
  void dispose() {
    _listenedManager?.removeListener(_onManagerChanged);
    _listenedApp?.treeNavigate.removeListener(_onTreeNavigate);
    _selectedNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.read<AppState>();

    final connections =
        context.select<AppState, List<ConnectionInfo>>((a) => a.filteredConnections);
    final hasFilter =
        context.select<AppState, bool>((a) =>
            a.selectedDbTypes.isNotEmpty ||
            a.treeSearchText.isNotEmpty);

    final rows = <Widget>[];
    for (final conn in connections) {
      rows.addAll(_liveConnectionRows(context, app, conn));
    }

    // 空态:无任何连接 / 筛选无结果
    if (rows.isEmpty) {
      rows.add(
        SizedBox(
          height: 200,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.dns_outlined, size: 28, color: t.disabledForeground),
                const SizedBox(height: 10),
                Text(
                  hasFilter ? '没有匹配的连接' : '暂无连接',
                  style: TextStyle(color: t.mutedForeground, fontSize: 13),
                ),
                if (!hasFilter) ...[
                  const SizedBox(height: 4),
                  Text(
                    '点击工具栏「连接」按钮新建连接',
                    style: TextStyle(color: t.disabledForeground, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      color: t.background,
      child: Column(
        children: [
          Expanded(
            child: ListView(children: rows),
          ),
          _buildBottomBar(context, t, hasFilter),
        ],
      ),
    );
  }

  // ── 真实连接树:连接 → 库 → 表,展开时懒加载 ──────────────────

  /// 渲染一个真实连接的整棵子树
  List<Widget> _liveConnectionRows(
    BuildContext context,
    AppState app,
    ConnectionInfo conn,
  ) {
    final c = AppColors.of(context);
    final manager = app.connectionManager;
    final supported = hasDriver(conn);
    final rows = <Widget>[];

    // 查找连接类型对应的品牌图标定义
    DbType? dbType;
    for (final e in kAllDbTypes) {
      if (e.id == conn.typeId) { dbType = e; break; }
    }

    // 连接图标:品牌图标 + 右下角状态点;离线时品牌色去饱和
    final connected = manager.isConnected(conn.name);
    final connLeading = dbType == null
        ? null
        : DbTypeIcon(type: dbType, size: _treeIconSize, connected: connected);

    // 连接节点:展开时触发连接 + 拉取库列表
    rows.add(
      ValueListenableBuilder<String?>(
        valueListenable: _selectedNode,
        builder: (context, sel, _) => _node(
          context,
          depth: 0,
          text: conn.name,
          icon: Icons.dns,
          color: c.iconInfo,
          expanded: _expanded.contains(conn.name),
          selected: sel == conn.name,
          kind: NodeKind.connection,
          leading: connLeading,
          // 箭头 / 灰色态跟随真实连接状态:查询页等外部入口打开连接后
          // (驱动已建立,isConnected=true)即使本树未展开过也显示展开箭头;
          // 与右键菜单「已连接=显示关闭连接」的判定口径保持一致
          opened:
              _opened.contains(conn.name) || manager.isConnected(conn.name),
          onToggle: () => _toggleNode(
            app: app,
            conn: conn,
            kind: NodeKind.connection,
            key: conn.name,
          ),
          onSelect: () {
            _selectNode(conn.name);
            app.detailSelection.value =
                SelectedNode(NodeKind.connection, conn.name, connection: conn.name);
          },
          onContextMenu: (position) =>
              _showConnectionMenu(context, app, conn, position),
        ),
      ),
    );
    if (!_expanded.contains(conn.name)) return rows;

    // 尚未实现驱动的类型:展开仅提示,不发请求
    if (!supported) {
      rows.add(_hintNode(context, depth: 1, text: '暂不支持该类型,待实现驱动'));
      return rows;
    }

    // 库列表:按加载状态渲染
    final dbState = manager.databaseStateOf(conn.name);
    switch (dbState.status) {
      case LoadStatus.idle:
      case LoadStatus.loading:
        rows.add(_hintNode(context, depth: 1, text: '加载中...'));
        return rows;
      case LoadStatus.error:
        rows.add(_hintNode(
          context,
          depth: 1,
          text: '加载失败: ${dbState.error}',
          isAction: true,
          onTap: () => manager.retryExpandConnection(conn),
        ));
        return rows;
      case LoadStatus.loaded:
        break;
    }

    for (final database in dbState.databases) {
      final dbKey = '${conn.name}|$database';
      rows.add(
        ValueListenableBuilder<String?>(
          valueListenable: _selectedNode,
          builder: (context, sel, _) => _node(
            context,
            depth: 1,
            text: database,
            icon: Icons.storage,
            color: c.iconSuccess,
            expanded: _expanded.contains(dbKey),
            selected: sel == dbKey,
            kind: NodeKind.database,
            opened: _opened.contains(dbKey),
            // 图标按节点「打开过」状态切换(曾加载数据 / 右键打开 = 彩色,
            // 未打开 / 右键关闭 = 灰阶);「打开」≠ 树节点展开——折叠 / 折叠全部
            // 不清打开状态,图标不变;连接在线与否不影响库图标
            leading: UiIcon(
              _opened.contains(dbKey) ? kDatabaseIcon : kDatabaseClosedIcon,
              size: _treeIconSize,
            ),
            onToggle: () => _toggleNode(
              app: app,
              conn: conn,
              kind: NodeKind.database,
              key: dbKey,
              database: database,
            ),
            onSelect: () {
              _selectNode(dbKey);
              app.detailSelection.value = SelectedNode(
                NodeKind.database,
                database,
                connection: conn.name,
                database: database,
              );
              // 单击库节点:仅同步中部对象页浏览上下文(重置到默认模式)。
              // 单击 ≠ 打开——不触发对象列表加载;数据在展开(打开)库/模式节点时才加载,
              // 未打开时对象面板保持空态、操作栏整体禁用
              app.setObjectContext(conn.name, database);
            },
            onContextMenu: (position) =>
                _showDatabaseMenu(context, app, conn, database, position),
          ),
        ),
      );
      if (!_expanded.contains(dbKey)) continue;

      // 模式层:PostgreSQL / SQL Server 等有独立模式层的类型
      // (listSchemas 返回非空)在库与对象分组之间渲染模式节点;
      // MySQL 等 Database 即 Schema 的类型返回空,保持原有三级布局
      final schemaState = manager.schemaStateOf(conn.name, database);
      if (schemaState.status == LoadStatus.loaded &&
          schemaState.schemas.isNotEmpty) {
        for (final schema in schemaState.schemas) {
          final schemaKey = '$dbKey|$schema';
          rows.add(
            ValueListenableBuilder<String?>(
              valueListenable: _selectedNode,
              builder: (context, sel, _) => _node(
                context,
                depth: 2,
                text: schema,
                icon: Icons.folder_outlined,
                color: c.iconWarning,
                expanded: _expanded.contains(schemaKey),
                selected: sel == schemaKey,
                kind: NodeKind.schema,
                opened: _opened.contains(schemaKey),
                // 图标按节点「打开过」状态切换(曾加载数据 / 右键打开 = 彩色,
                // 未打开 / 右键关闭 = 灰阶);「打开」≠ 树节点展开——折叠 / 折叠全部
                // 不清打开状态,图标不变;连接在线与否不影响模式图标
                leading: UiIcon(
                  _opened.contains(schemaKey) ? kSchemaIcon : kSchemaClosedIcon,
                  size: _treeIconSize,
                ),
                onToggle: () => _toggleNode(
                  app: app,
                  conn: conn,
                  kind: NodeKind.schema,
                  key: schemaKey,
                  database: database,
                  schema: schema,
                ),
                onSelect: () {
                  _selectNode(schemaKey);
                  app.detailSelection.value = SelectedNode(
                    NodeKind.schema,
                    schema,
                    connection: conn.name,
                    database: database,
                  );
                  // 单击模式节点:仅同步对象页上下文,不触发加载(单击 ≠ 打开)
                  app.setObjectContext(conn.name, database, schema: schema);
                },
                onContextMenu: (position) => _showSchemaMenu(
                    context, app, conn, database, schema, position),
              ),
            ),
          );
          if (!_expanded.contains(schemaKey)) continue;
          rows.addAll(
            _groupRows(context, app, conn, database, schema, schemaKey, 3),
          );
        }
      } else {
        // 无模式层:分组直挂库节点下(原布局)
        rows.addAll(_groupRows(context, app, conn, database, null, dbKey, 2));
      }
    }
    return rows;
  }

  /// 对象分组 + 对象行(库直挂分组或模式挂分组共用)。
  /// [schema] 为 null 表示库级(默认模式)上下文;
  /// [parentKey] 为分组 key 的父前缀(库 key 或模式 key),
  /// [groupDepth] 为分组节点深度(无模式层 2 / 有模式层 3)。
  /// 分组(表 / 视图 / 函数 / 用户 / 查询)不是懒加载层级:无箭头、不可展开,
  /// 父级(库 / 模式)展开后对象行始终紧随分组渲染;单击分组仅同步对象面板分类。
  List<Widget> _groupRows(
    BuildContext context,
    AppState app,
    ConnectionInfo conn,
    String database,
    String? schema,
    String parentKey,
    int groupDepth,
  ) {
    final manager = app.connectionManager;
    final rows = <Widget>[];

    // 对象列表(表 / 视图 / 函数):按加载状态渲染
    final objState = schema == null
        ? manager.tableStateOf(conn.name, database)
        : manager.tableStateOf(conn.name, database, schema: schema);
    switch (objState.status) {
      case LoadStatus.idle:
      case LoadStatus.loading:
        rows.add(_hintNode(context, depth: groupDepth, text: '加载中...'));
        return rows;
      case LoadStatus.error:
        rows.add(_hintNode(
          context,
          depth: groupDepth,
          text: '加载失败: ${objState.error}',
          isAction: true,
          onTap: () => schema == null
              ? manager.retryExpandDatabase(conn, database)
              : manager.retryExpandSchema(conn, database, schema),
        ));
        return rows;
      case LoadStatus.loaded:
        break;
    }

    // 分组节点:按当前连接类型过滤不支持的分类(如 SQLite 不显示函数/用户)
    for (final group in _groupsForType(conn.typeId)) {
      final groupKey = '$parentKey|${group.category.name}';
      final isExpanded = _expanded.contains(groupKey);
      final groupItems = _itemsOf(objState, group.category);
      rows.add(
        ValueListenableBuilder<String?>(
          valueListenable: _selectedNode,
          builder: (context, sel, _) => _node(
            context,
            depth: groupDepth,
            text: group.category.label,
            icon: group.icon,
            color: _groupColor(context, group.category),
            // 与 Ribbon 分类按钮同源的自绘 SVG
            leading: ObjectCategoryIcon(
              category: group.category,
              size: _treeIconSize,
            ),
            expanded: isExpanded,
            selected: sel == groupKey,
            kind: NodeKind.tableGroup,
            onToggle: () =>
                _toggleGroup(app, groupKey, group.category.label, isExpanded),
            // 空分组(打开后无数据)不显示折叠按钮
            noArrow: groupItems.isEmpty,
            onSelect: () {
              _selectNode(groupKey);
              // 单击分组:仅选中并同步对象面板分类,不展开/折叠
              app.setObjectContext(conn.name, database,
                  category: group.category, schema: schema);
              app.activateTab('对象');
              // 详情面板展示父节点信息(模式层存在时为模式,否则为数据库)
              app.detailSelection.value = schema == null
                  ? SelectedNode(
                      NodeKind.database,
                      database,
                      connection: conn.name,
                      database: database,
                    )
                  : SelectedNode(
                      NodeKind.schema,
                      schema,
                      connection: conn.name,
                      database: database,
                    );
            },
            // 右键菜单:表分组提供新建表;函数 / 过程分组提供新建函数 / 新建过程
            // (打开/关闭由单击完成,不占菜单)
            onContextMenu: group.category == ObjectCategory.table
                ? (position) => _showGroupMenu(
                    context, app, conn, database, schema, position)
                : group.category == ObjectCategory.function ||
                        group.category == ObjectCategory.procedure
                    ? (position) => _showRoutineGroupMenu(
                        context, app, conn, database, schema, position,
                        category: group.category)
                    : null,
          ),
        ),
      );
      // 分类级降级:该分组单独读取失败(如「角色」无 mysql.user / pg_roles
      // 读取权限),在分组下给出可点击重试的提示行,而不是显示成空分组
      if (objState.categoryErrorOf(group.category) != null) {
        rows.add(_hintNode(
          context,
          depth: groupDepth + 1,
          text: '读取失败',
          isAction: true,
          onTap: () => schema == null
              ? manager.retryExpandDatabase(conn, database)
              : manager.retryExpandSchema(conn, database, schema),
        ));
      }
      // 仅展开时渲染子项
      if (isExpanded) {
        for (final name in groupItems) {
          rows.add(
            _liveObjectNode(
              context,
              app,
              conn,
              database,
              name,
              category: group.category,
              schema: schema,
              depth: groupDepth + 1,
              // 表实例右键:打开 / 删除 / 清空 / 设计 / 转储 / 复制重命名;
              // 函数 / 过程实例右键:设计 / 删除
              onContextMenu: group.category == ObjectCategory.table
                  ? (position) => showTableContextMenu(
                        context: context,
                        app: app,
                        conn: conn,
                        database: database,
                        table: name,
                        schema: schema,
                        position: position,
                      )
                  : group.category == ObjectCategory.function ||
                          group.category == ObjectCategory.procedure
                      ? (position) => showRoutineContextMenu(
                          context: context,
                          app: app,
                          category: group.category,
                          conn: conn,
                          database: database,
                          name: name,
                          schema: schema,
                          position: position,
                        )
                      : null,
            ),
          );
        }
      }
    }
    return rows;
  }

  /// 库下的对象分组;按数据库类型过滤不支持的分类。
  /// 图标与 Ribbon 分类按钮一致:自绘 SVG(assets/icons/ui/*)。
  /// 备份分组暂无数据源,暂时隐藏(后续支持备份功能时加回)
  static const _allGroups = <({ObjectCategory category, IconData icon})>[
    (category: ObjectCategory.table, icon: Icons.table_chart_outlined),
    (category: ObjectCategory.view, icon: Icons.visibility_outlined),
    (category: ObjectCategory.materializedView, icon: Icons.auto_awesome_motion),
    (category: ObjectCategory.function, icon: Icons.functions),
    (category: ObjectCategory.procedure, icon: Icons.settings_suggest),
    (category: ObjectCategory.user, icon: Icons.person_outline),
    (category: ObjectCategory.query, icon: Icons.description_outlined),
    // (category: ObjectCategory.backup, icon: Icons.restore),
  ];

  /// 按数据库类型过滤后的分组列表:仅返回该类型支持的分类。
  /// 例如 SQLite / Access 不显示「函数」「用户」分组。
  static List<({ObjectCategory category, IconData icon})> _groupsForType(
      String typeId) {
    return _allGroups
        .where((g) => isCategorySupportedForType(typeId, g.category.name))
        .toList();
  }

  /// 分组节点图标颜色:表 / 视图 / 实体化视图 / 函数 / 过程用表色,查询用文件夹色,备份用次要色
  Color _groupColor(BuildContext context, ObjectCategory category) {
    final c = AppColors.of(context);
    final t = Tokens.of(context);
    return switch (category) {
      ObjectCategory.table ||
      ObjectCategory.view ||
      ObjectCategory.materializedView ||
      ObjectCategory.function ||
      ObjectCategory.procedure => c.iconPrimary,
      ObjectCategory.user => c.iconSecondary,
      ObjectCategory.query => c.iconWarning,
      ObjectCategory.backup => t.mutedForeground,
    };
  }

  /// 分组下的子项列表(查询 / 备份尚未实现,暂无子项);
  /// 列表字段空安全兑底:热重载后旧实例的 views/functions 可能为 null
  List<String> _itemsOf(TableListState state, ObjectCategory category) {
    return switch (category) {
      ObjectCategory.table => state.tables ?? const [],
      ObjectCategory.view => state.views ?? const [],
      ObjectCategory.materializedView => state.materializedViews ?? const [],
      ObjectCategory.function => state.functions ?? const [],
      ObjectCategory.procedure => state.procedures ?? const [],
      ObjectCategory.user => state.users ?? const [],
      ObjectCategory.query => const [],
      ObjectCategory.backup => const [],
    };
  }

  /// 真实对象节点(表 / 视图 / 函数):单击选中(零延迟);
  /// 双击表 / 视图打开前 100 行数据页。
  /// [schema] 为该对象所属模式(无模式层类型为 null);
  /// [depth] 为节点深度(无模式层 3 / 有模式层 4),决定缩进
  Widget _liveObjectNode(
    BuildContext context,
    AppState app,
    ConnectionInfo conn,
    String database,
    String name, {
    required ObjectCategory category,
    String? schema,
    required int depth,
    void Function(Offset position)? onContextMenu,
  }) {
    final t = Tokens.of(context);
    final key = schema == null
        ? '${conn.name}|$database|${category.name}|$name'
        : '${conn.name}|$database|$schema|${category.name}|$name';
    // Listener.onPointerDown 立即选中(零延迟);
    // 双击单独走 GestureDetector,避免单击被双击判定窗口 hold;
    // 右键触发上下文菜单(表实例支持 打开 / 删除 / 清空 / 设计 / 转储 / 复制重命名)
    return ValueListenableBuilder<String?>(
      valueListenable: _selectedNode,
      builder: (context, sel, _) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          _selectNode(key);
          if (category == ObjectCategory.table ||
              category == ObjectCategory.view ||
              category == ObjectCategory.materializedView) {
            app.detailSelection.value = SelectedNode(
              NodeKind.table,
              name,
              connection: conn.name,
              database: database,
              schema: schema,
            );
          }
          if (event.buttons == kSecondaryMouseButton) {
            onContextMenu?.call(event.position);
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: switch (category) {
            ObjectCategory.table ||
            ObjectCategory.view ||
            ObjectCategory.materializedView => () => app.openTable(
                  name,
                  connection: conn.name,
                  database: database,
                  schema: schema,
                ),
            ObjectCategory.function ||
            ObjectCategory.procedure => () => app.designRoutine(
                  name,
                  connection: conn.name,
                  database: database,
                  category: category,
                  schema: schema,
                ),
            _ => null,
          },
          child: Container(
            height: 24,
            color: sel == key ? t.treeSelectedBg : null,
            // 无箭头占位:深度缩进 + 箭头宽(20)+ 间隙(4)对齐父级行文本
            padding: EdgeInsets.only(left: 4 + depth * 14.0 + 20 + 4),
            child: Row(
              children: [
                _objectIcon(category),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: t.foreground,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 对象项图标(表 / 视图 / 实体化视图 / 函数 / 角色 / 查询):
  /// 与对应分组节点同源的自绘 SVG(ObjectCategoryIcon)
  Widget _objectIcon(ObjectCategory category) =>
      ObjectCategoryIcon(category: category, size: _objectIconSize);

  /// 加载中 / 错误提示节点;isAction 为 true 时点击可重试
  Widget _hintNode(
    BuildContext context, {
    required int depth,
    required String text,
    bool isAction = false,
    VoidCallback? onTap,
  }) {
    final t = Tokens.of(context);
    Widget row = Row(
      children: [
        if (isAction)
          Icon(Icons.error_outline, size: 14, color: t.mutedForeground)
        else
          const SizedBox(width: 14),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: t.mutedForeground),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (isAction)
          Text(
            '点击重试',
            style: TextStyle(fontSize: 12, color: t.accent),
          ),
      ],
    );

    if (isAction && onTap != null) {
      row = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: row,
      );
    }

    return Container(
      height: 24,
      padding: EdgeInsets.only(left: 4.0 + depth * 14 + 20 + 4 + 6),
      child: row,
    );
  }

  Widget _buildBottomBar(
    BuildContext context,
    AppPalette t,
    bool hasFilter,
  ) {
    final app = context.read<AppState>();
    final selectedDbTypes =
        context.select<AppState, Set<String>>((a) => a.selectedDbTypes);

    // 与「新建连接」对话框一致:未实现驱动的类型禁用并标注「未实现」
    final options = [
      for (final e in kAllDbTypes)
        (
          option: CheckOption(
            id: e.id,
            label: e.label,
            leading: Opacity(
              opacity: kSupportedDriverTypes.contains(e.id) ? 1.0 : 0.35,
              child: DbTypeIcon(type: e, size: 16),
            ),
            selected: selectedDbTypes.contains(e.id),
            onToggle: kSupportedDriverTypes.contains(e.id)
                ? () => app.toggleDbTypeFilter(e.id)
                : null,
          ),
          supported: kSupportedDriverTypes.contains(e.id),
        ),
    ];

    return Container(
      height: 32,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.border, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 6, top: 3, bottom: 3),
              child: SearchInput(
                controller: _searchController,
                hintText: '搜索连接...',
                onChanged: app.setTreeSearchText,
                onCleared: () => app.setTreeSearchText(''),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Popover(
                  width: 240,
                  padding: const EdgeInsets.all(10),
                  // 开合由外层 Popover 的 Listener 处理,按钮仅提供视觉态
                  trigger: IconBtn(
                    icon: Icons.filter_list,
                    iconSize: 15,
                    color: t.disabledForeground,
                    selected: hasFilter,
                    selectedColor: t.accent,
                    // 幽灵风格:无边框,仅 hover / 选中态着色
                    size: const Size(26, 26),
                    onTap: () {},
                  ),
                  content: Builder(
                    builder: (context) {
                      final dt = TokenScope.maybeOf(context) ?? DesktopTokens.winForm;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.tune, size: 15, color: t.disabledForeground),
                              const SizedBox(width: 6),
                              Text(
                                '数据库类型筛选',
                                style: TextStyle(
                                  fontFamily: dt.fontFamily,
                                  fontSize: dt.fontSize,
                                  fontWeight: FontWeight.w600,
                                  color: t.foreground,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 220,
                            child: SingleChildScrollView(
                              child: Column(
                                children: [
                                  for (final o in options)
                                    CheckRow(
                                      option: o.option,
                                      enabled: o.supported,
                                      trailing: o.supported
                                          ? null
                                          : Text(
                                              '未实现',
                                              style: TextStyle(
                                                fontFamily: dt.fontFamily,
                                                fontSize: 11,
                                                color: t.disabledForeground,
                                                decoration: TextDecoration.none,
                                              ),
                                            ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              _searchController.clear();
                              app.clearTreeFilter();
                            },
                            child: Text(
                              '全部清除',
                              style: TextStyle(
                                fontFamily: dt.fontFamily,
                                fontSize: dt.fontSize,
                                color: t.accent,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(width: 4),
                IconBtn(
                  icon: Icons.unfold_less,
                  iconSize: 15,
                  color: t.mutedForeground,
                  tooltip: '折叠全部',
                  size: const Size(26, 26),
                  // 无展开节点时禁用(onTap 为 null → 灰显不可点)
                  onTap: _expanded.isEmpty ? null : _collapseAll,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _node(
    BuildContext context, {
    required int depth,
    required String text,
    required IconData icon,
    required Color color,
    required VoidCallback onSelect,
    required NodeKind kind,
    bool expanded = false,
    VoidCallback? onToggle,
    // 无展开功能的节点(分组):隐藏箭头(保留箭头宽占位对齐文本)、双击无动作
    bool noArrow = false,
    // 节点是否已被打开过:未打开的节点隐藏箭头并以灰色显示,
    // 打开后恢复箭头和正常颜色。分组节点(noArrow)不受此参数影响
    bool opened = true,
    bool selected = false,
    Widget? leading,
    void Function(Offset position)? onContextMenu,
  }) {
    final t = Tokens.of(context);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        onSelect();
        // 右键:选中节点并弹出上下文菜单(连接节点专用)
        if (event.buttons == kSecondaryMouseButton) {
          onContextMenu?.call(event.position);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 有子节点的节点:双击整行 = 切换子树展开 / 收起(与箭头单击同一逻辑);
        // 无展开功能的节点(noArrow)双击无动作
        onDoubleTap: noArrow ? null : onToggle,
        child: Container(
          height: 26,
          color: selected ? t.treeSelectedBg : null,
          padding: EdgeInsets.only(left: 4.0 + depth * 14),
          child: Row(
            children: [
              if (noArrow)
                // 无箭头占位:与展开节点箭头宽(20)一致,保证同级文本对齐
                const SizedBox(width: 20, height: 26)
              else if (!opened)
                // 未打开:隐藏箭头,保留占位宽度对齐文本
                const SizedBox(width: 20, height: 26)
              else
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onToggle,
                  child: SizedBox(
                    width: 20,
                    height: 26,
                    child: Icon(
                      expanded ? Icons.expand_more : Icons.chevron_right,
                      size: 16,
                      color: t.disabledForeground,
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              // leading 已由调用方按打开/关闭状态传入对应图标(如连接 ON/OFF、
              // 库 DATABASE/CLOSE、模式 SCHEMA_ON/CLOSE),不再叠加半透明灰显
              (leading ?? Icon(icon, size: _treeIconSize, color: (!noArrow && !opened) ? t.mutedForeground : color)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: (!noArrow && !opened) ? t.mutedForeground : t.foreground,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
