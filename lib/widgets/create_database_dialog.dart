import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/app_state.dart';
import '../data/db_create_options.dart';
import '../data/db_data.dart';
import '../theme/app_theme.dart';

/// 「新建数据库」对话框:按连接类型展示不同选项,执行真实的 CREATE DATABASE。
///
/// - MySQL / MariaDB:数据库名 + 字符集 + 排序规则
/// - PostgreSQL:数据库名 + 编码 + 模板 + 拥有者
/// - SQL Server:数据库名 + 排序规则(可空 = 服务器默认)
///
/// 底部实时预览将执行的 SQL;成功时 [Navigator.pop] 返回 true
/// (库列表已由 [AppState.createDatabase] 刷新),失败时弹窗内提示可重试。
class CreateDatabaseDialog extends StatefulWidget {
  const CreateDatabaseDialog({super.key, required this.connection});

  /// 目标连接
  final ConnectionInfo connection;

  @override
  State<CreateDatabaseDialog> createState() => _CreateDatabaseDialogState();
}

class _CreateDatabaseDialogState extends State<CreateDatabaseDialog> {
  final _nameController = TextEditingController();
  final _ownerController = TextEditingController();
  final _focusNode = FocusNode();

  /// 创建是否进行中(防止重复提交)
  bool _creating = false;

  String get _typeId => widget.connection.typeId;

  bool get _isMysqlLike => _typeId == 'mysql' || _typeId == 'mariadb';

  bool get _isPg => _typeId == 'postgresql';

  bool get _isSqlServer => _typeId == 'sqlserver';

  // MySQL / MariaDB
  late String _charset;
  late String _collation;

  // PostgreSQL
  late String _encoding;
  late String _template;

  // SQL Server('' = 服务器默认)
  String _sqlServerCollation = '';

  @override
  void initState() {
    super.initState();
    _charset = kMysqlCharsets.first;
    _collation = mysqlCollationsFor(_charset).first;
    _encoding = kPgEncodings.first;
    _template = kPgTemplates.last; // template1(默认)
    // 弹窗打开后聚焦输入框
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ownerController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 当前表单选项(供 SQL 预览与提交共用)
  CreateDatabaseOptions get _options => CreateDatabaseOptions(
        name: _nameController.text,
        charset: _isMysqlLike ? _charset : null,
        collation: _isMysqlLike
            ? _collation
            : (_isSqlServer ? _sqlServerCollation : null),
        encoding: _isPg ? _encoding : null,
        template: _isPg ? _template : null,
        owner: _isPg ? _ownerController.text : null,
      );

  /// 字符集变化:排序规则跟随切换到该字符集的首选
  void _onCharsetChanged(String charset) {
    setState(() {
      _charset = charset;
      _collation = mysqlCollationsFor(charset).first;
    });
  }

  /// 编码变化:非 UTF8 编码必须使用 template0 模板,自动切换并提示
  void _onEncodingChanged(String encoding) {
    setState(() {
      _encoding = encoding;
      if (encoding != 'UTF8' && _template == 'template1') {
        _template = 'template0';
      }
    });
  }

  Future<void> _create() async {
    if (_creating) return;
    if (_nameController.text.trim().isEmpty) return;
    setState(() => _creating = true);

    final app = context.read<AppState>();
    final outcome = await app.createDatabase(widget.connection, _options);
    if (!mounted) return;

    if (outcome.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _creating = false);
    MessageBox.show(
      context,
      title: '新建数据库',
      message: '创建失败:\n${outcome.error}',
      type: MessageBoxType.error,
      okText: '知道了',
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return DialogBox(
      title: '新建数据库',
      width: 500,
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
              '在连接「${widget.connection.name}」上创建新数据库:',
              style: TextStyle(color: t.foreground, fontSize: 13),
            ),
            const SizedBox(height: 14),
            FieldRow(
              label: '数据库名:',
              child: SizedBox(
                width: 280,
                child: Input(
                  controller: _nameController,
                  focusNode: _focusNode,
                  hint: '数据库名称',
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _create(),
                  textInputAction: TextInputAction.go,
                ),
              ),
            ),
            if (_isMysqlLike) ...[
              const SizedBox(height: 12),
              FieldRow(
                label: '字符集:',
                child: SizedBox(
                  width: 240,
                  child: ComboBox<String>(
                    items: kMysqlCharsets,
                    value: _charset,
                    onChanged: (v) {
                      if (v != null) _onCharsetChanged(v);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FieldRow(
                label: '排序规则:',
                child: SizedBox(
                  width: 240,
                  child: ComboBox<String>(
                    items: mysqlCollationsFor(_charset),
                    value: _collation,
                    onChanged: (v) {
                      if (v != null) setState(() => _collation = v);
                    },
                  ),
                ),
              ),
            ],
            if (_isPg) ...[
              const SizedBox(height: 12),
              FieldRow(
                label: '编码:',
                child: SizedBox(
                  width: 200,
                  child: ComboBox<String>(
                    items: kPgEncodings,
                    value: _encoding,
                    onChanged: (v) {
                      if (v != null) _onEncodingChanged(v);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FieldRow(
                label: '模板:',
                child: SizedBox(
                  width: 200,
                  child: ComboBox<String>(
                    items: kPgTemplates,
                    value: _template,
                    onChanged: (v) {
                      if (v != null) setState(() => _template = v);
                    },
                  ),
                ),
              ),
              if (_encoding != 'UTF8') ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 90),
                  child: Text(
                    '非 UTF8 编码必须使用 template0 模板',
                    style: TextStyle(fontSize: 11, color: t.mutedForeground),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FieldRow(
                label: '拥有者:',
                child: SizedBox(
                  width: 200,
                  child: Input(
                    controller: _ownerController,
                    hint: '默认当前用户',
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
            ],
            if (_isSqlServer) ...[
              const SizedBox(height: 12),
              FieldRow(
                label: '排序规则:',
                child: SizedBox(
                  width: 260,
                  child: ComboBox<String>(
                    items: kSqlServerCollations,
                    value: _sqlServerCollation,
                    onChanged: (v) {
                      if (v != null) setState(() => _sqlServerCollation = v);
                    },
                    itemToString: (v) =>
                        v.isEmpty ? '服务器默认' : v,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            _sqlPreview(t),
          ],
        ),
      ),
    );
  }

  /// SQL 实时预览(仅提示作用,实际执行走同一生成器)
  Widget _sqlPreview(AppPalette t) {
    final sql = buildCreateDatabaseSql(_typeId, _options);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: t.background,
        border: Border.all(color: t.border),
      ),
      child: Text(
        sql,
        style: TextStyle(
          fontFamily: 'Consolas',
          fontFamilyFallback: const ['monospace'],
          fontSize: 12,
          color: t.mutedForeground,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}
