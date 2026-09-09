import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../data/csv_codec.dart';
import '../data/db_data.dart';
import '../data/db_export.dart';
import '../theme/app_theme.dart';

/// 打开「导出向导」:把一张表的数据导出为 CSV / SQL / JSON 文件。
///
/// 由对象面板工具栏、表右键菜单与表数据页「保存数据为」调用;
/// [conn] 必须是已建立的连接。[presetWhere] / [presetSortColumn] 由表数据页
/// 传入当前视图的筛选与排序,使导出结果与屏幕所见一致。
Future<void> showDataExportWizard(
  BuildContext context, {
  required AppState app,
  required ConnectionInfo conn,
  required String database,
  required String table,
  String? schema,
  String? presetWhere,
  String? presetSortColumn,
  bool presetSortAscending = true,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => DataExportWizard(
      app: app,
      connection: conn,
      database: database,
      table: table,
      schema: schema,
      presetWhere: presetWhere,
      presetSortColumn: presetSortColumn,
      presetSortAscending: presetSortAscending,
    ),
  );
}

/// 「导出向导」三步对话框:
/// 第 1 步 选择导出格式;第 2 步 该格式的选项;第 3 步 指定输出文件并执行。
///
/// 取数与写出全程流式(分页 + IOSink),大表不会把数据整体读进内存。
class DataExportWizard extends StatefulWidget {
  const DataExportWizard({
    super.key,
    required this.app,
    required this.connection,
    required this.database,
    required this.table,
    this.schema,
    this.presetWhere,
    this.presetSortColumn,
    this.presetSortAscending = true,
  });

  final AppState app;

  final ConnectionInfo connection;
  final String database;
  final String table;
  final String? schema;

  /// 来自表数据页当前视图的筛选 WHERE 片段(不含 WHERE 关键字);
  /// 为 null 表示整表导出
  final String? presetWhere;

  /// 来自表数据页当前视图的排序列;为 null 表示按主键/全列的稳定分页顺序
  final String? presetSortColumn;
  final bool presetSortAscending;

  @override
  State<DataExportWizard> createState() => _DataExportWizardState();
}

class _DataExportWizardState extends State<DataExportWizard> {
  static const _steps = ['源与格式', '导出选项', '输出文件'];

  /// 当前步骤(0..2)
  int _step = 0;

  // ── 格式与选项 ────────────────────────────────────────────
  DbExportFormat _format = DbExportFormat.csv;

  /// CSV 分隔符(单字符)
  String _delimiter = ',';

  /// CSV 中 NULL 的输出文本
  String _nullAs = '';
  bool _quoteAll = false;
  bool _withHeader = true;
  bool _bom = true;

  bool _dropStatement = false;
  bool _createStatement = true;
  int _insertBatchSize = 50;

  bool _prettyJson = false;

  /// 每次向数据库取数的行数
  int _pageSize = 2000;

  // ── 执行状态 ─────────────────────────────────────────────
  final TextEditingController _pathController = TextEditingController();

  /// 路径输入框内容是否仍是自动建议值(用户未手改、未通过「浏览」选择)
  bool _autoPath = true;
  bool _running = false;
  bool _cancelRequested = false;
  int _rowsDone = 0;
  int _totalRows = -1;
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

  /// 目标文件建议名:表名去掉路径非法字符 + 当前扩展名
  String get _suggestedFileName {
    final safe = widget.table.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return '$safe.${dbExportFormatExt(_format)}';
  }

  DelimitedStyle get _style =>
      DelimitedStyle(delimiter: _delimiter, nullAs: _nullAs);

  DbExportRequest get _request => DbExportRequest(
        format: _format,
        csv: _style,
        csvQuoteAll: _quoteAll,
        csvWithHeader: _withHeader,
        csvBom: _bom,
        sql: SqlExportOptions(
          dropStatement: _dropStatement,
          createStatement: _createStatement,
          insertBatchSize: _insertBatchSize,
        ),
        json: JsonExportOptions(pretty: _prettyJson),
        pageSize: _pageSize,
      );

  String get _filePath => _pathController.text.trim();

  bool get _canStart => !_running && _filePath.isNotEmpty;

  bool get _finished => _result != null && !_running;

  void _pickFile() async {
    final ext = dbExportFormatExt(_format);
    final location = await getSaveLocation(
      acceptedTypeGroups: [
        XTypeGroup(label: '${dbExportFormatLabel(_format)} 文件', extensions: [
          ext
        ]),
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

  Future<void> _start() async {
    if (!_canStart) return;
    final path = _filePath;
    setState(() {
      _running = true;
      _cancelRequested = false;
      _result = null;
      _rowsDone = 0;
      _totalRows = -1;
    });
    ExportResult result;
    try {
      result = await widget.app.exportTableData(
        conn: widget.connection,
        database: widget.database,
        table: widget.table,
        schema: widget.schema,
        filePath: path,
        request: _request,
        where: widget.presetWhere,
        sortColumn: widget.presetSortColumn,
        sortAscending: widget.presetSortAscending,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _rowsDone = done;
            _totalRows = total;
          });
        },
        isCancelled: () => _cancelRequested,
      );
    } catch (e) {
      result = ExportResult(rowsWritten: _rowsDone, error: e.toString());
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return DialogBox(
      title: '导出向导',
      width: 600,
      height: 440,
      onClose: () => Navigator.of(context).pop(),
      footer: Row(
        children: [
          Button(
            text: '< 上一步',
            onPressed: _step > 0 && !_running ? () => setState(() => _step--) : null,
          ),
          const SizedBox(width: 8),
          Button(
            text: '下一步 >',
            onPressed: _step < _steps.length - 1 && !_running
                ? () => setState(() => _step++)
                : null,
          ),
          const Spacer(),
          if (_running)
            Button(
              text: '停止',
              onPressed: () => setState(() => _cancelRequested = true),
            )
          else if (_step == _steps.length - 1)
            Button(
              text: _finished ? '关闭' : '开始导出',
              onPressed: _finished
                  ? () => Navigator.of(context).pop(true)
                  : (_canStart ? _start : null),
            ),
          const SizedBox(width: 8),
          Button(
            text: '取消',
            onPressed: _running ? null : () => Navigator.of(context).pop(),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: StepBar(steps: _steps, currentIndex: _step),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: switch (_step) {
                0 => _stepFormat(t),
                1 => _stepOptions(t),
                _ => _stepOutput(t),
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── 第 1 步:源与格式 ─────────────────────────────────────

  Widget _stepFormat(AppPalette t) {
    final db = widget.schema == null || widget.schema!.isEmpty
        ? widget.database
        : '${widget.database}.${widget.schema}';
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '导出表「${widget.table}」的数据',
            style: TextStyle(
              fontSize: 13,
              color: t.accent,
              fontWeight: FontWeight.w500,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 12),
          _infoRow(t, '连接', widget.connection.name),
          _infoRow(t, '数据库', db),
          _infoRow(t, '表', widget.table),
          if (widget.presetWhere != null)
            _infoRow(t, '筛选', widget.presetWhere!),
          if (widget.presetSortColumn != null)
            _infoRow(
                t,
                '排序',
                '${widget.presetSortColumn} ${widget.presetSortAscending ? '升序' : '降序'}'),
          const SizedBox(height: 18),
          FieldRow(
            label: '导出格式:',
            child: SizedBox(
              width: 260,
              child: ComboBox<DbExportFormat>(
                items: DbExportFormat.values,
                value: _format,
                itemToString: dbExportFormatLabel,
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _format = v;
                    // 路径仍是自动建议值时,跟随新格式的扩展名更新
                    if (_autoPath) _pathController.text = _suggestedFileName;
                    _result = null;
                  });
                },
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            switch (_format) {
              DbExportFormat.csv =>
                '逗号 / 分号 / 制表符分隔的纯文本,可用 Excel 直接打开。',
              DbExportFormat.sql =>
                '生成 INSERT 语句,可跨库回放;可选附带建表语句。',
              DbExportFormat.json =>
                '对象数组,每条记录一个对象,NULL 输出为 JSON null。',
            },
            style: TextStyle(fontSize: 12, color: t.mutedForeground),
          ),
        ],
      ),
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
                style: TextStyle(
                    fontSize: 12.5, color: t.mutedForeground),
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

  // ── 第 2 步:格式选项 ─────────────────────────────────────

  Widget _stepOptions(AppPalette t) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                    if (v != null) setState(() => _delimiter = v);
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
                    if (v != null) setState(() => _nullAs = v);
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            _check(t, '所有字段加引号', _quoteAll,
                (v) => setState(() => _quoteAll = v)),
            _check(t, '首行写入列名', _withHeader,
                (v) => setState(() => _withHeader = v)),
            _check(
                t,
                '写入 UTF-8 BOM(Excel 双击打开中文不乱码)',
                _bom, (v) => setState(() => _bom = v)),
          ],
          if (_format == DbExportFormat.sql) ...[
            _check(t, '包含建表语句(CREATE TABLE)', _createStatement,
                (v) => setState(() => _createStatement = v)),
            const SizedBox(height: 2),
            _check(
                t,
                '建表前先 DROP TABLE IF EXISTS',
                _dropStatement,
                (v) => setState(() => _dropStatement = v),
                enabled: _createStatement),
            const SizedBox(height: 10),
            FieldRow(
              label: '每条 INSERT:',
              child: SizedBox(
                width: 200,
                child: ComboBox<int>(
                  items: const [1, 10, 50, 100, 500],
                  value: _insertBatchSize,
                  itemToString: (v) => v == 1 ? '逐行 INSERT(1 行)' : '$v 行合并',
                  onChanged: (v) {
                    if (v != null) setState(() => _insertBatchSize = v);
                  },
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Access(ODBC)不支持多值 VALUES,导出时自动退化为逐行 INSERT。',
              style: TextStyle(fontSize: 12, color: t.mutedForeground),
            ),
          ],
          if (_format == DbExportFormat.json) ...[
            _check(t, '缩进美化(文件更大)', _prettyJson,
                (v) => setState(() => _prettyJson = v)),
          ],
          const SizedBox(height: 16),
          FieldRow(
            label: '分页行数:',
            child: SizedBox(
              width: 200,
              child: ComboBox<int>(
                items: const [500, 1000, 2000, 5000, 10000],
                value: _pageSize,
                itemToString: (v) => '$v 行 / 次',
                onChanged: (v) {
                  if (v != null) setState(() => _pageSize = v);
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.presetSortColumn == null
                ? '导出按主键排序分页(无主键时按全部列),保证大表不漏行、不重复。'
                : '导出沿用当前视图的排序,并以主键 / 全部列做同值行的兜底排序,保证不漏行、不重复。',
            style: TextStyle(fontSize: 12, color: t.mutedForeground),
          ),
        ],
      ),
    );
  }

  Widget _check(AppPalette t, String label, bool value,
      void Function(bool) onChanged,
      {bool enabled = true}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: CheckBox(
        value: value,
        enabled: enabled,
        onChanged: enabled ? (v) => onChanged(v ?? false) : null,
        label: label,
      ),
    );
  }

  // ── 第 3 步:输出文件与执行 ───────────────────────────────

  Widget _stepOutput(AppPalette t) {
    final result = _result;
    final pct = _totalRows > 0
        ? (_rowsDone / _totalRows * 100).clamp(0.0, 100.0)
        : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldRow(
          label: '输出文件:',
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  width: 300,
                  child: Input(
                    controller: _pathController,
                    enabled: !_running,
                    hint: '选择保存路径',
                    onChanged: (_) => setState(() => _autoPath = false),
                  ),
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
        const SizedBox(height: 10),
        _infoRow(t, '格式', dbExportFormatLabel(_format)),
        const SizedBox(height: 14),
        if (_running || result != null) ...[
          ProgressBar(value: pct),
          const SizedBox(height: 8),
          Text(
            result != null
                ? (result.error != null
                    ? '导出失败:${result.error}'
                    : '${result.cancelled ? '已取消,已写出' : '导出完成,共写出'} ${result.rowsWritten} 行')
                : '${_totalRows > 0 ? '已导出 $_rowsDone / $_totalRows 行' : '已导出 $_rowsDone 行'} ...',
            style: TextStyle(
              fontSize: 12.5,
              color: result != null && result.error != null
                  ? const Color(0xFFDC2626)
                  : t.mutedForeground,
            ),
          ),
          if (result != null && result.ok && result.rowsWritten == 0) ...[
            const SizedBox(height: 6),
            Text(
              '源表没有数据,已生成只含表头 / 语句的文件。',
              style: TextStyle(fontSize: 12, color: t.mutedForeground),
            ),
          ],
        ] else
          Text(
            '点击「开始导出」把表数据流式写入该文件;运行中可随时停止,已写出的内容保留。',
            style: TextStyle(fontSize: 12, color: t.mutedForeground),
          ),
      ],
    );
  }
}
