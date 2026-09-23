import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 本地化文件的三条硬不变量。
//
// `flutter gen-l10n` 的 untranslated 报告只查「en/ja 缺不缺 key」,下面这两种坑
// 它都不报:占位符声明与正文里的 {x} 对不上,以及改了 ARB 忘了重新 codegen。
// 生成的方法是**位置参数**,顺序 = ARB 里 placeholders 的**声明顺序**(不是字母序),
// 所以声明顺序与中文正文不一致时调用方极易写反 —— 两种都是 String,编译期查不出来,
// 只能等界面渲染出「约万1.2」这种串。漏 codegen 则是编译期找不到成员。
// 约定:占位符按其在中文正文里出现的先后声明,调用方就能按语序传参。

const _langs = ['zh', 'en', 'ja'];
const _template = 'zh';

Map<String, dynamic> _arb(String lang) => jsonDecode(
      File('lib/l10n/app_$lang.arb').readAsStringSync(),
    ) as Map<String, dynamic>;

/// 正文键(排除 `@@locale` 与 `@key` 形式的元数据)
List<String> _messages(Map<String, dynamic> arb) =>
    arb.keys.where((k) => !k.startsWith('@')).toList()..sort();

Map<String, dynamic> _placeholderDecls(Map<String, dynamic> arb, String key) =>
    ((arb['@$key'] as Map<String, dynamic>?)?['placeholders']
            as Map<String, dynamic>?) ??
        const {};

/// 正文里实际用到的 `{name}` 占位符
Set<String> _usedPlaceholders(String text) =>
    RegExp(r'\{(\w+)\}').allMatches(text).map((m) => m.group(1)!).toSet();

void main() {
  final arbs = {for (final lang in _langs) lang: _arb(lang)};

  test('三种语言的 key 集合完全一致', () {
    final expected = _messages(arbs[_template]!);
    for (final lang in _langs) {
      expect(_messages(arbs[lang]!), expected, reason: 'app_$lang.arb 与模板不符');
    }
  });

  test('占位符:声明与正文引用一一对应,且三种语言同构', () {
    for (final key in _messages(arbs[_template]!)) {
      for (final lang in _langs) {
        final text = arbs[lang]![key]! as String;
        final declared = _placeholderDecls(arbs[lang]!, key).keys.toSet();
        final used = _usedPlaceholders(text);
        expect(used, declared,
            reason: '$key($lang): 正文用了 $used,声明了 $declared');
      }
      // 位置参数按声明顺序生成,所以三种语言的声明**顺序**也要一致,
      // 否则 en/ja 的 override 与模板签名对不上,调用方按语序传参就会错位
      final base = _placeholderDecls(arbs[_template]!, key).keys.toList();
      for (final lang in _langs) {
        final other = _placeholderDecls(arbs[lang]!, key).keys.toList();
        expect(other, base, reason: '$key($lang) 的占位符顺序与模板不一致');
      }
    }
  });

  test('每个 key 都已生成 AppLocalizations 成员(改过 ARB 要重跑 gen-l10n)', () {
    final generated =
        File('lib/l10n/app_localizations.dart').readAsStringSync();
    final missing = <String>[
      for (final key in _messages(arbs[_template]!))
        if (!RegExp('String (?:get )?${RegExp.escape(key)}\\b')
            .hasMatch(generated))
          key,
    ];
    expect(missing, isEmpty,
        reason: '执行 `flutter gen-l10n` 重新生成 lib/l10n/app_localizations*.dart');
  });

  test('生成方法的参数顺序 = 模板占位符声明顺序', () {
    final generated =
        File('lib/l10n/app_localizations.dart').readAsStringSync();
    final mismatched = <String>[];
    for (final key in _messages(arbs[_template]!)) {
      final declared = _placeholderDecls(arbs[_template]!, key).keys.toList();
      if (declared.isEmpty) continue;
      final sig = RegExp('String ${RegExp.escape(key)}\\(([^)]*)\\)')
          .firstMatch(generated);
      if (sig == null) continue; // 上一条测试已按「缺成员」报错
      final params =
          sig.group(1)!.split(',').map((p) => p.trim().split(' ').last).toList();
      if (params.join(',') != declared.join(',')) {
        mismatched.add('$key: 生成 $params,声明 $declared');
      }
    }
    // 顺序错了不会编译报错(都是 String),只会在界面上把两个值对调显示
    expect(mismatched, isEmpty,
        reason: '改过占位符顺序后要重跑 `flutter gen-l10n`');
  });
}
