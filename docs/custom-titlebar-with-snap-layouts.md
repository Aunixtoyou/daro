# 自绘标题栏 + Win11 Snap Layouts 支持原理

> 记录将菜单栏放到窗口标题栏、并保留 Win11 Snap Layouts 快速布局功能的实现原理、踩过的坑和最终方案。
>
> 涉及文件：`lib/main.dart`、`lib/widgets/top_menu.dart`、`windows/runner/flutter_window.cpp`、`windows/runner/CMakeLists.txt`。

---

## 1. 目标

- 把应用菜单栏（文件/编辑/查看/...）画进窗口标题栏区域，省掉系统标题栏占用的 32px 高度。
- 标题栏左侧是菜单 + 拖拽区，右侧是最小化/最大化/关闭三个窗口控制按钮。
- 保留 Win11 的 Snap Layouts 功能（hover 最大化按钮弹出布局网格菜单）。

---

## 2. 关键背景：Flutter Windows 的窗口架构

Flutter Windows 应用的窗口分两层 HWND：

```
┌──────────────────────────────────┐
│ 主窗口 HWND (Win32Window)        │   ← 主 WndProc: FlutterWindow::MessageHandler
│ ┌────────────────────────────┐   │
│ │ FlutterView 子 HWND         │   │ ← 子 WndProc: Flutter engine 内部默认处理
│ │ (覆盖整个客户区)             │   │   鼠标消息全部进入这个 HWND
│ │                            │   │
│ └────────────────────────────┘   │
└──────────────────────────────────┘
```

- **FlutterView 子 HWND** 覆盖整个客户区，所有鼠标消息（包括 `WM_NCHITTEST`、`WM_MOUSEMOVE`）都被它吃掉。
- **主窗口 HWND 的 WndProc 几乎收不到 `WM_NCHITTEST`**——只有鼠标在窗口边框（resize 区）时才收到。
- 这是后续所有"为什么直接处理 WM_NCHITTEST 没用"的根因。

---

## 3. 阶段一：隐藏系统标题栏 + 自绘菜单栏（基础部分）

### 3.1 隐藏系统标题栏

`lib/main.dart` 在 `windowManager.waitUntilReadyToShow` 后设置：

```dart
windowManager.waitUntilReadyToShow(
  const WindowOptions(
    titleBarStyle: TitleBarStyle.hidden,  // 隐藏系统标题栏
  ),
  () async { ... },
);
```

`TitleBarStyle.hidden` 让系统不再绘制标题栏，但保留窗口边框。客户区扩展到原来标题栏的位置。

### 3.2 自绘菜单栏

`lib/widgets/top_menu.dart` 实现 `TopMenu`：

- 高度 `kWindowCaptionHeight`（32），背景色 `appPalette.menuBar`。
- 左侧 `MenuStrip`（base-ui-flutter 提供，支持点击展开 + 悬停自动切换），外面包一层 `DragToMoveArea` 让空白处可拖动窗口、双击切换最大化。
- 右侧依次：主题切换按钮、`WindowCaptionButton.minimize`、`WindowCaptionButton.maximize`/`unmaximize`、`WindowCaptionButton.close`。
- `WindowCaptionButton` 直接复用 window_manager 0.5.2 自带的，**不自绘按钮图标**。

`_TopMenuState` 监听 `WindowListener.onWindowMaximize/onWindowUnmaximize` 切换最大化/还原图标。

### 3.3 阶段一的副作用

隐藏系统标题栏后，系统不再把右上角按钮识别为原生 NC 按钮（`WM_NCHITTEST` 不返回 `HTMAXBUTTON`）。后果：

- hover 最大化按钮**不会弹出 Win11 Snap Layouts 网格**。
- 但点击仍工作（走 Flutter 端 `WindowCaptionButton.onPressed` → `windowManager.maximize()`）。

---

## 4. 阶段二：恢复 Snap Layouts（子类化子 HWND）

### 4.1 思路

让系统重新把右上角最大化按钮区域识别为 `HTMAXBUTTON`——Win11 看到这个返回值就会在 hover 时弹 Snap Layouts。

### 4.2 第一坑：主窗口 WndProc 收不到 WM_NCHITTEST

最初在 `FlutterWindow::MessageHandler`（主窗口 WndProc）里处理 `WM_NCHITTEST`：

```cpp
case WM_NCHITTEST:
  if (鼠标在最大化按钮区域) return HTMAXBUTTON;
  return HTCLIENT;
```

**实测无效**。通过日志确认：鼠标在客户区内移动时，主窗口的 `WM_NCHITTEST` 根本不触发——因为 FlutterView 子 HWND 在它自己的 WndProc 里把 `WM_NCHITTEST` 默认返回 `HTCLIENT` 抢走了所有事件。

### 4.3 正解：子类化子 HWND

用 `SetWindowLongPtr(view, GWLP_WNDPROC, newProc)` 替换 FlutterView 子 HWND 的 WndProc，在新的 WndProc 里处理 `WM_NCHITTEST`：

```cpp
g_view_hwnd = flutter_controller_->view()->GetNativeWindow();
g_orig_view_wndproc = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
    g_view_hwnd, GWLP_WNDPROC,
    reinterpret_cast<LONG_PTR>(ViewWndProc)));
```

新 WndProc 的 `WM_NCHITTEST` 处理：

```cpp
case WM_NCHITTEST:
  if (g_hovered_button == 2) return HTMAXBUTTON;  // 最大化按钮
  return HTCLIENT;
```

`g_hovered_button` 是当前 hover 的按钮编号（0=无，1=最小化，2=最大化，3=关闭），由 `WM_MOUSEMOVE`/`WM_NCMOUSEMOVE` 时通过 `GetCursorPos` + `ScreenToClient` + `PtInRect` 判断。

**只让最大化按钮返回 `HTMAXBUTTON`**——最小化/关闭按钮仍返回 `HTCLIENT`，让 Flutter 端 `WindowCaptionButton.onPressed` 处理点击，避免系统 NC 流程依赖窗口样式导致的点击失灵。

### 4.4 第二坑：进入 NC 区域后 WM_MOUSEMOVE 失效

鼠标进入 `HTMAXBUTTON` 区域后，系统把鼠标事件归入 NC 流程，子 HWND 收不到 `WM_MOUSEMOVE`——**无法检测鼠标何时离开按钮**。

解决：进入按钮区域时启动 `SetTimer`（24ms 一次），在 `WM_TIMER` 里轮询 `GetCursorPos` 判断是否离开，离开后 `KillTimer`。

### 4.5 第三坑：点击不触发最大化

返回 `HTMAXBUTTON` 后，hover 弹 Snap Layouts 成功，但点击按钮没反应。

原因：系统在 NC 点击时给子 HWND 发 `WM_NCLBUTTONDOWN`，子 HWND 默认不处理——消息不会传到主窗口的 `DefWindowProc`，所以不会触发 `SC_MAXIMIZE`。

解决：在子 HWND 的 WndProc 里捕获 `WM_NCLBUTTONDOWN`，**异步**转发 `SC_MAXIMIZE`/`SC_RESTORE` 到主窗口：

```cpp
case WM_NCLBUTTONDOWN:
  if (g_hovered_button == 2) {
    HWND main = GetParent(hWnd);
    bool maximized = ::IsZoomed(main);
    PostMessage(main, WM_SYSCOMMAND,
                maximized ? SC_RESTORE : SC_MAXIMIZE, 0);
    return 0;
  }
  break;
```

`PostMessage`（而非 `SendMessage`）避免同步调用导致的重入/死锁。系统执行最大化/还原后发 `WM_SIZE`，window_manager 监听后 emit "maximize"/"unmaximize" 事件给 Dart，Dart 端 `onWindowMaximize` 同步图标。

---

## 5. 阶段三：恢复 hover 背景效果（method channel）

### 5.1 问题

返回 `HTMAXBUTTON` 后，鼠标进入按钮区域时 Flutter 端 `WindowCaptionButton` 内部的 `MouseRegion` 失效——**按钮 hover 背景不变色**。最小化/关闭按钮不受影响（仍返回 `HTCLIENT`）。

### 5.2 方案

native 端通过 `MethodChannel` 主动推送 hover 状态到 Dart 端，Dart 端在最大化按钮上叠加 hover 背景。

#### native 端

`flutter_window.cpp` 创建 channel：

```cpp
g_hover_channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
    flutter_controller_->engine()->messenger(), "daro/titlebar",
    &flutter::StandardMethodCodec::GetInstance());
```

`UpdateHover` 中 hover 状态变化时推送：

```cpp
void NotifyHoverToDart(int button) {
  if (!g_hover_channel) return;
  g_hover_channel->InvokeMethod(
      "onHoverChange",
      std::make_unique<flutter::EncodableValue>(
          flutter::EncodableValue(button)));
}
```

#### Dart 端

`top_menu.dart` 订阅 channel：

```dart
const _titlebarChannel = MethodChannel('daro/titlebar');

_TitlebarChannel.setMethodCallHandler((call) async {
  if (call.method == 'onHoverChange' && call.arguments is int) {
    final next = call.arguments as int;
    if (next != _nativeHoveredButton && mounted) {
      setState(() => _nativeHoveredButton = next);
    }
  }
  return null;
});
```

最大化按钮封装为 `_MaximizeButton`，用 `Stack` 在 `WindowCaptionButton` 上叠加半透明背景：

```dart
Stack(children: [
  WindowCaptionButton.maximize(brightness: brightness, onPressed: ...),
  if (isHovered)
    Positioned.fill(
      child: IgnorePointer(  // 让点击穿透到 NC 区域
        child: Container(color: hoverBg),
      ),
    ),
]);
```

`hoverBg` 与 window_manager 内部 `WindowCaptionButton` 的 hover 颜色对齐（`window_caption_button.dart:342-363`）：

| 主题 | hover 颜色 |
|---|---|
| light | `Colors.black.withValues(alpha: 0.0373)` |
| dark | `Colors.white.withValues(alpha: 0.0605)` |

---

## 6. 文件改动清单

### `lib/main.dart`

- `WindowOptions` 加 `titleBarStyle: TitleBarStyle.hidden`。

### `lib/widgets/top_menu.dart`

- 改为 `StatefulWidget` + `WindowListener`。
- 高度 `kWindowCaptionHeight`（32），背景 `appPalette.menuBar`。
- 左侧 `DragToMoveArea` 包裹 `MenuStrip`，右侧窗口控制按钮 + 主题切换按钮。
- 监听 `MethodChannel('daro/titlebar')` 接收 native 端推送的 hover 状态。
- 新增 `_MaximizeButton` widget：`Stack` 叠加 `WindowCaptionButton` + hover 背景层。

### `windows/runner/flutter_window.cpp`

- include `<flutter/method_channel.h>` + `<flutter/standard_method_codec.h>` + `<windowsx.h>`。
- 全局变量：`g_view_hwnd`、`g_orig_view_wndproc`、`g_hovered_button`、`g_hover_channel`。
- `OnCreate`：创建 `MethodChannel`、子类化 FlutterView 子 HWND。
- `OnDestroy`：恢复原子 HWND WndProc、reset channel。
- `ViewWndProc`：处理 `WM_MOUSEMOVE`/`WM_NCMOUSEMOVE`/`WM_TIMER`/`WM_NCHITTEST`/`WM_NCLBUTTONDOWN`。
- `UpdateHover`：检测 hover 状态变化，启停 timer，通知 Dart。
- `GetHoveredButton`、`GetButtonRects`、`DipToPx`：辅助函数。
- `NotifyHoverToDart`：通过 channel 推送 hover 状态。

### `windows/runner/CMakeLists.txt`

- 加 `/utf-8` 编译选项，允许 cpp 含中文注释。

---

## 7. 编译选项坑

`flutter_window.cpp` 源文件以 UTF-8（无 BOM）保存并含中文注释。MSVC 在 GBK 代码页（936）下会报 `C2220`/`C4819` 警告甚至错误。`CMakeLists.txt` 必须加：

```cmake
target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")
```

---

## 8. 已知限制

- **点击 Snap Layouts 中的具体布局**：当前 `WM_NCLBUTTONDOWN` 直接转发 `SC_MAXIMIZE`/`SC_RESTORE`，不携带 Win11 Snap Layout 选中的具体布局标识。若用户点 Snap Layout 网格中的某个布局，可能只触发普通最大化，不按所选布局贴边。
- **最大化按钮 hover 时 Flutter 端的 hover 颜色不再触发**：因为鼠标事件被系统接管，Flutter 端 `WindowCaptionButton` 内部的 `MouseRegion` 失效。本文档阶段三通过 method channel + Stack 叠加背景模拟。
- **DPI 变化**：按钮宽度 46、高度 32 在 DIP 单位下与 `WindowCaptionButton.minWidth` 对齐，按窗口 DPI 缩放（`DipToPx`）。多显示器 DPI 不同时切换显示器可能短暂错位，待验证。
- **窗口尺寸变化时**：`GetButtonRects` 在每次 `WM_NCHITTEST` / `WM_MOUSEMOVE` 时重新计算，所以窗口 resize 后坐标自动跟随。

---

## 9. 参考资源

- **luoluoqixi/flutter_windows11_snap_layouts_examples**：
  https://github.com/luoluoqixi/flutter_windows11_snap_layouts_examples
  说明子类化 FlutterView 子 HWND 是必须的，README 提到 "C++端接管了 Flutter 侧的 Client 区域的 HWND 的 WndProc 事件"。

- **walterlv 博客**：Flutter Windows 窗口子 HWND 遮挡父窗口 WM_NCHITTEST 的原理。

- **window_manager 0.5.2**：`WindowCaptionButton` 源码 `lib/src/widgets/window_caption_button.dart` 提供 hover 颜色方案。

- **Flutter issue #98456**：讨论 Win32 窗口消息从 native 推送到 Dart 的方案（MethodChannel / EventChannel）。

---

## 10. 整体流程图

```
用户 hover 最大化按钮
       │
       ▼
FlutterView 子 HWND 收到 WM_MOUSEMOVE
       │
       ▼
ViewWndProc.WM_MOUSEMOVE → UpdateHover
       │  ├─ GetCursorPos → PtInRect(maximize rect) → g_hovered_button = 2
       │  ├─ SetTimer(24ms) 续命检测离开
       │  └─ NotifyHoverToDart(2) ──► MethodChannel("daro/titlebar")
       │                                      │
       │                                      ▼
       │                          Dart 端 setState(_nativeHoveredButton = 2)
       │                                      │
       │                                      ▼
       │                          _MaximizeButton 叠加 hover 背景
       │
       ▼
系统发 WM_NCHITTEST → ViewWndProc 返回 HTMAXBUTTON
       │
       ▼
Win11 弹出 Snap Layouts 网格 ✓

用户点击
       │
       ▼
系统发 WM_NCLBUTTONDOWN → ViewWndProc 捕获
       │  └─ PostMessage(main, WM_SYSCOMMAND, SC_MAXIMIZE)
       │
       ▼
主窗口执行最大化 → WM_SIZE → window_manager emit "maximize"
       │
       ▼
Dart 端 onWindowMaximize → setState(_isMaximized = true)
       │
       ▼
_MaximizeButton 切换为 unmaximize 图标 ✓
```
