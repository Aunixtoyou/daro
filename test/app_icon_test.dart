// 开发期资源生成工具:把 assets/icons/app_logo.svg 按 Windows 应用图标所需的
// 各档尺寸原生光栅化成 build/ico/<size>.png,再由 tool/make_app_icon.py 打包成 .ico。
// 运行:flutter test test/app_icon_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

/// Windows 图标位图惯例档位(含 125% / 150% / 200% 缩放用到的非 2 次幂档)
const _icoSizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256];

void main() {
  testWidgets('生成 .ico 各档位图', (tester) async {
    final svg = File('assets/icons/app_logo.svg').readAsStringSync();

    for (final size in _icoSizes) {
      final key = GlobalKey();
      await tester.binding.setSurfaceSize(Size.square(size + 8));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: key,
              child: SvgPicture.string(
                svg,
                width: size.toDouble(),
                height: size.toDouble(),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image =
          (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
      final data = (await tester
          .runAsync(() => image.toByteData(format: ui.ImageByteFormat.png)))!;
      File('build/ico/$size.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(data.buffer.asUint8List());
      image.dispose();
      debugPrint('已写出 build/ico/$size.png');
    }
    addTearDown(() => tester.binding.setSurfaceSize(null));
  });
}
