import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/app/mcp_service.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/theme/app_theme.dart';
import 'package:daro/widgets/mcp_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// MCP 设置弹窗「连接与模式」页的切换行为。
//
// 背景:本机连接数实测 384 条,该页原来在「点标签」那一帧把全部行连同下拉框
// 一起 mount 出来 —— 用户看到的是点下去先卡一拍、然后内容整块冒出来。现在拆成
// 「标签条与骨架屏同帧上屏 + 正文随后再建」,且行列表懒建。这里守两件事:
//   1. 切页那一帧必然只画骨架屏,不画正文;
//   2. 几百条连接只建视口内的行(不是全部)。

/// 连接名固定前缀,便于断言「哪些行被建出来了」。
const String _kNamePrefix = 'conn_';

ConnectionInfo _conn(int i) => ConnectionInfo(
      name: '$_kNamePrefix${i.toString().padLeft(2, '0')}',
      typeId: 'mysql',
      host: '10.255.255.1',
      port: '3306',
      username: 'u',
    );

Widget _harness(AppState app, McpService mcp) {
  final palette = AppTheme.light;
  return ChangeNotifierProvider<AppState>.value(
    value: app,
    child: ChangeNotifierProvider<McpService>.value(
      value: mcp,
      child: Provider<AppPalette>.value(
        value: palette,
        child: TokenScope(
          tokens: palette.toDesktopTokens(),
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light, palette),
            home: const Center(child: McpSettingsDialog()),
          ),
        ),
      ),
    ),
  );
}

void main() {
  /// 连接条数:取一个明显超出视口容量、又不让用例变慢的数。
  const int total = 40;

  late Directory supportDir;
  late AppState app;
  late McpService mcp;

  setUp(() async {
    // 指向一个**不删**的临时目录:AppState 的落盘是异步的,addConnections 触发的
    // 那次写盘可能在用例结束后才落地 —— 删掉目录的话它会带着 PathNotFoundException
    // 记成「failed after it had already completed」,看着像断言失败,其实是清理太早。
    supportDir = Directory(
            '${Directory.systemTemp.path}${Platform.pathSeparator}daro_mcp_conn_tab_test')
      ..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => supportDir.path,
    );
    app = AppState();
    app.addConnections([for (var i = 0; i < total; i++) _conn(i)]);
    mcp = McpService(loadConnections: () async => app.connections);
    addTearDown(mcp.dispose);
  });

  /// 切到「连接与模式」:弹窗本体尺寸 780×520,测试窗口给足空间。
  Future<void> openDialog(WidgetTester tester) async {
    tester.view.physicalSize = const Size(2400, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_harness(app, mcp));
    await tester.pump();
  }

  testWidgets('切到「连接与模式」:骨架屏同帧上屏,正文随后才建', (tester) async {
    await openDialog(tester);
    expect(find.byType(Skeleton), findsNothing, reason: '首屏是「服务」页,不该有骨架');

    await tester.tap(find.text('连接与模式'));
    await tester.pump();

    // 切换那一帧:标签条已切过去、骨架屏已上屏,正文一个都没建。
    expect(find.byType(Skeleton), findsWidgets);
    expect(find.text('默认执行模式'), findsNothing);

    // 骨架屏停留结束后换正文。
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(Skeleton), findsNothing);
    expect(find.text('默认执行模式'), findsOneWidget);
  });

  testWidgets('连接列表懒建:只造视口内的行', (tester) async {
    await openDialog(tester);
    await tester.tap(find.text('连接与模式'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('${_kNamePrefix}00'), findsOneWidget, reason: '首行可见');
    expect(find.text('${_kNamePrefix}39'), findsNothing,
        reason: '$total 条连接只该建可见的十来行;末行被建出来说明退回了整表 mount');
    final built = find.textContaining(_kNamePrefix).evaluate().length;
    expect(built, lessThan(total));
    expect(built, greaterThan(0));
  });

  testWidgets('切走再切回:第二次直接上正文,不再闪骨架', (tester) async {
    await openDialog(tester);
    await tester.tap(find.text('连接与模式'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('默认执行模式'), findsOneWidget);

    await tester.tap(find.text('服务'));
    await tester.pump();
    expect(find.text('默认执行模式'), findsNothing);

    await tester.tap(find.text('连接与模式'));
    await tester.pump();
    expect(find.byType(Skeleton), findsNothing);
    expect(find.text('默认执行模式'), findsOneWidget);
  });
}
