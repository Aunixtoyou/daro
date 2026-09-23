// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get langFollowSystem => 'Follow System';

  @override
  String get optionsTitle => 'Options';

  @override
  String get optionsGeneral => 'General';

  @override
  String get optionsLanguage => 'Language';

  @override
  String get optionsLanguageHint =>
      'Takes effect immediately; open views switch with it.';

  @override
  String get themeMenuTitle => 'Theme';

  @override
  String get themeFollowSystem => 'Follow System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String themeSwitchTooltip(String mode) {
    return 'Theme: $mode (click to switch)';
  }

  @override
  String get menuFile => 'File';

  @override
  String get menuNewConnection => 'New Connection...';

  @override
  String get menuNewQuery => 'New Query';

  @override
  String get menuImportConnections => 'Import Connections';

  @override
  String get menuExportConnections => 'Export Connections';

  @override
  String get menuExit => 'Exit';

  @override
  String get menuView => 'View';

  @override
  String get menuRefresh => 'Refresh';

  @override
  String get menuThemeCustomize => 'Customize Theme...';

  @override
  String get menuLargeIcons => 'Large Icons';

  @override
  String get menuSmallIcons => 'Small Icons';

  @override
  String get menuList => 'List';

  @override
  String get menuDetails => 'Details';

  @override
  String get menuTools => 'Tools';

  @override
  String get menuCommandLine => 'Command Line Interface...';

  @override
  String get menuDataTransfer => 'Data Transfer...';

  @override
  String get menuDataSync => 'Data Sync...';

  @override
  String get menuSchemaSync => 'Schema Sync...';

  @override
  String get menuBackup => 'Backup...';

  @override
  String get menuRestoreBackup => 'Restore Backup...';

  @override
  String get menuMcpService => 'MCP Server...';

  @override
  String get menuOptions => 'Options...';

  @override
  String get menuHelp => 'Help';

  @override
  String get menuIssueTracker => 'Report an Issue';

  @override
  String get menuAbout => 'About...';

  @override
  String get catTable => 'Table';

  @override
  String get catView => 'View';

  @override
  String get catMaterializedView => 'Materialized View';

  @override
  String get catFunction => 'Function';

  @override
  String get catProcedure => 'Procedure';

  @override
  String get catRole => 'Roles';

  @override
  String get catQuery => 'Query';

  @override
  String get catBackup => 'Backup';

  @override
  String get importDoneTitle => 'Import complete';

  @override
  String importDoneMessage(String count) {
    return 'Imported $count connections. See them in the connection tree on the left.';
  }

  @override
  String importDoneManualPassword(String count) {
    return '$count of them carried no password (Navicat had none saved, or used an older encryption). Right-click such a connection and choose Edit Connection to fill it in.';
  }

  @override
  String importDoneNewGroups(String count, String names) {
    return '$count groups did not exist locally and were created: $names.';
  }

  @override
  String get exportDoneTitle => 'Export complete';

  @override
  String exportDoneMessage(String count, String path) {
    return 'Exported $count connections to\n$path\nIn Navicat, use File | Import Connection Settings and pick this file.';
  }

  @override
  String exportDoneSkipped(String names) {
    return 'Not exported, because Navicat has no matching connection type: $names.';
  }

  @override
  String listEllipsisMore(String count) {
    return ' and $count more';
  }

  @override
  String get listEllipsis => ' etc.';

  @override
  String get listSeparator => ', ';

  @override
  String get issueTrackerTitle => 'Report an issue';

  @override
  String issueTrackerOpenFailed(String url) {
    return 'Could not open your browser automatically. Please visit:\n$url';
  }

  @override
  String get ribbonConnection => 'Connection';

  @override
  String get ribbonNewQuery => 'New Query';

  @override
  String get tabObjects => 'Objects';

  @override
  String get tabDesignSuffix => ' (Design)';

  @override
  String get tabNewSuffix => ' (New)';

  @override
  String get tabCommandLine => 'Command Line';

  @override
  String get tabCtxClose => 'Close';

  @override
  String get tabCtxCloseOthers => 'Close Other Tabs';

  @override
  String get tabCtxCloseRight => 'Close Tabs to the Right';

  @override
  String get tabCtxCloseAll => 'Close All Tabs';

  @override
  String get statusNoDatabase => 'No database selected';

  @override
  String statusRecordPosition(String current, String total, String page) {
    return 'Record $current of $total, page $page';
  }

  @override
  String statusSelectedRows(String count, String total, String page) {
    return '$count of $total rows selected, page $page';
  }

  @override
  String statusObjectsSelected(String count) {
    return '$count selected';
  }

  @override
  String get tipDetailedLayout => 'Detailed layout';

  @override
  String get tipListLayout => 'List';

  @override
  String get tipLeftPanel => 'Left panel';

  @override
  String get tipRightPanel => 'Right panel';

  @override
  String sqlHistoryTitle(String count) {
    return 'SQL history ($count)';
  }

  @override
  String get sqlHistoryLatest => 'Latest';

  @override
  String get mcpTipDisabled =>
      'MCP server is disabled (click to open settings)';

  @override
  String get mcpTipCorrupted =>
      'Failed to load the MCP policy (click for details)';

  @override
  String get mcpTipIdle =>
      'MCP server is enabled but not listening (click to open settings)';

  @override
  String get mcpTipRunning => 'MCP server is running (click to open settings)';

  @override
  String mcpTipRunningCalls(String count) {
    return 'MCP server is running ($count calls)';
  }

  @override
  String get infoPickNode =>
      'Select a node in the connection tree to see its details';

  @override
  String get infoSectionDatabase => 'Database';

  @override
  String get infoSectionConnection => 'Connection';

  @override
  String get infoSectionSchema => 'Schema';

  @override
  String get infoSectionConnGroup => 'Connection group';

  @override
  String get infoSectionTable => 'Table';

  @override
  String get fieldConnection => 'Connection';

  @override
  String get fieldType => 'Type';

  @override
  String get fieldHost => 'Host';

  @override
  String get fieldUser => 'User';

  @override
  String get fieldDatabase => 'Database';

  @override
  String get fieldSchema => 'Schema';

  @override
  String get fieldConnCount => 'Connections';

  @override
  String get infoGroupEmpty =>
      'The group is empty. Right-click a connection and choose Move to Group, or delete this group.';

  @override
  String get infoTableDoubleClickHint =>
      'Double-click a table to browse its first 100 rows';

  @override
  String get fieldCharset => 'Character Set';

  @override
  String get fieldCollation => 'Collation';

  @override
  String get fieldRows => 'Rows';

  @override
  String get fieldEngine => 'Engine';

  @override
  String get fieldAutoIncrement => 'Auto Increment';

  @override
  String get fieldRowFormat => 'Row Format';

  @override
  String get fieldCreateTime => 'Created';

  @override
  String get fieldUpdateTime => 'Last Modified';

  @override
  String get fieldCheckTime => 'Last Checked';

  @override
  String get fieldDataLength => 'Data Length';

  @override
  String get fieldIndexLength => 'Index Length';

  @override
  String get fieldMaxDataLength => 'Max Data Length';

  @override
  String get fieldDataFree => 'Data Free';

  @override
  String get fieldCreateOptions => 'Create Options';

  @override
  String get fieldComment => 'Comment';

  @override
  String infoRowCountEstimate(String count) {
    return '$count (Est.)';
  }

  @override
  String get infoFetchRowCount => 'Get row count';

  @override
  String get infoFetchingRowCount => 'Counting...';

  @override
  String infoRowCountFailed(String error) {
    return 'Count failed: $error';
  }

  @override
  String get infoShare => 'Share';

  @override
  String get infoShareTooltip =>
      'Copy this object\'s reference text to the clipboard';

  @override
  String get infoShareCopied => 'Copied';

  @override
  String get infoPageInfo => 'Information';

  @override
  String get infoPageDdl => 'DDL';

  @override
  String get fieldOid => 'OID';

  @override
  String get fieldOwner => 'Owner';

  @override
  String get fieldTablespace => 'Tablespace';

  @override
  String get fieldEncoding => 'Encoding';

  @override
  String get fieldLcCollate => 'LC_COLLATE';

  @override
  String get fieldConnectionLimit => 'Connection Limit';

  @override
  String get infoValueNoLimit => 'Unlimited';

  @override
  String get fieldTableType => 'Table Type';

  @override
  String get tableTypeRegular => 'Regular';

  @override
  String get tableTypePartitioned => 'Partitioned table';

  @override
  String get tableTypeView => 'View';

  @override
  String get tableTypeMatView => 'Materialized view';

  @override
  String get tableTypeForeign => 'Foreign table';

  @override
  String get fieldPartitionOf => 'Partition Of';

  @override
  String get fieldInheritsFrom => 'Inherits From';

  @override
  String get fieldHasOids => 'Has OIDs';

  @override
  String get fieldFillFactor => 'Fill Factor';

  @override
  String get fieldAcl => 'ACL';

  @override
  String get infoValueYes => 'Yes';

  @override
  String get infoValueNo => 'No';

  @override
  String get infoPageUses => 'Uses';

  @override
  String get infoPageUsedBy => 'Used By';

  @override
  String get infoPageUsesTooltip => 'Objects this table depends on';

  @override
  String get infoPageUsedByTooltip => 'Objects referencing this table';

  @override
  String get infoDepsLoading => 'Reading dependencies...';

  @override
  String get infoDepsEmpty => 'No dependent objects';

  @override
  String infoDepsFailed(String error) {
    return 'Failed to read dependencies: $error';
  }

  @override
  String get infoMaximizePanel => 'Widen the details panel';

  @override
  String get infoRestorePanel => 'Restore panel width';

  @override
  String infoDetailFailed(String error) {
    return 'Could not read details: $error';
  }

  @override
  String get infoDdlLoading => 'Reading definition...';

  @override
  String get infoDdlUnsupported =>
      'This database type cannot show its CREATE statement.';

  @override
  String infoDdlFailed(String error) {
    return 'Could not read DDL: $error';
  }

  @override
  String get infoCopyDdl => 'Copy CREATE statement';

  @override
  String actionOpen(String label) {
    return 'Open $label';
  }

  @override
  String actionDesign(String label) {
    return 'Design $label';
  }

  @override
  String actionNew(String label) {
    return 'New $label';
  }

  @override
  String actionDelete(String label) {
    return 'Delete $label';
  }

  @override
  String get tableKindRegular => 'Regular';

  @override
  String get tableKindExternal => 'External';

  @override
  String get tableKindPartition => 'Partition';

  @override
  String get importWizard => 'Import Wizard';

  @override
  String get exportWizard => 'Export Wizard';

  @override
  String actionClear(String label) {
    return 'Truncate $label';
  }

  @override
  String clearConfirmOne(String label, String name) {
    return 'Truncate $label \"$name\"?\nThis deletes all rows but keeps the structure, and cannot be undone.';
  }

  @override
  String clearFailedDetail(String error) {
    return 'Could not truncate:\n$error';
  }

  @override
  String get btnClear => 'Truncate';

  @override
  String get ctxCopyRename => 'Copy / Rename';

  @override
  String get btnGotIt => 'OK';

  @override
  String get btnDelete => 'Delete';

  @override
  String get btnPaste => 'Paste';

  @override
  String get btnRetry => 'Retry';

  @override
  String stubWip(String action) {
    return '$action is not implemented yet';
  }

  @override
  String get deleteQueryTitle => 'Delete Query';

  @override
  String deleteQueryConfirmOne(String name) {
    return 'Delete the query \"$name\"?\nYou can save it again later; open query tabs are not affected.';
  }

  @override
  String deleteQueryConfirmMany(String count) {
    return 'Delete the $count selected queries?';
  }

  @override
  String deleteObjectConfirmOne(String label, String name) {
    return 'Delete $label \"$name\"?\nThis permanently removes the object and cannot be undone.';
  }

  @override
  String deleteObjectConfirmMany(String count, String label) {
    return 'Delete the $count selected $label?\nThis permanently removes them and cannot be undone.';
  }

  @override
  String deleteFailedDetail(String error) {
    return 'Delete failed:\n$error';
  }

  @override
  String loadingObjectsTitle(String database) {
    return 'Loading objects of $database ...';
  }

  @override
  String openDatabaseFailedTitle(String database) {
    return 'Could not open $database';
  }

  @override
  String categoryListFailedTitle(String label) {
    return 'Could not read the $label list';
  }

  @override
  String get colName => 'Name';

  @override
  String get colRowsEstimated => 'Rows (est.)';

  @override
  String get colComment => 'Comment';

  @override
  String rowsApprox(String value, String unit) {
    return '~$value$unit';
  }

  @override
  String get rowsUnitSmall => 'K';

  @override
  String get rowsUnitLarge => 'M';

  @override
  String get renameTableTitle => 'Rename Table';

  @override
  String renameFailedDetail(String error) {
    return 'Rename failed:\n$error';
  }

  @override
  String copiedTables(String count) {
    return 'Copied $count table(s) - press Ctrl+V to paste copies';
  }

  @override
  String pasteNeedOpenConnection(String connection) {
    return 'Open the connection \"$connection\" before pasting.';
  }

  @override
  String pasteWrongContext(String context) {
    return 'Tables can only be pasted into the connection / database / schema they were copied from:\n$context';
  }

  @override
  String get pasteTableTitle => 'Paste Tables';

  @override
  String pasteConfirmDetail(String count, String plan) {
    return 'Create $count table(s) (structure + data):\n$plan';
  }

  @override
  String pastedTables(String count) {
    return 'Pasted $count table(s)';
  }

  @override
  String pasteFailedDetail(String detail) {
    return 'Paste failed:\n$detail';
  }

  @override
  String get catTablePlural => 'Tables';

  @override
  String get catViewPlural => 'Views';

  @override
  String get catMaterializedViewPlural => 'Materialized Views';

  @override
  String get catFunctionPlural => 'Functions';

  @override
  String get catProcedurePlural => 'Procedures';

  @override
  String get newExternalTable => 'New External Table';

  @override
  String get newPartitionTable => 'New Partitioned Table';

  @override
  String openedConnection(String name) {
    return 'Opened connection \"$name\"';
  }

  @override
  String openedDatabase(String name) {
    return 'Opened database \"$name\"';
  }

  @override
  String openedSchema(String name) {
    return 'Opened schema \"$name\"';
  }

  @override
  String get openedBare => 'Opened';

  @override
  String get closedBare => 'Closed';

  @override
  String closedConnection(String name) {
    return 'Closed connection \"$name\"';
  }

  @override
  String closedSchema(String name) {
    return 'Closed schema \"$name\"';
  }

  @override
  String closedDatabase(String name) {
    return 'Closed database \"$name\"';
  }

  @override
  String openedNamed(String name) {
    return 'Opened \"$name\"';
  }

  @override
  String closedNamed(String name) {
    return 'Closed \"$name\"';
  }

  @override
  String renamedConnection(String newName, String oldName) {
    return 'Renamed connection \"$oldName\" to \"$newName\"';
  }

  @override
  String renamedTable(String newName, String oldName) {
    return 'Renamed table \"$oldName\" to \"$newName\"';
  }

  @override
  String movedConnectionToUngrouped(String name) {
    return 'Moved connection \"$name\" out of any group';
  }

  @override
  String movedConnectionToGroup(String group, String name) {
    return 'Moved connection \"$name\" into group \"$group\"';
  }

  @override
  String get unnamedGroup => 'Unnamed Group';

  @override
  String unnamedGroupNumbered(String index) {
    return 'Unnamed Group $index';
  }

  @override
  String get renameGroupTitle => 'Rename Group';

  @override
  String groupAlreadyExists(String name) {
    return 'A group named \"$name\" already exists (names are case-insensitive).';
  }

  @override
  String get ctxOpenConnection => 'Open Connection';

  @override
  String get ctxCloseConnection => 'Close Connection';

  @override
  String get ctxOpen => 'Open';

  @override
  String get ctxClose => 'Close';

  @override
  String get ctxRefresh => 'Refresh';

  @override
  String get ctxNewDatabase => 'New Database';

  @override
  String get ctxEditConnection => 'Edit Connection';

  @override
  String get ctxCopyConnection => 'Copy Connection';

  @override
  String get ctxMoveToGroup => 'Move to Group';

  @override
  String get ctxUngrouped => 'Ungrouped';

  @override
  String get ctxNewGroup => 'New Group';

  @override
  String get ctxDeleteConnection => 'Delete Connection';

  @override
  String get ctxNewConnectionEllipsis => 'New Connection…';

  @override
  String get ctxRenameGroup => 'Rename Group';

  @override
  String get ctxDeleteGroup => 'Delete Group';

  @override
  String ctxDeleteGroupWith(String count) {
    return 'Delete Group ($count connections)';
  }

  @override
  String deleteGroupConfirm(String count, String group) {
    return 'Deleting the group \"$group\" keeps its $count connection(s); they move back to Ungrouped. Continue?';
  }

  @override
  String get btnCancel => 'Cancel';

  @override
  String get btnSave => 'Save';

  @override
  String get ctxNewSchema => 'New Schema';

  @override
  String get ctxDelete => 'Delete';

  @override
  String get ctxEditDatabase => 'Edit Database';

  @override
  String get ctxNewQuery => 'New Query';

  @override
  String get ctxDumpSql => 'Dump SQL File';

  @override
  String get ctxStructureOnly => 'Structure Only';

  @override
  String get ctxRunSql => 'Run SQL File';

  @override
  String get ctxCloseSchema => 'Close Schema';

  @override
  String get ctxOpenSchema => 'Open Schema';

  @override
  String get ctxEditSchema => 'Edit Schema';

  @override
  String get ctxDeleteSchema => 'Delete Schema';

  @override
  String deleteSchemaConfirm(String name) {
    return 'Delete schema \"$name\"?\nThis permanently removes the schema and every object in it, and cannot be undone.';
  }

  @override
  String get ctxNewTable => 'New Table';

  @override
  String get ctxNewFunction => 'New Function';

  @override
  String get ctxNewProcedure => 'New Procedure';

  @override
  String get deleteDatabaseTitle => 'Delete Database';

  @override
  String deleteDatabaseConfirm(String name) {
    return 'Delete database \"$name\"?\nThis permanently removes the database and all of its data, and cannot be undone.';
  }

  @override
  String get sqlFileTypeLabel => 'SQL files';

  @override
  String get dumpStructureReadFailed =>
      'Could not read the structure:\nThe database is unavailable or the connection is closed. Open the connection and try again.';

  @override
  String dumpWriteFailed(String error) {
    return 'Could not write the file:\n$error';
  }

  @override
  String dumpDatabaseDone(String name, String path) {
    return 'Exported the structure of \"$name\" (structure only, no data) to:\n$path';
  }

  @override
  String dumpSchemaDone(String name, String path) {
    return 'Exported the structure of schema \"$name\" (structure only, no data) to:\n$path';
  }

  @override
  String openConnectionUnsupported(String name, String type) {
    return 'The database type ($type) of connection \"$name\" is not supported yet, so it cannot be opened.';
  }

  @override
  String openConnectionFailed(String error, String name) {
    return 'Could not connect to \"$name\":\n$error';
  }

  @override
  String deleteConnectionConfirm(String name) {
    return 'Delete connection \"$name\"?\nTabs opened from it stay, but can no longer be used.';
  }

  @override
  String get noMatchingConnections => 'No matching connections';

  @override
  String get noConnectionsYet => 'No connections yet';

  @override
  String get clickToolbarNewConnection =>
      'Use the Connection button on the toolbar to add one';

  @override
  String get dropToUngroup => 'Release to move to Ungrouped';

  @override
  String get driverNotImplemented => 'This type has no driver yet';

  @override
  String loadFailedDetail(String error) {
    return 'Could not load: $error';
  }

  @override
  String get readFailed => 'Could not read';

  @override
  String get clickToRetry => 'Click to retry';

  @override
  String get searchConnectionsHint => 'Search connections...';

  @override
  String get dbTypeFilter => 'Filter by database type';

  @override
  String get notImplemented => 'Not implemented';

  @override
  String get clearAllFilters => 'Clear all';

  @override
  String get collapseAll => 'Collapse all';

  @override
  String get cellEditorPickCell => 'Select a cell first';

  @override
  String get btnCommitChanges => 'Commit Changes';

  @override
  String rowsCopiedToClipboard(String count) {
    return 'Copied $count row(s) to clipboard';
  }

  @override
  String cellMenuSetNull(String count) {
    return 'Set $count cell(s) to NULL';
  }

  @override
  String cellMenuCopy(String count) {
    return 'Copy $count cell(s)';
  }

  @override
  String cellsCopiedToClipboard(String count) {
    return 'Copied $count cell(s) to clipboard';
  }

  @override
  String cellsClearedToNull(String count, String action) {
    return 'Set $count cell(s) to NULL — $action or Ctrl+S to save';
  }

  @override
  String get filterSourceBuilder => 'Builder';

  @override
  String get filterSourceText => 'Text';

  @override
  String get toolPanelFilter => 'Filter & Sort';

  @override
  String get toolPanelColumns => 'Columns';

  @override
  String get toolPanelCellEditor => 'Cell Editor';

  @override
  String get btnOk => 'OK';

  @override
  String get dtpTime => 'Time';

  @override
  String get dtpSelectTime => 'Select Time';

  @override
  String get dtpHour => 'hr';

  @override
  String get dtpMinute => 'min';

  @override
  String get dtpSecond => 'sec';

  @override
  String get dtpWeekdayMon => 'Mon';

  @override
  String get dtpWeekdayTue => 'Tue';

  @override
  String get dtpWeekdayWed => 'Wed';

  @override
  String get dtpWeekdayThu => 'Thu';

  @override
  String get dtpWeekdayFri => 'Fri';

  @override
  String get dtpWeekdaySat => 'Sat';

  @override
  String get dtpWeekdaySun => 'Sun';

  @override
  String get catRecord => 'record';

  @override
  String gridPagingFailed(String error) {
    return 'Failed to load page: $error';
  }

  @override
  String get gridAlreadyLastPage => 'Already on the last page';

  @override
  String gridPageMissing(String page) {
    return 'Page $page does not exist';
  }

  @override
  String get gridDiscardTitle => 'Discard Unsaved Changes';

  @override
  String get gridDiscardConfirm =>
      'You have unsaved changes. Continuing will discard them.\nContinue?';

  @override
  String gridDeleteRowConfirm(String row) {
    return 'Delete row $row?\n';
  }

  @override
  String gridDeleteRowsConfirm(String count, String preview) {
    return 'Delete the $count selected rows? ($preview)\n';
  }

  @override
  String get gridDeletePendingHint =>
      'Nothing is written until you click Commit Changes or press Ctrl+S.';

  @override
  String get gridNothingToSave => 'Nothing to save';

  @override
  String gridConnectionMissing(String connection) {
    return 'Connection \"$connection\" no longer exists';
  }

  @override
  String gridDeleteRowError(String row, String error) {
    return 'Delete row $row: $error';
  }

  @override
  String gridInsertRowError(String error) {
    return 'Insert row: $error';
  }

  @override
  String gridUpdateRowError(String row, String error) {
    return 'Update row $row: $error';
  }

  @override
  String gridSavedRows(String count) {
    return 'Saved $count row(s)';
  }

  @override
  String gridSaveFailed(String errors) {
    return 'Save failed: $errors';
  }

  @override
  String get gridSaveFailedTitle => 'Save Failed';

  @override
  String get gridSortMethod => 'Sort order';

  @override
  String get gridAddSortCriterion => 'Add sort criterion';

  @override
  String get gridSortEmptyHint => 'Click + to add a sort criterion';

  @override
  String get gridReadingColumns => 'Reading column info …';

  @override
  String get gridFilterEmptyHint =>
      'Click + to add a filter. Select a row to append a sibling criterion (+) or a parenthesised group (O+) at its end.';

  @override
  String get gridFilter => 'Filter';

  @override
  String get gridAddFilterCriterion => 'Add filter criterion';

  @override
  String get gridMoveCriterionUp => 'Move selected criterion up';

  @override
  String get gridMoveCriterionDown => 'Move selected criterion down';

  @override
  String get gridNoValueNeeded => '(no value needed)';

  @override
  String get gridAddSibling => 'Add a sibling criterion after this one';

  @override
  String get gridAddGroup => 'Add a parenthesised group after this one';

  @override
  String get gridDeleteFilterGroup => 'Delete group';

  @override
  String get gridDeleteCriterion => 'Delete criterion';

  @override
  String get gridWhereHint =>
      'Without the WHERE keyword, e.g. id > 100 AND name LIKE \'Acme%\'';

  @override
  String get gridApplyFilterSort => 'Apply Filter & Sort';

  @override
  String get gridCriterionEdited => 'Criterion edited';

  @override
  String get gridAsc => 'Ascending';

  @override
  String get gridDesc => 'Descending';

  @override
  String get gridDeleteSortCriterion => 'Delete sort criterion';

  @override
  String gridColumnsCount(String visible, String total) {
    return 'Columns ($visible/$total)';
  }

  @override
  String get gridShowAllColumns => 'Show all columns';

  @override
  String get gridKeepFirstColumnOnly => 'Keep first column only';

  @override
  String get gridLoadingColumns => 'Loading column info ...';

  @override
  String get gridSearch => 'Search';

  @override
  String get gridColumnName => 'Column name';

  @override
  String get cellNoneSelected => 'No cell selected';

  @override
  String cellColumnIndex(String col) {
    return 'Column $col';
  }

  @override
  String cellRowIndex(String row) {
    return '  ·  row $row';
  }

  @override
  String cellEditorTitle(String title) {
    return 'Cell Editor · $title';
  }

  @override
  String get btnApply => 'Apply';

  @override
  String get btnUndo => 'Revert';

  @override
  String get cellEmptyValue => 'Cell is empty';

  @override
  String get cellNotBase64Image =>
      'This cell is not recognised base64 image data';

  @override
  String get cellNotHtml => 'This cell does not contain HTML source';

  @override
  String cellWrittenBack(String action) {
    return 'Written back to the cell — $action or Ctrl+S to save';
  }

  @override
  String get cellMenuSetBlank => 'Set to empty string';

  @override
  String get cellMenuSetNullCell => 'Set to NULL';

  @override
  String get gridSort => 'Sort';

  @override
  String gridSortAscBy(String column) {
    return 'Ascending ($column)';
  }

  @override
  String gridSortDescBy(String column) {
    return 'Descending ($column)';
  }

  @override
  String get gridClearSort => 'Clear sort';

  @override
  String get gridMoreSorting => 'More sorting...';

  @override
  String gridHideColumn(String column) {
    return 'Hide \"$column\"';
  }

  @override
  String get gridColumnsPanel => 'Columns panel...';

  @override
  String get gridMoreFilters => 'More filters...';

  @override
  String get gridClearFilter => 'Clear filter';

  @override
  String get gridRemoveAllSortFilter => 'Remove all sorting and filters';

  @override
  String get gridShow => 'Show';

  @override
  String get gridShowAll => 'All records';

  @override
  String get gridShowNullOnly => 'Records with NULL only';

  @override
  String get gridShowNotNullOnly => 'Records without NULL';

  @override
  String get gridClipboardEmpty => 'Clipboard is empty';

  @override
  String get gridClipboardNoRecords => 'No pasteable records on the clipboard';

  @override
  String gridPastedRows(String count) {
    return 'Pasted $count row(s) as new records (not saved)';
  }

  @override
  String get gridRowCountUnknown => '  ·  row count unknown';

  @override
  String gridRowCount(String total) {
    return '  ·  $total rows';
  }

  @override
  String gridLoadingTable(String table) {
    return 'Loading $table ...';
  }

  @override
  String gridReadTableFailed(String table) {
    return 'Failed to read $table';
  }

  @override
  String get gridFilterDirty => 'Filter / sort has unapplied changes';

  @override
  String get gridFilterApplied => 'Filter / sort applied';

  @override
  String get gridAddRecord => 'Add Record';

  @override
  String get gridDeleteSelectedRecords => 'Delete Selected Records';

  @override
  String get gridSaving => 'Saving...';

  @override
  String get gridRevertChanges => 'Revert';

  @override
  String get gridStop => 'Stop';

  @override
  String gridPagerRange(String from, String to, String total) {
    return '$from-$to of $total';
  }

  @override
  String get gridPageSize => 'Page Size';

  @override
  String gridRowsPerPage(String size) {
    return '$size rows/page';
  }

  @override
  String get cliEmptyHint =>
      'Type a SQL statement and press Enter. Statements end with a semicolon; keep typing to continue an unfinished one, use ↑ / ↓ for history.';

  @override
  String get cliInputHint => 'Enter a SQL statement';
}
