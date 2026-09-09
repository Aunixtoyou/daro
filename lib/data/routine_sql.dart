import '../app/app_state.dart';

/// 例程参数(函数向导第 2 步采集)。
/// [mode]:PostgreSQL / MySQL / MariaDB 为 IN / OUT / INOUT;
/// SQL Server 为 'OUTPUT'(输出参数)或 ''(普通参数)。
class RoutineParam {
  RoutineParam({this.mode = 'IN', this.name = '', this.type = ''});

  String mode;
  String name;
  String type;
}

/// 例程 SQL 生成 / 解析工具:
/// 按数据库类型生成 CREATE FUNCTION / CREATE PROCEDURE 模板,
/// 并把模板(或驱动返回的定义)解析回 参数签名 / 返回类型 / 语言 /
/// 安全定义者 / 函数体,供「高级」「SQL 预览」「注释」标签使用。
///
/// 模板格式固定(向导 + 新建设计页共用),解析器只识别本文件生成的格式;
/// 用户手动改写的 SQL 无法识别时返回 null,UI 退化为默认值并提示。
class RoutineSql {
  RoutineSql._();

  /// 无模式层(MySQL / MariaDB / SQLite / Access)时不需要默认模式;
  /// PostgreSQL 默认 public,SQL Server 默认 dbo
  static String? defaultSchema(String typeId) => switch (typeId) {
        'postgresql' => 'public',
        'sqlserver' => 'dbo',
        _ => null,
      };

  /// 数据库类型是否支持例程(函数 / 过程)概念
  static bool supportsRoutine(String typeId) => const {
        'mysql',
        'mariadb',
        'postgresql',
        'sqlserver',
      }.contains(typeId);

  /// 是否支持过程(PostgreSQL 11+ 才支持;低版本由服务端报错,驱动仍列出)
  static bool supportsProcedure(String typeId) => supportsRoutine(typeId);

  /// 数据库类型是否支持 COMMENT ON(仅 PostgreSQL 有例程注释语法)
  static bool supportsCommentOn(String typeId) => typeId == 'postgresql';

  /// 函数默认返回类型(新建模板使用)
  static String defaultReturnType(String typeId) => switch (typeId) {
        'postgresql' => 'integer',
        'sqlserver' => 'INT',
        _ => 'INT',
      };

  /// PostgreSQL 默认过程语言
  static String defaultLanguage(String typeId) =>
      typeId == 'postgresql' ? 'plpgsql' : '';

  /// 数据库类型可选的过程语言列表(仅 PostgreSQL 有意义)
  static List<String> languagesOf(String typeId) => switch (typeId) {
        'postgresql' => const ['plpgsql', 'sql', 'plpython3u'],
        _ => const [],
      };

  /// 参数模式候选(按数据库类型)
  static List<String> modesOf(String typeId) => switch (typeId) {
        'sqlserver' => const ['', 'OUTPUT'],
        _ => const ['IN', 'OUT', 'INOUT'],
      };

  /// 按类型引用的对象名(如 "public"."test" / `test` / [dbo].[test])
  static String qualifiedName(String typeId, String name, {String? schema}) {
    final s = (schema == null || schema.isEmpty)
        ? defaultSchema(typeId)
        : schema;
    switch (typeId) {
      case 'postgresql':
      case 'sqlite':
        final q = (v) => '"${v.replaceAll('"', '""')}"';
        return s == null ? q(name) : '${q(s)}.${q(name)}';
      case 'sqlserver':
      case 'access':
        final q = (v) => '[${v.replaceAll(']', ']]')}]';
        return s == null ? q(name) : '${q(s)}.${q(name)}';
      default: // mysql / mariadb:Database 即 Schema,不做二级限定
        return '`${name.replaceAll('`', '``')}`';
    }
  }

  /// 由参数列表生成签名文本(按数据库类型):
  /// - PostgreSQL / MySQL / MariaDB:`IN a INT, IN b VARCHAR(50)`
  /// - SQL Server:`@a INT, @b VARCHAR(50) OUTPUT`
  static String signature(String typeId, List<RoutineParam> params) {
    final parts = <String>[];
    for (final p in params) {
      final name = p.name.trim();
      final type = p.type.trim();
      if (name.isEmpty && type.isEmpty) continue;
      final n = name.isEmpty ? 'arg${parts.length + 1}' : name;
      final ty = type.isEmpty ? 'INT' : type;
      if (typeId == 'sqlserver') {
        final pn = n.startsWith('@') ? n : '@$n';
        parts.add(p.mode == 'OUTPUT' ? '$pn $ty OUTPUT' : '$pn $ty');
      } else {
        final mode = p.mode.trim().isEmpty ? 'IN' : p.mode.trim();
        parts.add('$mode $n $ty');
      }
    }
    return parts.join(', ');
  }

  /// 生成新建模板(函数体为默认占位,用户在设计页「定义」标签中编辑)。
  /// [params] 为空列表时生成空参数签名 `()`(函数)或无参数(过程)。
  /// 注释不嵌入模板:由设计页「注释」标签单独管理,保存时作为 COMMENT ON
  /// 执行(仅 PG;见 [commentOnSql])
  static String buildTemplate({
    required String typeId,
    required ObjectCategory category,
    required String name,
    String? schema,
    List<RoutineParam> params = const [],
    String returnType = '',
    String language = '',
    bool securityDefiner = false,
  }) {
    final sig = signature(typeId, params);
    final qualified = qualifiedName(typeId, name, schema: schema);
    final isFunction = category == ObjectCategory.function;
    final ret =
        isFunction ? (returnType.trim().isEmpty ? defaultReturnType(typeId) : returnType.trim()) : '';
    final lang = language.trim().isEmpty ? defaultLanguage(typeId) : language.trim();

    final buf = StringBuffer();
    switch (typeId) {
      case 'postgresql':
        final kw = isFunction ? 'FUNCTION' : 'PROCEDURE';
        buf.writeln('CREATE OR REPLACE $kw $qualified($sig)');
        if (isFunction && ret.isNotEmpty) buf.writeln('RETURNS $ret');
        if (lang.isNotEmpty) buf.writeln('LANGUAGE $lang');
        if (securityDefiner) buf.writeln('SECURITY DEFINER');
        buf.writeln('AS \$BODY\$');
        buf.writeln(_defaultBody(isFunction, indent: '  '));
        buf.writeln('\$BODY\$;');
      case 'sqlserver':
        final kw = isFunction ? 'FUNCTION' : 'PROCEDURE';
        buf.writeln('CREATE $kw $qualified');
        if (isFunction) {
          buf.writeln('  ($sig)');
          if (ret.isNotEmpty) buf.writeln('RETURNS $ret');
        } else if (sig.isNotEmpty) {
          buf.writeln('  ${sig.replaceAll(', ', ',\n  ')}');
        }
        buf.writeln('AS');
        buf.writeln('BEGIN');
        buf.writeln(_defaultBody(isFunction, indent: '  '));
        buf.writeln('END;');
      default: // mysql / mariadb
        final kw = isFunction ? 'FUNCTION' : 'PROCEDURE';
        buf.writeln('CREATE $kw $qualified($sig)');
        if (isFunction && ret.isNotEmpty) buf.writeln('RETURNS $ret');
        buf.writeln('BEGIN');
        buf.writeln(_defaultBody(isFunction, indent: '  '));
        buf.writeln('END;');
    }
    return buf.toString().trimRight() + '\n';
  }

  /// 用指定函数体重建完整 SQL(「高级」标签「应用」时调用)。
  /// [signature] 为参数签名原文(解析自当前 SQL),[body] 为函数体原文。
  static String buildWithBody({
    required String typeId,
    required ObjectCategory category,
    required String name,
    String? schema,
    required String signature,
    required String body,
    String returnType = '',
    String language = '',
    bool securityDefiner = false,
  }) {
    final qualified = qualifiedName(typeId, name, schema: schema);
    final isFunction = category == ObjectCategory.function;
    final ret =
        isFunction ? (returnType.trim().isEmpty ? defaultReturnType(typeId) : returnType.trim()) : '';
    final lang = language.trim().isEmpty ? defaultLanguage(typeId) : language.trim();
    final bodyText = body.trimRight();

    final buf = StringBuffer();
    switch (typeId) {
      case 'postgresql':
        final kw = isFunction ? 'FUNCTION' : 'PROCEDURE';
        buf.writeln('CREATE OR REPLACE $kw $qualified($signature)');
        if (isFunction && ret.isNotEmpty) buf.writeln('RETURNS $ret');
        if (lang.isNotEmpty) buf.writeln('LANGUAGE $lang');
        if (securityDefiner) buf.writeln('SECURITY DEFINER');
        buf.writeln('AS \$BODY\$');
        // writeln 自带换行:body 以 \n 结尾时不追加,避免空行
        buf.write(bodyText);
        if (!bodyText.endsWith('\n')) buf.writeln();
        buf.writeln('\$BODY\$;');
      case 'sqlserver':
        final kw = isFunction ? 'FUNCTION' : 'PROCEDURE';
        buf.writeln('CREATE $kw $qualified');
        if (isFunction) {
          buf.writeln('  ($signature)');
          if (ret.isNotEmpty) buf.writeln('RETURNS $ret');
        } else if (signature.isNotEmpty) {
          buf.writeln('  ${signature.replaceAll(', ', ',\n  ')}');
        }
        buf.writeln('AS');
        buf.writeln('BEGIN');
        buf.write(bodyText);
        if (!bodyText.endsWith('\n')) buf.writeln();
        buf.writeln('END;');
      default:
        final kw = isFunction ? 'FUNCTION' : 'PROCEDURE';
        buf.writeln('CREATE $kw $qualified($signature)');
        if (isFunction && ret.isNotEmpty) buf.writeln('RETURNS $ret');
        buf.writeln('BEGIN');
        buf.write(bodyText);
        if (!bodyText.endsWith('\n')) buf.writeln();
        buf.writeln('END;');
    }
    return buf.toString().trimRight() + '\n';
  }

  /// PG 的 COMMENT ON 语句(供保存时执行;其它类型返回空)
  static String commentOnSql({
    required String typeId,
    required ObjectCategory category,
    required String name,
    String? schema,
    required String signature,
    required String comment,
  }) {
    if (!supportsCommentOn(typeId)) return '';
    final c = comment.trim();
    if (c.isEmpty) return '';
    final qualified = qualifiedName(typeId, name, schema: schema);
    final kw = category == ObjectCategory.function ? 'FUNCTION' : 'PROCEDURE';
    final esc = c.replaceAll("'", "''");
    return "COMMENT ON $kw $qualified($signature) IS '$esc';";
  }

  /// 默认函数体(新建模板占位)
  static String _defaultBody(bool isFunction, {required String indent}) {
    if (isFunction) {
      return '$indent-- Routine body goes here...\n${indent}RETURN 0;';
    }
    return '$indent-- Routine body goes here...';
  }
}

/// 解析结果(模板 / 定义文本的结构化视图)
class RoutineParsed {
  const RoutineParsed({
    required this.signature,
    required this.returnType,
    required this.language,
    required this.securityDefiner,
    required this.body,
  });

  /// 参数签名原文(如 "IN a INT, IN b VARCHAR(50)")
  final String signature;

  /// 函数返回类型(过程为空)
  final String returnType;

  /// 过程语言(PG 等;其它为空)
  final String language;

  /// 是否 SECURITY DEFINER(PG)
  final bool securityDefiner;

  /// 函数体原文(不含包裹符 / BEGIN END)
  final String body;
}

/// 解析例程 SQL,提取 参数签名 / 返回类型 / 语言 / 安全定义者 / 函数体。
/// 仅识别 [RoutineSql] 生成的模板格式及常见变体(PG 的 $function$ / $$ 包裹、
/// 驱动 SHOW CREATE 输出);无法识别返回 null。
RoutineParsed? parseRoutineSql(
  String sql, {
  required String typeId,
  required ObjectCategory category,
}) {
  if (sql.trim().isEmpty) return null;
  final isFunction = category == ObjectCategory.function;

  switch (typeId) {
    case 'postgresql':
      final m = RegExp(
        r'^CREATE(?:\s+OR\s+REPLACE)?\s+(FUNCTION|PROCEDURE)\s+'
        r'(?:"[\w\s]+"(?:\s*\.\s*"?[\w\s]+"?)?|[\[\]"\w]+)\s*'
        r'\((?<params>[^\n]*)\)',
        caseSensitive: false,
        multiLine: true,
      ).firstMatch(sql.trim());
      if (m == null) return null;
      final params = m.namedGroup('params')!.trim();
      final ret = isFunction
          ? RegExp(r'RETURNS\s+(?<ret>[^\n]+)', caseSensitive: false)
              .firstMatch(sql)
              ?.namedGroup('ret')
              ?.trim() ?? ''
          : '';
      final lang = RegExp(r'LANGUAGE\s+(?<lang>\w+)', caseSensitive: false)
              .firstMatch(sql)
              ?.namedGroup('lang') ?? '';
      final sec = RegExp(r'SECURITY\s+DEFINER', caseSensitive: false)
          .hasMatch(sql);
      final body = _extractDollarBody(sql);
      if (body == null) return null;
      return RoutineParsed(
        signature: params,
        returnType: ret,
        language: lang,
        securityDefiner: sec,
        body: body,
      );
    case 'mysql':
    case 'mariadb':
      final m = RegExp(
        r'^CREATE\s+(FUNCTION|PROCEDURE)\s+'
        r'`?[\w$]+`?(?:\s*\.\s*`?[\w$]+`?)?\s*'
        r'\((?<params>[^\n]*)\)',
        caseSensitive: false,
      ).firstMatch(sql.trim());
      if (m == null) return null;
      final params = m.namedGroup('params')!.trim();
      final ret = isFunction
          ? RegExp(r'RETURNS\s+(?<ret>\S+)', caseSensitive: false)
              .firstMatch(sql)
              ?.namedGroup('ret')
              ?.trim() ?? ''
          : '';
      final body = _extractBeginEnd(sql);
      if (body == null) return null;
      return RoutineParsed(
        signature: params,
        returnType: ret,
        language: '',
        securityDefiner: false,
        body: body,
      );
    case 'sqlserver':
      // 函数:CREATE FUNCTION [dbo].[name] (@a INT) RETURNS INT AS BEGIN ... END
      // 过程:CREATE PROCEDURE [dbo].[name] @a INT, @b INT OUTPUT AS BEGIN ... END
      final kwMatch = RegExp(
        r'^CREATE\s+(FUNCTION|PROCEDURE)\s+'
        r'\[?[\w\s#]+\]?(?:\s*\.\s*\[?[\w\s]+\]?)?',
        caseSensitive: false,
      ).firstMatch(sql.trim());
      if (kwMatch == null) return null;
      final head = sql.substring(kwMatch.end).trimLeft();
      String params;
      if (isFunction) {
        final pm = RegExp(r'^\((?<params>[^\n]*)\)', caseSensitive: false)
            .firstMatch(head);
        if (pm == null) return null;
        params = pm.namedGroup('params')!.trim();
      } else {
        // 过程:参数为 AS 之前的整段,去掉行尾分号
        final asIdx = RegExp(r'\bAS\b', caseSensitive: false)
            .allMatches(head)
            .map((m) => m.start)
            .lastOrNull;
        if (asIdx == null) return null;
        final paramText = head
            .substring(0, asIdx)
            .trim()
            .replaceAll(RegExp(r'^\s*\(\s*|\s*\)\s*$'), '')
            // 行尾逗号去掉,避免与换行替换产生的 ',,' 连排
            .replaceAll(RegExp(r',\s*\n'), '\n')
            .replaceAll(RegExp(r'\s*\n\s*'), ', ');
        params = paramText.trim();
      }
      final ret = isFunction
          ? RegExp(r'RETURNS\s+(?<ret>[^\n]+)', caseSensitive: false)
              .firstMatch(sql)
              ?.namedGroup('ret')
              ?.trim() ?? ''
          : '';
      final body = _extractBeginEnd(sql);
      if (body == null) return null;
      return RoutineParsed(
        signature: params,
        returnType: ret,
        language: '',
        securityDefiner: false,
        body: body,
      );
    default:
      return null;
  }
}

/// 提取 PG 的 $tag$ ... $tag$ 函数体(支持 \$BODY\$ / \$function\$ / \$\$ 等)
String? _extractDollarBody(String sql) {
  final m = RegExp(r'AS\s+\$(?<tag>\w*)\$\s*\n(?<body>[\s\S]*?)\n\$(?<tag2>\w*)\$;?')
      .firstMatch(sql);
  if (m == null) return null;
  if (m.namedGroup('tag') != m.namedGroup('tag2')) return null;
  return m.namedGroup('body')!.trimRight();
}

/// 提取 MySQL / SQL Server 的 BEGIN ... END 函数体(取第一个 BEGIN 到最后一个 END)
String? _extractBeginEnd(String sql) {
  final beginIdx = RegExp(r'\bBEGIN\b', caseSensitive: false)
      .allMatches(sql)
      .map((m) => m.start)
      .firstOrNull;
  if (beginIdx == null) return null;
  final endIdx = RegExp(r'\bEND\b', caseSensitive: false)
      .allMatches(sql)
      .map((m) => m.start)
      .lastOrNull;
  if (endIdx == null) return null;
  final body = sql.substring(beginIdx + 'BEGIN'.length, endIdx).trim();
  return body;
}
