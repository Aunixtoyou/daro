/// MCP 服务设置对话框(简报 §6 W6 / W7)。
///
/// 形态与 [theme_customize_dialog](同用 `DialogBox` + `TabControl`),但**不用草稿态**:
/// 定稿语义是「策略每次调用实时生效」,所以每个开关一改动就落盘 + 对账宿主,
/// 关闭对话框不需要「保存」。只有监听地址 / 端口 / Token 三个文本框例外
/// —— 逐字符落盘会让宿主反复重绑端口,因此它们要按「应用端点」一次性提交。
///
/// 全 base-ui 控件、零 Material、零动画(AGENTS.md 强制规则)。
library;

import 'dart:async';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/app_state.dart';
import '../app/mcp_service.dart';
import '../data/db_data.dart';
import '../data/db_types.dart';
import '../data/drivers/db_driver.dart';
import '../mcp/mcp_client_configs.dart';
import '../mcp/mcp_policy.dart';
import '../theme/app_theme.dart';

/// 拒绝 / 失败提示的红色:与 `query_page.dart` 的 `_errorColor` 同一中调色,
/// 主题无关(色板里没有语义错误色,业务色 [AppColors] 也不含)。
const Color _kErrorColor = Color(0xffd93025);

class McpSettingsDialog extends StatefulWidget {
  const McpSettingsDialog({super.key});

  @override
  State<McpSettingsDialog> createState() => _McpSettingsDialogState();
}

class _McpSettingsDialogState extends State<McpSettingsDialog> {
  /// DialogBox 正文固定高度(与 build 里的 height 同源)。
  static const double _kBodyHeight = 520;

  /// TabControl chrome 高度:标签条 + 面板底线(配合 contentPadding: zero)。
  static const double _kTabChromeHeight = 32;

  late final McpService _mcp;
  final TextEditingController _hostCtl = TextEditingController();
  final TextEditingController _portCtl = TextEditingController();
  final TextEditingController _tokenCtl = TextEditingController();
  final FocusNode _hostFocus = FocusNode();
  final FocusNode _portFocus = FocusNode();
  final FocusNode _tokenFocus = FocusNode();

  bool _tokenVisible = false;

  /// 端点栏的校验/失败原因(不落盘的那种,直接显示在字段下方)。
  String? _endpointError;

  /// 「重新检查」结果:null = 还没检查过,空串以外的值一律是一条中文原因。
  String? _checkResult;
  bool _checkOk = false;
  bool _checking = false;
  bool _copied = false;
  Timer? _copyReset;

  /// 工具页的整批拒绝原因(比如只剩最后一个工具时不让再关)。
  String? _toolsNote;

  int _clientIndex = 0;

  @override
  void initState() {
    super.initState();
    // initState 里用 read:watch 只允许在 build 期间注册依赖。
    _mcp = context.read<McpService>();
    _fillEndpointFields(_mcp.policy.http);
    _mcp.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _mcp.removeListener(_onServiceChanged);
    _copyReset?.cancel();
    _hostCtl.dispose();
    _portCtl.dispose();
    _tokenCtl.dispose();
    _hostFocus.dispose();
    _portFocus.dispose();
    _tokenFocus.dispose();
    super.dispose();
  }

  void _fillEndpointFields(McpHttpSettings http) {
    _hostCtl.text = http.host;
    _portCtl.text = http.port.toString();
    _tokenCtl.text = http.token;
  }

  /// 服务状态变化后同步端点输入框(焦点在框里时不动,别打断用户输入)。
  void _onServiceChanged() {
    if (!mounted) return;
    final http = _mcp.policy.http;
    if (!_hostFocus.hasFocus && _hostCtl.text != http.host) {
      _hostCtl.text = http.host;
    }
    if (!_portFocus.hasFocus && _portCtl.text != http.port.toString()) {
      _portCtl.text = http.port.toString();
    }
    if (!_tokenFocus.hasFocus && _tokenCtl.text != http.token) {
      _tokenCtl.text = http.token;
    }
    setState(() {});
  }

  // ── 保存 ───────────────────────────────────────────────────────────

  Future<void> _save(McpPolicy next, {String? reason}) async {
    try {
      await _mcp.save(next);
      if (!mounted) return;
      setState(() => _endpointError = null);
    } catch (e) {
      if (!mounted) return;
      await MessageBox.show(
        context,
        title: '保存失败',
        message: '${reason ?? '策略未能写入磁盘'}\n$e',
        type: MessageBoxType.error,
        okText: '知道了',
        tokens: Tokens.read(context).toDesktopTokens(),
      );
    }
  }

  Future<void> _applyEndpoint() async {
    final host = _hostCtl.text.trim();
    final port = int.tryParse(_portCtl.text.trim());
    if (host.isEmpty) {
      setState(() => _endpointError = '监听地址不能为空。要只给本机用就填 127.0.0.1');
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      setState(() => _endpointError = '端口需要是 1–65535 的整数');
      return;
    }
    final token = _tokenCtl.text.trim();
    final http = McpHttpSettings(
      host: host,
      port: port,
      token: token,
      allowRemote: _mcp.policy.http.allowRemote,
    );
    if (!http.isLoopback && token.isEmpty) {
      setState(() => _endpointError =
          '绑定 $host 属于对外监听,必须先设置 Token —— 否则同网段的任何人都能调你的数据库。'
          'daro 会在你补齐 Token 前拒绝启动监听。');
      return;
    }
    await _save(_mcp.policy.copyWith(http: http), reason: '端点设置未能写入:');
  }

  Future<void> _generateToken() async {
    setState(() => _tokenCtl.text = generateMcpToken());
    await _applyEndpoint();
  }

  // ── 检查 ───────────────────────────────────────────────────────────

  Future<void> _recheck() async {
    if (_checking) return;
    setState(() => _checking = true);
    final error = await _mcp.probe();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _checkOk = error == null;
      _checkResult = error ?? '健康探测通过(${_mcp.endpoint} 返回 200)';
    });
  }

  Future<void> _copy(String text) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    _copyReset?.cancel();
    _copyReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  // ── 构建 ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final mcp = context.watch<McpService>();
    final policy = mcp.policy;
    final bodyHeight = _kBodyHeight - _kTabChromeHeight;
    return DialogBox(
      title: 'MCP 服务',
      width: 780,
      height: _kBodyHeight,
      onClose: () => Navigator.of(context).maybePop(),
      footer: _buildFooter(t, mcp),
      child: SizedBox(
        height: _kBodyHeight,
        child: TabControl(
          contentPadding: EdgeInsets.zero,
          tabs: [
            TabItem(
              label: '服务',
              width: 92,
              child: _scroll(t, bodyHeight, _buildServiceTab(t, mcp, policy)),
            ),
            TabItem(
              label: '连接与模式',
              width: 104,
              child: _scroll(t, bodyHeight, _buildConnectionTab(t, policy)),
            ),
            TabItem(
              label: '工具与限额',
              width: 104,
              child: _scroll(t, bodyHeight, _buildToolTab(t, policy)),
            ),
            TabItem(
              label: '客户端配置',
              width: 104,
              child: _scroll(t, bodyHeight, _buildClientTab(t, policy)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scroll(AppPalette t, double height, List<Widget> children) {
    return SizedBox(
      height: height,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }

  // ── Tab 1:服务 ──────────────────────────────────────────────────────

  List<Widget> _buildServiceTab(AppPalette t, McpService mcp, McpPolicy policy) {
    final http = policy.http;
    return [
      CheckBox(
        value: policy.enabled,
        label: '启用 MCP 服务(默认关闭)',
        onChanged: (v) => mcp.setEnabled(v ?? false),
      ),
      _hint(t, '关闭时任何工具调用一律拒绝,监听端口也不会打开。'),
      const SizedBox(height: 12),
      _groupTitle(t, '监听端点'),
      _field(t, '地址', Row(children: [
        Expanded(child: Input(
          controller: _hostCtl,
          focusNode: _hostFocus,
          hint: '127.0.0.1',
        )),
        SizedBox(width: 10, child: _hint(t, ':')),
        Expanded(child: Input(
          controller: _portCtl,
          focusNode: _portFocus,
          hint: '5225',
          keyboardType: TextInputType.number,
        )),
      ]), description: '127.0.0.1 / localhost / ::1 = 只有本机能连;绑局域网地址前请想清楚。'),
      _field(t, 'Bearer Token', Row(children: [
        Expanded(child: Input(
          controller: _tokenCtl,
          focusNode: _tokenFocus,
          hint: '留空 = 仅回环监听时免鉴权',
          obscureText: !_tokenVisible,
        )),
        const SizedBox(width: 8),
        Button(
          text: _tokenVisible ? '隐藏' : '显示',
          variant: ButtonVariant.ghost,
          onPressed: () => setState(() => _tokenVisible = !_tokenVisible),
        ),
        const SizedBox(width: 8),
        Button(text: '生成', onPressed: _generateToken),
      ]), description: '轮换 Token 后各客户端都要重新粘贴一次配置。'),
      Row(children: [
        Button(text: '应用端点', onPressed: _applyEndpoint),
        const SizedBox(width: 10),
        Text('端点 ${http.endpoint}',
            style: TextStyle(
                fontSize: 12,
                fontFamily: 'Consolas',
                color: t.mutedForeground,
                decoration: TextDecoration.none,
                fontWeight: FontWeight.w400)),
      ]),
      if (_endpointError != null) _line(t, _endpointError!, _kErrorColor),
      const SizedBox(height: 10),
      _groupTitle(t, '运行状态'),
      _line(t, _statusLine(mcp, policy), mcp.isRunning ? t.foreground : _kErrorColor),
      if (mcp.startError != null && !mcp.isRunning)
        _line(t, '原因:${mcp.startError}', _kErrorColor),
      _line(
          t,
          '并发调用 ${mcp.activeCalls} 次 · 池内专用连接 ${mcp.pooledDrivers} 个 · '
              '最近握手 ${_fmtTime(mcp.lastRequestAt)}',
          t.mutedForeground),
      Row(children: [
        Button(
          text: _checking ? '检查中…' : '重新检查',
          onPressed: _checking ? null : _recheck,
        ),
        const SizedBox(width: 10),
        if (_checkResult != null)
          Expanded(
              child: _line(t, _checkResult!, _checkOk ? _okColor(t) : _kErrorColor)),
      ]),
      if (!mcp.policyStatus.isHealthy)
        _line(t, '策略文件读取失败,当前显示的是默认策略 —— 保存一次即可覆盖修复。', _kErrorColor),
      const SizedBox(height: 10),
      _groupTitle(t, '可观测与凭据'),
      CheckBox(
        value: policy.auditEnabled,
        label: '记录审计日志(每次工具调用一行)',
        onChanged: (v) =>
            _save(policy.copyWith(auditEnabled: v ?? false), reason: '审计设置未能写入:'),
      ),
      _hint(t, '落盘在应用数据目录的 mcp_audit.jsonl;只记连接/库/语句摘要与耗时,绝不记密码。'),
      const SizedBox(height: 6),
      _field(t, '连接缺少已保存密码时', ComboBox<String>(
        items: const ['在 daro 里弹窗请我补录', '直接拒绝该次调用'],
        value: policy.passwordPrompt == McpPasswordPrompt.askInApp
            ? '在 daro 里弹窗请我补录'
            : '直接拒绝该次调用',
        onChanged: (v) => _save(
            policy.copyWith(
                passwordPrompt: v == '在 daro 里弹窗请我补录'
                    ? McpPasswordPrompt.askInApp
                    : McpPasswordPrompt.deny),
            reason: '密码策略未能写入:'),
      ), description: '弹窗等待上限 120 秒;无人响应即返回 PASSWORD_REQUIRED。'),
      if (!http.isLoopback)
        _line(t, '正在对外监听 ${http.host}: 请确认这是你想要的。', AppColors.of(context).iconWarning),
    ];
  }

  String _statusLine(McpService mcp, McpPolicy policy) {
    if (!policy.enabled) return '未启用 —— 监听未开启,agent 连不上';
    if (!policy.http.isServeable) return '已启用但拒绝监听:非回环地址必须设置 Token';
    if (!mcp.isRunning) return '未在监听(${policy.http.endpoint})';
    return '正在监听 ${mcp.endpoint}';
  }

  // ── Tab 2:连接与模式 ────────────────────────────────────────────────

  List<Widget> _buildConnectionTab(AppPalette t, McpPolicy policy) {
    final conns = context.watch<AppState>().connections;
    final orphans = _orphanNames(policy, conns);
    return [
      _field(t, '默认执行模式', ComboBox<String>(
        items: const ['只读', '数据读写', '完全访问'],
        value: policy.defaultMode.label,
        onChanged: (v) => _save(policy.copyWith(defaultMode: _modeByLabel(v)),
            reason: '默认模式未能写入:'),
      ), description: _modeMatrix(policy)),
      const SizedBox(height: 4),
      CheckBox(
        value: policy.connectionScopeAll,
        label: '全部连接(含以后新增的)',
        onChanged: (v) => _save(policy.copyWith(connectionScopeAll: v ?? true),
            reason: '连接范围未能写入:'),
      ),
      _hint(t, '取消勾选后只放行下面打勾的连接;未打勾的连接在任何模式下都不可见。'),
      const SizedBox(height: 8),
      if (conns.isEmpty) _line(t, '当前没有连接。', t.mutedForeground),
      for (final c in conns) _connRow(t, policy, c),
      if (orphans.isNotEmpty) ...[
        const SizedBox(height: 8),
        _line(t, '有 ${orphans.length} 条授权指向已不存在的连接:${orphans.join('、')}',
            _kErrorColor),
        Button(
          text: '清理孤儿授权',
          variant: ButtonVariant.ghost,
          onPressed: () => _save(policy.copyWith(
            connectionNames:
                policy.connectionNames.where((n) => !orphans.contains(n)).toList(),
            connections: policy.connections
                .where((r) => !orphans.contains(r.connection))
                .toList(),
          ), reason: '清理未能写入:'),
        ),
      ],
    ];
  }

  String _modeMatrix(McpPolicy policy) => switch (policy.defaultMode) {
        McpMode.readonly =>
          '只读:SELECT / SHOW / DESC / EXPLAIN 等明确只读语句;带 LIMIT 0 之类无效包装也算高风险。',
        McpMode.readWrite =>
          '数据读写:额外允许 INSERT、带非平凡 WHERE 的 UPDATE / DELETE;无 WHERE 或 WHERE 1=1 一律要求完全访问。',
        McpMode.full =>
          '完全访问:额外允许全表更新/清空与 DDL。这是风险档位,请只为确实要改结构的连接开启。',
      };

  Widget _connRow(AppPalette t, McpPolicy policy, ConnectionInfo c) {
    final rule = policy.connections
        .where((r) => r.connection == c.name)
        .firstOrNull;
    final allowed = policy.connectionScopeAll || policy.connectionNames.contains(c.name);
    final supported = hasDriver(c);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.divider, width: 1)),
      ),
      child: Row(children: [
        SizedBox(
          width: 22,
          child: CheckBox(
            value: allowed,
            enabled: !policy.connectionScopeAll,
            onChanged: (v) => _toggleConnection(policy, c.name, v ?? false),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.name,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: supported ? t.foreground : t.disabledForeground,
                      decoration: TextDecoration.none,
                      fontWeight: FontWeight.w400)),
              Text(
                  '${_typeLabel(c.typeId)} · ${c.host}:${c.port}'
                  '${supported ? '' : ' · daro 无可用驱动'}',
                  style: TextStyle(
                      fontSize: 11,
                      color: t.mutedForeground,
                      decoration: TextDecoration.none,
                      fontWeight: FontWeight.w400)),
            ],
          ),
        ),
        SizedBox(
          width: 150,
          child: ComboBox<String>(
            items: const ['继承默认', '只读', '数据读写', '完全访问'],
            value: rule?.mode?.label ?? '继承默认',
            onChanged: (v) => _setConnMode(policy, c.name, v),
          ),
        ),
      ]),
    );
  }

  void _toggleConnection(McpPolicy policy, String name, bool allowed) {
    final names = policy.connectionNames.toList();
    if (allowed) {
      if (!names.contains(name)) names.add(name);
    } else {
      names.remove(name);
    }
    _save(policy.copyWith(connectionScopeAll: false, connectionNames: names),
        reason: '连接授权未能写入:');
  }

  void _setConnMode(McpPolicy policy, String name, String? label) {
    final mode = _modeByLabel(label);
    final rules = [
      for (final r in policy.connections)
        if (r.connection == name)
          McpConnectionRule(
            connection: name,
            mode: mode == null ? null : mode,
            databaseScope: r.databaseScope,
            databaseModes: r.databaseModes,
          )
        else
          r,
    ];
    if (!rules.any((r) => r.connection == name)) {
      rules.add(McpConnectionRule(connection: name, mode: mode));
    }
    // 全继承且没有其它字段的规则没有落盘价值,但保留它们更直观:删掉会让
    // 「连接范围」里的显式条目凭空消失。
    _save(policy.copyWith(connections: rules), reason: '连接模式未能写入:');
  }

  static List<String> _orphanNames(McpPolicy policy, List<ConnectionInfo> conns) {
    final live = conns.map((c) => c.name).toSet();
    final named = <String>{
      ...policy.connectionNames,
      ...policy.connections.map((r) => r.connection),
    };
    return named.where((n) => !live.contains(n)).toList()..sort();
  }

  static McpMode? _modeByLabel(String? label) => switch (label) {
        '只读' => McpMode.readonly,
        '数据读写' => McpMode.readWrite,
        '完全访问' => McpMode.full,
        _ => null,
      };

  static String _typeLabel(String typeId) =>
      kAllDbTypes.where((d) => d.id == typeId).firstOrNull?.label.split('\n').last ??
      typeId;

  // ── Tab 3:工具与限额 ────────────────────────────────────────────────

  List<Widget> _buildToolTab(AppPalette t, McpPolicy policy) {
    final enabled = policy.tools.isEmpty
        ? kMcpPhase1ToolIds.toSet()
        : policy.tools.toSet();
    return [
      _groupTitle(t, '开放给 MCP 的工具'),
      _hint(t, '名单在服务端每次调用强校验,不只是界面隐藏。'),
      const SizedBox(height: 4),
      for (final id in kMcpPhase1ToolIds)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: CheckBox(
            value: enabled.contains(id),
            label: '${_toolLabels[id] ?? id}  $id',
            onChanged: (v) => _toggleTool(policy, id, v ?? false, enabled),
          ),
        ),
      if (_toolsNote != null) _line(t, _toolsNote!, _kErrorColor),
      const SizedBox(height: 12),
      _groupTitle(t, '规模与超时'),
      _pair(t, '默认返回行数', NumericUpDown(
            value: policy.maxRows.toDouble(),
            min: 1,
            max: 100000,
            step: 10,
            onChanged: (v) => _setMaxRows(policy, v.round()),
          ), '单次上限', NumericUpDown(
            value: policy.hardRowCap.toDouble(),
            min: 1,
            max: 100000,
            step: 50,
            onChanged: (v) => _save(
                policy.copyWith(hardRowCap: v.round() < policy.maxRows ? policy.maxRows : v.round()),
                reason: '行数上限未能写入:'),
          )),
      _hint(t, 'agent 请求的行数越界时夹取到上限,不报错。'),
      const SizedBox(height: 6),
      _field(t, '查询超时(秒)', Row(children: [
        Expanded(child: NumericUpDown(
              value: policy.timeouts.readonlySecs.toDouble(),
              min: 1,
              max: 3600,
              step: 5,
              onChanged: (v) => _setTimeouts(policy, readonly: v.round()),
            )),
        SizedBox(width: 8, child: _hint(t, '只读')),
        Expanded(child: NumericUpDown(
              value: policy.timeouts.readWriteSecs.toDouble(),
              min: 1,
              max: 3600,
              step: 5,
              onChanged: (v) => _setTimeouts(policy, readWrite: v.round()),
            )),
        SizedBox(width: 8, child: _hint(t, '读写')),
        Expanded(child: NumericUpDown(
              value: policy.timeouts.fullSecs.toDouble(),
              min: 1,
              max: 3600,
              step: 10,
              onChanged: (v) => _setTimeouts(policy, full: v.round()),
            )),
        SizedBox(width: 8, child: _hint(t, '完全')),
      ]), description: 'SQLite / Access 没有服务端会话可取消:到点只能丢弃驱动实例并返回 QUERY_TIMEOUT。'),
      const SizedBox(height: 6),
      _pair(t, '并发专用连接', NumericUpDown(
            value: policy.poolMaxDrivers.toDouble(),
            min: 1,
            max: 64,
            onChanged: (v) => _save(policy.copyWith(poolMaxDrivers: v.round()),
                reason: '连接池设置未能写入:'),
          ), '空闲回收(秒)', NumericUpDown(
            value: policy.poolIdleTtlSecs.toDouble(),
            min: 10,
            max: 86400,
            step: 30,
            onChanged: (v) => _save(policy.copyWith(poolIdleTtlSecs: v.round()),
                reason: '连接池设置未能写入:'),
          )),
      _hint(t, '同一 连接|库|模式 复用一条连接;超出并发上限直接返回 POOL_EXHAUSTED。'),
    ];
  }

  void _toggleTool(McpPolicy policy, String id, bool on, Set<String> current) {
    final next = current.toSet();
    if (on) {
      next.add(id);
      _toolsNote = null;
    } else if (next.length > 1) {
      next.remove(id);
      _toolsNote = null;
    } else {
      // tools 落盘成空 = 「全选」语义,所以不能靠清空名单来表达「全关」。
      setState(() => _toolsNote = '至少保留一个工具;要整体停用请取消勾选「启用 MCP 服务」。');
      return;
    }
    _save(policy.copyWith(tools: next.toList()..sort()), reason: '工具名单未能写入:');
  }

  void _setMaxRows(McpPolicy policy, int rows) {
    _save(
        policy.copyWith(
          maxRows: rows,
          hardRowCap: policy.hardRowCap < rows ? rows : policy.hardRowCap,
        ),
        reason: '行数设置未能写入:');
  }

  void _setTimeouts(McpPolicy p, {int? readonly, int? readWrite, int? full}) {
    final t = p.timeouts;
    _save(
        p.copyWith(
            timeouts: McpTimeouts(
          readonlySecs: readonly ?? t.readonlySecs,
          readWriteSecs: readWrite ?? t.readWriteSecs,
          fullSecs: full ?? t.fullSecs,
        )),
        reason: '超时设置未能写入:');
  }

  static const Map<String, String> _toolLabels = {
    'daro_list_connections': '列出已授权连接',
    'daro_list_databases': '列出数据库',
    'daro_list_schemas': '列出模式',
    'daro_list_tables': '列出表',
    'daro_describe_table': '查看表结构',
    'daro_get_schema_context': '打包结构上下文',
    'daro_execute_query': '执行 SQL',
    'daro_preview_table': '预览表数据',
    'daro_list_routines': '列出函数/存储过程',
    'daro_get_routine_source': '读取例程源码',
    'daro_open_table': '在 daro 里打开表',
  };

  // ── Tab 4:客户端配置(W7)────────────────────────────────────────────

  List<Widget> _buildClientTab(AppPalette t, McpPolicy policy) {
    final configs = mcpClientConfigs(policy.http);
    final index = _clientIndex.clamp(0, configs.length - 1);
    final config = configs[index];
    return [
      _field(t, '目标客户端', ComboBox<String>(
        items: [for (final c in configs) c.label],
        value: config.label,
        onChanged: (v) {
          final i = configs.indexWhere((c) => c.label == v);
          if (i >= 0) setState(() => _clientIndex = i);
        },
      ), description: '粘贴到:${config.filePath}'),
      const SizedBox(height: 6),
      Row(children: [
        Button(
          text: _copied ? '已复制' : '复制配置',
          onPressed: () => _copy(config.json),
        ),
        const SizedBox(width: 8),
        Button(
          text: _checking ? '检查中…' : '重新检查',
          variant: ButtonVariant.ghost,
          onPressed: _checking ? null : _recheck,
        ),
        const SizedBox(width: 10),
        if (_checkResult != null)
          Expanded(child: _line(t, _checkResult!, _checkOk ? _okColor(t) : _kErrorColor)),
      ]),
      const SizedBox(height: 8),
      SizedBox(height: 224, child: _codeBlock(t, config.json)),
      const SizedBox(height: 8),
      for (final note in config.notes)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: _line(t, '· $note', t.mutedForeground),
        ),
      _line(t, 'daro 不代写第三方客户端的配置文件:这里只生成,复制过去由你保存。',
          t.disabledForeground),
    ];
  }

  /// 只读代码块。AGENTS.md 禁止在 daro 侧自造控件,而 base-ui 的 `Input` 没有
  /// 多行形态(`Textarea` 是编辑态、禁用后着色会变灰),因此沿用
  /// `schema_sync_dialog.dart` 的既有做法:Container + 滚动 + 等宽 Text。
  Widget _codeBlock(AppPalette t, String text) {
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.border, width: 1),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(10),
        child: Text(
          text,
          style: TextStyle(
            fontFamily: 'Consolas',
            fontFamilyFallback: const ['monospace'],
            fontSize: 12,
            height: 1.45,
            color: t.foreground,
            decoration: TextDecoration.none,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }

  // ── Footer ──────────────────────────────────────────────────────────

  Widget _buildFooter(AppPalette t, McpService mcp) {
    return Row(children: [
      Text(
        mcp.policy.enabled
            ? '改动即时落盘并生效,无需重启 MCP 客户端'
            : '服务未启用:agent 现在连不上 daro',
        style: TextStyle(
            fontSize: 11.5,
            color: t.mutedForeground,
            decoration: TextDecoration.none,
            fontWeight: FontWeight.w400),
      ),
      const Spacer(),
      Button(text: '关闭', onPressed: () => Navigator.of(context).maybePop()),
    ]);
  }

  // ── 小件:分组标题 / 字段 / 文本行 ───────────────────────────────────

  Widget _groupTitle(AppPalette t, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: t.mutedForeground,
                decoration: TextDecoration.none)),
      );

  Widget _field(AppPalette t, String label, Widget control, {String? description}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: t.foreground,
                  decoration: TextDecoration.none,
                  fontWeight: FontWeight.w400)),
          const SizedBox(height: 4),
          control,
          if (description != null) ...[
            const SizedBox(height: 3),
            _hint(t, description),
          ],
        ],
      ),
    );
  }

  Widget _hint(AppPalette t, String text) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(text,
            style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: t.mutedForeground,
                decoration: TextDecoration.none,
                fontWeight: FontWeight.w400)),
      );

  Widget _line(AppPalette t, String text, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(text,
            style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: color,
                decoration: TextDecoration.none,
                fontWeight: FontWeight.w400)),
      );

  Widget _pair(AppPalette t, String labelA, Widget a, String labelB, Widget b) =>
      Row(children: [
        Expanded(child: _field(t, labelA, a)),
        const SizedBox(width: 12),
        Expanded(child: _field(t, labelB, b)),
      ]);

  /// 成功提示色:业务色板的成功图标色(按主题各有一套)。
  Color _okColor(AppPalette t) => AppColors.of(context).iconSuccess;

  static String _fmtTime(DateTime? dt) {
    if (dt == null) return '从未';
    final local = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}
