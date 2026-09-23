import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/l10n/locale_config.dart';
import 'package:daro/theme/app_theme.dart';
import 'package:daro/widgets/options_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// 「工具 → 选项… → 常规」的语言切换守护。
//
// 语言入口原来挂在顶部菜单的「语言」子菜单上(点一下立即生效),搬进选项对话框后
// 多了「草稿态」这层语义:下拉里改选不等于生效,只有「确定」才写 AppState。
// 取消必须真的不写 —— 否则对话框的「取消」是个假按钮。

void main() {
  // 选项对话框的「确定」会经 AppState.setLanguageCode → LocaleStore 落盘;
  // 测试宿主里没有 path_provider 插件,不 mock 就抛 MissingPluginException。
  late Directory dir;
  late AppState app;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    dir = await Directory.systemTemp.createTemp('daro_options_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (c) async => dir.path);
    app = AppState();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    // 落盘是 unawaited 的异步写,目录可能还被占着 —— 删不掉就留给系统清理。
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 挂一个「打开选项」按钮再经 [showOptionsDialog] 弹出来。
  ///
  /// 直接把对话框当 home 挂的话,「确定 / 取消」里的 pop 关不掉根路由,
  /// 就测不到「点完关闭」这半条行为。外壳与 main.dart 同构:
  /// Provider + TokenScope 都在 MaterialApp 之上(Dialog 路由才拿得到)。
  /// 语言钉死简体中文:不钉的话「跟随系统」会让本机与 CI 的断言文案不一致。
  Future<void> pumpOptions(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);

    final palette = AppTheme.light;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: Provider<AppPalette>.value(
          value: palette,
          child: TokenScope(
            tokens: palette.toDesktopTokens(),
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: kAppLocalizationsDelegates,
              supportedLocales: kSupportedLocales,
              theme: buildAppTheme(Brightness.light, palette),
              home: Builder(
                builder: (context) => Center(
                  child: Button(
                    text: '打开选项',
                    onPressed: () => showOptionsDialog(context),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开选项'));
    await tester.pumpAndSettle();
  }

  /// 在语言下拉里选一项:展开面板 → 点文案。
  Future<void> pickLanguage(
      WidgetTester tester, String current, String next) async {
    await tester.tap(find.text(current));
    await tester.pumpAndSettle();
    await tester.tap(find.text(next));
    await tester.pumpAndSettle();
  }

  testWidgets('「常规」页显示语言字段,初值取当前生效语言', (tester) async {
    await pumpOptions(tester);

    expect(find.text('选项'), findsOneWidget);
    // 分类树与正文标题各一处
    expect(find.text('常规'), findsNWidgets(2));
    expect(find.text('语言'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);
  });

  testWidgets('点「确定」才把草稿写回 AppState', (tester) async {
    await pumpOptions(tester);
    await pickLanguage(tester, '跟随系统', 'English');
    expect(app.languageCode, isNull, reason: '未点确定前不该写回 AppState');

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(app.languageCode, 'en');
    expect(find.byType(OptionsDialog), findsNothing);
  });

  testWidgets('点「取消」丢弃草稿,语言不变', (tester) async {
    await pumpOptions(tester);
    await pickLanguage(tester, '跟随系统', '日本語');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(app.languageCode, isNull);
    expect(find.byType(OptionsDialog), findsNothing);
  });

  testWidgets('已有手选语言时下拉回显该语言,而不是「跟随系统」', (tester) async {
    app.languageCode = 'ja';
    await pumpOptions(tester);

    expect(find.text('日本語'), findsOneWidget);
    expect(find.text('跟随系统'), findsNothing);
  });
}
