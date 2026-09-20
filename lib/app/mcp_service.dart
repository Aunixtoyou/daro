/// MCP 服务的应用侧宿主(简报 §6 W5/W6/W14 的接线点)。
///
/// 职责:**只有生命周期与注入**,判定逻辑全在 `lib/mcp/`(纯 Dart,可单测)。
/// - 策略文件每次工具调用都重读(`McpToolDeps.loadPolicy` 直连磁盘),所以
///   用户在设置页收紧权限后不必重启 MCP 客户端;本类的 [_policy] 只是给 UI 的快照;
/// - 宿主按策略对账:未启用 / 绑了非回环却没 token → 不起,并把原因留给设置页显示;
/// - 驱动池、协议层、审计落盘都在此处装配,`dispose` 时按序收干净。
///
/// 与连接树无关:工具执行走 [McpDriverPool] 的专用实例,绝不复用
/// `ConnectionManager` 的长连接(E4:反复 useDatabase 会改用户正在用的运行上下文)。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:path_provider/path_provider.dart';

import '../app/sub_window.dart';
import '../data/db_data.dart';
import '../data/mcp_policy_store.dart';
import '../theme/app_theme.dart' show AppTheme;
import '../widgets/connection_password_dialog.dart';
import '../mcp/mcp_http_host.dart';
import '../mcp/mcp_policy.dart';
import '../mcp/mcp_pool.dart';
import '../mcp/mcp_protocol.dart';
import '../mcp/mcp_tools.dart';
import 'version.g.dart';

/// 空密码连接的补录回调(W14):宿主弹 daro 的密码子窗,人输入后返回 true。
/// 未注入时工具层直接回 `PASSWORD_REQUIRED`(不会静默挂住)。
typedef McpPasswordAsker = Future<bool> Function(ConnectionInfo conn);

/// UI 桥(D9):在 daro 里把表打开成人能看的标签页。
typedef McpTableOpener = Future<void> Function(
    String connection, String database, String table);

/// 健康探测:GET 端点并回状态码,连不上就抛。单独抽出来是为了可测 ——
/// `TestWidgetsFlutterBinding` 会把 `HttpClient` 全部请求变成 400,
/// 不注入就没法验证「起来了 / 没起来」两条分支。
typedef McpHealthGet = Future<int> Function(String url);

class McpService extends ChangeNotifier {
  McpService({
    required Future<List<ConnectionInfo>> Function() loadConnections,
    this.askPassword,
    this.openTableBridge,
    McpPolicyStore? policyStore,
    McpDriverPool? pool,
    McpHealthGet? healthGet,
  })  : _loadConnections = loadConnections,
        _store = policyStore ?? McpPolicyStore(),
        _pool = pool ?? McpDriverPool(),
        _healthGet = healthGet ?? _httpStatus;

  static const _auditFileName = 'mcp_audit.jsonl';

  /// 审计日志上限:超了就从文件头重写。这是回看线索不是账本,不该无界涨盘。
  static const _auditMaxBytes = 2 * 1024 * 1024;

  final Future<List<ConnectionInfo>> Function() _loadConnections;
  final McpPasswordAsker? askPassword;
  final McpTableOpener? openTableBridge;
  final McpPolicyStore _store;
  final McpDriverPool _pool;
  final McpHealthGet _healthGet;

  late final McpToolService _tools = McpToolService(McpToolDeps(
    // 直连磁盘而非 _policy 快照 —— 定稿语义「改权限不必重启客户端」。
    loadPolicy: _store.load,
    loadConnections: _loadConnections,
    pool: _pool,
    requestPassword: askPassword,
    openTableBridge: openTableBridge,
    audit: _writeAudit,
  ));

  McpPolicy _policy = const McpPolicy.defaults();
  McpPolicyLoadStatus _status = McpPolicyLoadStatus.missing;
  McpHttpHost? _host;
  String? _startError;
  int _activeCalls = 0;
  bool _disposed = false;
  Future<void>? _bootstrap;

  /// 对账串行链:设置页连点(启用 → 改端口 → 保存)不能交叉起停宿主。
  Future<void> _chain = Future<void>.value();

  /// 审计落盘串行链:同步回调不能 await,顺序靠这条链保证。
  Future<void> _auditChain = Future<void>.value();

  // ── 只读状态(UI 侧) ─────────────────────────────────────────────

  /// 给 UI 的策略快照。**判定不看它** —— 工具侧每次调用重新读盘。
  McpPolicy get policy => _policy;

  /// 策略文件读取状态:`corrupted` 时设置页要显示降级告警。
  McpPolicyLoadStatus get policyStatus => _status;

  bool get isRunning => _host?.isRunning ?? false;

  /// 未起来的原因(端口占用 / 非回环却没 token)。null = 没有失败过。
  String? get startError => _startError;

  String get endpoint => isRunning ? _host!.endpoint : _policy.http.endpoint;

  /// 正在执行的工具调用数(状态栏:让用户知道「有 agent 在动我的库」)。
  int get activeCalls => _activeCalls;

  DateTime? get lastRequestAt => _host?.lastRequestAt;

  /// 当前池内活着的专用驱动实例数(设置页显示,排查握手开销用)。
  int get pooledDrivers => _pool.activeCount;

  /// 协议层:HTTP 宿主与测试都从这一个入口进(宿主只负责收发与鉴权)。
  late final McpProtocolHandler protocolHandler = McpProtocolHandler(
    tools: _tools,
    serverName: 'daro',
    serverVersion: kAppVersion,
  );

  // ── 生命周期 ─────────────────────────────────────────────────────

  /// 启动时读盘并按策略起宿主。幂等(AppState 只在连接加载完后调一次)。
  Future<void> bootstrap() => _bootstrap ??= _run(_refresh);

  /// 重新读盘 + 对账:设置页「重新检查」用,也兜住策略文件被外部改过的情况。
  Future<void> reload() => _run(_refresh);

  /// 保存策略并立即对账(启用 / 改端口 / 换 token / 调模式都走这里)。
  ///
  /// 落盘失败时抛异常且不改动内存态 —— UI 不该显示一个没生效的开关状态。
  Future<void> save(McpPolicy next) => _run(() async {
        await _store.save(next);
        _policy = next;
        await _reconcile();
        _notify();
      });

  /// 便捷开关(设置页顶部那个 CheckBox)。
  Future<void> setEnabled(bool enabled) => save(_policy.copyWith(enabled: enabled));

  /// 连接名是否为 MCP 所授权(W12 改名守卫:只有 true 才需要提示与迁移)。
  bool authorizes(String connectionName) =>
      _policy.authorizesConnection(connectionName);

  /// 连接改名(P6 / D10:名称即标识,所以改名必须带走授权)。
  ///
  /// 策略条目随名字迁移,池里以旧名为键的实例一律销毁 ——
  /// 否则改名后旧实例仍会服务新连接,看着像授权没失效。
  Future<void> renameConnection(String oldName, String newName) async {
    if (oldName == newName || !authorizes(oldName)) return;
    await save(_policy.withRenamedConnection(oldName, newName));
    await _pool.invalidateConnection(oldName);
  }

  /// 「重新检查」:探一次自己的健康端点。返回 null = 通,否则一句可执行的中文原因。
  Future<String?> probe() async {
    if (!_policy.enabled) return 'MCP 服务当前未启用';
    final url = _policy.http.endpoint;
    // 只观察不重试:起停宿主必须走 _run 串行链,在这里并发 bind 会自己撞自己。
    if (!isRunning) return _startError ?? '宿主未在监听($url)';
    try {
      final status = await _healthGet(url);
      if (status == HttpStatus.ok) return null;
      return '$url 在监听,但健康探测返回 HTTP $status';
    } on SocketException catch (e) {
      return '连不上 $url —— ${e.osError?.message ?? e.message}';
    } catch (e) {
      return '连不上 $url —— $e';
    }
  }

  /// W14 密码补录:策略设置 passwordPrompt == askInApp 时,工具层调用此方法。
  ///
  /// 返回 true = 用户输入了密码(由外部回调更新连接列表);
  /// 返回 false = 用户取消 / 超时(≤120s) / 无注入回调 → 工具层回 PASSWORD_REQUIRED.
  Future<bool> requestPassword(ConnectionInfo conn,
      {Duration timeout = const Duration(seconds: 120)}) async {
    try {
      return await _askForPassword(conn).timeout(timeout);
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 默认探测实现:GET /mcp(daro 自有健康路由,不走鉴权)。
  static Future<int> _httpStatus(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  /// 收干净:停监听 → 丢弃池内实例 → 等审计写完。
  ///
  /// 公开是因为测试(以及退出流程)需要**等**它做完;`dispose` 只能 fire-and-forget。
  Future<void> shutdown() => _run(() async {
        await _stopHost();
        await _pool.dispose();
        await _auditChain;
      });

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }

  /// W14 密码补录回调(策略 passwordPrompt == McpPasswordPrompt.askInApp)。
  ///
  /// 注入路径: [AppState] → 构造 McpService 时传 `askPassword`.
  /// - 有外部回调时先调用它(UI-based,可操作 BuildContext).
  ///   回调负责展示 UI 并将新密码存入连接列表,返回 true/false.
  /// - 无回调时尝试 openSubWindow 独立子窗口.
  ///   插件不可用 / 非桌面平台则降级为 deny(false).
  Future<bool> _askForPassword(ConnectionInfo conn) async {
    final callback = askPassword;
    if (callback != null) {
      try {
        return await callback(conn);
      } catch (_) {
        return false;
      }
    }
    // 无外部回调 → 通过 openSubWindow 打开「连接密码」独立子窗口。
    // 用户输入密码 → 回传结果.超时 / 取消 / 插件不可用 → 返回 false.
    try {
      final result = await openSubWindow<ConnectionPasswordResult>(
        channelPrefix: 'daro/connection_password',
        args: (channelName) => {
          'type': 'connectionPassword',
          'channel': channelName,
          'conn': conn.toJson(),
          'dark': true,
          'palette': AppTheme.dark.toJson(),
        },
        onSubmit: (call) {
          final a = call.arguments as Map<String, dynamic>;
          return ConnectionPasswordResult(
            a['password'] as String? ?? '',
            save: a['save'] == true,
          );
        },
      );
      if (result != null && result.password.isNotEmpty) {
        return true;
      }
      return false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  // ── 内部 ─────────────────────────────────────────────────────────

  Future<void> _run(Future<void> Function() body) {
    final prev = _chain;
    final done = Completer<void>();
    _chain = done.future;
    return prev.whenComplete(() async {
      try {
        await body();
      } finally {
        if (!done.isCompleted) done.complete();
      }
    });
  }

  Future<void> _refresh() async {
    final loaded = await _store.loadWithStatus();
    _policy = loaded.policy;
    _status = loaded.status;
    await _reconcile();
    _notify();
  }

  /// 按当前策略起停宿主:端点或 token 变了就重建(先 stop 再 bind,否则会留下
  /// 一个仍在监听旧端口的僵尸宿主 = 两份权限同时生效),不该服务时一律停。
  Future<void> _reconcile() async {
    // 首帧加载完成时应用可能已经退出(Widget 测试尤其如此),别在那之后再绑端口。
    if (_disposed) return;
    final http = _policy.http;
    if (!_policy.isServing) {
      await _stopHost();
      _startError = _policy.enabled
          ? '已启用但拒绝监听:绑定非回环地址 ${http.host} 必须设置 Token'
              '(否则同网段的任何人都能调你的数据库)'
          : null;
      return;
    }
    final current = _host;
    if (current != null &&
        current.host == http.host &&
        current.port == http.port &&
        current.token == http.token) {
      return; // 端点没变,继续跑
    }
    await _stopHost();
    final host = McpHttpHost(
      handler: protocolHandler,
      host: http.host,
      port: http.port,
      token: http.token,
      onActivityChanged: _onActivity,
    );
    final result = await host.start();
    if (result.ok) {
      _host = host;
      _startError = null;
    } else {
      _startError = result.error;
    }
  }

  Future<void> _stopHost() async {
    final host = _host;
    _host = null;
    _activeCalls = 0;
    if (host != null) await host.stop();
  }

  void _onActivity(int active) {
    if (_activeCalls == active) return;
    _activeCalls = active;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ── 审计(P4 之外的可观测面:验收要求「看审计日志,不能只看返回值」) ──

  /// 同步回调(工具层在 callTool 收尾时调),落盘排成单链,顺序与调用一致。
  void _writeAudit(Map<String, dynamic> event) {
    if (!_policy.auditEnabled) return;
    final line = jsonEncode(event);
    _auditChain = _auditChain
        .then((_) => _appendAuditLine(line))
        .catchError((Object _) {
      // 审计写盘失败不该让工具调用失败,也不该留下未接管的异步错误。
    });
  }

  Future<void> _appendAuditLine(String line) async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$_auditFileName');
    final mode = await file.exists() && await file.length() > _auditMaxBytes
        ? FileMode.write
        : FileMode.append;
    await file.writeAsString('$line\n', mode: mode, flush: true);
  }
}
