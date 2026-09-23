import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../app/app_state.dart';

/// 应用自绘图标(assets/icons/ui/*.svg):矢量原图,任意 DPI 下按显示尺寸直接光栅化,
/// 无需位图解码缓存参数。全应用的分类 / 库 / 模式 / 连接图标统一走本组件。
class UiIcon extends StatelessWidget {
  const UiIcon(this.asset, {super.key, required this.size});

  final String asset;
  final double size;

  @override
  Widget build(BuildContext context) =>
      SvgPicture.asset(asset, width: size, height: size);
}

/// 连接树「库 / 模式」节点图标:打开态与关闭态同几何,关闭态用灰阶表达
const String kDatabaseIcon = 'assets/icons/ui/database.svg';
const String kDatabaseClosedIcon = 'assets/icons/ui/database_closed.svg';
const String kSchemaIcon = 'assets/icons/ui/schema.svg';
const String kSchemaClosedIcon = 'assets/icons/ui/schema_closed.svg';

/// 序列图标。序列不是 [ObjectCategory] 的一员(那是连接树 / 功能区的对象分类,
/// 加一个值会牵动树分组与面板),它目前只出现在「结构同步」的差异表里,
/// 故单列一个资源常量而不进 [ObjectCategoryIcon.assetOf]。
const String kSequenceIcon = 'assets/icons/ui/sequence.svg';

/// 连接树顶层「连接分组」节点图标:实心文件夹(参考 Navicat 的连接分组)。
/// 展开 / 折叠状态不切换图标,始终用这一个。
const String kConnGroupIcon = 'assets/icons/ui/conn_group.svg';

/// 命令列界面标签图标:自绘终端瓦片。命令列不是 [ObjectCategory] 的一员,
/// 故与序列一样单列资源常量,不进 [ObjectCategoryIcon.assetOf]。
const String kConsoleIcon = 'assets/icons/ui/console.svg';

/// 对象分类图标组件:渲染自绘彩色 SVG(与 Ribbon 分类按钮一致)。
///
/// 连接树分组节点 / 树中对象实例 / 对象面板实例 / 打开标签页 的图标
/// 均通过本组件取图,保证各处图标样式单一数据源、永不出现样式分叉。
class ObjectCategoryIcon extends StatelessWidget {
  const ObjectCategoryIcon({
    super.key,
    required this.category,
    required this.size,
  });

  /// 对象分类(表 / 视图 / 实体化视图 / 函数 / 角色 / 查询)
  final ObjectCategory category;

  /// 图标显示尺寸
  final double size;

  /// 分类 → SVG 资源路径(唯一数据源;备份分类暂无资源)
  static const Map<ObjectCategory, String> assetOf = {
    ObjectCategory.table: 'assets/icons/ui/table.svg',
    ObjectCategory.view: 'assets/icons/ui/view.svg',
    ObjectCategory.materializedView: 'assets/icons/ui/materialized_view.svg',
    ObjectCategory.function: 'assets/icons/ui/function.svg',
    ObjectCategory.procedure: 'assets/icons/ui/procedure.svg',
    ObjectCategory.user: 'assets/icons/ui/user.svg',
    ObjectCategory.query: 'assets/icons/ui/query.svg',
  };

  @override
  Widget build(BuildContext context) {
    final asset = assetOf[category];
    if (asset == null) return SizedBox(width: size, height: size);
    return UiIcon(asset, size: size);
  }
}
