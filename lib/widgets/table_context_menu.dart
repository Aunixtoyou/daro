import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../data/db_data.dart';
import 'data_export_wizard.dart';
import 'data_import_wizard.dart';
import 'table_copy_rename_dialog.dart';

// 表实例右键菜单:打开 / 删除 / 清空 / 设计 / 转储SQL / 复制重命名。
// 连接树(database_tree)与对象面板(object_panel)共用本函数,保证两处交互一致。
// 需驱动已建立连接的动作(删除 / 清空 / 设计 / 转储 / 复制重命名)在未连接时禁用;
// 「打开表」与双击行为一致,不强制要求连接(标签页打开后数据页自行加载)。

/// 弹出表实例上下文菜单。
/// [position] 为全局屏幕坐标(直接来自 PointerDownEvent.position)。
void showTableContextMenu({
  required BuildContext context,
  required AppState app,
  required ConnectionInfo conn,
  required String database,
  required String table,
  String? schema,
  required Offset position,
}) {
  final isOpen = app.connectionManager.isConnected(conn.name);
  showContextMenu(
    context,
    position: position,
    items: [
      MenuItem(
        text: '打开表',
        onPressed: () => app.openTable(
          table,
          connection: conn.name,
          database: database,
          schema: schema,
        ),
      ),
      MenuItem(
        text: '删除表',
        enabled: isOpen,
        onPressed: () => _deleteTable(context, app, conn, database, table, schema),
      ),
      MenuItem(
        text: '清空表',
        enabled: isOpen,
        onPressed: () => _clearTable(context, app, conn, database, table, schema),
      ),
      MenuItem(
        text: '设计表',
        enabled: isOpen,
        onPressed: () => app.designTable(
          table,
          connection: conn.name,
          database: database,
          schema: schema,
        ),
      ),
      MenuSeparator(),
      MenuItem(
        text: '转储SQL',
        enabled: isOpen,
        onPressed: () => _dumpTable(context, app, conn, database, table, schema),
      ),
      MenuItem(
        text: '导入向导',
        enabled: isOpen,
        onPressed: () => showDataImportWizard(
          context,
          app: app,
          conn: conn,
          database: database,
          table: table,
          schema: schema,
        ),
      ),
      MenuItem(
        text: '导出向导',
        enabled: isOpen,
        onPressed: () => showDataExportWizard(
          context,
          app: app,
          conn: conn,
          database: database,
          table: table,
          schema: schema,
        ),
      ),
      MenuItem(
        text: '复制重命名',
        enabled: isOpen,
        onPressed: () => _copyRenameTable(context, app, conn, database, table, schema),
      ),
    ],
  );
}

/// 「删除表」:确认后 DROP TABLE 并刷新对象列表
Future<void> _deleteTable(
  BuildContext context,
  AppState app,
  ConnectionInfo conn,
  String database,
  String table,
  String? schema,
) async {
  final result = await MessageBox.show(
    context,
    title: '删除表',
    message: '确定要删除表「$table」吗?\n'
        '此操作会永久删除该表及其所有数据,且不可恢复。',
    type: MessageBoxType.warning,
    buttons: MessageBoxButtons.okCancel,
    okText: '删除',
  );
  if (result != MessageBoxResult.ok || !context.mounted) return;
  final outcome = await app.dropTable(conn, database, table, schema: schema);
  if (!context.mounted) return;
  if (!outcome.ok) {
    MessageBox.show(
      context,
      title: '删除表',
      message: '删除失败:\n${outcome.error}',
      type: MessageBoxType.error,
      okText: '知道了',
    );
  }
}

/// 「清空表」:确认后删除全部行(保留结构)
Future<void> _clearTable(
  BuildContext context,
  AppState app,
  ConnectionInfo conn,
  String database,
  String table,
  String? schema,
) async {
  final result = await MessageBox.show(
    context,
    title: '清空表',
    message: '确定要清空表「$table」吗?\n'
        '此操作会删除该表全部数据(保留表结构),且不可恢复。',
    type: MessageBoxType.warning,
    buttons: MessageBoxButtons.okCancel,
    okText: '清空',
  );
  if (result != MessageBoxResult.ok || !context.mounted) return;
  final outcome =
      await app.truncateTable(conn, database, table, schema: schema);
  if (!context.mounted) return;
  if (!outcome.ok) {
    MessageBox.show(
      context,
      title: '清空表',
      message: '清空失败:\n${outcome.error}',
      type: MessageBoxType.error,
      okText: '知道了',
    );
  }
}

/// 「转储SQL」:选择保存位置,生成该表 CREATE TABLE DDL 并落盘
Future<void> _dumpTable(
  BuildContext context,
  AppState app,
  ConnectionInfo conn,
  String database,
  String table,
  String? schema,
) async {
  final location = await getSaveLocation(
    acceptedTypeGroups: [XTypeGroup(label: 'SQL 文件', extensions: ['sql'])],
    suggestedName: '${table}_structure.sql',
    confirmButtonText: '保存',
  );
  if (location == null || !context.mounted) return;

  final sql = await app.dumpTableSql(conn, database, table, schema: schema);
  if (sql == null || !context.mounted) {
    MessageBox.show(
      context,
      title: '转储SQL',
      message: '结构读取失败:\n表不可用或连接已断开,请先打开连接重试。',
      type: MessageBoxType.error,
      okText: '知道了',
    );
    return;
  }

  try {
    final file = File(location.path);
    await file.writeAsString(sql);
  } catch (e) {
    if (!context.mounted) return;
    MessageBox.show(
      context,
      title: '转储SQL',
      message: '文件写入失败:\n$e',
      type: MessageBoxType.error,
      okText: '知道了',
    );
    return;
  }
  if (!context.mounted) return;
  MessageBox.show(
    context,
    title: '转储SQL',
    message: '已导出「$table」结构(仅结构,不含数据)到:\n${location.path}',
    type: MessageBoxType.info,
    okText: '知道了',
  );
}

/// 「复制重命名」:打开对话框,提供「复制」与「重命名」两个动作
Future<void> _copyRenameTable(
  BuildContext context,
  AppState app,
  ConnectionInfo conn,
  String database,
  String table,
  String? schema,
) async {
  await showDialog<bool>(
    context: context,
    builder: (_) => TableCopyRenameDialog(
      connection: conn,
      database: database,
      tableName: table,
      schema: schema,
    ),
  );
}

/// 例程(函数 / 过程)实例右键菜单:设计 / 删除。
/// 连接树与对象面板共用,保证两处交互一致。
void showRoutineContextMenu({
  required BuildContext context,
  required AppState app,
  required ObjectCategory category,
  required ConnectionInfo conn,
  required String database,
  required String name,
  String? schema,
  required Offset position,
}) {
  final label = category.label;
  final isOpen = app.connectionManager.isConnected(conn.name);
  showContextMenu(
    context,
    position: position,
    items: [
      MenuItem(
        text: '设计$label',
        enabled: isOpen,
        onPressed: () => app.designRoutine(
          name,
          connection: conn.name,
          database: database,
          category: category,
          schema: schema,
        ),
      ),
      MenuItem(
        text: '删除$label',
        enabled: isOpen,
        onPressed: () =>
            _deleteRoutine(context, app, category, conn, database, name, schema),
      ),
    ],
  );
}

/// 「删除例程」:确认后 DROP 并刷新对象列表
Future<void> _deleteRoutine(
  BuildContext context,
  AppState app,
  ObjectCategory category,
  ConnectionInfo conn,
  String database,
  String name,
  String? schema,
) async {
  final label = category.label;
  final result = await MessageBox.show(
    context,
    title: '删除$label',
    message: '确定要删除$label「$name」吗?\n此操作会永久删除该对象,且不可恢复。',
    type: MessageBoxType.warning,
    buttons: MessageBoxButtons.okCancel,
    okText: '删除',
  );
  if (result != MessageBoxResult.ok || !context.mounted) return;
  final failed = await app.dropObjects(
    category,
    [name],
    connection: conn.name,
    database: database,
    schema: schema,
  );
  if (!context.mounted) return;
  if (failed.isNotEmpty) {
    MessageBox.show(
      context,
      title: '删除$label',
      message: '删除失败:\n$failed',
      type: MessageBoxType.error,
      okText: '知道了',
    );
  }
}
