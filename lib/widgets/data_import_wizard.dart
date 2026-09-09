import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../data/csv_codec.dart';
import '../data/db_data.dart';
import '../data/db_import.dart';
import '../data/drivers/db_driver.dart';
import '../theme/app_theme.dart';

/// 打开「导入向导」:把 CSV / JSON 文件导入一张**已存在**的表。
///
/// 由对象面板工具栏与表右键菜单调用;目标表 [table] 由当前选中项决定。
Future<void> showDataImportWizard(
  BuildContext context, {
  required AppState app,
  required ConnectionInfo conn,
  required String database,
  required String table,
  String? schema,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => DataImportWizard(
      app: app,
      connection: conn,
      database: database,
      table: table,
      schema: schema,
    ),
  );
}

/// 「导入向导」三步对话框:
/// 第 1 步 选文件并设定解析方式(CSV 分隔符 / 表头 / 跳行);
/// 第 2 步 源列 → 目标列映射(同名自动匹配,可手工调整);
/// 第 3 步 写入选项与执行(按文件字节数显示进度,可中途停止)。
///
/// 解析与写入均为流式:边读文件边攒批 INSERT,大文件不会整体载入内存。
class DataImportWizard extends StatefulWidget {
  const DataImportWizard({
    super.key,
    required this.app,
    required this.connection,
    required this.database,
    required this.table,
    this.schema,
  });

  final AppState app;
  final ConnectionInfo connection;
  final String database;
  final String table;
  final String? schema;

  @override
  State<DataImportWizard> createState() => _DataImportWizardState();
}

class _DataImportWizardState extends State<DataImportWizard> {
  static const _steps = ['源文件', '字段映射', '执行导入'];

  /// 警示文本色:业务色板 [AppColors.iconWarning],按主题在 build 中刷新
  Color _warn = AppColors.light.iconWarning;

  /// 当前步骤(0..2)
  int _step = 0;

  // ── 解析选项 ─────────────────────────────────────────────
  DbImportFormat _format = DbImportFormat.csv;
  String _delimiter = ',';
  bool _hasHeader = true;
  int _skipRows = 0;
  bool _trimFields = false;

  // ── 写入选项 ─────────────────────────────────────────────
  bool _emptyAsNull = true;
  int _batchSize = 200;
  bool _truncateFirst = false;

  // ── 解析结果 ─────────────────────────────────────────────
  final TextEditingController _pathController = TextEditingController();
  String _filePath = '';
  ImportSource? _source;
  List<ColumnDef> _columns = const [];

  /// 与 [_columns] 等长的源列下标,-1 表示该目标列不参与导入
  List<int> _map = const [];
  bool _loading = false;
  String? _loadError;

  // ── 执行状态 ─────────────────────────────────────────────
  bool _running = false;
  bool _cancelRequested = false;
  int _rowsDone = 0;
  int _bytesDone = 0;
  int _totalBytes = -1;
  ImportResult? _result;

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  /// JSON 对象数组的键序列就是隐式表头,因此始终按「有表头」处理
  bool get _effectiveHasHeader =>
      _format == DbImportFormat.json ? true : _hasHeader;

  DbImportRequest get _request => DbImportRequest(
        format: _format,
        style: DelimitedStyle(delimiter: _delimiter),
        hasHeader: _effectiveHasHeader,
        skipRows: _skipRows,
        trimFields: _trimFields,
        emptyAsNull: _emptyAsNull,
        batchSize: _batchSize,
        truncateFirst: _truncateFirst,
      );

  int get _mappedCount => _map.where((i) => i >= 0).length;

  bool get _readyToMap => _source != null && _columns.isNotEmpty;

  /// 目标表非空列且未映射:导入大概率会失败,给出提示
  List<String> get _riskyColumns {
    final out = <String>[];
    for (var i = 0; i < _columns.length; i++) {
      final c = _columns[i];
      if (!c.nullable && (i >= _map.length || _map[i] < 0)) out.add(c.name);
    }
    return out;
  }

  bool get _canNext => switch (_step) {
        0 => _readyToMap && !_loading,
        1 => _mappedCount > 0,
        _ => false,
      };

  bool get _finished => _result != null && !_running;

  Future<void> _pickFile() async {
    final groups = _format == DbImportFormat.json
        ? [const XTypeGroup(label: 'JSON 文件', extensions: ['json'])]
        : [
            const XTypeGroup(
                label: 'CSV / 文本文件', extensions: ['csv', 'txt', 'tsv']),
          ];
    final file = await openFile(
      acceptedTypeGroups: [...groups, const XTypeGroup(label: '所有文件')],
      confirmButtonText: '打开',
    );
    final path = file?.path;
    if (path == null || !mounted) return;
    _pathController.text = path;
    setState(() => _filePath = path);
    await _analyze();
  }

  /// 采样源文件 + 读取目标表结构,并自动做一次同名映射
  Future<void> _analyze() async {
    if (_filePath.isEmpty) return;
    setState(() {
      _loading = true;
      _loadError = null;
      _source = null;
      _result = null;
    });
    try {
      final results = await Future.wait([
        readImportSample(_filePath, _request),
        widget.app.connectionManager.describeTable(
          widget.connection,
          widget.database,
          widget.table,
          schema: widget.schema,
        ),
      ]);
      if (!mounted) return;
      final source = results[0] as ImportSource;
      final columns = results[1] as List<ColumnDef>;
      setState(() {
        _source = source;
        _columns = columns;
        _map = _autoMap(source, columns);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '解析源文件失败:$e';
      });
    }
  }

  /// 自动映射:列名同名(忽略大小写)优先;无表头时按位置对齐。
  List<int> _autoMap(ImportSource source, List<ColumnDef> columns) {
    final headers = source.headers;
    final lowered = [for (final h in headers) h.trim().toLowerCase()];
    final used = <int>{};
    final map = <int>[];
    for (final c in columns) {
      final idx = lowered.indexOf(c.name.trim().toLowerCase());
      if (idx >= 0 && !used.contains(idx)) {
        used.add(idx);
        map.add(idx);
      } else {
        map.add(-1);
      }
    }
    if (!_effectiveHasHeader) {
      // 无表头文件:源列就是数据本身,按位置一一映射更直观
      for (var i = 0; i < map.length && i < headers.length; i++) {
        map[i] = i;
      }
    }
    return map;
  }

  Future<void> _start() async {
    if (_running || _mappedCount == 0) return;
    setState(() {
      _running = true;
      _cancelRequested = false;
      _result = null;
      _rowsDone = 0;
      _bytesDone = 0;
      _totalBytes = -1;
    });
    final mapping = <ImportColumn>[
      for (var i = 0; i < _columns.length; i++)
        ImportColumn(
          targetColumn: _columns[i].name,
          typeLabel: _columns[i].type,
          sourceIndex: _map[i],
          nullable: _columns[i].nullable,
        ),
    ];
    ImportResult result;
    try {
      result = await widget.app.importTableData(
        conn: widget.connection,
        database: widget.database,
        table: widget.table,
        schema: widget.schema,
        filePath: _filePath,
        request: _request,
        mapping: mapping,
        onProgress: (rows, bytes, total) {
          if (!mounted) return;
          setState(() {
            _rowsDone = rows;
            _bytesDone = bytes;
            _totalBytes = total;
          });
        },
        isCancelled: () => _cancelRequested,
      );
    } catch (e) {
      result = ImportResult(
        rowsInserted: _rowsDone,
        rowsRead: _rowsDone,
        failedBatches: 1,
        errors: [e.toString()],
      );
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
    _warn = AppColors.of(context).iconWarning;
    return DialogBox(
      title: '导入向导',
      width: 680,
      height: 480,
      onClose: () => Navigator.of(context).pop(),
      footer: Row(
        children: [
          Button(
            text: '< 上一步',
            onPressed: _step > 0 && !_running
                ? () => setState(() => _step--)
                : null,
          ),
          const SizedBox(width: 8),
          Button(
            text: '下一步 >',
            onPressed: _step < _steps.length - 1 && _canNext
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
              text: _finished ? '关闭' : '开始导入',
              onPressed: _finished
                  ? () => Navigator.of(context).pop(true)
                  : (_mappedCount > 0 ? _start : null),
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
                0 => _stepSource(t),
                1 => _stepMapping(t),
                _ => _stepRun(t),
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── 第 1 步:源文件与解析方式 ─────────────────────────────

  Widget _stepSource(AppPalette t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldRow(
          label: '源文件:',
          child: Row(
            children: [
              Expanded(
                child: Input(
                  controller: _pathController,
                  hint: '选择或直接粘贴 CSV / TSV / JSON 文件路径',
                  onChanged: (_) => setState(
                      () => _filePath = _pathController.text.trim()),
                  onSubmitted: (_) => _analyze(),
                ),
              ),
              const SizedBox(width: 8),
              Button(text: '浏览...', onPressed: _pickFile),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text('格式:', style: _labelStyle(t)),
            const SizedBox(width: 8),
            SizedBox(
              width: 160,
              child: ComboBox<DbImportFormat>(
                items: DbImportFormat.values,
                value: _format,
                itemToString: dbImportFormatLabel,
                onChanged: (v) {
                  if (v == null) return;
                  _applyParseChange(() => _format = v);
                },
              ),
            ),
            const SizedBox(width: 18),
            if (_format == DbImportFormat.csv) ...[
              Text('分隔符:', style: _labelStyle(t)),
              const SizedBox(width: 8),
              SizedBox(
                width: 160,
                child: ComboBox<String>(
                  items: const [',', ';', '\t', '|'],
                  value: _delimiter,
                  itemToString: DelimitedStyle.delimiterLabel,
                  onChanged: (v) {
                    if (v == null) return;
                    _applyParseChange(() => _delimiter = v);
                  },
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (_format == DbImportFormat.csv)
              CheckBox(
                value: _hasHeader,
                onChanged: (v) => _applyParseChange(() => _hasHeader = v ?? true),
                label: '首行为列名',
              )
            else
              Text('JSON 对象数组:首条记录的键即列名',
                  style: _hintStyle(t, color: t.mutedForeground)),
            const SizedBox(width: 22),
            Text('跳过前:', style: _labelStyle(t)),
            const SizedBox(width: 6),
            SizedBox(
              width: 90,
              child: NumericUpDown(
                value: _skipRows.toDouble(),
                min: 0,
                max: 1000,
                onChanged: (v) => _applyParseChange(() => _skipRows = v.round()),
              ),
            ),
            Text('行', style: _labelStyle(t)),
            const SizedBox(width: 22),
            CheckBox(
              value: _trimFields,
              onChanged: (v) => _applyParseChange(() => _trimFields = v ?? false),
              label: '去除字段首尾空白',
            ),
          ],
        ),
        const SizedBox(height: 14),
        Expanded(child: _sampleView(t)),
      ],
    );
  }

  /// 解析选项变化后必须重新采样,否则预览与实际导入的行列口径会不一致
  void _applyParseChange(VoidCallback change) {
    setState(change);
    if (_filePath.isNotEmpty) _analyze();
  }

  Widget _sampleView(AppPalette t) {
    if (_filePath.isEmpty) {
      return _centerHint(t, '请选择要导入的文件。');
    }
    if (_loading) return _centerHint(t, '正在解析文件 ...', spinner: true);
    final err = _loadError;
    if (err != null) {
      return _centerHint(t, err, color: const Color(0xFFDC2626));
    }
    final source = _source;
    if (source == null) return const SizedBox.shrink();
    final sample = source.sample.take(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '识别到 ${source.headers.length} 列,预览前 ${sample.length} 行:',
          style: _hintStyle(t, color: t.mutedForeground),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: t.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: 120.0 * source.headers.length,
                child: DataGridView(
                  columns: [
                    for (final h in source.headers)
                      DataGridViewColumn(title: h, width: 120),
                  ],
                  rowCount: sample.length,
                  rowHeight: 24,
                  cellPaddingX: 8,
                  headerFontSize: 12,
                  zebra: true,
                  headerColor: t.secondary,
                  gridLineColor: t.gridLine,
                  rowHoverColor: t.background,
                  cellBuilder: (row, col) => Text(
                    col < sample[row].length ? sample[row][col] : '',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12,
                      color: t.foreground,
                      decoration: TextDecoration.none,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (source.warning != null) ...[
          const SizedBox(height: 6),
          Text(source.warning!, style: _hintStyle(t, color: _warn)),
        ],
        const SizedBox(height: 6),
        Text(
          '目标表:${widget.connection.name} / ${widget.database}.${widget.table}',
          style: _hintStyle(t, color: t.mutedForeground),
        ),
      ],
    );
  }

  Widget _centerHint(AppPalette t, String message,
      {Color? color, bool spinner = false}) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spinner) ...[
            const Spinner(size: 16),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              message,
              style: _hintStyle(t, color: color ?? t.mutedForeground),
            ),
          ),
        ],
      ),
    );
  }

  TextStyle _labelStyle(AppPalette t) => TextStyle(
        fontSize: 12.5,
        color: t.foreground,
        decoration: TextDecoration.none,
        fontWeight: FontWeight.w400,
      );

  TextStyle _hintStyle(AppPalette t, {Color? color}) => TextStyle(
        fontSize: 12,
        color: color ?? t.mutedForeground,
        decoration: TextDecoration.none,
        fontWeight: FontWeight.w400,
      );

  // ── 第 2 步:字段映射 ─────────────────────────────────────

  Widget _stepMapping(AppPalette t) {
    final source = _source;
    if (source == null || _columns.isEmpty) {
      return _centerHint(t, '尚未取得源文件结构,请返回第 1 步重新选择文件。');
    }
    final options = <String>['(不导入)'];
    for (var i = 0; i < source.headers.length; i++) {
      options.add('${i + 1}. ${source.headers[i]}');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(width: 200, child: _gridHeader(t, '目标列')),
            SizedBox(width: 130, child: _gridHeader(t, '类型')),
            Expanded(child: _gridHeader(t, '源列')),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: t.border),
              color: t.background,
            ),
            clipBehavior: Clip.antiAlias,
            child: ListView.builder(
              itemCount: _columns.length,
              itemExtent: 30,
              padding: const EdgeInsets.symmetric(vertical: 2),
              itemBuilder: (context, i) => _mappingRow(t, i, options),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '已映射 $_mappedCount / ${_columns.length} 列;'
          '未映射的列由数据库默认值填充。',
          style: _hintStyle(t, color: t.mutedForeground),
        ),
        if (_riskyColumns.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '以下 NOT NULL 列未映射,导入可能失败:${_riskyColumns.join(', ')}',
            style: _hintStyle(t, color: _warn),
          ),
        ],
      ],
    );
  }

  Widget _gridHeader(AppPalette t, String text) => Text(
        text,
        style: _hintStyle(t, color: t.mutedForeground),
      );

  Widget _mappingRow(AppPalette t, int i, List<String> options) {
    final c = _columns[i];
    final selected = options[_map[i] < 0 ? 0 : _map[i] + 1];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          SizedBox(
            width: 200,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    c.name,
                    overflow: TextOverflow.ellipsis,
                    style: _labelStyle(t),
                  ),
                ),
                if (c.primaryKey)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text('PK', style: _hintStyle(t, color: t.accent)),
                  ),
                if (!c.nullable)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text('NOT NULL',
                        style: _hintStyle(t, color: t.disabledForeground)),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 130,
            child: Text(
              c.type,
              overflow: TextOverflow.ellipsis,
              style: _hintStyle(t, color: t.mutedForeground),
            ),
          ),
          Expanded(
            child: ComboBox<String>(
              items: options,
              value: selected,
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _map = [..._map];
                  _map[i] = options.indexOf(v) - 1;
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── 第 3 步:写入选项与执行 ───────────────────────────────

  Widget _stepRun(AppPalette t) {
    final result = _result;
    final pct = _totalBytes > 0 ? (_bytesDone / _totalBytes * 100) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '写入 ${_mappedCount} 列到表「${widget.table}」,源文件 ${_fileName}',
          style: _labelStyle(t),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text('每条 INSERT:', style: _labelStyle(t)),
            const SizedBox(width: 8),
            SizedBox(
              width: 110,
              child: ComboBox<int>(
                items: const [1, 10, 50, 200, 1000],
                value: _batchSize,
                itemToString: (v) => v == 1 ? '逐行(1 行)' : '$v 行',
                onChanged: (v) {
                  if (v != null) setState(() => _batchSize = v);
                },
              ),
            ),
            const SizedBox(width: 22),
            CheckBox(
              value: _emptyAsNull,
              onChanged: (v) => setState(() => _emptyAsNull = v ?? true),
              label: '空字段写入 NULL',
            ),
          ],
        ),
        const SizedBox(height: 10),
        CheckBox(
          value: _truncateFirst,
          onChanged: (v) => setState(() => _truncateFirst = v ?? false),
          label: '导入前清空目标表(DELETE FROM,不可恢复)',
        ),
        const SizedBox(height: 16),
        if (_running || result != null) ...[
          ProgressBar(value: pct.clamp(0.0, 100.0)),
          const SizedBox(height: 8),
          Text(
            _running
                ? '已导入 $_rowsDone 行'
                    '${_totalBytes > 0 ? '(文件进度 ${(pct.roundToDouble())}%)' : ''} ...'
                : _summaryText(result!),
            style: _hintStyle(
              t,
              color: result != null && !result.ok
                  ? const Color(0xFFDC2626)
                  : t.mutedForeground,
            ),
          ),
          if (result != null && result.errors.isNotEmpty) ...[
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: t.surface,
                  border: Border.all(color: t.border),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListView.builder(
                  itemCount: result.errors.length,
                  itemBuilder: (context, i) => Text(
                    result.errors[i],
                    style: _hintStyle(t, color: t.mutedForeground),
                  ),
                ),
              ),
            ),
          ],
        ] else ...[
          Text(
            '点击「开始导入」按批写入:失败批次会记录错误并跳过,其余数据继续导入。',
            style: _hintStyle(t, color: t.mutedForeground),
          ),
          if (_riskyColumns.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '提醒:${_riskyColumns.length} 个 NOT NULL 列未映射。',
              style: _hintStyle(t, color: _warn),
            ),
          ],
        ],
      ],
    );
  }

  String get _fileName {
    final i = _filePath.replaceAll(r'\', '/').lastIndexOf('/');
    return i < 0 ? _filePath : _filePath.substring(i + 1);
  }

  String _summaryText(ImportResult r) {
    if (r.cancelled) {
      return '已停止:已写入 ${r.rowsInserted} 行(源文件已读取 ${r.rowsRead} 行)。';
    }
    if (r.failedBatches > 0) {
      return '导入完成:写入 ${r.rowsInserted} 行,'
          '${r.failedBatches} 个批次失败(源文件共 ${r.rowsRead} 行)。';
    }
    return '导入完成:共写入 ${r.rowsInserted} 行。';
  }
}
