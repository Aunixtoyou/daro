import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 已保存的查询(对象面板「查询」分类的条目):归属于某连接 / 库,
/// 保存一份 SQL 文本,双击可重新打开到查询编辑页。
/// 关联上下文为空表示无归属查询(不显示在任何库的查询面板中)。
class SavedQuery {
  const SavedQuery({
    required this.name,
    required this.connection,
    required this.database,
    required this.sql,
  });

  final String name;
  final String? connection;
  final String? database;
  final String sql;

  /// 同一归属下的业务键(连接|库|名称),同名同归属视为同一条查询
  String get key => '$connection|$database|$name';

  Map<String, dynamic> toJson() => {
        'name': name,
        'connection': connection,
        'database': database,
        'sql': sql,
      };

  static SavedQuery fromJson(Map<String, dynamic> json) => SavedQuery(
        name: json['name'] as String? ?? '',
        connection: json['connection'] as String?,
        database: json['database'] as String?,
        sql: json['sql'] as String? ?? '',
      );
}

/// 已保存查询持久化:存为应用支持目录下的 queries.json。
///
/// 文件结构:
/// ```json
/// { "queries": [ { "name": "...", "connection": "...", "database": "...", "sql": "..." }, ... ] }
/// ```
///
/// 与 [ConnectionStore] 同模式:文件不存在 / 损坏按空列表处理(不阻止
/// 应用启动),保存为全量覆写。
class SavedQueryStore {
  static const _fileName = 'queries.json';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// 读取全部已保存查询;文件不存在或损坏时返回空列表
  Future<List<SavedQuery>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const [];
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return const [];
      final list = json['queries'];
      if (list is! List) return const [];
      return [
        for (final item in list)
          if (item is Map<String, dynamic>) SavedQuery.fromJson(item),
      ];
    } catch (_) {
      // 配置文件损坏不应阻止应用启动,按无已保存查询处理
      return const [];
    }
  }

  /// 全量覆写保存
  Future<void> save(List<SavedQuery> queries) async {
    final file = await _file();
    final json = jsonEncode({
      'queries': [for (final q in queries) q.toJson()],
    });
    await file.writeAsString(json, flush: true);
  }
}
