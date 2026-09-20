/// MCP 错误码契约(简报 §5.3,痛点 P1/P2/P3/P4/P5 的落点)。
///
/// 为什么单列:本仓的失败路径是**中文异常文本**
/// (`connection_manager.dart` 的 `UnsupportedError('暂不支持 …')`、驱动里的
/// 「连接超时(10 秒无响应)…」)。给人看很友好,给 agent 看是灾难 ——
/// 它读不出「该重试 / 该换连接 / 该问用户」,于是反复重试同一条死路。
/// MCP 侧一律输出 `{code, message, retryable, hint}` 四元组:
/// - `code` 是稳定契约(同 §5.2 工具清单,改名即破坏 agent 侧提示词);
/// - `message` 保留中文原文(对齐既有约定「中文提示保留原始堆栈」);
/// - `hint` 是给 agent 的下一步指令,写进工具 description 与错误响应两处。
///
/// ⚠️ 本文件禁止 import package:flutter(见 tool/check_mcp_purity.dart)。
library;

import 'mcp_policy.dart';

/// 线上错误码。`wire` 是 SCREAMING_SNAKE 稳定字符串,枚举顺序可变、wire 不可变。
enum McpErrorCode {
  connectionNotVisible(
    'CONNECTION_NOT_VISIBLE',
    hint: '该连接未授权给 MCP,请让用户在 设置 → MCP 中添加;不要换名重试',
  ),
  serviceDisabled(
    'SERVICE_DISABLED',
    hint: 'MCP 服务未在 daro 中启用,请让用户开启',
  ),
  driverUnsupported(
    'DRIVER_UNSUPPORTED',
    hint: 'daro 当前不支持该引擎的驱动,换 daro_list_connections 中 supported:true 的连接',
  ),
  passwordRequired(
    'PASSWORD_REQUIRED',
    hint: '请让用户在 daro 里打开该连接一次并勾选保存密码;'
        '绝不要尝试代传密码',
  ),
  databaseOutOfScope(
    'DATABASE_OUT_OF_SCOPE',
    hint: '该库不在允许范围内;先调 daro_list_databases 拿允许名单',
  ),
  modeDenied(
    'MODE_DENIED',
    hint: '当前执行模式档位不允许该操作;换只读语句,或让用户在 设置 → MCP 提高档位',
  ),
  whereTooBroad(
    'WHERE_TOO_BROAD',
    hint: '该 UPDATE/DELETE 无有效过滤条件(会全表生效);补上可收窄的 WHERE,'
        '或让用户切到完全访问档',
  ),
  toolNotAllowed(
    'TOOL_NOT_ALLOWED',
    hint: '该工具未开放;客户端可能缓存了旧工具列表,刷新 tools/list',
  ),
  queryTimeout(
    'QUERY_TIMEOUT',
    retryable: true,
    hint: '查询超时;若 cancelAttempted 为 false,服务端可能仍在执行,'
        '请勿立即重跑同一语句',
  ),
  cancelFailed(
    'CANCEL_FAILED',
    hint: '该驱动实例已销毁,重试会新建连接;本地文件库无法中途取消,'
        '请缩小查询范围',
  ),
  poolExhausted(
    'POOL_EXHAUSTED',
    retryable: true,
    hint: 'MCP 并发连接数达上限;等待 retryAfterMs 后重试,服务端不排队',
  ),
  connectionFailed(
    'CONNECTION_FAILED',
    retryable: true,
    hint: '握手/认证失败;区分「网络不可达」与「凭据错误」后告知用户,不要连续盲重试',
  ),
  invalidParams(
    'INVALID_PARAMS',
    hint: '参数缺失或格式不对;按工具 inputSchema 修正后重试',
  ),
  internal(
    'INTERNAL_ERROR',
    retryable: true,
    hint: 'daro 内部错误;可重试一次,仍失败就把错误反馈给用户',
  );

  const McpErrorCode(this.wire,
      {this.retryable = false, this.hint = '把完整错误反馈给用户处理'});

  /// 落线字符串(契约)。
  final String wire;

  /// 默认可重试性;个别场景(如 QUERY_TIMEOUT 看取消结果)会被显式覆盖。
  final bool retryable;

  /// 给 agent 的下一步建议。
  final String hint;
}

/// MCP 侧统一异常/错误载荷:宿主把它的字段直接序列化进错误响应。
class McpException implements Exception {
  McpException(
    this.code, {
    this.message = '',
    bool? retryable,
    this.retryAfterMs,
    this.details = const {},
  }) : retryable = retryable ?? code.retryable;

  McpException.invalidParams(String message)
      : this(McpErrorCode.invalidParams, message: message);

  McpException.internal(String message)
      : this(McpErrorCode.internal, message: message);

  final McpErrorCode code;

  /// 给人看的中文原文(含原始异常信息,不翻译不裁剪)。
  final String message;
  final bool retryable;

  /// POOL_EXHAUSTED 这类「稍后再试」的重试间隔提示。
  final int? retryAfterMs;

  /// 错误附带的结构化上下文:cancelAttempted / cancelReason / mode / rows 等。
  final Map<String, Object?> details;

  /// 四元组契约(§5.3):code / message / retryable / hint(+ 可选扩展位)。
  Map<String, dynamic> toJson() => {
        'code': code.wire,
        'message': message,
        'retryable': retryable,
        'hint': code.hint,
        if (retryAfterMs != null) 'retryAfterMs': retryAfterMs,
        ...details,
      };

  @override
  String toString() => '${code.wire}: $message';
}

/// 策略拒绝原因 → 线上错误码(§5.3 表的一一映射,不留默认放行)。
McpErrorCode mcpCodeForDeny(McpDenyReason reason) => switch (reason) {
      McpDenyReason.serviceDisabled => McpErrorCode.serviceDisabled,
      McpDenyReason.connectionNotVisible => McpErrorCode.connectionNotVisible,
      McpDenyReason.databaseOutOfScope => McpErrorCode.databaseOutOfScope,
      McpDenyReason.modeDenied => McpErrorCode.modeDenied,
      McpDenyReason.toolNotAllowed => McpErrorCode.toolNotAllowed,
      McpDenyReason.driverUnsupported => McpErrorCode.driverUnsupported,
      McpDenyReason.passwordRequired => McpErrorCode.passwordRequired,
      McpDenyReason.poolExhausted => McpErrorCode.poolExhausted,
    };

/// 把 [McpVerdict] 的拒绝转成异常(允许时返回 null)。
McpException? mcpExceptionForVerdict(McpVerdict verdict) {
  final reason = verdict.reason;
  if (reason == null) return null;
  final code = mcpCodeForDeny(reason);
  return McpException(code, message: reason.text);
}
