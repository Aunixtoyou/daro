import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'db_data.dart';

/// 连接配置持久化:存为应用支持目录下的 connections.json。
///
/// 文件结构:
/// ```json
/// { "connections": [ { "name": "...", "typeId": "mysql", ... }, ... ] }
/// ```
///
/// 密码仅当向导勾选「保存密码」时才会写入(此时 ConnectionInfo.password
/// 非空);本地桌面单机工具,当前以明文保存,后续可换加密存储。
class ConnectionStore {
  static const _fileName = 'connections.json';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// 读取全部连接;文件不存在或损坏时返回空列表(不抛异常,首次启动即此场景)
  Future<List<ConnectionInfo>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const [];
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return const [];
      final list = json['connections'];
      if (list is! List) return const [];
      return [
        for (final item in list)
          if (item is Map<String, dynamic>)
            ConnectionInfo.fromJson(item),
      ];
    } catch (_) {
      // 配置文件损坏不应阻止应用启动,按无连接处理
      return const [];
    }
  }

  /// 全量覆写保存
  Future<void> save(List<ConnectionInfo> connections) async {
    final file = await _file();
    final json = jsonEncode({
      'connections': [for (final c in connections) c.toJson()],
    });
    await file.writeAsString(json, flush: true);
  }
}
