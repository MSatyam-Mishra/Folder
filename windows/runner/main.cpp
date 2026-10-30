#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// A window opened from another Explorer window (New window, Ctrl+N, Open in
// new window) appears a little below and right of it, at its size, instead
// of exactly on top of it. Create takes logical pixels.
void CascadeFromOpener(Win32Window::Point* origin, Win32Window::Size* size) {
  HWND opener = ::GetForegroundWindow();
  wchar_t class_name[64];
  if (!opener || !::GetClassNameW(opener, class_name, 64) ||
      wcscmp(class_name, L"FLUTTER_RUNNER_WIN32_WINDOW") != 0) {
    return;
  }
  // Only this app's windows: other Flutter apps use the same class name.
  DWORD pid = 0;
  ::GetWindowThreadProcessId(opener, &pid);
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) {
    return;
  }
  wchar_t theirs[MAX_PATH];
  wchar_t ours[MAX_PATH];
  DWORD length = MAX_PATH;
  const bool same =
      ::QueryFullProcessImageNameW(process, 0, theirs, &length) &&
      ::GetModuleFileNameW(nullptr, ours, MAX_PATH) &&
      _wcsicmp(theirs, ours) == 0;
  ::CloseHandle(process);
  if (!same) {
    return;
  }

  // The restored size and place, also when the opener is maximized.
  WINDOWPLACEMENT placement = {sizeof(placement)};
  if (!::GetWindowPlacement(opener, &placement)) {
    return;
  }
  const RECT r = placement.rcNormalPosition;
  HMONITOR monitor = ::MonitorFromWindow(opener, MONITOR_DEFAULTTONEAREST);
  const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  const LONG step = static_cast<LONG>(32 * scale);
  const LONG width = r.right - r.left;
  const LONG height = r.bottom - r.top;
  LONG left = r.left + step;
  LONG top = r.top + step;
  // Back to the screen's corner rather than past its edge.
  MONITORINFO info = {sizeof(info)};
  if (::GetMonitorInfoW(monitor, &info) &&
      (left + width > info.rcWork.right || top + height > info.rcWork.bottom)) {
    left = info.rcWork.left + step;
    top = info.rcWork.top + step;
  }
  if (left < 0 || top < 0 || width <= 0 || height <= 0) {
    return;  // A screen left of or above the main one: keep the default.
  }
  origin->x = static_cast<unsigned int>(left / scale);
  origin->y = static_cast<unsigned int>(top / scale);
  size->width = static_cast<unsigned int>(width / scale);
  size->height = static_cast<unsigned int>(height / scale);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
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
  CascadeFromOpener(&origin, &size);
  if (!window.Create(L"Explorer", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Out of sight while the engine and the plugins shut down, which takes
  // a few seconds.
  ::ShowWindow(window.GetHandle(), SW_HIDE);
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
