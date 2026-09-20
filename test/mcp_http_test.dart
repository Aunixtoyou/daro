/// 协议层 + HTTP 宿主单测(简报 §6 W8:握手、鉴权、并发计数、SSE 缺席)。
///
/// 走真 socket(bind 到 127.0.0.1 的一个空闲端口),因为要验的恰恰是 socket
/// 层的行为:Bearer 定长比较、413 前把流读完、通知回 202、以及「不提供 SSE
/// 但要说清楚」。工具层自身在 `mcp_tools_test.dart` 已用假驱动钉死,
/// 这里只借它当被调用方。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daro/data/db_data.dart';
import 'package:daro/mcp/mcp_http_host.dart';
import 'package:daro/mcp/mcp_policy.dart';
import 'package:daro/mcp/mcp_pool.dart';
import 'package:daro/mcp/mcp_protocol.dart';
import 'package:daro/mcp/mcp_tools.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mcp_fakes.dart';

void main() {
  final hosts = <_Host>[];
  tearDown(() {
    while (hosts.isNotEmpty) {
      hosts.removeLast().dispose();
    }
  });

  group('JSON-RPC / MCP 握手', () {
    test('initialize 回显客户端协议版本,并声明只有 tools 能力', () async {
      final h = _Host(hosts);
      final res = await h.rpc('initialize', {
        'protocolVersion': '2025-03-26',
        'capabilities': {},
        'clientInfo': {'name': 'claude-code', 'version': '1.2.3'},
      });
      final result = res['result'] as Map;
      expect(result['protocolVersion'], '2025-03-26');
      expect(result['serverInfo'], {'name': 'daro-mcp', 'version': '0.5.1'});
      expect((result['capabilities'] as Map).keys, ['tools']);
      expect(result['instructions'] as String, contains('设置 → MCP'));
    });

    test('客户端报了别的版本:顺着它,不硬顶', () async {
      final h = _Host(hosts);
      final res = await h.rpc('initialize', {'protocolVersion': '2024-11-05'});
      expect((res['result'] as Map)['protocolVersion'], '2024-11-05');
    });

    test('未声明的能力(resources / prompts)回 -32601,而不是空结果', () async {
      final h = _Host(hosts);
      final res = await h.rpc('resources/list');
      expect(res['error']['code'], kJsonRpcMethodNotFound);
    });

    test('tools/list 只暴露当次策略放行的工具', () async {
      final h = _Host(hosts, policy: enabledPolicy(tools: ['daro_list_connections']));
      final res = await h.rpc('tools/list');
      final tools = res['result']['tools'] as List;
      expect(tools.map((t) => (t as Map)['name']), ['daro_list_connections']);

      // 策略改了不必重连:同一 handler 再问一次就是新名单。
      h.policy = enabledPolicy();
      final again = await h.rpc('tools/list');
      expect(again['result']['tools'] as List, hasLength(11));
    });

    test('tools/call 的成功与失败都走 result,失败带 isError + 四元组', () async {
      final h = _Host(hosts);
      final ok = await h.rpc('tools/call', {
        'name': 'daro_list_connections',
        'arguments': <String, dynamic>{},
      });
      expect(ok.containsKey('error'), isFalse);
      final result = ok['result'] as Map;
      expect(result['isError'], isFalse);
      final text = (result['content'] as List).first as Map;
      expect(text['type'], 'text');
      expect(jsonDecode(text['text'] as String), contains('connections'));
      expect(result['structuredContent'], isA<Map>());

      h.policy = enabledPolicy(enabled: false);
      final denied = await h.rpc('tools/call', {
        'name': 'daro_list_connections',
        'arguments': <String, dynamic>{},
      });
      expect(denied.containsKey('error'), isFalse,
          reason: '工具失败不是 JSON-RPC 错误,否则四元组会被客户端吞成一句 transport 错误');
      final deniedResult = denied['result'] as Map;
      expect(deniedResult['isError'], isTrue);
      final err = (deniedResult['structuredContent'] as Map)['error'] as Map;
      expect(err['code'], 'SERVICE_DISABLED');
      expect(err['hint'], isNotEmpty);
    });

    test('tools/call 缺 name:这才是真正的 JSON-RPC -32602', () async {
      final h = _Host(hosts);
      final res = await h.rpc('tools/call', {'arguments': {}});
      expect(res['error']['code'], kJsonRpcInvalidParams);
    });

    test('通知不回响应体(由 HTTP 侧翻译成 202)', () async {
      final h = _Host(hosts);
      expect(await h.handler.handle({'jsonrpc': '2.0', 'method': 'ping'}), isNull);
      expect(
          await h.handler.handle({
            'jsonrpc': '2.0',
            'method': 'notifications/initialized',
          }),
          isNull);
    });
  });

  group('HTTP 宿主', () {
    test('GET /mcp 是 daro 健康探测(不属于 MCP 协议)', () async {
      final h = _Host(hosts);
      final res = await h.send('GET', '/mcp');
      expect(res.status, 200);
      final body = res.json as Map;
      expect(body['status'], 'ok');
      expect(body['server'], 'daro-mcp');
      expect(body['activeCalls'], 0);
      expect(res.headers['cache-control'], 'no-store');
    });

    test('要求 SSE 流的客户端拿到 405 + 明确的缺席声明', () async {
      final h = _Host(hosts);
      final res = await h.send('GET', '/mcp', accept: 'text/event-stream');
      expect(res.status, 405);
      expect(res.headers['allow'], contains('POST'));
      expect(res.headers['x-daro-streams'], 'none');
    });

    test('预检不放行 CORS:浏览器脚本不得调本地 agent 通道', () async {
      final h = _Host(hosts);
      final res = await h.send('OPTIONS', '/mcp');
      expect(res.headers.containsKey('access-control-allow-origin'), isFalse);
      expect(res.headers['allow'], contains('POST'));
    });

    test('未知路径 404;其它方法 405', () async {
      final h = _Host(hosts);
      expect((await h.send('GET', '/health')).status, 404);
      expect((await h.send('PUT', '/mcp', body: '{}')).status, 405);
    });

    test('Bearer:配了 token 时缺头 / 差一个字符都 401,对了才 200', () async {
      final h = _Host(hosts, token: 'tk-1234567890');
      final missing = await h.post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'});
      expect(missing.status, 401);
      expect(missing.json['error'], 'UNAUTHORIZED');

      final wrong = await h.post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
          token: 'tk-123456789');
      expect(wrong.status, 401);

      final right = await h.post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
          token: 'tk-1234567890');
      expect(right.status, 200);
      expect(right.json['result'], isEmpty);
    });

    test('回环 + 空 token = 免鉴权(单机默认姿态)', () async {
      final h = _Host(hosts);
      final res = await h.post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'});
      expect(res.status, 200);
    });

    test('解析失败的报文回 -32700,而不是崩掉宿主', () async {
      final h = _Host(hosts);
      final res = await h.post('{not json');
      expect(res.status, 200);
      expect(res.json['error']['code'], kJsonRpcParseError);
      expect((await h.send('GET', '/mcp')).status, 200, reason: '宿主仍可用');
    });

    test('通知回 202 空体;批量请求回数组', () async {
      final h = _Host(hosts);
      final note = await h
          .post({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
      expect(note.status, 202);
      expect(note.body, isEmpty);

      final batch = await h.post([
        {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
        {'jsonrpc': '2.0', 'method': 'notifications/cancelled'},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
      ]);
      expect(batch.json, isA<List>());
      expect((batch.json as List).map((e) => (e as Map)['id']), [1, 2]);
    });

    test('超大 body 在未解析前就被拒(2MB 上限)', () async {
      final h = _Host(hosts);
      final huge = jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'daro_execute_query',
          'arguments': {'sql': 'x' * (2 * 1024 * 1024 + 1024)},
        },
      });
      final res = await h.post(huge);
      expect(res.status, 413);
      expect(res.json['error'], 'PAYLOAD_TOO_LARGE');
    });

    test('并发调用计数:in-flight 时健康探测能看到,结束后归零', () async {
      final h = _Host(hosts, policy: enabledPolicy(defaultMode: McpMode.full));
      final calls = <int>[];
      h.onActivity = calls.add;
      h.spy.tune = (d) => d.executeDelay = const Duration(milliseconds: 600);

      final pending = h.post({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'daro_execute_query',
          'arguments': {'connection': 'a', 'database': 'db_a', 'sql': 'SELECT 1'}
        },
      });
      await _waitUntil(() => calls.contains(1));
      expect(((await h.send('GET', '/mcp')).json as Map)['activeCalls'], 1);

      await pending;
      expect(((await h.send('GET', '/mcp')).json as Map)['activeCalls'], 0);
      expect(calls.last, 0);
    });

    test('端口被占用:启动失败并把原因原样交给设置页', () async {
      final a = _Host(hosts);
      await a.start();
      final b = McpHttpHost(
        handler: a.handler,
        host: '127.0.0.1',
        port: a.port,
        token: '',
      );
      final res = await b.start();
      expect(res.ok, isFalse);
      expect(res.error, contains('端口 ${a.port} 已被占用'));
      await b.stop();
      expect(a.host!.isRunning, isTrue, reason: '第二个宿主启动失败不能拖垮第一个');
    });

    test('start 幂等;stop 后不再监听', () async {
      final h = _Host(hosts);
      await h.start();
      expect((await h.host!.start()).ok, isTrue);
      await h.post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'});
      await h.host!.stop();
      expect(h.host!.isRunning, isFalse);
    });
  });
}

Future<void> _waitUntil(bool Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('等待条件超时');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _Reply {
  _Reply(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final String body;
  /// 解析后的响应体(空体为 null)。dynamic:测试里直接 `json['error']['code']` 取值。
  dynamic get json => body.isEmpty ? null : jsonDecode(body);
}

/// 跑在随机空闲端口上的宿主 + 客户端。`rpc` / `send` 都按需惰性启动,
/// 这样测试里先设 `onActivity` / `spy.tune` 再发请求是有效的。
class _Host {
  _Host(this._registry, {McpPolicy? policy, List<ConnectionInfo>? conns, String? token})
      : token = token ?? '' {
    if (policy != null) this.policy = policy;
    if (conns != null) this.conns = conns;
    pool = McpDriverPool(driverFactory: spy.call);
    service = McpToolService(McpToolDeps(
      loadPolicy: () async => this.policy,
      loadConnections: () async => this.conns,
      pool: pool,
    ));
    handler = McpProtocolHandler(
        tools: service, serverName: 'daro-mcp', serverVersion: '0.5.1');
    _registry.add(this);
  }

  final List<_Host> _registry;

  McpPolicy policy = enabledPolicy();
  List<ConnectionInfo> conns = [fakeConn('a')];
  final String token;

  final DriverFactorySpy spy = DriverFactorySpy();
  late final McpDriverPool pool;
  late final McpToolService service;
  late final McpProtocolHandler handler;

  McpHttpHost? host;
  void Function(int)? onActivity;
  final HttpClient _client = HttpClient();
  int _port = 0;

  int get port => _port;

  /// 惰性启动:先向系统要一个空闲端口,再让宿主去 bind。
  Future<void> start() async {
    if (host != null && host!.isRunning) return;
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = probe.port;
    await probe.close(force: true);
    final h = McpHttpHost(
      handler: handler,
      host: '127.0.0.1',
      port: _port,
      token: token,
      onActivityChanged: (n) => onActivity?.call(n),
    );
    final res = await h.start();
    expect(res.ok, isTrue, reason: res.error);
    host = h;
  }

  /// 发一条 JSON-RPC 报文并断言 HTTP 200,返回解析后的响应 map。
  Future<Map<String, dynamic>> rpc(String method, [Object? params]) async {
    final res = await post({
      'jsonrpc': '2.0',
      'id': 1,
      'method': method,
      if (params != null) 'params': params,
    });
    expect(res.status, 200, reason: res.body);
    return res.json as Map<String, dynamic>;
  }

  /// 原始 JSON-RPC 往返:[message] 为字符串时按原文发送(测坏 JSON / 超大 body)。
  /// [token] 为 null 表示**不发**鉴权头(与宿主自身的 token 无关),
  /// 这样「配了 token 却没带头」的场景才测得到。
  Future<_Reply> post(Object message, {String? token}) => raw(
        'POST',
        '/mcp',
        message is String ? message : jsonEncode(message),
        token: token,
      );

  Future<_Reply> send(String method, String path,
          {String? body, String? accept}) =>
      raw(method, path, body, accept: accept, token: token);

  Future<_Reply> raw(String method, String path, String? body,
      {String? token, String? accept}) async {
    await start();
    final req = await _client
        .openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    req.headers.contentType = ContentType.json;
    if (accept != null) req.headers.set(HttpHeaders.acceptHeader, accept);
    if (token != null && token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) req.write(body);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    final headers = <String, String>{};
    res.headers.forEach((name, values) => headers[name] = values.join(','));
    return _Reply(res.statusCode, headers, text);
  }

  void dispose() {
    _client.close(force: true);
    unawaited(host?.stop());
    unawaited(pool.dispose());
  }
}
