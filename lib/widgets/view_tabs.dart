import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/app_state.dart';
import '../theme/app_theme.dart';
import 'object_category_icon.dart';

// 中部面板顶部的视图标签栏:默认展示"对象"页,表数据页/查询页追加为标签。
// 复用 base-ui 的 TabControl:自适应宽度、closable、滚动箭头、
// 右键菜单、键盘方向键切换均由组件内置,本文件只负责装配标签数据。

/// 文档标签条高度:比对话框内的标签(约 21)略高,好容纳 16px 图标。
const double _kTabBarHeight = 26;

class ViewTabs extends StatelessWidget {
  const ViewTabs({super.key});

  @override
  Widget build(BuildContext context) {
    // 标签列表与活动标签变化时重建(选中表由子项独立通知,不级联到这里)
    final tabCount = context.select<AppState, int>((a) => a.tabs.length);
    final activeTab = context.select<AppState, String>((a) => a.activeTab);
    final app = context.read<AppState>();
    final t = Tokens.of(context);

    // 活动标签在完整标签列表(含固定"对象"页)中的位置;未找到时回到 0
    final activeIndex = activeTab == '对象'
        ? 0
        : app.tabs.indexWhere((tab) => tab.title == activeTab) + 1;

    // 文档标签条:条高固定 26(比对话框标签略高,好容纳 16px 图标),
    // 标签宽度交由 TabControl 按标题自适应 —— 不再平分撑满整条,
    // 标签多到超出可视宽度时由组件内部弹出滚动箭头。
    return Container(
      height: _kTabBarHeight,
      color: t.background,
      child: TabControl(
        initialIndex: activeIndex.clamp(0, tabCount),
        // 延迟到下一帧再同步,避免鼠标事件处理期间触发 setState
        onChanged: (index) => WidgetsBinding.instance
            .addPostFrameCallback((_) => _activate(context, index)),
        // 选中标签用 surface(与内容区同底),悬浮用 secondary,
        // 与 app 标题栏/标签栏配色一致
        tabBarColor: t.background,
        selectedTabColor: t.surface,
        hoverTabColor: t.secondary,
        barHeight: _kTabBarHeight,
        // 纯标签条场景:不需要内容区
        contentPadding: EdgeInsets.zero,
        tabs: [
          // 固定的"对象"标签:不可关闭,无右键菜单
          const TabItem(label: '对象'),
          for (final tab in app.tabs)
            TabItem(
              label: tab.title,
              // 与连接树分组同一套图标,保证标签图标与分组一致:
              // 查询 → 查询图;表数据 / 新建表 → 表图;设计页按对象分类取图
              icon: ObjectCategoryIcon(
                category: _tabCategory(tab),
                size: 16,
              ),
              onClose: () => context.read<AppState>().closeTab(tab.title),
              contextMenuItems: _tabMenuItems(context, tab.title),
            ),
        ],
      ),
    );
  }

  /// 标签图标分类:与连接树分组图标同源。
  /// 查询 → 查询;表数据页 / 新建表 → 表;设计页按
  /// [OpenTab.routineCategory] 区分视图 / 函数等(routineCategory 为空即表设计)。
  ObjectCategory _tabCategory(OpenTab tab) => switch (tab.type) {
        TabType.query => ObjectCategory.query,
        TabType.table || TabType.createTable => ObjectCategory.table,
        TabType.design => tab.routineCategory ?? ObjectCategory.table,
        _ => ObjectCategory.table,
      };

  /// 点击标签:0 = "对象"页,其余映射到打开标签列表
  void _activate(BuildContext context, int index) {
    final app = context.read<AppState>();
    if (index == 0) {
      app.activateTab('对象');
    } else if (index - 1 < app.tabs.length) {
      app.activateTab(app.tabs[index - 1].title);
    }
  }

  /// 标签右键菜单:关闭 / 关闭其他 / 关闭右侧 / 全部关闭(仿 DBeaver)
  List<MenuModel> _tabMenuItems(BuildContext context, String title) {
    final app = context.read<AppState>();
    final index = app.tabs.indexWhere((tab) => tab.title == title);
    return [
      MenuItem(
        text: '关闭',
        shortcut: 'Ctrl+W',
        onPressed: () => app.closeTab(title),
      ),
      MenuItem(
        text: '关闭其他选项卡',
        enabled: app.tabs.length > 1,
        onPressed: () => app.closeOtherTabs(title),
      ),
      MenuItem(
        text: '关闭右侧的选项卡',
        enabled: index >= 0 && index < app.tabs.length - 1,
        onPressed: () => app.closeTabsToRight(title),
      ),
      const MenuSeparator(),
      MenuItem(
        text: '全部关闭',
        shortcut: 'Ctrl+Shift+W',
        onPressed: () => app.closeAllTabs(),
      ),
    ];
  }
}
