import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/sql.dart';
import '../app/app_state.dart';
import '../app/connection_manager.dart';
import '../data/db_types.dart';
import '../data/table_design.dart';
import '../theme/app_theme.dart';

/// 新建表设计器:pgAdmin 风格的多标签页建表流程。
///
/// 以文档标签页形式打开(见 [AppState.newTableDesigner]),含 11 个标签:
/// 字段 / 索引 / 外键 / 唯一键 / 检查 / 排除 / 规则 / 触发器 / 选项 / 注释 / SQL 预览。
/// 各标签实时采集设计数据([DesignTable]),「SQL 预览」标签按当前连接类型
/// 实时生成方言 DDL(预览即所见),点「保存」通过 [AppState.createTableDesign]
/// 逐条执行,PostgreSQL 家族在事务中执行,失败回滚。
///
/// 交互约定:行选中用 [Listener.onPointerDown] 零延迟;输入框一律
/// `selectAllOnFocus: false`(桌面聚焦全选坑);颜色全部走 [Tokens.of]。
class TableDesignerPage extends StatefulWidget {
  const TableDesignerPage({
    super.key,
    required this.title,
    required this.connection,
    required this.database,
    this.schema,
  });

  /// 标签标题(保存成功后关闭本标签用)
  final String title;

  /// 所属连接名
  final String connection;

  /// 所属数据库
  final String database;

  /// 目标模式(PostgreSQL 等有模式层的类型;无模式层为 null)
  final String? schema;

  @override
  State<TableDesignerPage> createState() => _TableDesignerPageState();
}

class _TableDesignerPageState extends State<TableDesignerPage> {
  /// 设计数据(各标签共写)
  final DesignTable _design = DesignTable();

  /// 表名输入(默认 Untitled,与参考工具一致)
  final TextEditingController _nameCtrl = TextEditingController(text: 'Untitled');

  /// SQL 预览控制器(只读,每次重建时同步 DDL 文本)
  final CodeLineEditingController _sqlCtrl = CodeLineEditingController.fromText('');

  /// 表注释输入控制器(注释标签页)
  final TextEditingController _commentCtrl = TextEditingController();

  /// 当前连接类型 id 与显示名
  String _typeId = 'postgresql';
  String _typeLabel = '';

  /// 外键引用表候选(当前模式,懒加载)
  List<String> _refTables = const [];

  bool _saving = false;
  String? _error;

  /// 设计数据是否通过校验(由 build 实时计算,用于禁用「保存」并提示)
  bool _valid = true;

  /// 校验未通过的原因(用于状态栏灰色提示)
  String _invalidReason = '';

  /// 当前活动标签索引(TabControl 内部持有选中态,通过 onChanged 同步到此)
  int _tabIndex = 0;

  /// 各标签当前选中行
  int _selColumn = 0;
  int _selIndex = -1;
  int _selFk = -1;
  int _selUnique = -1;
  int _selCheck = -1;
  int _selExclude = -1;
  int _selRule = -1;
  int _selTrigger = -1;

  // ── 下拉候选 ──────────────────────────────────────────────

  /// 常用字段类型(覆盖 PostgreSQL / MySQL 主流;类型格可输入自定义值)
  static const List<String> _typeOptions = [
    'INT',
    'INTEGER',
    'BIGINT',
    'SMALLINT',
    'TINYINT',
    'MEDIUMINT',
    'SERIAL',
    'BIGSERIAL',
    'SMALLSERIAL',
    'DECIMAL',
    'NUMERIC',
    'MONEY',
    'VARCHAR',
    'CHAR',
    'TEXT',
    'TINYTEXT',
    'MEDIUMTEXT',
    'LONGTEXT',
    'BOOLEAN',
    'BIT',
    'DATE',
    'TIME',
    'DATETIME',
    'TIMESTAMP',
    'TIMESTAMPTZ',
    'INTERVAL',
    'UUID',
    'JSON',
    'JSONB',
    'BYTEA',
    'BLOB',
    'MEDIUMBLOB',
    'LONGBLOB',
    'FLOAT',
    'DOUBLE',
    'REAL',
    'DOUBLE PRECISION',
    'INET',
    'CIDR',
    'MACADDR',
    'XML',
  ];

  /// 索引方法(PostgreSQL 全量;MySQL 仅 btree / hash,保存时由服务端校验)
  static const List<String> _indexMethods = ['btree', 'hash', 'gist', 'gin', 'brin', 'spgist'];

  /// 排除约束方法
  static const List<String> _excludeMethods = ['gist', 'spgist', 'btree', 'hash', 'gin', 'brin'];

  /// 外键删除 / 更新行为
  static const List<String> _fkActions = [
    'NO ACTION',
    'RESTRICT',
    'CASCADE',
    'SET NULL',
    'SET DEFAULT',
  ];

  /// 可延迟 / 延迟 的 YES / NO(空 = 不生成子句)
  static const List<String> _yesNo = ['', 'YES', 'NO'];

  /// 触发器 FOR EACH
  static const List<String> _forEachOptions = ['行', '语句'];

  /// 触发器时机
  static const List<String> _timingOptions = ['BEFORE', 'AFTER', 'INSTEAD OF'];

  /// 规则事件
  static const List<String> _ruleEvents = ['INSERT', 'UPDATE', 'DELETE', 'SELECT'];

  // ── 生命周期 ──────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    final conn = app.connectionByName(widget.connection);
    _typeId = conn?.typeId ?? 'postgresql';
    for (final e in kAllDbTypes) {
      if (e.id == _typeId) {
        _typeLabel = e.label;
        break;
      }
    }
    _design.columns.add(DesignColumn());
    _loadRefTables();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _commentCtrl.dispose();
    _sqlCtrl.dispose();
    super.dispose();
  }

  /// 懒加载外键「被引用的表」候选:当前库 / 模式的表列表。
  /// 加载失败保持空列表(仍可手动输入表名)。
  Future<void> _loadRefTables() async {
    final app = context.read<AppState>();
    final conn = app.connectionByName(widget.connection);
    if (conn == null || !app.connectionManager.isConnected(conn.name)) return;
    try {
      final manager = app.connectionManager;
      final state = manager.tableStateOf(conn.name, widget.database, schema: widget.schema);
      if (state.status != LoadStatus.loaded) {
        if (widget.schema != null) {
          await manager.expandSchema(conn, widget.database, widget.schema!);
        } else {
          await manager.expandDatabase(conn, widget.database);
        }
      }
      final fresh = manager.tableStateOf(conn.name, widget.database, schema: widget.schema);
      if (mounted) setState(() => _refTables = fresh.tables ?? const []);
    } catch (_) {
      // 连接未就绪等场景:静默,允许手动输入表名
    }
  }

  // ── 保存 ──────────────────────────────────────────────────

  Future<void> _save() async {
    final app = context.read<AppState>();
    setState(() {
      _saving = true;
      _error = null;
    });
    final outcome = await app.createTableDesign(
      _design,
      connection: widget.connection,
      database: widget.database,
      schema: widget.schema,
    );
    if (!mounted) return;
    if (outcome.ok) {
      // 成功后关闭设计器标签;对象列表已由 createTableDesign 刷新
      app.closeTab(widget.title);
    } else {
      setState(() {
        _saving = false;
        _error = outcome.error ?? '新建表失败';
      });
    }
  }

  // ── 主布局 ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final validation = DdlBuilder.validate(_design);
    _valid = validation.ok;
    _invalidReason = validation.error ?? '设计数据不完整';
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyS, control: true): _SaveIntent(),
        SingleActivator(LogicalKeyboardKey.keyS, meta: true): _SaveIntent(),
      },
      child: Actions(
        actions: {
          _SaveIntent: CallbackAction<_SaveIntent>(
            onInvoke: (_) {
              if (!_saving && _valid) _save();
              return null;
            },
          ),
        },
        child: Container(
          color: t.background,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(t),
              _toolbar(t),
              // TabControl 仅作标签条(子标签不挂 child,内容区由下方 Expanded
              // 自渲染——TabControl 内容区是 shrink-wrap,不能承载 Expanded 子级)
              TabControl(
                initialIndex: 0,
                barHeight: 30,
                tabWidth: 82,
                tabBarColor: t.background,
                selectedTabColor: t.surface,
                hoverTabColor: t.secondary,
                contentPadding: EdgeInsets.zero,
                onChanged: (i) => setState(() => _tabIndex = i),
                tabs: [
                  for (final label in const [
                    '字段', '索引', '外键', '唯一键', '检查', '排除',
                    '规则', '触发器', '选项', '注释', 'SQL 预览',
                  ])
                    TabItem(label: label),
                ],
              ),
              Expanded(child: _tabBody(t, _tabIndex)),
              _statusBar(t),
            ],
          ),
        ),
      ),
    );
  }

  /// 按活动标签索引返回对应内容
  Widget _tabBody(AppPalette t, int index) {
    switch (index) {
      case 0:
        return _fieldsTab(t);
      case 1:
        return _indexTab(t);
      case 2:
        return _fkTab(t);
      case 3:
        return _uniqueTab(t);
      case 4:
        return _checkTab(t);
      case 5:
        return _excludeTab(t);
      case 6:
        return _ruleTab(t);
      case 7:
        return _triggerTab(t);
      case 8:
        return _optionsTab(t);
      case 9:
        return _commentsTab(t);
      default:
        return _sqlTab(t);
    }
  }

  /// 标题栏:表名 @ 库.模式 (连接 · 类型)
  Widget _header(AppPalette t) {
    final name = _design.name.trim().isEmpty ? '无标题' : _design.name.trim();
    final schemaSuffix = widget.schema == null || widget.schema!.isEmpty
        ? ''
        : '.${widget.schema}';
    return Container(
      height: 28,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 12),
      color: t.secondary,
      child: Text(
        '$name @ ${widget.database}$schemaSuffix (${widget.connection} · $_typeLabel)',
        style: TextStyle(
          fontSize: 12.5,
          color: t.mutedForeground,
          decoration: TextDecoration.none,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }

  /// 工具栏:表名 + 保存 + 当前标签的动作按钮
  Widget _toolbar(AppPalette t) {
    return Container(
      height: 42,
      color: t.secondary,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Text('表名', style: TextStyle(fontSize: 12.5, color: t.mutedForeground)),
          const SizedBox(width: 6),
          SizedBox(
            width: 170,
            child: Input(
              controller: _nameCtrl,
              hint: '输入表名',
              selectAllOnFocus: false,
              onChanged: (v) => setState(() => _design.name = v),
            ),
          ),
          const SizedBox(width: 10),
          Button(
            text: '保存',
            variant: ButtonVariant.solid,
            onPressed: _saving || !_valid ? null : _save,
          ),
          const SizedBox(width: 14),
          Container(width: 1, height: 22, color: t.border),
          const SizedBox(width: 14),
          Expanded(child: _tabActions(t)),
        ],
      ),
    );
  }

  /// 当前标签专属动作按钮(字段:增删插/主键/上下移;其余:增删)
  Widget _tabActions(AppPalette t) {
    final actions = <Widget>[];
    switch (_tabIndex) {
      case 0:
        actions.addAll([
          Button(text: '添加字段', onPressed: _addColumn),
          const SizedBox(width: 6),
          Button(text: '插入字段', onPressed: _insertColumn),
          const SizedBox(width: 6),
          Button(text: '删除字段', onPressed: _design.columns.isEmpty ? null : _removeColumn),
          const SizedBox(width: 14),
          Button(text: '主键', onPressed: _design.columns.isEmpty ? null : _togglePk),
          const SizedBox(width: 6),
          Button(text: '上移', onPressed: _selColumn <= 0 ? null : _moveColumnUp),
          const SizedBox(width: 6),
          Button(text: '下移',
              onPressed: _selColumn < 0 || _selColumn >= _design.columns.length - 1
                  ? null
                  : _moveColumnDown),
        ]);
      case 1:
        actions.addAll([
          Button(text: '添加索引', onPressed: () => _addRow(_design.indexes, (i) => _selIndex = i)),
          const SizedBox(width: 6),
          Button(text: '删除索引', onPressed: () => _removeRow(_design.indexes, () => _selIndex, (i) => _selIndex = i)),
        ]);
      case 2:
        actions.addAll([
          Button(text: '添加外键', onPressed: _addFk),
          const SizedBox(width: 6),
          Button(text: '删除外键', onPressed: () => _removeRow(_design.foreignKeys, () => _selFk, (i) => _selFk = i)),
        ]);
      case 3:
        actions.addAll([
          Button(text: '添加唯一键', onPressed: () => _addRow(_design.uniqueKeys, (i) => _selUnique = i)),
          const SizedBox(width: 6),
          Button(text: '删除唯一键', onPressed: () => _removeRow(_design.uniqueKeys, () => _selUnique, (i) => _selUnique = i)),
        ]);
      case 4:
        actions.addAll([
          Button(text: '添加检查', onPressed: () => _addRow(_design.checks, (i) => _selCheck = i)),
          const SizedBox(width: 6),
          Button(text: '删除检查', onPressed: () => _removeRow(_design.checks, () => _selCheck, (i) => _selCheck = i)),
        ]);
      case 5:
        actions.addAll([
          Button(text: '添加排除', onPressed: () => _addRow(_design.excludes, (i) => _selExclude = i)),
          const SizedBox(width: 6),
          Button(text: '删除排除', onPressed: () => _removeRow(_design.excludes, () => _selExclude, (i) => _selExclude = i)),
        ]);
      case 6:
        actions.addAll([
          Button(text: '添加规则', onPressed: () => _addRow(_design.rules, (i) => _selRule = i)),
          const SizedBox(width: 6),
          Button(text: '删除规则', onPressed: () => _removeRow(_design.rules, () => _selRule, (i) => _selRule = i)),
        ]);
      case 7:
        actions.addAll([
          Button(text: '添加触发器', onPressed: () => _addRow(_design.triggers, (i) => _selTrigger = i)),
          const SizedBox(width: 6),
          Button(text: '删除触发器', onPressed: () => _removeRow(_design.triggers, () => _selTrigger, (i) => _selTrigger = i)),
        ]);
      default:
        return const SizedBox.shrink();
    }
    // 排除 / 规则 / 触发器仅 PostgreSQL 家族生成 DDL,其它类型提示但不拦截
    if ((_tabIndex == 5 || _tabIndex == 6 || _tabIndex == 7) &&
        !DdlBuilder.isPgLike(_typeId)) {
      actions.add(const SizedBox(width: 12));
      actions.add(Text(
        '仅 PostgreSQL 支持该功能,其它类型保存时忽略',
        style: TextStyle(fontSize: 11, color: t.disabledForeground),
      ));
    }
    return Row(children: actions);
  }

  /// 底部状态条:错误信息 + 保存中提示
  Widget _statusBar(AppPalette t) {
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: t.statusBar,
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          if (_error != null)
            Expanded(
              child: Text(
                _error!,
                style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626)),
                overflow: TextOverflow.ellipsis,
              ),
            )
          else if (!_valid)
            Expanded(
              child: Text(
                _invalidReason,
                style: TextStyle(fontSize: 12, color: t.disabledForeground),
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            const Spacer(),
          if (_saving) ...[
            const Spinner(size: 12),
            const SizedBox(width: 8),
            Text('正在创建表 ...', style: TextStyle(fontSize: 12, color: t.mutedForeground)),
          ],
        ],
      ),
    );
  }

  // ── 字段标签 ──────────────────────────────────────────────

  Widget _fieldsTab(AppPalette t) {
    final cols = _design.columns;
    final sel = _selColumn.clamp(0, cols.isEmpty ? 0 : cols.length - 1);
    return _editorGrid(
      t,
      headers: const ['名称', '类型', '长度', '小数点', '不是 null', '键', '注释'],
      widths: const [170, 160, 64, 64, 72, 64, 210],
      rowCount: cols.length,
      selected: cols.isEmpty ? -1 : _selColumn,
      onSelect: (i) => setState(() => _selColumn = i),
      rowBuilder: (i) => _fieldRow(t, cols[i]),
      propsPanel: _props(
        t,
        cols.isEmpty
            ? null
            : cols[sel],
        (c) => [
          _propField(t, '默认', _modelInput(c.defaultValue, (v) => c.defaultValue = v, hint: '字符串自动加引号')),
          _propField(t, '排序规则', _modelInput(c.collation, (v) => c.collation = v)),
          _propField(t, '维度', _modelInput(c.dimension, (v) => c.dimension = v, width: 110)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckBox(
                value: c.autoIncrement,
                enabled: DdlBuilder.isMysqlLike(_typeId),
                onChanged: (v) => setState(() => c.autoIncrement = v ?? false),
              ),
              const SizedBox(width: 4),
              Text('自增', style: TextStyle(fontSize: 12, color: t.mutedForeground)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _fieldRow(AppPalette t, DesignColumn c) {
    return Row(
      children: [
        SizedBox(width: 170, child: _modelInput(c.name, (v) => c.name = v, hint: '列名')),
        const SizedBox(width: 6),
        SizedBox(
          width: 160,
          child: ComboBox<String>(
            items: _typeOptions,
            value: c.type.isEmpty ? null : c.type,
            editable: true,
            hint: '类型',
            onChanged: (v) => setState(() => c.type = v ?? ''),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(width: 64, child: _modelInput(c.length, (v) => c.length = v, hint: '长度')),
        const SizedBox(width: 6),
        SizedBox(width: 64, child: _modelInput(c.decimal, (v) => c.decimal = v, hint: '小数点')),
        const SizedBox(width: 6),
        SizedBox(
          width: 72,
          child: Center(
            child: CheckBox(value: c.notNull, onChanged: (v) => setState(() => c.notNull = v ?? false)),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 64,
          child: Center(
            child: CheckBox(value: c.primaryKey, onChanged: (v) => setState(() => c.primaryKey = v ?? false)),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(child: _modelInput(c.comment, (v) => c.comment = v, hint: '注释')),
      ],
    );
  }

  // ── 索引标签 ──────────────────────────────────────────────

  Widget _indexTab(AppPalette t) {
    final items = _design.indexes;
    return _editorGrid(
      t,
      headers: const ['名称', '字段', '索引方法', '唯一键', '并发', '注释'],
      widths: const [140, 150, 110, 64, 64, 180],
      rowCount: items.length,
      selected: _selIndex,
      onSelect: (i) => setState(() => _selIndex = i),
      rowBuilder: (i) => _indexRow(t, items[i]),
      propsPanel: _props(
        t,
        _selIndex >= 0 && _selIndex < items.length ? items[_selIndex] : null,
        (it) => [
          _propField(t, '表空间', _modelInput(it.tablespace, (v) => it.tablespace = v, enabled: DdlBuilder.isPgLike(_typeId))),
          _propField(t, '填充因子 (%)', _modelInput(it.fillFactor, (v) => it.fillFactor = v)),
          _propField(t, '正在缓冲', _disabledInput),
          _propField(t, '快速更新', _disabledInput),
          _propField(t, '待处理列表限制', _disabledInput),
          _propField(t, '每范围页数', _disabledInput),
        ],
      ),
    );
  }

  Widget _indexRow(AppPalette t, DesignIndex it) {
    return Row(
      children: [
        SizedBox(width: 140, child: _modelInput(it.name, (v) => it.name = v, hint: '索引名')),
        const SizedBox(width: 6),
        SizedBox(width: 150, child: _modelInput(it.columns, (v) => it.columns = v, hint: '多列用逗号分隔')),
        const SizedBox(width: 6),
        SizedBox(
          width: 110,
          child: ComboBox<String>(
            items: _indexMethods,
            value: it.method.isEmpty ? null : it.method,
            onChanged: (v) => setState(() => it.method = v ?? ''),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(width: 64, child: Center(child: CheckBox(value: it.unique, onChanged: (v) => setState(() => it.unique = v ?? false)))),
        const SizedBox(width: 6),
        SizedBox(width: 64, child: Center(child: CheckBox(value: it.concurrent, onChanged: (v) => setState(() => it.concurrent = v ?? false)))),
        const SizedBox(width: 6),
        Expanded(child: _modelInput(it.comment, (v) => it.comment = v, hint: '注释')),
      ],
    );
  }

  // ── 外键标签 ──────────────────────────────────────────────

  Widget _fkTab(AppPalette t) {
    final items = _design.foreignKeys;
    return _editorGrid(
      t,
      headers: const ['名称', '字段', '被引用的模式', '被引用的表（父）', '被引用的字段', '删除时', '更新时'],
      widths: const [110, 100, 100, 120, 100, 100, 100],
      rowCount: items.length,
      selected: _selFk,
      onSelect: (i) => setState(() => _selFk = i),
      rowBuilder: (i) => _fkRow(t, items[i]),
      propsPanel: _props(
        t,
        _selFk >= 0 && _selFk < items.length ? items[_selFk] : null,
        (fk) => [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckBox(value: fk.matchAll, onChanged: (v) => setState(() => fk.matchAll = v ?? false)),
              const SizedBox(width: 4),
              Text('符合全部', style: TextStyle(fontSize: 12, color: t.mutedForeground)),
            ],
          ),
          const SizedBox(width: 18),
          _propField(t, '可延迟', _yesNoCombo(fk.deferrable, (v) => fk.deferrable = v)),
          _propField(t, '延迟', _yesNoCombo(fk.deferred, (v) => fk.deferred = v)),
        ],
      ),
    );
  }

  Widget _fkRow(AppPalette t, DesignForeignKey fk) {
    return Row(
      children: [
        SizedBox(width: 110, child: _modelInput(fk.name, (v) => fk.name = v, hint: '约束名')),
        const SizedBox(width: 6),
        SizedBox(width: 100, child: _modelInput(fk.columns, (v) => fk.columns = v, hint: '本表字段')),
        const SizedBox(width: 6),
        SizedBox(width: 100, child: _modelInput(fk.refSchema, (v) => fk.refSchema = v, hint: widget.schema ?? '模式')),
        const SizedBox(width: 6),
        SizedBox(
          width: 120,
          child: ComboBox<String>(
            items: _refTables,
            value: fk.refTable.isEmpty ? null : fk.refTable,
            editable: true,
            hint: '表名',
            onChanged: (v) => setState(() => fk.refTable = v ?? ''),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(width: 100, child: _modelInput(fk.refColumns, (v) => fk.refColumns = v, hint: '如 id')),
        const SizedBox(width: 6),
        SizedBox(
          width: 100,
          child: ComboBox<String>(
            items: _fkActions,
            value: fk.onDelete,
            onChanged: (v) => setState(() => fk.onDelete = v ?? 'NO ACTION'),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 100,
          child: ComboBox<String>(
            items: _fkActions,
            value: fk.onUpdate,
            onChanged: (v) => setState(() => fk.onUpdate = v ?? 'NO ACTION'),
          ),
        ),
      ],
    );
  }

  // ── 唯一键标签 ────────────────────────────────────────────

  Widget _uniqueTab(AppPalette t) {
    final items = _design.uniqueKeys;
    return _editorGrid(
      t,
      headers: const ['名称', '字段', '注释'],
      widths: const [160, 200, 240],
      rowCount: items.length,
      selected: _selUnique,
      onSelect: (i) => setState(() => _selUnique = i),
      rowBuilder: (i) => _uniqueRow(t, items[i]),
      propsPanel: _props(
        t,
        _selUnique >= 0 && _selUnique < items.length ? items[_selUnique] : null,
        (uk) => [
          _propField(t, '表空间', _modelInput(uk.tablespace, (v) => uk.tablespace = v, enabled: DdlBuilder.isPgLike(_typeId))),
          _propField(t, '填充因子 (%)', _modelInput(uk.fillFactor, (v) => uk.fillFactor = v)),
          _propField(t, '可延迟', _yesNoCombo(uk.deferrable, (v) => uk.deferrable = v)),
          _propField(t, '延迟', _yesNoCombo(uk.deferred, (v) => uk.deferred = v)),
        ],
      ),
    );
  }

  Widget _uniqueRow(AppPalette t, DesignUniqueKey uk) {
    return Row(
      children: [
        SizedBox(width: 160, child: _modelInput(uk.name, (v) => uk.name = v, hint: '约束名')),
        const SizedBox(width: 6),
        SizedBox(width: 200, child: _modelInput(uk.columns, (v) => uk.columns = v, hint: '多列用逗号分隔')),
        const SizedBox(width: 6),
        Expanded(child: _modelInput(uk.comment, (v) => uk.comment = v, hint: '注释')),
      ],
    );
  }

  // ── 检查标签 ──────────────────────────────────────────────

  Widget _checkTab(AppPalette t) {
    final items = _design.checks;
    return _editorGrid(
      t,
      headers: const ['名称', '条件', '注释'],
      widths: const [160, 320, 240],
      rowCount: items.length,
      selected: _selCheck,
      onSelect: (i) => setState(() => _selCheck = i),
      rowBuilder: (i) => _checkRow(t, items[i]),
      propsPanel: null,
    );
  }

  Widget _checkRow(AppPalette t, DesignCheck ck) {
    return Row(
      children: [
        SizedBox(width: 160, child: _modelInput(ck.name, (v) => ck.name = v, hint: '约束名')),
        const SizedBox(width: 6),
        SizedBox(width: 320, child: _modelInput(ck.expression, (v) => ck.expression = v, hint: '如 age > 0')),
        const SizedBox(width: 6),
        Expanded(child: _modelInput(ck.comment, (v) => ck.comment = v, hint: '注释')),
      ],
    );
  }

  // ── 排除标签(仅 PostgreSQL) ──────────────────────────────

  Widget _excludeTab(AppPalette t) {
    final items = _design.excludes;
    return _editorGrid(
      t,
      headers: const ['名称', '字段 / 表达式', '排除方法', '注释'],
      widths: const [150, 260, 110, 180],
      rowCount: items.length,
      selected: _selExclude,
      onSelect: (i) => setState(() => _selExclude = i),
      rowBuilder: (i) => _excludeRow(t, items[i]),
      propsPanel: null,
    );
  }

  Widget _excludeRow(AppPalette t, DesignExclude ex) {
    return Row(
      children: [
        SizedBox(width: 150, child: _modelInput(ex.name, (v) => ex.name = v, hint: '约束名')),
        const SizedBox(width: 6),
        SizedBox(width: 260, child: _modelInput(ex.columns, (v) => ex.columns = v, hint: '如 col WITH =')),
        const SizedBox(width: 6),
        SizedBox(
          width: 110,
          child: ComboBox<String>(
            items: _excludeMethods,
            value: ex.method,
            onChanged: (v) => setState(() => ex.method = v ?? 'gist'),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(child: _modelInput(ex.comment, (v) => ex.comment = v, hint: '注释')),
      ],
    );
  }

  // ── 规则标签(仅 PostgreSQL) ──────────────────────────────

  Widget _ruleTab(AppPalette t) {
    final items = _design.rules;
    return _editorGrid(
      t,
      headers: const ['名称', '事件', '语句', '注释'],
      widths: const [150, 100, 320, 160],
      rowCount: items.length,
      selected: _selRule,
      onSelect: (i) => setState(() => _selRule = i),
      rowBuilder: (i) => _ruleRow(t, items[i]),
      propsPanel: null,
    );
  }

  Widget _ruleRow(AppPalette t, DesignRule r) {
    return Row(
      children: [
        SizedBox(width: 150, child: _modelInput(r.name, (v) => r.name = v, hint: '规则名')),
        const SizedBox(width: 6),
        SizedBox(
          width: 100,
          child: ComboBox<String>(
            items: _ruleEvents,
            value: r.event,
            onChanged: (v) => setState(() => r.event = v ?? 'INSERT'),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(width: 320, child: _modelInput(r.statement, (v) => r.statement = v, hint: 'DO INSTEAD 后的语句')),
        const SizedBox(width: 6),
        Expanded(child: _modelInput(r.comment, (v) => r.comment = v, hint: '注释')),
      ],
    );
  }

  // ── 触发器标签 ────────────────────────────────────────────

  Widget _triggerTab(AppPalette t) {
    final items = _design.triggers;
    return _editorGrid(
      t,
      headers: const ['名称', '给每个', '触发', '插入', '更新', '删除', '截断', '更新字段', '启用', '注释'],
      widths: const [110, 70, 90, 44, 44, 44, 44, 110, 44, 140],
      rowCount: items.length,
      selected: _selTrigger,
      onSelect: (i) => setState(() => _selTrigger = i),
      rowBuilder: (i) => _triggerRow(t, items[i]),
      propsPanel: _props(
        t,
        _selTrigger >= 0 && _selTrigger < items.length ? items[_selTrigger] : null,
        (tr) => [
          _propField(t, '当', _modelInput(tr.when, (v) => tr.when = v, hint: 'WHEN 条件')),
          _propField(t, '触发函数', _modelInput(tr.function, (v) => tr.function = v, hint: '如 public.update_ts()')),
          _propField(t, '参数', _modelInput(tr.parameters, (v) => tr.parameters = v, hint: '如 NEW.id')),
        ],
      ),
    );
  }

  Widget _triggerRow(AppPalette t, DesignTrigger tr) {
    Widget cell(Widget child) => Center(child: child);
    return Row(
      children: [
        SizedBox(width: 110, child: _modelInput(tr.name, (v) => tr.name = v, hint: '触发器名')),
        const SizedBox(width: 6),
        SizedBox(
          width: 70,
          child: ComboBox<String>(
            items: _forEachOptions,
            value: tr.forEach,
            onChanged: (v) => setState(() => tr.forEach = v ?? '行'),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 90,
          child: ComboBox<String>(
            items: _timingOptions,
            value: tr.timing,
            onChanged: (v) => setState(() => tr.timing = v ?? 'BEFORE'),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(width: 44, child: cell(CheckBox(value: tr.insert, onChanged: (v) => setState(() => tr.insert = v ?? false)))),
        const SizedBox(width: 6),
        SizedBox(width: 44, child: cell(CheckBox(value: tr.update, onChanged: (v) => setState(() => tr.update = v ?? false)))),
        const SizedBox(width: 6),
        SizedBox(width: 44, child: cell(CheckBox(value: tr.delete, onChanged: (v) => setState(() => tr.delete = v ?? false)))),
        const SizedBox(width: 6),
        SizedBox(width: 44, child: cell(CheckBox(value: tr.truncate, onChanged: (v) => setState(() => tr.truncate = v ?? false)))),
        const SizedBox(width: 6),
        SizedBox(width: 110, child: _modelInput(tr.updateColumns, (v) => tr.updateColumns = v, hint: '更新字段')),
        const SizedBox(width: 6),
        SizedBox(width: 44, child: cell(CheckBox(value: tr.enable, onChanged: (v) => setState(() => tr.enable = v ?? true)))),
        const SizedBox(width: 6),
        Expanded(child: _modelInput(tr.comment, (v) => tr.comment = v, hint: '注释')),
      ],
    );
  }

  // ── 选项标签 ──────────────────────────────────────────────

  Widget _optionsTab(AppPalette t) {
    final isPg = DdlBuilder.isPgLike(_typeId);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 320,
                child: _propField(t, '填充因子 (%)', _modelInput(_design.fillFactor, (v) => _design.fillFactor = v)),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 320,
                child: _propField(
                  t,
                  '表空间',
                  _modelInput(_design.tablespace, (v) => _design.tablespace = v, enabled: isPg),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            isPg
                ? '填充因子生成 WITH (fillfactor = n),表空间生成 TABLESPACE 子句;其它类型忽略。'
                : '表选项仅 PostgreSQL / SQL Server 部分支持;填充因子对 MySQL / SQLite / Access 不生成。',
            style: TextStyle(fontSize: 11.5, color: t.disabledForeground),
          ),
        ],
      ),
    );
  }

  // ── 注释标签 ──────────────────────────────────────────────

  Widget _commentsTab(AppPalette t) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('表注释', style: TextStyle(fontSize: 12.5, color: t.mutedForeground)),
          const SizedBox(height: 6),
          Expanded(
            child: Textarea(
              controller: _commentCtrl,
              hint: '输入表的注释…(MySQL 生成 COMMENT=,PostgreSQL 生成 COMMENT ON TABLE)',
              onChanged: (v) => setState(() => _design.tableComment = v),
              expands: true,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '列的注释请在「字段」标签的注释列填写。',
            style: TextStyle(fontSize: 11.5, color: t.disabledForeground),
          ),
        ],
      ),
    );
  }

  // ── SQL 预览标签 ──────────────────────────────────────────

  Widget _sqlTab(AppPalette t) {
    final sql = DdlBuilder.buildPreview(_design, _typeId);
    if (_sqlCtrl.text != sql) _sqlCtrl.text = sql;
    final isDark = t.background.computeLuminance() < 0.5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          color: t.secondary,
          child: Text(
            '「保存」将按以下顺序执行这些语句(PostgreSQL 在事务中执行,失败自动回滚)',
            style: TextStyle(fontSize: 11.5, color: t.mutedForeground),
          ),
        ),
        Expanded(
          child: CodeEditor(
            controller: _sqlCtrl,
            readOnly: true,
            wordWrap: false,
            chunkAnalyzer: const NonCodeChunkAnalyzer(),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            style: CodeEditorStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              fontHeight: 20 / 13,
              textColor: t.foreground,
              backgroundColor: t.background,
              selectionColor: Color.alphaBlend(
                t.accent.withValues(alpha: 0.30),
                t.background,
              ),
              cursorColor: t.foreground,
              codeTheme: CodeHighlightTheme(
                languages: {'sql': CodeHighlightThemeMode(mode: langSql)},
                theme: {
                  ...(isDark ? _sqlDarkTheme : _sqlLightTheme),
                  'root': TextStyle(color: t.foreground),
                },
              ),
            ),
            indicatorBuilder:
                (context, editingController, chunkController, notifier) =>
                    DefaultCodeLineNumber(
              controller: editingController,
              notifier: notifier,
              textStyle: TextStyle(fontSize: 12.5, color: t.disabledForeground),
              focusedTextStyle: TextStyle(fontSize: 12.5, color: t.mutedForeground),
              minNumberCount: 3,
            ),
          ),
        ),
      ],
    );
  }

  // ── 通用网格脚手架 ─────────────────────────────────────────

  /// 表头 + 行列表 + 底部属性面板(可选)的编辑网格。
  /// 表头与行放在同一个水平滚动容器内,超宽时一起滚动、始终对齐。
  Widget _editorGrid(
    AppPalette t, {
    required List<String> headers,
    required List<double> widths,
    required int rowCount,
    required Widget Function(int row) rowBuilder,
    required int selected,
    required ValueChanged<int> onSelect,
    Widget? propsPanel,
  }) {
    final total = widths.fold(0.0, (a, b) => a + b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: total + 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 表头
                  Container(
                    height: 26,
                    color: t.secondary,
                    padding: const EdgeInsets.only(left: 8, right: 12),
                    child: Row(
                      children: [
                        for (var i = 0; i < headers.length; i++)
                          _headCell(t, headers[i], widths[i]),
                        const Spacer(),
                      ],
                    ),
                  ),
                  // 行列表(垂直滚动);无数据时留白,不显示空态提示
                  Expanded(
                    child: rowCount == 0
                        ? const SizedBox.shrink()
                        : ListView.builder(
                            itemCount: rowCount,
                            itemExtent: 30,
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            itemBuilder: (context, i) => _rowWrap(
                              t,
                              i,
                              selected: i == selected,
                              onTap: () => onSelect(i),
                              child: rowBuilder(i),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (propsPanel != null) propsPanel,
      ],
    );
  }

  Widget _headCell(AppPalette t, String title, double width) => Container(
        width: width,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: t.mutedForeground,
            decoration: TextDecoration.none,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      );

  /// 行容器:Listener.onPointerDown 零延迟选中 + zebra / 选中底色
  Widget _rowWrap(AppPalette t, int index,
      {required bool selected, required VoidCallback onTap, required Widget child}) {
    return Listener(
      onPointerDown: (_) => onTap(),
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        color: selected
            ? t.treeSelectedBg
            : (index.isOdd
                ? Color.alphaBlend(t.foreground.withValues(alpha: 0.03), t.background)
                : t.background),
        child: child,
      ),
    );
  }

  /// 底部属性面板:标签 + 控件 一行排列;model 为空(无选中行)时整个面板隐藏。
  Widget _props<T>(
    AppPalette t,
    T? model,
    List<Widget> Function(T) builder,
  ) {
    if (model == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.border)),
        color: t.surface,
      ),
      child: Row(
        children: [
          for (final w in builder(model)) ...[w, const SizedBox(width: 16)],
        ],
      ),
    );
  }

  /// 属性字段:左侧标签(固定宽)+ 右侧控件
  Widget _propField(AppPalette t, String label, Widget child) {
    return Expanded(
      child: Row(
        children: [
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: t.mutedForeground),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(child: child),
        ],
      ),
    );
  }

  // ── 通用控件 ──────────────────────────────────────────────

  /// 绑定字符串字段的输入框:自持控制器、变更即时写回模型,外部值变化时同步。
  Widget _modelInput(
    String value,
    ValueChanged<String> onChanged, {
    String? hint,
    bool enabled = true,
    double? width,
  }) {
    final input = _ModelInput(
      value: value,
      enabled: enabled,
      hint: hint,
      onChanged: (v) {
        onChanged(v);
        // 触发父级重建,使「SQL 预览」与校验状态实时刷新(预览即所见)
        setState(() {});
      },
    );
    return width == null ? input : SizedBox(width: width, child: input);
  }

  /// 灰色占位输入(正在缓冲 / 快速更新 等暂未支持项)
  Widget get _disabledInput => _ModelInput(value: '', onChanged: (_) {}, enabled: false, hint: '—');

  /// YES / NO 下拉(空 = 不生成子句)
  Widget _yesNoCombo(String value, ValueChanged<String> onChanged) {
    return ComboBox<String>(
      items: _yesNo,
      value: value,
      onChanged: (v) => setState(() => onChanged(v ?? '')),
    );
  }

  // ── 字段动作 ──────────────────────────────────────────────

  void _addColumn() {
    setState(() {
      _design.columns.add(DesignColumn());
      _selColumn = _design.columns.length - 1;
    });
  }

  void _insertColumn() {
    setState(() {
      final at = _selColumn.clamp(0, _design.columns.length);
      _design.columns.insert(at, DesignColumn());
      _selColumn = at;
    });
  }

  void _removeColumn() {
    setState(() {
      final at = _selColumn.clamp(0, _design.columns.length - 1);
      _design.columns.removeAt(at);
      _selColumn = _design.columns.isEmpty ? -1 : at.clamp(0, _design.columns.length - 1);
    });
  }

  void _togglePk() {
    setState(() {
      if (_selColumn < 0 || _selColumn >= _design.columns.length) return;
      final c = _design.columns[_selColumn];
      c.primaryKey = !c.primaryKey;
    });
  }

  void _moveColumnUp() {
    setState(() {
      if (_selColumn <= 0) return;
      final i = _selColumn;
      final c = _design.columns.removeAt(i);
      _design.columns.insert(i - 1, c);
      _selColumn = i - 1;
    });
  }

  void _moveColumnDown() {
    setState(() {
      final i = _selColumn;
      if (i < 0 || i >= _design.columns.length - 1) return;
      final c = _design.columns.removeAt(i);
      _design.columns.insert(i + 1, c);
      _selColumn = i + 1;
    });
  }

  void _addFk() {
    setState(() {
      final fk = DesignForeignKey(refSchema: widget.schema ?? '');
      _design.foreignKeys.add(fk);
      _selFk = _design.foreignKeys.length - 1;
    });
  }

  /// 通用「添加」:向列表追加一行新模型并选中
  void _addRow<T>(
    List<T> list,
    ValueChanged<int> select,
  ) {
    setState(() {
      list.add(_newRow<T>());
      select(list.length - 1);
    });
  }

  /// 按类型创建一行设计数据(与 _addRow 的 T 对应)
  T _newRow<T>() {
    if (T == DesignIndex) return DesignIndex() as T;
    if (T == DesignForeignKey) return DesignForeignKey() as T;
    if (T == DesignUniqueKey) return DesignUniqueKey() as T;
    if (T == DesignCheck) return DesignCheck() as T;
    if (T == DesignExclude) return DesignExclude() as T;
    if (T == DesignRule) return DesignRule() as T;
    if (T == DesignTrigger) return DesignTrigger() as T;
    throw StateError('不支持的模型类型: $T');
  }

  /// 通用「删除」:删除选中行并回退选中到安全位置
  void _removeRow<T>(
    List<T> list,
    int Function() selectedOf,
    ValueChanged<int> select,
  ) {
    setState(() {
      final sel = selectedOf();
      if (sel < 0 || sel >= list.length) return;
      list.removeAt(sel);
      select(list.isEmpty ? -1 : (sel < list.length ? sel : list.length - 1));
    });
  }
}

/// Ctrl/Cmd + S 触发的保存意图(供 [Shortcuts] / [Actions] 绑定)
class _SaveIntent extends Intent {
  const _SaveIntent();
}

/// 绑定模型字符串字段的输入框:自持 [TextEditingController],
/// 输入即时写回模型(触发父级重建以刷新 SQL 预览);外部值变化时同步文本。
class _ModelInput extends StatefulWidget {
  const _ModelInput({
    required this.value,
    required this.onChanged,
    this.hint,
    this.enabled = true,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool enabled;

  @override
  State<_ModelInput> createState() => _ModelInputState();
}

class _ModelInputState extends State<_ModelInput> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(_ModelInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Input(
      controller: _controller,
      hint: widget.hint,
      enabled: widget.enabled,
      selectAllOnFocus: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      onChanged: widget.onChanged,
    );
  }
}

// SQL 语法高亮配色(与查询页同款,中调色主题无关)
const Map<String, TextStyle> _sqlLightTheme = {
  'keyword': TextStyle(color: Color(0xff0000ff)),
  'literal': TextStyle(color: Color(0xff001080)),
  'name': TextStyle(color: Color(0xff001080)),
  'attr': TextStyle(color: Color(0xff001080)),
  'variable': TextStyle(color: Color(0xff001080)),
  'meta': TextStyle(color: Color(0xff001080)),
  'string': TextStyle(color: Color(0xffa31515)),
  'quote': TextStyle(color: Color(0xffa31515)),
  'regexp': TextStyle(color: Color(0xffa31515)),
  'comment': TextStyle(color: Color(0xff008000), fontStyle: FontStyle.italic),
  'doctag': TextStyle(color: Color(0xff800000)),
  'section': TextStyle(color: Color(0xff800000)),
  'number': TextStyle(color: Color(0xff098658)),
  'symbol': TextStyle(color: Color(0xff098658)),
  'type': TextStyle(color: Color(0xff267f99)),
  'class-title': TextStyle(color: Color(0xff267f99)),
  'built_in': TextStyle(color: Color(0xff795e26)),
  'title': TextStyle(color: Color(0xff795e26)),
};

const Map<String, TextStyle> _sqlDarkTheme = {
  'keyword': TextStyle(color: Color(0xff569cd6)),
  'literal': TextStyle(color: Color(0xff569cd6)),
  'name': TextStyle(color: Color(0xff9cdcfe)),
  'attr': TextStyle(color: Color(0xff9cdcfe)),
  'variable': TextStyle(color: Color(0xff9cdcfe)),
  'meta': TextStyle(color: Color(0xff9cdcfe)),
  'string': TextStyle(color: Color(0xffce9178)),
  'quote': TextStyle(color: Color(0xffce9178)),
  'regexp': TextStyle(color: Color(0xffd16969)),
  'comment': TextStyle(color: Color(0xff6a9955), fontStyle: FontStyle.italic),
  'doctag': TextStyle(color: Color(0xff6a9955)),
  'section': TextStyle(color: Color(0xff6a9955)),
  'number': TextStyle(color: Color(0xffb5cea8)),
  'symbol': TextStyle(color: Color(0xffb5cea8)),
  'type': TextStyle(color: Color(0xff4ec9b0)),
  'class-title': TextStyle(color: Color(0xff4ec9b0)),
  'built_in': TextStyle(color: Color(0xffdcdcaa)),
  'title': TextStyle(color: Color(0xffdcdcaa)),
};
