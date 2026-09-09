import 'package:daro/app/connection_manager.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/data/drivers/db_driver.dart';
import 'package:daro/data/sql_completions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

/// 构造已加载 schema 的 ConnectionManager:
/// 表 [tables]、视图 [views](仅 sqlite 假连接,不发真实请求)
ConnectionManager _managerWithSchema({
  String database = 'db',
  List<String> tables = const [],
  List<String> views = const [],
}) {
  final manager = ConnectionManager();
  manager.tableStateOf('c', database)
    ..status = LoadStatus.loaded
    ..tables = tables
    ..views = views;
  return manager;
}

ConnectionInfo get _conn => ConnectionInfo(
      name: 'c',
      typeId: 'sqlite',
      host: '',
      port: '',
      username: '',
      isLive: true,
    );

/// 在单行 [text] 的 [offset] 处触发补全构建
CodeAutocompleteEditingValue? _buildAt(
  BuildContext context,
  SqlPromptsBuilder builder,
  String text,
  int offset,
) =>
    builder.build(
      context,
      CodeLine(text),
      CodeLineSelection.collapsed(index: 0, offset: offset),
    );

/// 提取提示词列表
List<String> _words(CodeAutocompleteEditingValue value) =>
    [for (final p in value.prompts) (p as SqlPrompt).word];

void main() {
  testWidgets('关键字前缀过滤 + 大小写不敏感', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      }),
    ));

    final builder = SqlPromptsBuilder();
    final value = _buildAt(ctx, builder, 'SELECT * FROM us', 16);
    expect(value, isNotNull);
    expect(value!.input, 'us');
    expect(_words(value), contains('USING'));

    final lower = _buildAt(ctx, builder, 'sele', 4);
    expect(lower, isNotNull);
    expect(_words(lower!), contains('SELECT'));
  });

  testWidgets('输入完整词时不再提示', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      }),
    ));

    final builder = SqlPromptsBuilder();
    // 'SELECT' 已是完整关键字,函数与关键字均不匹配
    expect(_buildAt(ctx, builder, 'SELECT', 6), isNull);
    // 行首(无输入且无「表名.」前缀)
    expect(_buildAt(ctx, builder, 'SELECT a', 0), isNull);
  });

  testWidgets('字符串字面量内不提示', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      }),
    ));

    final builder = SqlPromptsBuilder();
    expect(_buildAt(ctx, builder, "SELECT 'ab", 10), isNull);
    expect(_buildAt(ctx, builder, 'SELECT `ab', 10), isNull);
    // 引号闭合后恢复提示
    expect(_buildAt(ctx, builder, "SELECT 'a' us", 13), isNotNull);
  });

  testWidgets('schema 感知:表/视图补全', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      }),
    ));

    final manager = _managerWithSchema(
      tables: ['users', 'orders'],
      views: ['user_stats'],
    );
    final builder = SqlPromptsBuilder();
    builder.updateContext(manager, _conn, 'db');

    final value = _buildAt(ctx, builder, 'SELECT * FROM us', 16);
    expect(value, isNotNull);
    final words = _words(value!);
    expect(words, containsAll(['users', 'user_stats']));

    final kinds = [
      for (final p in value.prompts.whereType<SqlPrompt>())
        if (p.word == 'users') p.kind,
    ];
    expect(kinds, [SqlPromptKind.table]);
  });

  testWidgets('「表名.」列补全:懒加载后生效', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      }),
    ));

    final manager = _managerWithSchema(tables: ['users']);
    final builder = SqlPromptsBuilder(
      describeTableImpl: (manager, conn, db, table) async {
        expect(table, 'users');
        return [
          const ColumnDef(name: 'id', type: 'int'),
          const ColumnDef(name: 'user_name', type: 'varchar'),
        ];
      },
    );
    builder.updateContext(manager, _conn, 'db');

    // 首次触发:异步加载尚未完成,无提示
    expect(_buildAt(ctx, builder, 'SELECT users.i', 14), isNull);
    await tester.pump();

    // 加载完成后:按前缀过滤出列,并携带数据类型标注
    final value = _buildAt(ctx, builder, 'SELECT users.i', 14);
    expect(value, isNotNull);
    expect(value!.input, 'i');
    expect(_words(value), ['id']);
    final prompt = value.prompts.single as SqlPrompt;
    expect(prompt.kind, SqlPromptKind.column);
    expect(prompt.detail, 'int');

    // 表名大小写不敏感
    final upper = _buildAt(ctx, builder, 'SELECT USERS.', 13);
    expect(upper, isNotNull);
    expect(_words(upper!), containsAll(['id', 'user_name']));
  });

  testWidgets('未识别的「表名.」不提示', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      }),
    ));

    final manager = _managerWithSchema(tables: ['users']);
    final builder = SqlPromptsBuilder();
    builder.updateContext(manager, _conn, 'db');

    expect(_buildAt(ctx, builder, 'SELECT nobody.', 13), isNull);
  });

  testWidgets('运行上下文切换后列缓存清空', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      }),
    ));

    var calls = 0;
    final manager = _managerWithSchema(tables: ['users']);
    final builder = SqlPromptsBuilder(
      describeTableImpl: (manager, conn, db, table) async {
        calls++;
        return [const ColumnDef(name: 'id', type: 'int')];
      },
    );
    builder.updateContext(manager, _conn, 'db');

    expect(_buildAt(ctx, builder, 'SELECT users.', 13), isNull);
    await tester.pump();
    expect(_buildAt(ctx, builder, 'SELECT users.', 13), isNotNull);
    expect(calls, 1);

    // 切换库:缓存清空,重新加载
    final other = _managerWithSchema(database: 'other_db', tables: ['users']);
    builder.updateContext(other, _conn, 'other_db');
    expect(_buildAt(ctx, builder, 'SELECT users.', 13), isNull);
    await tester.pump();
    expect(_buildAt(ctx, builder, 'SELECT users.', 13), isNotNull);
    expect(calls, 2);
  });
}
