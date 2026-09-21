import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/main.dart';
import 'package:daro/widgets/connection_password_dialog.dart';
import 'package:daro/widgets/database_tree.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// 「打开连接前需要补录密码,用户却关掉了弹窗」的回归:
// 整次打开作废——连接节点不展开、不标记已打开、不记日志,转圈指示器撤下。
// 曾经的实现是「先展开节点再弹密码窗」,弹窗一取消节点就停在展开态,
// 而库列表状态仍是 idle,树上于是永远挂着加载中的样子。
//
// 注意「打开中」的起止:从触发打开动作那一刻就开始转(等密码弹窗的时间
// 也算打开过程),用户取消才撤下——所以弹窗还开着时指示器是亮着的。

ConnectionInfo _conn(String name) => ConnectionInfo(
      name: name,
      typeId: 'mysql',
      host: '10.0.0.1',
      port: '3306',
      username: 'root',
      isLive: true,
    );

void main() {
  late Directory dir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // AppState 每次改动都会 _persist → path_provider,没有该通道会抛
    dir = await Directory.systemTemp.createTemp('daro_pwd_cancel_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (c) async => dir.path);
  });

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

  /// 树内行首的转圈指示器(「打开中」的唯一外在标志)
  Finder treeSpinner() => find.descendant(
      of: find.byType(DatabaseTree), matching: find.byType(Spinner));

  /// 推进若干帧,让弹窗动画与异步加载的后续步骤落地。
  /// 刻意不用 pumpAndSettle:节点一旦误入打开中状态,转圈动画永不静止,
  /// pumpAndSettle 只会一路等到超时,反而掩盖真正的原因。
  Future<void> pumpFrames(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// 双击连接行展开(树内的双击判定窗口是 500ms,两次点击需落在同窗口内)
  Future<void> doubleTapRow(WidgetTester tester, String name) async {
    await tester.tap(treeText(name));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(treeText(name));
    await pumpFrames(tester);
  }

  testWidgets('触发打开后第一帧就转起圈来(不等密码弹窗)', (tester) async {
    await pumpApp(tester)..addConnection(_conn('乙'));
    await tester.pump();

    await tester.tap(treeText('乙'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(treeText('乙'));

    // 只推一帧就必须已经在转:补录窗口(桌面端是独立系统窗口)的创建很重,
    // 指示器得先上屏,否则用户看到的就是「双击之后过一会才开始转」。
    await tester.pump();
    expect(treeSpinner(), findsOneWidget, reason: '双击后第一帧就该转起来');

    await pumpFrames(tester);
    expect(find.text('连接密码 - 乙'), findsOneWidget, reason: '随后弹窗正常出现');
  });

  testWidgets('密码弹窗被取消:连接节点不展开,打开中指示器撤下', (tester) async {
    final app = await pumpApp(tester)..addConnection(_conn('甲'));
    await tester.pump();

    await doubleTapRow(tester, '甲');
    // 密码未保存 → 先补录。打开动作已触发,等弹窗的这段时间同样算打开中,
    // 连接行行首应当已经在转圈(否则点了会像没反应)
    expect(find.text('连接密码 - 甲'), findsOneWidget);
    expect(treeSpinner(), findsOneWidget, reason: '触发打开后指示器立即开始转');
    // 节点仍是收起态:整次展开要等密码确认
    expect(app.connectionManager.isConnected('甲'), isFalse);

    await tester.tap(find.descendant(
      of: find.byType(ConnectionPasswordDialog),
      matching: find.text('取消'),
    ));
    await pumpFrames(tester);
    // 指示器有最小可见时长,推过它再断言已撤下
    await tester.pump(const Duration(milliseconds: 400));
    await pumpFrames(tester);

    expect(treeSpinner(), findsNothing, reason: '取消后连接行不该停在转圈打开中状态');
    expect(treeText('甲'), findsOneWidget);
    // 连接未建立,节点保持未打开(灰色、无展开箭头)
    expect(app.connectionManager.isConnected('甲'), isFalse);
  });
}
