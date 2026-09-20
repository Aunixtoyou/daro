import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../theme/app_theme.dart';

/// 收一个连接分组名(新建 / 重命名共用),复用 base-ui 的 [InputDialog]。
///
/// 返回 null = 用户取消或没改(空名、与原同名);重名时弹错并返回 null,
/// 因为判重规则(大小写不敏感)只在 [AppState] 那边有权威列表,不在这层复制一份 UI。
/// 写库仍由调用方负责:`AppState.addGroup` / `renameGroup`。
Future<String?> promptGroupName(
  BuildContext context,
  AppState app, {
  required String title,
  String initial = '',
  String okText = '确定',
}) async {
  final typed = await InputDialog.show(
    context,
    title: title,
    message: '分组只有一层;连接可随时在分组之间移动。',
    initialValue: initial,
    okText: okText,
    tokens: Tokens.read(context).toDesktopTokens(),
  );
  if (typed == null) return null;
  final name = typed.trim();
  // 空名与「没改名」都不算一次操作:调用方按 null 直接放弃
  if (name.isEmpty || name == initial) return null;
  final duplicated = app.groupNames.any(
      (g) => g.toLowerCase() == name.toLowerCase() && g != initial);
  if (!duplicated) return name;
  if (context.mounted) {
    await MessageBox.show(
      context,
      title: title,
      message: '已存在同名分组「$name」(不区分大小写)。',
      type: MessageBoxType.error,
      okText: '知道了',
      tokens: Tokens.read(context).toDesktopTokens(),
    );
  }
  return null;
}
