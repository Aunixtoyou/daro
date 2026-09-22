import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/mcp_service.dart';
import 'package:daro/theme/app_theme.dart';
import 'package:daro/widgets/mcp_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// MCP 设置对话框的**版式**守护(与 mcp_settings_dialog_test.dart 的纯逻辑轨互补)。
//
// 起源:「工具与限额」页的「查询超时(秒)」一行,三个双字标签(只读 / 读写 / 完全)
// 被套在 `SizedBox(width: 8)` 里 —— 8 逻辑像素连一个字都放不下,`Text` 只能竖排
// 折成两行,行高翻倍后溢出画到数值框上,看起来就是文字糊成一团。这类"盒子给窄了"
// 的错误不会抛 RenderFlex 溢出(行高是取最高子项),只能靠量渲染尺寸兜住。

void main() {
  /// 把对话框挂起来并切到「工具与限额」页。
  Future<void> pumpToolTab(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);

    final palette = AppTheme.light;
    await tester.pumpWidget(
      ChangeNotifierProvider<McpService>.value(
        value: McpService(loadConnections: () async => const []),
        child: Provider<AppPalette>.value(
          value: palette,
          child: TokenScope(
            tokens: palette.toDesktopTokens(),
            child: MaterialApp(
              theme: buildAppTheme(Brightness.light, palette),
              home: const Center(child: McpSettingsDialog()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('工具与限额'));
    await tester.pumpAndSettle();
  }

  /// 取树里所有该文案的段落渲染尺寸。
  List<Size> renderedSizes(WidgetTester tester, String text) => [
        for (final element in find.text(text).evaluate())
          (element.renderObject as RenderBox).size,
      ];

  testWidgets('「查询超时」三档标签单行放下,不被挤成竖排', (tester) async {
    await pumpToolTab(tester);

    // 11.5 字号 × 1.4 行高 ≈ 16.1;折成两行会到 32 左右。留一点余量判"单行"。
    const oneLineMax = 20.0;
    for (final label in ['只读', '读写', '完全']) {
      final sizes = renderedSizes(tester, label);
      expect(sizes, isNotEmpty, reason: '找不到标签 $label');
      for (final size in sizes) {
        expect(size.height, lessThan(oneLineMax),
            reason: '$label 被挤成了多行(行高 ${size.height}),会溢出画到数值框上');
        expect(size.width, greaterThan(12),
            reason: '$label 的渲染宽度只有 ${size.width},盒子给窄了');
      }
    }
  });

  testWidgets('三档标签与各自的数值框同行且左缘递增', (tester) async {
    await pumpToolTab(tester);

    final rows = [
      for (final label in ['只读', '读写', '完全']) tester.getCenter(find.text(label)),
    ];
    for (final center in rows) {
      expect(center.dy, closeTo(rows.first.dy, 1.0), reason: '三个标签不在同一行');
    }
    expect(rows[1].dx, greaterThan(rows[0].dx));
    expect(rows[2].dx, greaterThan(rows[1].dx));
  });
}
