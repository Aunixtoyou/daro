#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <optional>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Win11 Snap Layouts 支持:FlutterView 子 HWND 吃掉主窗口的 WM_NCHITTEST,
// 必须子类化子 HWND 才能拦截。详见 flutter_window.cpp 顶部说明。
constexpr UINT_PTR kHoverTimerId = 2233;
constexpr int kHoverTimerMs = 24;

// 按钮宽度 46、标题栏高度 32(与 lib/widgets/top_menu.dart 中
// WindowCaptionButton.minWidth:46 / kWindowCaptionHeight:32 对齐)。
constexpr int kButtonWidthDip = 46;
constexpr int kCaptionHeightDip = 32;

HWND g_view_hwnd = nullptr;
WNDPROC g_orig_view_wndproc = nullptr;
// 当前 hover 的按钮(0=无;1=最小化;2=最大化;3=关闭)。
int g_hovered_button = 0;

// 用于把 hover 状态推送到 Dart 端(让最大化按钮显示 hover 背景)。
// 鼠标进入 HTMAXBUTTON 区域后,Flutter 端 WindowCaptionButton 的 MouseRegion
// 收不到事件,必须由 native 端主动通知。
std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_hover_channel;

void NotifyHoverToDart(int button) {
  if (!g_hover_channel) return;
  g_hover_channel->InvokeMethod(
      "onHoverChange",
      std::make_unique<flutter::EncodableValue>(flutter::EncodableValue(button)));
}

int DipToPx(int dip, HWND hWnd) {
  return MulDiv(dip, GetDpiForWindow(hWnd), 96);
}

// 三个按钮的 rect(子 HWND 客户坐标系)。
struct ButtonRects {
  RECT minimize;
  RECT maximize;
  RECT close;
};

ButtonRects GetButtonRects(HWND hWnd) {
  RECT client;
  GetClientRect(hWnd, &client);
  const int bw = DipToPx(kButtonWidthDip, hWnd);
  const int bh = DipToPx(kCaptionHeightDip, hWnd);
  ButtonRects r{};
  r.minimize = {client.right - 3 * bw, 0, client.right - 2 * bw, bh};
  r.maximize = {client.right - 2 * bw, 0, client.right - bw, bh};
  r.close = {client.right - bw, 0, client.right, bh};
  return r;
}

int GetHoveredButton(HWND hWnd) {
  POINT pt;
  if (!GetCursorPos(&pt)) return 0;
  if (!ScreenToClient(hWnd, &pt)) return 0;
  const auto r = GetButtonRects(hWnd);
  if (PtInRect(&r.close, pt)) return 3;
  if (PtInRect(&r.maximize, pt)) return 2;
  if (PtInRect(&r.minimize, pt)) return 1;
  return 0;
}

void UpdateHover(HWND hWnd) {
  int next = GetHoveredButton(hWnd);
  if (next != g_hovered_button) {
    g_hovered_button = next;
    if (g_hovered_button != 0) {
      // 进入 NC 区域后子窗口收不到 WM_MOUSEMOVE,靠 timer 续命检测离开。
      SetTimer(hWnd, kHoverTimerId, kHoverTimerMs, nullptr);
    } else {
      KillTimer(hWnd, kHoverTimerId);
    }
    // 通知 Dart 端当前 hover 的按钮,让最大化按钮(被 HTMAXBUTTON 抢走事件)
    // 也能显示 hover 背景。最小化/关闭按钮由 Flutter 端 MouseRegion 自行处理。
    NotifyHoverToDart(g_hovered_button);
  }
}

LRESULT CALLBACK ViewWndProc(HWND hWnd, UINT message, WPARAM wParam,
                             LPARAM lParam) noexcept {
  switch (message) {
    case WM_MOUSEMOVE:
    case WM_NCMOUSEMOVE:
      UpdateHover(hWnd);
      break;
    case WM_TIMER:
      if (wParam == kHoverTimerId) {
        if (GetHoveredButton(hWnd) == 0) {
          g_hovered_button = 0;
          KillTimer(hWnd, kHoverTimerId);
          SetWindowPos(hWnd, nullptr, 0, 0, 0, 0,
                      SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
        }
      }
      break;
    case WM_NCHITTEST:
      // 只让系统识别最大化按钮:Win11 据此在 hover 时弹 Snap Layouts,并接管
      // 点击(发 WM_SYSCOMMAND SC_MAXIMIZE → WM_SIZE SIZE_MAXIMIZED →
      // window_manager emit "maximize" → Dart 端 onWindowMaximize 同步图标)。
      // 最小化/关闭按钮仍返回 HTCLIENT,继续走 Flutter 端 WindowCaptionButton
      // 的 onPressed(避免系统 NC 处理依赖窗口样式,导致点击失灵)。
      if (g_hovered_button == 2) {
        return HTMAXBUTTON;
      }
      return HTCLIENT;
    case WM_NCLBUTTONDOWN:
      // 子 HWND 返回 HTMAXBUTTON 后,系统在 NC 点击时发此消息给子 HWND 而非
      // 主窗口。捕获并异步转发 SC_MAXIMIZE/SC_RESTORE 到主窗口,由系统执行
      // 最大化/还原(window_manager 通过 WM_SIZE 监听到 maximize 事件并 emit
      // 给 Dart)。用 PostMessage 避免同步调用导致的重入/死锁。
      if (g_hovered_button == 2) {
        HWND main = GetParent(hWnd);
        bool maximized = ::IsZoomed(main);
        PostMessage(main, WM_SYSCOMMAND,
                   maximized ? SC_RESTORE : SC_MAXIMIZE, 0);
        return 0;
      }
      break;
  }
  return CallWindowProc(g_orig_view_wndproc, hWnd, message, wParam, lParam);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 创建与 Dart 端通信的 method channel,用于推送窗口按钮 hover 状态。
  // 鼠标进入 HTMAXBUTTON 区域后,Flutter 端 MouseRegion 失效,native 端
  // 通过此 channel 主动通知 Dart 端当前 hover 的按钮,让其重绘 hover 背景。
  g_hover_channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "daro/titlebar",
      &flutter::StandardMethodCodec::GetInstance());

  // Handle Dart-initiated window commands. The titlebar double-click uses
  // this "toggleMaximize" path instead of window_manager.maximize(), because
  // the latter uses GetWindowPlacement on an uninitialized WINDOWPLACEMENT
  // (length not set) and therefore fails. This uses ShowWindow directly,
  // bypassing WM_SYSCOMMAND routing entirely (PostMessage with
  // SC_MAXIMIZE was also tested and silently swallowed somewhere in the
  // top-level window-proc delegate chain). ShowWindow still triggers
  // WM_SIZE/SIZE_MAXIMIZED, so window_manager's maximize event (and thus
  // Dart-side onWindowMaximize) keeps working.
  g_hover_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "toggleMaximize") {
          HWND main = GetParent(g_view_hwnd);
          bool ok = false;
          if (main != nullptr) {
            ok = true;
            if (::IsZoomed(main)) {
              ::ShowWindow(main, SW_RESTORE);
            } else {
              ::ShowWindow(main, SW_MAXIMIZE);
            }
          }
          result->Success(flutter::EncodableValue(ok));
        } else {
          result->NotImplemented();
        }
      });

  // 子类化 FlutterView 子 HWND:让 Win11 在 hover 最大化按钮时弹 Snap Layouts。
  // Flutter Windows 把所有输入送到子 HWND(FlutterView),主窗口的 WndProc
  // 收不到 WM_NCHITTEST;且子 HWND 默认在 WM_NCHITTEST 返回 HTCLIENT 抢走
  // NC 流程。这里替换其 WndProc,根据 hover 状态返回 HTMAXBUTTON 等让系统
  // 识别按钮区域。参考 https://github.com/luoluoqixi/flutter_windows11_snap_layouts_examples
  g_view_hwnd = flutter_controller_->view()->GetNativeWindow();
  g_orig_view_wndproc = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
      g_view_hwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(ViewWndProc)));

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (g_view_hwnd && g_orig_view_wndproc) {
    SetWindowLongPtr(g_view_hwnd, GWLP_WNDPROC,
                     reinterpret_cast<LONG_PTR>(g_orig_view_wndproc));
    g_view_hwnd = nullptr;
    g_orig_view_wndproc = nullptr;
  }
  g_hover_channel.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
