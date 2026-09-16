import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';

import '../data/table_design.dart';
import '../theme/app_theme.dart';

/// 「选择数据表字段」弹窗:索引 / 唯一键的「字段」格点 `...` 打开。
///
/// 行 = 已加入索引的字段(保持其顺序)在前 + 表内其余字段在后;
/// 勾选框决定是否参与索引,底部 ↑ ↓ + − 依次为上移 / 下移 / 加入 / 移出。
/// 确定后按顺序回传 [DesignIndexColumn] 列表(含排序规则 / 运算符类别 /
/// 排序顺序 / Nulls 排序),由调用方写回索引并同步逗号串。
class IndexColumnPickerDialog extends StatefulWidget {
  const IndexColumnPickerDialog({
    super.key,
    required this.fields,
    required this.selected,
    this.schemaCandidates = const [],
    this.collationCandidates = const [],
    this.opClassCandidates = const [],
  });

  /// 表的全部字段名(弹窗行来源)
  final List<String> fields;

  /// 索引当前字段项(决定初始勾选与顺序)
  final List<DesignIndexColumn> selected;

  /// 「排序规则模式 / 运算符类别模式」候选(schema 列表;仍可手输)
  final List<String> schemaCandidates;

  /// 「排序规则」候选
  final List<String> collationCandidates;

  /// 「运算符类别」候选
  final List<String> opClassCandidates;

  /// 弹出选择;取消返回 null,确定返回选中的字段项(可能为空列表 = 清空索引字段)
  static Future<List<DesignIndexColumn>?> show(
    BuildContext context, {
    required List<String> fields,
    required List<DesignIndexColumn> selected,
    List<String> schemaCandidates = const [],
    List<String> collationCandidates = const [],
    List<String> opClassCandidates = const [],
  }) {
    return showDialog<List<DesignIndexColumn>>(
      context: context,
      builder: (_) => IndexColumnPickerDialog(
        fields: fields,
        selected: selected,
        schemaCandidates: schemaCandidates,
        collationCandidates: collationCandidates,
        opClassCandidates: opClassCandidates,
      ),
    );
  }

  @override
  State<IndexColumnPickerDialog> createState() => _IndexColumnPickerDialogState();
}

class _IndexColumnPickerDialogState extends State<IndexColumnPickerDialog> {
  /// 网格行:字段项 + 是否加入索引
  final List<_Row> _rows = [];

  /// 当前行(▶ 标记);↑↓ 与 +− 都作用于它
  int _current = 0;

  static const List<double> _widths = [
    150, // 名称
    118, // 排序规则模式
    128, // 排序规则
    128, // 运算符类别模式
    122, // 运算符类别
    96, // 排序顺序
    96, // Nulls 排序
  ];

  static const double _rowMarkerWidth = 16;

  @override
  void initState() {
    super.initState();
    // 已选字段在前(保留其选项),其余表字段在后(未勾选)
    final used = <String>{};
    for (final item in widget.selected) {
      final name = item.name.trim();
      if (name.isEmpty || !used.add(name.toLowerCase())) continue;
      _rows.add(_Row(item.copy(), true));
    }
    for (final f in widget.fields) {
      final name = f.trim();
      if (name.isEmpty || !used.add(name.toLowerCase())) continue;
      _rows.add(_Row(DesignIndexColumn(name: name), false));
    }
  }

  _Row? get _row => _current >= 0 && _current < _rows.length ? _rows[_current] : null;

  void _move(int delta) {
    final to = _current + delta;
    if (_current < 0 || _current >= _rows.length) return;
    if (to < 0 || to >= _rows.length) return;
    setState(() {
      final row = _rows.removeAt(_current);
      _rows.insert(to, row);
      _current = to;
    });
  }

  void _add() {
    final row = _row;
    if (row == null || row.checked) return;
    setState(() => row.checked = true);
  }

  void _remove() {
    final row = _row;
    if (row == null || !row.checked) return;
    setState(() => row.checked = false);
  }

  void _confirm() {
    final picked = [
      for (final r in _rows)
        if (r.checked) r.item,
    ];
    Navigator.of(context).pop(picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return DialogBox(
      title: '选择数据表字段',
      width: 900,
      height: 520,
      onClose: () => Navigator.of(context).pop(),
      footer: _footer(t),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: _rows.isEmpty
            ? Center(
                child: Text(
                  '当前表还没有字段,请先在「字段」标签添加字段。',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: t.mutedForeground,
                    decoration: TextDecoration.none,
                  ),
                ),
              )
            : _grid(t),
      ),
    );
  }

  /// 底部:左侧行操作按钮,右侧确定 / 取消(与参考工具的排布一致)
  Widget _footer(AppPalette t) {
    Widget op(IconData icon, VoidCallback? onTap) => IconBtn(
          icon: icon,
          iconSize: 15,
          size: const Size(28, 26),
          outline: true,
          color: onTap == null ? t.disabledForeground : t.foreground,
          onTap: onTap,
        );
    final row = _row;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(
        children: [
          op(Icons.arrow_upward, _current > 0 ? () => _move(-1) : null),
          const SizedBox(width: 4),
          op(Icons.arrow_downward,
              _current >= 0 && _current < _rows.length - 1 ? () => _move(1) : null),
          const SizedBox(width: 4),
          op(Icons.add, row != null && !row.checked ? _add : null),
          const SizedBox(width: 4),
          op(Icons.remove, row != null && row.checked ? _remove : null),
          const Spacer(),
          Button(text: '确定', onPressed: _confirm),
          const SizedBox(width: 8),
          Button(text: '取消', onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }

  Widget _grid(AppPalette t) {
    final total = _widths.fold(0.0, (a, b) => a + b) + _rowMarkerWidth;
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                // 表头左右内边距 6 + 12 = 18,预留够才不会比行内容窄
                width: total + 18,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      height: 26,
                      color: t.secondary,
                      padding: const EdgeInsets.only(left: 6, right: 12),
                      child: Row(
                        children: [
                          const SizedBox(width: _rowMarkerWidth),
                          for (var i = 0; i < _headers.length; i++)
                            _headCell(t, _headers[i], _widths[i]),
                          const Spacer(),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _rows.length,
                        itemExtent: 30,
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        itemBuilder: (context, i) => _rowView(t, i),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const List<String> _headers = [
    '名称',
    '排序规则模式',
    '排序规则',
    '运算符类别模式',
    '运算符类别',
    '排序顺序',
    'Nulls 排序',
  ];

  Widget _headCell(AppPalette t, String title, double width) => Container(
        width: width,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: t.mutedForeground,
            decoration: TextDecoration.none,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      );

  /// 行:按下即选中(零延迟);勾选框决定该字段是否进入索引
  Widget _rowView(AppPalette t, int i) {
    final row = _rows[i];
    return Listener(
      onPointerDown: (_) => setState(() => _current = i),
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        color: i == _current
            ? t.treeSelectedBg
            : (i.isOdd
                ? Color.alphaBlend(t.foreground.withValues(alpha: 0.03), t.background)
                : t.background),
        child: Row(
          children: [
            SizedBox(
              width: _rowMarkerWidth,
              child: i == _current
                  ? Icon(Icons.arrow_right, size: 16, color: t.foreground)
                  : null,
            ),
            SizedBox(
              width: _widths[0],
              child: Row(
                children: [
                  CheckBox(
                    value: row.checked,
                    onChanged: (v) => setState(() => row.checked = v ?? false),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Label(row.item.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
            _comboCell(row, row.item.collationSchema,
                (v) => row.item.collationSchema = v,
                widget.schemaCandidates, _widths[1]),
            _comboCell(row, row.item.collation, (v) => row.item.collation = v,
                _withCurrent(widget.collationCandidates, row.item.collation), _widths[2]),
            _comboCell(row, row.item.opClassSchema,
                (v) => row.item.opClassSchema = v,
                widget.schemaCandidates, _widths[3]),
            _comboCell(row, row.item.opClass, (v) => row.item.opClass = v,
                _withCurrent(widget.opClassCandidates, row.item.opClass), _widths[4]),
            _comboCell(row, row.item.order, (v) => row.item.order = v,
                _orderOptions, _widths[5]),
            _comboCell(
                row, row.item.nullsOrder, (v) => row.item.nullsOrder = v, _nullsOptions, _widths[6]),
          ],
        ),
      ),
    );
  }

  static const List<String> _orderOptions = ['', 'ASC', 'DESC'];
  static const List<String> _nullsOptions = ['', 'FIRST', 'LAST'];

  /// 未勾选的行不给编辑(选项对索引无意义,避免误以为已生效)
  Widget _comboCell(_Row row, String value, ValueChanged<String> set,
      List<String> items, double width) {
    return SizedBox(
      width: width,
      child: ComboBox<String>(
        items: items,
        value: value.isEmpty ? null : value,
        editable: true,
        enabled: row.checked,
        onChanged: (v) => setState(() => set(v ?? '')),
      ),
    );
  }

  /// 候选列表里没有当前值时把它并进去,避免回显丢失
  List<String> _withCurrent(List<String> base, String current) {
    final v = current.trim();
    if (v.isEmpty || base.contains(v)) return base;
    return [...base, v];
  }
}

class _Row {
  _Row(this.item, this.checked);

  final DesignIndexColumn item;
  bool checked;
}
