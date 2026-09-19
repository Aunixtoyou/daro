import 'dart:convert';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:daro/app/sub_window.dart';
import 'package:daro/data/db_data.dart';
import 'package:daro/theme/app_theme.dart';
import 'package:daro/widgets/connection_password_dialog.dart';
import 'package:daro/widgets/connection_password_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 「连接密码」形态冒烟:标题带连接名、回显主机与用户名、空密码不可提交、
// 密码与「保存密码」勾选状态一起回传;并核对父子窗口的入口参数契约。
// 测试环境没有多窗口插件,showConnectionPasswordDialog 走应用内弹窗回落。

const _conn = ConnectionInfo(
    name: '明杰测试',
    typeId: 'mysql',
    host: '10.70.24.109',
    port: '3306',
    username: 'root');

void main() {
  Future<void> pumpAndOpen(
      WidgetTester tester, void Function(ConnectionPasswordResult?) done) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Material(
          child: Button(
            text: 'open',
            onPressed: () async => done(
                await showConnectionPasswordDialog(context, conn: _conn)),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('回显连接信息,空密码点「确定」不提交', (tester) async {
    var popped = false;
    await pumpAndOpen(tester, (_) => popped = true);
    expect(find.text('连接密码 - 明杰测试'), findsOneWidget);
    expect(find.text('输入连接 "明杰测试" 的密码。'), findsOneWidget);
    expect(find.text('10.70.24.109:3306'), findsOneWidget);
    expect(find.text('root'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(popped, isFalse);
    expect(find.text('密码:'), findsOneWidget);
  });

  testWidgets('密码与「保存密码」勾选状态一起回传', (tester) async {
    ConnectionPasswordResult? result;
    await pumpAndOpen(tester, (r) => result = r);

    await tester.enterText(find.byType(TextField), 'p@ss');
    await tester.tap(find.text('保存密码')); // 默认勾选 → 取消
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result?.password, 'p@ss');
    expect(result?.save, isFalse);
  });

  testWidgets('取消不回传结果', (tester) async {
    var submitted = false;
    await pumpAndOpen(tester, (r) => submitted = r != null);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(submitted, isFalse);
    expect(find.text('密码:'), findsNothing);
  });

  testWidgets('视口比表单矮也不溢出,量到的是表单自然高度', (tester) async {
    // 复刻子窗口装配(Align + 固定宽度 + 可滚动外层)量自然尺寸:
    // 写死窗口高度会随字体 / 文字缩放失准(实测差 19 像素就溢出)。
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        width: 800,
        height: 200, // 故意比表单矮
        child: Material(
          child: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                key: key,
                width: kConnectionPasswordFormWidth,
                child: ConnectionPasswordForm(
                  conn: _conn,
                  onSubmitted: (_) {},
                  onCancelled: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final size =
        (key.currentContext!.findRenderObject() as RenderBox).size;
    expect(size.width, kConnectionPasswordFormWidth);
    expect(size.height, greaterThan(200));
  });

  test('父子窗口入口参数可回读', () {
    final payload = encodeConnectionPasswordWindowArgs(
      conn: _conn,
      palette: AppTheme.dark,
      dark: true,
      channelName: 'daro/connection_password/1',
    );
    final app = buildSubWindowApp(
        ['multi_window', 'win-1', jsonEncode(payload)]) as ConnectionPasswordWindowApp;

    expect(app.conn.name, '明杰测试');
    expect(app.conn.host, '10.70.24.109');
    expect(app.palette.accent, AppTheme.dark.accent);
    expect(app.dark, isTrue);
    expect(app.channelName, 'daro/connection_password/1');

    expect(buildSubWindowApp(const []), isNull);
    expect(buildSubWindowApp(['multi_window', 'win-1', '{"type":"other"}']), isNull);
  });
}
