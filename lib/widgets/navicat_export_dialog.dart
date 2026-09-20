import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../app/app_state.dart';
import '../data/db_data.dart';
import '../data/db_types.dart';
import '../data/navicat_export.dart';
import '../theme/app_theme.dart';

/// 导出完成后的汇总(由调用方弹 MessageBox 告知结果)。
class NavicatExportOutcome {
  const NavicatExportOutcome({
    required this.path,
    required this.exported,
    required this.skipped,
  });

  /// 实际写出的文件
  final File path;

  /// 写进文件的连接数
  final int exported;

  /// Navicat 没有对应类型、未能写出的连接(名称 + 原因)
  final List<(String name, String reason)> skipped;
}

/// 打开「导出连接」对话框(形态与 Navicat 的同名对话框一致)。
///
/// 取消返回 null;写出成功返回 [NavicatExportOutcome]。
Future<NavicatExportOutcome?> showNavicatExportDialog(
  BuildContext context, {
  required AppState app,
}) {
  return showDialog<NavicatExportOutcome>(
    context: context,
    builder: (_) => NavicatExportDialog(app: app),
  );
}

/// 导出连接为 Navicat `.ncx`:勾选连接 → 选目标文件 → 可选「导出密码」→ 写出。
///
/// 列表与勾选行为对齐 Navicat 的「导出连接」对话框:默认全选,可全选/取消全选;
/// Navicat 没有的连接类型(Access 等)置灰并说明原因,而不是导出一份 Navicat
/// 读不了的文件。
class NavicatExportDialog extends StatefulWidget {
  const NavicatExportDialog({super.key, required this.app});

  final AppState app;

  @override
  State<NavicatExportDialog> createState() => _NavicatExportDialogState();
}

class _NavicatExportDialogState extends State<NavicatExportDialog> {
  static const double _rowHeight = 34;

  /// 成功/警告/禁用色:随主题在 build 中刷新
  Color _ok = AppColors.light.iconSuccess;
  Color _warn = AppColors.light.iconWarning;

  final TextEditingController _pathController = TextEditingController();

  final Set<int> _selected = {};
  bool _includePasswords = true;
  bool _exporting = false;

  /// 导出失败原因(文件被占用 / 无权限等),原样展示
  String? _error;

  List<ConnectionInfo> get _connections => widget.app.connections;

  /// 可导出(Navicat 有对应类型)的下标
  Set<int> get _exportable {
    final out = <int>{};
    for (var i = 0; i < _connections.length; i++) {
      if (kNavicatExportTypes.containsKey(_connections[i].typeId)) out.add(i);
    }
    return out;
  }

  bool get _hasPath => _pathController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _selected.addAll(_exportable);
    _pathController.text = _suggestPath();
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  /// 默认导出到桌面 connections.ncx,与 Navicat 的默认值一致
  String _suggestPath() {
    final home = Platform.environment['USERPROFILE'] ?? '';
    final sep = Platform.pathSeparator;
    return home.isEmpty
        ? 'connections.ncx'
        : '$home${sep}Desktop${sep}connections.ncx';
  }

  Future<void> _pickFile() async {
    final location = await getSaveLocation(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Navicat 连接文件', extensions: ['ncx', 'xml']),
        XTypeGroup(label: '所有文件'),
      ],
      suggestedName: 'connections.ncx',
      confirmButtonText: '保存',
    );
    final path = location?.path;
    if (path == null || !mounted) return;
    setState(() {
      _pathController.text = path;
      _error = null;
    });
  }

  /// 「全选」/「取消全选」各自语义确定,不做状态取反(与 Navicat 的同名按钮一致)
  void _selectAll() {
    setState(() {
      _selected
        ..clear()
        ..addAll(_exportable);
    });
  }

  void _clearAll() => setState(_selected.clear);

  void _toggle(int index) {
    setState(() {
      if (!_selected.remove(index)) _selected.add(index);
    });
  }

  /// 写出 .ncx。失败时把原因留在对话框里,不静默吞掉。
  Future<void> _export() async {
    if (_exporting || !_hasPath || _selected.isEmpty) return;
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final docs = await getApplicationDocumentsDirectory();
      final indices = _selected.toList()..sort();
      final conns = [for (final i in indices) _connections[i]];
      final result = buildNavicatNcx(
        conns,
        includePasswords: _includePasswords,
        settingsSaveRoot: '${docs.path}${Platform.pathSeparator}Navicat',
      );
      final file = await writeNavicatNcxFile(
          _pathController.text.trim(), result.xml);
      if (!mounted) return;
      Navigator.of(context).pop(NavicatExportOutcome(
        path: file,
        exported: result.exported.length,
        skipped: result.skipped,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _error = '写出文件失败:$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final colors = AppColors.of(context);
    _ok = colors.iconSuccess;
    _warn = colors.iconWarning;
    return DialogBox(
      title: '导出连接',
      width: 720,
      height: 520,
      onClose: _exporting ? null : () => Navigator.of(context).pop(),
      footer: Row(
        children: [
          Button(
            text: '确定',
            onPressed:
                (_hasPath && _selected.isNotEmpty && !_exporting) ? _export : null,
          ),
          const SizedBox(width: 8),
          Button(
            text: '取消',
            onPressed: _exporting ? null : () => Navigator.of(context).pop(),
          ),
          const Spacer(),
          Text(
            '已勾选 ${_selected.length} 条',
            style: _style(t, color: t.mutedForeground),
          ),
          const SizedBox(width: 10),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('连接:', style: _style(t, size: 12.5)),
            const SizedBox(height: 6),
            Expanded(
              child: _connections.isEmpty
                  ? _emptyHint(t)
                  : _list(t, colors),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Button(text: '全选', onPressed: _selectAll),
                const SizedBox(width: 8),
                Button(text: '取消全选', onPressed: _clearAll),
              ],
            ),
            const SizedBox(height: 10),
            FieldRow(
              label: '导出到:',
              labelWidth: 62,
              child: Row(
                children: [
                  Expanded(
                    child: Input(
                      controller: _pathController,
                      hint: r'导出为 Navicat 可直接导入的 .ncx,如 C:\Users\你\Desktop\connections.ncx',
                      onChanged: (v) => setState(() => _error = null),
                      onSubmitted: (_) => _export(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Button(text: '...', onPressed: _exporting ? null : _pickFile),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                CheckBox(
                  value: _includePasswords,
                  onChanged: _exporting
                      ? null
                      : (v) => setState(() => _includePasswords = v ?? false),
                  label: '导出密码(密码按 Navicat 内置算法加密,Navicat 可直接解密)',
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (_error != null)
              Text('$_error',
                  style: _style(t, color: _warn),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis)
            else
              Text(
                '未在 Navicat 里的连接类型会被跳过并说明原因;'
                '不勾选「导出密码」时,Navicat 导入后需重新输入密码。',
                style: _style(t, color: t.mutedForeground),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              '分组会写入 Group 属性:Navicat 原生没有连接分组的概念,会忽略该属性,'
              '由 daro 导入时还原(本地没有的分组自动新建)。',
              style: _style(t, color: t.disabledForeground, size: 11.5),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyHint(AppPalette t) {
    return Center(
      child: Text(
        '还没有可导出的连接。',
        style: _style(t, color: t.mutedForeground, size: 12.5),
      ),
    );
  }

  Widget _list(AppPalette t, AppColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _listHeader(t),
        const SizedBox(height: 2),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: t.surface,
              border: Border.all(color: t.border),
            ),
            child: ListView.builder(
              itemExtent: _rowHeight,
              itemCount: _connections.length,
              itemBuilder: (_, i) => _row(t, colors, i),
            ),
          ),
        ),
      ],
    );
  }

  /// 列头:分组单列摆出来,才看得清「这条会带着分组一起走」
  Widget _listHeader(AppPalette t) {
    Widget cell(String text, int flex) => Expanded(
          flex: flex,
          child: Text(text,
              style: _style(t, color: t.mutedForeground, size: 11.5)),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          const SizedBox(width: 46),
          cell('连接名称', 5),
          cell('分组', 3),
          cell('目标', 5),
          cell('状态', 3),
        ],
      ),
    );
  }

  Widget _row(AppPalette t, AppColors colors, int index) {
    final conn = _connections[index];
    final selected = _selected.contains(index);
    final exportable = kNavicatExportTypes.containsKey(conn.typeId);
    return Listener(
      // 按下即切换:零延迟,也不引入 Material 水波纹
      onPointerDown: exportable ? (_) => _toggle(index) : null,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? t.highlight.withValues(alpha: 0.10) : null,
          border: Border(bottom: BorderSide(color: t.divider)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            // 勾选统一由整行的 Listener 处理,onChanged 空实现避免二次触发
            CheckBox(value: selected, onChanged: (_) {}, enabled: exportable),
            const SizedBox(width: 6),
            _typeIcon(conn),
            const SizedBox(width: 6),
            Expanded(
              flex: 5,
              child: Text(
                conn.name.isEmpty ? '(未命名)' : conn.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _style(t,
                    color: exportable ? t.foreground : t.disabledForeground,
                    size: 12.5),
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                conn.group.isEmpty ? '-' : conn.group,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _style(t, color: t.mutedForeground, size: 12),
              ),
            ),
            Expanded(
              flex: 5,
              child: Text(_target(conn),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _style(t, color: t.mutedForeground, size: 12)),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: (exportable ? _ok : t.disabledForeground)
                          .withValues(alpha: 0.5)),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  exportable ? '可导出' : 'Navicat 无此类型',
                  style: _style(t,
                      color: exportable ? _ok : t.disabledForeground,
                      size: 10.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 一行摘要:文件型显示路径,其余显示 host:port / 实例名
  String _target(ConnectionInfo conn) {
    if (conn.typeId == 'sqlite' || conn.typeId == 'access') {
      return conn.database.isNotEmpty ? conn.database : conn.host;
    }
    final h = conn.host.isEmpty ? '(未指定主机)' : conn.host;
    return conn.port.isEmpty ? h : '$h:${conn.port}';
  }

  Widget _typeIcon(ConnectionInfo conn) {
    final type = kAllDbTypes.where((d) => d.id == conn.typeId).firstOrNull;
    if (type == null) return const SizedBox(width: 18);
    return DbTypeIcon(type: type, size: 18);
  }

  TextStyle _style(AppPalette t, {Color? color, double size = 12}) =>
      TextStyle(
        fontSize: size,
        color: color ?? t.foreground,
        decoration: TextDecoration.none,
        fontWeight: FontWeight.w400,
      );
}
