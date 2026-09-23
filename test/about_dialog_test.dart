import 'package:daro/app/app_state.dart';
import 'package:daro/theme/app_theme.dart';
import 'package:daro/widgets/about_dialog.dart';
import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:daro/l10n/locale_config.dart';

/// 「关于」弹窗的项目主页入口:GitHub / Gitee 双平台 + 问题反馈。
///
/// 守护三件事:
/// ① 三个入口的文案与目标地址(改文案 / 换仓库别偷偷漏掉一个平台);
/// ② 两枚品牌图标真的能加载 —— 资源路径写错、或 `pubspec.yaml` 里漏声明
///    时 `SvgPicture.asset` 会抛,这一条就是那道闸;
/// ③ 点击走系统默认浏览器(externalApplication),不是应用内 webview。

/// 记录 launch 调用的假实现:测试进程里没有 url_launcher 的原生插件,
/// 直接调用会 MissingPluginException,必须替换平台实例才能验证接线。
class _RecordingUrlLauncher extends UrlLauncherPlatform {
  String? lastUrl;
  LaunchOptions? lastOptions;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    lastUrl = url;
    lastOptions = options;
    return true;
  }

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;
}

/// 走真实入口打开弹窗(帮助 → 关于…):弹层挂在 Navigator 上,
/// 所以取色用的 TokenScope 要跟调用点在同一棵树上。
Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: kAppLocalizationsDelegates,
        supportedLocales: kSupportedLocales,
        theme: buildAppTheme(Brightness.light, AppTheme.light),
        home: TokenScope(
          tokens: AppTheme.light.toDesktopTokens(),
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: GestureDetector(
                  onTap: () => showDaroAboutDialog(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// 弹窗里实际用到的 SVG 资源名(Logo + 两枚平台图标)。
List<String> _svgAssets(WidgetTester tester) => tester
    .widgetList<SvgPicture>(find.byType(SvgPicture))
    .map((w) => w.bytesLoader)
    .whereType<SvgAssetLoader>()
    .map((l) => l.assetName)
    .toList();

void main() {
  late _RecordingUrlLauncher fake;

  setUp(() {
    fake = _RecordingUrlLauncher();
    final original = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = fake;
    addTearDown(() => UrlLauncherPlatform.instance = original);
  });

  testWidgets('项目主页同时给出 GitHub / Gitee 两个入口,各带品牌图标', (tester) async {
    await _open(tester);

    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Gitee'), findsOneWidget);
    expect(find.text('问题反馈'), findsOneWidget);

    // 图标能渲染出来即说明资源已随包发布(路径 / pubspec 声明都对)
    expect(_svgAssets(tester), containsAll(<String>[
      'assets/icons/brands/github.svg',
      'assets/icons/brands/gitee.svg',
    ]));
  });

  testWidgets('三个按钮分别打开对应地址,且交给系统默认浏览器', (tester) async {
    await _open(tester);

    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();
    expect(fake.lastUrl, kGithubHomeUrl);
    expect(fake.lastOptions?.mode, PreferredLaunchMode.externalApplication);

    await tester.tap(find.text('Gitee'));
    await tester.pumpAndSettle();
    expect(fake.lastUrl, kGiteeHomeUrl);

    await tester.tap(find.text('问题反馈'));
    await tester.pumpAndSettle();
    expect(fake.lastUrl, kIssuesUrl);
    expect(fake.lastOptions?.mode, PreferredLaunchMode.externalApplication);
  });

  test('两个平台是同一仓库在两个站点的地址', () {
    expect(kGithubHomeUrl, 'https://github.com/SpringHgui/daro');
    expect(kGiteeHomeUrl, 'https://gitee.com/SpringHgui/daro');
    expect(kIssuesUrl, '$kGithubHomeUrl/issues');
  });
}
