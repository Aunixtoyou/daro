// 版本号一致性守卫:pubspec.yaml 是唯一数据源,其余消费端一律由
// tool/gen_version.py 生成。任何一处忘了重新生成就会在 CI 直接失败,
// 而不是打出"安装包 1.0.0 / 关于对话框 0.1.0"这种自相矛盾的包。
// 运行:flutter test test/app_version_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:daro/app/version.g.dart';

/// 从 `key: value` 形式的文本里取第一个匹配值。
String? _match(RegExp re, String text) => re.firstMatch(text)?.group(1);

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final raw = _match(RegExp(r'^version:\s*([0-9][^\s]*)$', multiLine: true), pubspec);

  test('pubspec.yaml 声明了合法版本', () {
    expect(raw, isNotNull, reason: 'pubspec.yaml 缺少形如 `version: 0.1.0+1` 的行');
    expect(raw, matches(RegExp(r'^\d+\.\d+\.\d+(\+\d+)?$')));
  });

  test('version.g.dart 与 pubspec.yaml 同步', () {
    final parts = raw!.split('+');
    expect(kAppVersion, parts.first,
        reason: '请运行 python tool/gen_version.py 后提交 lib/app/version.g.dart');
    expect(kAppBuild, parts.length > 1 ? parts[1] : '0');
    expect(kAppVersionFull, raw);
  });

  test('installer/windows/version.inc 与 pubspec.yaml 同步', () {
    final inc = File('installer/windows/version.inc');
    expect(inc.existsSync(), isTrue, reason: '缺少生成文件,运行 python tool/gen_version.py');
    final text = inc.readAsStringSync();
    final base = _match(RegExp(r'#define PubAppVersion "([^"]*)"'), text);
    final full = _match(RegExp(r'#define PubAppVersionFull "([^"]*)"'), text);
    expect(base, raw!.split('+').first,
        reason: '安装包版本会与 pubspec 不一致,请重新生成 version.inc');
    expect(full, raw);
  });

  test('业务代码里没有第二处硬编码版本号', () {
    // 允许 version.g.dart 自己出现字面量,其余 lib/**.dart 里 "版本 x.y.z" 一律视为分叉。
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('version.g.dart')) continue;
      if (entity.readAsStringSync().contains(RegExp(r'版本\s*\d+\.\d+\.\d+'))) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty, reason: '版本号只能来自 version.g.dart:${offenders.join(', ')}');
  });
}
