// 内存复现测试:打开表 → 设置分页大小 → 翻页 → 重开标签 → 查询页运行。
// 用 SQLite 走与真实库完全相同的 UI / 分页路径,各阶段打印进程 RSS。
// 运行:flutter drive --profile -d windows --driver=test_driver/integration_test.dart --target=integration_test/mem_repro_test.dart
import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/main.dart';
import 'package:daro/widgets/table_data_page.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:sqlite3/sqlite3.dart';

int _rss() => ProcessInfo.currentRss ~/ (1024 * 1024);

void _log(String label) => debugPrint('[MEM] $label | RSS=${_rss()} MB');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('memory repro', (tester) async {
    // ── 造 SQLite 测试库:5000 行 × 20 列 ──
    final dir = Directory.systemTemp.createTempSync('daro_mem');
    final dbPath = '${dir.path}${Platform.pathSeparator}memtest.db';
    {
      final db = sqlite3.open(dbPath);
      db.execute(
          'CREATE TABLE t1 (${[for (var i = 0; i < 20; i++) 'c$i TEXT'].join(', ')})');
      db.execute('BEGIN');
      final ins = db.prepare(
          'INSERT INTO t1 VALUES (${List.filled(20, '?').join(',')})');
      for (var r = 0; r < 5000; r++) {
        ins.execute([for (var c = 0; c < 20; c++) 'row${r}_col${c}_value']);
      }
      db.execute('COMMIT');
      ins.dispose();
      db.dispose();
    }

    final app = AppState();
    addTearDown(() async {
      try {
        await app.removeConnection(
            const ConnectionInfo(name: 'memtest', typeId: 'sqlite', host: '', port: '', username: ''));
      } catch (_) {}
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(value: app, child: const DbApp()),
    );
    await tester.pump(const Duration(seconds: 3));
    _log('A startup');

    final conn = ConnectionInfo(
        name: 'memtest', typeId: 'sqlite', host: dbPath, port: '', username: '', isLive: true);
    app.addConnection(conn);
    await tester.pump(const Duration(milliseconds: 300));
    await app.connectionManager.expandConnection(conn);
    await tester.pump(const Duration(milliseconds: 300));
    _log('B connection expanded');

    app.openTable('t1', connection: 'memtest', database: 'memtest.db');
    await tester.pump(const Duration(seconds: 2));
    _log('C table opened (default 100/page)');

    // ── 设置分页大小 100 → 500(用户反馈的暴涨触发点)──
    try {
      debugPrint('[MEM] TableDataPage=${find.byType(TableDataPage).evaluate().length}');
      debugPrint('[MEM] loading=${find.textContaining('正在加载').evaluate().length}');
      debugPrint('[MEM] error=${find.textContaining('加载失败').evaluate().length}');
      final gear = find.byIcon(Icons.settings);
      debugPrint('[MEM] gear found=${gear.evaluate().length}');
      await tester.tap(gear.first);
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      final item = find.text('500 条/页');
      debugPrint('[MEM] 500 entry found=${item.evaluate().length}');
      await tester.tap(item.first);
      await tester.pump(const Duration(seconds: 2));
      _log('D page size -> 500');
    } catch (e, st) {
      debugPrint('[MEM] page-size step FAILED: $e\n$st');
      rethrow;
    }

    // ── 来回翻页(命中/未命中页缓存)──
    for (var i = 1; i <= 8; i++) {
      final next = find.byWidgetPredicate(
          (w) => w is Surface && w.semanticLabel == 'Next page');
      await tester.tap(next);
      await tester.pump(const Duration(milliseconds: 500));
      if (i == 4) _log('E paged to 5');
    }
    _log('F paged to 9');
    for (var i = 1; i <= 5; i++) {
      final prev = find.byWidgetPredicate(
          (w) => w is Surface && w.semanticLabel == 'Previous page');
      await tester.tap(prev);
      await tester.pump(const Duration(milliseconds: 400));
    }
    _log('G paged back to 4');

    // ── 反复关闭/重开表标签 ──
    for (var i = 0; i < 5; i++) {
      app.closeAllTabs();
      await tester.pump(const Duration(milliseconds: 500));
      app.openTable('t1', connection: 'memtest', database: 'memtest.db');
      await tester.pump(const Duration(milliseconds: 1200));
    }
    _log('H after 5 close/reopen cycles');

    // ── 查询页:连续运行 5 次 SELECT ──
    app.objectConnection = 'memtest';
    app.objectDatabase = 'memtest.db';
    final qTab = OpenTab(
        TabType.query, '无标题-查询 1', null, 'memtest', 'memtest.db', null);
    app.updateQueryText(qTab.key, 'SELECT * FROM t1 LIMIT 1000');
    app.newQuery();
    await tester.pump(const Duration(seconds: 1));
    _log('I query tab opened');
    for (var i = 1; i <= 5; i++) {
      final run = find.byWidgetPredicate(
          (w) => w is ToolbarButton && w.text == '运行');
      expect(run, findsOneWidget, reason: '找不到运行按钮');
      await tester.tap(run);
      await tester.pump(const Duration(seconds: 1));
      _log('J query run #$i');
    }

    await tester.pump(const Duration(seconds: 2));
    _log('K final idle');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
