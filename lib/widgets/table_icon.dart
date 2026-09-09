import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 数据库表图标:蓝色方框 + 内部网格线
/// const 构造 + 按颜色缓存 painter,大量图标共享同一实例且无需重绘
class TableIcon extends StatelessWidget {
  const TableIcon({super.key, this.size = 16, this.color});

  final double size;

  /// 不传时使用当前主题下的表图标色,实现明暗自适应
  final Color? color;

  // 缓存画笔对象,避免每次 paint 调用重新分配;按颜色复用同一 painter
  static final Map<Color, _TableIconPainter> _painterCache = {};

  static final Paint _defaultPaint = Paint()..style = PaintingStyle.stroke;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.of(context).iconPrimary;
    final painter = _painterCache.putIfAbsent(c, () => _TableIconPainter(c));
    return CustomPaint(
      size: Size.square(size),
      painter: painter,
    );
  }
}

class _TableIconPainter extends CustomPainter {
  final Color color;
  const _TableIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = TableIcon._defaultPaint
      ..color = color
      ..strokeWidth = size.width / 8;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
    canvas.drawLine(Offset(0, size.height / 3), Offset(size.width, size.height / 3), paint);
    canvas.drawLine(Offset(0, size.height * 2 / 3), Offset(size.width, size.height * 2 / 3), paint);
    canvas.drawLine(Offset(size.width / 2, size.height / 3), Offset(size.width / 2, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _TableIconPainter oldDelegate) => oldDelegate.color != color;
}
