import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/theme/app_theme.dart';
import 'package:daro/widgets/object_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 对象面板的铬件层级守护。
///
/// 对象面板正文实测是纯白(#FFFFFF),宽度只有两百来逻辑像素 —— 面板里唯一
/// 会把它压成"发灰"的就是铺满整宽的那条工具条。工具条底色必须取**内容底色**
/// (`AppPalette.background`),不能取铬件灰(`surface` / `control`):
/// 一条实心浅灰色带在窄面板里的视觉权重远大于它在宽面板里的占比。
void main() {
  Future<AppState> pumpObjectPanel(
    WidgetTester tester, {
    ThemeMode mode = ThemeMode.light,
  }) async {
    final app = AppState();
    app.setThemeMode(mode);
    final palette = mode == ThemeMode.dark ? AppTheme.dark : AppTheme.light;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          Provider<AppPalette>.value(value: palette),
          Provider<AppColors>.value(
              value: mode == ThemeMode.dark
                  ? AppColors.dark
                  : AppColors.light),
        ],
        child: TokenScope(
          tokens: palette.toDesktopTokens(),
          child: MaterialApp(
            theme: ThemeData(brightness: Brightness.light),
            home: const Material(
              type: MaterialType.transparency,
              child: ObjectPanel(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return app;
  }

  DesktopTokens stripTokens(WidgetTester tester) {
    final strip = tester.widget<ToolStrip>(find.byType(ToolStrip));
    return strip.tokens!;
  }

  testWidgets('明亮主题:工具条底色 = 内容白(不是铬件灰)', (tester) async {
    await pumpObjectPanel(tester);
    final tokens = stripTokens(tester);
    expect(tokens.controlColor, AppTheme.light.background);
    expect(tokens.controlColor, isNot(AppTheme.light.surface),
        reason: '工具条若用 surface 会在窄面板里连成一条灰带');
    expect(tokens.controlColor, isNot(AppTheme.light.control));
  });

  testWidgets('暗色主题:工具条同样跟随内容底色', (tester) async {
    await pumpObjectPanel(tester, mode: ThemeMode.dark);
    final tokens = stripTokens(tester);
    expect(tokens.controlColor, AppTheme.dark.background);
  });

  testWidgets('hover / pressed 由工具条底色派生,亮色下更深', (tester) async {
    await pumpObjectPanel(tester);
    final tokens = stripTokens(tester);
    final base = AppTheme.light.background.computeLuminance();
    expect(tokens.controlHoverColor.computeLuminance(), lessThan(base));
    expect(tokens.controlPressedColor.computeLuminance(),
        lessThan(tokens.controlHoverColor.computeLuminance()),
        reason: '按下应比悬浮更明显');
  });
}
