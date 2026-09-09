import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:provider/provider.dart';

import 'package:daro/app/app_state.dart';
import 'package:daro/pages/connection_dialog_page.dart';
import 'package:daro/theme/app_theme.dart';

void main() {
  testWidgets('DialogBox shrink-wraps scrollable body', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var popped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: GestureDetector(
              onTap: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => DialogBox(
                    title: '新建连接',
                    width: 960,
                    onClose: () {
                      popped = true;
                      Navigator.of(context).pop();
                    },
                    footer: const SizedBox(height: 32),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('header'),
                          Expanded(
                            child: SingleChildScrollView(
                              child: Column(
                                children: List.generate(
                                  60,
                                  (i) => const SizedBox(height: 40, child: Text('row')),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // DialogBox's build root is a Center (always full-size, for centering);
    // the actual dialog shell is the inner IntrinsicWidth.
    final size =
        (tester.renderObject(find.descendant(
      of: find.byType(DialogBox),
      matching: find.byType(IntrinsicWidth),
    ).first) as RenderBox)
            .size;
    debugPrint('DialogBox outer size = $size (screen 1600x900)');
    // Expect the dialog NOT to fill the whole screen height.
    expect(size.height, lessThan(900), reason: '弹窗不应全屏高度');
    expect(size.width, lessThan(1600), reason: '弹窗不应全屏宽度');

    expect(popped, false);
  });

  testWidgets('ConnectionDialogPage is a centered dialog, not fullscreen',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: MaterialApp(
        theme: ThemeData(brightness: Brightness.light),
        home: TokenScope(
          tokens: AppTheme.light.toDesktopTokens(),
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: GestureDetector(
                  onTap: () {
                    showDialog<void>(
                      context: context,
                      builder: (_) => const ConnectionDialogPage(),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final size =
        (tester.renderObject(find.descendant(
      of: find.byType(DialogBox),
      matching: find.byType(IntrinsicWidth),
    ).first) as RenderBox)
            .size;
    debugPrint('ConnectionDialog size = $size (screen 1600x900)');
    expect(size.width, 960, reason: '弹窗宽度应为 960');
    expect(size.height, lessThan(900), reason: '弹窗不应全屏高度');
    expect(size.height, greaterThan(300), reason: '弹窗高度应能容纳内容');
  });
}
