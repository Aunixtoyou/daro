import 'package:daro/data/db_data.dart';
import 'package:daro/pages/connection_dialog_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 连接向导两步冒烟:新建走「选类型 → 填表单」,编辑直接进表单;
// 结果与「测试连接」都由宿主(ConnectionDialogPage)注入,弹窗内容与宿主解耦。

const _mysql = ConnectionInfo(
    name: '本地 MySQL',
    typeId: 'mysql',
    host: '127.0.0.1',
    port: '3306',
    username: 'root',
    password: 'pw');

void main() {
  /// 按弹窗客户区的尺寸排版向导,返回期间收到的所有结果(取消为 null)
  Future<List<ConnectionInfo?>> pumpWizard(
    WidgetTester tester, {
    ConnectionInfo? initial,
    Future<(bool, String)> Function(ConnectionInfo)? onTestConnection,
  }) async {
    final results = <ConnectionInfo?>[];
    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        width: kConnectionEditorContentSize.width,
        height: kConnectionEditorContentSize.height,
        child: Material(
          child: ConnectionWizard(
            initial: initial,
            onResult: results.add,
            onTestConnection: onTestConnection ?? (info) async => (true, 'ok'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('新建:先选类型,未选中不能进下一步', (tester) async {
    await pumpWizard(tester);
    expect(find.text('选择一个连接类型:'), findsOneWidget);
    expect(find.text('主机:'), findsNothing);

    // 「下一步」此时是禁用态(Button onPressed=null):点了不换步
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('选择一个连接类型:'), findsOneWidget);

    await tester.tap(find.text('MySQL'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.text('主机:'), findsOneWidget);
    // 新建模式可以回退到选择步
    expect(find.text('上一步'), findsOneWidget);
  });

  testWidgets('编辑:直接进表单并预填,不给「上一步」', (tester) async {
    await pumpWizard(tester, initial: _mysql);
    expect(find.text('选择一个连接类型:'), findsNothing);
    expect(find.text('主机:'), findsOneWidget);
    expect(find.text('127.0.0.1'), findsOneWidget);
    expect(find.text('本地 MySQL'), findsOneWidget);
    expect(find.text('上一步'), findsNothing);
  });

  testWidgets('确定回传表单值,取消回传 null', (tester) async {
    final results = await pumpWizard(tester, initial: _mysql);
    await tester.enterText(find.widgetWithText(TextField, '127.0.0.1'), 'db.internal');
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(results.single!.host, 'db.internal');
    expect(results.single!.typeId, 'mysql');
    // 「保存密码」默认跟随已有配置(密码非空即勾选),密码原样带回
    expect(results.single!.password, 'pw');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(results.last, isNull);
  });

  testWidgets('「测试连接」交宿主执行(表单不自己连库)', (tester) async {
    ConnectionInfo? probed;
    await pumpWizard(tester, initial: _mysql, onTestConnection: (info) async {
      probed = info;
      return (false, '连不上');
    });

    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    expect(probed?.typeId, 'mysql');
    expect(probed?.host, '127.0.0.1');
    // 失败结果落在表单内的提示条上,不弹 Material SnackBar
    expect(find.text('连不上'), findsOneWidget);
  });
}
