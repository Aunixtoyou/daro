import 'dart:convert';
import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../app/connection_manager.dart';
import '../data/db_data.dart';
import '../data/db_types.dart';
import '../data/drivers/db_driver.dart';
import '../data/schema_sync.dart';
import '../theme/app_theme.dart';
import 'object_category_icon.dart';

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

/// 向导步骤:①源/目标设置 → ②差异审查 → ③部署(脚本 / 消息日志)。
enum _Step { setup, review, script }

// 差异表的动作着色(功能强调色,主题无关,与参考工具一致):
// 修改=蓝、新建=绿、删除=红、无操作=灰。
const Color kSyncAlterColor = Color(0xff2f6fed);
const Color kSyncCreateColor = Color(0xff22b573);
const Color kSyncDropColor = Color(0xffd2343f);
const Color kSyncNoneColor = Color(0xff98a1ab);

/// 差异表分组方式(左上角下拉)。
const String kGroupByAction = '按操作分组';
const String kGroupByKind = '按对象类型分组';

/// 「结构同步」向导:比对源 / 目标两侧的库(或模式),把选中的差异部署到目标。
///
/// 界面为三步向导(参照主流工具的同步流程):
/// ①设置页:顶部「源 → 目标」端点摘要横幅 + 两列端点选择(连接 / 数据库 / 模式,
///   中间「⇅」交换)+ 两侧「信息」面板;底部「保存 / 加载配置文件 … 选项 / 比较」。
/// ②差异页:同一横幅 + 「按操作分组」下拉 + 三列差异表(源对象 | 操作 | 目标对象,
///   分组标题带勾选与展开),底部「DDL 比较 / 部署脚本」标签页;
///   比较时以覆盖层显示进度并可取消。
/// ③部署页:「部署脚本 / 消息日志」标签页,脚本区带目标服务器说明与复制按钮,
///   日志区统计进度 / 成功 / 错误 / 时间并逐对象记录执行明细;底部「开始」执行部署。
/// 所有控件走 base-ui,取色走 [Tokens] 明暗自适应。
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
  // ── 向导步骤 / 界面状态 ────────────────────────────────────
  _Step _step = _Step.setup;
  String _groupBy = kGroupByAction;
  final Set<String> _collapsedGroups = {};
  int _reviewTab = 0; // 差异页底部:0=DDL 比较,1=部署脚本
  int _scriptTab = 0; // 部署页:0=部署脚本,1=消息日志

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
  SyncObject? _focused; // 差异表中聚焦的对象(DDL 比较显示它)
  bool _comparing = false;
  bool _deploying = false;
  bool _cancelCompare = false;
  String _stage = '';
  int _done = 0;
  int _total = 0;

  // ── 部署选项 / 消息日志 ────────────────────────────────────
  bool _stopOnError = false;
  bool _recompareAfterDeploy = true;
  final List<String> _logLines = [];
  int _deployTotal = 0;
  int _deploySuccess = 0;
  int _deployFailed = 0;
  final Stopwatch _deployWatch = Stopwatch();
  final ScrollController _logScroll = ScrollController();
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    // 库 / 模式列表由 ConnectionManager 异步加载,完成时重建下拉框。
    widget.app.connectionManager.addListener(_onMetadataChanged);
    // 仅预填源侧连接名(不预选库 / 模式,避免误同步)。
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
    _logScroll.dispose();
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

  // ── 两侧交换 ──────────────────────────────────────────────

  /// 交换源 / 目标的全部端点选择(连接 / 库 / 模式 / 版本)。
  /// 两侧类型必然同源(目标列表按源过滤),交换后类型约束仍成立。
  void _swapSides() {
    if (_comparing || _deploying) return;
    setState(() {
      final c = _srcConn;
      _srcConn = _tgtConn;
      _tgtConn = c;
      final d = _srcDb;
      _srcDb = _tgtDb;
      _tgtDb = d;
      final s = _srcSchema;
      _srcSchema = _tgtSchema;
      _tgtSchema = s;
      final v = _srcVersion;
      _srcVersion = _tgtVersion;
      _tgtVersion = v;
      _plan = null;
      _focused = null;
    });
    if (_srcConn != null) _loadDatabases(_srcConn!);
    if (_tgtConn != null) _loadDatabases(_tgtConn!);
    _readVersion(source: true);
    _readVersion(source: false);
  }

  // ── 配置文件 保存 / 加载(JSON) ───────────────────────────
  static const _configTypeGroups = [
    XTypeGroup(
        label: '结构同步配置 (JSON)',
        extensions: ['json'],
        mimeTypes: ['application/json']),
  ];

  Map<String, dynamic> _configJson() => {
        'version': 1,
        'source': _endpointJson(
            conn: _srcConn, database: _srcDb, schema: _srcSchema),
        'target': _endpointJson(
            conn: _tgtConn, database: _tgtDb, schema: _tgtSchema),
        'options': {
          'tables': _options.tables,
          'views': _options.views,
          'functions': _options.functions,
          'procedures': _options.procedures,
          'ignoreComments': _options.ignoreComments,
          'stripDefiner': _options.stripDefiner,
          'ignoreDefinitionSpace': _options.ignoreDefinitionSpace,
        },
      };

  Map<String, dynamic> _endpointJson({
    required ConnectionInfo? conn,
    required String? database,
    required String? schema,
  }) =>
      {
        'connection': conn?.name,
        'typeId': conn?.typeId,
        'database': database,
        'schema': schema,
      };

  Future<void> _saveConfig() async {
    final t = Tokens.read(context);
    final location = await getSaveLocation(
      acceptedTypeGroups: _configTypeGroups,
      suggestedName: 'schema_sync.json',
      confirmButtonText: '保存配置文件',
    );
    final path = location?.path;
    if (path == null || !mounted) return;
    try {
      await File(path)
          .writeAsString(const JsonEncoder.withIndent('  ').convert(_configJson()));
      if (mounted) {
        MessageBox.show(
          context,
          title: '已保存',
          message: '配置文件已保存到:\n$path',
          type: MessageBoxType.info,
          okText: '知道了',
          tokens: t.desktopTokensFor(context),
        );
      }
    } catch (e) {
      if (mounted) {
        MessageBox.show(
          context,
          title: '保存失败',
          message: '$e',
          type: MessageBoxType.error,
          okText: '知道了',
          tokens: t.desktopTokensFor(context),
        );
      }
    }
  }

  Future<void> _loadConfig() async {
    final t = Tokens.read(context);
    final file = await openFile(
      acceptedTypeGroups: _configTypeGroups,
      confirmButtonText: '加载配置文件',
    );
    if (file == null || !mounted) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) throw const FormatException('不是有效的配置对象');
      _applyConfig(Map<String, dynamic>.from(decoded));
    } catch (e) {
      if (mounted) {
        MessageBox.show(
          context,
          title: '加载失败',
          message: '无法解析配置文件:$e',
          type: MessageBoxType.error,
          okText: '知道了',
          tokens: t.desktopTokensFor(context),
        );
      }
    }
  }

  /// 把配置 JSON 应用到当前选择:连接按名称匹配可用连接,库 / 模式直接回填
  /// (其下拉列表随 ConnectionManager 异步加载,值先占位显示)。
  void _applyConfig(Map<String, dynamic> cfg) {
    ConnectionInfo? resolve(dynamic side) {
      if (side is! Map) return null;
      final name = side['connection'];
      if (name is! String) return null;
      final conn = widget.app.connectionByName(name);
      if (conn == null || structureSyncUnsupported(conn) != null) return null;
      return conn;
    }

    String? str(dynamic side, String key) {
      if (side is! Map) return null;
      final v = side[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final src = resolve(cfg['source']);
    final tgt = resolve(cfg['target']);
    final opt = cfg['options'];
    setState(() {
      _srcConn = src;
      _srcDb = str(cfg['source'], 'database');
      _srcSchema = str(cfg['source'], 'schema');
      _srcVersion = null;
      _tgtConn = tgt;
      _tgtDb = str(cfg['target'], 'database');
      _tgtSchema = str(cfg['target'], 'schema');
      _tgtVersion = null;
      _plan = null;
      _focused = null;
      // 配置属于端点选择,回到设置页。
      _step = _Step.setup;
      if (opt is Map) {
        _options
          ..tables = opt['tables'] ?? _options.tables
          ..views = opt['views'] ?? _options.views
          ..functions = opt['functions'] ?? _options.functions
          ..procedures = opt['procedures'] ?? _options.procedures
          ..ignoreComments =
              opt['ignoreComments'] ?? _options.ignoreComments
          ..stripDefiner = opt['stripDefiner'] ?? _options.stripDefiner
          ..ignoreDefinitionSpace = opt['ignoreDefinitionSpace'] ??
              _options.ignoreDefinitionSpace;
      }
    });
    if (src != null) {
      _loadDatabases(src);
      _readVersion(source: true);
    }
    if (tgt != null) {
      _loadDatabases(tgt);
      _readVersion(source: false);
    }
  }

  // ── 比对(带进度覆盖层与取消) ─────────────────────────────

  Future<void> _compare() async {
    if (!_canCompare) return;
    final prevPlan = _plan;
    final prevStep = _step;
    setState(() {
      _comparing = true;
      _cancelCompare = false;
      _stage = '正在获取对象列表 ...';
      _done = 0;
      _total = 0;
    });
    final plan = await compareSchemaSync(
      source: _source,
      target: _target,
      options: _options,
      driverFactory: widget.driverFactory,
      isCancelled: () => _cancelCompare,
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
    if (plan.canceled) {
      // 取消:丢弃半成品结果,回到比较前的页面与计划。
      setState(() {
        _comparing = false;
        _stage = '';
        _plan = prevPlan;
        _step = prevStep;
      });
      return;
    }
    setState(() {
      _comparing = false;
      _stage = '';
      _plan = plan;
      _focused = null;
      _collapsedGroups.clear();
      _reviewTab = 0;
      _step = _Step.review;
    });
    if (plan.errors.isNotEmpty) {
      MessageBox.show(
        context,
        title: '比对未完成',
        message: plan.errors.join('\n'),
        type: MessageBoxType.warning,
        okText: '知道了',
        tokens: Tokens.read(context).desktopTokensFor(context),
      );
    }
  }

  void _cancelComparison() {
    setState(() => _cancelCompare = true);
  }

  Future<void> _openOptions() async {
    final updated =
        await showSchemaSyncOptionsDialog(context, current: _options);
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
      // 选项变了,旧比对结果作废并回到设置页。
      _plan = null;
      _focused = null;
      _step = _Step.setup;
    });
  }

  // ── 部署 + 消息日志 ────────────────────────────────────────

  Future<void> _startDeploy() async {
    final plan = _plan;
    if (plan == null || _deploying) return;
    final selected = plan.selected;
    if (selected.isEmpty) return;

    final t = Tokens.read(context);
    // 仅当勾选包含「删除」时才二次确认(破坏性操作);其余直接执行。
    final hasDrop = selected.any((o) => o.action == SyncAction.drop);
    if (hasDrop) {
      final confirm = await MessageBox.show(
        context,
        title: '确认部署',
        type: MessageBoxType.warning,
        buttons: MessageBoxButtons.yesNo,
        yesText: '执行部署',
        noText: '取消',
        tokens: t.desktopTokensFor(context),
        content: _DeployPreview(plan: plan, script: plan.deployScript()),
      );
      if (confirm != MessageBoxResult.yes || !mounted) return;
    }

    setState(() {
      _deploying = true;
      _scriptTab = 1; // 切到「消息日志」看执行过程
      _deployTotal = selected.length;
      _deploySuccess = 0;
      _deployFailed = 0;
      _logLines
        ..clear()
        ..add('--Start--');
    });
    _deployWatch
      ..reset()
      ..start();
    var seq = 0;
    final report = await deploySchemaSync(
      target: _target,
      selected: selected,
      driverFactory: widget.driverFactory,
      stopOnError: _stopOnError,
      onItemDone: (item) {
        if (!mounted) return;
        setState(() {
          seq++;
          if (item.ok) {
            _deploySuccess++;
          } else {
            _deployFailed++;
          }
          _logLines.add('[$seq/$_deployTotal] '
              '${item.object.action.label} ${item.object.kind.label} '
              '${item.object.name}');
          _logLines.add('Query:');
          _logLines.addAll(item.object.statements.map((s) => '$s;'));
          _logLines.add('Result: ${item.ok ? 'OK' : 'ERROR: ${item.error}'}');
          _logLines.add('-' * 40);
        });
        _scrollLogToBottom();
      },
    );
    _deployWatch.stop();
    if (!mounted) return;
    setState(() {
      _deploying = false;
      _logLines.add('--End--');
    });

    if (report.successCount > 0 && _recompareAfterDeploy) {
      // 部署后重新比对,让差异表反映目标最新结构。
      await _compare();
      return;
    }
    if (!report.allOk) {
      await MessageBox.show(
        context,
        title: '部署结果',
        message: '完成:成功 ${report.successCount} 个,失败 ${report.failureCount} 个。\n\n'
            '${_failureText(report)}',
        type: MessageBoxType.error,
        okText: '知道了',
        tokens: t.desktopTokensFor(context),
      );
    }
  }

  void _scrollLogToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  String _failureText(DeployReport report) {
    final failed = report.items.where((e) => !e.ok).toList();
    return failed.map((e) => '· ${e.object.name}:${e.error}').join('\n');
  }

  Future<void> _copyScript() async {
    final script = _plan?.deployScript() ?? '';
    if (script.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: script));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  static String _fmtElapsed(Duration d) {
    final mm = d.inMinutes.toString().padLeft(2, '0');
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    final cs = (d.inMilliseconds % 1000 ~/ 10).toString().padLeft(2, '0');
    return '$mm:$ss.$cs';
  }

  // ── 构建 ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return DialogBox(
      title: '结构同步',
      width: 1120,
      height: 760,
      onClose: () => Navigator.of(context).pop(),
      footer: _footer(t),
      child: Stack(
        children: [
          Positioned.fill(
            child: switch (_step) {
              _Step.setup => _setupPage(t),
              _Step.review => _reviewPage(t),
              _Step.script => _scriptPage(t),
            },
          ),
          if (_comparing) Positioned.fill(child: _compareOverlay(t)),
        ],
      ),
    );
  }

  // ── ① 设置页 ──────────────────────────────────────────────

  Widget _setupPage(AppPalette t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _banner(t),
        Container(height: 1, color: t.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _endpointColumn(t, source: true)),
              _swapButton(t),
              Expanded(child: _endpointColumn(t, source: false)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _infoColumn(t, source: true)),
              Container(width: 1, color: t.border),
              Expanded(child: _infoColumn(t, source: false)),
            ],
          ),
        ),
        const Expanded(child: SizedBox.shrink()),
      ],
    );
  }

  // 顶部「源 → 目标」端点摘要横幅(三个页面共用)
  Widget _banner(AppPalette t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _bannerSide(t, conn: _srcConn, db: _srcDb, schema: _srcSchema),
          const SizedBox(width: 18),
          const UiIcon(kDatabaseIcon, size: 28),
          const SizedBox(width: 14),
          Text(
            '→',
            style: TextStyle(
              color: t.mutedForeground,
              fontSize: 20,
              height: 1.0,
            ),
          ),
          const SizedBox(width: 14),
          const UiIcon(kDatabaseIcon, size: 28),
          const SizedBox(width: 18),
          _bannerSide(t, conn: _tgtConn, db: _tgtDb, schema: _tgtSchema),
        ],
      ),
    );
  }

  Widget _bannerSide(AppPalette t, {
    required ConnectionInfo? conn,
    required String? db,
    required String? schema,
  }) {
    final target = (db == null || db.isEmpty)
        ? '--'
        : (schema == null || schema.isEmpty ? db : '$db.$schema');
    return SizedBox(
      width: 260,
      child: Column(
        children: [
          Text(
            conn?.name ?? '--',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.foreground, fontSize: 13),
          ),
          const SizedBox(height: 2),
          Text(
            target,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.foreground, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // 单侧端点列:标题 + 连接 / 数据库 / 模式(标签在上、下拉在下)
  Widget _endpointColumn(AppPalette t, {required bool source}) {
    final conn = source ? _srcConn : _tgtConn;
    final database = source ? _srcDb : _tgtDb;
    final schema = source ? _srcSchema : _tgtSchema;
    final cm = widget.app.connectionManager;
    final dbState = conn == null ? null : cm.databaseStateOf(conn.name);
    final dbItems = dbState?.databases ?? const <String>[];
    final dbLoading = dbState?.status == LoadStatus.loading;
    final hasSchemaLayer = _hasSchemaLayer(conn);
    final schemaState = (conn != null && database != null && hasSchemaLayer)
        ? cm.schemaStateOf(conn.name, database)
        : null;
    final schemaItems = schemaState?.schemas ?? const <String>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          source ? '源' : '目标',
          style: TextStyle(
            color: t.accent,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        _fieldLabel(t, '连接:'),
        ComboBox<ConnectionInfo>(
          items: source ? _eligibleConnections : _targetConnections,
          value: conn,
          hint: _eligibleConnections.isEmpty ? '无可用连接' : '选择连接',
          itemToString: (c) => c.name,
          iconBuilder: (c) {
            final type = _dbTypeOf(c.typeId);
            return type == null ? null : DbTypeIcon(type: type, size: 16);
          },
          onChanged: source ? _onSourceChanged : _onTargetChanged,
        ),
        const SizedBox(height: 8),
        _fieldLabel(t, '数据库:'),
        ComboBox<String>(
          items: dbItems,
          value: database,
          enabled: conn != null && !dbLoading,
          hint: conn == null
              ? '先选连接'
              : (dbLoading ? '加载中 ...' : '选择数据库'),
          iconBuilder: (_) => const UiIcon(kDatabaseIcon, size: 15),
          onChanged: (v) => _onDatabaseChanged(source: source, db: v),
        ),
        const SizedBox(height: 8),
        _fieldLabel(t, '模式:'),
        ComboBox<String>(
          items: schemaItems,
          value: schema,
          enabled: conn != null && hasSchemaLayer && database != null,
          hint: !hasSchemaLayer
              ? '该类型无模式层'
              : (database == null
                  ? '先选数据库'
                  : (schemaItems.isEmpty ? '默认模式' : '选择模式')),
          iconBuilder: (_) => const UiIcon(kSchemaIcon, size: 15),
          onChanged: (v) => setState(() {
            if (source) {
              _srcSchema = v;
            } else {
              _tgtSchema = v;
            }
            _plan = null;
            _focused = null;
          }),
        ),
      ],
    );
  }

  Widget _fieldLabel(AppPalette t, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Text(
          text,
          style: TextStyle(color: t.foreground, fontSize: 12.5),
        ),
      );

  // 中间「⇅」交换按钮(与数据库行大致对齐)
  Widget _swapButton(AppPalette t) {
    return SizedBox(
      width: 76,
      child: Padding(
        padding: const EdgeInsets.only(top: 92),
        child: Button(
          text: '⇅',
          onPressed:
              (_comparing || _deploying || (_srcConn == null && _tgtConn == null))
                  ? null
                  : _swapSides,
        ),
      ),
    );
  }

  // 单侧「信息」面板
  Widget _infoColumn(AppPalette t, {required bool source}) {
    final conn = source ? _srcConn : _tgtConn;
    final version = source ? _srcVersion : _tgtVersion;
    final rows = <List<String>>[
      [
        '连接类型:',
        conn == null
            ? '--'
            : (_dbTypeOf(conn.typeId)?.label.replaceAll('\n', ' ') ?? conn.typeId),
      ],
      ['连接名称:', conn?.name ?? '--'],
      ['主机:', conn?.host ?? '--'],
      ['端口:', conn?.port ?? '--'],
      [
        '服务器版本:',
        (version == null || version.isEmpty) ? '--' : version,
      ],
    ];
    return Padding(
      padding: EdgeInsets.only(right: source ? 28 : 0, left: source ? 0 : 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '信息',
            style: TextStyle(
              color: t.accent,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 84,
                    child: Text(
                      r[0],
                      style: TextStyle(
                        color: t.mutedForeground,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      r[1],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.foreground, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  DbType? _dbTypeOf(String typeId) {
    for (final e in kAllDbTypes) {
      if (e.id == typeId) return e;
    }
    return null;
  }

  // ── 比较进度覆盖层 ────────────────────────────────────────

  Widget _compareOverlay(AppPalette t) {
    return Container(
      color: t.background,
      alignment: Alignment.center,
      child: SizedBox(
        width: 520,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const UiIcon(kDatabaseIcon, size: 34),
                const SizedBox(width: 12),
                Text(
                  '正在比较数据库...',
                  style: TextStyle(
                    color: t.foreground,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            ProgressBar(
              value: _total > 0 ? _done.toDouble() : 0,
              max: _total > 0 ? _total.toDouble() : 1,
              style: _total > 0
                  ? ProgressBarStyle.determinate
                  : ProgressBarStyle.marquee,
            ),
            const SizedBox(height: 10),
            Text(
              _total > 0 ? '$_stage（$_done / $_total）' : _stage,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.mutedForeground, fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: Button(text: '取消', onPressed: _cancelComparison),
            ),
          ],
        ),
      ),
    );
  }

  // ── ② 差异页 ──────────────────────────────────────────────

  Widget _reviewPage(AppPalette t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Stack 需要有限高(Positioned.fill 依赖),按横幅固有高度固定
        SizedBox(
          height: 68,
          child: Stack(
            children: [
              Positioned.fill(child: _banner(t)),
              Positioned(
                left: 16,
                top: 10,
                child: SizedBox(
                  width: 170,
                  child: ComboBox<String>(
                    items: const [kGroupByAction, kGroupByKind],
                    value: _groupBy,
                    itemToString: (s) => s,
                    onChanged: (v) => setState(() {
                      _groupBy = v ?? kGroupByAction;
                      _collapsedGroups.clear();
                    }),
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(height: 1, color: t.border),
        _tableHeader(t),
        Expanded(child: _diffTable(t)),
        Container(height: 1, color: t.border),
        SizedBox(
          height: 250,
          child: TabControl(
            initialIndex: _reviewTab,
            onChanged: (i) => _reviewTab = i,
            tabs: [
              TabItem(label: 'DDL 比较', child: _ddlComparePane(t)),
              TabItem(label: '部署脚本', child: _scriptPane(t)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tableHeader(AppPalette t) {
    return Container(
      height: 30,
      color: t.secondary,
      padding: const EdgeInsets.only(left: 50),
      child: Row(
        children: [
          Expanded(child: _headerCell(t, '源对象')),
          Container(width: 1, height: 16, color: t.border),
          SizedBox(width: 110, child: _headerCell(t, '操作', center: true)),
          Container(width: 1, height: 16, color: t.border),
          Expanded(child: _headerCell(t, '目标对象')),
          const SizedBox(width: 16),
        ],
      ),
    );
  }

  Widget _headerCell(AppPalette t, String text, {bool center = false}) => Text(
        text,
        textAlign: center ? TextAlign.center : TextAlign.start,
        style: TextStyle(color: t.mutedForeground, fontSize: 12.5),
      );

  Widget _diffTable(AppPalette t) {
    final plan = _plan;
    if (plan == null) {
      return Container(
        alignment: Alignment.center,
        color: t.surface,
        child: Text('尚未比较',
            style: TextStyle(color: t.mutedForeground, fontSize: 13)),
      );
    }
    final sections = <Widget>[];
    if (_groupBy == kGroupByAction) {
      for (final action in SyncAction.values) {
        final objs = plan.objects.where((o) => o.action == action).toList();
        if (objs.isEmpty) continue;
        _appendGroup(sections, t, 'a:${action.name}',
            _actionTitle(action, objs), action, objs);
      }
    } else {
      for (final kind in SyncObjectKind.values) {
        final objs = plan.objects.where((o) => o.kind == kind).toList();
        if (objs.isEmpty) continue;
        _appendGroup(sections, t, 'k:${kind.name}',
            '${kind.label}（共 ${objs.length} 个）', null, objs);
      }
    }
    if (sections.isEmpty) {
      return Container(
        alignment: Alignment.center,
        color: t.surface,
        child: Text('两侧结构一致,无需同步。',
            style: TextStyle(color: t.mutedForeground, fontSize: 13)),
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

  void _appendGroup(
    List<Widget> sections,
    AppPalette t,
    String key,
    String title,
    SyncAction? headAction,
    List<SyncObject> objs,
  ) {
    final collapsed = _collapsedGroups.contains(key);
    sections.add(_groupHeader(t, key, title, headAction, objs, collapsed));
    if (!collapsed) {
      for (final o in objs) {
        sections.add(_objectRow(t, o));
      }
    }
  }

  String _actionTitle(SyncAction action, List<SyncObject> objs) {
    if (action == SyncAction.none) return '无操作 (${objs.length} 个对象)';
    final sel = objs.where((o) => o.selected).length;
    return '${action.groupLabel} (已选择 $sel 个（共 ${objs.length} 个）)';
  }

  Widget _groupHeader(
    AppPalette t,
    String key,
    String title,
    SyncAction? headAction,
    List<SyncObject> objs,
    bool collapsed,
  ) {
    final deployable = objs.where((o) => o.selectable).toList();
    final allChecked =
        deployable.isNotEmpty && deployable.every((o) => o.selected);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() {
          if (_collapsedGroups.contains(key)) {
            _collapsedGroups.remove(key);
          } else {
            _collapsedGroups.add(key);
          }
        }),
        child: Container(
          height: 30,
          padding: const EdgeInsets.only(left: 8),
          child: Row(
            children: [
              Text(
                collapsed ? '▸' : '▾',
                style: TextStyle(
                  color: t.mutedForeground,
                  fontSize: 11,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 20,
                child: CheckBox(
                  value: allChecked,
                  enabled: deployable.isNotEmpty,
                  onChanged: deployable.isEmpty
                      ? null
                      : (v) => setState(() {
                            for (final o in deployable) {
                              o.checked = v ?? false;
                            }
                          }),
                ),
              ),
              const SizedBox(width: 8),
              if (headAction != null) ...[
                SizedBox(
                  width: 20,
                  child: Center(child: _actionGlyph(headAction)),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.foreground,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionGlyph(SyncAction action) {
    final (ch, color) = switch (action) {
      SyncAction.alter => ('→', kSyncAlterColor),
      SyncAction.create => ('+', kSyncCreateColor),
      SyncAction.drop => ('✕', kSyncDropColor),
      SyncAction.none => ('≡', kSyncNoneColor),
    };
    return Text(
      ch,
      style: TextStyle(
        color: color,
        fontSize: 14,
        fontWeight: FontWeight.w700,
        height: 1.0,
        decoration: TextDecoration.none,
      ),
    );
  }

  Widget _objectRow(AppPalette t, SyncObject o) {
    final focused = identical(_focused, o);
    return Listener(
      onPointerDown: (_) => setState(() => _focused = o),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: 27,
          color: focused ? t.treeSelectedBg : Colors.transparent,
          child: Row(
            children: [
              const SizedBox(width: 26),
              SizedBox(
                width: 20,
                child: o.selectable
                    ? CheckBox(
                        value: o.selected,
                        onChanged: (v) =>
                            setState(() => o.checked = v ?? false),
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: 4),
              Expanded(child: _nameCell(t, o, left: true)),
              SizedBox(width: 110, child: Center(child: _actionGlyph(o.action))),
              Expanded(child: _nameCell(t, o, left: false)),
              const SizedBox(width: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nameCell(AppPalette t, SyncObject o, {required bool left}) {
    // 删除行只剩目标侧,新建行只剩源侧;另一侧留空。
    final visible =
        left ? o.action != SyncAction.drop : o.action != SyncAction.create;
    if (!visible) return const SizedBox.shrink();
    final color = left
        ? (o.action == SyncAction.none ? t.mutedForeground : t.foreground)
        : t.mutedForeground;
    return Row(
      children: [
        ObjectCategoryIcon(category: _categoryOf(o.kind), size: 15),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            o.name + (o.note != null && left && !o.blocked ? '  · ${o.note}' : ''),
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: o.blocked && left
                  ? AppColors.of(context).iconWarning
                  : color,
              fontSize: 12.5,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ],
    );
  }

  ObjectCategory _categoryOf(SyncObjectKind kind) => switch (kind) {
        SyncObjectKind.table => ObjectCategory.table,
        SyncObjectKind.view => ObjectCategory.view,
        SyncObjectKind.function => ObjectCategory.function,
        SyncObjectKind.procedure => ObjectCategory.procedure,
      };

  Widget _ddlComparePane(AppPalette t) {
    final o = _focused;
    if (o == null) {
      return Container(
        alignment: Alignment.center,
        color: t.surface,
        child: Text(
          '在上方选择一个对象查看 DDL 比较。',
          style: TextStyle(color: t.mutedForeground, fontSize: 12.5),
        ),
      );
    }
    return SplitContainer(
      initialRatio: 0.5,
      minFirst: 160,
      minSecond: 160,
      first: _monoCard(t, '源 · ${o.name}', o.sourceDdl, '（源不存在该对象）'),
      second: _monoCard(t, '目标 · ${o.name}', o.targetDdl, '（目标不存在该对象）'),
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

  // ── ③ 部署页(部署脚本 / 消息日志) ────────────────────────

  Widget _scriptPage(AppPalette t) {
    return TabControl(
      // 程序化切换(部署开始跳日志)靠 key 重建实现:
      // TabControl 只在初始 index 生效,改 initialIndex 不会切页。
      key: ValueKey('script_tabs_$_scriptTab'),
      initialIndex: _scriptTab,
      onChanged: (i) => _scriptTab = i,
      tabs: [
        TabItem(label: '部署脚本', child: _scriptPane(t, withHeader: true)),
        TabItem(label: '消息日志', child: _logPane(t)),
      ],
    );
  }

  Widget _scriptPane(AppPalette t, {bool withHeader = false}) {
    final plan = _plan;
    final script = plan?.deployScript() ?? '';
    final targetLabel = _targetReady ? _target.displayTarget : '--';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (withHeader) ...[
          _banner(t),
          Container(height: 1, color: t.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                const UiIcon(kDatabaseIcon, size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _tgtConn?.name ?? '--',
                        style: TextStyle(
                            color: t.foreground,
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$targetLabel（以下脚本将在此服务器上运行）',
                        style:
                            TextStyle(color: t.mutedForeground, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Button(
                  text: _copied ? '已复制' : '复制脚本',
                  onPressed: script.isEmpty ? null : _copyScript,
                ),
              ],
            ),
          ),
          Container(height: 1, color: t.border),
        ],
        Expanded(
          child: Container(
            color: t.surface,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: Text(
                script.isEmpty ? '（未勾选任何可部署对象）' : script,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontFamilyFallback: const ['monospace'],
                  fontSize: 12,
                  height: 1.4,
                  color: script.isEmpty ? t.mutedForeground : t.foreground,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _logPane(AppPalette t) {
    final executed = _deploySuccess + _deployFailed;
    final started = _deployWatch.elapsed > Duration.zero;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: Row(
            children: [
              _logStat(
                t,
                '进度:',
                _deployTotal > 0
                    ? '$executed/$_deployTotal '
                        '(${(executed / _deployTotal * 100).toStringAsFixed(1)}%)'
                    : '--',
              ),
              _logStat(t, '成功:', '$_deploySuccess'),
              _logStat(t, '错误:', '$_deployFailed'),
              _logStat(
                  t, '时间:', started ? _fmtElapsed(_deployWatch.elapsed) : '--'),
            ],
          ),
        ),
        Container(height: 1, color: t.border),
        Expanded(
          child: Container(
            color: t.surface,
            child: SingleChildScrollView(
              controller: _logScroll,
              padding: const EdgeInsets.all(10),
              child: Text(
                _logLines.isEmpty ? '（尚未执行部署）' : _logLines.join('\n'),
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontFamilyFallback: const ['monospace'],
                  fontSize: 12,
                  height: 1.4,
                  color: _logLines.isEmpty
                      ? t.mutedForeground
                      : t.foreground,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _logStat(AppPalette t, String label, String value) => Padding(
        padding: const EdgeInsets.only(right: 24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    color: t.mutedForeground, fontSize: 12.5)),
            Text(value,
                style: TextStyle(
                    color: t.foreground,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      );

  // ── 底部按钮栏(随步骤变化) ───────────────────────────────

  Widget _footer(AppPalette t) {
    final busy = _comparing || _deploying;
    switch (_step) {
      case _Step.setup:
        return Row(
          children: [
            ..._configButtons(busy),
            const SizedBox(width: 8),
            Button(text: '选项', onPressed: busy ? null : _openOptions),
            const Spacer(),
            Button(
              text: _comparing ? '比对中...' : '比较',
              onPressed: _canCompare ? _compare : null,
            ),
          ],
        );
      case _Step.review:
        return Row(
          children: [
            ..._configButtons(busy),
            const Spacer(),
            Button(
              text: '上一步',
              onPressed:
                  busy ? null : () => setState(() => _step = _Step.setup),
            ),
            const SizedBox(width: 8),
            Button(
              text: '重新比较',
              onPressed: _canCompare ? _compare : null,
            ),
            const SizedBox(width: 8),
            Button(
              text: '下一步',
              onPressed: busy || _plan == null
                  ? null
                  : () => setState(() {
                        _scriptTab = 0;
                        _step = _Step.script;
                      }),
            ),
          ],
        );
      case _Step.script:
        final hasSelection = _plan != null && _plan!.selected.isNotEmpty;
        return Row(
          children: [
            ..._configButtons(busy),
            const SizedBox(width: 8),
            DropDownButton(
              trigger: Button(
                onPressed: () {},
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Text('部署选项'),
                    SizedBox(width: 8),
                    Text('▾', style: TextStyle(fontSize: 10)),
                  ],
                ),
              ),
              items: [
                ListItem(
                  title: '遇错停止',
                  selected: _stopOnError,
                  onSelect: () =>
                      setState(() => _stopOnError = !_stopOnError),
                ),
                ListItem(
                  title: '部署成功后重新比较',
                  selected: _recompareAfterDeploy,
                  onSelect: () => setState(
                      () => _recompareAfterDeploy = !_recompareAfterDeploy),
                ),
              ],
            ),
            const Spacer(),
            Button(
              text: '上一步',
              onPressed:
                  busy ? null : () => setState(() => _step = _Step.review),
            ),
            const SizedBox(width: 8),
            Button(
              text: '重新比较',
              onPressed: _canCompare ? _compare : null,
            ),
            const SizedBox(width: 8),
            Button(
              text: _deploying ? '部署中...' : '开始',
              onPressed: (hasSelection && !busy) ? _startDeploy : null,
            ),
          ],
        );
    }
  }

  List<Widget> _configButtons(bool busy) => [
        DropDownButton(
          trigger: Button(
            // 开合由 DropDownButton 接管,按钮仅提供视觉态
            onPressed: () {},
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text('保存配置文件'),
                SizedBox(width: 8),
                Text('▾', style: TextStyle(fontSize: 10)),
              ],
            ),
          ),
          items: [
            ListItem(
                title: '保存配置到 JSON 文件…',
                enabled: !busy,
                onSelect: _saveConfig),
          ],
        ),
        const SizedBox(width: 8),
        Button(text: '加载配置文件', onPressed: busy ? null : _loadConfig),
      ];
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
