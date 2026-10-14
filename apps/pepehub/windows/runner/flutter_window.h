#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> video_window_channel_;
  bool SetVideoFullscreen(bool enabled);
  bool ResizeVideoFullscreen();
  bool SetVideoMiniWindow(bool enabled);
  bool video_mini_window_ = false;
  LONG_PTR video_mini_style_ = 0;
  LONG_PTR video_mini_ex_style_ = 0;
  WINDOWPLACEMENT video_mini_placement_ = {sizeof(WINDOWPLACEMENT)};
  bool video_fullscreen_ = false;
  LONG_PTR video_window_style_ = 0;
  WINDOWPLACEMENT video_window_placement_ = {sizeof(WINDOWPLACEMENT)};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
