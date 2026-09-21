import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daro/theme/app_theme.dart';

/// `AppPalette.desktopTokensFor` 的守护测试。
///
/// 参照的 Navicat 是原生窗口,边框恒为 1 **物理**像素:200% 缩放下等于 0.5
/// 逻辑像素。令牌默认的 1.0 会画成 2 物理像素,看起来粗一倍。因此凡是渲染
/// base-ui 组件时传 `tokens:` 的地方,都必须走 [AppPalette.desktopTokensFor]
/// —— 少一处就会同屏出现两种粗细的边框,比统一变细更难看。
void main() {
  group('边框收成 1 设备像素', () {
    testWidgets('按当前显示缩放推导 borderWidth', (tester) async {
      addTearDown(tester.view.reset);
      late DesktopTokens at100;
      late DesktopTokens at200;

      Future<DesktopTokens> resolve(double dpr) async {
        tester.view.devicePixelRatio = dpr;
        late DesktopTokens out;
        await tester.pumpWidget(Builder(builder: (context) {
          out = AppTheme.light.desktopTokensFor(context);
          return const SizedBox();
        }));
        return out;
      }

      at100 = await resolve(1.0);
      at200 = await resolve(2.0);

      expect(at100.borderWidth, 1.0, reason: '100% 屏上原生边框本来就是 1 逻辑像素');
      expect(at200.borderWidth, 0.5, reason: '200% 屏上要收半个逻辑像素才等于 1 物理像素');
      expect(at200.backgroundColor, at100.backgroundColor, reason: '颜色映射不受影响');
    });

    test('lib 下只允许 app_theme.dart 直接调 toDesktopTokens()', () {
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll(r'\', '/');
        if (path == 'lib/theme/app_theme.dart') continue;
        if (entity.readAsStringSync().contains('toDesktopTokens()')) {
          offenders.add(path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '这些文件绕过了 desktopTokensFor(),边框在 200% 屏上会粗一倍:'
            '${offenders.join(', ')}',
      );
    });
  });
}
