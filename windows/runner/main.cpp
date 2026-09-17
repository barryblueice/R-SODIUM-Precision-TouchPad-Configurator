#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Keep ownership until the window, Flutter engine and HID bridge are destroyed.
// Local scopes the instance to the current Windows login session.
class ApplicationInstance {
 public:
  enum class Result { primary, secondary, error };

  ApplicationInstance() = default;
  ApplicationInstance(const ApplicationInstance&) = delete;
  ApplicationInstance& operator=(const ApplicationInstance&) = delete;

  ~ApplicationInstance() {
    if (owns_mutex_) ::ReleaseMutex(mutex_);
    if (mutex_) ::CloseHandle(mutex_);
  }

  Result AcquireOrActivate() {
    mutex_ = ::CreateMutexW(
        nullptr, FALSE, L"Local\\RSODIUM.TouchpadConfigurator.SingleInstance");
    if (!mutex_) return Result::error;

    // A concurrent launch may own the mutex before its window exists. Wait a
    // bounded time for that window, or take ownership if that launch exits.
    const ULONGLONG deadline = ::GetTickCount64() + 5000;
    DWORD wait_ms = 0;
    do {
      const DWORD result = ::WaitForSingleObject(mutex_, wait_ms);
      if (result == WAIT_OBJECT_0 || result == WAIT_ABANDONED) {
        owns_mutex_ = true;
        return Result::primary;
      }
      if (result != WAIT_TIMEOUT) return Result::error;

      HWND existing_window =
          ::FindWindowW(Win32Window::kWindowClassName, nullptr);
      if (existing_window) {
        // SW_SHOW preserves a maximized window; restore only when minimized.
        // Async avoids hanging this process if the existing UI is busy.
        ::ShowWindowAsync(existing_window,
                          ::IsIconic(existing_window) ? SW_RESTORE : SW_SHOW);
        if (!::SetForegroundWindow(existing_window)) {
          FLASHWINFO flash = {sizeof(FLASHWINFO), existing_window,
                             FLASHW_TRAY, 3, 0};
          ::FlashWindowEx(&flash);
        }
        return Result::secondary;
      }
      wait_ms = 50;
    } while (::GetTickCount64() < deadline);

    // A slow/hung first launch must never allow a second Flutter/HID instance.
    return Result::secondary;
  }

 private:
  HANDLE mutex_ = nullptr;
  bool owns_mutex_ = false;
};

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  ApplicationInstance application_instance;
  const auto instance_result = application_instance.AcquireOrActivate();
  if (instance_result == ApplicationInstance::Result::secondary) {
    return EXIT_SUCCESS;
  }
  if (instance_result == ApplicationInstance::Result::error) {
    ::MessageBoxW(nullptr, L"无法检查程序运行状态，请稍后重试。",
                  L"R-SODIUM TouchPad Configurator", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"R-SODIUM TouchPad Configurator", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
