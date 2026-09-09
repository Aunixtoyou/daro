import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:chinese_font_library/chinese_font_library.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app/app_state.dart';
import '../data/db_data.dart';
import '../data/drivers/db_driver.dart';
import '../pages/connection_dialog_page.dart';
import '../theme/app_theme.dart';
import 'object_category_icon.dart';

// 顶部工具栏:每个按钮使用独立的图标与配色,可点击并有悬停提示。
// 使用 base_ui_flutter 的 Button(ghost 无边框变体)实现,相当于一个无边框按钮组,
// 按钮内容为「图标 + 文字」的 widget。
//
// 分割线右侧的分类按钮(表 / 视图 / 函数 / 角色 / 查询)根据当前选中连接的
// 数据库类型动态显隐:例如 SQLite / Access 不显示「函数」「角色」按钮。
// 未选中任何连接时仅显示所有类型都支持的基础分类(表 / 视图 / 查询)。
class Ribbon extends StatelessWidget {
  const Ribbon({super.key});

  // 各功能按钮的强调色:选用在明/暗背景下都清晰的中调色
  static const _accents = <Color>[
    Color(0xff2f80ed), // 连接
    Color(0xff0ea5e9), // 新建查询
    Color(0xff0d9488), // 表
    Color(0xff7c3aed), // 视图
    Color(0xffe11d48), // 实体化视图
    Color(0xffea580c), // 函数
    Color(0xff0891b2), // 过程
    Color(0xffca8a04), // 角色
    Color(0xff16a34a), // 查询
  ];

  /// 分类按钮定义:ObjectCategory 枚举 / 配色索引。
  /// 文字取 category.label、能力匹配取 category.name、图标查
  /// [ObjectCategoryIcon.assetOf](均与连接树分组同源,避免同一分类在不同入口显示不同名)。
  static const _categoryButtons = <({
    ObjectCategory category,
    int accentIndex,
  })>[
    (category: ObjectCategory.table, accentIndex: 2),
    (category: ObjectCategory.view, accentIndex: 3),
    (category: ObjectCategory.materializedView, accentIndex: 4),
    (category: ObjectCategory.function, accentIndex: 5),
    (category: ObjectCategory.procedure, accentIndex: 8),
    (category: ObjectCategory.user, accentIndex: 6),
    (category: ObjectCategory.query, accentIndex: 7),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final activeCategory = app.objectCategory;

    // 当前选中连接的数据库类型 id;无选中连接时为 null
    final connInfo = app.connectionByName(app.objectConnection);
    final typeId = connInfo?.typeId;

    // 按当前数据库类型过滤分类按钮:
    // - 有选中连接时:仅显示该类型支持的分类
    // - 无选中连接时:仅显示所有类型都支持的基础分类(表 / 视图 / 查询)
    final visibleButtons = _categoryButtons.where((b) {
      if (typeId != null) return isCategorySupportedForType(typeId, b.category.name);
      // 无连接选中:只保留全类型通用的分类
      return b.category == ObjectCategory.table ||
          b.category == ObjectCategory.view ||
          b.category == ObjectCategory.query;
    }).toList();

    return Container(
      height: 56,
      color: t.control,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 按钮组:窗口过窄时横向滚动,保证所有按钮可达
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 「连接」「新建查询」:自绘 SVG 图标 + 右下角绿色「+」徽章
                  _button(context, (c) => _badgedIcon('assets/icons/ui/connection.svg'),
                      '连接', _accents[0],
                      onTap: () => _openConnectionWindow(context)),
                  _button(context, (c) => _badgedIcon('assets/icons/ui/query.svg'),
                      '新建查询', _accents[1],
                      onTap: () => app.newQuery()),
                  // 新建查询右侧分割线
                  SizedBox(
                    height: 40,
                    child: Separator(
                      orientation: Axis.vertical,
                      thickness: 1,
                      color: t.border,
                    ),
                  ),
                  // 分类按钮:按当前数据库类型动态显隐,
                  // active 状态与左侧连接树分组节点选中联动;
                  // 图标与连接树 / 对象面板同源(ObjectCategoryIcon),
                  // 文字取 category.label(同样同源,避免同名不同称)
                  for (final b in visibleButtons)
                    _button(context,
                        (c) => ObjectCategoryIcon(
                            category: b.category, size: 32),
                        b.category.label, _accents[b.accentIndex],
                        active: activeCategory == b.category,
                        onTap: () => app.showObjectCategory(b.category)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  // 单个工具栏按钮:无边框(ghost)变体,内容为图标 + 文字。
  // 未传入 onTap 的按钮也保持可点击(启用),避免被禁用置灰。
  // active 为 true 时显示背景高亮,与左侧连接树分组节点选中联动。
  // iconBuilder 接收按钮强调色 [color] 的 active 态派生色,由调用方构造图标。
  Widget _button(BuildContext context, Widget Function(Color color) iconBuilder,
      String text, Color color,
      {VoidCallback? onTap, bool active = false}) {
    final t = Tokens.of(context);
    return Container(
      padding: active ? const EdgeInsets.only(bottom: 2) : null,
      decoration: active
          ? BoxDecoration(
              color: color.withValues(alpha: 0.10),
            )
          : null,
      child: Button(
        text: text,
        variant: ButtonVariant.ghost,
        onPressed: onTap ?? () {},
        child: SizedBox(
          width: 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              iconBuilder(active ? color : color.withValues(alpha: 0.7)),
              const SizedBox(height: 3),
              Text(
                text,
                style: TextStyle(
                  fontSize: 11,
                  // 非激活按钮文字也用主前景色;
                  // 选中态不加粗,仅靠背景高亮区分
                  color: t.foreground,
                  fontWeight: FontWeight.w400,
                  // 与全局字体机制一致:Button 内部 DefaultTextStyle 用的是 Segoe UI
                  // 且无 fontVariations,中文会退化成最细的 regular;
                  // 显式补上中文回退 + 可变字重轴,保证 ribbon 文字与其它区域同粗细
                  fontFamilyFallback: SystemChineseFont.fontFamilyFallback,
                  fontVariations: const [
                    FontVariation.weight(400),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 点击"连接":以模态弹窗(base-ui `DialogBox`)弹出"选择一个连接类型"窗口。
  /// 完成连接向导后,把新建的连接加入连接树。
  Future<void> _openConnectionWindow(BuildContext context) async {
    final result = await showDialog<ConnectionInfo>(
      context: context,
      builder: (_) => const ConnectionDialogPage(),
    );
    if (result != null) {
      context.read<AppState>().addConnection(result);
    }
  }

  /// 基础图标(32px)+ 右下角绿色「+」徽章,与新建按钮角标一致。
  Widget _badgedIcon(String asset) => SizedBox(
        width: 32,
        height: 32,
        child: Stack(
          children: [
            Positioned.fill(child: UiIcon(asset, size: 32)),
            Positioned(right: 0, bottom: 0, child: _PlusBadge(size: 13)),
          ],
        ),
      );
}

/// 绿色圆形「+」徽章:自绘无动画,直径约为图标的三分之一。
class _PlusBadge extends StatelessWidget {
  const _PlusBadge({this.size = 11});

  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: const _PlusBadgePainter());
}

class _PlusBadgePainter extends CustomPainter {
  const _PlusBadgePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final c = Offset(s / 2, s / 2);
    // 绿色圆底
    canvas.drawCircle(c, s / 2, Paint()..color = const Color(0xff4caf50));
    // 白色「+」
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = s * 0.16
      ..strokeCap = StrokeCap.round;
    final arm = s * 0.26;
    canvas.drawLine(c - Offset(arm, 0), c + Offset(arm, 0), p);
    canvas.drawLine(c - Offset(0, arm), c + Offset(0, arm), p);
  }

  @override
  bool shouldRepaint(covariant _PlusBadgePainter oldDelegate) => false;
}
