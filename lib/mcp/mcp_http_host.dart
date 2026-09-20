/// 内嵌 Streamable HTTP 宿主(简报 §6 W5 / 定稿 D1 方案 A)。
///
/// - 单一端点 `POST /mcp`(JSON-RPC 2.0;`GET /mcp` 是 daro 自己的健康探测,
///   供设置页「重新检查」与状态栏使用,不属于 MCP 协议);
/// - Bearer 鉴权:回环 + 空 token = 免鉴权(与 DBX 同语义);绑非回环必须
///   有 token(由策略 `isServeable` 在 app 侧挡住,这里再兜一层);
/// - 端口占用 / 绑定失败**不静默**:原因原样上报给设置页自解释
///   (DBX FAQ 的 ERR_CONNECTION_REFUSED / 端口占用两条要能在 UI 上讲清);
/// - 并发调用计数上报给状态栏(W9:让用户随时知道「有 agent 在动我的库」)。
///
/// ⚠️ 本文件禁止 import package:flutter;宿主生命周期由 app 侧
/// (`lib/app/mcp_service.dart`)掌控。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'mcp_protocol.dart';

/// 启动结果:失败原因给人看,也给设置页红字展示。
class McpHostStartResult {
  const McpHostStartResult.success()
      : error = null,
        ok = true;
  const McpHostStartResult.failure(this.error)
      : ok = false;

  final bool ok;
  final String? error;
}

class McpHttpHost {
  McpHttpHost({
    required this.handler,
    required this.host,
    required this.port,
    required this.token,
    this.onActivityChanged,
  });

  final McpProtocolHandler handler;
  final String host;
  final int port;

  /// Bearer token;空串 = 回环免鉴权(仅当监听回环地址时 app 侧才会建宿主)。
  final String token;

  /// 并发调用数变化(状态栏指示 / 设置页计数)。
  final void Function(int activeCalls)? onActivityChanged;

  HttpServer? _server;
  int _active = 0;
  DateTime? _lastRequestAt;

  bool get isRunning => _server != null;
  int get activeCalls => _active;
  DateTime? get lastRequestAt => _lastRequestAt;
  String get endpoint => 'http://$host:$port/mcp';

  /// 幂等启动:已在运行直接成功。绑定失败返回原因。
  Future<McpHostStartResult> start() async {
    if (_server != null) return const McpHostStartResult.success();
    try {
      final server = await HttpServer.bind(
        InternetAddress(host),
        port,
        shared: false,
      );
      _server = server;
      unawaited(_serve(server));
      return const McpHostStartResult.success();
    } on SocketException catch (e) {
      // Windows 上 dart:io 会把 WSAEADDRINUSE 换成「shared flag」那句提示
      // (实测),所以判定占用不能只看 osError 码。
      final text = '$e';
      final occupied = e.osError?.errorCode == 10048 || // WSAEADDRINUSE
          text.contains('address already in use') ||
          text.contains('shared flag');
      final reason = occupied
          ? '端口 $port 已被占用(可能有两个 daro 实例在跑)。'
              '请在设置里换一个端口。'
          : '无法监听 $host:$port —— $e';
      return McpHostStartResult.failure(reason);
    } catch (e) {
      return McpHostStartResult.failure('无法监听 $host:$port —— $e');
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
    _notifyActivity();
  }

  Future<void> _serve(HttpServer server) async {
    try {
      await for (final request in server) {
        unawaited(_handleSafely(request));
      }
    } catch (_) {
      // close() 之后的 socket 噪音,忽略;app 侧按 isRunning 显示状态。
    }
  }

  Future<void> _handleSafely(HttpRequest request) async {
    try {
      await _handle(request);
    } catch (e) {
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'error': 'INTERNAL_ERROR',
            'message': '$e',
          }));
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _handle(HttpRequest request) async {
    _lastRequestAt = DateTime.now();
    final path = request.uri.path;
    if (path != '/mcp') {
      await _reply(request, HttpStatus.notFound, {'error': 'not found'});
      return;
    }

    // daro 自有健康探测(非 MCP 协议):设置页「重新检查」用。
    if (request.method == 'GET') {
      final accept = request.headers.value(HttpHeaders.acceptHeader) ?? '';
      if (accept.contains('text/event-stream')) {
        // 明确告知不提供 SSE 流,而非含糊 405,客户端据此回退 POST-only。
        request.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..headers.set('Allow', 'POST, GET')
          ..headers.set('X-Daro-Streams', 'none');
        await request.response.close();
        return;
      }
      await _reply(request, HttpStatus.ok, {
        'status': 'ok',
        'server': 'daro-mcp',
        'endpoint': endpoint,
        'activeCalls': _active,
        'lastRequestAt': _lastRequestAt?.toIso8601String(),
      });
      return;
    }

    if (request.method == 'OPTIONS') {
      // 原生客户端不发预检;浏览器类调试页会。只回方法列表,不放 CORS 头:
      // 任何浏览器脚本都不该被允许调本地 agent 通道。
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.set('Allow', 'POST, GET');
      await request.response.close();
      return;
    }

    if (request.method != 'POST') {
      request.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..headers.set('Allow', 'POST, GET');
      await request.response.close();
      return;
    }

    if (!_authorized(request)) {
      await _reply(request, HttpStatus.unauthorized, {
        'error': 'UNAUTHORIZED',
        'message': '缺少或错误的 Authorization: Bearer <token>。'
            '请在 daro 设置 → MCP 复制最新配置(token 轮换后旧值立即失效)',
      });
      return;
    }

    final body = await _readBody(request);
    if (body == null) {
      await _reply(request, HttpStatus.requestEntityTooLarge,
          {'error': 'PAYLOAD_TOO_LARGE'});
      return;
    }
    Object? parsed;
    try {
      parsed = jsonDecode(body);
    } catch (_) {
      await _replyJson(request, {
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': kJsonRpcParseError, 'message': 'JSON 解析失败'},
      });
      return;
    }

    _active++;
    _notifyActivity();
    try {
      if (parsed is List) {
        // JSON-RPC 批量:逐条处理,过滤通知的空响应。
        final responses = <Map<String, dynamic>>[];
        for (final item in parsed) {
          if (item is! Map) continue;
          final r = await handler.handle(Map<String, dynamic>.from(item));
          if (r != null) responses.add(r);
        }
        if (responses.isEmpty) {
          await _replyStatus(request, HttpStatus.accepted);
        } else {
          await _replyJson(request, responses);
        }
      } else if (parsed is Map) {
        final response =
            await handler.handle(Map<String, dynamic>.from(parsed));
        if (response == null) {
          await _replyStatus(request, HttpStatus.accepted); // 通知:202
        } else {
          await _replyJson(request, response);
        }
      } else {
        await _replyJson(request, {
          'jsonrpc': '2.0',
          'id': null,
          'error': {'code': kJsonRpcInvalidRequest, 'message': '需要 JSON 对象'},
        });
      }
    } finally {
      _active--;
      _notifyActivity();
    }
  }

  /// Bearer 校验(定长比较,防本机上的时序侧信道侦察 token 前缀)。
  bool _authorized(HttpRequest request) {
    if (token.isEmpty) return true;
    final header = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    const prefix = 'Bearer ';
    if (!header.startsWith(prefix)) return false;
    return _constantTimeEquals(
        Uint8List.fromList(utf8.encode(header.substring(prefix.length))),
        Uint8List.fromList(utf8.encode(token)));
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static const _maxBodyBytes = 2 * 1024 * 1024;

  /// 读请求体,超限返回 null(拒超大 body 打满内存)。
  static Future<String?> _readBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    var overflow = false;
    await for (final chunk in request) {
      // 必须把流读到结束再回 413:中途回错 = 半关 socket,客户端只会看到连接重置。
      // (也不能在这里对同一个流再 listen/drain:HTTP 输入流只允许一个订阅。)
      if (overflow) continue;
      builder.add(chunk);
      if (builder.length > _maxBodyBytes) {
        builder.clear();
        overflow = true;
      }
    }
    if (overflow) return null;
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<void> _reply(
      HttpRequest request, int status, Map<String, dynamic> json) async {
    await _replyStatus(request, status, body: jsonEncode(json));
  }

  Future<void> _replyJson(HttpRequest request, Object json) =>
      _replyStatus(request, HttpStatus.ok, body: jsonEncode(json));

  Future<void> _replyStatus(HttpRequest request, int status,
      {String? body}) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..headers.set('Cache-Control', 'no-store');
    if (body != null) request.response.write(body);
    await request.response.close();
  }

  void _notifyActivity() => onActivityChanged?.call(_active);
}
