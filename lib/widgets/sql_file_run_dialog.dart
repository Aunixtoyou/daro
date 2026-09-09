import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../data/db_data.dart';
import '../data/sql_file_run.dart';
import '../theme/app_theme.dart';

/// 打开「运行 SQL 文件」对话框:把整个 .sql 脚本(通常是转储 / 还原文件)
/// 逐条执行到 [database]。[schema] 非空时限定该模式(PostgreSQL 家族)。
///
/// 由连接树的库 / 模式右键菜单调用,与「转储 SQL 文件」成对出现。
Future<void> showRunSqlFileDialog(
  BuildContext context, {
  required AppState app,
  required ConnectionInfo conn,
  required String database,
  String? schema,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => RunSqlFileDialog(
      app: app,
      connection: conn,
      database: database,
      schema: schema,
    ),
  );
}

/// 「运行 SQL 文件」对话框:选文件 → 执行选项 → 进度与错误明细。
///
/// 切分与执行全程流式(见 [runSqlFile]),几百 MB 的转储不会整体进内存。
class RunSqlFileDialog extends StatefulWidget {
  const RunSqlFileDialog({
    super.key,
    required this.app,
    required this.connection,
    required this.database,
    this.schema,
  });

  final AppState app;
  final ConnectionInfo connection;
  final String database;
  final String? schema;

  @override
  State<RunSqlFileDialog> createState() => _RunSqlFileDialogState();
}

class _RunSqlFileDialogState extends State<RunSqlFileDialog> {
  /// 结果文本色:业务色板按主题在 build 中刷新
  Color _warn = AppColors.light.iconWarning;
  Color _ok = AppColors.light.iconSuccess;

  final TextEditingController _pathController = TextEditingController();

  /// 错误明细用只读多行框承载:可整段选中复制,不必自造文本选择组件
  final TextEditingController _logController = TextEditingController();

  String _filePath = '';
  int _fileBytes = -1;

  /// 默认继续执行:转储里「表已存在」一类可容忍报错很多,停下来得不偿失
  bool _stopOnError = false;

  bool _running = false;
  bool _cancelRequested = false;
  SqlRunResult? _result;
  SqlRunProgress? _progress;

  @override
  void dispose() {
    _pathController.dispose();
    _logController.dispose();
    super.dispose();
  }

  bool get _hasPath => _filePath.isNotEmpty && _fileBytes >= 0;

  Future<void> _pickFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'SQL 文件', extensions: ['sql', 'txt']),
        XTypeGroup(label: '所有文件'),
      ],
      confirmButtonText: '打开',
    );
    final path = file?.path;
    if (path == null || !mounted) return;
    _pathController.text = path;
    _onPathChanged(path);
  }

  /// 路径变化后同步取一次文件大小:单次 stat 代价可忽略,却能让执行前
  /// 就显示转储体积,也顺带充当「文件可读」的校验
  void _onPathChanged(String path) {
    final trimmed = path.trim();
    var bytes = -1;
    if (trimmed.isNotEmpty) {
      try {
        final f = File(trimmed);
        if (f.existsSync()) bytes = f.lengthSync();
      } catch (_) {
        bytes = -1;
      }
    }
    setState(() {
      _filePath = trimmed;
      _fileBytes = bytes;
      _result = null;
      _progress = null;
      _logController.clear();
    });
  }

  Future<void> _start() async {
    if (_running || !_hasPath) return;
    setState(() {
      _running = true;
      _cancelRequested = false;
      _result = null;
      _progress = null;
      _logController.clear();
    });
    final result = await widget.app.executeSqlFile(
      conn: widget.connection,
      database: widget.database,
      schema: widget.schema,
      filePath: _filePath,
      stopOnError: _stopOnError,
      onProgress: (p) {
        if (!mounted) return;
        setState(() => _progress = p);
      },
      isCancelled: () => _cancelRequested,
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
      if (result.errors.isNotEmpty) {
        _logController.text = result.errors.join('\n\n');
      }
    });
  }

  String get _targetLabel => widget.schema == null
      ? '${widget.connection.name} / ${widget.database}'
      : '${widget.connection.name} / ${widget.schema}.${widget.database}';

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final colors = AppColors.of(context);
    _warn = colors.iconWarning;
    _ok = colors.iconSuccess;
    return DialogBox(
      title: '运行 SQL 文件',
      width: 660,
      height: 470,
      onClose: _running ? null : () => Navigator.of(context).pop(),
      footer: Row(
        children: [
          if (_running)
            Button(
              text: '停止',
              onPressed: () => setState(() => _cancelRequested = true),
            )
          else
            Button(text: '开始执行', onPressed: _hasPath ? _start : null),
          const SizedBox(width: 8),
          Button(
            text: _result != null && !_running ? '关闭' : '取消',
            onPressed: _running ? null : () => Navigator.of(context).pop(),
          ),
          const Spacer(),
          Text(_targetLabel, style: _hintStyle(t, color: t.mutedForeground)),
          const SizedBox(width: 8),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FieldRow(
              label: 'SQL 文件:',
              child: Row(
                children: [
                  Expanded(
                    child: Input(
                      controller: _pathController,
                      hint: '选择或直接粘贴 .sql 转储文件路径',
                      enabled: !_running,
                      onChanged: _onPathChanged,
                      onSubmitted: _onPathChanged,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Button(
                    text: '浏览...',
                    onPressed: _running ? null : _pickFile,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _fileLine(t),
            const SizedBox(height: 12),
            CheckBox(
              value: _stopOnError,
              onChanged: _running
                  ? null
                  : (v) => setState(() => _stopOnError = v ?? false),
              label: '遇到错误立即停止(默认忽略单条失败并继续)',
            ),
            const SizedBox(height: 4),
            Text(
              '转储中「表已存在」一类报错很常见,默认会继续执行后续语句;'
              '无论何时停止,已成功的语句都不会回滚。',
              style: _hintStyle(t, color: t.mutedForeground),
            ),
            const SizedBox(height: 14),
            _progressView(t),
            const SizedBox(height: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('错误明细', style: _hintStyle(t)),
                  const SizedBox(height: 4),
                  Expanded(
                    child: Textarea(
                      controller: _logController,
                      enabled: false,
                      expands: true,
                      hint: _result == null ? '尚未开始执行。' : '本次执行没有失败语句。',
                      style: TextStyle(
                        fontSize: 12,
                        color: t.foreground,
                        decoration: TextDecoration.none,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fileLine(AppPalette t) {
    if (_filePath.isEmpty) return Text('尚未选择文件。', style: _hintStyle(t));
    final name = _filePath.replaceAll(r'\', '/').split('/').last;
    return Text(
      _fileBytes < 0
          ? '$name —— 文件不存在或不可读'
          : '$name · ${_humanBytes(_fileBytes)}',
      style: _hintStyle(
        t,
        color: _fileBytes < 0 ? const Color(0xFFDC2626) : t.mutedForeground,
      ),
    );
  }

  Widget _progressView(AppPalette t) {
    final result = _result;
    final progress = _progress;
    final pct = result == null && progress != null && progress.totalBytes > 0
        ? progress.bytesDone / progress.totalBytes * 100
        : result != null
            ? (result.cancelled || result.fatalError != null ? 0.0 : 100.0)
            : 0.0;
    String message;
    Color color = t.mutedForeground;
    if (result != null) {
      final fatal = result.fatalError;
      if (fatal != null) {
        message = fatal;
        color = const Color(0xFFDC2626);
      } else if (result.cancelled) {
        message = '已停止:执行了 ${result.executed} 条语句'
            '(成功 ${result.succeeded} / 失败 ${result.failed}),已执行的部分未回滚。';
        color = _warn;
      } else if (result.stoppedOnError) {
        message = '遇错停止:执行了 ${result.executed} 条语句'
            '(成功 ${result.succeeded} / 失败 ${result.failed})。';
        color = _warn;
      } else {
        final extra = result.errors.length < result.failed
            ? ',错误仅列出前 ${result.errors.length} 条'
            : '';
        message = '执行完成:${result.executed} 条语句'
            '(成功 ${result.succeeded} / 失败 ${result.failed})$extra。';
        color = result.ok ? _ok : _warn;
      }
    } else if (progress == null) {
      message = _running ? '正在准备会话 ...' : '就绪。';
    } else {
      message = '已执行 ${progress.executed} 条(成功 ${progress.succeeded} / '
          '失败 ${progress.failed}):${progress.current}';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ProgressBar(value: pct.clamp(0.0, 100.0)),
        const SizedBox(height: 6),
        Row(
          children: [
            if (_running) ...[
              const Spinner(size: 14),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: _hintStyle(t, color: color),
              ),
            ),
          ],
        ),
      ],
    );
  }

  TextStyle _hintStyle(AppPalette t, {Color? color}) => TextStyle(
        fontSize: 12,
        color: color ?? t.foreground,
        decoration: TextDecoration.none,
        fontWeight: FontWeight.w400,
      );
}

/// 人类可读的文件大小(1 位小数),仅用于对话框回显
String _humanBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0 ? '$bytes B' : '${v.toStringAsFixed(1)} ${units[i]}';
}
