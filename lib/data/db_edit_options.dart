/// 「编辑数据库」的表单值与**差异 DDL 生成**(PostgreSQL 家族)。
///
/// 与 `db_create_options.dart`(建库:选项 → 全新语句)相对,这里是**改库**:
/// 表单值必须和 [PgDatabaseProps](服务端现状)一起喂进来,只输出真正变化过的
/// 语句 —— 没动的字段一条都不生成,避免「打开对话框点确定」就重放一遍
/// `ALTER DATABASE`(其中 `SET TABLESPACE` 在有其它连接时是会直接报错的)。
///
/// SQL 预览页与「确定」按钮共用 [buildEditDatabaseStatements],保证预览即所见、
/// 保存即所写。
library;

import 'database_edit_catalog.dart';
import 'table_design.dart';

/// 编辑库对话框采集的表单值(全部为「用户想要的最终状态」)
class DatabaseEditForm {
  const DatabaseEditForm({
    this.owner = '',
    this.tablespace = '',
    this.connectionLimit = -1,
    this.allowConnections = true,
    this.isTemplate = false,
    this.comment = '',
    this.installExtensions = const [],
    this.uninstallExtensions = const [],
  });

  /// 所有者角色(空 = 未选,不生成 `OWNER TO`)
  final String owner;

  /// 表空间(空 = 未选,不生成 `SET TABLESPACE`)
  final String tablespace;

  /// 连接限制(`-1` = 无限制)
  final int connectionLimit;

  /// 允许连接(`datallowconn`)
  final bool allowConnections;

  /// 是否模板(`datistemplate`)
  final bool isTemplate;

  /// 库注释(空串 = 无注释;现状有注释时生成 `IS NULL` 清空)
  final String comment;

  /// 待安装扩展(扩展页里用 `>` 从「可用」移到「已安装」的项)
  final List<String> installExtensions;

  /// 待卸载扩展(用 `<` 从「已安装」移回「可用」的项)
  final List<String> uninstallExtensions;
}

/// 库级语句:`ALTER DATABASE` + `COMMENT ON DATABASE`。
///
/// 都按库名寻址,在集群任意会话里都能执行;`SET TABLESPACE` 还额外要求目标库
/// **没有**活动连接,所以调用方更不该把会话切过去(见 `AppState.applyDatabaseEdits`)。
List<String> buildDatabaseLevelEditStatements({
  required String typeId,
  required PgDatabaseProps current,
  required DatabaseEditForm form,
}) {
  final db = DdlBuilder.ident(typeId, current.name);
  final sqls = <String>[];

  final owner = form.owner.trim();
  if (owner.isNotEmpty && owner != current.owner) {
    sqls.add(
        'ALTER DATABASE $db OWNER TO ${DdlBuilder.ident(typeId, owner)}');
  }

  final space = form.tablespace.trim();
  if (space.isNotEmpty && space != current.tablespace) {
    sqls.add(
        'ALTER DATABASE $db SET TABLESPACE ${DdlBuilder.ident(typeId, space)}');
  }

  if (form.connectionLimit != current.connectionLimit) {
    sqls.add(
        'ALTER DATABASE $db WITH CONNECTION LIMIT ${form.connectionLimit}');
  }
  if (form.allowConnections != current.allowConnections) {
    sqls.add('ALTER DATABASE $db WITH ALLOW_CONNECTIONS '
        '${form.allowConnections ? 'true' : 'false'}');
  }
  if (form.isTemplate != current.isTemplate) {
    sqls.add('ALTER DATABASE $db WITH IS_TEMPLATE '
        '${form.isTemplate ? 'true' : 'false'}');
  }

  final comment = form.comment.trim();
  if (comment != current.comment.trim()) {
    sqls.add(comment.isEmpty
        ? 'COMMENT ON DATABASE $db IS NULL'
        : 'COMMENT ON DATABASE $db IS ${DdlBuilder.lit(comment)}');
  }
  return sqls;
}

/// 扩展语句:`DROP EXTENSION` + `CREATE EXTENSION`,必须在目标库上下文执行。
///
/// 卸载排在安装前,让「先撤后装」这类互换在同一批语句里能跑通。
List<String> buildExtensionEditStatements(
  String typeId,
  DatabaseEditForm form,
) {
  final sqls = <String>[];
  for (final ext in form.uninstallExtensions) {
    final e = ext.trim();
    if (e.isEmpty) continue;
    sqls.add('DROP EXTENSION IF EXISTS ${DdlBuilder.ident(typeId, e)}');
  }
  for (final ext in form.installExtensions) {
    final e = ext.trim();
    if (e.isEmpty) continue;
    sqls.add('CREATE EXTENSION IF NOT EXISTS ${DdlBuilder.ident(typeId, e)}');
  }
  return sqls;
}

/// 全部改动语句(不含分号),SQL 预览与「确定」共用的唯一来源;列表为空即
/// 「无改动」。顺序固定为库级属性 → 注释 → 卸载扩展 → 安装扩展。
List<String> buildEditDatabaseStatements({
  required String typeId,
  required PgDatabaseProps current,
  required DatabaseEditForm form,
}) =>
    [
      ...buildDatabaseLevelEditStatements(
          typeId: typeId, current: current, form: form),
      ...buildExtensionEditStatements(typeId, form),
    ];

/// SQL 预览页文本:每条语句一行,分号结尾。
String buildEditDatabaseScript({
  required String typeId,
  required PgDatabaseProps current,
  required DatabaseEditForm form,
}) {
  final sqls =
      buildEditDatabaseStatements(typeId: typeId, current: current, form: form);
  if (sqls.isEmpty) return '-- 没有需要执行的改动';
  return sqls.map((s) => '$s;').join('\n');
}
