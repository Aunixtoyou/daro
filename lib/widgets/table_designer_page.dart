import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/sql.dart';
import '../app/app_state.dart';
import '../app/connection_manager.dart';
import '../data/db_metadata.dart';
import '../data/db_types.dart';
import '../data/drivers/db_driver.dart';
import '../data/table_design.dart';
import '../theme/app_theme.dart';
import 'index_column_picker_dialog.dart';

/// 表设计器:「新建表」与「设计表」共用同一页面(新建 + 编辑双模式)。
///
/// 以文档标签页形式打开(新建见 [AppState.newTableDesigner],编辑已有表见
/// [AppState.designTable]),含 11 个标签:
/// 字段 / 索引 / 外键 / 唯一键 / 检查 / 排除 / 规则 / 触发器 / 选项 / 注释 / SQL 预览。
/// 各标签实时采集设计数据([DesignTable]),「字段」页为「网格 + 行首 ▶ 当前行
/// 标记 + 底部纵向属性面板」:属性面板按方言展示默认 / 排序规则 / 维度 /
/// 虚拟类型(IDENTITY)及其序列选项 / 循环;「键」列以 钥匙 + 序号 表示主键。
/// 「SQL 预览」标签按当前连接类型实时生成方言 DDL(预览即所见):
/// 新建模式输出 CREATE 语句,编辑模式输出 [DdlBuilder.buildAlterStatements]
/// 生成的变更语句。点「保存」经 [AppState.createTableDesign] /
/// [AppState.saveTableDesignEdit] 逐条执行,PostgreSQL 家族在事务中执行,失败回滚。
///
/// 编辑模式由 [existingTable] 触发:打开时经 [DatabaseDriver.readTableDesign]
/// 反查真实结构回填,并留存快照 [DesignTable.snapshot] 作为差异基线;
/// 驱动不支持结构反查时(SQLite / Access)降级为只读展示 —— 编辑控件全部
/// 禁用并提示,与「读取失败」(展示错误 + 重试)严格区分。
///
/// 交互约定:行选中与「键」列切换用 [Listener.onPointerDown] 零延迟;输入框一律
/// `selectAllOnFocus: false`(桌面聚焦全选坑);颜色全部走 [Tokens.of] / [AppColors.of]。
class TableDesignerPage extends StatefulWidget {
  const TableDesignerPage({
    super.key,
    required this.title,
    required this.connection,
    required this.database,
    this.schema,
    this.existingTable,
    this.designLoader,
    this.candidatesLoader,
  });

  /// 标签标题(保存成功后关闭本标签用)
  final String title;

  /// 所属连接名
  final String connection;

  /// 所属数据库
  final String database;

  /// 目标模式(PostgreSQL 等有模式层的类型;无模式层为 null)
  final String? schema;

  /// 非空 = 编辑已有表(「设计表」):打开时反查结构回填并可保存变更;
  /// 为 null = 新建表。
  final String? existingTable;

  /// 表结构反查注入点(测试用):默认 null 走 [AppState] 的 ConnectionManager。
  final Future<DesignTable?> Function(
      String database, String table, String? schema)? designLoader;

  /// 下拉候选注入点(测试用):默认 null 走 ConnectionManager 的系统目录查询。
  final Future<DesignCandidates> Function(String database)? candidatesLoader;

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

  /// 模式 / 函数 / 用户 候选(索引字段弹窗的排序规则模式、触发器函数、表所有者)
  List<String> _schemas = const [];
  List<String> _functions = const [];
  List<String> _users = const [];

  /// 排序规则 / 运算符类别 / 表空间 候选(整页只查一次;为空时退化为手输)
  List<String> _collations = const [];
  List<String> _opClasses = const [];
  List<String> _tablespaces = const [];

  /// 候选查询是否已发出(发出后失败也不重发,避免每次展开控件都重试)
  bool _candidatesRequested = false;

  /// 触发器属性面板的子标签索引(0 = 常规,1 = 约束)
  int _triggerPropsTab = 0;

  /// 编辑基线:打开时反查到的结构快照,差异 / 脏态一律与它比较
  DesignTable? _original;

  bool _saving = false;
  String? _error;

  /// 编辑模式:结构反查进行中 / 读取失败原因 / 驱动不支持编辑(只读降级)
  bool _loading = false;
  String? _loadError;
  bool _readOnly = false;

  /// 上次保存成功的提示(状态栏显示,一有变更即撤下)
  String? _note;

  /// 设计数据是否通过校验(由 build 实时计算,用于禁用「保存」并提示)
  bool _valid = true;

  /// 校验未通过的原因(用于状态栏灰色提示)
  String _invalidReason = '';

  /// 当前活动标签索引(TabControl 内部持有选中态,通过 onChanged 同步到此)
  int _tabIndex = 0;

  // ── 模式判定 ────────────────────────────────────

  /// 是否编辑已有表(「设计表」)
  bool get _isEdit => widget.existingTable != null;

  /// 相对编辑基线是否有待应用的变更。
  /// 不自己逐字段比对:直接复用差异生成,保证与「SQL 预览」同一口径。
  bool get _dirty {
    final base = _original;
    if (!_isEdit || _readOnly || base == null) return false;
    return DdlBuilder.hasChanges(_design, base, _typeId);
  }

  /// 「保存」是否可点:编辑模式额外要求「有变更」且不在加载中
  bool get _canSave =>
      !_saving &&
      !_loading &&
      _loadError == null &&
      _valid &&
      !_readOnly &&
      (!_isEdit || _dirty);

  /// 调整已有列顺序仅 MySQL 家族能生成 `MODIFY ... AFTER`
  bool get _canReorderColumns => !_isEdit || DdlBuilder.isMysqlLike(_typeId);

  /// 当前标签的动作按钮是否可用:只读降级与编辑模式不支持的标签(触发器 /
  /// 规则 / 排除)置灰,与 [DdlBuilder.alterUnsupported] 的拦口保持一致
  bool get _actionsEnabled {
    if (_readOnly) return false;
    if (_isEdit && (_tabIndex == 5 || _tabIndex == 6 || _tabIndex == 7)) {
      return false;
    }
    return true;
  }

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

  /// 常用字段类型(小写存储,覆盖 PostgreSQL / MySQL 主流;类型格可输入自定义值)
  static const List<String> _typeOptions = [
    'int2',
    'int4',
    'int8',
    'integer',
    'smallint',
    'mediumint',
    'bigint',
    'tinyint',
    'serial',
    'bigserial',
    'smallserial',
    'decimal',
    'numeric',
    'float',
    'real',
    'double precision',
    'money',
    'bit',
    'bool',
    'boolean',
    'char',
    'varchar',
    'bpchar',
    'text',
    'tinytext',
    'mediumtext',
    'longtext',
    'date',
    'time',
    'datetime',
    'timestamp',
    'timestamptz',
    'interval',
    'year',
    'uuid',
    'json',
    'jsonb',
    'xml',
    'bytea',
    'blob',
    'tinyblob',
    'mediumblob',
    'longblob',
    'varbit',
    'inet',
    'cidr',
    'macaddr',
    'enum',
    'set',
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

  /// 「虚拟类型」下拉候选(与截图一致;与 identityMode 的双向映射见下方函数)
  static const List<String> _identityOptions = [
    '无',
    'GENERATED ALWAYS AS IDENTITY',
    'GENERATED BY DEFAULT AS IDENTITY',
  ];

  /// 默认值候选(仍可手工输入其它表达式)
  static const List<String> _defaultOptions = [
    '',
    'NULL',
    'true',
    'false',
    'current_timestamp',
    'current_date',
    '0',
    "''",
  ];

  /// PostgreSQL 常用排序规则候选(仍可手工输入)
  static const List<String> _collationOptions = [
    '',
    'default',
    'C',
    'POSIX',
    'en_US.utf8',
    'zh_CN.utf8',
  ];

  /// 删除类动作图标色(功能强调色,主题无关,与本文件错误提示同色)
  static const Color _iconDanger = Color(0xFFDC2626);

  /// 字段网格列宽(与截图比例一致;前导行标记另占 [_rowMarkerWidth])
  static const List<double> _fieldWidths = [170, 160, 64, 64, 72, 64, 210];

  /// 行首「当前行」标记列宽(表头与行同时预留,保证列对齐)
  static const double _rowMarkerWidth = 16;

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
    // 新建模式预置一行空字段(与参考工具一致);编辑模式的列由反查结果填充
    if (!_isEdit) _design.columns.add(DesignColumn());
    _loadRefTables();
    _ensureCandidates();
    if (_isEdit) _loadExisting();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _commentCtrl.dispose();
    _sqlCtrl.dispose();
    super.dispose();
  }

  /// 懒加载下拉候选:外键「被引用的表」与模式 / 函数 / 用户 列表。
  /// 加载失败保持空列表(仍可手动输入表名)。
  Future<void> _loadRefTables() async {
    final app = context.read<AppState>();
    final conn = app.connectionByName(widget.connection);
    if (conn == null || !app.connectionManager.isConnected(conn.name)) return;
    final manager = app.connectionManager;
    try {
      final state = manager.tableStateOf(conn.name, widget.database, schema: widget.schema);
      if (state.status != LoadStatus.loaded) {
        if (widget.schema != null) {
          await manager.expandSchema(conn, widget.database, widget.schema!);
        } else {
          await manager.expandDatabase(conn, widget.database);
        }
      }
      final fresh = manager.tableStateOf(conn.name, widget.database, schema: widget.schema);
      // 模式列表独立缓存(函数名的 schema 候选、外键被引用模式)
      final schemas = manager.schemaStateOf(conn.name, widget.database);
      if (schemas.status == LoadStatus.idle) {
        await manager.ensureSchemas(conn, widget.database);
      }
      if (!mounted) return;
      setState(() {
        _refTables = fresh.tables ?? const [];
        _functions = fresh.functions ?? const [];
        _users = fresh.users ?? const [];
        _schemas = manager.schemaStateOf(conn.name, widget.database).schemas;
      });
    } catch (_) {
      // 连接未就绪等场景:静默,允许手动输入表名
    }
  }

  /// 懒加载排序规则 / 运算符类别 / 表空间 候选(整页只发一次查询)。
  ///
  /// 连接未就绪时不置已发标志(下次打开控件可重试);查询失败或驱动无
  /// 对应系统目录时候选留空,控件退化为手输,不打扰用户。
  Future<void> _ensureCandidates() async {
    if (_candidatesRequested) return;
    final loader = widget.candidatesLoader;
    final app = context.read<AppState>();
    final conn = app.connectionByName(widget.connection);
    final manager = app.connectionManager;
    if (loader == null &&
        (conn == null || !manager.isConnected(conn.name))) {
      return; // 连接未就绪:下次打开控件仍可重试
    }
    _candidatesRequested = true;
    try {
      final fresh = loader != null
          ? await loader(widget.database)
          : await manager.readDesignCandidates(conn!, widget.database);
      if (!mounted) return;
      setState(() {
        _collations = fresh.collations;
        _opClasses = fresh.opClasses;
        _tablespaces = fresh.tablespaces;
      });
    } catch (_) {
      // 无系统目录读权限 / 连接已断开:候选留空,控件退化为手输
    }
  }

  /// 排序规则候选:优先用数据库实际目录,取不到时退回常用静态列表
  /// (首项空串 = 不指定,与静态列表保持一致)。
  List<String> get _collationChoices =>
      _collations.isEmpty ? _collationOptions : ['', ..._collations];

  /// 反查已有表结构回填,并留存基线快照。
  ///
  /// 驱动返回 null = 该类型不支持结构编辑(SQLite / Access):降级为只读展示,
  /// 仅按 [DatabaseDriver.describeTable] 填列基础信息;抛错 = 读取失败,
  /// 展示错误与「重试」(不能静默变成一张空表,否则用户会误以为表无字段)。
  Future<void> _loadExisting() async {
    final table = widget.existingTable;
    if (table == null) return;
    final app = context.read<AppState>();
    final loader = widget.designLoader;
    final conn =
        loader == null ? app.connectionByName(widget.connection) : null;
    if (loader == null && conn == null) {
      setState(() => _loadError = '连接 "${widget.connection}" 不存在');
      return;
    }
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final read = loader != null
          ? await loader(widget.database, table, widget.schema)
          : await app.connectionManager
              .readTableDesign(conn!, widget.database, table, schema: widget.schema);
      if (!mounted) return;
      if (read == null) {
        final cols = conn == null
            ? const <ColumnDef>[]
            : await app.connectionManager.describeTable(
                conn, widget.database, table, schema: widget.schema);
        if (!mounted) return;
        _applyDesign(
            DesignTable()
              ..name = table
              ..schema = widget.schema
              ..columns.addAll(cols.map(_columnFromDef)),
            readOnly: true);
        return;
      }
      _applyDesign(read);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _readOnly = false;
        _loadError = e.toString();
      });
    }
  }

  /// 反查结果落到界面,并重取基线快照(必须为独立副本,否则改完就没基线了)。
  void _applyDesign(DesignTable read, {bool readOnly = false}) {
    final fallback = widget.existingTable ?? '';
    final name = read.name.trim().isEmpty ? fallback : read.name.trim();
    _design
      ..name = name
      ..schema = widget.schema
      ..tableComment = read.tableComment
      ..fillFactor = read.fillFactor
      ..tablespace = read.tablespace
      ..pkName = read.pkName;
    _design.columns
      ..clear()
      ..addAll(read.columns);
    _design.indexes
      ..clear()
      ..addAll(read.indexes);
    _design.foreignKeys
      ..clear()
      ..addAll(read.foreignKeys);
    _design.uniqueKeys
      ..clear()
      ..addAll(read.uniqueKeys);
    _design.checks
      ..clear()
      ..addAll(read.checks);
    _design.excludes
      ..clear()
      ..addAll(read.excludes);
    _design.rules
      ..clear()
      ..addAll(read.rules);
    _design.triggers
      ..clear()
      ..addAll(read.triggers);
    _original = _design.snapshot();
    _nameCtrl.text = name;
    _commentCtrl.text = read.tableComment;
    _selColumn = _design.columns.isEmpty ? -1 : 0;
    _selIndex = _design.indexes.isEmpty ? -1 : 0;
    _selFk = _design.foreignKeys.isEmpty ? -1 : 0;
    _selUnique = _design.uniqueKeys.isEmpty ? -1 : 0;
    _selCheck = _design.checks.isEmpty ? -1 : 0;
    _selExclude = _design.excludes.isEmpty ? -1 : 0;
    _selRule = _design.rules.isEmpty ? -1 : 0;
    _selTrigger = _design.triggers.isEmpty ? -1 : 0;
    setState(() {
      _loading = false;
      _readOnly = readOnly;
      _loadError = null;
      _error = null;
      _note = null;
    });
  }

  /// 只读降级时把 [ColumnDef] 映射为网格行:仅名称 / 类型 / 长度 / 小数点 /
  /// 可空 / 主键 / 默认值 / 注释。这些信息不足以生成 ALTER,故该模式不可保存。
  DesignColumn _columnFromDef(ColumnDef d) {
    final split = splitColumnType(d.type);
    return DesignColumn(
      name: d.name,
      type: baseTypeOf(d.type, _typeId),
      length: split.length,
      decimal: split.decimal,
      notNull: !d.nullable,
      primaryKey: d.primaryKey,
      comment: d.comment,
      defaultValue: d.defaultValue ?? '',
    );
  }

  // ── 保存 ──────────────────────────────────────────────────

  /// 保存:新建模式执行 CREATE 全套语句;编辑模式先二次确认再执行 ALTER。
  Future<void> _save() async {
    if (_readOnly || _loading || _saving) return;
    final app = context.read<AppState>();
    final base = _original;
    if (_isEdit && base == null) return;
    final stmts = _isEdit
        ? DdlBuilder.buildAlterStatements(_design, base!, _typeId)
        : DdlBuilder.buildStatements(_design, _typeId);
    if (_isEdit) {
      // 无法用 ALTER 表达的变更(改列序 / 触发器 / 表选项等)直接阻断并说明原因,
      // 不静默丢弃用户的修改
      final blocked = DdlBuilder.alterUnsupported(_design, base!, _typeId);
      if (blocked != null) {
        setState(() => _error = blocked);
        return;
      }
      if (stmts.isEmpty) {
        setState(() => _note = '没有待应用的变更');
        return;
      }
      // 危险变更(删列 / 主键重建)只靠这一次确认;正文回显语句数与首条语句
      final risky = stmts.any((s) => RegExp(r'\bDROP\s+(COLUMN|PRIMARY\s+KEY)\b',
              caseSensitive: false)
          .hasMatch(s));
      final result = await MessageBox.show(
        context,
        title: '确认变更表结构',
        message: '将在 ${widget.database} 对 ${_design.name.trim()} 执行 '
            '${stmts.length} 条变更语句。\n\n'
            '${stmts.first}${stmts.length > 1 ? '\n…' : ''}'
            '${risky ? '\n\n含删除列 / 主键重建,数据不可逆。' : ''}',
        type: risky ? MessageBoxType.warning : MessageBoxType.question,
        buttons: MessageBoxButtons.okCancel,
        okText: risky ? '仍要执行' : '执行变更',
        cancelText: '取消',
      );
      if (!mounted || result != MessageBoxResult.ok) return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _note = null;
    });
    final outcome = _isEdit
        ? await app.saveTableDesignEdit(
            _design,
            base!,
            connection: widget.connection,
            database: widget.database,
            schema: widget.schema,
          )
        : await app.createTableDesign(
            _design,
            connection: widget.connection,
            database: widget.database,
            schema: widget.schema,
          );
    if (!mounted) return;
    if (!outcome.ok) {
      // 保留编辑内容与基线(仍为「已修改」),原文回显驱动错误
      final detail = outcome.error ?? (_isEdit ? '保存表结构失败' : '新建表失败');
      final String? tail;
      if (!_isEdit) {
        tail = null;
      } else if (outcome.rolledBack) {
        tail = '所有变更已回滚';
      } else if (outcome.failedAt > 0) {
        tail = '第 ${outcome.failedAt} 条语句失败,之前的变更已生效';
      } else {
        tail = null;
      }
      setState(() {
        _saving = false;
        _error = tail == null ? detail : '$detail · $tail';
      });
      return;
    }
    if (!_isEdit) {
      // 成功后关闭设计器标签;对象列表已由 createTableDesign 刷新
      app.closeTab(widget.title);
      return;
    }
    // 编辑成功后不关标签(可继续改),只把基线前移到当前设计
    final oldTitle = widget.title;
    final newTitle = '${_design.name.trim()} (设计)';
    setState(() {
      _saving = false;
      _original = _design.snapshot();
      _note = '已保存 ${stmts.length} 条变更';
    });
    // 表被重命名:同步换标签标题,否则下次打开会错配到旧表名
    if (newTitle != oldTitle) app.renameTab(oldTitle, newTitle);
  }

  // ── 主布局 ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final validation = DdlBuilder.validate(_design);
    _valid = validation.ok;
    _invalidReason = validation.error ?? '设计数据不完整';
    // 一有实质变更就撤下上次保存的提示,不长期挂「已保存」
    if (_note != null && _dirty) _note = null;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyS, control: true): _SaveIntent(),
        SingleActivator(LogicalKeyboardKey.keyS, meta: true): _SaveIntent(),
      },
      child: Actions(
        actions: {
          _SaveIntent: CallbackAction<_SaveIntent>(
            onInvoke: (_) {
              if (_canSave) _save();
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

  /// 内容区容器:加载中 / 读取失败占满整块;只读降级在顶部加提示条。
  Widget _tabBody(AppPalette t, int index) {
    final table = widget.existingTable ?? '';
    if (_loading) {
      return Empty(
        icon: const Spinner(size: 20),
        title: '正在加载 $table 的结构 ...',
        compact: true,
        maxWidth: 520,
      );
    }
    if (_loadError != null) {
      return Empty(
        icon: const Icon(Icons.error_outline),
        title: '读取 $table 结构失败',
        description: _loadError,
        action: Button(text: '重试', onPressed: _loadExisting),
        compact: true,
        maxWidth: 520,
      );
    }
    final body = _tabContent(t, index);
    if (!_readOnly) return body;
    final warn = AppColors.of(context).iconWarning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 22,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          // 由主题警告色派生底色,明暗两套都能看清
          color: Color.alphaBlend(warn.withValues(alpha: 0.16), t.surface),
          child: Row(
            children: [
              Icon(Icons.lock_outline, size: 13, color: warn),
              const SizedBox(width: 6),
              const Expanded(
                child: Label(
                  '当前数据库类型暂不支持编辑已有表结构,仅可查看',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  /// 按活动标签索引返回对应内容
  Widget _tabContent(AppPalette t, int index) {
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

  /// 标题栏:表名 @ 库.模式 (连接 · 类型),编辑模式尾部追加「— 设计」
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
        '$name @ ${widget.database}$schemaSuffix (${widget.connection} · $_typeLabel)'
        '${_isEdit ? ' — 设计' : ''}',
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
    final c = AppColors.of(context);
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
              enabled: !_readOnly,
              selectAllOnFocus: false,
              // 编辑模式改表名 = 生成 RENAME
              onChanged: (v) => setState(() => _design.name = v),
            ),
          ),
          const SizedBox(width: 10),
          ToolbarButton(
            icon: Icons.save_outlined,
            iconColor: c.iconPrimary,
            text: '保存',
            outlined: true,
            enabled: _canSave,
            onTap: _save,
          ),
          const SizedBox(width: 14),
          Container(width: 1, height: 22, color: t.border),
          const SizedBox(width: 14),
          // 窄窗口下动作按钮可能多于可用宽:横向滚动而非 RenderFlex 溢出
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: _tabActions(t),
            ),
          ),
        ],
      ),
    );
  }

  /// 「添加 X / 删除 X」按钮对(与参考工具一致:绿色 ⊕ / 红色 ⊖)
  List<Widget> _addRemoveActions({
    required String label,
    required VoidCallback onAdd,
    required VoidCallback onRemove,
  }) {
    final c = AppColors.of(context);
    return [
      ToolbarButton(
        icon: Icons.add_circle_outline,
        iconColor: c.iconSuccess,
        text: '添加$label',
        onTap: onAdd,
      ),
      const SizedBox(width: 10),
      ToolbarButton(
        icon: Icons.remove_circle_outline,
        iconColor: _iconDanger,
        text: '删除$label',
        onTap: onRemove,
      ),
    ];
  }

  /// 当前标签专属动作按钮(字段:增删插/主键/上下移;其余:增删)
  Widget _tabActions(AppPalette t) {
    final c = AppColors.of(context);
    final actions = <Widget>[];
    switch (_tabIndex) {
      case 0:
        final cols = _design.columns;
        final hasSel = _selColumn >= 0 && _selColumn < cols.length;
        actions.addAll([
          ToolbarButton(
            icon: Icons.add_circle_outline,
            iconColor: c.iconSuccess,
            text: '添加字段',
            onTap: _addColumn,
          ),
          const SizedBox(width: 2),
          ToolbarButton(
            icon: Icons.subdirectory_arrow_right,
            text: '插入字段',
            onTap: _insertColumn,
          ),
          const SizedBox(width: 2),
          ToolbarButton(
            icon: Icons.remove_circle_outline,
            iconColor: _iconDanger,
            text: '删除字段',
            enabled: cols.isNotEmpty,
            onTap: _removeColumn,
          ),
          const SizedBox(width: 10),
          // 「主键 ▾」:弹层开合由 DropDownButton 的 Listener 处理,按钮仅提供视觉态
          DropDownButton(
            width: 156,
            trigger: ToolbarButton(
              icon: Icons.key,
              iconColor: c.iconWarning,
              text: '主键',
              showCaret: true,
              enabled: cols.isNotEmpty,
              onTap: () {},
            ),
            items: [
              ListItem(
                title: '设置主键',
                enabled: hasSel,
                onSelect: () => _setPk(true),
              ),
              ListItem(
                title: '取消主键',
                enabled: hasSel,
                onSelect: () => _setPk(false),
              ),
            ],
          ),
          const SizedBox(width: 10),
          ToolbarButton(
            icon: Icons.arrow_upward,
            text: '上移',
            enabled: _selColumn > 0 && _canReorderColumns,
            onTap: _moveColumnUp,
          ),
          const SizedBox(width: 2),
          ToolbarButton(
            icon: Icons.arrow_downward,
            text: '下移',
            enabled:
                hasSel && _selColumn < cols.length - 1 && _canReorderColumns,
            onTap: _moveColumnDown,
          ),
        ]);
      case 1:
        actions.addAll(_addRemoveActions(
          label: '索引',
          onAdd: () => _addRow(_design.indexes, (i) => _selIndex = i),
          onRemove: () => _removeRow(_design.indexes, () => _selIndex, (i) => _selIndex = i),
        ));
      case 2:
        actions.addAll(_addRemoveActions(
          label: '外键',
          onAdd: _addFk,
          onRemove: () => _removeRow(_design.foreignKeys, () => _selFk, (i) => _selFk = i),
        ));
      case 3:
        actions.addAll(_addRemoveActions(
          label: '唯一键',
          onAdd: () => _addRow(_design.uniqueKeys, (i) => _selUnique = i),
          onRemove: () => _removeRow(_design.uniqueKeys, () => _selUnique, (i) => _selUnique = i),
        ));
      case 4:
        actions.addAll(_addRemoveActions(
          label: '检查',
          onAdd: () => _addRow(_design.checks, (i) => _selCheck = i),
          onRemove: () => _removeRow(_design.checks, () => _selCheck, (i) => _selCheck = i),
        ));
      case 5:
        actions.addAll(_addRemoveActions(
          label: '排除',
          onAdd: () => _addRow(_design.excludes, (i) => _selExclude = i),
          onRemove: () => _removeRow(_design.excludes, () => _selExclude, (i) => _selExclude = i),
        ));
      case 6:
        actions.addAll(_addRemoveActions(
          label: '规则',
          onAdd: () => _addRow(_design.rules, (i) => _selRule = i),
          onRemove: () => _removeRow(_design.rules, () => _selRule, (i) => _selRule = i),
        ));
      case 7:
        actions.addAll(_addRemoveActions(
          label: '触发器',
          onAdd: () => _addRow(_design.triggers, (i) => _selTrigger = i),
          onRemove: () => _removeRow(_design.triggers, () => _selTrigger, (i) => _selTrigger = i),
        ));
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
    // 编辑已有表时上移 / 下移置灰(PG / SQL Server 无对应 ALTER)
    if (_tabIndex == 0 && !_canReorderColumns) {
      actions.add(const SizedBox(width: 12));
      actions.add(Text(
        '调整已有列的顺序仅 MySQL / MariaDB 支持',
        style: TextStyle(fontSize: 11, color: t.disabledForeground),
      ));
    }
    final row = Row(mainAxisSize: MainAxisSize.min, children: actions);
    if (_actionsEnabled) return row;
    // 只读降级 / 不支持编辑的标签:整组动作置灰不可点
    return IgnorePointer(
      ignoring: true,
      child: Opacity(opacity: 0.45, child: row),
    );
  }

  /// 底部状态条:错误 / 校验提示 / 上次保存结果 + 变更状态 + 保存中提示
  Widget _statusBar(AppPalette t) {
    // 加载期间字段为空并非「设计无效」,不抢提示位
    final showInvalid = !_valid && !_loading && _loadError == null;
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
          else if (showInvalid)
            Expanded(
              child: Text(
                _invalidReason,
                style: TextStyle(fontSize: 12, color: t.disabledForeground),
                overflow: TextOverflow.ellipsis,
              ),
            )
          else if (_note != null)
            Expanded(
              child: Text(
                _note!,
                style: TextStyle(fontSize: 12, color: t.mutedForeground),
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            const Spacer(),
          // 变更状态指示(仅编辑模式):只读 / 已修改 / 无变更
          if (_isEdit && !_loading && _loadError == null) ...[
            Text(
              _readOnly ? '只读' : (_dirty ? '已修改' : '无变更'),
              style: TextStyle(
                fontSize: 12,
                color: _dirty ? t.accent : t.disabledForeground,
              ),
            ),
            const SizedBox(width: 10),
          ],
          if (_saving) ...[
            const Spinner(size: 12),
            const SizedBox(width: 8),
            Text(
              _isEdit ? '正在保存变更 ...' : '正在创建表 ...',
              style: TextStyle(fontSize: 12, color: t.mutedForeground),
            ),
          ],
        ],
      ),
    );
  }

  // ── 字段标签 ──────────────────────────────────────────────

  Widget _fieldsTab(AppPalette t) {
    final cols = _design.columns;
    final sel = _selColumn.clamp(0, cols.isEmpty ? 0 : cols.length - 1);
    // 主键序号与表级 PRIMARY KEY 列序同一来源,保证 🔑n 与 SQL 一致
    final ordinals = DdlBuilder.pkOrdinals(_design);
    return _editorGrid(
      t,
      headers: const ['名称', '类型', '长度', '小数点', '不是 null', '键', '注释'],
      widths: _fieldWidths,
      rowCount: cols.length,
      selected: cols.isEmpty ? -1 : _selColumn,
      onSelect: (i) => setState(() => _selColumn = i),
      rowBuilder: (i) => _fieldRow(t, cols[i], i, ordinals[cols[i]]),
      propsPanel: _props(
        t,
        cols.isEmpty ? null : cols[sel],
        (c) => _columnProps(t, c),
        hint: _identityHintText(),
      ),
    );
  }

  /// 字段页底部属性面板行(顺序与截图一致:
  /// 默认 / 排序规则 / 维度 / 虚拟类型 / 递增 / 最小 / 最大 / 开始值 / 缓存 / 循环)
  List<Widget> _columnProps(AppPalette t, DesignColumn c) {
    final isPg = DdlBuilder.isPgLike(_typeId);
    final isMysql = DdlBuilder.isMysqlLike(_typeId);
    final isSqlServer = DdlBuilder.isSqlServerLike(_typeId);
    final identityOn = c.hasIdentity;
    final rows = <Widget>[
      _propField(
        t,
        '默认',
        ComboBox<String>(
          items: _defaultOptions,
          value: c.defaultValue,
          editable: true,
          enabled: !_readOnly,
          hint: '字符串自动加引号',
          onChanged: (v) => setState(() => c.defaultValue = v ?? ''),
        ),
      ),
      _propField(
        t,
        '排序规则',
        // 两个下拉并排(同截图):左为排序规则名(仅字符类型可用),
        // 右为占位(PG 无对应语法,不参与 DDL)
        Row(
          children: [
            SizedBox(
              width: 168,
              child: ComboBox<String>(
                items: _collationChoices,
                value: c.collation,
                editable: true,
                enabled: _isTextType(c.type) && !_readOnly,
                onChanged: (v) => setState(() => c.collation = v ?? ''),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(child: _disabledInput),
          ],
        ),
      ),
      _propField(
        t,
        '维度',
        _modelInput(c.dimension, (v) => c.dimension = v,
            enabled: isPg, textAlign: TextAlign.right, keyboardType: TextInputType.number),
      ),
    ];
    if (isMysql) {
      // MySQL / MariaDB 无 IDENTITY 概念:保留「自增」复选框(AUTO_INCREMENT)
      rows.add(_propField(
        t,
        '自增',
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CheckBox(
              value: c.autoIncrement,
              enabled: !_readOnly,
              onChanged: (v) => setState(() => c.autoIncrement = v ?? false),
            ),
            const SizedBox(width: 6),
            Text('AUTO_INCREMENT', style: TextStyle(fontSize: 12, color: t.mutedForeground)),
          ],
        ),
      ));
      return rows;
    }
    rows.add(_propField(
      t,
      isSqlServer ? '标识' : '虚拟类型',
      ComboBox<String>(
        items: _identityOptions,
        value: _identityLabelOf(c.identityMode),
        // SQLite / Access 无自增 / 标识列的统一写法,禁用并提示
        enabled: (isPg || isSqlServer) && !_readOnly,
        onChanged: (v) => setState(() => _applyIdentity(c, _identityModeOf(v ?? '无'))),
      ),
    ));
    Widget num(String label, String value, ValueChanged<String> set) =>
        _propField(
          t,
          label,
          _modelInput(value, set,
              enabled: identityOn,
              textAlign: TextAlign.right,
              keyboardType: TextInputType.number),
        );
    rows.add(num('递增', c.identityIncrement, (v) => c.identityIncrement = v));
    rows.add(num('开始值', c.identityStart, (v) => c.identityStart = v));
    if (isPg) {
      rows.add(num('最小', c.identityMinValue, (v) => c.identityMinValue = v));
      rows.add(num('最大', c.identityMaxValue, (v) => c.identityMaxValue = v));
      rows.add(num('缓存', c.identityCache, (v) => c.identityCache = v));
      rows.add(_propField(
        t,
        '循环',
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CheckBox(
              value: c.identityCycle,
              enabled: identityOn && !_readOnly,
              onChanged: (v) => setState(() => c.identityCycle = v ?? false),
            ),
            const SizedBox(width: 6),
            Text('CYCLE', style: TextStyle(fontSize: 12, color: t.mutedForeground)),
          ],
        ),
      ));
    }
    return rows;
  }

  /// 属性面板尾部的方言提示(无提示时返回 null,面板不占行)
  String? _identityHintText() {
    if (DdlBuilder.isPgLike(_typeId)) return null;
    if (DdlBuilder.isMysqlLike(_typeId)) return 'MySQL / MariaDB 自增:生成 AUTO_INCREMENT。';
    if (DdlBuilder.isSqlServerLike(_typeId)) return 'SQL Server 标识列:生成 IDENTITY(开始值,递增)。';
    return '当前类型不支持自增 / 标识列,这些属性不参与 DDL 生成。';
  }

  /// 字符类类型(决定「排序规则」是否可编辑)
  static bool _isTextType(String type) => const {
        'char',
        'varchar',
        'bpchar',
        'character',
        'text',
        'tinytext',
        'mediumtext',
        'longtext',
        'citext',
        'nvarchar',
        'nchar',
        'enum',
        'set',
      }.contains(type.trim().toLowerCase());

  static String _identityLabelOf(String mode) => switch (mode) {
        'ALWAYS' => 'GENERATED ALWAYS AS IDENTITY',
        'BY DEFAULT' => 'GENERATED BY DEFAULT AS IDENTITY',
        _ => '无',
      };

  static String _identityModeOf(String label) => switch (label) {
        'GENERATED ALWAYS AS IDENTITY' => 'ALWAYS',
        'GENERATED BY DEFAULT AS IDENTITY' => 'BY DEFAULT',
        _ => '',
      };

  /// 类型变更:若「最大」仍是旧类型的自动上限,跟随新类型更新(不覆盖用户手输值)
  void _onColumnTypeChanged(DesignColumn c, String newType) {
    final old = c.type;
    c.type = newType;
    if (c.hasIdentity &&
        c.identityMaxValue.isNotEmpty &&
        c.identityMaxValue == kIdentityMaxValue(old)) {
      c.identityMaxValue = kIdentityMaxValue(newType);
    }
  }

  Widget _fieldRow(AppPalette t, DesignColumn c, int index, int? pkOrdinal) {
    final colors = AppColors.of(context);
    final w = _fieldWidths;
    // 无长度参数的整数类型:长度格显示位宽(仅信息展示,禁用编辑)
    final bit = bitWidthOf(c.type);
    return Row(
      children: [
        SizedBox(width: w[0], child: _modelInput(c.name, (v) => c.name = v, hint: '列名')),
        const SizedBox(width: 6),
        SizedBox(
          width: w[1],
          child: ComboBox<String>(
            items: _typeOptions,
            value: c.type.isEmpty ? null : c.type,
            editable: true,
            enabled: !_readOnly,
            hint: '类型',
            onChanged: (v) => setState(() => _onColumnTypeChanged(c, v ?? '')),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: w[2],
          child: _modelInput(
            bit ?? c.length,
            (v) => c.length = v,
            hint: '长度',
            enabled: bit == null,
            textAlign: TextAlign.right,
            keyboardType: TextInputType.number,
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: w[3],
          child: _modelInput(
            c.decimal,
            (v) => c.decimal = v,
            hint: '小数点',
            enabled: bit == null,
            textAlign: TextAlign.right,
            keyboardType: TextInputType.number,
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: w[4],
          child: Center(
            child: CheckBox(
              value: c.notNull,
              // IDENTITY 列必须 NOT NULL(由 _applyIdentity 保证),不再开放编辑
              enabled: !(c.hasIdentity && DdlBuilder.isPgLike(_typeId)) && !_readOnly,
              onChanged: (v) => setState(() => c.notNull = v ?? false),
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: w[5],
          // 「键」格:按下即切换主键(零延迟);主键行显示 钥匙 + 序号
          child: Listener(
            onPointerDown: (_) {
              if (!_readOnly) _togglePkAt(index);
            },
            behavior: HitTestBehavior.opaque,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Center(
                child: c.primaryKey
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.key, size: 14, color: colors.iconWarning),
                          const SizedBox(width: 2),
                          Text(
                            '${pkOrdinal ?? 1}',
                            style: TextStyle(
                              fontSize: 12,
                              color: t.foreground,
                              decoration: TextDecoration.none,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
            ),
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
          _propField(t, '表空间',
              _candidateCombo(_tablespaces, it.tablespace,
                  (v) => it.tablespace = v, '表空间名',
                  enabled: DdlBuilder.isPgLike(_typeId))),
          _propField(t, '填充因子 (%)', _modelInput(it.fillFactor, (v) => it.fillFactor = v)),
          _propField(t, '正在缓冲', _disabledInput),
          _propField(t, '快速更新', _disabledInput),
          _propField(t, '待处理列表限制', _disabledInput),
          _propField(t, '每范围页数', _disabledInput),
          // 约束名 = 该索引背后的主键 / 唯一约束:由 CREATE TABLE / ALTER ADD CONSTRAINT
          // 生成,此处仅展示,开放编辑会得到两条互相冲突的语句
          _propField(t, '约束', _readonlyInput(_backingConstraintName(it))),
        ],
      ),
    );
  }

  /// 索引对应的约束名(主键 / 唯一键同名约束);无则留空
  String _backingConstraintName(DesignIndex idx) {
    final key = idx.name.trim().toLowerCase();
    if (key.isEmpty) return '';
    final pk = _design.pkName.trim();
    if (pk.toLowerCase() == key) return pk;
    for (final uk in _design.uniqueKeys) {
      if (uk.name.trim().toLowerCase() == key) return uk.name.trim();
    }
    return '';
  }

  /// 打开「选择数据表字段」弹窗,确认后写回字段项并同步逗号串
  Future<void> _pickIndexColumns(DesignIndex idx) async {
    await _ensureCandidates();
    final picked = await IndexColumnPickerDialog.show(
      context,
      fields: [
        for (final c in _design.columns) c.name.trim(),
      ].where((e) => e.isNotEmpty).toList(),
      selected: idx.columnItems,
      schemaCandidates: _schemas,
      collationCandidates: _collationChoices,
      opClassCandidates: _opClasses,
    );
    if (picked == null) return;
    setState(() {
      idx.columnItems
        ..clear()
        ..addAll(picked);
      idx.applyColumnItems();
    });
  }

  Widget _indexRow(AppPalette t, DesignIndex it) {
    // 复选框可用性统一收口(只读降级不逐个传参)
    Widget box(bool value, ValueChanged<bool> set) => CheckBox(
        value: value,
        enabled: !_readOnly,
        onChanged: (v) => setState(() => set(v ?? false)));
    return Row(
      children: [
        SizedBox(width: 140, child: _modelInput(it.name, (v) => it.name = v, hint: '索引名')),
        const SizedBox(width: 6),
        SizedBox(
          width: 150,
          // 字段格:可直接输逗号串,也可点 `...` 用弹窗逐字段设选项
          child: Row(
            children: [
              Expanded(
                child: _modelInput(it.columns, (v) => it.columns = v, hint: '多列用逗号分隔'),
              ),
              const SizedBox(width: 4),
              _dotsButton(onTap: _readOnly ? null : () => _pickIndexColumns(it)),
            ],
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 110,
          child: ComboBox<String>(
            items: _indexMethods,
            value: it.method.isEmpty ? null : it.method,
            enabled: !_readOnly,
            onChanged: (v) => setState(() => it.method = v ?? ''),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(width: 64, child: Center(child: box(it.unique, (v) => it.unique = v))),
        const SizedBox(width: 6),
        SizedBox(width: 64, child: Center(child: box(it.concurrent, (v) => it.concurrent = v))),
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
      headers: const ['名称', '字段', '被引用的模式', '被引用的表（父）', '被引用的字段', '删除时', '更新时', '注释'],
      widths: const [110, 100, 100, 120, 100, 96, 96, 180],
      rowCount: items.length,
      selected: _selFk,
      onSelect: (i) => setState(() => _selFk = i),
      rowBuilder: (i) => _fkRow(t, items[i]),
      propsPanel: _props(
        t,
        _selFk >= 0 && _selFk < items.length ? items[_selFk] : null,
        (fk) => [
          _propField(
            t,
            '符合全部',
            CheckBox(
              value: fk.matchAll,
              enabled: !_readOnly,
              onChanged: (v) => setState(() => fk.matchAll = v ?? false),
            ),
          ),
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
            enabled: !_readOnly,
            hint: '表名',
            onChanged: (v) => setState(() => fk.refTable = v ?? ''),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(width: 100, child: _modelInput(fk.refColumns, (v) => fk.refColumns = v, hint: '如 id')),
        const SizedBox(width: 6),
        SizedBox(
          width: 96,
          child: ComboBox<String>(
            items: _fkActions,
            value: fk.onDelete,
            enabled: !_readOnly,
            onChanged: (v) => setState(() => fk.onDelete = v ?? 'NO ACTION'),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 96,
          child: ComboBox<String>(
            items: _fkActions,
            value: fk.onUpdate,
            enabled: !_readOnly,
            onChanged: (v) => setState(() => fk.onUpdate = v ?? 'NO ACTION'),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(child: _modelInput(fk.comment, (v) => fk.comment = v, hint: '注释')),
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
          _propField(t, '表空间',
              _candidateCombo(_tablespaces, uk.tablespace,
                  (v) => uk.tablespace = v, '表空间名',
                  enabled: DdlBuilder.isPgLike(_typeId))),
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
            enabled: !_readOnly,
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
            enabled: !_readOnly,
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
          // 属性面板内再分「常规 / 约束」两个子页(与参考工具一致)
          SizedBox(
            height: 26,
            child: TabControl(
              initialIndex: _triggerPropsTab,
              barHeight: 24,
              tabWidth: 62,
              tabBarColor: t.surface,
              selectedTabColor: t.background,
              hoverTabColor: t.secondary,
              contentPadding: EdgeInsets.zero,
              onChanged: (i) => setState(() => _triggerPropsTab = i),
              tabs: const [TabItem(label: '常规'), TabItem(label: '约束')],
            ),
          ),
          ...(_triggerPropsTab == 0
              ? _triggerGeneralProps(t, tr)
              : _triggerConstraintProps(t, tr)),
        ],
      ),
    );
  }

  /// 触发器「常规」子页:WHEN 条件 / 触发函数(模式 + 函数名)/ 参数
  List<Widget> _triggerGeneralProps(AppPalette t, DesignTrigger tr) {
    final fn = tr.function.trim();
    final dot = fn.lastIndexOf('.');
    final fnSchema = dot < 0 ? '' : fn.substring(0, dot);
    final fnName = dot < 0 ? fn : fn.substring(dot + 1);
    return [
      _propField(t, '当', _modelInput(tr.when, (v) => tr.when = v, hint: 'WHEN 条件')),
      _propField(
        t,
        '触发函数',
        Row(
          children: [
            SizedBox(
              width: 172,
              child: ComboBox<String>(
                items: _schemas,
                value: fnSchema.isEmpty ? null : fnSchema,
                editable: true,
                enabled: !_readOnly,
                hint: '模式',
                onChanged: (v) =>
                    setState(() => tr.function = _joinQualified(v ?? '', fnName)),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 182,
              child: ComboBox<String>(
                items: _functions,
                value: fnName.isEmpty ? null : fnName,
                editable: true,
                enabled: !_readOnly,
                hint: '函数名',
                onChanged: (v) =>
                    setState(() => tr.function = _joinQualified(fnSchema, v ?? '')),
              ),
            ),
          ],
        ),
      ),
      _propField(t, '参数', _modelInput(tr.parameters, (v) => tr.parameters = v, hint: '如 NEW.id')),
    ];
  }

  /// 触发器「约束」子页:可延迟 / 延迟(仅 PostgreSQL 生成 CREATE CONSTRAINT TRIGGER)
  List<Widget> _triggerConstraintProps(AppPalette t, DesignTrigger tr) {
    final isPg = DdlBuilder.isPgLike(_typeId);
    final deferredEnabled = isPg && tr.deferrable.trim().toUpperCase() == 'YES';
    return [
      _propField(t, '可延迟',
          _yesNoCombo(tr.deferrable, (v) => tr.deferrable = v, enabled: isPg)),
      _propField(t, '延迟',
          _yesNoCombo(tr.deferred, (v) => tr.deferred = v, enabled: deferredEnabled)),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          isPg
              ? '可延迟的触发器生成 CREATE CONSTRAINT TRIGGER … DEFERRABLE;'
                  '延迟需先置「可延迟 = YES」。'
              : '仅 PostgreSQL 支持约束触发器,其它类型保存时忽略。',
          style: TextStyle(fontSize: 11.5, color: t.disabledForeground),
        ),
      ),
    ];
  }

  /// 模式 + 函数名 合成模型里的限定名(模式为空时只留函数名)
  String _joinQualified(String schema, String name) {
    final s = schema.trim();
    final n = name.trim();
    if (s.isEmpty) return n;
    return n.isEmpty ? s : '$s.$n';
  }

  Widget _triggerRow(AppPalette t, DesignTrigger tr) {
    Widget cell(Widget child) => Center(child: child);
    Widget box(bool value, ValueChanged<bool> set, {bool fallback = false}) => CheckBox(
        value: value,
        enabled: !_readOnly,
        onChanged: (v) => setState(() => set(v ?? fallback)));
    return Row(
      children: [
        SizedBox(width: 110, child: _modelInput(tr.name, (v) => tr.name = v, hint: '触发器名')),
        const SizedBox(width: 6),
        SizedBox(
          width: 70,
          child: ComboBox<String>(
            items: _forEachOptions,
            value: tr.forEach,
            enabled: !_readOnly,
            onChanged: (v) => setState(() => tr.forEach = v ?? '行'),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 90,
          child: ComboBox<String>(
            items: _timingOptions,
            value: tr.timing,
            enabled: !_readOnly,
            onChanged: (v) => setState(() => tr.timing = v ?? 'BEFORE'),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(width: 44, child: cell(box(tr.insert, (v) => tr.insert = v))),
        const SizedBox(width: 6),
        SizedBox(width: 44, child: cell(box(tr.update, (v) => tr.update = v))),
        const SizedBox(width: 6),
        SizedBox(width: 44, child: cell(box(tr.delete, (v) => tr.delete = v))),
        const SizedBox(width: 6),
        SizedBox(width: 44, child: cell(box(tr.truncate, (v) => tr.truncate = v))),
        const SizedBox(width: 6),
        SizedBox(width: 110, child: _modelInput(tr.updateColumns, (v) => tr.updateColumns = v, hint: '更新字段')),
        const SizedBox(width: 6),
        SizedBox(width: 44, child: cell(box(tr.enable, (v) => tr.enable = v, fallback: true))),
        const SizedBox(width: 6),
        Expanded(child: _modelInput(tr.comment, (v) => tr.comment = v, hint: '注释')),
      ],
    );
  }

  // ── 选项标签 ──────────────────────────────────────────────

  Widget _optionsTab(AppPalette t) {
    final isPg = DdlBuilder.isPgLike(_typeId);
    // 表选项没有对应的 ALTER(不记录 / 继承 / 填充因子 都需重建表),编辑模式整页不开放
    final editable = !_readOnly && !_isEdit;
    final pgOn = editable && isPg;
    final ffOn = editable && (isPg || DdlBuilder.isSqlServerLike(_typeId));
    Widget combo(List<String> items, String value, ValueChanged<String> set, String hint,
            {bool enabled = true}) =>
        ComboBox<String>(
          items: items,
          value: value.isEmpty ? null : value,
          editable: true,
          enabled: enabled,
          hint: hint,
          onChanged: (v) => setState(() => set(v ?? '')),
        );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 28,
            child: CheckBox(
              value: _design.unlogged,
              label: '不记录',
              enabled: pgOn,
              onChanged: (v) => setState(() => _design.unlogged = v ?? false),
            ),
          ),
          _propField(
            t,
            '所有者',
            combo(_users, _design.owner, (v) => _design.owner = v, '角色名', enabled: pgOn),
          ),
          _propField(
            t,
            '表空间',
            combo(_tablespaces, _design.tablespace, (v) => _design.tablespace = v, '表空间名',
                enabled: pgOn),
          ),
          _propField(
            t,
            '继承自',
            Row(
              children: [
                Expanded(
                  child: _modelInput(_design.inherits, (v) => _design.inherits = v,
                      enabled: pgOn, hint: '父表,多个用逗号分隔'),
                ),
                const SizedBox(width: 4),
                _dotsButton(tooltip: '选择父表', onTap: pgOn ? _pickInherits : null),
              ],
            ),
          ),
          _propField(
            t,
            '填充因子 (%)',
            _modelInput(_design.fillFactor, (v) => _design.fillFactor = v,
                enabled: ffOn, keyboardType: TextInputType.number),
          ),
          _propField(
            t,
            '集群',
            combo(_clusterCandidates, _design.cluster, (v) => _design.cluster = v, '索引名',
                enabled: pgOn),
          ),
          const SizedBox(height: 10),
          Text(
            // 表选项无对应 ALTER(改填充因子需重建表),编辑模式不开放
            _isEdit
                ? '「设计表」不修改不记录 / 所有者 / 表空间 / 继承 / 填充因子 / 集群:无对应的 ALTER 语句。'
                : isPg
                    ? '不记录生成 CREATE UNLOGGED TABLE,继承生成 INHERITS(...),填充因子生成 WITH (fillfactor = n),'
                        '表空间生成 TABLESPACE;所有者与集群各补一条 ALTER TABLE … OWNER TO / CLUSTER … USING。'
                    : '表选项仅 PostgreSQL / SQL Server 部分支持;填充因子以外的表选项对其它类型不生成。',
            style: TextStyle(fontSize: 11.5, color: t.disabledForeground),
          ),
        ],
      ),
    );
  }

  /// 「集群」候选:本表已设计的索引名 + 主键约束名
  List<String> get _clusterCandidates => [
        for (final i in _design.indexes) i.name.trim(),
        _design.pkName.trim(),
      ].where((e) => e.isNotEmpty).toList();

  /// 选父表(排除本表自身;手工输入的不在候选里时并入,以免勾选丢失)
  Future<void> _pickInherits() async {
    final self = _design.name.trim().toLowerCase();
    final current = _design.inherits
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final items = <String>[
      for (final e in _refTables)
        if (e.trim().isNotEmpty && e.trim().toLowerCase() != self) e.trim(),
    ];
    for (final c in current) {
      if (!items.contains(c) && c.toLowerCase() != self) items.add(c);
    }
    final picked = await ListPickerDialog.show<String>(
      context,
      title: '选择继承的父表',
      items: items,
      selected: current,
      emptyHint: '当前库 / 模式没有其它表,可直接在输入框填写父表名。',
      okText: '确定',
      cancelText: '取消',
    );
    if (picked == null) return;
    setState(() => _design.inherits = picked.join(', '));
  }

  // ── 注释标签 ──────────────────────────────────────────────

  Widget _commentsTab(AppPalette t) {
    // 注释页整区留给编辑器(与参考工具一致):不加标题与底部说明,避免挤压输入区
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 2),
      child: Textarea(
        controller: _commentCtrl,
        hint: '输入表的注释…',
        enabled: !_readOnly,
        onChanged: (v) => setState(() => _design.tableComment = v),
        expands: true,
      ),
    );
  }

  // ── SQL 预览标签 ──────────────────────────────────────────

  /// 预览即所见:新建模式输出 CREATE 全套,编辑模式输出待应用的 ALTER。
  /// 编辑模式无差异时给一行说明,不留空白(否则看起来像加载失败)。
  String _previewSql() {
    final base = _original;
    if (!_isEdit || base == null) return DdlBuilder.buildPreview(_design, _typeId);
    final alter = DdlBuilder.alterPreview(_design, base, _typeId);
    return alter.trim().isEmpty ? '-- 没有待应用的变更' : alter;
  }

  Widget _sqlTab(AppPalette t) {
    final sql = _previewSql();
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
            _isEdit
                ? '「保存」将按以下顺序执行这些变更语句(PostgreSQL 在事务中执行,失败自动回滚)'
                : '「保存」将按以下顺序执行这些语句(PostgreSQL 在事务中执行,失败自动回滚)',
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
  /// [rowMarker] 控制行首「当前行」▶ 标记(表头同步预留宽度)。
  Widget _editorGrid(
    AppPalette t, {
    required List<String> headers,
    required List<double> widths,
    required int rowCount,
    required Widget Function(int row) rowBuilder,
    required int selected,
    required ValueChanged<int> onSelect,
    Widget? propsPanel,
    bool rowMarker = true,
  }) {
    final total = widths.fold(0.0, (a, b) => a + b) +
        (rowMarker ? _rowMarkerWidth : 0);
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
                        if (rowMarker) const SizedBox(width: _rowMarkerWidth),
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
                              showMarker: rowMarker,
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

  /// 行容器:Listener.onPointerDown 零延迟选中 + zebra / 选中底色;
  /// [showMarker] 时在行首画 ▶ 标记当前行(与表头预留列同宽)
  Widget _rowWrap(AppPalette t, int index,
      {required bool selected,
      required VoidCallback onTap,
      required Widget child,
      bool showMarker = true}) {
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
        child: Row(
          children: [
            SizedBox(
              width: showMarker ? _rowMarkerWidth : 0,
              child: showMarker && selected
                  ? Icon(Icons.arrow_right, size: 16, color: t.foreground)
                  : null,
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }

  /// 底部属性面板:每行一个属性(标签列 + 控件列),超高时面板内滚动;
  /// model 为空(无选中行)时整个面板隐藏。
  Widget _props<T>(
    AppPalette t,
    T? model,
    List<Widget> Function(T) builder, {
    String? hint,
  }) {
    if (model == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 232),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.border)),
        color: t.surface,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final w in builder(model)) w,
            if (hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  hint,
                  style: TextStyle(fontSize: 11.5, color: t.disabledForeground),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 属性字段:左侧标签(固定宽 180)+ 右侧控件(固定宽 360),单行高 30
  Widget _propField(AppPalette t, String label, Widget child) {
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          SizedBox(
            width: 180,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: t.mutedForeground),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          SizedBox(width: 360, child: child),
        ],
      ),
    );
  }

  // ── 通用控件 ──────────────────────────────────────────────

  /// 绑定字符串字段的输入框:自持控制器、变更即时写回模型,外部值变化时同步。
  ///
  /// 只读降级在本方法统一门控:字段网格里几十处文本格共用此入口,
  /// 逐个传参会漏改且淹没真正的差异。
  Widget _modelInput(
    String value,
    ValueChanged<String> onChanged, {
    String? hint,
    bool enabled = true,
    double? width,
    TextAlign? textAlign,
    TextInputType? keyboardType,
  }) {
    final input = _ModelInput(
      value: value,
      enabled: enabled && !_readOnly,
      hint: hint,
      textAlign: textAlign,
      keyboardType: keyboardType,
      onChanged: (v) {
        onChanged(v);
        // 触发父级重建,使「SQL 预览」与校验状态实时刷新(预览即所见)
        setState(() {});
      },
    );
    return width == null ? input : SizedBox(width: width, child: input);
  }

  /// 候选下拉(仍可手输):候选为空时行为等同输入框。
  ///
  /// 与选项页局部的 `combo` 同构,供各属性面板复用;只读降级统一在此收口。
  Widget _candidateCombo(
          List<String> items, String value, ValueChanged<String> onChanged,
          String hint,
          {bool enabled = true}) =>
      ComboBox<String>(
        items: items,
        value: value.isEmpty ? null : value,
        editable: true,
        enabled: enabled && !_readOnly,
        hint: hint,
        onChanged: (v) => setState(() => onChanged(v ?? '')),
      );

  /// 灰色占位输入(正在缓冲 / 快速更新 等暂未支持项)
  Widget get _disabledInput => _ModelInput(value: '', onChanged: (_) {}, enabled: false, hint: '—');

  /// 只读展示输入(值由其它标签推导,不开放编辑)
  Widget _readonlyInput(String value) =>
      _ModelInput(value: value, onChanged: (_) {}, enabled: false, hint: '—');

  /// 单元格右侧的 `...` 按钮(打开选择弹窗);onTap 为 null 时置灰
  Widget _dotsButton({required VoidCallback? onTap, String? tooltip}) => IconBtn(
        child: const Text(
          '...',
          style: TextStyle(fontSize: 13, height: 1.0, fontWeight: FontWeight.w600),
        ),
        size: const Size(24, 26),
        outline: true,
        tooltip: tooltip,
        onTap: onTap,
      );

  /// YES / NO 下拉(空 = 不生成子句)
  Widget _yesNoCombo(String value, ValueChanged<String> onChanged, {bool enabled = true}) {
    return ComboBox<String>(
      items: _yesNo,
      value: value,
      enabled: enabled && !_readOnly,
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

  /// 显式设置 / 取消当前行的主键(供「主键 ▾」下拉;
  /// 序号由 [DdlBuilder.pkOrdinals] 按列序推导,无需手工维护)
  void _setPk(bool on) {
    setState(() {
      if (_selColumn < 0 || _selColumn >= _design.columns.length) return;
      _design.columns[_selColumn].primaryKey = on;
    });
  }

  /// 切换指定行的主键(「键」列点击,零延迟)
  void _togglePkAt(int index) {
    setState(() {
      if (index < 0 || index >= _design.columns.length) return;
      final c = _design.columns[index];
      c.primaryKey = !c.primaryKey;
      _selColumn = index;
    });
  }

  /// 设置 / 清除列的 IDENTITY(虚拟类型);
  /// 开启时预填截图同款序列默认值,并自动勾选「不是 null」
  void _applyIdentity(DesignColumn c, String mode) {
    if (mode.isEmpty) {
      c.identityMode = '';
      c.identityIncrement = '';
      c.identityMinValue = '';
      c.identityMaxValue = '';
      c.identityStart = '';
      c.identityCache = '';
      c.identityCycle = false;
      return;
    }
    c.identityMode = mode;
    if (c.identityIncrement.isEmpty) c.identityIncrement = '1';
    if (c.identityMinValue.isEmpty) c.identityMinValue = '1';
    if (c.identityMaxValue.isEmpty) c.identityMaxValue = kIdentityMaxValue(c.type);
    if (c.identityStart.isEmpty) c.identityStart = '1';
    if (c.identityCache.isEmpty) c.identityCache = '1';
    c.notNull = true;
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
    this.textAlign,
    this.keyboardType,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool enabled;

  /// 数字属性右对齐用
  final TextAlign? textAlign;
  final TextInputType? keyboardType;

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
      textAlign: widget.textAlign,
      keyboardType: widget.keyboardType,
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
