#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

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
  video_window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "pepehub/video-window",
      &flutter::StandardMethodCodec::GetInstance());
  video_window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "getCapabilities") {
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
            {flutter::EncodableValue("pip"), flutter::EncodableValue(false)},
            {flutter::EncodableValue("miniWindow"), flutter::EncodableValue(true)}}));
          return;
        }
        if (call.method_name() == "setPlayback") {
          const auto* parameters = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
          if (!parameters) { result->Error("arguments", "Expected playback parameters"); return; }
          auto flag = [parameters](const char* key) {
            const auto entry = parameters->find(flutter::EncodableValue(key));
            if (entry == parameters->end()) return false;
            const auto* value = std::get_if<bool>(&entry->second);
            return value && *value;
          };
          EXECUTION_STATE state = ES_CONTINUOUS;
          if (flag("playing")) {
            state |= ES_SYSTEM_REQUIRED;
            if (flag("visual")) state |= ES_DISPLAY_REQUIRED;
          }
          SetThreadExecutionState(state);
          result->Success();
          return;
        }
        if (call.method_name() != "setFullscreen" && call.method_name() != "setMiniWindow") {
          result->NotImplemented();
          return;
        }
        const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
        if (!enabled) {
          result->Error("arguments", "Expected a fullscreen boolean");
        } else if (!(call.method_name() == "setMiniWindow" ? SetVideoMiniWindow(*enabled) : SetVideoFullscreen(*enabled))) {
          result->Error("window", "Could not change the window presentation");
        } else {
          result->Success();
        }
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  SetThreadExecutionState(ES_CONTINUOUS);
  video_window_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

bool FlutterWindow::ResizeVideoFullscreen() {
  const HWND window = GetHandle();
  MONITORINFO monitor = {sizeof(MONITORINFO)};
  if (!GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) {
    return false;
  }
  return SetWindowPos(window, nullptr, monitor.rcMonitor.left, monitor.rcMonitor.top,
      monitor.rcMonitor.right - monitor.rcMonitor.left,
      monitor.rcMonitor.bottom - monitor.rcMonitor.top,
      SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED) != 0;
}

bool FlutterWindow::SetVideoFullscreen(bool enabled) {
  if (enabled && video_mini_window_ && !SetVideoMiniWindow(false)) return false;
  if (enabled == video_fullscreen_) return true;
  const HWND window = GetHandle();
  if (!window) return false;
  if (enabled) {
    if (!GetWindowPlacement(window, &video_window_placement_)) return false;
    video_window_style_ = GetWindowLongPtr(window, GWL_STYLE);
    SetWindowLongPtr(window, GWL_STYLE,
        (video_window_style_ & ~(WS_OVERLAPPEDWINDOW | WS_MAXIMIZE | WS_MINIMIZE)) | WS_POPUP);
    video_fullscreen_ = true;
    if (!ResizeVideoFullscreen()) {
      video_fullscreen_ = false;
      SetWindowLongPtr(window, GWL_STYLE, video_window_style_);
      SetWindowPlacement(window, &video_window_placement_);
      return false;
    }
  } else {
    // Allow WM_DPICHANGED to restore the normal window on its original monitor.
    video_fullscreen_ = false;
    SetWindowLongPtr(window, GWL_STYLE, video_window_style_);
    SetWindowPlacement(window, &video_window_placement_);
    SetWindowPos(window, nullptr, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  }
  return true;
}

bool FlutterWindow::SetVideoMiniWindow(bool enabled) {
  if (enabled == video_mini_window_) return true;
  const HWND window = GetHandle();
  if (!window) return false;
  if (enabled) {
    if (video_fullscreen_ && !SetVideoFullscreen(false)) return false;
    if (!GetWindowPlacement(window, &video_mini_placement_)) return false;
    video_mini_style_ = GetWindowLongPtr(window, GWL_STYLE);
    video_mini_ex_style_ = GetWindowLongPtr(window, GWL_EXSTYLE);
    MONITORINFO monitor = {sizeof(MONITORINFO)};
    if (!GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) return false;
    const UINT dpi = GetDpiForWindow(window);
    const int width = MulDiv(360, dpi ? dpi : 96, 96);
    const int height = MulDiv(240, dpi ? dpi : 96, 96);
    const int margin = MulDiv(16, dpi ? dpi : 96, 96);
    ShowWindow(window, SW_RESTORE);
    SetWindowLongPtr(window, GWL_STYLE, (video_mini_style_ | WS_OVERLAPPEDWINDOW) & ~(WS_MAXIMIZE | WS_MINIMIZE | WS_MAXIMIZEBOX));
    if (!SetWindowPos(window, HWND_TOPMOST, monitor.rcWork.right - width - margin,
        monitor.rcWork.bottom - height - margin, width, height, SWP_FRAMECHANGED)) {
      SetWindowLongPtr(window, GWL_STYLE, video_mini_style_);
      SetWindowLongPtr(window, GWL_EXSTYLE, video_mini_ex_style_);
      SetWindowPlacement(window, &video_mini_placement_);
      return false;
    }
    video_mini_window_ = true;
  } else {
    video_mini_window_ = false;
    SetWindowLongPtr(window, GWL_STYLE, video_mini_style_);
    SetWindowLongPtr(window, GWL_EXSTYLE, video_mini_ex_style_);
    SetWindowPlacement(window, &video_mini_placement_);
    SetWindowPos(window, (video_mini_ex_style_ & WS_EX_TOPMOST) ? HWND_TOPMOST : HWND_NOTOPMOST,
        0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  }
  return true;
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
    case WM_DISPLAYCHANGE:
      if (video_fullscreen_) ResizeVideoFullscreen();
      break;
    case WM_DPICHANGED:
      if (video_fullscreen_) {
        ResizeVideoFullscreen();
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
