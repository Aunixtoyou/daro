import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../app/app_state.dart';
import '../data/csv_codec.dart';
import '../data/db_data.dart';
import '../data/db_export.dart';
import '../theme/app_theme.dart';
import 'table_icon.dart';

/// Windows / POSIX 通用的路径拼接(避免为一次拼接引入 package:path)
String _joinPath(String dir, String name) {
  if (dir.isEmpty) return name;
  final sep = dir.contains('\\') ? '\\' : '/';
  final trimmed = dir.endsWith(sep) ? dir.substring(0, dir.length - 1) : dir;
  return '$trimmed$sep$name';
}

/// 空列表安全取首项(Dart SDK 的 Iterable 无 firstOrNull)
T? _firstOrNull<T>(List<T> list) => list.isEmpty ? null : list.first;

/// 打开「导出向导」:按 格式 → 源与目标 → 选择列 → 附加选项 → 执行 五步导出表数据。
///
/// 由对象面板工具栏、表右键菜单与表数据页「保存数据为」调用;
/// [conn] 必须是已建立的连接。[presetWhere] / [presetSortColumn] 由表数据页
/// 传入当前视图的筛选与排序,仅作用于 [table] 这一张表。
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

/// 「导出向导」五步对话框（流程与版式对齐 Navicat 导出向导）:
/// ① 导出格式 ② 源表与导出文件 ③ 导出列 ④ 附加选项 ⑤ 执行与日志。
///
/// 取数与写出全程流式（分页 + IOSink），批量导出逐表推进，内存与表大小无关。
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

  /// 调用方选中的表:进入向导时预勾选并带入筛选 / 排序
  final String table;
  final String? schema;

  /// 来自表数据页当前视图的筛选 WHERE 片段(不含 WHERE 关键字);
  /// 为 null 表示整表导出
  final String? presetWhere;

  /// 来自表数据页当前视图的排序列;为 null 表示按主键/全部列的稳定分页顺序
  final String? presetSortColumn;
  final bool presetSortAscending;

  @override
  State<DataExportWizard> createState() => _DataExportWizardState();
}

class _DataExportWizardState extends State<DataExportWizard> {
  /// 总步数:①格式 ②源与目标 ③列 ④附加选项 ⑤执行。
  /// 版式对齐 Navicat——它不画步骤条,页面位置由顶部蓝色引导语承担。
  static const _stepCount = 5;

  /// 每步顶部的蓝色引导语(Navicat 同位置文案)
  static const _hints = [
    '向导可以让你指定导出数据的细节。你要使用哪一种导出格式？',
    '你可以选择导出文件并定义一些附加选项。',
    '你可以选择导出哪些列。',
    '你可以定义一些附加的选项。',
    '我们已收集向导导出数据时所需的所有信息。点击 [开始] 按钮开始导出。',
  ];

  int _step = 0;

  // ── ① 格式 ────────────────────────────────────────────────
  DbExportFormat _format = DbExportFormat.csv;

  // ── ② 源表与目标文件 ──────────────────────────────────────
  List<String> _allTables = const [];
  bool _tablesLoading = false;
  String? _tablesError;

  /// 勾选待导出的表(集合语义,展示顺序始终跟 [_allTables])
  final Set<String> _checked = {};

  /// 未指定单表路径时,文件名落在这个目录下
  String _outputDir = '';

  /// 用户双击「导出到」单独指定过完整路径的表
  final Map<String, String> _customPath = {};

  // ── ③ 列选择 ──────────────────────────────────────────────
  /// 当前正在配置列的源表
  String? _columnTable;

  /// 表名 → 可用列名(第 3 步按需 describe 后缓存)
  final Map<String, List<String>> _columnsByTable = {};
  final Set<String> _columnsLoading = {};
  final Map<String, String> _columnsError = {};

  /// 表名 → 是否导出全部列(勾选「所有字段」)
  final Map<String, bool> _allColumns = {};

  /// 表名 → 勾选的列(仅在非全部列时生效)
  final Map<String, List<String>> _pickedColumns = {};

  // ── ④ 附加选项 ────────────────────────────────────────────
  bool _append = false;
  bool _continueOnError = true;
  bool _withHeader = true;
  String _eol = '\r\n';
  String _quote = '"';
  String _delimiter = ',';

  /// 用户是否手动改过分隔符(改格式时决定是否重置为格式默认值)
  bool _delimiterTouched = false;

  String _nullAs = '';
  bool _quoteAll = false;
  bool _bom = true;

  bool _dropStatement = false;
  bool _createStatement = true;
  int _insertBatchSize = 50;
  bool _prettyJson = false;
  int _pageSize = 2000;

  // ── ⑤ 执行状态 ────────────────────────────────────────────
  bool _running = false;
  bool _cancelRequested = false;
  int _rowsDone = 0;
  int _rowsTotal = 0;
  String? _currentTable;
  final List<String> _log = [];
  final ScrollController _logScroll = ScrollController();
  Stopwatch? _watch;
  int _elapsedMs = 0;
  Timer? _ticker;
  BatchExportResult? _result;

  @override
  void initState() {
    super.initState();
    _checked.add(widget.table);
    _columnTable = widget.table;
    _loadTables();
    _initOutputDir();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _logScroll.dispose();
    super.dispose();
  }

  bool get _finished => _result != null && !_running;

  bool get _isDelimited => _format.delimited;

  String get _ext => dbExportFormatExt(_format);

  /// 整体进度百分比:总行数未知(尚未统计到)时保持 0
  double get _percent {
    if (_finished) return 100;
    if (_rowsTotal <= 0) return 0;
    return (_rowsDone / _rowsTotal * 100).clamp(0, 100).toDouble();
  }

  // ── 数据装载 ─────────────────────────────────────────────

  Future<void> _initOutputDir() async {
    String? dir;
    try {
      // 并非所有平台都提供「下载」目录(取不到时退回应用支持目录)
      dir = (await getDownloadsDirectory())?.path;
    } catch (_) {
      dir = null;
    }
    final support = await getApplicationSupportDirectory();
    if (!mounted) return;
    setState(() => _outputDir = dir ?? support.path);
  }

  Future<void> _loadTables() async {
    setState(() {
      _tablesLoading = true;
      _tablesError = null;
    });
    try {
      final tables = await widget.app.tablesInDatabase(
        widget.connection,
        widget.database,
        schema: widget.schema,
      );
      if (!mounted) return;
      setState(() {
        _allTables = tables;
        _tablesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tablesLoading = false;
        _tablesError = e.toString();
      });
    }
  }

  Future<void> _loadColumns(String table) async {
    if (_columnsByTable.containsKey(table) || _columnsLoading.contains(table)) {
      return;
    }
    setState(() {
      _columnsLoading.add(table);
      _columnsError.remove(table);
    });
    try {
      final cols = await widget.app.connectionManager.describeTable(
        widget.connection,
        widget.database,
        table,
        schema: widget.schema,
      );
      if (!mounted) return;
      setState(() {
        _columnsLoading.remove(table);
        _columnsByTable[table] = cols.map((c) => c.name).toList();
        _allColumns.putIfAbsent(table, () => true);
        _pickedColumns.putIfAbsent(table, () => cols.map((c) => c.name).toList());
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _columnsLoading.remove(table);
        _columnsError[table] = e.toString();
      });
    }
  }

  // ── 派生值 ───────────────────────────────────────────────

  /// 勾选表的展示顺序(跟随库内表列表;不在列表中的入口表排在最前)
  List<String> get _checkedTables {
    final inList = _allTables.where(_checked.contains).toList();
    final extra = _checked.where((t) => !_allTables.contains(t)).toList();
    return [...extra, ...inList];
  }

  /// 某张表的导出路径:单独指定过用之,否则落到输出目录 + 表名.扩展名
  String _pathOf(String table) {
    final custom = _customPath[table];
    if (custom != null && custom.isNotEmpty) return custom;
    final safe = table.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return _joinPath(_outputDir, '$safe.$_ext');
  }

  DelimitedStyle get _style => DelimitedStyle(
        delimiter: _delimiter,
        quote: _quote,
        eol: _eol,
        nullAs: _nullAs,
      );

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
        append: _append,
        pageSize: _pageSize,
      );

  /// 该表要导出的列;全部列时 null(引擎不做投影)
  List<String>? _columnsFor(String table) {
    if (_allColumns[table] ?? true) return null;
    final picked = _pickedColumns[table] ?? const <String>[];
    return picked.isEmpty ? null : picked;
  }

  bool get _canNext => switch (_step) {
        1 => _checked.isNotEmpty,
        2 => _columnTable == null || !_columnsLoading.contains(_columnTable),
        _ => true,
      };

  bool get _canStart =>
      !_running && _checked.isNotEmpty && _outputDir.isNotEmpty;

  // ── 动作 ─────────────────────────────────────────────────

  void _setFormat(DbExportFormat f) {
    setState(() {
      _format = f;
      if (!_delimiterTouched) _delimiter = f == DbExportFormat.txt ? '\t' : ',';
      if (!f.delimited) _append = false;
      _result = null;
    });
  }

  void _goToStep(int s) {
    if (_running) return;
    setState(() => _step = s.clamp(0, _stepCount - 1));
    if (_step == 2) {
      final t = _columnTable ?? _firstOrNull(_checkedTables);
      _columnTable = t;
      if (t != null) _loadColumns(t);
    }
  }

  Future<void> _pickDir() async {
    final dir = await getDirectoryPath(
      confirmButtonText: '设为输出目录',
      initialDirectory: _outputDir.isEmpty ? null : _outputDir,
    );
    if (dir == null || !mounted) return;
    setState(() {
      _outputDir = dir;
      _customPath.clear();
    });
  }

  /// 勾选 / 取消勾选一张表(单击勾选框、双击行共用)
  void _toggleTable(String table) => setState(() {
        if (!_checked.remove(table)) _checked.add(table);
      });

  /// 双击「导出到」单元格:为单张表指定完整文件路径
  Future<void> _pickTablePath(String table) async {
    final path = await getSaveLocation(
      acceptedTypeGroups: [
        XTypeGroup(label: dbExportFormatLabel(_format), extensions: [_ext])
      ],
      suggestedName: _pathOf(table).split(RegExp(r'[\\/]')).last,
      confirmButtonText: '保存',
    );
    final picked = path?.path;
    if (picked == null || !mounted) return;
    setState(() => _customPath[table] = picked);
  }

  Future<void> _start() async {
    if (!_canStart) return;
    final jobs = [
      for (final t in _checkedTables)
        ExportJob(table: t, filePath: _pathOf(t), columns: _columnsFor(t)),
    ];
    setState(() {
      _running = true;
      _cancelRequested = false;
      _result = null;
      _rowsDone = 0;
      _rowsTotal = 0;
      _currentTable = null;
      _elapsedMs = 0;
      _log
        ..clear()
        ..add('[EXP] Start exporting ${jobs.length} table(s) to '
            '${_outputDir.isEmpty ? '(各表单独路径)' : _outputDir}')
        ..add('[EXP] Format: ${dbExportFormatLabel(_format)}');
    });
    _watch = Stopwatch()..start();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) return;
      setState(() => _elapsedMs = _watch?.elapsedMilliseconds ?? 0);
    });

    BatchExportResult result;
    try {
      result = await widget.app.exportTablesBatch(
        conn: widget.connection,
        database: widget.database,
        schema: widget.schema,
        jobs: jobs,
        request: _request,
        where: widget.presetWhere,
        sortColumn: widget.presetSortColumn,
        sortAscending: widget.presetSortAscending,
        whereTable: widget.table,
        continueOnError: _continueOnError,
        onTableStart: (job, total) {
          if (!mounted) return;
          setState(() {
            _currentTable = job.table;
            _rowsTotal = total < 0 ? _rowsTotal : _rowsTotal + total;
          });
        },
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _rowsDone = done;
            if (total > _rowsTotal) _rowsTotal = total;
          });
        },
        onLog: (line) {
          if (!mounted) return;
          setState(() => _log.add(line));
        },
        isCancelled: () => _cancelRequested,
      );
    } catch (e) {
      result = BatchExportResult(
        rowsWritten: _rowsDone,
        tablesDone: 0,
        tablesFailed: jobs.length,
        error: e.toString(),
      );
    }
    _ticker?.cancel();
    _watch?.stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
      _elapsedMs = _watch?.elapsedMilliseconds ?? _elapsedMs;
    });
    _scrollLogToEnd();
  }

  void _scrollLogToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_logScroll.hasClients) return;
      _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  // ── 配置文件 ─────────────────────────────────────────────

  Map<String, Object?> _configMap() => {
        'version': 1,
        'database': widget.database,
        'schema': widget.schema,
        'format': _format.name,
        'outputDir': _outputDir,
        'options': {
          'delimiter': _delimiter,
          'quote': _quote,
          'eol': _eol,
          'nullAs': _nullAs,
          'quoteAll': _quoteAll,
          'withHeader': _withHeader,
          'bom': _bom,
          'append': _append,
          'continueOnError': _continueOnError,
          'pageSize': _pageSize,
          'dropStatement': _dropStatement,
          'createStatement': _createStatement,
          'insertBatchSize': _insertBatchSize,
          'prettyJson': _prettyJson,
        },
        'tables': [
          for (final t in _checkedTables)
            {
              'name': t,
              'path': _customPath[t],
              'allColumns': _allColumns[t] ?? true,
              'columns': _pickedColumns[t],
            }
        ],
      };

  void _notify(String message, {bool error = false}) {
    MessageBox.show(
      context,
      title: '导出配置',
      message: message,
      type: error ? MessageBoxType.error : MessageBoxType.info,
      okText: '知道了',
    );
  }

  Future<void> _saveConfig() async {
    final loc = await getSaveLocation(
      acceptedTypeGroups: [
        const XTypeGroup(label: '导出配置', extensions: ['json'])
      ],
      suggestedName: 'export-config.$_ext.json',
      confirmButtonText: '保存',
    );
    final path = loc?.path;
    if (path == null) return;
    try {
      await File(path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(_configMap()),
      );
      if (!mounted) return;
      setState(() => _log.add('[CFG] 配置已保存到 $path'));
      _notify('配置已保存到\n$path');
    } catch (e) {
      if (!mounted) return;
      _notify('保存失败:$e', error: true);
    }
  }

  Future<void> _loadConfig() async {
    final picked = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: '导出配置', extensions: ['json'])
      ],
    );
    final file = picked?.path;
    if (file == null) return;
    Map<String, Object?> map;
    try {
      final decoded = jsonDecode(await File(file).readAsString());
      if (decoded is! Map) throw const FormatException('配置根节点应为对象');
      map = decoded.cast<String, Object?>();
    } catch (e) {
      if (!mounted) return;
      _notify('读取配置失败:$e', error: true);
      return;
    }
    final opts = (map['options'] as Map?)?.cast<String, Object?>() ?? const {};
    final tables = (map['tables'] as List?) ?? const [];
    setState(() {
      _format = DbExportFormat.values.firstWhere(
        (f) => f.name == map['format'],
        orElse: () => _format,
      );
      if (map['outputDir'] is String) _outputDir = map['outputDir'] as String;
      _delimiter = (opts['delimiter'] as String?) ?? _delimiter;
      _quote = (opts['quote'] as String?) ?? _quote;
      _eol = (opts['eol'] as String?) ?? _eol;
      _nullAs = (opts['nullAs'] as String?) ?? _nullAs;
      _quoteAll = (opts['quoteAll'] as bool?) ?? _quoteAll;
      _withHeader = (opts['withHeader'] as bool?) ?? _withHeader;
      _bom = (opts['bom'] as bool?) ?? _bom;
      _append = (opts['append'] as bool?) ?? _append;
      _continueOnError = (opts['continueOnError'] as bool?) ?? _continueOnError;
      _pageSize = (opts['pageSize'] as int?) ?? _pageSize;
      _dropStatement = (opts['dropStatement'] as bool?) ?? _dropStatement;
      _createStatement =
          (opts['createStatement'] as bool?) ?? _createStatement;
      _insertBatchSize = (opts['insertBatchSize'] as int?) ?? _insertBatchSize;
      _prettyJson = (opts['prettyJson'] as bool?) ?? _prettyJson;
      _checked
        ..clear()
        ..addAll([for (final t in tables) if (t is Map) t['name'] as String]);
      _customPath.clear();
      _allColumns.clear();
      _pickedColumns.clear();
      for (final t in tables) {
        if (t is! Map) continue;
        final name = t['name'] as String;
        final path = t['path'];
        if (path is String && path.isNotEmpty) _customPath[name] = path;
        _allColumns[name] = (t['allColumns'] as bool?) ?? true;
        final cols = t['columns'];
        if (cols is List) _pickedColumns[name] = cols.cast<String>();
      }
      _columnTable = _firstOrNull(_checkedTables);
      _result = null;
    });
    if (_columnTable != null) _loadColumns(_columnTable!);
  }

  // ── 骨架 ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final pct = _percent.round();
    return DialogBox(
      title: _running || _finished ? '$pct% - 导出向导' : '导出向导',
      width: 900,
      height: 640,
      onClose: () => Navigator.of(context).pop(),
      footer: _footer(t),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _hints[_step],
              style: TextStyle(
                fontSize: 16,
                color: t.accent,
                fontWeight: FontWeight.w500,
                height: 1.4,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 22),
            Expanded(
              child: switch (_step) {
                0 => _stepFormat(t),
                1 => _stepSources(t),
                2 => _stepColumns(t),
                3 => _stepOptions(t),
                _ => _stepRun(t),
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 带 ▾ 的下拉按钮;执行中退化为禁用按钮(此时不允许改动向导配置)
  Widget _dropDown(String label, List<ListItem> items) {
    if (_running) return Button(text: label, onPressed: null);
    return DropDownButton(
      trigger: Button(
        // 开合由 DropDownButton 接管,按钮仅提供视觉态
        onPressed: () {},
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            const SizedBox(width: 8),
            const Text('▾', style: TextStyle(fontSize: 10)),
          ],
        ),
      ),
      items: items,
    );
  }

  Widget _footer(AppPalette t) {
    final last = _step == _stepCount - 1;
    Widget sep() => const SizedBox(width: 8);
    return Row(
      children: [
        _dropDown('保存配置文件', [
          ListItem(title: '保存配置到 JSON 文件…', onSelect: _saveConfig),
        ]),
        sep(),
        _dropDown('打开...', [
          ListItem(title: '从 JSON 配置载入…', onSelect: _loadConfig),
        ]),
        const Spacer(),
        Button(
          text: '<<',
          onPressed: _step > 0 && !_running ? () => _goToStep(0) : null,
        ),
        sep(),
        Button(
          text: '< 上一步',
          onPressed: _step > 0 && !_running ? () => _goToStep(_step - 1) : null,
        ),
        sep(),
        Button(
          text: '下一步 >',
          onPressed: !_running && _step < _stepCount - 1 && _canNext
              ? () => _goToStep(_step + 1)
              : null,
        ),
        sep(),
        Button(
          text: '>>',
          onPressed: !_running && !last && _canNext
              ? () => _goToStep(_stepCount - 1)
              : null,
        ),
        sep(),
        if (_running)
          Button(
            text: '停止',
            onPressed: () => setState(() => _cancelRequested = true),
          )
        else
          Button(
            text: last ? (_finished ? '关闭' : '开始') : '取消',
            onPressed: last && _finished
                ? () => Navigator.of(context).pop(true)
                : last
                    ? (_canStart ? _start : null)
                    : () => Navigator.of(context).pop(),
          ),
      ],
    );
  }

  // ── ① 导出格式 ───────────────────────────────────────────

  Widget _stepFormat(AppPalette t) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('导出格式:', style: TextStyle(fontSize: 13, color: t.foreground)),
          const SizedBox(height: 10),
          Expanded(
            child: ListView(
              children: [
                for (final f in DbExportFormat.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: RadioButton<DbExportFormat>(
                      value: f,
                      groupValue: _format,
                      onChanged: (_) => _setFormat(f),
                      label: dbExportFormatLabel(f),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            dbExportFormatHint(_format),
            style: TextStyle(fontSize: 12, color: t.mutedForeground),
          ),
          const SizedBox(height: 6),
          Text(
            '源: ${widget.connection.name} · ${widget.database}'
            '${widget.schema == null || widget.schema!.isEmpty ? '' : '.${widget.schema}'}',
            style: TextStyle(fontSize: 12, color: t.mutedForeground),
          ),
        ],
      ),
    );
  }

  // ── ② 源表与导出文件 ─────────────────────────────────────

  Widget _stepSources(AppPalette t) {
    final rows = _allTables.isEmpty && !_tablesLoading
        ? [widget.table]
        : _allTables;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_tablesError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '读取表列表失败:${_tablesError}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626)),
                  ),
                ),
                Button(text: '重试', onPressed: _loadTables),
              ],
            ),
          ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: t.surface,
              border: Border.all(color: t.border),
            ),
            child: DataGridView(
              showHeader: true,
              zebra: true,
              // 默认 12px 单元格内边距会把勾选 / 图标两列挤没,这里收紧
              cellPaddingX: 6,
              columns: const [
                DataGridViewColumn(title: '', width: 36, flex: 0),
                DataGridViewColumn(title: '', width: 28, flex: 0),
                DataGridViewColumn(title: '源', flex: 2),
                DataGridViewColumn(title: '导出到', flex: 3),
              ],
              rowCount: rows.length,
              cellBuilder: (row, col) {
                final table = rows[row];
                final checked = _checked.contains(table);
                return switch (col) {
                  // 单元格外层有双击 GestureDetector,会把 CheckBox 自身的 onTap
                  // 吞进双击判定窗口 → 单击无响应。按项目规范改为按下瞬间触发。
                  0 => Center(
                      child: Listener(
                        onPointerDown: (e) {
                          if (e.buttons == kPrimaryMouseButton) {
                            _toggleTable(table);
                          }
                        },
                        child: CheckBox(value: checked),
                      ),
                    ),
                  1 => Center(child: TableIcon(size: 15)),
                  2 => _cellText(table,
                      bold: table == widget.table, color: t.foreground),
                  _ => _cellText(_pathOf(table), color: t.mutedForeground),
                };
              },
              onCellDoubleTap: (row, col) {
                final table = rows[row];
                if (col == 3) {
                  _pickTablePath(table);
                } else if (col != 0) {
                  _toggleTable(table);
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _dropDown('全选', [
              ListItem(
                title: '全选',
                onSelect: () => setState(() => _checked.addAll(rows)),
              ),
              ListItem(
                title: '取消全选',
                onSelect: () => setState(_checked.clear),
              ),
              ListItem(
                title: '反选',
                onSelect: () => setState(() {
                  for (final tb in rows) {
                    if (_checked.contains(tb)) {
                      _checked.remove(tb);
                    } else {
                      _checked.add(tb);
                    }
                  }
                }),
              ),
            ]),
            const SizedBox(width: 8),
            Button(text: '输出目录...', onPressed: _pickDir),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _outputDir.isEmpty ? '正在准备输出目录…' : '输出到:$_outputDir',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: t.mutedForeground),
              ),
            ),
            Button(
              text: '高级',
              onPressed: _checked.isEmpty ? null : () => _goToStep(3),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '双击某行的「导出到」可单独指定文件路径;勾选 ${_checked.length} 张表。'
          '${widget.presetWhere == null ? '' : '筛选条件仅应用于当前表「${widget.table}」:${widget.presetWhere}'}',
          style: TextStyle(fontSize: 12, color: t.mutedForeground),
        ),
      ],
    );
  }

  Widget _cellText(String v, {Color? color, bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            v,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              color: color,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      );

  // ── ③ 选择列 ─────────────────────────────────────────────

  Widget _stepColumns(AppPalette t) {
    final tables = _checkedTables;
    final current = _columnTable ?? _firstOrNull(tables);
    if (tables.isEmpty) {
      return _centerHint(t, '请先在第 2 步勾选至少一张表。');
    }
    final cols = current == null ? const <String>[] : _columnsByTable[current];
    final allOn = _allColumns[current] ?? true;
    final picked = _pickedColumns[current] ?? const <String>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldRow(
          label: '源表:',
          labelWidth: 52,
          child: ComboBox<String>(
            items: tables,
            value: current,
            onChanged: (v) {
              if (v == null) return;
              setState(() => _columnTable = v);
              _loadColumns(v);
            },
          ),
        ),
        const SizedBox(height: 12),
        Text('可用字段:', style: TextStyle(fontSize: 13, color: t.foreground)),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: t.surface,
              border: Border.all(color: t.border),
            ),
            child: _columnsLoading.contains(current)
                ? _centerHint(t, '正在读取字段…')
                : _columnsError[current] != null
                    ? _centerHint(t, '读取字段失败:${_columnsError[current]}')
                    : (cols == null || cols.isEmpty
                        ? _centerHint(t, '该表没有可用字段。')
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemExtent: 26,
                            itemCount: cols.length,
                            itemBuilder: (_, i) {
                              final name = cols[i];
                              return Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: CheckBox(
                                  value: allOn || picked.contains(name),
                                  enabled: !allOn,
                                  onChanged: allOn
                                      ? null
                                      : (v) => setState(() {
                                            final set = picked.toSet();
                                            if (v ?? false) {
                                              set.add(name);
                                            } else {
                                              set.remove(name);
                                            }
                                            _pickedColumns[current!] =
                                                cols.where(set.contains).toList();
                                          }),
                                  label: name,
                                ),
                              );
                            },
                          )),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Button(
              text: '全选',
              onPressed: allOn || cols == null
                  ? null
                  : () => setState(() => _pickedColumns[current!] = [...cols]),
            ),
            const SizedBox(width: 8),
            Button(
              text: '取消全选',
              onPressed: allOn || cols == null
                  ? null
                  : () => setState(() => _pickedColumns[current!] = const []),
            ),
            const SizedBox(width: 18),
            CheckBox(
              value: allOn,
              onChanged: (v) => setState(() => _allColumns[current!] = v ?? true),
              label: '所有字段',
            ),
            const Spacer(),
            Text(
              current == null
                  ? ''
                  : '「$current」导出 '
                      '${allOn ? (cols?.length ?? 0) : picked.length} / ${cols?.length ?? '…'} 列',
              style: TextStyle(fontSize: 12, color: t.mutedForeground),
            ),
          ],
        ),
      ],
    );
  }

  Widget _centerHint(AppPalette t, String text) => Center(
        child: Text(
          text,
          style: TextStyle(fontSize: 12.5, color: t.mutedForeground),
        ),
      );

  // ── ④ 附加选项 ───────────────────────────────────────────

  Widget _stepOptions(AppPalette t) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _check(t, '追加', _append, (v) => setState(() => _append = v),
              enabled: _isDelimited),
          _check(t, '遇到错误时继续', _continueOnError,
              (v) => setState(() => _continueOnError = v)),
          const SizedBox(height: 14),
          GroupBox(
            title: '文件格式',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _check(t, '包含列的标题', _withHeader,
                    (v) => setState(() => _withHeader = v),
                    enabled: _isDelimited || _format == DbExportFormat.html),
                if (_isDelimited) ...[
                  const SizedBox(height: 8),
                  _comboRow(t, '分隔符:', [
                    ',',
                    ';',
                    '\t',
                    '|',
                  ], _delimiter, (v) => setState(() {
                        _delimiter = v;
                        _delimiterTouched = true;
                      }), DelimitedStyle.delimiterLabel),
                ],
                const SizedBox(height: 8),
                _comboRow(t, '记录分隔符:', ['\r\n', '\n', '\r'], _eol,
                    (v) => setState(() => _eol = v),
                    (v) => switch (v) { '\r\n' => 'CRLF', '\n' => 'LF', _ => 'CR' }),
                if (_isDelimited) ...[
                  const SizedBox(height: 8),
                  _comboRow(t, '文本识别符号:', ['"', "'", ''], _quote,
                      (v) => setState(() => _quote = v),
                      (v) => v.isEmpty ? '无' : v),
                  const SizedBox(height: 8),
                  _check(t, '所有字段加引号', _quoteAll,
                      (v) => setState(() => _quoteAll = v)),
                  const SizedBox(height: 4),
                  _check(t, '写入 UTF-8 BOM(Excel 双击打开中文不乱码)', _bom,
                      (v) => setState(() => _bom = v)),
                  const SizedBox(height: 8),
                  _comboRow(t, 'NULL 输出:', ['', r'\N', 'NULL'], _nullAs,
                      (v) => setState(() => _nullAs = v),
                      (v) => v.isEmpty ? '空字符串' : v),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          GroupBox(
            title: '数据格式',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_format == DbExportFormat.sql) ...[
                  _check(t, '包含建表语句(CREATE TABLE)', _createStatement,
                      (v) => setState(() => _createStatement = v)),
                  const SizedBox(height: 4),
                  _check(
                      t,
                      '建表前先 DROP TABLE IF EXISTS',
                      _dropStatement,
                      (v) => setState(() => _dropStatement = v),
                      enabled: _createStatement),
                  const SizedBox(height: 8),
                  _comboRow(t, '每条 INSERT:', ['1', '10', '50', '100', '500'],
                      '$_insertBatchSize', (v) {
                    setState(() => _insertBatchSize = int.tryParse(v) ?? 50);
                  }, (v) => v == '1' ? '逐行 INSERT(1 行)' : '$v 行合并'),
                  const SizedBox(height: 6),
                  Text(
                    'Access(ODBC) 不支持多值 VALUES,导出时自动退化为逐行 INSERT。',
                    style: TextStyle(fontSize: 12, color: t.mutedForeground),
                  ),
                ],
                if (_format == DbExportFormat.json)
                  _check(t, '缩进美化(文件更大)', _prettyJson,
                      (v) => setState(() => _prettyJson = v)),
                if (_format == DbExportFormat.xml ||
                    _format == DbExportFormat.html)
                  Text(
                    'XML / HTML 的列名始终随数据写出,「包含列的标题」对其无影响。',
                    style: TextStyle(fontSize: 12, color: t.mutedForeground),
                  ),
                const SizedBox(height: 10),
                _comboRow(
                    t, '分页行数:', ['500', '1000', '2000', '5000', '10000'],
                    '$_pageSize', (v) {
                  setState(() => _pageSize = int.tryParse(v) ?? 2000);
                }, (v) => '$v 行 / 次'),
                const SizedBox(height: 6),
                Text(
                  widget.presetSortColumn == null
                      ? '导出按主键排序分页(无主键时按全部列),保证大表不漏行、不重复。'
                      : '当前表沿用屏幕排序并以主键兜底;其余表按主键 / 全部列稳定分页。',
                  style: TextStyle(fontSize: 12, color: t.mutedForeground),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
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

  Widget _comboRow(AppPalette t, String label, List<String> items, String value,
      ValueChanged<String> onChanged, String Function(String) toLabel,
      {double labelWidth = 96}) {
    return FieldRow(
      label: label,
      labelWidth: labelWidth,
      child: SizedBox(
        width: 200,
        child: ComboBox<String>(
          items: items,
          value: value,
          itemToString: toLabel,
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }

  // ── ⑤ 执行 ───────────────────────────────────────────────

  Widget _stepRun(AppPalette t) {
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _statRow(t, '源表:', _currentTable ??
            (_checked.isEmpty ? '' : '${_checked.length} 张表')),
        _statRow(t, '总计:', _rowsTotal > 0 ? '$_rowsTotal' : ''),
        _statRow(t, '已处理:', '$_rowsDone'),
        _statRow(t, '时间:', _formatElapsed(_elapsedMs)),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: t.surface,
              border: Border.all(color: t.border),
            ),
            child: ListView.builder(
              controller: _logScroll,
              padding: const EdgeInsets.all(6),
              itemCount: _log.length,
              itemBuilder: (_, i) => Text(
                _log[i],
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  fontFamily: 'Consolas',
                  fontFamilyFallback: const ['Courier New', 'monospace'],
                  color: _log[i].startsWith('[ERR]')
                      ? const Color(0xFFDC2626)
                      : t.foreground,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        ProgressBar(
          value: _percent,
          barColor: result != null && result.ok
              ? const Color(0xFF22A745)
              : (result != null && result.error != null
                  ? const Color(0xFFDC2626)
                  : null),
        ),
        if (result != null) ...[
          const SizedBox(height: 6),
          Text(
            result.ok
                ? '导出完成:${result.tablesDone} 张表 / ${result.rowsWritten} 行'
                : result.cancelled
                    ? '已取消:已处理 ${result.rowsWritten} 行'
                    : '有 ${result.tablesFailed} 张表失败:${result.error}',
            style: TextStyle(
              fontSize: 12,
              color: result.ok ? t.mutedForeground : const Color(0xFFDC2626),
            ),
          ),
        ],
      ],
    );
  }

  Widget _statRow(AppPalette t, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 70,
              child: Text(
                label,
                style: TextStyle(fontSize: 12.5, color: t.foreground),
              ),
            ),
            Expanded(
              child: Text(
                value,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: t.foreground),
              ),
            ),
          ],
        ),
      );

  static String _formatElapsed(int ms) {
    final m = (ms ~/ 60000).toString().padLeft(2, '0');
    final s = ((ms ~/ 1000) % 60).toString().padLeft(2, '0');
    final cs = ((ms ~/ 10) % 100).toString().padLeft(2, '0');
    return '$m:$s.$cs';
  }
}
