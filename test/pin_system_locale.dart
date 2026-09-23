import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 把测试环境的**系统语言**钉成简体中文。
///
/// 走真实 `DbApp` 的用例不断言中文文案(树分组、标签、状态栏)。`DbApp` 的语言
/// 策略是「用户未显式选择时跟随系统」,而测试机/CI 的系统语言不受本仓库控制,
/// 于是这类断言会在非中文系统上整片飘红。这里在 pump 之前钉住平台 locale,
/// 让「跟随系统」这条分支在测试里有一个确定的落点。
///
/// 只影响 `DbApp` 自己解析 locale;直接 pump `MaterialApp` 的用例语言写死在
/// `locale:` 参数上,无需调用本函数。
void pinSystemChineseLocale(WidgetTester tester) {
  tester.platformDispatcher.localeTestValue = const Locale('zh');
  addTearDown(tester.platformDispatcher.clearLocaleTestValue);
}
