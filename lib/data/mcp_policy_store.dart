import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../mcp/mcp_policy.dart';

/// MCP 策略持久化:存为应用支持目录下的 `mcp_policy.json`。
///
/// 与 [ConnectionStore] 同构(同目录、同样全量覆写、同样「文件坏掉不阻止启动」),
/// 但有一条**关键差异**:MCP 宿主每次请求都重新 `load()` 本文件,不在内存里缓存。
/// 这是定稿语义 —— 用户在 daro 里收紧权限后,不必重启 MCP 客户端就立即生效
/// (对齐 DBX「策略在每次请求时重新读取」)。
///
/// 文件结构:
/// ```json
/// {
///   "schemaVersion": 1,
///   "enabled": false,
///   "defaultMode": "readonly",
///   "connectionScopeAll": true,
///   "connections": [ { "connection": "local-pg", "mode": "readWrite",
///                      "databaseScope": { "all": false, "include": ["app"] } } ],
///   "http": { "host": "127.0.0.1", "port": 5225, "token": "…" }
/// }
/// ```
class McpPolicyStore {
  static const _fileName = 'mcp_policy.json';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// 读取策略;文件不存在 / 非对象 / 损坏时返回**默认策略**(关闭 + 只读)。
  Future<McpPolicy> load() async => (await loadWithStatus()).policy;

  /// 带状态读取:设置页据此显示「策略文件已损坏,已按默认值运行」的降级告警,
  /// 而不是让应用启动失败。
  Future<McpPolicyWithStatus> loadWithStatus() async {
    try {
      final file = await _file();
      if (!await file.exists()) {
        return const McpPolicyWithStatus(
            policy: McpPolicy.defaults(), status: McpPolicyLoadStatus.missing);
      }
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) {
        return const McpPolicyWithStatus(
            policy: McpPolicy.defaults(), status: McpPolicyLoadStatus.corrupted);
      }
      return McpPolicyWithStatus(
        policy: McpPolicy.fromJson(json),
        status: McpPolicyLoadStatus.ok,
      );
    } catch (_) {
      // 配置文件损坏不应阻止应用启动,按「未启用」处理。
      return const McpPolicyWithStatus(
          policy: McpPolicy.defaults(), status: McpPolicyLoadStatus.corrupted);
    }
  }

  /// 全量覆写保存(与 `ConnectionStore.save` 一致:整文件写 + flush)。
  Future<void> save(McpPolicy policy) async {
    final file = await _file();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(policy.toJson()),
      flush: true,
    );
  }
}

enum McpPolicyLoadStatus {
  /// 正常读取。
  ok,

  /// 文件不存在(首次启动即此场景,不算异常)。
  missing,

  /// 文件存在但解析失败 —— 界面需给出降级告警。
  corrupted;

  bool get isHealthy => this == ok || this == missing;
}

/// 读取结果:策略 + 来源状态。
class McpPolicyWithStatus {
  const McpPolicyWithStatus({required this.policy, required this.status});

  final McpPolicy policy;
  final McpPolicyLoadStatus status;
}
