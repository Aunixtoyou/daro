import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/app_state.dart';
import '../data/db_data.dart';
import '../theme/app_theme.dart';

/// 「复制 / 重命名表」对话框:输入新表名,提供两个动作。
///
/// - 复制:将当前表(结构 + 数据)克隆到新表名([AppState.copyTable])
/// - 重命名:原地更名([AppState.renameTable])
///
/// 成功后 [Navigator.pop] 返回 true(对象列表已由对应方法刷新);
/// 失败时在弹窗内提示,可修正后重试。
class TableCopyRenameDialog extends StatefulWidget {
  const TableCopyRenameDialog({
    super.key,
    required this.connection,
    required this.database,
    required this.tableName,
    this.schema,
  });

  /// 目标连接
  final ConnectionInfo connection;

  /// 所属数据库
  final String database;

  /// 被复制 / 重命名的原表名
  final String tableName;

  /// 所属模式(PostgreSQL / SQL Server 等;无模式层为 null)
  final String? schema;

  @override
  State<TableCopyRenameDialog> createState() => _TableCopyRenameDialogState();
}

class _TableCopyRenameDialogState extends State<TableCopyRenameDialog> {
  final _nameController = TextEditingController();
  final _focusNode = FocusNode();

  /// 操作进行中(防止重复提交)
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 预填原表名,用户在此基础上改成新名
    _nameController.text = widget.tableName;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
        _nameController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _nameController.text.length,
        );
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  String get _newName => _nameController.text.trim();

  bool get _canSubmit => _newName.isNotEmpty && _newName != widget.tableName;

  Future<void> _run(Future<dynamic> Function() action, String actionName) async {
    if (_busy || !_canSubmit) return;
    setState(() => _busy = true);
    final outcome = await action();
    if (!mounted) return;
    if (outcome.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _busy = false);
    MessageBox.show(
      context,
      title: actionName,
      message: '操作失败:\n${outcome.error}',
      type: MessageBoxType.error,
      okText: '知道了',
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final scope = widget.schema == null ? '' : ' (模式: ${widget.schema})';
    return DialogBox(
      title: '复制 / 重命名表',
      width: 460,
      onClose: () => Navigator.of(context).pop(),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Button(
            text: '取消',
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 8),
          // 复制:仅当新名与原名不同才可用
          Button(
            text: _busy ? '处理中...' : '复制',
            onPressed: _canSubmit && !_busy
                ? () => _run(
                      () => context.read<AppState>().copyTable(
                            widget.connection,
                            widget.database,
                            widget.tableName,
                            _newName,
                            schema: widget.schema,
                          ),
                      '复制表',
                    )
                : null,
          ),
          const SizedBox(width: 8),
          Button(
            text: '重命名',
            // 重命名会改变原表名:仅新名有效且不同时可用
            onPressed: _canSubmit && !_busy
                ? () => _run(
                      () => context.read<AppState>().renameTable(
                            widget.connection,
                            widget.database,
                            widget.tableName,
                            _newName,
                            schema: widget.schema,
                          ),
                      '重命名表',
                    )
                : null,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '连接「${widget.connection.name}」· 数据库「${widget.database}」$scope',
              style: TextStyle(color: t.foreground, fontSize: 13),
            ),
            const SizedBox(height: 14),
            FieldRow(
              label: '原表名:',
              child: SizedBox(
                width: 280,
                child: Text(
                  widget.tableName,
                  style: TextStyle(
                    fontSize: 13,
                    color: t.mutedForeground,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            FieldRow(
              label: '新表名:',
              child: SizedBox(
                width: 280,
                child: Input(
                  controller: _nameController,
                  focusNode: _focusNode,
                  hint: '输入新表名',
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _run(
                    () => context.read<AppState>().copyTable(
                          widget.connection,
                          widget.database,
                          widget.tableName,
                          _newName,
                          schema: widget.schema,
                        ),
                    '复制表',
                  ),
                  textInputAction: TextInputAction.go,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 84),
              child: Text(
                '「复制」克隆结构与数据到新表;「重命名」原地更名',
                style: TextStyle(fontSize: 11, color: t.mutedForeground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
