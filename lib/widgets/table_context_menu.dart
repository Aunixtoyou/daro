import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../data/db_data.dart';
import '../l10n/locale_config.dart';
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
  final l = context.l10n;
  final tableLabel = l.catTable;
  showContextMenu(
    context,
    position: position,
    items: [
      MenuItem(
        text: l.actionOpen(tableLabel),
        onPressed: () => app.openTable(
          table,
          connection: conn.name,
          database: database,
          schema: schema,
        ),
      ),
      MenuItem(
        text: l.actionDelete(tableLabel),
        enabled: isOpen,
        onPressed: () => _deleteTable(context, app, conn, database, table, schema),
      ),
      MenuItem(
        text: l.actionClear(tableLabel),
        enabled: isOpen,
        onPressed: () => _clearTable(context, app, conn, database, table, schema),
      ),
      MenuItem(
        text: l.actionDesign(tableLabel),
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
        text: l.ctxDumpSql,
        enabled: isOpen,
        onPressed: () => _dumpTable(context, app, conn, database, table, schema),
      ),
      MenuItem(
        text: l.importWizard,
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
        text: l.exportWizard,
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
        text: l.ctxCopyRename,
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
  final l = context.l10n;
  final title = l.actionDelete(l.catTable);
  final result = await MessageBox.show(
    context,
    title: title,
    message: l.deleteObjectConfirmOne(l.catTable, table),
    type: MessageBoxType.warning,
    buttons: MessageBoxButtons.okCancel,
    okText: l.btnDelete,
  );
  if (result != MessageBoxResult.ok || !context.mounted) return;
  final outcome = await app.dropTable(conn, database, table, schema: schema);
  if (!context.mounted) return;
  if (!outcome.ok) {
    MessageBox.show(
      context,
      title: title,
      message: l.deleteFailedDetail('${outcome.error}'),
      type: MessageBoxType.error,
      okText: l.btnGotIt,
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
  final l = context.l10n;
  final title = l.actionClear(l.catTable);
  final result = await MessageBox.show(
    context,
    title: title,
    message: l.clearConfirmOne(l.catTable, table),
    type: MessageBoxType.warning,
    buttons: MessageBoxButtons.okCancel,
    okText: l.btnClear,
  );
  if (result != MessageBoxResult.ok || !context.mounted) return;
  final outcome =
      await app.truncateTable(conn, database, table, schema: schema);
  if (!context.mounted) return;
  if (!outcome.ok) {
    MessageBox.show(
      context,
      title: title,
      message: l.clearFailedDetail('${outcome.error}'),
      type: MessageBoxType.error,
      okText: l.btnGotIt,
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
  final l = context.l10n;
  final location = await getSaveLocation(
    acceptedTypeGroups: [XTypeGroup(label: l.sqlFileTypeLabel, extensions: ['sql'])],
    suggestedName: '${table}_structure.sql',
    confirmButtonText: l.btnSave,
  );
  if (location == null || !context.mounted) return;

  final sql = await app.dumpTableSql(conn, database, table, schema: schema);
  if (sql == null || !context.mounted) {
    MessageBox.show(
      context,
      title: l.ctxDumpSql,
      message: l.dumpStructureReadFailed,
      type: MessageBoxType.error,
      okText: l.btnGotIt,
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
      title: l.ctxDumpSql,
      message: l.dumpWriteFailed('$e'),
      type: MessageBoxType.error,
      okText: l.btnGotIt,
    );
    return;
  }
  if (!context.mounted) return;
  MessageBox.show(
    context,
    title: l.ctxDumpSql,
    message: l.dumpDatabaseDone(table, location.path),
    type: MessageBoxType.info,
    okText: l.btnGotIt,
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
  final l = context.l10n;
  final label = category.labelOf(l);
  final isOpen = app.connectionManager.isConnected(conn.name);
  showContextMenu(
    context,
    position: position,
    items: [
      MenuItem(
        text: l.actionDesign(label),
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
        text: l.actionDelete(label),
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
  final l = context.l10n;
  final label = category.labelOf(l);
  final title = l.actionDelete(label);
  final result = await MessageBox.show(
    context,
    title: title,
    message: l.deleteObjectConfirmOne(label, name),
    type: MessageBoxType.warning,
    buttons: MessageBoxButtons.okCancel,
    okText: l.btnDelete,
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
      title: title,
      message: l.deleteFailedDetail(failed.join(', ')),
      type: MessageBoxType.error,
      okText: l.btnGotIt,
    );
  }
}
