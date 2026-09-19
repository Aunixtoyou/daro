import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 连接类型条目:用于"选择一个连接类型"对话框里的每一个图标卡片。
///
/// [label] 支持两行(如"阿里云 云数据库\nRDS MySQL 版"),渲染时按 \n 自动分行。
class DbType {
  const DbType({required this.id, required this.label});

  /// 唯一 id(英文,用于选择结果回传)
  final String id;

  /// 显示名,可包含 \n 换行
  final String label;

  /// 引擎图标:厂商官方 logo 等比合成到统一圆角瓦片底(assets/icons/engines/),
  /// 明暗主题下均可直接使用,无需运行时着色。素材出处见 NOTICE.md。
  String get iconAsset => 'assets/icons/engines/$id.svg';
}

// ────────────────────────────────────────────────────────────
// 类型数据
// ────────────────────────────────────────────────────────────

/// 全部数据库类型(已实现的在前,未实现的在后)
const List<DbType> kAllDbTypes = [
  // ── 已实现 ──
  DbType(id: 'mysql', label: 'MySQL'),
  DbType(id: 'postgresql', label: 'PostgreSQL'),
  DbType(id: 'sqlserver', label: 'SQL Server'),
  DbType(id: 'sqlite', label: 'SQLite'),
  DbType(id: 'access', label: 'Access'),
  DbType(id: 'mariadb', label: 'MariaDB'),
  // ── 未实现 ──
  DbType(id: 'oracle', label: 'Oracle'),
  DbType(id: 'mongodb', label: 'MongoDB'),
  DbType(id: 'redis', label: 'Redis'),
  DbType(id: 'snowflake', label: 'Snowflake'),
];

/// 连接状态点配色:在线绿 / 离线灰,与图标几何无关,主题下均可辨
const Color kConnOnline = Color(0xff22b573);
const Color kConnOffline = Color(0xff98a1ab);

/// 数据库类型图标组件:渲染官方 logo 瓦片 SVG,不加任何色彩滤镜。
///
/// [connected] 非 null 时按连接状态出图:右下角叠加状态点,
/// 离线则整图去饱和。离线态复用同一套几何,不另画一套灰色图标。
class DbTypeIcon extends StatelessWidget {
  const DbTypeIcon(
      {super.key, required this.type, this.size = 80, this.connected});

  final DbType type;
  final double size;

  /// null = 不体现连接状态(类型选择器等场景);非 null = 连接树 / 详情面板
  final bool? connected;

  @override
  Widget build(BuildContext context) {
    final asset = type.iconAsset;
    final Widget glyph = SvgPicture.asset(
      asset,
      width: size,
      height: size,
      colorFilter: connected == false ? const ColorFilter.matrix(_desaturate) : null,
    );

    if (connected == null) return glyph;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned.fill(child: glyph),
          Positioned(
            right: 0,
            bottom: 0,
            child: _StatusDot(
              connected: connected!,
              diameter: (size * .34).clamp(6.0, 14.0),
            ),
          ),
        ],
      ),
    );
  }

  /// 饱和度 0.15 的去饱和矩阵(等价 SVG feColorMatrix type="saturate"),
  /// 每行系数和为 1,故明度基本保持不变,亮/暗主题下都不会变黑或变白。
  static const List<double> _desaturate = [
    0.331, 0.608, 0.061, 0, 0, //
    0.181, 0.758, 0.061, 0, 0, //
    0.181, 0.608, 0.211, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

/// 右下角连接状态点:自绘无动画,1px 半透明描边保证压在任意品牌色上都可辨
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.connected, required this.diameter});

  final bool connected;
  final double diameter;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(diameter),
        painter: _StatusDotPainter(connected),
      );
}

class _StatusDotPainter extends CustomPainter {
  const _StatusDotPainter(this.connected);

  final bool connected;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(
        c,
        size.width / 2,
        Paint()
          ..color = connected ? kConnOnline : kConnOffline
          ..style = PaintingStyle.fill);
    canvas.drawCircle(
        c,
        size.width / 2 - .6,
        Paint()
          ..color = const Color(0x59000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);
  }

  @override
  bool shouldRepaint(covariant _StatusDotPainter oldDelegate) =>
      oldDelegate.connected != connected;
}
