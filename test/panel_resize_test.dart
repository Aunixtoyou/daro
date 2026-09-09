import 'package:daro/app/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 侧栏拖动改宽( AppState.resizeLeftPanel / resizeRightPanel )单元测试。
/// 构造 AppState 触发的异步本地加载均已 catch,不产生未处理异常。
void main() {
  test('左栏:向右拖动变宽,并在上下限夹紧', () {
    final app = AppState();
    expect(app.leftPanelWidth.value, 240);

    app.resizeLeftPanel(60);
    expect(app.leftPanelWidth.value, 300);

    app.resizeLeftPanel(-10000);
    expect(app.leftPanelWidth.value, 180);
    app.resizeLeftPanel(10000);
    expect(app.leftPanelWidth.value, 600);
  });

  test('右栏:停靠右缘,拖动增量方向相反(向左拖变宽)', () {
    final app = AppState();
    expect(app.rightPanelWidth.value, 300);

    app.resizeRightPanel(-80);
    expect(app.rightPanelWidth.value, 380);

    app.resizeRightPanel(10000);
    expect(app.rightPanelWidth.value, 200);
    app.resizeRightPanel(-10000);
    expect(app.rightPanelWidth.value, 640);
  });

  test('宽度用 ValueNotifier 承载:拖动只重建面板容器', () {
    final app = AppState();
    var notified = 0;
    app.leftPanelWidth.addListener(() => notified++);

    app.resizeLeftPanel(10);
    app.resizeLeftPanel(10);
    expect(notified, 2);

    // 夹紧到同一值时不再重复通知
    app.resizeLeftPanel(10000);
    expect(notified, 3);
    app.resizeLeftPanel(10000);
    expect(notified, 3);
  });
}
