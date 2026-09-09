import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/app_state.dart';
import '../data/db_data.dart';
import '../theme/app_theme.dart';

/// 「编辑模式」对话框:重命名模式(ALTER SCHEMA 旧名 RENAME TO 新名)。
///
/// 仅 PostgreSQL 家族支持(菜单项已按类型过滤);底部实时预览将执行的 SQL;
/// 成功时 [Navigator.pop] 返回 true(模式列表已由 [AppState.renameSchema] 刷新),
/// 失败时弹窗内提示可重试。
class RenameSchemaDialog extends StatefulWidget {
  const RenameSchemaDialog({
    super.key,
    required this.connection,
    required this.database,
    required this.schema,
  });

  /// 目标连接
  final ConnectionInfo connection;

  /// 目标数据库(模式属于该库)
  final String database;

  /// 当前模式名(将被重命名)
  final String schema;

  @override
  State<RenameSchemaDialog> createState() => _RenameSchemaDialogState();
}

class _RenameSchemaDialogState extends State<RenameSchemaDialog> {
  final _nameController = TextEditingController();
  final _focusNode = FocusNode();

  /// 重命名是否进行中(防止重复提交)
  bool _renaming = false;

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.schema;
    // 弹窗打开后聚焦输入框并选中全名,便于直接输入新名
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

  /// 按类型引用模式名(与 AppState._ident 规则一致),供预览与提交共用
  String _identOf(String name) {
    final typeId = widget.connection.typeId;
    switch (typeId) {
      case 'postgresql':
        return '"${name.replaceAll('"', '""')}"';
      case 'sqlserver':
      case 'access':
        return '[${name.replaceAll(']', ']]')}]';
      default:
        return '`${name.replaceAll('`', '``')}`';
    }
  }

  Future<void> _rename() async {
    if (_renaming) return;
    final newName = _nameController.text.trim();
    if (newName.isEmpty || newName == widget.schema) return;
    setState(() => _renaming = true);

    final app = context.read<AppState>();
    final outcome = await app.renameSchema(
      widget.connection,
      widget.database,
      widget.schema,
      newName,
    );
    if (!mounted) return;

    if (outcome.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _renaming = false);
    MessageBox.show(
      context,
      title: '编辑模式',
      message: '重命名失败:\n${outcome.error}',
      type: MessageBoxType.error,
      okText: '知道了',
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final newName = _nameController.text.trim();
    return DialogBox(
      title: '编辑模式',
      width: 460,
      onClose: () => Navigator.of(context).pop(),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Button(
            text: '取消',
            onPressed: _renaming ? null : () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 8),
          Button(
            text: _renaming ? '保存中...' : '保存',
            onPressed: newName.isEmpty || newName == widget.schema || _renaming
                ? null
                : _rename,
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
              '将数据库「${widget.database}」中的模式「${widget.schema}」重命名为:',
              style: TextStyle(color: t.foreground, fontSize: 13),
            ),
            const SizedBox(height: 12),
            FieldRow(
              label: '模式名:',
              child: SizedBox(
                width: 260,
                child: Input(
                  controller: _nameController,
                  focusNode: _focusNode,
                  hint: '新模式名称',
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _rename(),
                  textInputAction: TextInputAction.go,
                ),
              ),
            ),
            const SizedBox(height: 14),
            // SQL 实时预览(仅提示作用,实际执行走 AppState.renameSchema)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: t.background,
                border: Border.all(color: t.border),
              ),
              child: Text(
                'ALTER SCHEMA ${_identOf(widget.schema)} '
                'RENAME TO ${_identOf(newName.isEmpty ? '_' : newName)}',
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontFamilyFallback: const ['monospace'],
                  fontSize: 12,
                  color: t.mutedForeground,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
