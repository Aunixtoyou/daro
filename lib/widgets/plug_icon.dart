import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 电源插头图标:Ribbon「连接」按钮专用。
///
/// 与 [TableIcon] 同类(应用主题专用图标,不归入 base-ui-flutter):
/// 线框风格 + 按颜色缓存 painter,大量实例共享同一画笔且无需重绘。
/// 构图:双插脚(实心胶囊)+ 圆形插头头(描边)+ 底部引线,
/// 参照主流数据库工具的「连接」惯例,避免方形头产生歧义。
class PlugIcon extends StatelessWidget {
  const PlugIcon({super.key, this.size = 21, this.color});

  final double size;

  /// 不传时使用当前主题下的连接图标色([AppColors.iconInfo]),明暗自适应
  final Color? color;

  // 按颜色复用 painter,避免重复分配
  static final Map<Color, _PlugPainter> _painterCache = {};

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.of(context).iconInfo;
    final painter = _painterCache.putIfAbsent(c, () => _PlugPainter(c));
    return CustomPaint(size: Size.square(size), painter: painter);
  }
}

class _PlugPainter extends CustomPainter {
  final Color color;
  const _PlugPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;

    // 描边画笔:圆形插头头 + 引线
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s / 10
      ..strokeCap = StrokeCap.round
      ..color = color;

    // 插脚:实心胶囊,与描边插头头形成虚实对比
    final footW = s * 0.08;
    final foot = Paint()..color = color;
    for (final x in [s * 0.40, s * 0.52]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, s * 0.10, footW, s * 0.15),
          Radius.circular(footW / 2),
        ),
        foot,
      );
    }

    // 圆形插头头:描边圆
    canvas.drawCircle(Offset(s * 0.50, s * 0.47), s * 0.22, stroke);

    // 底部引线:垂直段 → 圆角拐弯 → 水平收尾
    final wire = Path()
      ..moveTo(s * 0.50, s * 0.69)
      ..lineTo(s * 0.50, s * 0.79)
      ..quadraticBezierTo(s * 0.50, s * 0.87, s * 0.58, s * 0.87)
      ..lineTo(s * 0.66, s * 0.87);
    canvas.drawPath(wire, stroke);
  }

  @override
  bool shouldRepaint(covariant _PlugPainter oldDelegate) =>
      oldDelegate.color != color;
}
