import 'dart:convert';

import 'package:daro/mcp/mcp_client_configs.dart';
import 'package:daro/mcp/mcp_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// 客户端配置片段是**给人复制出去**的东西:一处形状错了,对面客户端直接连不上,
/// 而且报错在人家那边 —— 所以这里钉死键名、鉴权头的有无、以及端点必须跟设置一致。
void main() {
  const loopback = McpHttpSettings(host: '127.0.0.1', port: 5225);
  const withToken =
      McpHttpSettings(host: '127.0.0.1', port: 5231, token: 'tk-abc');

  List<McpClientConfig> build([McpHttpSettings http = loopback]) =>
      mcpClientConfigs(http);

  Map<String, dynamic> parseOf(String id, [McpHttpSettings http = loopback]) =>
      jsonDecode(build(http).firstWhere((c) => c.id == id).json)
          as Map<String, dynamic>;

  group('清单本身', () {
    test('定稿 D8 的四个客户端 + 通用 JSON,顺序稳定', () {
      expect(build().map((c) => c.id),
          ['claude_code', 'cursor', 'vscode', 'qwen', 'generic']);
      expect(build().map((c) => c.label),
          containsAll(<String>['Claude Code', 'Cursor', 'VS Code', '千问办公']));
    });

    test('每段都有落点说明与提示,且 JSON 可解析', () {
      for (final c in build(withToken)) {
        expect(c.filePath, isNotEmpty, reason: c.id);
        expect(c.notes, isNotEmpty, reason: c.id);
        expect(jsonDecode(c.json), isA<Map<String, dynamic>>(), reason: c.id);
      }
    });
  });

  group('端点与鉴权', () {
    test('端点跟着设置走:换端口后所有片段都换新 URL', () {
      for (final c in build(const McpHttpSettings(port: 6100))) {
        expect(c.json, contains('http://127.0.0.1:6100/mcp'), reason: c.id);
        expect(c.json, isNot(contains('5225')));
      }
    });

    test('回环 + 空 token:不写 Authorization 头(空认证头会让握手失败)', () {
      final claude = parseOf('claude_code');
      final server =
          ((claude['mcpServers'] as Map)['daro'] as Map).cast<String, dynamic>();
      expect(server.containsKey('headers'), isFalse);
      for (final c in build()) {
        expect(c.json, isNot(contains('Bearer')));
      }
    });

    test('设了 token:每段都带 Bearer 头', () {
      for (final c in build(withToken)) {
        expect(c.json, contains('Bearer tk-abc'), reason: c.id);
      }
      final vscode = parseOf('vscode', withToken);
      final headers = (((vscode['servers'] as Map)['daro'] as Map)['headers']
          as Map);
      expect(headers['Authorization'], 'Bearer tk-abc');
    });
  });

  group('各家键名形状', () {
    test('Claude Code / Cursor 用 mcpServers,VS Code 用 servers', () {
      expect(parseOf('claude_code').keys, ['mcpServers']);
      expect(parseOf('cursor').keys, ['mcpServers']);
      expect(parseOf('vscode').keys, ['servers', 'inputs']);
    });

    test('HTTP 类型标出来:agent 据此走 Streamable HTTP 而不是 stdio 命令', () {
      expect(
          ((parseOf('claude_code')['mcpServers'] as Map)['daro'] as Map)['type'],
          'http');
      expect(
          ((parseOf('vscode')['servers'] as Map)['daro'] as Map)['type'], 'http');
      expect(parseOf('generic')['mcpServers'], isNotNull);
    });

    test('千问办公要 mcpServers 包裹 + streamable-http(对话框 JSON 页的形状)', () {
      final qwen = parseOf('qwen', withToken);
      expect(qwen.keys, ['mcpServers']);
      final server =
          ((qwen['mcpServers'] as Map)['daro'] as Map).cast<String, dynamic>();
      expect(server['type'], 'streamable-http');
      expect(server['url'], 'http://127.0.0.1:5231/mcp');
      expect(server['headers'], {'Authorization': 'Bearer tk-abc'});
    });
  });
}
