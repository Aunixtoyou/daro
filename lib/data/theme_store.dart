import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../theme/app_theme.dart';

/// 主题定制持久化:存为应用支持目录下的 theme_custom.json。
///
/// 文件结构:
/// ```json
/// {
///   "light": { "surface": "#FFFFFFFF", "...": "..." },
///   "dark":  { "surface": "#FF252526", "...": "..." }
/// }
/// ```
///
/// 仅记录被用户定制的亮度色板;未定制时不写入对应键(读取时回退默认)。
class ThemeStore {
  static const _fileName = 'theme_custom.json';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// 读取已定制的明 / 暗色板;文件不存在 / 损坏 / 无定制时返回 null。
  Future<({AppPalette? light, AppPalette? dark})> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return (light: null, dark: null);
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return (light: null, dark: null);
      AppPalette? parse(String key) {
        final v = json[key];
        if (v is! Map<String, dynamic>) return null;
        return AppPalette.fromJson(v);
      }
      return (light: parse('light'), dark: parse('dark'));
    } catch (_) {
      // 配置损坏不应阻止应用启动,按无定制处理
      return (light: null, dark: null);
    }
  }

  /// 全量覆写保存(某一亮度未定制传 null 即可省略)
  Future<void> save(AppPalette? light, AppPalette? dark) async {
    final file = await _file();
    final json = <String, dynamic>{
      if (light != null) 'light': light.toJson(),
      if (dark != null) 'dark': dark.toJson(),
    };
    await file.writeAsString(jsonEncode(json), flush: true);
  }
}
