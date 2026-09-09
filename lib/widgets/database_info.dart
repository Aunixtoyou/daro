import 'package:flutter/material.dart';
import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:provider/provider.dart';
import '../app/app_state.dart';
import '../data/db_data.dart';
import '../data/db_types.dart';
import '../theme/app_theme.dart';
import 'object_category_icon.dart';

// 右侧对象详情面板:根据当前选中节点展示不同信息。
// - 选中表节点   -> 表名 + 所属上下文
// - 选中库节点   -> 库名 + 所属连接信息(类型/主机/端口/用户)
// - 选中连接节点 -> 连接信息
// - 未选中       -> 跟随对象页浏览上下文(objectContext)展示库信息,无则空态
class DatabaseInfo extends StatelessWidget {
  const DatabaseInfo({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();

    return ValueListenableBuilder<SelectedNode?>(
      valueListenable: app.detailSelection,
      builder: (context, node, _) {
        if (node != null) {
          switch (node.kind) {
            case NodeKind.table:
              return _TableInfoView(
                table: node.name,
                connection: node.connection,
                database: node.database,
                schema: node.schema,
              );
            case NodeKind.database:
              return _DatabaseInfoView(
                database: node.name,
                connection: node.connection,
              );
            case NodeKind.connection:
              return _ConnectionInfoView(connection: node.name);
            case NodeKind.schema:
              return _SchemaInfoView(
                schema: node.name,
                connection: node.connection,
                database: node.database,
              );
            case NodeKind.tableGroup:
              break;
          }
        }
        // 未选中节点:跟随对象页上下文展示库信息
        final conn = app.objectConnection;
        final db = app.objectDatabase;
        if (conn != null && db != null) {
          return _DatabaseInfoView(database: db, connection: conn);
        }
        return Container(
          color: Tokens.of(context).background,
          child: const Empty(
            icon: Icon(Icons.info_outline),
            title: '在左侧连接树中选择节点查看详情',
            compact: true,
          ),
        );
      },
    );
  }

  /// 按连接名取连接配置,不存在返回 null
  static ConnectionInfo? _find(AppState app, String? name) {
    if (name == null) return null;
    for (final c in app.connections) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// 按类型 id 查 DbType,不存在返回 null
  static DbType? _dbTypeOf(String? typeId) {
    if (typeId == null) return null;
    for (final e in kAllDbTypes) {
      if (e.id == typeId) return e;
    }
    return null;
  }
}

/// 大图标(默认 46px),与连接树同源的自绘 SVG
Widget _navIcon(String asset, {double size = 46}) => UiIcon(asset, size: size);

/// 数据库信息视图(选中库 / 对象页浏览库时展示)
class _DatabaseInfoView extends StatelessWidget {  const _DatabaseInfoView({required this.database, this.connection});

  final String database;
  final String? connection;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final conn = DatabaseInfo._find(context.read<AppState>(), connection);

    return Container(
      color: t.background,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 与连接树同源:数据库绿色圆柱图标
          _navIcon(kDatabaseIcon),
          const SizedBox(height: 8),
          Text(
            database,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: t.foreground),
          ),
          const SizedBox(height: 4),
          Text('数据库', style: TextStyle(fontSize: 12, color: t.mutedForeground)),
          const SizedBox(height: 18),
          if (conn != null) ...[
            _field(t, '连接', conn.name),
            _field(t, '类型', _typeName(conn.typeId)),
            _field(t, '主机', '${conn.host}:${conn.port}'),
            _field(t, '用户', conn.username),
          ],
        ],
      ),
    );
  }
}

/// 模式信息视图(选中模式节点时展示)
class _SchemaInfoView extends StatelessWidget {
  const _SchemaInfoView({required this.schema, this.connection, this.database});

  final String schema;
  final String? connection;
  final String? database;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final conn = DatabaseInfo._find(context.read<AppState>(), connection);

    return Container(
      color: t.background,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 与连接树同源:模式绿色层级图图标
          _navIcon(kSchemaIcon),
          const SizedBox(height: 8),
          Text(
            schema,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: t.foreground),
          ),
          const SizedBox(height: 4),
          Text('模式', style: TextStyle(fontSize: 12, color: t.mutedForeground)),
          const SizedBox(height: 18),
          if (conn != null) ...[
            _field(t, '连接', conn.name),
            _field(t, '类型', _typeName(conn.typeId)),
            _field(t, '主机', '${conn.host}:${conn.port}'),
          ],
          if (database != null) _field(t, '数据库', database!),
        ],
      ),
    );
  }
}

/// 连接信息视图(选中连接节点时展示)
class _ConnectionInfoView extends StatelessWidget {
  const _ConnectionInfoView({required this.connection});

  final String connection;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final conn = DatabaseInfo._find(context.read<AppState>(), connection);
    // 与连接树同源:品牌图标 + 右下角状态点,离线时品牌色去饱和
    final dbType = DatabaseInfo._dbTypeOf(conn?.typeId);
    final connected = conn != null &&
        context.read<AppState>().connectionManager.isConnected(conn.name);

    return Container(
      color: t.background,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (dbType != null)
            DbTypeIcon(type: dbType, size: 46, connected: connected)
          else
            Icon(Icons.dns, size: 46, color: t.mutedForeground),
          const SizedBox(height: 8),
          Text(
            connection,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: t.foreground),
          ),
          const SizedBox(height: 4),
          Text('连接', style: TextStyle(fontSize: 12, color: t.mutedForeground)),
          const SizedBox(height: 18),
          if (conn != null) ...[
            _field(t, '类型', _typeName(conn.typeId)),
            _field(t, '主机', '${conn.host}:${conn.port}'),
            _field(t, '用户', conn.username),
          ],
        ],
      ),
    );
  }
}

/// 表信息视图(选中表时展示)
class _TableInfoView extends StatelessWidget {
  const _TableInfoView({
    required this.table,
    this.connection,
    this.database,
    this.schema,
  });

  final String table;
  final String? connection;
  final String? database;
  final String? schema;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    
    return Container(
      color: t.background,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 与连接树分组同源:表图标
          ObjectCategoryIcon(category: ObjectCategory.table, size: 46),
          const SizedBox(height: 8),
          Text(
            table,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: t.foreground),
          ),
          const SizedBox(height: 4),
          Text('表', style: TextStyle(fontSize: 12, color: t.mutedForeground)),
          const SizedBox(height: 18),
          if (connection != null) _field(t, '连接', connection!),
          if (database != null) _field(t, '数据库', database!),
          if (schema != null) _field(t, '模式', schema!),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.open_in_new, size: 13, color: t.disabledForeground),
              const SizedBox(width: 5),
              Text(
                '双击表可查看前 100 行数据',
                style: TextStyle(fontSize: 12, color: t.disabledForeground),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 按类型 id 查显示名(取 label 首行)
String _typeName(String typeId) {
  for (final type in kAllDbTypes) {
    if (type.id == typeId) return type.label.split('\n').first;
  }
  return typeId;
}

Widget _field(AppPalette t, String label, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: t.mutedForeground)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 13, color: t.foreground)),
      ],
    ),
  );
}
