// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get langFollowSystem => '跟随系统';

  @override
  String get optionsTitle => '选项';

  @override
  String get optionsGeneral => '常规';

  @override
  String get optionsLanguage => '语言';

  @override
  String get optionsLanguageHint => '切换后立即生效,已打开的界面文案一起切换。';

  @override
  String get themeMenuTitle => '主题';

  @override
  String get themeFollowSystem => '跟随系统';

  @override
  String get themeLight => '明亮';

  @override
  String get themeDark => '暗黑';

  @override
  String themeSwitchTooltip(String mode) {
    return '主题:$mode（点击切换）';
  }

  @override
  String get menuFile => '文件';

  @override
  String get menuNewConnection => '新建连接...';

  @override
  String get menuNewQuery => '新建查询';

  @override
  String get menuImportConnections => '导入连接';

  @override
  String get menuExportConnections => '导出连接';

  @override
  String get menuExit => '退出';

  @override
  String get menuView => '视图';

  @override
  String get menuRefresh => '刷新';

  @override
  String get menuThemeCustomize => '主题定制...';

  @override
  String get menuLargeIcons => '大型图标';

  @override
  String get menuSmallIcons => '小图标';

  @override
  String get menuList => '列表';

  @override
  String get menuDetails => '详细信息';

  @override
  String get menuTools => '工具';

  @override
  String get menuCommandLine => '命令列界面...';

  @override
  String get menuDataTransfer => '数据传输...';

  @override
  String get menuDataSync => '数据同步...';

  @override
  String get menuSchemaSync => '结构同步...';

  @override
  String get menuBackup => '备份...';

  @override
  String get menuRestoreBackup => '还原备份...';

  @override
  String get menuMcpService => 'MCP 服务...';

  @override
  String get menuOptions => '选项...';

  @override
  String get menuHelp => '帮助';

  @override
  String get menuIssueTracker => '问题反馈';

  @override
  String get menuAbout => '关于...';

  @override
  String get catTable => '表';

  @override
  String get catView => '视图';

  @override
  String get catMaterializedView => '实体化视图';

  @override
  String get catFunction => '函数';

  @override
  String get catProcedure => '过程';

  @override
  String get catRole => '角色';

  @override
  String get catQuery => '查询';

  @override
  String get catBackup => '备份';

  @override
  String get importDoneTitle => '导入完成';

  @override
  String importDoneMessage(String count) {
    return '已导入 $count 条连接,可在左侧连接树查看。';
  }

  @override
  String importDoneManualPassword(String count) {
    return '其中 $count 条没能带过密码(Navicat 端未保存,或用了旧版加密方式),右键该连接 →「编辑连接」补填后即可正常连接。';
  }

  @override
  String importDoneNewGroups(String count, String names) {
    return '文件里的分组本地不存在,已新建 $count 个:$names。';
  }

  @override
  String get exportDoneTitle => '导出完成';

  @override
  String exportDoneMessage(String count, String path) {
    return '已把 $count 条连接导出到\n$path\n在 Navicat 里用「文件 → 导入连接设置…」选择该文件即可。';
  }

  @override
  String exportDoneSkipped(String names) {
    return 'Navicat 没有对应类型的连接未导出:$names。';
  }

  @override
  String listEllipsisMore(String count) {
    return ' 等 $count 条';
  }

  @override
  String get listEllipsis => ' 等';

  @override
  String get listSeparator => '、';

  @override
  String get issueTrackerTitle => '问题反馈';

  @override
  String issueTrackerOpenFailed(String url) {
    return '无法自动打开浏览器,请在浏览器中访问:\n$url';
  }

  @override
  String get ribbonConnection => '连接';

  @override
  String get ribbonNewQuery => '新建查询';

  @override
  String get tabObjects => '对象';

  @override
  String get tabDesignSuffix => ' (设计)';

  @override
  String get tabNewSuffix => ' (新建)';

  @override
  String get tabCommandLine => '命令列界面';

  @override
  String get tabCtxClose => '关闭';

  @override
  String get tabCtxCloseOthers => '关闭其他选项卡';

  @override
  String get tabCtxCloseRight => '关闭右侧的选项卡';

  @override
  String get tabCtxCloseAll => '全部关闭';

  @override
  String get statusNoDatabase => '未选择数据库';

  @override
  String statusRecordPosition(String current, String total, String page) {
    return '第 $current 条记录（共 $total 条）于第 $page 页';
  }

  @override
  String statusSelectedRows(String count, String total, String page) {
    return '已选 $count 行（共 $total 条）于第 $page 页';
  }

  @override
  String statusObjectsSelected(String count) {
    return '已选择 $count 项';
  }

  @override
  String get tipDetailedLayout => '详细布局';

  @override
  String get tipListLayout => '列表';

  @override
  String get tipLeftPanel => '左侧栏';

  @override
  String get tipRightPanel => '右侧栏';

  @override
  String sqlHistoryTitle(String count) {
    return 'SQL 执行历史 ($count)';
  }

  @override
  String get sqlHistoryLatest => '最新';

  @override
  String get mcpTipDisabled => 'MCP 服务已禁用(点击打开设置)';

  @override
  String get mcpTipCorrupted => 'MCP 策略加载失败(点击查看详情)';

  @override
  String get mcpTipIdle => 'MCP 服务已启用但未监听(点击打开设置)';

  @override
  String get mcpTipRunning => 'MCP 运行中(点击打开设置)';

  @override
  String mcpTipRunningCalls(String count) {
    return 'MCP 运行中 ($count 个调用)';
  }

  @override
  String get infoPickNode => '在左侧连接树中选择节点查看详情';

  @override
  String get infoSectionDatabase => '数据库';

  @override
  String get infoSectionConnection => '连接';

  @override
  String get infoSectionSchema => '模式';

  @override
  String get infoSectionConnGroup => '连接分组';

  @override
  String get infoSectionTable => '表';

  @override
  String get fieldConnection => '连接';

  @override
  String get fieldType => '类型';

  @override
  String get fieldHost => '主机';

  @override
  String get fieldUser => '用户';

  @override
  String get fieldDatabase => '数据库';

  @override
  String get fieldSchema => '模式';

  @override
  String get fieldConnCount => '连接数';

  @override
  String get infoGroupEmpty => '分组为空:把连接右键 →「移动到分组」放进来,或删除该分组。';

  @override
  String get infoTableDoubleClickHint => '双击表可查看前 100 行数据';

  @override
  String get fieldCharset => '字符集';

  @override
  String get fieldCollation => '排序规则';

  @override
  String get fieldRows => '行';

  @override
  String get fieldEngine => '引擎';

  @override
  String get fieldAutoIncrement => '自动递增';

  @override
  String get fieldRowFormat => '行格式';

  @override
  String get fieldCreateTime => '创建日期';

  @override
  String get fieldUpdateTime => '修改日期';

  @override
  String get fieldCheckTime => '检查时间';

  @override
  String get fieldDataLength => '数据长度';

  @override
  String get fieldIndexLength => '索引长度';

  @override
  String get fieldMaxDataLength => '最大数据长度';

  @override
  String get fieldDataFree => '数据可用空间';

  @override
  String get fieldCreateOptions => '创建选项';

  @override
  String get fieldComment => '注释';

  @override
  String infoRowCountEstimate(String count) {
    return '$count (估算)';
  }

  @override
  String get infoFetchRowCount => '获取行数';

  @override
  String get infoFetchingRowCount => '正在统计…';

  @override
  String infoRowCountFailed(String error) {
    return '统计失败:$error';
  }

  @override
  String get infoShare => '共享';

  @override
  String get infoShareTooltip => '复制该对象的引用文本到剪贴板';

  @override
  String get infoShareCopied => '已复制';

  @override
  String get infoPageInfo => '信息';

  @override
  String get infoPageDdl => 'DDL';

  @override
  String get fieldOid => 'OID';

  @override
  String get fieldOwner => '所有者';

  @override
  String get fieldTablespace => '表空间';

  @override
  String get fieldEncoding => '编码';

  @override
  String get fieldLcCollate => '排序规则排序';

  @override
  String get fieldConnectionLimit => '连接限制';

  @override
  String get infoValueNoLimit => '无';

  @override
  String get fieldTableType => 'Table Type';

  @override
  String get tableTypeRegular => '常规';

  @override
  String get tableTypePartitioned => '分区表';

  @override
  String get tableTypeView => '视图';

  @override
  String get tableTypeMatView => '物化视图';

  @override
  String get tableTypeForeign => '外部表';

  @override
  String get fieldPartitionOf => '分区属于';

  @override
  String get fieldInheritsFrom => 'Inherits From';

  @override
  String get fieldHasOids => 'Has OIDs';

  @override
  String get fieldFillFactor => '填充因子';

  @override
  String get fieldAcl => 'ACL';

  @override
  String get infoValueYes => '是';

  @override
  String get infoValueNo => '否';

  @override
  String get infoPageUses => '使用';

  @override
  String get infoPageUsedBy => '被使用';

  @override
  String get infoPageUsesTooltip => '本表所引用的对象';

  @override
  String get infoPageUsedByTooltip => '引用本表的对象';

  @override
  String get infoDepsLoading => '正在读取依赖关系…';

  @override
  String get infoDepsEmpty => '没有依赖对象';

  @override
  String infoDepsFailed(String error) {
    return '依赖读取失败:$error';
  }

  @override
  String get infoMaximizePanel => '加宽详情面板';

  @override
  String get infoRestorePanel => '恢复面板宽度';

  @override
  String infoDetailFailed(String error) {
    return '详情读取失败:$error';
  }

  @override
  String get infoDdlLoading => '正在读取定义…';

  @override
  String get infoDdlUnsupported => '该数据库类型暂不支持显示建表语句。';

  @override
  String infoDdlFailed(String error) {
    return 'DDL 读取失败:$error';
  }

  @override
  String get infoCopyDdl => '复制建表语句';

  @override
  String actionOpen(String label) {
    return '打开$label';
  }

  @override
  String actionDesign(String label) {
    return '设计$label';
  }

  @override
  String actionNew(String label) {
    return '新建$label';
  }

  @override
  String actionDelete(String label) {
    return '删除$label';
  }

  @override
  String get tableKindRegular => '常规';

  @override
  String get tableKindExternal => '外部';

  @override
  String get tableKindPartition => '分区';

  @override
  String get importWizard => '导入向导';

  @override
  String get exportWizard => '导出向导';

  @override
  String actionClear(String label) {
    return '清空$label';
  }

  @override
  String clearConfirmOne(String label, String name) {
    return '确定要清空$label「$name」吗?\n此操作会删除其中全部数据(保留结构),且不可恢复。';
  }

  @override
  String clearFailedDetail(String error) {
    return '清空失败:\n$error';
  }

  @override
  String get btnClear => '清空';

  @override
  String get ctxCopyRename => '复制重命名';

  @override
  String get btnGotIt => '知道了';

  @override
  String get btnDelete => '删除';

  @override
  String get btnPaste => '粘贴';

  @override
  String get btnRetry => '重试';

  @override
  String stubWip(String action) {
    return '$action 功能开发中,敬请期待';
  }

  @override
  String get deleteQueryTitle => '删除查询';

  @override
  String deleteQueryConfirmOne(String name) {
    return '确定要删除查询「$name」吗?\n删除后可重新保存,打开着的查询页不受影响。';
  }

  @override
  String deleteQueryConfirmMany(String count) {
    return '确定要删除选中的 $count 个查询吗?';
  }

  @override
  String deleteObjectConfirmOne(String label, String name) {
    return '确定要删除$label「$name」吗?\n此操作会永久删除该对象,且不可恢复。';
  }

  @override
  String deleteObjectConfirmMany(String count, String label) {
    return '确定要删除选中的 $count 个$label吗?\n此操作会永久删除这些对象,且不可恢复。';
  }

  @override
  String deleteFailedDetail(String error) {
    return '删除失败:\n$error';
  }

  @override
  String loadingObjectsTitle(String database) {
    return '正在加载 $database 的对象列表 ...';
  }

  @override
  String openDatabaseFailedTitle(String database) {
    return '打开 $database 失败';
  }

  @override
  String categoryListFailedTitle(String label) {
    return '$label列表读取失败';
  }

  @override
  String get colName => '名称';

  @override
  String get colRowsEstimated => '行(估算)';

  @override
  String get colComment => '注释';

  @override
  String rowsApprox(String value, String unit) {
    return '约$value$unit';
  }

  @override
  String get rowsUnitSmall => '万';

  @override
  String get rowsUnitLarge => '亿';

  @override
  String get renameTableTitle => '重命名表';

  @override
  String renameFailedDetail(String error) {
    return '重命名失败:\n$error';
  }

  @override
  String copiedTables(String count) {
    return '已复制 $count 张表,Ctrl+V 粘贴为副本';
  }

  @override
  String pasteNeedOpenConnection(String connection) {
    return '请先打开连接「$connection」再粘贴。';
  }

  @override
  String pasteWrongContext(String context) {
    return '粘贴只能回到复制时的连接 / 数据库 / 模式:\n$context';
  }

  @override
  String get pasteTableTitle => '粘贴表';

  @override
  String pasteConfirmDetail(String count, String plan) {
    return '将粘贴创建 $count 张表(结构 + 数据):\n$plan';
  }

  @override
  String pastedTables(String count) {
    return '已粘贴创建 $count 张表';
  }

  @override
  String pasteFailedDetail(String detail) {
    return '粘贴失败:\n$detail';
  }

  @override
  String get catTablePlural => '表';

  @override
  String get catViewPlural => '视图';

  @override
  String get catMaterializedViewPlural => '实体化视图';

  @override
  String get catFunctionPlural => '函数';

  @override
  String get catProcedurePlural => '过程';

  @override
  String get newExternalTable => '新建外部表';

  @override
  String get newPartitionTable => '新建分区表';

  @override
  String openedConnection(String name) {
    return '已打开连接「$name」';
  }

  @override
  String openedDatabase(String name) {
    return '已打开数据库「$name」';
  }

  @override
  String openedSchema(String name) {
    return '已打开模式「$name」';
  }

  @override
  String get openedBare => '已打开';

  @override
  String get closedBare => '已关闭';

  @override
  String closedConnection(String name) {
    return '已关闭连接「$name」';
  }

  @override
  String closedSchema(String name) {
    return '已关闭模式「$name」';
  }

  @override
  String closedDatabase(String name) {
    return '已关闭数据库「$name」';
  }

  @override
  String openedNamed(String name) {
    return '已打开「$name」';
  }

  @override
  String closedNamed(String name) {
    return '已关闭「$name」';
  }

  @override
  String renamedConnection(String newName, String oldName) {
    return '已重命名连接「$oldName」为「$newName」';
  }

  @override
  String renamedTable(String newName, String oldName) {
    return '已重命名表「$oldName」为「$newName」';
  }

  @override
  String movedConnectionToUngrouped(String name) {
    return '已把连接「$name」移到未分组';
  }

  @override
  String movedConnectionToGroup(String group, String name) {
    return '已把连接「$name」移入分组「$group」';
  }

  @override
  String get unnamedGroup => '未命名分组';

  @override
  String unnamedGroupNumbered(String index) {
    return '未命名分组 $index';
  }

  @override
  String get renameGroupTitle => '重命名分组';

  @override
  String groupAlreadyExists(String name) {
    return '已存在同名分组「$name」(不区分大小写)。';
  }

  @override
  String get ctxOpenConnection => '打开连接';

  @override
  String get ctxCloseConnection => '关闭连接';

  @override
  String get ctxOpen => '打开';

  @override
  String get ctxClose => '关闭';

  @override
  String get ctxRefresh => '刷新';

  @override
  String get ctxNewDatabase => '新建数据库';

  @override
  String get ctxEditConnection => '编辑连接';

  @override
  String get ctxCopyConnection => '复制连接';

  @override
  String get ctxMoveToGroup => '移动到分组';

  @override
  String get ctxUngrouped => '未分组';

  @override
  String get ctxNewGroup => '新建分组';

  @override
  String get ctxDeleteConnection => '删除连接';

  @override
  String get ctxNewConnectionEllipsis => '新建连接…';

  @override
  String get ctxRenameGroup => '重命名分组';

  @override
  String get ctxDeleteGroup => '删除分组';

  @override
  String ctxDeleteGroupWith(String count) {
    return '删除分组(含 $count 条连接)';
  }

  @override
  String deleteGroupConfirm(String count, String group) {
    return '删除分组「$group」不会删除其中的 $count 条连接,它们会回落到未分组。继续?';
  }

  @override
  String get btnCancel => '取消';

  @override
  String get btnSave => '保存';

  @override
  String get ctxNewSchema => '新建模式';

  @override
  String get ctxDelete => '删除';

  @override
  String get ctxEditDatabase => '编辑数据库';

  @override
  String get ctxNewQuery => '新建查询';

  @override
  String get ctxDumpSql => '转储SQL文件';

  @override
  String get ctxStructureOnly => '仅结构';

  @override
  String get ctxRunSql => '运行SQL文件';

  @override
  String get ctxCloseSchema => '关闭模式';

  @override
  String get ctxOpenSchema => '打开模式';

  @override
  String get ctxEditSchema => '编辑模式';

  @override
  String get ctxDeleteSchema => '删除模式';

  @override
  String deleteSchemaConfirm(String name) {
    return '确定要删除模式「$name」吗?\n此操作会永久删除该模式及其全部对象,且不可恢复。';
  }

  @override
  String get ctxNewTable => '新建表';

  @override
  String get ctxNewFunction => '新建函数';

  @override
  String get ctxNewProcedure => '新建过程';

  @override
  String get deleteDatabaseTitle => '删除数据库';

  @override
  String deleteDatabaseConfirm(String name) {
    return '确定要删除数据库「$name」吗?\n此操作会永久删除该数据库及其所有数据,且不可恢复。';
  }

  @override
  String get sqlFileTypeLabel => 'SQL 文件';

  @override
  String get dumpStructureReadFailed => '结构读取失败:\n数据库不可用或连接已断开,请先打开连接重试。';

  @override
  String dumpWriteFailed(String error) {
    return '文件写入失败:\n$error';
  }

  @override
  String dumpDatabaseDone(String name, String path) {
    return '已导出「$name」结构(仅结构,不含数据)到:\n$path';
  }

  @override
  String dumpSchemaDone(String name, String path) {
    return '已导出「$name」模式结构(仅结构,不含数据)到:\n$path';
  }

  @override
  String openConnectionUnsupported(String name, String type) {
    return '连接「$name」的数据库类型($type)暂不支持,无法打开。';
  }

  @override
  String openConnectionFailed(String error, String name) {
    return '连接「$name」失败:\n$error';
  }

  @override
  String deleteConnectionConfirm(String name) {
    return '确定要删除连接「$name」吗?\n已打开的该连接标签页仍会保留,但将无法继续访问。';
  }

  @override
  String get noMatchingConnections => '没有匹配的连接';

  @override
  String get noConnectionsYet => '暂无连接';

  @override
  String get clickToolbarNewConnection => '点击工具栏「连接」按钮新建连接';

  @override
  String get dropToUngroup => '释放以移到「未分组」';

  @override
  String get driverNotImplemented => '暂不支持该类型,待实现驱动';

  @override
  String loadFailedDetail(String error) {
    return '加载失败: $error';
  }

  @override
  String get readFailed => '读取失败';

  @override
  String get clickToRetry => '点击重试';

  @override
  String get searchConnectionsHint => '搜索连接...';

  @override
  String get dbTypeFilter => '数据库类型筛选';

  @override
  String get notImplemented => '未实现';

  @override
  String get clearAllFilters => '全部清除';

  @override
  String get collapseAll => '折叠全部';

  @override
  String get cellEditorPickCell => '请先选中一个单元格';

  @override
  String get btnCommitChanges => '确认修改';

  @override
  String rowsCopiedToClipboard(String count) {
    return '已复制 $count 行到剪贴板';
  }

  @override
  String cellMenuSetNull(String count) {
    return '将 $count 个单元格置为 NULL';
  }

  @override
  String cellMenuCopy(String count) {
    return '复制 $count 个单元格';
  }

  @override
  String cellsCopiedToClipboard(String count) {
    return '已复制 $count 个单元格到剪贴板';
  }

  @override
  String cellsClearedToNull(String count, String action) {
    return '已将 $count 个单元格置为 NULL（点「$action」或 Ctrl+S 落库）';
  }

  @override
  String get filterSourceBuilder => '创建工具';

  @override
  String get filterSourceText => '文本';

  @override
  String get toolPanelFilter => '筛选 & 排序';

  @override
  String get toolPanelColumns => '列';

  @override
  String get toolPanelCellEditor => '单元格编辑器';

  @override
  String get btnOk => '确定';

  @override
  String get dtpTime => '时间';

  @override
  String get dtpSelectTime => '选择时间';

  @override
  String get dtpHour => '时';

  @override
  String get dtpMinute => '分';

  @override
  String get dtpSecond => '秒';

  @override
  String get dtpWeekdayMon => '周一';

  @override
  String get dtpWeekdayTue => '周二';

  @override
  String get dtpWeekdayWed => '周三';

  @override
  String get dtpWeekdayThu => '周四';

  @override
  String get dtpWeekdayFri => '周五';

  @override
  String get dtpWeekdaySat => '周六';

  @override
  String get dtpWeekdaySun => '周日';

  @override
  String get catRecord => '记录';

  @override
  String gridPagingFailed(String error) {
    return '分页加载失败: $error';
  }

  @override
  String get gridAlreadyLastPage => '已是最后一页';

  @override
  String gridPageMissing(String page) {
    return '第 $page 页不存在';
  }

  @override
  String get gridDiscardTitle => '放弃未保存的修改';

  @override
  String get gridDiscardConfirm => '当前有未保存的修改，继续将丢弃这些修改。\n是否继续？';

  @override
  String gridDeleteRowConfirm(String row) {
    return '确定要删除第 $row 行记录吗?\n';
  }

  @override
  String gridDeleteRowsConfirm(String count, String preview) {
    return '确定要删除选中的 $count 行记录吗?($preview)\n';
  }

  @override
  String get gridDeletePendingHint => '删除后点击「确认修改」或 Ctrl+S 才会写入数据库。';

  @override
  String get gridNothingToSave => '没有需要保存的修改';

  @override
  String gridConnectionMissing(String connection) {
    return '连接 \"$connection\" 不存在';
  }

  @override
  String gridDeleteRowError(String row, String error) {
    return '删除第 $row 行: $error';
  }

  @override
  String gridInsertRowError(String error) {
    return '新增行: $error';
  }

  @override
  String gridUpdateRowError(String row, String error) {
    return '更新第 $row 行: $error';
  }

  @override
  String gridSavedRows(String count) {
    return '已保存 $count 行修改';
  }

  @override
  String gridSaveFailed(String errors) {
    return '保存失败: $errors';
  }

  @override
  String get gridSaveFailedTitle => '保存失败';

  @override
  String get gridSortMethod => '排序方式';

  @override
  String get gridAddSortCriterion => '添加排序准则';

  @override
  String get gridSortEmptyHint => '点击 + 以添加排序准则';

  @override
  String get gridReadingColumns => '正在读取列信息 …';

  @override
  String get gridFilterEmptyHint => '点击 + 添加筛选条件；选中一行后可在其行尾追加同级条件（+）或括号分组（O+）';

  @override
  String get gridFilter => '筛选';

  @override
  String get gridAddFilterCriterion => '添加筛选条件';

  @override
  String get gridMoveCriterionUp => '上移选中条件';

  @override
  String get gridMoveCriterionDown => '下移选中条件';

  @override
  String get gridNoValueNeeded => '（无需值）';

  @override
  String get gridAddSibling => '在此条件后添加同级条件';

  @override
  String get gridAddGroup => '在此条件后添加括号分组';

  @override
  String get gridDeleteFilterGroup => '删除分组';

  @override
  String get gridDeleteCriterion => '删除条件';

  @override
  String get gridWhereHint => '不含 WHERE 关键字，例如：id > 100 AND name LIKE \'集团%\'';

  @override
  String get gridApplyFilterSort => '应用筛选 & 排序';

  @override
  String get gridCriterionEdited => '已编辑准则';

  @override
  String get gridAsc => '升序';

  @override
  String get gridDesc => '降序';

  @override
  String get gridDeleteSortCriterion => '删除排序准则';

  @override
  String gridColumnsCount(String visible, String total) {
    return '列 ($visible/$total)';
  }

  @override
  String get gridShowAllColumns => '显示所有列';

  @override
  String get gridKeepFirstColumnOnly => '只保留第一列';

  @override
  String get gridLoadingColumns => '正在加载列信息 ...';

  @override
  String get gridSearch => '搜索';

  @override
  String get gridColumnName => '列名';

  @override
  String get cellNoneSelected => '未选中单元格';

  @override
  String cellColumnIndex(String col) {
    return '列 $col';
  }

  @override
  String cellRowIndex(String row) {
    return '  ·  第 $row 行';
  }

  @override
  String cellEditorTitle(String title) {
    return '单元格编辑器 · $title';
  }

  @override
  String get btnApply => '应用';

  @override
  String get btnUndo => '撤销';

  @override
  String get cellEmptyValue => '当前单元格为空';

  @override
  String get cellNotBase64Image => '当前单元格不是可识别的 base64 图片数据';

  @override
  String get cellNotHtml => '当前单元格内容不是 HTML 网页源码';

  @override
  String cellWrittenBack(String action) {
    return '已写回单元格（点「$action」或 Ctrl+S 落库）';
  }

  @override
  String get cellMenuSetBlank => '设置为空白字符串';

  @override
  String get cellMenuSetNullCell => '设置为 NULL';

  @override
  String get gridSort => '排序';

  @override
  String gridSortAscBy(String column) {
    return '升序（$column）';
  }

  @override
  String gridSortDescBy(String column) {
    return '降序（$column）';
  }

  @override
  String get gridClearSort => '取消排序';

  @override
  String get gridMoreSorting => '更多排序...';

  @override
  String gridHideColumn(String column) {
    return '隐藏「$column」';
  }

  @override
  String get gridColumnsPanel => '列面板...';

  @override
  String get gridMoreFilters => '更多筛选...';

  @override
  String get gridClearFilter => '清除筛选';

  @override
  String get gridRemoveAllSortFilter => '移除所有排序及筛选';

  @override
  String get gridShow => '显示';

  @override
  String get gridShowAll => '全部记录';

  @override
  String get gridShowNullOnly => '仅含 NULL 值的记录';

  @override
  String get gridShowNotNullOnly => '仅不含 NULL 值的记录';

  @override
  String get gridClipboardEmpty => '剪贴板为空';

  @override
  String get gridClipboardNoRecords => '剪贴板里没有可粘贴的记录';

  @override
  String gridPastedRows(String count) {
    return '已粘贴 $count 行为新增记录(未保存)';
  }

  @override
  String get gridRowCountUnknown => '  ·  行数未知';

  @override
  String gridRowCount(String total) {
    return '  ·  $total 行';
  }

  @override
  String gridLoadingTable(String table) {
    return '正在加载 $table ...';
  }

  @override
  String gridReadTableFailed(String table) {
    return '读取 $table 失败';
  }

  @override
  String get gridFilterDirty => '筛选 / 排序有未应用的更改';

  @override
  String get gridFilterApplied => '已应用筛选 / 排序';

  @override
  String get gridAddRecord => '添加记录';

  @override
  String get gridDeleteSelectedRecords => '删除选中记录';

  @override
  String get gridSaving => '保存中...';

  @override
  String get gridRevertChanges => '取消修改';

  @override
  String get gridStop => '停止';

  @override
  String gridPagerRange(String from, String to, String total) {
    return '第 $from-$to 条 / 共 $total 条';
  }

  @override
  String get gridPageSize => '页大小设置';

  @override
  String gridRowsPerPage(String size) {
    return '$size 条/页';
  }

  @override
  String get cliEmptyHint => '输入 SQL 语句后按回车执行。语句以分号结尾;未写完可继续输入下一行,↑ / ↓ 翻历史。';

  @override
  String get cliInputHint => '输入 SQL 语句';
}
