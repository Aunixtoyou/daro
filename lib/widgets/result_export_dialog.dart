import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../data/csv_codec.dart';
import '../data/db_export.dart';
import '../data/drivers/db_driver.dart';
import '../theme/app_theme.dart';

/// 结果集导出错误提示色(功能强调色,主题无关)
const _errorColor = Color(0xFFDC2626);

/// 打开「导出结果」对话框:把一份已在内存中的结果集写为 CSV / JSON 文件。
///
/// 与「导出向导」的分工:向导面向**服务端分页的大表**(需要进度与取消),
/// 本对话框面向**已经取回的数据**(查询页结果网格),数据量受结果行数上限
/// 约束,一次写完即可,因此不提供进度 / 停止。
/// [label] 用作建议文件名与 SQL 目标标识(仅 CSV / JSON 可选,不会生成 INSERT)。
Future<void> showExportResultDialog(
  BuildContext context, {
  required TablePreview data,
  required String typeId,
  required String database,
  required String label,
  String? schema,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ResultExportDialog(
      data: data,
      typeId: typeId,
      database: database,
      label: label,
      schema: schema,
    ),
  );
}

/// 「导出结果」对话框:格式 + 该格式选项 + 输出文件,单页布局。
class ResultExportDialog extends StatefulWidget {
  const ResultExportDialog({
    super.key,
    required this.data,
    required this.typeId,
    required this.database,
    required this.label,
    this.schema,
  });

  final TablePreview data;
  final String typeId;
  final String database;
  final String? schema;

  /// 建议文件名(不含扩展名),通常是查询标签标题或表名
  final String label;

  @override
  State<ResultExportDialog> createState() => _ResultExportDialogState();
}

class _ResultExportDialogState extends State<ResultExportDialog> {
  /// 结果集没有目标表,SQL(INSERT) 会凭空造表名,故只提供两种文本格式
  static const _formats = [DbExportFormat.csv, DbExportFormat.json];

  DbExportFormat _format = DbExportFormat.csv;

  String _delimiter = ',';
  String _nullAs = '';
  bool _quoteAll = false;
  bool _withHeader = true;
  bool _bom = true;
  bool _prettyJson = false;

  final TextEditingController _pathController = TextEditingController();

  /// 路径是否仍是自动建议值(用户未手改、未通过「浏览」选择)
  bool _autoPath = true;
  bool _busy = false;
  ExportResult? _result;

  @override
  void initState() {
    super.initState();
    _pathController.text = _suggestedFileName;
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  String get _safeLabel {
    final safe = widget.label.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return safe.isEmpty ? 'result' : safe;
  }

  String get _suggestedFileName => '$_safeLabel.${dbExportFormatExt(_format)}';

  DbExportRequest get _request => DbExportRequest(
        format: _format,
        csv: DelimitedStyle(delimiter: _delimiter, nullAs: _nullAs),
        csvQuoteAll: _quoteAll,
        csvWithHeader: _withHeader,
        csvBom: _bom,
        json: JsonExportOptions(pretty: _prettyJson),
        // 数据已在内存:一页写完,pageSize 取行数上限避免引擎再回调取数
        pageSize: widget.data.rows.isEmpty ? 1 : widget.data.rows.length,
      );

  String get _filePath => _pathController.text.trim();

  bool get _canRun => !_busy && _filePath.isNotEmpty;

  bool get _finished => _result != null && !_busy;

  /// 实际写入的绝对路径(裸文件名会落到进程工作目录,摘要里必须显示全路径)
  String? _writtenTo;

  void _pickFile() async {
    final location = await getSaveLocation(
      acceptedTypeGroups: [
        XTypeGroup(
          label: '${dbExportFormatLabel(_format)} 文件',
          extensions: [dbExportFormatExt(_format)],
        ),
      ],
      suggestedName: _suggestedFileName,
      confirmButtonText: '保存',
    );
    final path = location?.path;
    if (path == null || !mounted) return;
    setState(() {
      _pathController.text = path;
      _autoPath = false;
      _result = null;
    });
  }

  Future<void> _run() async {
    if (!_canRun) return;
    final path = _filePath;
    setState(() {
      _busy = true;
      _result = null;
    });
    ExportResult result;
    final absolute = File(path).absolute.path;
    try {
      result = await exportRows(
        target: ExportTarget(
          typeId: widget.typeId,
          database: widget.database,
          schema: widget.schema,
          table: widget.label,
        ),
        request: _request,
        data: widget.data,
        filePath: absolute,
      );
    } catch (e) {
      // 打开 / 写入文件失败(路径非法、磁盘只读)发生在引擎的 try 之外
      result = ExportResult(rowsWritten: 0, error: e.toString());
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _writtenTo = absolute;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return DialogBox(
      title: '导出结果',
      width: 540,
      height: 420,
      onClose: _busy ? null : () => Navigator.of(context).pop(),
      footer: Row(
        children: [
          const Spacer(),
          Button(
            text: _finished ? '关闭' : '导出',
            onPressed: _finished
                ? () => Navigator.of(context).pop()
                : (_canRun ? _run : null),
          ),
          const SizedBox(width: 8),
          Button(
            text: '取消',
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '导出 ${widget.data.columns.length} 列 × ${widget.data.rows.length} 行结果',
                style: TextStyle(
                  fontSize: 13,
                  color: t.accent,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 12),
              _infoRow(t, '数据库', _databaseLabel()),
              const SizedBox(height: 14),
              FieldRow(
                label: '导出格式:',
                child: SizedBox(
                  width: 240,
                  child: ComboBox<DbExportFormat>(
                    items: _formats,
                    value: _format,
                    itemToString: dbExportFormatLabel,
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() {
                        _format = v;
                        if (_autoPath) {
                          _pathController.text = _suggestedFileName;
                        }
                        _result = null;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                switch (_format) {
                  DbExportFormat.csv =>
                    '逗号 / 分号 / 制表符分隔的纯文本,可用 Excel 直接打开。',
                  DbExportFormat.json =>
                    '对象数组,每条记录一个对象;结果集没有目标表,故不提供 SQL。',
                  DbExportFormat.sql => '',
                },
                style: TextStyle(fontSize: 12, color: t.mutedForeground),
              ),
              const SizedBox(height: 12),
              if (_format == DbExportFormat.csv) ...[
                FieldRow(
                  label: '分隔符:',
                  child: SizedBox(
                    width: 200,
                    child: ComboBox<String>(
                      items: const [',', ';', '\t', '|'],
                      value: _delimiter,
                      itemToString: DelimitedStyle.delimiterLabel,
                      onChanged: (v) {
                        if (v != null) {
                          setState(() {
                            _delimiter = v;
                            _result = null;
                          });
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                FieldRow(
                  label: 'NULL 文本:',
                  child: SizedBox(
                    width: 200,
                    child: ComboBox<String>(
                      items: const ['', r'\N', 'NULL'],
                      value: _nullAs,
                      itemToString: (v) => v.isEmpty ? '空字符串' : v,
                      onChanged: (v) {
                        if (v != null) {
                          setState(() {
                            _nullAs = v;
                            _result = null;
                          });
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _check('所有字段加引号', _quoteAll, (v) => _quoteAll = v),
                _check('首行写入列名', _withHeader, (v) => _withHeader = v),
                _check('写入 UTF-8 BOM(Excel 双击打开中文不乱码)', _bom,
                    (v) => _bom = v),
              ] else
                _check('缩进美化(文件更大)', _prettyJson, (v) => _prettyJson = v),
              const SizedBox(height: 16),
              FieldRow(
                label: '输出文件:',
                child: Row(
                  children: [
                    Expanded(
                      child: Input(
                        controller: _pathController,
                        enabled: !_busy,
                        hint: '选择保存路径',
                        onChanged: (_) => setState(() {
                          _autoPath = false;
                          _result = null;
                        }),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Button(
                      text: '浏览...',
                      onPressed: _busy ? null : _pickFile,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (_busy || _result != null) _statusLine(t),
            ],
          ),
        ),
      ),
    );
  }

  String _databaseLabel() {
    final schema = widget.schema;
    if (schema == null || schema.isEmpty) return widget.database;
    return '${widget.database}.$schema';
  }

  Widget _statusLine(AppPalette t) {
    final r = _result;
    if (r == null) {
      return Text(
        '正在写出文件 ...',
        style: TextStyle(fontSize: 12.5, color: t.mutedForeground),
      );
    }
    if (r.error != null) {
      return Text(
        '导出失败:${r.error}',
        style: const TextStyle(fontSize: 12.5, color: _errorColor),
      );
    }
    return Text(
      '已导出 ${r.rowsWritten} 行到\n${_writtenTo ?? _filePath}',
      style: TextStyle(fontSize: 12.5, color: t.mutedForeground),
    );
  }

  Widget _infoRow(AppPalette t, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 70,
              child: Text(
                '$label:',
                style:
                    TextStyle(fontSize: 12.5, color: t.mutedForeground),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: TextStyle(fontSize: 12.5, color: t.foreground),
              ),
            ),
          ],
        ),
      );

  Widget _check(String label, bool value, void Function(bool) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: CheckBox(
        value: value,
        onChanged: (v) => setState(() {
          onChanged(v ?? false);
          _result = null;
        }),
        label: label,
      ),
    );
  }
}
