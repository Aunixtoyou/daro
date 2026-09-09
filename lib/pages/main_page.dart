import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:base_ui_flutter/base_ui_flutter.dart' show Splitter;
import '../app/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/top_menu.dart';
import '../widgets/ribbon.dart';
import '../widgets/database_tree.dart';
import '../widgets/object_panel.dart';
import '../widgets/database_info.dart';
import '../widgets/status_bar.dart';
import '../widgets/view_tabs.dart';
import '../widgets/table_data_page.dart';
import '../widgets/query_page.dart';
import '../widgets/table_design_page.dart';
import '../widgets/table_designer_page.dart';
import '../widgets/routine_design_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  /// 拖动分隔条中:此时关闭面板宽度的隐式动画,让宽度严格跟随鼠标
  bool _resizing = false;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final leftVisible = context.select((AppState a) => a.leftPanelVisible);
    final rightVisible = context.select((AppState a) => a.rightPanelVisible);

    return ColoredBox(
      color: Tokens.of(context).background,
      child: Column(
        children: [
          const TopMenu(),
          const Ribbon(),
          Expanded(
            child: Row(
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: app.leftPanelWidth,
                  builder: (context, width, child) => _AnimatedPanel(
                    visible: leftVisible,
                    width: width,
                    animate: !_resizing,
                    child: child!,
                  ),
                  // child 由 ValueListenableBuilder 缓存,拖动改宽时不重建子树
                  child: const DatabaseTree(),
                ),
                if (leftVisible)
                  Splitter(
                    onDragStart: () => setState(() => _resizing = true),
                    onDrag: app.resizeLeftPanel,
                    onDragEnd: () => setState(() => _resizing = false),
                  ),
                Expanded(
                  child: Column(
                    children: [
                      const ViewTabs(),
                      Expanded(
                        // 根据活动标签切换页面:对象浏览 / 表数据 / 查询编辑
                        // 用 Selector 仅在当前标签变化时重建,选中表时由子项 context.select 独立更新
                        child: Selector<AppState, OpenTab?>(
                          selector: (_, app) => app.activeTabModel,
                          child: const ObjectPanel(),
                          builder: (context, tab, cachedChild) {
                            if (tab == null) return cachedChild!;
                            if (tab.type == TabType.table)
                              return TableDataPage(
                                table: tab.title,
                                connection: tab.connection!,
                                database: tab.database!,
                                schema: tab.schema,
                              );
                            if (tab.type == TabType.design) {
                              // 设计标签标题带有 " (设计)" / " (新建)" 后缀以与数据页区分,
                              // 这里还原出真实对象名传给设计视图
                              const suffixDesign = ' (设计)';
                              const suffixNew = ' (新建)';
                              final category = tab.routineCategory;
                              if (category != null) {
                                // 例程(过程 / 函数 / 视图)设计页
                                final isNew = tab.title.endsWith(suffixNew);
                                final suffix = isNew ? suffixNew : suffixDesign;
                                final name = tab.title.endsWith(suffix)
                                    ? tab.title.substring(
                                        0, tab.title.length - suffix.length)
                                    : tab.title;
                                return RoutineDesignPage(
                                  name: name,
                                  connection: tab.connection!,
                                  database: tab.database!,
                                  category: category,
                                  schema: tab.schema,
                                  isNew: isNew,
                                  params: tab.routineParams ?? '',
                                  comment: tab.routineComment ?? '',
                                );
                              }
                              final tableName = tab.title.endsWith(suffixDesign)
                                  ? tab.title.substring(
                                      0,
                                      tab.title.length - suffixDesign.length)
                                  : tab.title;
                              return TableDesignPage(
                                table: tableName,
                                connection: tab.connection!,
                                database: tab.database!,
                                schema: tab.schema,
                              );
                            }
                            if (tab.type == TabType.query)
                              return QueryPage(
                                title: tab.title,
                                connection: tab.connection,
                                database: tab.database,
                                schema: tab.schema,
                              );
                            if (tab.type == TabType.createTable)
                              return TableDesignerPage(
                                title: tab.title,
                                connection: tab.connection!,
                                database: tab.database!,
                                schema: tab.schema,
                              );
                            return cachedChild!;
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                if (rightVisible)
                  Splitter(
                    onDragStart: () => setState(() => _resizing = true),
                    onDrag: app.resizeRightPanel,
                    onDragEnd: () => setState(() => _resizing = false),
                  ),
                ValueListenableBuilder<double>(
                  valueListenable: app.rightPanelWidth,
                  builder: (context, width, child) => _AnimatedPanel(
                    visible: rightVisible,
                    width: width,
                    animate: !_resizing,
                    alignment: Alignment.centerRight,
                    child: child!,
                  ),
                  child: const DatabaseInfo(),
                ),
              ],
            ),
          ),
          const StatusBar(),
        ],
      ),
    );
  }
}

/// 侧栏容器:展开时显示当前宽度(可拖动分隔条调整),收起时宽度动画到 0,
/// 内部内容保持原宽并裁剪
class _AnimatedPanel extends StatelessWidget {
  final bool visible;
  final double width;

  /// false = 宽度变化立即生效(拖动分隔条时避免隐式动画拖慢跟随感)
  final bool animate;
  final Alignment alignment;
  final Widget child;

  const _AnimatedPanel({
    required this.visible,
    required this.width,
    this.animate = true,
    this.alignment = Alignment.centerLeft,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration:
          animate ? const Duration(milliseconds: 200) : Duration.zero,
      curve: Curves.easeInOut,
      width: visible ? width : 0,
      // clipBehavior 生效需要 decoration 提供裁剪路径,这里用透明 decoration 占位
      decoration: const BoxDecoration(),
      clipBehavior: Clip.hardEdge,
      child: OverflowBox(
        alignment: alignment,
        minWidth: width,
        maxWidth: width,
        child: SizedBox(width: width, child: child),
      ),
    );
  }
}
