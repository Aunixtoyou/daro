import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('DataGridView 外层纵向 ScrollBar 应渲染滑块', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final v = ScrollController();
    final h = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 600,
            height: 300,
            child: Builder(
              builder: (context) => ScrollConfiguration(
                behavior:
                    ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: ScrollBar(
                controller: v,
                thumbVisibility: true,
                child: ScrollBar(
                  controller: h,
                  orientation: ScrollBarOrientation.horizontal,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: h,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: 1200,
                      child: DataGridView(
                        columns: const [
                          DataGridViewColumn(title: 'a', width: 600),
                          DataGridViewColumn(title: 'b', width: 600),
                        ],
                        rowCount: 100,
                        rowHeight: 24,
                        verticalScrollController: v,
                        cellBuilder: (r, c) => Text('$r-$c'),
                      ),
                    ),
                  ),
                ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(v.hasClients, isTrue);
    debugPrint('vController maxScrollExtent=${v.position.maxScrollExtent} '
        'viewport=${v.position.viewportDimension}');

    final bars = find.bySubtype<RawScrollbar>();
    debugPrint('RawScrollbar count=${bars.evaluate().length}');
    for (final bar in tester.widgetList<RawScrollbar>(find.bySubtype<RawScrollbar>())) {
      debugPrint('RawScrollbar thumbVisibility=${bar.thumbVisibility} '
          'thumbVisibility=${bar.thumbVisibility} '
          'thickness=${bar.thickness} controllerAttached=${bar.controller?.hasClients}');
    }
    expect(v.position.maxScrollExtent, greaterThan(0));
    debugDefaultTargetPlatformOverride = null;
    v.dispose();
    h.dispose();
  });
}
