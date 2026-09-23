import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../l10n/locale_config.dart';

/// 语言偏好持久化:存为应用支持目录下的 locale.json。
///
/// 文件结构:
/// ```json
/// { "languageCode": "ja" }
/// ```
///
/// 文件不存在 / 缺键 / 值不在支持列表内,都按「跟随系统」处理(返回 null),
/// 与 [ThemeStore] 一样:配置损坏绝不阻断应用启动。
class LocaleStore {
  static const _fileName = 'locale.json';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// 读取用户显式选定的语言码;null = 跟随系统。
  Future<String?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return null;
      final code = json['languageCode'];
      if (code is! String) return null;
      return kSupportedLanguageCodes.contains(code) ? code : null;
    } catch (_) {
      return null;
    }
  }

  /// 保存语言码;传 null 表示改回跟随系统(删除文件,不留空壳配置)。
  Future<void> save(String? languageCode) async {
    final file = await _file();
    if (languageCode == null) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.writeAsString(
      jsonEncode({'languageCode': languageCode}),
      flush: true,
    );
  }
}
