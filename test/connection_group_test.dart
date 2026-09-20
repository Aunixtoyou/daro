import 'dart:convert';
import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/main.dart';
import 'package:daro/widgets/database_tree.dart';
import 'package:daro/widgets/navicat_import_dialog.dart';
import 'package:daro/widgets/object_category_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// 连接分组(单层)的行为测试:模型/状态层的建、改、删、移动,落盘与老配置兼容,
// 以及「从 Navicat 导入连接」时按文件里的 Group 重建分组。
// .ncx 里 Group 属性的写法与导出侧的约定由 test/navicat_export_test.dart 钉住。

ConnectionInfo _conn(String name, {String group = '', String typeId = 'mysql'}) =>
    ConnectionInfo(
      name: name,
      typeId: typeId,
      host: '10.0.0.1',
      port: '3306',
      username: 'root',
      group: group,
      isLive: true,
    );

/// 带 daro 私有 Group 属性的导出文件:一条落在已有分组、一条落在本地没有的分组、
/// 一条不带 Group(Navicat 自己导出的文件就是这种形态)
const _ncxWithGroups = '''
<?xml version="1.0" encoding="UTF-8"?>
<Connections Ver="1.5">
	<Connection ConnectionName="生产主库" ConnType="MYSQL" Host="10.0.0.11" Port="3306" UserName="root" Password="" SavePassword="false" Group="生产"/>
	<Connection ConnectionName="客户现场A" ConnType="MYSQL" Host="192.168.1.7" Port="3306" UserName="root" Password="" SavePassword="false" Group="客户现场"/>
	<Connection ConnectionName="随手加的" ConnType="SQLITE" DatabaseFileName="C:\\data\\x.db" Password="" SavePassword="false"/>
</Connections>
''';

void main() {
  // AppState 的每次改动都会走 _persist → path_provider;没有这个通道时
  // save() 会抛 MissingPluginException(异步、无人接管),所以整份测试统一 mock。
  late Directory dir;
  late File store;
  late File ncxFile;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    dir = await Directory.systemTemp.createTemp('daro_group_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (c) async => dir.path);
    store = File('${dir.path}${Platform.pathSeparator}connections.json');
    ncxFile = File('${dir.path}${Platform.pathSeparator}connections.ncx')
      ..writeAsStringSync(_ncxWithGroups, flush: true);
  });

  group('AppState 分组状态', () {
    test('新建连接指向未知分组时顺手登记,重复登记不产生第二条', () {
      final app = AppState()..addConnection(_conn('a', group: '生产'));
      expect(app.groupNames, ['生产']);
      app.addConnection(_conn('b', group: '生产'));
      expect(app.groupNames, ['生产']);
      expect(app.connections.map((c) => c.group), ['生产', '生产']);
    });

    test('空分组可以独立存在(否则“新建分组”看着像没生效)', () {
      final app = AppState();
      expect(app.addGroup('测试'), '测试');
      expect(app.groupNames, ['测试']);
      expect(app.connections, isEmpty);
      // 重名(不区分大小写)不新增
      expect(app.addGroup('测试'), '测试');
      expect(app.groupNames, ['测试']);
    });

    test('移动到分组:空串 = 移出,未知目标名自动建组', () {
      final app = AppState()..addConnection(_conn('a'));
      expect(app.connections.single.group, '');
      app.moveConnectionToGroup(app.connections.single, '归档');
      expect(app.connections.single.group, '归档');
      expect(app.groupNames, ['归档']);
      app.moveConnectionToGroup(app.connections.single, '');
      expect(app.connections.single.group, '');
      // 移出后分组仍在:允许空分组
      expect(app.groupNames, ['归档']);
    });

    test('重命名分组同步改写组内连接,连接名不受影响', () {
      final app = AppState()
        ..addConnection(_conn('a', group: '生产'))
        ..addConnection(_conn('b', group: '生产'))
        ..addConnection(_conn('c', group: '测试'));
      expect(app.renameGroup('生产', '生产-主'), isTrue);
      expect(app.groupNames, ['生产-主', '测试']);
      expect(
        app.connections.map((c) => '${c.name}:${c.group}'),
        ['a:生产-主', 'b:生产-主', 'c:测试'],
      );
    });

    test('重命名撞到已有分组名时拒绝,不留下半成品', () {
      final app = AppState()
        ..addConnection(_conn('a', group: '生产'))
        ..addConnection(_conn('b', group: '测试'));
      expect(app.renameGroup('生产', '测试'), isFalse);
      expect(app.renameGroup('生产', '  '), isFalse);
      expect(app.groupNames, ['生产', '测试']);
      expect(app.connections.first.group, '生产');
    });

    test('删除分组只删条目,组内连接回落到未分组', () {
      final app = AppState()
        ..addConnection(_conn('a', group: '生产'))
        ..addConnection(_conn('b'));
      app.deleteGroup('生产');
      expect(app.groupNames, isEmpty);
      expect(
        app.connections.map((c) => '${c.name}:${c.group}'),
        ['a:', 'b:'],
      );
    });

    test('ensureGroups 幂等:同一批名字重复调用只新增一次', () {
      final app = AppState();
      expect(app.ensureGroups(['生产', '测试', '生产', '  ']), 2);
      expect(app.ensureGroups(['生产', '测试']), 0);
      expect(app.groupNames, ['生产', '测试']);
    });
  });

  group('持久化与老配置兼容', () {
    test('分组与连接上的 group 一起落盘,重启后读回', () async {
      final app = AppState()
        ..addConnection(_conn('a', group: '生产'))
        ..addGroup('空分组');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(app.groupNames, ['生产', '空分组']);

      final saved = jsonDecode(store.readAsStringSync()) as Map<String, dynamic>;
      expect((saved['groups'] as List).cast<Map<String, dynamic>>().map((g) => g['name']),
          ['生产', '空分组']);
      expect(
        (saved['connections'] as List)
            .cast<Map<String, dynamic>>()
            .single['group'],
        '生产',
      );

      final reloaded = AppState();
      await reloaded.reloadConnections();
      expect(reloaded.groupNames, ['生产', '空分组']);
      expect(reloaded.connections.single.group, '生产');
    });

    test('老 connections.json 没有 groups 键时按连接上的 group 补齐', () async {
      store.writeAsStringSync(
        jsonEncode({
          'connections': [
            const ConnectionInfo(
                    name: '旧连接',
                    typeId: 'mysql',
                    host: 'h',
                    port: '3306',
                    username: 'u',
                    group: '遗留分组')
                .toJson(),
          ]
        }),
        flush: true,
      );
      final app = AppState();
      await app.reloadConnections();
      expect(app.connections.single.group, '遗留分组');
      // 分组条目被现场补齐,右键菜单与「移动到分组」才有候选
      expect(app.groupNames, ['遗留分组']);
    });
  });

  group('从 Navicat 导入时重建分组', () {
    Future<void> openAndImport(WidgetTester tester, AppState app) async {
      await tester.pumpWidget(_harness(app, _entryPage(app)));
      await tester.tap(find.text('打开导入向导'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Input));
      await tester.enterText(find.byType(Input), ncxFile.path);
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入选中'));
      await tester.pumpAndSettle();
    }

    testWidgets('文件里的分组本地不存在则新建,连接挂进去', (tester) async {
      final app = AppState()..addGroup('生产');
      await openAndImport(tester, app);

      // 「生产」已存在 → 只补建「客户现场」;不带 Group 的那条仍是未分组
      expect(app.groupNames, ['生产', '客户现场']);
      expect(
        app.connections.map((c) => '${c.name}:${c.group}'),
        ['生产主库:生产', '客户现场A:客户现场', '随手加的:'],
      );
      // 重建是幂等的:同一份文件再解析一次,不会多出第二个「客户现场」
      expect(app.ensureGroups(['生产', '客户现场']), 0);
      expect(app.groupNames, ['生产', '客户现场']);
    });

    testWidgets('分组列标出「新建」,汇总行给分组数', (tester) async {
      final app = AppState()..addGroup('生产');
      await tester.pumpWidget(_harness(app, _entryPage(app)));
      await tester.tap(find.text('打开导入向导'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Input));
      await tester.enterText(find.byType(Input), ncxFile.path);
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      // 本地已有的分组只显示名字,没有的标「·新建」
      expect(find.text('生产'), findsWidgets);
      expect(find.text('客户现场 ·新建'), findsOneWidget);
      expect(find.textContaining('分组 2'), findsOneWidget);
    });
  });

  group('连接树的分组渲染', () {
    Future<AppState> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final app = AppState();
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const DbApp(),
      ));
      await tester.pump();
      return app;
    }

    Finder treeText(String text) => find.descendant(
        of: find.byType(DatabaseTree), matching: find.text(text));

    testWidgets('一条分组都没有时保持平铺,不凭空插入包装层', (tester) async {
      final app = await pumpApp(tester)
        ..addConnection(_conn('甲'))
        ..addConnection(_conn('乙'));
      await tester.pump();

      // 两条连接同层级(没有分组头、也没有多一级缩进)
      expect(tester.getTopLeft(treeText('甲')).dx,
          tester.getTopLeft(treeText('乙')).dx);
      expect(app.connections.length, 2);
    });

    testWidgets('有分组后:分组头在上,组内连接比未分组连接多缩进一级', (tester) async {
      final app = await pumpApp(tester)
        ..addConnection(_conn('甲', group: '生产'))
        ..addConnection(_conn('乙'));
      await tester.pump();

      expect(treeText('生产'), findsOneWidget);
      final groupX = tester.getTopLeft(treeText('生产')).dx;
      final inGroupX = tester.getTopLeft(treeText('甲')).dx;
      final looseX = tester.getTopLeft(treeText('乙')).dx;
      // 分组头与未分组连接同在顶层,组内连接多一级缩进
      expect(groupX, looseX);
      expect(inGroupX, greaterThan(groupX));
      expect(app.groupNames, ['生产']);
      // 分组头用的是自绘文件夹 SVG(与库 / 模式节点同一套 UiIcon 通道),
      // 未展开任何连接时,树里出现的 UiIcon 数量 = 分组数量
      expect(
        find.descendant(
            of: find.byType(DatabaseTree), matching: find.byType(UiIcon)),
        findsNWidgets(app.groups.length),
      );
    });

    testWidgets('搜索只剩一个分组时,空分组头不再占位', (tester) async {
      final app = await pumpApp(tester)
        ..addConnection(_conn('甲', group: '生产'))
        ..addConnection(_conn('乙', group: '测试'))
        ..setTreeSearchText('甲');
      await tester.pump();

      expect(treeText('甲'), findsOneWidget);
      expect(treeText('生产'), findsOneWidget);
      expect(treeText('测试'), findsNothing);
      // 命中口径仍是连接名:「测试」分组因无可见子项而隐藏
      expect(app.filteredConnections.map((c) => c.name), ['甲']);
    });

    testWidgets('按住连接拖到分组头:移入该分组', (tester) async {
      final app = await pumpApp(tester)
        ..addConnection(_conn('甲', group: '生产'))
        ..addConnection(_conn('乙'));
      await tester.pump();

      final from = tester.getCenter(treeText('乙'));
      final to = tester.getCenter(treeText('生产'));
      await tester.drag(treeText('乙'), to - from);
      await tester.pump();

      expect(
        app.connections.map((c) => '${c.name}:${c.group}'),
        ['甲:生产', '乙:生产'],
      );
    });

    testWidgets('拖到组内兄弟连接上:等同拖到分组头', (tester) async {
      final app = await pumpApp(tester)
        ..addConnection(_conn('甲', group: '生产'))
        ..addConnection(_conn('乙'));
      await tester.pump();

      final from = tester.getCenter(treeText('乙'));
      final to = tester.getCenter(treeText('甲'));
      await tester.drag(treeText('乙'), to - from);
      await tester.pump();

      expect(
        app.connections.map((c) => '${c.name}:${c.group}'),
        ['甲:生产', '乙:生产'],
      );
    });

    testWidgets('拖到未分组兄弟连接上:移出分组', (tester) async {
      final app = await pumpApp(tester)
        ..addConnection(_conn('甲', group: '生产'))
        ..addConnection(_conn('乙'));
      await tester.pump();

      final from = tester.getCenter(treeText('甲'));
      final to = tester.getCenter(treeText('乙'));
      await tester.drag(treeText('甲'), to - from);
      await tester.pump();

      expect(
        app.connections.map((c) => '${c.name}:${c.group}'),
        ['甲:', '乙:'],
      );
      // 分组条目保留(允许空分组)
      expect(app.groupNames, ['生产']);
    });

    testWidgets('拖动分组内连接时底部出现「未分组」放置条,释放即移出', (tester) async {
      final app = await pumpApp(tester)
        ..addConnection(_conn('甲', group: '生产'));
      await tester.pump();

      // 未拖动时放置条不存在
      expect(find.textContaining('释放以移到'), findsNothing);

      final gesture = await tester.startGesture(tester.getCenter(treeText('甲')));
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump(); // 拖动开始 → 放置条出现
      final strip = find.textContaining('释放以移到');
      expect(strip, findsOneWidget);

      await gesture.moveTo(tester.getCenter(strip));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(app.connections.single.group, '');
      // 拖动结束后放置条消失
      expect(strip, findsNothing);
    });

    testWidgets('拖动未分组连接时不出现「未分组」放置条', (tester) async {
      await pumpApp(tester)..addConnection(_conn('乙'));
      await tester.pump();

      final gesture = await tester.startGesture(tester.getCenter(treeText('乙')));
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      expect(find.textContaining('释放以移到'), findsNothing);
      await gesture.up();
      await tester.pump();
    });
  });
}

Widget _harness(AppState app, Widget home) =>
    ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: home,
      ),
    );

Widget _entryPage(AppState app) => Builder(
      builder: (context) => Material(
        child: Button(
          text: '打开导入向导',
          onPressed: () => showNavicatImportDialog(context, app: app),
        ),
      ),
    );
