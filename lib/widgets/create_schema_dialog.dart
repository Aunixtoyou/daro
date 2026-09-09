import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/app_state.dart';
import '../data/db_data.dart';
import '../theme/app_theme.dart';

/// 「新建模式」对话框:在指定库下输入模式名,执行真实的 CREATE SCHEMA。
///
/// 仅支持模式层的数据库类型(PostgreSQL / SQL Server)使用;
/// 底部实时预览将执行的 SQL;成功时 [Navigator.pop] 返回 true
/// (模式列表已由 [AppState.createSchema] 刷新),失败时弹窗内提示可重试。
class CreateSchemaDialog extends StatefulWidget {
  const CreateSchemaDialog({
    super.key,
    required this.connection,
    required this.database,
  });

  /// 目标连接
  final ConnectionInfo connection;

  /// 目标数据库(模式建在该库下)
  final String database;

  @override
  State<CreateSchemaDialog> createState() => _CreateSchemaDialogState();
}

class _CreateSchemaDialogState extends State<CreateSchemaDialog> {
  final _nameController = TextEditingController();
  final _focusNode = FocusNode();

  /// 创建是否进行中(防止重复提交)
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    // 弹窗打开后聚焦输入框
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 按类型引用模式名(与 AppState._ident 规则一致),供预览与提交共用
  String get _ident {
    final name = _nameController.text.trim();
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

  Future<void> _create() async {
    if (_creating) return;
    if (_nameController.text.trim().isEmpty) return;
    setState(() => _creating = true);

    final app = context.read<AppState>();
    final outcome = await app.createSchema(
      widget.connection,
      widget.database,
      _nameController.text,
    );
    if (!mounted) return;

    if (outcome.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _creating = false);
    MessageBox.show(
      context,
      title: '新建模式',
      message: '创建失败:\n${outcome.error}',
      type: MessageBoxType.error,
      okText: '知道了',
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return DialogBox(
      title: '新建模式',
      width: 460,
      onClose: () => Navigator.of(context).pop(),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Button(
            text: '取消',
            onPressed: _creating ? null : () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 8),
          Button(
            text: _creating ? '创建中...' : '创建',
            onPressed: _nameController.text.trim().isEmpty || _creating
                ? null
                : _create,
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
              '在数据库「${widget.database}」上创建新模式:',
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
                  hint: '模式名称',
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _create(),
                  textInputAction: TextInputAction.go,
                ),
              ),
            ),
            const SizedBox(height: 14),
            // SQL 实时预览(仅提示作用,实际执行走 AppState.createSchema)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: t.background,
                border: Border.all(color: t.border),
              ),
              child: Text(
                'CREATE SCHEMA $_ident',
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
