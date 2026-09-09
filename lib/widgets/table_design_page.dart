import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/app_state.dart';
import '../data/drivers/db_driver.dart';
import '../theme/app_theme.dart';

/// 表设计视图:展示选中表的字段(列)结构——序号 / 列名 / 类型 / 允许空 /
/// 主键 / 默认值 / 注释。数据为只读(编辑能力后续扩展);通过真实驱动查询
/// information_schema / PRAGMA 获取结构信息。
class TableDesignPage extends StatefulWidget {
  const TableDesignPage({
    super.key,
    required this.table,
    required this.connection,
    required this.database,
    this.schema,
  });

  /// 表名
  final String table;

  /// 所属连接名
  final String connection;

  /// 所属数据库
  final String database;

  /// 所属模式(PostgreSQL / SQL Server 等有模式层的类型;无模式层为 null)
  final String? schema;

  @override
  State<TableDesignPage> createState() => _TableDesignPageState();
}

class _TableDesignPageState extends State<TableDesignPage> {
  /// 表字段结构(加载完成后非空)
  List<ColumnDef>? _columns;

  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 标签切换复用 State 时感知表 / 连接上下文变化重新加载
  @override
  void didUpdateWidget(TableDesignPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed = oldWidget.table != widget.table ||
        oldWidget.connection != widget.connection ||
        oldWidget.database != widget.database ||
        oldWidget.schema != widget.schema;
    if (changed) {
      setState(() {
        _columns = null;
        _error = null;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    final conn = app.connectionByName(widget.connection);
    if (conn == null) {
      setState(() => _error = '连接 "${widget.connection}" 不存在');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final columns = await app.connectionManager.describeTable(
        conn,
        widget.database,
        widget.table,
        schema: widget.schema,
      );
      if (!mounted) return;
      setState(() {
        _columns = columns;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Container(
      color: t.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleBar(t),
          Expanded(
            child: () {
              if (_loading) {
                return _centerHint(
                  t,
                  const Spinner(size: 18),
                  '正在加载 ${widget.table} 的结构 ...',
                );
              }
              if (_error != null) {
                return _centerHint(
                  t,
                  Icon(Icons.error_outline, size: 18, color: t.mutedForeground),
                  '加载失败: $_error',
                  action: Button(text: '重试', onPressed: _load),
                );
              }
              if (_columns == null || _columns!.isEmpty) {
                // 表无字段:内容区留白,不展示空态提示
                return Container(color: t.background);
              }
              return _buildGrid(t, _columns!);
            }(),
          ),
        ],
      ),
    );
  }

  /// 字段结构网格:表头 + 数据行;列宽固定,超宽时水平滚动
  Widget _buildGrid(AppPalette t, List<ColumnDef> columns) {
    const widths = [48.0, 200.0, 170.0, 80.0, 72.0, 170.0, 240.0];
    const headers = ['#', '列名', '类型', '允许空', '主键', '默认值', '注释'];
    final totalWidth = widths.fold(0.0, (a, b) => a + b);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: totalWidth,
        child: DataGridView(
          columns: [
            for (var i = 0; i < headers.length; i++)
              DataGridViewColumn(title: headers[i], width: widths[i]),
          ],
          rowCount: columns.length,
          cellBuilder: (row, col) => _fieldCell(t, row, columns[row], col),
          rowHeight: 28,
          zebra: true,
          headerColor: t.secondary,
          gridLineColor: t.gridLine,
          cellPaddingX: 8,
          rowHoverColor: Color.alphaBlend(
            t.foreground.withValues(alpha: 0.06),
            t.background,
          ),
        ),
      ),
    );
  }

  /// 表信息标题行:设计表: 表名 @ 连接.数据库
  Widget _titleBar(AppPalette t) => Container(
        height: 28,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 12),
        color: t.secondary,
        child: Text(
          '设计表: ${widget.table} @ ${widget.connection}.${widget.database}',
          style: TextStyle(
            fontSize: 12.5,
            color: t.mutedForeground,
            decoration: TextDecoration.none,
            fontWeight: FontWeight.w400,
          ),
        ),
      );

  /// 居中提示(加载 / 错误 / 空数据)
  Widget _centerHint(
    AppPalette t,
    Widget icon,
    String message, {
    Widget? action,
  }) =>
      Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message,
                style: TextStyle(fontSize: 12.5, color: t.mutedForeground),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (action != null) ...[const SizedBox(width: 12), action],
          ],
        ),
      );
}

/// 字段结构网格单元格内容(按列索引分派;行高 / 网格线 / 内边距由 DataGridView 处理)
Widget _fieldCell(AppPalette t, int row, ColumnDef c, int col) {
  switch (col) {
    case 0:
      return Text(
        '${row + 1}',
        style: TextStyle(
          fontSize: 12,
          color: t.disabledForeground,
          decoration: TextDecoration.none,
          fontWeight: FontWeight.w400,
        ),
      );
    case 1:
      return Text(
        c.name,
        style: TextStyle(
          fontSize: 12.5,
          color: t.foreground,
          decoration: TextDecoration.none,
          fontWeight: FontWeight.w400,
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      );
    case 2:
      return Text(
        c.type.isEmpty ? '—' : c.type,
        style: TextStyle(
          fontSize: 12.5,
          color: t.foreground,
          decoration: TextDecoration.none,
          fontWeight: FontWeight.w400,
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      );
    case 3:
      return _yesNo(t, c.nullable);
    case 4:
      return c.primaryKey
          ? Icon(Icons.key, size: 13, color: t.accent)
          : Text(
              'NO',
              style: TextStyle(
                fontSize: 12,
                color: t.disabledForeground,
                decoration: TextDecoration.none,
                fontWeight: FontWeight.w400,
              ),
            );
    case 5:
      return Text(
        c.defaultValue ?? 'NULL',
        style: TextStyle(
          fontSize: 12,
          color: c.defaultValue == null ? t.disabledForeground : t.foreground,
          decoration: TextDecoration.none,
          fontWeight: FontWeight.w400,
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      );
    default:
      return Text(
        c.comment.isEmpty ? '—' : c.comment,
        style: TextStyle(
          fontSize: 12,
          color: t.mutedForeground,
          decoration: TextDecoration.none,
          fontWeight: FontWeight.w400,
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      );
  }
}

/// "允许空"列展示:YES(次级色) / NO(红色)
Widget _yesNo(AppPalette t, bool nullable) => Text(
      nullable ? 'YES' : 'NO',
      style: TextStyle(
        fontSize: 12,
        color: nullable ? t.mutedForeground : const Color(0xFFDC2626),
        decoration: TextDecoration.none,
        fontWeight: FontWeight.w400,
      ),
    );

