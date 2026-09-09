import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:base_ui_flutter/base_ui_flutter.dart';
import '../app/app_state.dart';
import '../theme/app_theme.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.read<AppState>();

    return Selector<AppState,
        (bool, bool, bool, String, String?, String?, TablePageStatus?)>(
      selector: (_, app) => (
        app.leftPanelVisible,
        app.rightPanelVisible,
        app.objectGridLayout,
        app.activeTab,
        app.objectConnection,
        app.objectDatabase,
        app.tableStatusFor(app.activeTabModel?.key ?? ''),
      ),
      builder: (context, panels, __) {
        final (
          leftVisible,
          rightVisible,
          gridLayout,
          activeTab,
          _,
          _,
          tableStatus
        ) = panels;
        final activeTabModel = context.read<AppState>().activeTabModel;
        return ValueListenableBuilder<Set<String>>(
          valueListenable: app.selectionNotifier,
          builder: (_, selected, __) {
            final selectedCount = selected.length;
            return Container(
              height: 26,
              color: t.statusBar,
              padding: const EdgeInsets.only(left: 12, right: 8),
              child: Row(
                children: [
                  // 树操作日志:最近一条打开/关闭节点操作
                  Expanded(
                    child: Row(
                      children: [
                        ValueListenableBuilder<String?>(
                          valueListenable: app.treeLog,
                          builder: (context, log, _) =>
                              _buildTreeLog(t, log),
                        ),
                        if (app.treeLog.value != null)
                          const SizedBox(width: 12),
                        Expanded(
                          child: _buildLeftContent(
                            context,
                            t,
                            activeTab,
                            activeTabModel,
                            selectedCount,
                            app,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 表数据页:记录位置信息(第 xx 条记录（共 xx 条）于第 x 页)
                  if (activeTabModel?.type == TabType.table &&
                      tableStatus != null) ...[
                    Text(
                      '第 ${tableStatus.currentRecord} 条记录'
                      '（共 ${tableStatus.totalRows ?? '?'} 条）'
                      '于第 ${tableStatus.page} 页',
                      style: TextStyle(fontSize: 12, color: t.mutedForeground),
                    ),
                    const SizedBox(width: 12),
                  ],
                  // 对象面板布局切换:详细布局(多列网格) / 列表
                  // 仅在活动标签为"对象"(对象浏览页)时展示
                  if (activeTabModel == null) ...[
                    IconBtn(
                      tooltip: '详细布局',
                      selected: gridLayout,
                      onTap: () => app.setObjectLayout(true),
                      size: const Size(26, 22),
                      selectedColor: t.accent,
                      child: SizedBox(
                        width: 18,
                        height: 14,
                        child: CustomPaint(
                          painter: _LayoutPainter(
                            color: gridLayout ? t.accent : t.mutedForeground,
                            isGrid: true,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    IconBtn(
                      tooltip: '列表',
                      selected: !gridLayout,
                      onTap: () => app.setObjectLayout(false),
                      size: const Size(26, 22),
                      selectedColor: t.accent,
                      child: SizedBox(
                        width: 18,
                        height: 14,
                        child: CustomPaint(
                          painter: _LayoutPainter(
                            color: !gridLayout ? t.accent : t.mutedForeground,
                            isGrid: false,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  IconBtn(
                    tooltip: '左侧栏',
                    selected: leftVisible,
                    onTap: () => app.toggleLeftPanel(),
                    size: const Size(26, 22),
                    selectedColor: t.accent,
                    child: SizedBox(
                      width: 18,
                      height: 14,
                      child: CustomPaint(
                        painter: _PanelTogglePainter(
                          color: leftVisible ? t.accent : t.mutedForeground,
                          isRight: false,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconBtn(
                    tooltip: '右侧栏',
                    selected: rightVisible,
                    onTap: () => app.toggleRightPanel(),
                    size: const Size(26, 22),
                    selectedColor: t.accent,
                    child: SizedBox(
                      width: 18,
                      height: 14,
                      child: CustomPaint(
                        painter: _PanelTogglePainter(
                          color: rightVisible ? t.accent : t.mutedForeground,
                          isRight: true,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 树操作日志标签:展示最近一条打开/关闭节点操作
  Widget _buildTreeLog(AppPalette t, String? log) {
    if (log == null) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.terminal, size: 12, color: t.accent),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              log,
              style: TextStyle(
                fontSize: 12,
                color: t.mutedForeground,
                decoration: TextDecoration.none,
                fontWeight: FontWeight.w400,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }

  /// 根据当前活动标签构建左侧内容
  Widget _buildLeftContent(
    BuildContext context,
    AppPalette t,
    String activeTab,
    OpenTab? activeTabModel,
    int selectedCount,
    AppState app,
  ) {
    final c = AppColors.of(context);
    // 对象标签:显示面包屑导航(当前对象浏览上下文)
    if (activeTabModel == null) {
      if (selectedCount > 0) {
        return Row(
          children: [
            _buildBreadcrumb(context, t, app),
            const SizedBox(width: 16),
            Text(
              '已选择 $selectedCount 项',
              style: TextStyle(fontSize: 12, color: t.mutedForeground),
            ),
          ],
        );
      }
      return _buildBreadcrumb(context, t, app);
    }
    // 表标签:显示查询语句信息(最后一条 + 点击展开历史)
    if (activeTabModel.type == TabType.table) {
      final history = app.sqlHistoryFor(activeTabModel.key);
      final lastSql = history.isNotEmpty ? history.last : null;
      return _SqlHistoryBar(
        t: t,
        lastSql: lastSql ??
            'SELECT * FROM ${activeTabModel.title} @ ${activeTabModel.connection}.${activeTabModel.database}',
        history: history,
      );
    }
    // 查询标签:显示该查询关联的连接信息(新建查询时绑定,非对象浏览上下文)
    if (activeTabModel.type == TabType.query) {
      final conn = activeTabModel.connection;
      final db = activeTabModel.database;
      final schema = activeTabModel.schema;
      final target = db == null
          ? null
          : schema == null
              ? '$conn @ $db'
              : '$conn @ $db.$schema';
      return Row(
        children: [
          Icon(Icons.storage, size: 13, color: c.iconSuccess),
          const SizedBox(width: 6),
          Text(
            target ?? '未选择数据库',
            style: TextStyle(fontSize: 12, color: t.foreground),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }

  /// 面包屑导航:连接 > 数据库(当前对象浏览上下文)
  Widget _buildBreadcrumb(BuildContext context, AppPalette t, AppState app) {
    final c = AppColors.of(context);
    final conn = app.objectConnection;
    final db = app.objectDatabase;
    if (conn == null || db == null) {
      return Text(
        '未选择数据库',
        style: TextStyle(fontSize: 12, color: t.disabledForeground),
      );
    }
    return Breadcrumb(
      items: [
        BreadcrumbItem(conn,
            icon: Icon(Icons.dns, size: 13, color: c.iconInfo)),
        BreadcrumbItem(db,
            icon: Icon(Icons.storage, size: 13, color: c.iconSuccess)),
      ],
    );
  }
}

/// 对象面板布局图标 painter:
/// - isGrid=true : 2x2 圆角方阵(详细布局)
/// - isGrid=false: 3 条横线(列表)
class _LayoutPainter extends CustomPainter {
  final Color color;
  final bool isGrid;

  _LayoutPainter({required this.color, required this.isGrid});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    if (isGrid) {
      const gap = 2.0;
      final cellW = (size.width - gap) / 2;
      final cellH = (size.height - gap) / 2;
      const r = Radius.circular(1.2);
      for (var row = 0; row < 2; row++) {
        for (var col = 0; col < 2; col++) {
          final rect = Rect.fromLTWH(
            col * (cellW + gap),
            row * (cellH + gap),
            cellW,
            cellH,
          );
          canvas.drawRRect(RRect.fromRectAndRadius(rect, r), paint);
        }
      }
    } else {
      const lineCount = 3;
      const lineGap = 2.0;
      final lineH = (size.height - lineGap * (lineCount - 1)) / lineCount;
      final r = Radius.circular(lineH / 2);
      for (var i = 0; i < lineCount; i++) {
        final y = i * (lineH + lineGap);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0, y, size.width, lineH),
            r,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LayoutPainter old) =>
      old.color != color || old.isGrid != isGrid;
}

class _PanelTogglePainter extends CustomPainter {
  final Color color;
  final bool isRight;

  _PanelTogglePainter({required this.color, required this.isRight});

  @override
  void paint(Canvas canvas, Size size) {
    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final rect = Rect.fromLTWH(0.6, 0.6, size.width - 1.2, size.height - 1.2);
    canvas.drawRect(rect, strokePaint);

    final barWidth = size.width * 0.32;
    final bar = isRight
        ? Rect.fromLTWH(
            size.width - barWidth - 0.6,
            0.6,
            barWidth,
            size.height - 1.2,
          )
        : Rect.fromLTWH(0.6, 0.6, barWidth, size.height - 1.2);
    canvas.drawRect(bar, fillPaint);
  }

  @override
  bool shouldRepaint(covariant _PanelTogglePainter old) =>
      old.color != color || old.isRight != isRight;
}

/// SQL 历史记录栏:显示当前 tab 最后一条 SQL,点击展开历史列表
class _SqlHistoryBar extends StatefulWidget {
  final AppPalette t;
  final String lastSql;
  final List<String> history;

  const _SqlHistoryBar({
    required this.t,
    required this.lastSql,
    required this.history,
  });

  @override
  State<_SqlHistoryBar> createState() => _SqlHistoryBarState();
}

class _SqlHistoryBarState extends State<_SqlHistoryBar> {
  final OverlayPortalController _overlayController = OverlayPortalController();

  void _toggleHistory() {
    if (widget.history.length <= 1) return;
    _overlayController.toggle();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final hasHistory = widget.history.length > 1;
    return OverlayPortal(
      controller: _overlayController,
      overlayChildBuilder: (context) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _overlayController.hide(),
          child: Container(
            color: const Color(0x00000000),
            child: Center(
              child: _HistoryPopup(
                t: t,
                history: widget.history,
                onDismiss: () => _overlayController.hide(),
              ),
            ),
          ),
        );
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleHistory,
        child: MouseRegion(
          cursor:
              hasHistory ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: Row(
            children: [
              Icon(Icons.terminal, size: 13, color: t.mutedForeground),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  widget.lastSql,
                  style: TextStyle(
                    fontSize: 12,
                    color: t.foreground,
                    fontFamily: 'monospace',
                    decoration: TextDecoration.none,
                    fontWeight: FontWeight.w400,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              if (hasHistory) ...[
                const SizedBox(width: 4),
                Icon(
                  _overlayController.isShowing
                      ? Icons.expand_less
                      : Icons.expand_more,
                  size: 14,
                  color: t.mutedForeground,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// SQL 历史弹出列表
class _HistoryPopup extends StatelessWidget {
  final AppPalette t;
  final List<String> history;
  final VoidCallback onDismiss;

  const _HistoryPopup({
    required this.t,
    required this.history,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    // 最新在末尾,展示时倒序(最新在顶部)
    final reversed = history.reversed.toList();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600, maxHeight: 300),
      child: Container(
        decoration: BoxDecoration(
          color: t.popover,
          border: Border.all(color: t.border),
          borderRadius: BorderRadius.circular(4),
          boxShadow: [
            BoxShadow(
              color: const Color(0x33000000),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: t.border)),
              ),
              child: Row(
                children: [
                  Icon(Icons.history, size: 14, color: t.mutedForeground),
                  const SizedBox(width: 6),
                  Text(
                    'SQL 执行历史 (${history.length})',
                    style: TextStyle(
                      fontSize: 12,
                      color: t.foreground,
                      decoration: TextDecoration.none,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: reversed.length,
                itemBuilder: (context, index) {
                  final sql = reversed[index];
                  final isLatest = index == 0;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onDismiss,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color:
                              isLatest ? t.accent.withValues(alpha: 0.1) : null,
                        ),
                        child: Row(
                          children: [
                            if (isLatest)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Text(
                                  '最新',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: t.accent,
                                    fontWeight: FontWeight.w600,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ),
                            Flexible(
                              child: Text(
                                sql,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: t.foreground,
                                  decoration: TextDecoration.none,
                                  fontWeight: FontWeight.w400,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
