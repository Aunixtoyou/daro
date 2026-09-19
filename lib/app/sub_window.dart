import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:base_ui_flutter/base_ui_flutter.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../widgets/connection_password_window.dart';
import '../theme/app_theme.dart';

/// `desktop_multi_window` 子窗口的公共装配。
///
/// 子窗口是**同进程里的另一个 Flutter 引擎**:拿不到 AppState,也不能直接
/// `showDialog`,只能靠 [WindowMethodChannel] 与主窗口通信;原生标题栏、尺寸、
/// 位置都得自己配。这里集中放三件容易踩坑的事:
///   - 父侧:建窗口 + 握手(就绪才用,否则回落应用内弹窗) + 收结果
///   - 子侧:把原生标题栏染成主窗口顶条的颜色(Windows 11 DWM)
///   - 子侧:把窗口外框配成「客户区刚好装下内容」并居中到主窗口
///
/// 使用者:「连接密码」(connection_password_window.dart)。
/// 「新建 / 编辑连接」试过走独立窗口,但冷启一个引擎的打开延迟不可接受,已退回应用内弹窗。

/// 子窗口握手时限:超过即认定该端没接好插件,回落应用内弹窗
const Duration kSubWindowReadyTimeout = Duration(seconds: 3);

/// 只有真机桌面才有多窗口插件;`flutter test` / `integration_test` 里通道没有
/// 实现,await 会挂起,故按环境变量直接走应用内弹窗。
bool get canUseSubWindow =>
    !Platform.environment.containsKey('FLUTTER_TEST') &&
    (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// 子窗口入口分流:按 desktop_multi_window 注入的入口参数
/// (`['multi_window', 窗口 id, 业务参数 JSON]`)构建对应 App;
/// 非子窗口(主窗口)或类型未登记时返回 null。
Widget? buildSubWindowApp(List<String> args) {
  if (args.length < 3 || args.first != 'multi_window') return null;
  final dynamic decoded = jsonDecode(args[2]);
  if (decoded is! Map) return null;
  final payload = Map<String, dynamic>.from(decoded);
  return kSubWindowBuilders[payload['type']]?.call(payload);
}

/// 子窗口类型 → 构建器。新增独立窗口时在这里登记一项。
///
/// 构建器自己负责校验参数,拿不到必需字段时返回 null(退化成空白窗口总好过崩)。
typedef SubWindowBuilder = Widget? Function(Map<String, dynamic> payload);

final Map<String, SubWindowBuilder> kSubWindowBuilders = {
  kConnectionPasswordWindowType: buildConnectionPasswordWindowApp,
};

// DWMWA_* 属性号:标题栏底色与文字色是 Windows 11 才有的能力,
// 更老版本 / 其它系统调用失败即保持系统默认色。
const int _dwmwaUseImmersiveDarkMode = 20;
const int _dwmwaCaptionColor = 35;
const int _dwmwaTextColor = 36;

/// 把子窗口的原生标题栏染成主窗口顶条的颜色(同一个 [AppPalette.surface])。
///
/// 主窗口的标题栏是 Flutter 自绘的,子窗口用系统标题栏,不染色就会一边跟
/// 系统配色、一边跟应用配色。immersive dark mode 决定最小化/最大化/关闭
/// 三个按钮的图标明暗,必须一起设,否则深底上会出现深色图标。
Future<void> applySubWindowCaption(
  AppPalette palette, {
  required bool dark,
}) async {
  if (!Platform.isWindows) return;
  try {
    final hwnd = await windowManager.getId();
    final setAttribute = ffi.DynamicLibrary.open('dwmapi.dll').lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.Uint32, ffi.Pointer<ffi.Uint32>,
            ffi.Uint32),
        int Function(
            int, int, ffi.Pointer<ffi.Uint32>, int)>('DwmSetWindowAttribute');
    final value = calloc<ffi.Uint32>();
    try {
      value.value = _colorRef(palette.surface);
      setAttribute(hwnd, _dwmwaCaptionColor, value, ffi.sizeOf<ffi.Uint32>());
      value.value = _colorRef(palette.foreground);
      setAttribute(hwnd, _dwmwaTextColor, value, ffi.sizeOf<ffi.Uint32>());
      value.value = dark ? 1 : 0;
      setAttribute(
          hwnd, _dwmwaUseImmersiveDarkMode, value, ffi.sizeOf<ffi.Uint32>());
    } finally {
      calloc.free(value);
    }
  } catch (_) {
    // 拿不到 DWM 就退回系统标题栏配色,不影响窗口功能
  }
}

/// Flutter 的 0xAARRGGBB → Win32 COLORREF 的 0x00BBGGRR(交换 R 与 B)
int _colorRef(Color color) {
  final rgb = color.toARGB32() & 0x00ffffff;
  return ((rgb & 0xff) << 16) | (rgb & 0xff00) | ((rgb >> 16) & 0xff);
}

/// 宿主对子窗口其它请求的应答(如「测试连接」要回主窗口执行)。
typedef SubWindowRequestHandler = FutureOr<Object?> Function(MethodCall call);

/// 父侧:建子窗口、等握手、把回传解成 [T],返回结果。
///
/// - 子窗口配好原生窗口后回 `ready`,本函数才认为独立窗口可用;配不上
///   (某端没接插件注册钩子)则回 `failed` 或超时不回,此时收起这个半成品窗口
///   并抛 [MissingPluginException],由调用方回落应用内弹窗;
/// - 用户点原生标题栏 X 时窗口直接销毁、不会有任何回传,因此额外监听窗口列表
///   变化,窗口消失即按取消(null)处理,避免调用方永久挂起。
///
/// [onSubmit] 负责把 `submit` 的参数解成结果;`cancel` 与窗口消失都算 null。
/// [args] 收到本函数生成的通道名,把它原样放进入口参数即可(子侧凭它回话)。
Future<T?> openSubWindow<T>({
  required String channelPrefix,
  required Map<String, dynamic> Function(String channelName) args,
  required T? Function(MethodCall call) onSubmit,
  SubWindowRequestHandler? onRequest,
}) async {
  final channelName =
      '$channelPrefix/${DateTime.now().microsecondsSinceEpoch}';
  final channel =
      WindowMethodChannel(channelName, mode: ChannelMode.unidirectional);
  final completer = Completer<T?>();
  final ready = Completer<bool>();

  // 每个分支都显式回话:回传内容(ownerBounds / testConnection)要靠返回值交给
  // 子窗口;写成闭包字面量时返回类型会被推断成 Future<void> 而报错。
  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'ready':
        if (!ready.isCompleted) ready.complete(true);
        return null;
      case 'failed':
        if (!ready.isCompleted) ready.complete(false);
        return null;
      case 'ownerBounds':
        final b = await windowManager.getBounds();
        return [b.left, b.top, b.width, b.height];
      case 'cancel':
        if (!completer.isCompleted) completer.complete(null);
        return null;
      case 'submit':
        if (!completer.isCompleted) completer.complete(onSubmit(call));
        return null;
      default:
        return onRequest == null ? null : await onRequest(call);
    }
  }

  await channel.setMethodCallHandler(handle);

  try {
    final controller = await WindowController.create(WindowConfiguration(
      hiddenAtLaunch: true,
      arguments: jsonEncode(args(channelName)),
    ));
    if (controller.windowId.isEmpty) throw MissingPluginException();

    try {
      final usable =
          await ready.future.timeout(kSubWindowReadyTimeout, onTimeout: () => false);
      if (!usable) throw MissingPluginException('独立窗口未就绪');
    } on MissingPluginException {
      // 半成品窗口不显示出来:收起来后交回调用方回落应用内弹窗
      // (子窗口配置失败时可能已自行 close,这里只尽力而为)
      try {
        await controller.hide();
      } catch (_) {}
      rethrow;
    }

    final subscription = onWindowsChanged.listen((_) async {
      if (completer.isCompleted) return;
      final alive = (await WindowController.getAll())
          .any((w) => w.windowId == controller.windowId);
      if (!alive && !completer.isCompleted) completer.complete(null);
    });
    try {
      return await completer.future;
    } finally {
      await subscription.cancel();
    }
  } finally {
    await channel.setMethodCallHandler(null);
  }
}

/// 子侧:在窗口仍 hidden 时配好标题 / 尺寸 / 位置,再显示并回 `ready`。
///
/// 原生侧建的窗口是 800x600 空标题,不配就闪出空白大窗。
/// [contentSize] 在首帧布局完成后调用,给出**客户区**目标尺寸
/// (量出来的自然尺寸,或宿主写死的尺寸)。
/// 任一步失败都回 `failed` 并自行 close,不留隐藏的半成品窗口。
Future<void> configureSubWindow({
  required String channelName,
  required String title,
  required AppPalette palette,
  required bool dark,
  required Size Function() contentSize,
}) async {
  final channel =
      WindowMethodChannel(channelName, mode: ChannelMode.unidirectional);
  try {
    await windowManager.ensureInitialized();
    // Windows 端 window_manager 的 ITaskbarList3 只在 waitUntilReadyToShow
    // 里创建;子窗口引擎不调它,setSkipTaskbar 就会解引用空指针直接崩进程。
    await windowManager.waitUntilReadyToShow();
    await applySubWindowCaption(palette, dark: dark);
    await windowManager.setTitle(title);
    await windowManager.setResizable(false);
    await windowManager.setSkipTaskbar(true);
    final outer = await _sizeWindowToClient(contentSize());
    await _centerOverOwner(channel, outer);
    await windowManager.show();
    await windowManager.focus();
    await channel.invokeMethod('ready');
  } catch (_) {
    try {
      await channel.invokeMethod('failed');
    } catch (_) {
      // 连父窗口都联系不上时由父侧超时兜底
    }
    try {
      await windowManager.close();
    } catch (_) {}
  }
}

/// 把窗口外框调成「客户区刚好是 [content]」,返回定稿后的外框尺寸。
///
/// 外框 = 内容 + 标题栏与边框占位,占位多少只能从真实窗口量;原生侧建的窗口
/// 还没动过尺寸,此刻的「外框 - 客户区」就是占位,据此设一次即可。
/// 内容高度也不能写死常量:实测写死会随字体与文字缩放失准(差 19 像素就溢出)。
Future<Size> _sizeWindowToClient(Size content) async {
  final bounds = await windowManager.getBounds();
  final client = _currentClientSize();
  final outer = Size(
    content.width + (bounds.width - client.width),
    content.height + (bounds.height - client.height),
  );
  await windowManager.setSize(outer);
  return outer;
}

/// 当前客户区尺寸(逻辑像素,与 [windowManager.getBounds] 同一单位):
/// 直接读引擎 view,不依赖 BuildContext,也不触发重建
Size _currentClientSize() {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  return view.physicalSize / view.devicePixelRatio;
}

/// 居中到主窗口(而非整屏):向父窗口要一次自身矩形
Future<void> _centerOverOwner(WindowMethodChannel channel, Size outer) async {
  try {
    final bounds = await channel.invokeMethod<List<dynamic>>('ownerBounds');
    if (bounds != null && bounds.length == 4) {
      final owner = Rect.fromLTWH(
          (bounds[0] as num).toDouble(),
          (bounds[1] as num).toDouble(),
          (bounds[2] as num).toDouble(),
          (bounds[3] as num).toDouble());
      await windowManager.setPosition(Offset(
        owner.center.dx - outer.width / 2,
        owner.center.dy - outer.height / 2,
      ));
      return;
    }
  } catch (_) {
    // 拿不到主窗口位置时按屏幕居中
  }
  await windowManager.center();
}

/// 子侧:把结果回传给父窗口并关窗。[result] 为 null 即按取消处理。
///
/// 父窗口已不在(极端时序)时回传失败也没关系,关窗照常。
Future<void> finishSubWindow(String channelName, {Map<String, Object?>? result}) async {
  final channel =
      WindowMethodChannel(channelName, mode: ChannelMode.unidirectional);
  try {
    await channel.invokeMethod(result == null ? 'cancel' : 'submit', result);
  } catch (_) {}
  await windowManager.close();
}

/// 子窗口的 App 根:自带主题与 TokenScope,原生标题栏承担标题与关闭。
Widget buildSubWindowAppRoot({
  required String title,
  required AppPalette palette,
  required bool dark,
  required Widget child,
}) {
  final brightness = dark ? Brightness.dark : Brightness.light;
  // 色板挂成 Provider:子窗口引擎没有 AppState,Tokens.of 靠这条回落取色
  return Provider<AppPalette>.value(
    value: palette,
    child: TokenScope(
      tokens: palette.toDesktopTokens(),
      child: MaterialApp(
        title: title,
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(brightness, palette),
        home: SubWindowBody(palette: palette, child: child),
      ),
    ),
  );
}

/// 子窗口内容底座:铺满客户区的底色 + 透明 Material 宿主。
///
/// base-ui 的 Input 内嵌 TextField,必须有 Material 祖先;透明即可,
/// 底色由外层 Container 提供,免得 Material 的墨水与阴影污染绘制。
class SubWindowBody extends StatelessWidget {
  const SubWindowBody({
    super.key,
    required this.palette,
    required this.child,
  });

  final AppPalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.background,
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}
