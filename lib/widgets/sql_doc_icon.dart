import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// SQL 标签文档图标:Ribbon「新建查询」按钮专用。
///
/// 与 [TableIcon] 同类(应用主题专用图标,不归入 base-ui-flutter):
/// 线框风格 + 按颜色缓存 painter,大量实例共享同一画笔且无需重绘。
/// 构图:右上折角的文档轮廓 + 居中「SQL」字样,
/// 既表达「编写 SQL 查询」,又与分类按钮的普通文档图标区分。
class SqlDocIcon extends StatelessWidget {
  const SqlDocIcon({super.key, this.size = 21, this.color});

  final double size;

  /// 不传时使用当前主题下的主图标色([AppColors.iconPrimary]),明暗自适应
  final Color? color;

  // 按颜色复用 painter,避免重复分配
  static final Map<Color, _SqlDocPainter> _painterCache = {};

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.of(context).iconPrimary;
    final painter = _painterCache.putIfAbsent(c, () => _SqlDocPainter(c));
    return CustomPaint(size: Size.square(size), painter: painter);
  }
}

class _SqlDocPainter extends CustomPainter {
  final Color color;
  const _SqlDocPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;

    // 描边画笔:文档轮廓
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s / 10
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    // 文档外框:右上角折角(折叠边长 0.12s 的正方形)
    final body = Path()
      ..moveTo(s * 0.24, s * 0.12) // 左上
      ..lineTo(s * 0.64, s * 0.12) // 顶边至折点
      ..lineTo(s * 0.76, s * 0.24) // 折角斜边
      ..lineTo(s * 0.76, s * 0.88) // 右边缘
      ..lineTo(s * 0.24, s * 0.88) // 底边
      ..close(); // 左边缘
    canvas.drawPath(body, stroke);

    // 折角内线:折点 → 右肩
    canvas.drawLine(
        Offset(s * 0.64, s * 0.12), Offset(s * 0.64, s * 0.24), stroke);
    canvas.drawLine(
        Offset(s * 0.64, s * 0.24), Offset(s * 0.76, s * 0.24), stroke);

    // 居中「SQL」字样
    final tp = TextPainter(
      text: TextSpan(
        text: 'SQL',
        style: TextStyle(
          fontSize: s * 0.26,
          fontWeight: FontWeight.w700,
          color: color,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((s - tp.width) / 2, (s - tp.height) / 2));
  }

  @override
  bool shouldRepaint(covariant _SqlDocPainter oldDelegate) =>
      oldDelegate.color != color;
}
