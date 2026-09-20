import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'db_data.dart';

/// 连接配置持久化:存为应用支持目录下的 connections.json。
///
/// 文件结构:
/// ```json
/// {
///   "connections": [ { "name": "...", "typeId": "mysql", "group": "生产", ... } ],
///   "groups":      [ { "name": "生产" } ]
/// }
/// ```
///
/// `groups` 独立于连接存放,空分组也能存在(见 [ConnGroup]);老文件没有该键时
/// 按「无分组」读取,连接上的 `group` 仍会被树现场建组显示,不会丢连接。
///
/// 密码仅当向导勾选「保存密码」时才会写入(此时 ConnectionInfo.password
/// 非空);本地桌面单机工具,当前以明文保存,后续可换加密存储。
class ConnectionStore {
  static const _fileName = 'connections.json';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// 读取全部连接与分组;文件不存在或损坏时返回两个空列表(不抛异常,首次启动即此场景)
  Future<(List<ConnectionInfo> connections, List<ConnGroup> groups)>
      load() async {
    const empty = (_noConnections, _noGroups);
    try {
      final file = await _file();
      if (!await file.exists()) return empty;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return empty;
      return (_decodeList<ConnectionInfo>(
          json['connections'], ConnectionInfo.fromJson), _decodeList<ConnGroup>(
          json['groups'], ConnGroup.fromJson));
    } catch (_) {
      // 配置文件损坏不应阻止应用启动,按无连接处理
      return empty;
    }
  }

  static const List<ConnectionInfo> _noConnections = [];
  static const List<ConnGroup> _noGroups = [];

  static List<T> _decodeList<T>(
    Object? list,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    if (list is! List) return const [];
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) fromJson(item),
    ];
  }

  /// 全量覆写保存
  Future<void> save(
    List<ConnectionInfo> connections,
    List<ConnGroup> groups,
  ) async {
    final file = await _file();
    final json = jsonEncode({
      'groups': [for (final g in groups) g.toJson()],
      'connections': [for (final c in connections) c.toJson()],
    });
    await file.writeAsString(json, flush: true);
  }
}
