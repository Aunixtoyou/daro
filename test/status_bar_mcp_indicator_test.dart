import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/app/mcp_service.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/data/mcp_policy_store.dart';
import 'package:daro/mcp/mcp_policy.dart';
import 'package:daro/theme/app_theme.dart';
import 'package:daro/widgets/status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:daro/l10n/locale_config.dart';

/// 状态栏 MCP 指示器的重建契约。
///
/// 回归点:指示器早先用 `context.read<AppState>().mcp` 取一次快照,而
/// `StatusBar` 外层的 `Selector` 只订阅 AppState 的展示字段 —— 于是「取消勾选
/// 启用 MCP 服务」这种**只由 McpService 通知**的变化传不到指示器,状态栏会一直
/// 停在「运行中」。本测试用假 McpService 直接驱动通知,断言指示器跟着变。
void main() {
  const disabledTip = 'MCP 服务已禁用(点击打开设置)';
  const runningTip = 'MCP 运行中(点击打开设置)';

  Future<_FakeMcpService> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = AppState();
    // 只覆写 UI 用到的只读状态:不起宿主、不落盘
    final mcp = _FakeMcpService();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: ChangeNotifierProvider<McpService>.value(
          value: mcp,
          child: TokenScope(
            tokens: AppTheme.dark.toDesktopTokens(),
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: kAppLocalizationsDelegates,
              supportedLocales: kSupportedLocales,
              home: Material(
                type: MaterialType.transparency,
                child: const StatusBar(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return mcp;
  }

  testWidgets('默认策略关闭:指示器显示「已禁用」', (tester) async {
    await pump(tester);
    expect(find.byTooltip(disabledTip), findsOneWidget);
  });

  testWidgets('宿主起停与活动调用数都随 McpService 通知重建', (tester) async {
    final mcp = await pump(tester);

    mcp.emit(enabled: true, running: true);
    await tester.pump();
    expect(find.byTooltip(runningTip), findsOneWidget);

    mcp.emit(enabled: true, running: true, calls: 3);
    await tester.pump();
    expect(find.byTooltip('MCP 运行中 (3 个调用)'), findsOneWidget);
  });

  testWidgets('取消勾选启用后,指示器立刻回到「已禁用」(回归)', (tester) async {
    final mcp = await pump(tester);

    mcp.emit(enabled: true, running: true);
    await tester.pump();
    expect(find.byTooltip(runningTip), findsOneWidget);

    // 只发 McpService 通知,不碰 AppState —— 正是设置页取消勾选时的实际路径
    mcp.emit(enabled: false);
    await tester.pump();
    expect(find.byTooltip(disabledTip), findsOneWidget,
        reason: '禁用后不该继续显示「运行中」');
    expect(find.byTooltip(runningTip), findsNothing);
  });
}

class _FakeMcpService extends McpService {
  _FakeMcpService() : super(loadConnections: () async => const <ConnectionInfo>[]);

  McpPolicy _policy = McpPolicy.defaults();
  bool _running = false;
  int _calls = 0;

  @override
  McpPolicy get policy => _policy;

  @override
  McpPolicyLoadStatus get policyStatus => McpPolicyLoadStatus.ok;

  @override
  bool get isRunning => _running;

  @override
  int get activeCalls => _calls;

  /// 模拟一次策略 / 运行态变化并通知 UI。
  void emit({required bool enabled, bool running = false, int calls = 0}) {
    _policy = McpPolicy.defaults().copyWith(enabled: enabled);
    _running = enabled && running;
    _calls = enabled ? calls : 0;
    notifyListeners();
  }
}
