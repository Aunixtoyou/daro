/// 客户端接入配置生成(简报 §6 W7 / 定稿 D8)。
///
/// 只做**生成与展示**:复制给人粘到客户端里。绝不代写第三方的配置文件
/// (DBX 同样只「检测和提示」;改别人的 config 属于越界,且各家格式会跟着上游变)。
///
/// ⚠️ 本文件禁止 import package:flutter(见 `tool/check_mcp_purity.dart`):
/// 输入只有 [McpHttpSettings],输出只有字符串,因此可以当纯函数单测。
library;

import 'dart:convert';

import 'mcp_policy.dart';

/// 一个客户端的配置片段。
class McpClientConfig {
  const McpClientConfig({
    required this.id,
    required this.label,
    required this.filePath,
    required this.json,
    required this.notes,
  });

  /// 稳定标识(测试快照与 Tab 选中态用它,不显示给用户)。
  final String id;

  /// 客户端名(界面上的选项文字)。
  final String label;

  /// 该配置放在哪个文件里(相对项目根的路径;没有固定文件的写「界面填写」)。
  final String filePath;

  /// 可直接复制的 JSON 正文。
  final String json;

  /// 一两句话的落地提示(放哪儿、要不要重启)。
  final List<String> notes;

  @override
  String toString() => '$label -> $filePath';
}

/// 各家客户端的配置。[http] 是当前监听设置:换了端口 / 轮换 token 后
/// 这里的结果随之变化,所以设置页每次显示都重新生成。
List<McpClientConfig> mcpClientConfigs(McpHttpSettings http) {
  final endpoint = http.endpoint;
  final servers = _serversBlock('http', endpoint, http.token);
  return [
    McpClientConfig(
      id: 'claude_code',
      label: 'Claude Code',
      filePath: '.mcp.json(项目根目录)',
      json: _encode({'mcpServers': servers}),
      notes: [
        '放在项目根目录的 .mcp.json,或在 Claude Code 里执行 /mcp 添加 HTTP 类型的服务。',
        '改端口或轮换 token 后要重新粘贴一次。',
      ],
    ),
    McpClientConfig(
      id: 'cursor',
      label: 'Cursor',
      filePath: '.cursor/mcp.json',
      json: _encode({'mcpServers': servers}),
      notes: [
        '项目级 .cursor/mcp.json;全局则在 Cursor 设置 → Tools/MCP 里粘贴同样的 JSON。',
        '保存后需要重开一次 MCP 面板才会重新拉取工具清单。',
      ],
    ),
    McpClientConfig(
      id: 'vscode',
      label: 'VS Code',
      filePath: '.vscode/mcp.json',
      // VS Code 的键名是 servers(不是 mcpServers),字段与 stdio 配置同源。
      json: _encode({'servers': servers, 'inputs': []}),
      notes: [
        '工作区 .vscode/mcp.json;首次会在编辑器里要求「允许」该服务。',
        '如果不想绑文件,也可以在 Copilot Chat 的 MCP 管理里手工添加。',
      ],
    ),
    McpClientConfig(
      id: 'qwen',
      label: '千问办公',
      filePath: '设置 → MCP 服务 → 自定义添加',
      // 千问办公「添加自定义 MCP」的 JSON 页只认 mcpServers 包裹 + streamable-http;
      // 平铺 name / type=streamableHttp 的形状导入不了。
      json: _encode({
        'mcpServers': {
          'daro': _server(endpoint, http.token, type: 'streamable-http'),
        },
      }),
      notes: [
        '在「添加自定义 MCP」的 JSON 页整段粘贴,导入后写入用户级 settings.json。',
        'daro 只监听回环地址时同机可用;跨机访问请在设置里绑地址并设置 Token。',
      ],
    ),
    McpClientConfig(
      id: 'generic',
      label: '通用 JSON',
      filePath: '任意支持 Streamable HTTP 的客户端',
      json: _encode({'mcpServers': {'daro': _server(endpoint, http.token)}}),
      notes: [
        '多数客户端认这个形状;不认时按它要求单独填 URL(即 ${http.endpoint})与请求头。',
        'daro 侧无需重启:策略与端口改动下一次调用即生效。',
      ],
    ),
  ];
}

Map<String, dynamic> _serversBlock(String type, String endpoint, String token) =>
    {'daro': _server(endpoint, token, type: type)};

Map<String, dynamic> _server(String endpoint, String token, {String type = 'http'}) =>
    {
      'type': type,
      'url': endpoint,
      // 回环 + 空 token = 免鉴权:那就别写一个空 Authorization 头,多数客户端会
      // 因为「带了个空认证头」直接判定握手失败。
      if (token.isNotEmpty) 'headers': {'Authorization': 'Bearer $token'},
    };

String _encode(Map<String, dynamic> json) =>
    const JsonEncoder.withIndent('  ').convert(json);
