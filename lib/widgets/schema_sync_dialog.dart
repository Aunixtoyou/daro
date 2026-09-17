import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../app/connection_manager.dart';
import '../data/db_data.dart';
import '../data/drivers/db_driver.dart';
import '../data/schema_sync.dart';
import '../theme/app_theme.dart';

/// 打开「工具 → 结构同步」弹窗。
///
/// [AppState] 提供连接列表与元数据缓存;弹窗自带专用会话比对 / 部署
/// (见 schema_sync.dart 的 [compareSchemaSync] / [deploySchemaSync]),
/// 不复用连接树长连接。[driverFactory] 仅供测试注入假驱动,生产留空走默认工厂。
Future<void> showSchemaSyncDialog(
  BuildContext context, {
  required AppState app,
  @visibleForTesting SyncDriverFactory? driverFactory,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => SchemaSyncDialog(app: app, driverFactory: driverFactory),
  );
}

/// 「结构同步」:比对源 / 目标两侧的库(或模式),把选中的差异部署到目标。
///
/// 布局自上而下:①源 / 目标端点(连接 + 库 + 可选模式 + 服务器版本)②「选项 / 比较 /
/// 进度」③左侧差异分组树(要修改 / 要新建 / 要删除)配右侧「DDL 比较 + 将执行语句」。
/// 底部汇总勾选数并给出「部署」。所有控件走 base-ui,取色走 [Tokens] 明暗自适应。
class SchemaSyncDialog extends StatefulWidget {
  const SchemaSyncDialog({
    super.key,
    required this.app,
    @visibleForTesting this.driverFactory,
  });

  final AppState app;

  /// 比对 / 部署用的驱动工厂;仅供测试注入假驱动,生产为 null 走默认工厂。
  final SyncDriverFactory? driverFactory;

  @override
  State<SchemaSyncDialog> createState() => _SchemaSyncDialogState();
}

class _SchemaSyncDialogState extends State<SchemaSyncDialog> {
  // ── 端点选择 ──────────────────────────────────────────────
  ConnectionInfo? _srcConn;
  ConnectionInfo? _tgtConn;
  String? _srcDb;
  String? _tgtDb;
  String? _srcSchema;
  String? _tgtSchema;
  String? _srcVersion;
  String? _tgtVersion;

  // ── 比对 / 部署状态 ────────────────────────────────────────
  final SyncOptions _options = SyncOptions();
  SyncPlan? _plan;
  SyncObject? _focused; // 右侧 DDL 比较聚焦的对象
  bool _comparing = false;
  bool _deploying = false;
  String _stage = '';
  int _done = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    // 库 / 模式列表由 ConnectionManager 异步加载,完成时重建下拉框。
    widget.app.connectionManager.addListener(_onMetadataChanged);
    // 仅预填源侧连接名(采纳决策:不预选库 / 模式,避免误同步)。
    final selConnName = widget.app.detailSelection.value?.connection;
    if (selConnName != null) {
      final conn = widget.app.connectionByName(selConnName);
      if (conn != null && structureSyncUnsupported(conn) == null) {
        _srcConn = conn;
        _loadDatabases(conn);
      }
    }
  }

  @override
  void dispose() {
    widget.app.connectionManager.removeListener(_onMetadataChanged);
    super.dispose();
  }

  void _onMetadataChanged() {
    if (mounted) setState(() {});
  }

  // ── 端点辅助 ──────────────────────────────────────────────

  /// 可参与同步的连接(真实连接 + 有驱动 + 非文件型)。
  List<ConnectionInfo> get _eligibleConnections =>
      widget.app.connections.where((c) => structureSyncUnsupported(c) == null).toList();

  /// 目标侧再按源类型过滤:结构同步不支持跨类型。
  List<ConnectionInfo> get _targetConnections {
    final all = _eligibleConnections;
    final src = _srcConn;
    if (src == null) return all;
    return all.where((c) => c.typeId == src.typeId).toList();
  }

  SyncEndpoint _endpointOf({
    required ConnectionInfo conn,
    required String? database,
    required String? schema,
  }) =>
      SyncEndpoint(
        connection: conn,
        database: database ?? '',
        schema: kSchemaLayerTypes.contains(conn.typeId) ? schema : null,
      );

  bool _hasSchemaLayer(ConnectionInfo? conn) =>
      conn != null && kSchemaLayerTypes.contains(conn.typeId);

  bool get _sourceReady => _srcConn != null && (_srcDb?.isNotEmpty ?? false);
  bool get _targetReady => _tgtConn != null && (_tgtDb?.isNotEmpty ?? false);

  // 仅在 [_sourceReady] / [_targetReady] 为真(连接已选定)时被调用,故 ! 安全。
  SyncEndpoint get _source => _endpointOf(
      conn: _srcConn!, database: _srcDb, schema: _srcSchema);
  SyncEndpoint get _target => _endpointOf(
      conn: _tgtConn!, database: _tgtDb, schema: _tgtSchema);

  bool get _canCompare =>
      !_comparing && !_deploying && _sourceReady && _targetReady;

  Future<void> _loadDatabases(ConnectionInfo conn) =>
      widget.app.connectionManager.expandConnection(conn);

  void _onSourceChanged(ConnectionInfo? conn) {
    setState(() {
      _srcConn = conn;
      _srcDb = null;
      _srcSchema = null;
      _srcVersion = null;
      _plan = null;
      _focused = null;
      // 目标若类型不再匹配源,清空目标选择。
      if (conn != null && _tgtConn != null && _tgtConn!.typeId != conn.typeId) {
        _tgtConn = null;
        _tgtDb = null;
        _tgtSchema = null;
        _tgtVersion = null;
      }
    });
    if (conn != null) {
      _loadDatabases(conn);
      _readVersion(source: true);
    }
  }

  void _onTargetChanged(ConnectionInfo? conn) {
    setState(() {
      _tgtConn = conn;
      _tgtDb = null;
      _tgtSchema = null;
      _tgtVersion = null;
      _plan = null;
      _focused = null;
    });
    if (conn != null) {
      _loadDatabases(conn);
      _readVersion(source: false);
    }
  }

  void _onDatabaseChanged({required bool source, String? db}) {
    setState(() {
      if (source) {
        _srcDb = db;
        _srcSchema = null;
      } else {
        _tgtDb = db;
        _tgtSchema = null;
      }
      _plan = null;
      _focused = null;
    });
    final conn = source ? _srcConn : _tgtConn;
    if (conn != null && db != null && _hasSchemaLayer(conn)) {
      widget.app.connectionManager.ensureSchemas(conn, db);
    }
    _readVersion(source: source);
  }

  Future<void> _readVersion({required bool source}) async {
    final conn = source ? _srcConn : _tgtConn;
    final db = source ? _srcDb : _tgtDb;
    if (conn == null || db == null || db.isEmpty) return;
    final v = await readServerVersion(widget.app.connectionManager, conn,
        database: db);
    if (!mounted) return;
    setState(() {
      if (source) {
        _srcVersion = v;
      } else {
        _tgtVersion = v;
      }
    });
  }

  // ── 比对 / 部署 ────────────────────────────────────────────

  Future<void> _compare() async {
    if (!_canCompare) return;
    setState(() {
      _comparing = true;
      _plan = null;
      _focused = null;
      _stage = '准备比对 ...';
      _done = 0;
      _total = 0;
    });
    final plan = await compareSchemaSync(
      source: _source,
      target: _target,
      options: _options,
      driverFactory: widget.driverFactory,
      onProgress: (stage, done, total) {
        if (!mounted) return;
        setState(() {
          _stage = stage;
          _done = done;
          _total = total;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _comparing = false;
      _plan = plan;
      _stage = '';
    });
    if (plan.errors.isNotEmpty) {
      MessageBox.show(
        context,
        title: '比对未完成',
        message: plan.errors.join('\n'),
        type: MessageBoxType.warning,
        okText: '知道了',
        tokens: Tokens.read(context).toDesktopTokens(),
      );
    }
  }

  Future<void> _openOptions() async {
    final updated = await showSchemaSyncOptionsDialog(context, current: _options);
    if (updated == null || !mounted) return;
    setState(() {
      _options
        ..tables = updated.tables
        ..views = updated.views
        ..functions = updated.functions
        ..procedures = updated.procedures
        ..ignoreComments = updated.ignoreComments
        ..stripDefiner = updated.stripDefiner
        ..ignoreDefinitionSpace = updated.ignoreDefinitionSpace;
      // 选项变了,旧比对结果作废,强制重新比较。
      _plan = null;
      _focused = null;
    });
  }

  List<SyncObject> _changedOf(SyncAction action) {
    final plan = _plan;
    if (plan == null) return const [];
    return plan.objects.where((o) => o.action == action).toList();
  }

  int get _selectedCount => _plan?.selected.length ?? 0;
  int get _changedCount =>
      _plan?.objects.where((o) => o.changed).length ?? 0;
  int get _dropCount => _changedOf(SyncAction.drop).where((o) => o.deployable).length;

  Future<void> _deploy() async {
    final plan = _plan;
    if (plan == null) return;
    final selected = plan.selected;
    if (selected.isEmpty) return;

    final t = Tokens.read(context);
    // 执行前最终确认:汇总对象数、含删除时高亮警示、可预览将执行的 SQL。
    final confirm = await MessageBox.show(
      context,
      title: '确认部署',
      type: MessageBoxType.warning,
      buttons: MessageBoxButtons.yesNo,
      yesText: '执行部署',
      noText: '取消',
      tokens: t.toDesktopTokens(),
      content: _DeployPreview(plan: plan, script: plan.deployScript()),
    );
    if (confirm != MessageBoxResult.yes || !mounted) return;

    setState(() {
      _deploying = true;
      _stage = '部署中 ...';
      _done = 0;
      _total = selected.length;
    });
    final report = await deploySchemaSync(
      target: _target,
      selected: selected,
      onItemDone: (_) {
        if (!mounted) return;
        setState(() => _done++);
      },
    );
    if (!mounted) return;
    setState(() {
      _deploying = false;
      _stage = '';
    });

    await MessageBox.show(
      context,
      title: '部署结果',
      message: report.allOk
          ? '全部成功:已部署 ${report.successCount} 个对象。'
          : '完成:成功 ${report.successCount} 个,失败 ${report.failureCount} 个。\n\n'
              '${_failureText(report)}',
      type: report.allOk ? MessageBoxType.info : MessageBoxType.error,
      okText: '知道了',
      tokens: t.toDesktopTokens(),
    );

    // 部署后重新比对,让差异表反映目标最新结构。
    if (report.successCount > 0 && mounted) {
      await _compare();
    }
  }

  String _failureText(DeployReport report) {
    final failed = report.items.where((e) => !e.ok).toList();
    return failed
        .map((e) => '· ${e.object.name}:${e.error}')
        .join('\n');
  }

  // ── 构建 ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return DialogBox(
      title: '结构同步',
      width: 1040,
      height: 700,
      onClose: () => Navigator.of(context).pop(),
      footer: _footer(t),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _endpointRow(t),
            const SizedBox(height: 10),
            _toolbar(t),
            const SizedBox(height: 10),
            Expanded(child: _resultArea(t)),
          ],
        ),
      ),
    );
  }

  // ① 源 / 目标端点
  Widget _endpointRow(AppPalette t) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _endpointCard(
            t,
            title: '源(结构来源)',
            conn: _srcConn,
            onConn: _onSourceChanged,
            database: _srcDb,
            onDatabase: (v) => _onDatabaseChanged(source: true, db: v),
            schema: _srcSchema,
            onSchema: (v) => setState(() {
              _srcSchema = v;
              _plan = null;
              _focused = null;
            }),
            connections: _eligibleConnections,
            version: _srcVersion,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _endpointCard(
            t,
            title: '目标(部署到)',
            conn: _tgtConn,
            onConn: _onTargetChanged,
            database: _tgtDb,
            onDatabase: (v) => _onDatabaseChanged(source: false, db: v),
            schema: _tgtSchema,
            onSchema: (v) => setState(() {
              _tgtSchema = v;
              _plan = null;
              _focused = null;
            }),
            connections: _targetConnections,
            version: _tgtVersion,
          ),
        ),
      ],
    );
  }

  Widget _endpointCard(
    AppPalette t, {
    required String title,
    required ConnectionInfo? conn,
    required ValueChanged<ConnectionInfo?> onConn,
    required String? database,
    required ValueChanged<String?> onDatabase,
    required String? schema,
    required ValueChanged<String?> onSchema,
    required List<ConnectionInfo> connections,
    required String? version,
  }) {
    final cm = widget.app.connectionManager;
    final dbState =
        conn == null ? null : cm.databaseStateOf(conn.name);
    final dbItems = dbState?.databases ?? const <String>[];
    final dbLoading = dbState?.status == LoadStatus.loading;
    final schemaState =
        (conn != null && database != null && _hasSchemaLayer(conn))
            ? cm.schemaStateOf(conn.name, database)
            : null;
    final schemaItems = schemaState?.schemas ?? const <String>[];
    final showSchema = _hasSchemaLayer(conn) && database != null;

    return GroupBox(
      title: title,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FieldRow(
            label: '连接:',
            labelWidth: 44,
            child: ComboBox<ConnectionInfo>(
              items: connections,
              value: conn,
              hint: connections.isEmpty ? '无可用连接' : '选择连接',
              itemToString: (c) => c.name,
              onChanged: onConn,
            ),
          ),
          const SizedBox(height: 6),
          FieldRow(
            label: '数据库:',
            labelWidth: 44,
            child: ComboBox<String>(
              items: dbItems,
              value: database,
              enabled: conn != null && !dbLoading,
              hint: conn == null
                  ? '先选连接'
                  : (dbLoading ? '加载中 ...' : '选择数据库'),
              onChanged: onDatabase,
            ),
          ),
          if (showSchema) ...[
            const SizedBox(height: 6),
            FieldRow(
              label: '模式:',
              labelWidth: 44,
              child: ComboBox<String>(
                items: schemaItems,
                value: schema,
                enabled: schemaItems.isNotEmpty,
                hint: schemaItems.isEmpty ? '无模式 / 默认' : '选择模式',
                onChanged: onSchema,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            version == null || version.isEmpty
                ? '服务器版本:--'
                : '服务器版本:$version',
            style: TextStyle(color: t.mutedForeground, fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  // ② 工具条:选项 / 比较 / 进度
  Widget _toolbar(AppPalette t) {
    return Row(
      children: [
        Button(text: '选项...', onPressed: _openOptions),
        const SizedBox(width: 8),
        Button(
          text: _comparing ? '比对中...' : '比较',
          onPressed: _canCompare ? _compare : null,
        ),
        const SizedBox(width: 12),
        if (_comparing || _deploying) ...[
          SizedBox(
            width: 220,
            child: ProgressBar(
              value: _total > 0 ? _done.toDouble() : 0,
              max: _total > 0 ? _total.toDouble() : 1,
              style: _total > 0 ? ProgressBarStyle.determinate : ProgressBarStyle.marquee,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _stage,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.mutedForeground, fontSize: 12),
            ),
          ),
        ] else
          Expanded(
            child: Text(
              _summary(t),
              style: TextStyle(color: t.mutedForeground, fontSize: 12),
            ),
          ),
      ],
    );
  }

  String _summary(AppPalette t) {
    final plan = _plan;
    if (plan == null) return '选择源与目标后点击「比较」。';
    if (plan.errors.isNotEmpty) return '比对存在 ${plan.errors.length} 处错误,结果可能不完整。';
    if (_changedCount == 0) return '两侧结构一致,无需同步。';
    return '共 $_changedCount 处差异,已勾选 $_selectedCount 项待部署'
        '${_dropCount > 0 ? '（含删除 $_dropCount,默认不勾选）' : ''}。';
  }

  // ③ 结果区:左差异分组树 | 右 DDL 比较
  Widget _resultArea(AppPalette t) {
    if (_plan == null) {
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: t.surface,
          border: Border.all(color: t.border),
        ),
        child: Text(
          _comparing ? '正在比对结构 ...' : '尚未比较',
          style: TextStyle(color: t.mutedForeground, fontSize: 13),
        ),
      );
    }
    return SplitContainer(
      initialRatio: 0.46,
      minFirst: 300,
      minSecond: 360,
      first: _diffList(t),
      second: _ddlPane(t),
    );
  }

  Widget _diffList(AppPalette t) {
    final sections = <Widget>[];
    for (final action in const [
      SyncAction.alter,
      SyncAction.create,
      SyncAction.drop,
    ]) {
      final objs = _changedOf(action);
      if (objs.isEmpty) continue;
      sections.add(_groupHeader(t, action, objs));
      for (final o in objs) {
        sections.add(_objectRow(t, o));
      }
    }
    if (sections.isEmpty) {
      // 三类差异都为空:结构一致
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: t.surface,
          border: Border.all(color: t.border),
        ),
        child: Text('无差异。', style: TextStyle(color: t.mutedForeground, fontSize: 13)),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.border),
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: sections,
      ),
    );
  }

  Widget _groupHeader(AppPalette t, SyncAction action, List<SyncObject> objs) {
    final deployable = objs.where((o) => o.selectable).toList();
    final allChecked =
        deployable.isNotEmpty && deployable.every((o) => o.selected);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
      child: Row(
        children: [
          CheckBox(
            value: allChecked,
            enabled: deployable.isNotEmpty,
            onChanged: deployable.isEmpty
                ? null
                : (v) => setState(() {
                      for (final o in deployable) {
                        o.checked = v ?? false;
                      }
                    }),
            label: '${action.groupLabel}（${objs.length}）',
          ),
        ],
      ),
    );
  }

  Widget _objectRow(AppPalette t, SyncObject o) {
    final focused = identical(_focused, o);
    final warn = o.blocked;
    return Listener(
      onPointerDown: (_) => setState(() => _focused = o),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: 26,
          color: focused ? t.treeSelectedBg : Colors.transparent,
          padding: const EdgeInsets.only(left: 22),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                child: o.selectable
                    ? CheckBox(
                        value: o.selected,
                        onChanged: (v) => setState(() => o.checked = v ?? false),
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: 6),
              Text(
                o.kind.label,
                style: TextStyle(
                  color: t.mutedForeground,
                  fontSize: 11,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  o.name + (o.note != null ? '  · ${o.note}' : ''),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: warn ? AppColors.of(context).iconWarning : t.foreground,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ddlPane(AppPalette t) {
    final o = _focused;
    if (o == null) {
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: t.surface,
          border: Border.all(color: t.border),
        ),
        child: Text(
          '从左侧选择一个对象查看 DDL 比较。',
          style: TextStyle(color: t.mutedForeground, fontSize: 12.5),
        ),
      );
    }
    return SplitContainer(
      orientation: Axis.vertical,
      initialRatio: 0.6,
      minFirst: 120,
      minSecond: 90,
      first: SplitContainer(
        initialRatio: 0.5,
        minFirst: 120,
        minSecond: 120,
        first: _monoCard(t, '源 · ${o.name}', o.sourceDdl, '（目标不存在,将新建）'),
        second: _monoCard(t, '目标 · ${o.name}', o.targetDdl, '（源不存在,将删除）'),
      ),
      second: _monoCard(
        t,
        '将执行的语句（${o.statements.length}）',
        o.statements.isEmpty ? '（无语句 / 不可部署）' : o.statements.join(';\n') + ';',
        null,
      ),
    );
  }

  Widget _monoCard(AppPalette t, String title, String body, String? emptyHint) {
    final showEmpty = body.trim().isEmpty && emptyHint != null;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: t.secondary,
            child: Text(
              title,
              style: TextStyle(
                color: t.mutedForeground,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: Text(
                showEmpty ? emptyHint : body,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontFamilyFallback: const ['monospace'],
                  fontSize: 12,
                  height: 1.4,
                  color: showEmpty ? t.mutedForeground : t.foreground,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(AppPalette t) {
    final selected = _selectedCount;
    return Row(
      children: [
        Text(
          _footerHint(t),
          style: TextStyle(
            color: selected > 0 ? t.foreground : t.mutedForeground,
            fontSize: 12,
          ),
        ),
        const Spacer(),
        Button(
          text: '关闭',
          onPressed:
              (_comparing || _deploying) ? null : () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 8),
        Button(
          text: _deploying ? '部署中...' : '部署到目标',
          onPressed: (_plan == null || selected == 0 || _comparing || _deploying)
              ? null
              : _deploy,
        ),
      ],
    );
  }

  String _footerHint(AppPalette t) {
    if (_plan == null) return '尚未比较';
    if (_changedCount == 0) return '两侧结构一致';
    return '勾选 $_selectedCount / 共 $_changedCount 处差异待部署'
        '${_dropCount > 0 ? '（其中删除 $_dropCount 项）' : ''}';
  }
}

/// 部署确认框里的「将执行 SQL」预览(含删除高亮)。
class _DeployPreview extends StatelessWidget {
  const _DeployPreview({required this.plan, required this.script});

  final SyncPlan plan;
  final String script;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final dropCount =
        plan.selected.where((o) => o.action == SyncAction.drop).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '将在目标库执行 ${plan.selected.length} 个对象的变更。',
          style: TextStyle(
            color: t.foreground,
            fontSize: 12.5,
            decoration: TextDecoration.none,
          ),
        ),
        if (dropCount > 0) ...[
          const SizedBox(height: 6),
          Text(
            '注意:其中包含 $dropCount 项「删除」,会移除目标库多余对象,不可撤销。',
            style: TextStyle(
              color: AppColors.of(context).iconWarning,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
        ],
        const SizedBox(height: 8),
        Container(
          width: 520,
          constraints: const BoxConstraints(maxHeight: 260),
          decoration: BoxDecoration(
            color: t.surface,
            border: Border.all(color: t.border),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Text(
              script.isEmpty ? '（无）' : script,
              style: TextStyle(
                fontFamily: 'Consolas',
                fontFamilyFallback: const ['monospace'],
                fontSize: 12,
                height: 1.4,
                color: t.foreground,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 打开「选项」弹窗,返回用户确认后的 [SyncOptions];取消返回 null。
Future<SyncOptions?> showSchemaSyncOptionsDialog(
  BuildContext context, {
  required SyncOptions current,
}) {
  return showDialog<SyncOptions>(
    context: context,
    builder: (_) => SchemaSyncOptionsDialog(initial: current.copy()),
  );
}

/// 「结构同步 → 选项」:对象类别开关 + 比对策略开关。
class SchemaSyncOptionsDialog extends StatefulWidget {
  const SchemaSyncOptionsDialog({super.key, required this.initial});

  final SyncOptions initial;

  @override
  State<SchemaSyncOptionsDialog> createState() => _SchemaSyncOptionsDialogState();
}

class _SchemaSyncOptionsDialogState extends State<SchemaSyncOptionsDialog> {
  late final SyncOptions _opt = widget.initial;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return DialogBox(
      title: '结构同步选项',
      width: 380,
      onClose: () => Navigator.of(context).pop(),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Button(text: '取消', onPressed: () => Navigator.of(context).pop()),
          const SizedBox(width: 8),
          Button(
            text: '确定',
            onPressed: () => Navigator.of(context).pop(_opt),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel(t, '同步对象'),
            _check('表', () => _opt.tables, (v) => _opt.tables = v),
            _check('视图', () => _opt.views, (v) => _opt.views = v),
            _check('函数', () => _opt.functions, (v) => _opt.functions = v),
            _check('过程', () => _opt.procedures, (v) => _opt.procedures = v),
            const SizedBox(height: 14),
            _sectionLabel(t, '比对策略'),
            _check(
              '忽略注释差异',
              () => _opt.ignoreComments,
              (v) => _opt.ignoreComments = v,
            ),
            _check(
              '去掉 MySQL 定义中的 DEFINER 子句',
              () => _opt.stripDefiner,
              (v) => _opt.stripDefiner = v,
            ),
            _check(
              '定义比较忽略空白差异',
              () => _opt.ignoreDefinitionSpace,
              (v) => _opt.ignoreDefinitionSpace = v,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(AppPalette t, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            color: t.mutedForeground,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.none,
          ),
        ),
      );

  Widget _check(String label, bool Function() get, void Function(bool) set) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: CheckBox(
        value: get(),
        label: label,
        onChanged: (v) => setState(() => set(v ?? false)),
      ),
    );
  }
}
