// 开发期自查工具：把 assets/icons/ui/*.svg 离屏光栅化成一张对照表，
// 用于核对图标的视觉大小是否统一、明暗底是否都可读。
// 运行：flutter test test/icon_sheet_test.dart  →  build/icon_sheet_{light,dark}.png
import 'dart:io';
import 'dart:ui' as ui;

import 'package:daro/data/db_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:daro/l10n/locale_config.dart';

const _names = [
  'table', 'view', 'materialized_view', 'function', 'procedure',
  'user', 'query', 'connection', 'database', 'database_closed',
  'schema', 'schema_closed',
];

/// 光学框参考线：flutter test --dart-define=GUIDE=true
const _guide = bool.fromEnvironment('GUIDE');

/// 渲染单个图标；_guide 为真时叠一个 21/24 的红框，用来核对各图标是否填满同一光学框。
Widget _cell(double s, String asset, bool guide) => SizedBox(
      width: s,
      height: s,
      child: Stack(
        fit: StackFit.expand,
        children: [
          SvgPicture.asset(asset, width: s, height: s),
          if (guide)
            Center(
              child: SizedBox(
                width: s * 21 / 24,
                height: s * 21 / 24,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                      border: Border.all(color: const Color(0x99ff2d55), width: .6)),
                ),
              ),
            ),
        ],
      ),
    );

void main() {
  testWidgets('图标对照表渲染', (tester) async {
    await tester.binding.setSurfaceSize(const Size(700, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Widget tile(String n) => Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _cell(16, 'assets/icons/ui/$n.svg', false),
              const SizedBox(width: 14),
              _cell(64, 'assets/icons/ui/$n.svg', _guide),
            ],
          ),
        );

    Widget block(Color bg) => Container(
          color: bg,
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int r = 0; r < _names.length; r += 3)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    for (int c = r; c < r + 3; c++) tile(_names[c]),
                  ],
                ),
            ],
          ),
        );

    final lightKey = GlobalKey();
    final darkKey = GlobalKey();
    // SVG 资源经事件循环异步解码，必须放在 runAsync 里，否则整列画不出来
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: kAppLocalizationsDelegates,
        supportedLocales: kSupportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              RepaintBoundary(
                  key: lightKey, child: block(const Color(0xfffbfcfd))),
              RepaintBoundary(
                  key: darkKey, child: block(const Color(0xff24272e))),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    });

    Future<void> shoot(GlobalKey key, String path) async {
      final boundary = key.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 2)))!;
      final data = (await tester
          .runAsync(() => image.toByteData(format: ui.ImageByteFormat.png)))!;
      File(path)
        ..createSync(recursive: true)
        ..writeAsBytesSync(data.buffer.asUint8List());
      debugPrint('已写出 $path');
    }

    await shoot(lightKey, 'build/icon_sheet_light.png');
    await shoot(darkKey, 'build/icon_sheet_dark.png');
  });

  testWidgets('引擎图标(官方 logo 瓦片 + 状态角标)对照', (tester) async {
    await tester.binding.setSurfaceSize(const Size(520, 1160));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Widget row(DbType t) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DbTypeIcon(type: t, size: 20, connected: true),
              const SizedBox(width: 10),
              DbTypeIcon(type: t, size: 20, connected: false),
              const SizedBox(width: 10),
              DbTypeIcon(type: t, size: 46, connected: true),
              const SizedBox(width: 10),
              DbTypeIcon(type: t, size: 96, connected: true),
            ],
          ),
        );

    // 每块套一层同亮度 Theme:让在线/离线两态在深浅底上都真正渲染一遍
    Widget themed({required Brightness brightness, required Color bg}) =>
        Theme(
          data: ThemeData(brightness: brightness, scaffoldBackgroundColor: bg),
          child: Container(
            color: bg,
            padding: const EdgeInsets.all(10),
            child: Column(children: [for (final t in kAllDbTypes) row(t)]),
          ),
        );

    final lightKey = GlobalKey();
    final darkKey = GlobalKey();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: kAppLocalizationsDelegates,
        supportedLocales: kSupportedLocales,
        home: Scaffold(
          body: Row(
            children: [
              RepaintBoundary(
                  key: lightKey,
                  child: themed(
                      brightness: Brightness.light, bg: const Color(0xfffbfcfd))),
              RepaintBoundary(
                  key: darkKey,
                  child: themed(
                      brightness: Brightness.dark, bg: const Color(0xff24272e))),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    });

    Future<void> shoot(GlobalKey key, String path) async {
      final boundary = key.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image =
          (await tester.runAsync(() => boundary.toImage(pixelRatio: 2)))!;
      final data = (await tester
          .runAsync(() => image.toByteData(format: ui.ImageByteFormat.png)))!;
      File(path)
        ..createSync(recursive: true)
        ..writeAsBytesSync(data.buffer.asUint8List());
      debugPrint('已写出 $path');
    }

    await shoot(lightKey, 'build/db_icon_sheet_light.png');
    await shoot(darkKey, 'build/db_icon_sheet_dark.png');
  });
}
