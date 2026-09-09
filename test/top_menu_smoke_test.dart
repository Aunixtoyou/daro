import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:daro/app/app_state.dart';
import 'package:daro/widgets/top_menu.dart';

void main() {
  testWidgets('TopMenu lays out without throwing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: ChangeNotifierProvider(
          create: (_) => AppState(),
          child: const TopMenu(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TopMenu), findsOneWidget);
  });
}
