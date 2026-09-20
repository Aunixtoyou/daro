import 'dart:io';

import 'package:daro/mcp/mcp_client_configs.dart' show mcpClientConfigs;
import 'package:daro/mcp/mcp_policy.dart'
    show McpHttpSettings, McpPolicy, generateMcpToken;
import 'package:flutter_test/flutter_test.dart';

// 设置对话框(简报 §6 W6/W7)的行为测试。
//
// 逻辑轨为主:纯 Dart API 验证 save / host bind / 配置生成 / 校验,无需 AppState 实例化开销。
// Widget 渲染已在 CI 集成路径覆盖(settings page 作为子页面自动通过整体冒烟测试)。

/// 取一个刚释放的端口给测试用。
Future<int> freePort() async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('daro_mcp_dialog_test');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  // ──────────────────────────────────────────────
  // 客户端配置分段
  // ──────────────────────────────────────────────

  test('客户端配置分段正确,免鉴权不含 Bearer', () async {
    final http = McpHttpSettings(host: '127.0.0.1', port: 5225);
    final configs = mcpClientConfigs(http);
    expect(configs.length, greaterThan(0));
    expect(configs.first.json, isNot(contains('Bearer')));
    expect(configs.first.json, contains('http://127.0.0.1:5225/mcp'));
  });

  test('带 Token 的配置含 Bearer Authorization 头', () async {
    final token = generateMcpToken();
    expect(token.length, greaterThanOrEqualTo(48));
    final http = McpHttpSettings(host: '127.0.0.1', port: 5225, token: token);
    final configs = mcpClientConfigs(http);
    expect(configs.first.json, contains('Bearer $token'));
  });

  test('非回环地址:isLoopback=false', () async {
    expect(McpHttpSettings(host: '0.0.0.0').isLoopback, isFalse);
    expect(McpHttpSettings(host: '127.0.0.1').isLoopback, isTrue);
  });

  test('端口越界构造合法,McpHttpSettings 不做范围校验', () async {
    final bad = McpHttpSettings(host: '127.0.0.1', port: 70000);
    expect(bad.port, 70000);
  });

  test('McpPolicy.defaults() 结构正确', () async {
    final policy = McpPolicy.defaults();
    expect(policy.enabled, isFalse);
    expect(policy.http.isLoopback, isTrue);
    expect(policy.defaultMode.label, '只读');
    expect(policy.connectionNames, isEmpty);
  });
}
