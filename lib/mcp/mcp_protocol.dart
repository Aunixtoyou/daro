/// MCP 协议层:JSON-RPC 2.0 + 握手(定稿 D2 自写薄层,零依赖)。
///
/// 支持的方法(Phase-1 无状态实现):
/// - `initialize` → protocolVersion / capabilities.tools / serverInfo;
/// - `notifications/initialized` → 202(无响应体);
/// - `ping` → {};
/// - `tools/list` → 按当次策略过滤的工具定义;
/// - `tools/call` → 委托 [McpToolService](错误全部收敛为 isError 结果,
///   agent 侧看到的仍是 §5.3 四元组)。
///
/// 有意**不实现**的东西(都写在这里,免得半年后当成遗漏):
/// - SSE 流(GET /mcp 返回 405):Phase-1 全是一次请求一个响应,
///   Streamable HTTP 客户端(Claude Code / Cursor / VS Code)按 POST-only 可用;
/// - 会话 id:`initialize` 不发 `Mcp-Session-Id`(规范允许无状态服务器),
///   也就不需要处理会话过期;
/// - resources / prompts 能力:声明为空,客户端不会尝试调用。
///
/// ⚠️ 本文件禁止 import package:flutter(见 tool/check_mcp_purity.dart)。
library;

import 'dart:convert';

import 'mcp_errors.dart';
import 'mcp_tools.dart';

/// JSON-RPC 2.0 标准错误码。
const int kJsonRpcParseError = -32700;
const int kJsonRpcInvalidRequest = -32600;
const int kJsonRpcMethodNotFound = -32601;
const int kJsonRpcInvalidParams = -32602;
const int kJsonRpcInternalError = -32603;

/// 我方对外声明并接受的协议版本(客户端提出其它已知版本时按客户端回显)。
const String kMcpProtocolVersion = '2025-03-26';

class McpProtocolHandler {
  McpProtocolHandler({
    required this.tools,
    required this.serverName,
    required this.serverVersion,
  });

  final McpToolService tools;
  final String serverName;
  final String serverVersion;

  /// 处理一条已经解析好的 JSON-RPC 消息。
  ///
  /// 返回 null 表示这是通知(无响应,HTTP 侧回 202);
  /// 否则返回 JSON-RPC response map(含 id)。[raw] 仅在解析失败回错误时用原文。
  Future<Map<String, dynamic>?> handle(Map<String, dynamic> message) async {
    final id = _idOf(message);
    final method = message['method'];
    if (method is! String) {
      return _error(id, kJsonRpcInvalidRequest, '缺少 method');
    }
    final isNotification = message['id'] == null;
    try {
      switch (method) {
        case 'initialize':
          final params = message['params'];
          final requested = params is Map
              ? (params['protocolVersion'] as String?)
              : null;
          return _result(id, {
            // 尽量顺着客户端:它报了版本就回显它,否则回我方默认。
            'protocolVersion':
                requested == null || requested.isEmpty ? kMcpProtocolVersion : requested,
            'capabilities': {
              'tools': const <String, dynamic>{},
            },
            'serverInfo': {'name': serverName, 'version': serverVersion},
            'instructions':
                'daro 桌面数据库管理工具的 MCP 服务。所有工具受 daro 内'
                '「设置 → MCP」策略约束(连接 allowlist / 执行模式 / 工具名单),'
                '策略每次调用实时生效。权限类错误请原样转达用户,不要重试或改名绕过。',
          });
        case 'notifications/initialized':
        case 'notifications/cancelled':
          return null; // 通知:确认收到即可
        case 'ping':
          return isNotification ? null : _result(id, {});
        case 'tools/list':
          return _result(id, {'tools': await tools.toolDefinitions()});
        case 'tools/call':
          return _result(id, await _callTool(message['params']));
        default:
          // resources/prompts/logging 等未声明能力:按规范回 Method not found。
          return _error(id, kJsonRpcMethodNotFound, '不支持的方法: $method');
      }
    } on McpException catch (e) {
      // 协议层能走到这里的只剩参数级错误(工具级错误已在 callTool 内收敛)。
      return isNotification
          ? null
          : _error(id, kJsonRpcInvalidParams, '${e.code.wire}: ${e.message}');
    } catch (e) {
      return isNotification ? null : _error(id, kJsonRpcInternalError, '$e');
    }
  }

  Future<Map<String, dynamic>> _callTool(Object? rawParams) async {
    final params = rawParams is Map ? rawParams : const {};
    final name = params['name'];
    if (name is! String || name.isEmpty) {
      throw McpException.invalidParams('tools/call 需要字符串参数 name');
    }
    final argsRaw = params['arguments'];
    final args = argsRaw is Map
        ? {for (final e in argsRaw.entries) '${e.key}': e.value}
        : <String, dynamic>{};
    final outcome = await tools.callTool(name, args);
    // MCP 约定:工具执行失败也用 result 承载(isError),不是 JSON-RPC error,
    // 否则多数客户端会把结构化四元组吞成一句 transport 错误。
    return {
      'content': [
        {
          'type': 'text',
          'text': const JsonEncoder.withIndent('  ').convert(outcome.payload),
        },
      ],
      'isError': outcome.isError,
      'structuredContent': outcome.payload,
    };
  }

  static Object? _idOf(Map<String, dynamic> m) {
    final id = m['id'];
    return (id is num || id is String) ? id : null;
  }

  static Map<String, dynamic> _result(Object? id, Map<String, dynamic> result) =>
      {'jsonrpc': '2.0', 'id': id, 'result': result};

  static Map<String, dynamic> _error(Object? id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };
}
