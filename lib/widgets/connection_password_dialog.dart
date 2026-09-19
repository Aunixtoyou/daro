import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';

import '../data/db_data.dart';

/// 密码窗口的回传结果:密码明文 + 是否落盘保存。
class ConnectionPasswordResult {
  const ConnectionPasswordResult(this.password, {required this.save});

  final String password;

  /// 勾选「保存密码」:写入本地连接配置,重启后无需再输
  final bool save;
}

/// 两种宿主(独立窗口 / 应用内弹窗)共用的文案，保证形态一致。
String connectionPasswordTitle(ConnectionInfo conn) =>
    '连接密码 - ${conn.name}';

String connectionPasswordPrompt(ConnectionInfo conn) =>
    '输入连接 "${conn.name}" 的密码。';

/// 表单宽度(逻辑像素):两种宿主同宽，子窗口据此量出自然高度再定窗口尺寸。
const double kConnectionPasswordFormWidth = 620;

/// 应用内宿主(遮罩弹窗):多窗口插件不可用时的回落形态。
class ConnectionPasswordDialog extends StatelessWidget {
  const ConnectionPasswordDialog({super.key, required this.conn});

  final ConnectionInfo conn;

  @override
  Widget build(BuildContext context) {
    return DialogBox(
      title: connectionPasswordTitle(conn),
      width: kConnectionPasswordFormWidth,
      onClose: () => Navigator.of(context).pop(),
      child: ConnectionPasswordForm(
        conn: conn,
        onSubmitted: (result) => Navigator.of(context).pop(result),
        onCancelled: () => Navigator.of(context).pop(),
      ),
    );
  }
}

/// 「连接密码」表单:回显主机与用户名,只需补录密码。
///
/// 无宿主依赖——独立系统窗口与应用内 [DialogBox] 都嵌它,
/// 提交 / 取消由调用方决定后续(关窗或 pop)。
class ConnectionPasswordForm extends StatefulWidget {
  const ConnectionPasswordForm({
    super.key,
    required this.conn,
    required this.onSubmitted,
    required this.onCancelled,
  });

  final ConnectionInfo conn;

  /// 密码非空时点「确定」/ 回车
  final ValueChanged<ConnectionPasswordResult> onSubmitted;

  /// 点「取消」
  final VoidCallback onCancelled;

  @override
  State<ConnectionPasswordForm> createState() => _ConnectionPasswordFormState();
}

class _ConnectionPasswordFormState extends State<ConnectionPasswordForm> {
  /// 标签列宽:信息行与密码输入框共用同一起始位置
  static const double _labelWidth = 210;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  bool _save = true;

  /// 空密码不允许提交:两种宿主都依赖「提交即有密码」这一契约
  bool _okEnabled = false;

  @override
  void initState() {
    super.initState();
    // 弹层/窗口路由动画结束后抢焦点,打开即可直接输入
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _confirm() {
    if (!_okEnabled) return;
    widget.onSubmitted(
        ConnectionPasswordResult(_controller.text, save: _save));
  }

  @override
  Widget build(BuildContext context) {
    final conn = widget.conn;
    final form = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Label(connectionPasswordPrompt(conn)),
        const SizedBox(height: 26),
        _infoRow('数据库主机:', '${conn.host}:${conn.port}'),
        _infoRow('用户名:', conn.username),
        _formRow(
          '密码:',
          Input(
            controller: _controller,
            focusNode: _focusNode,
            obscureText: true,
            obscureToggle: true,
            onChanged: (v) {
              final enabled = v.isNotEmpty;
              if (enabled != _okEnabled) {
                setState(() => _okEnabled = enabled);
              }
            },
            onSubmitted: (_) => _confirm(),
          ),
        ),
        const SizedBox(height: 10),
        _formRow(
          null,
          CheckBox(
            value: _save,
            label: '保存密码',
            onChanged: (v) => setState(() => _save = v ?? false),
          ),
        ),
        const SizedBox(height: 26),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Button(text: '确定', onPressed: _okEnabled ? _confirm : null),
            const SizedBox(width: 8),
            Button(text: '取消', onPressed: widget.onCancelled),
          ],
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      child: form,
    );
  }

  Widget _infoRow(String label, String value) =>
      _formRow(label, Label(value));

  /// 左标签 + 右内容两列布局(标签左对齐,与设计图一致)
  Widget _formRow(String? label, Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          children: [
            SizedBox(
              width: _labelWidth,
              child: label == null ? null : Label(label),
            ),
            Expanded(child: child),
          ],
        ),
      );
}
