#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <optional>

#include "drop_files.h"
#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayId = 1;
constexpr UINT kMenuTasks = 1;
constexpr UINT kMenuOpen = 2;
constexpr UINT kMenuQuit = 3;

std::wstring Utf16(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring out(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      out.data(), length);
  return out;
}

std::wstring Argument(const flutter::EncodableValue* arguments,
                      const char* key) {
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (!map) return std::wstring();
  auto found = map->find(flutter::EncodableValue(key));
  if (found == map->end()) return std::wstring();
  const auto* text = std::get_if<std::string>(&found->second);
  return text ? Utf16(*text) : std::wstring();
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

  tray_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "explorer/tray",
          &flutter::StandardMethodCodec::GetInstance());
  tray_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto& method = call.method_name();
        if (method == "show") {
          ShowTray(Argument(call.arguments(), "tooltip"));
        } else if (method == "hide") {
          HideTray();
        } else if (method == "notify") {
          NotifyTray(Argument(call.arguments(), "title"),
                     Argument(call.arguments(), "text"));
        } else {
          result->NotImplemented();
          return;
        }
        result->Success();
      });

  drop_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "explorer/drop",
          &flutter::StandardMethodCodec::GetInstance());
  drop_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto& method = call.method_name();
        if (method == "wrap") {
          result->Success(flutter::EncodableValue(WrapDropTarget(
              flutter_controller_->view()->GetNativeWindow())));
        } else if (method == "lastFiles") {
          flutter::EncodableList files;
          for (const auto& file : LastDroppedFiles()) {
            files.push_back(flutter::EncodableValue(file));
          }
          result->Success(flutter::EncodableValue(files));
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::ShowTray(const std::wstring& tooltip) {
  NOTIFYICONDATAW data = {sizeof(data)};
  data.hWnd = GetHandle();
  data.uID = kTrayId;
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcsncpy_s(data.szTip, tooltip.c_str(), _TRUNCATE);
  if (tray_visible_) {
    Shell_NotifyIconW(NIM_MODIFY, &data);
    return;
  }
  Shell_NotifyIconW(NIM_ADD, &data);
  data.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &data);
  tray_visible_ = true;
}

void FlutterWindow::HideTray() {
  if (!tray_visible_) return;
  NOTIFYICONDATAW data = {sizeof(data)};
  data.hWnd = GetHandle();
  data.uID = kTrayId;
  Shell_NotifyIconW(NIM_DELETE, &data);
  tray_visible_ = false;
}

void FlutterWindow::NotifyTray(const std::wstring& title,
                               const std::wstring& text) {
  if (!tray_visible_) return;
  NOTIFYICONDATAW data = {sizeof(data)};
  data.hWnd = GetHandle();
  data.uID = kTrayId;
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_INFO;
  wcsncpy_s(data.szInfoTitle, title.c_str(), _TRUNCATE);
  wcsncpy_s(data.szInfo, text.c_str(), _TRUNCATE);
  Shell_NotifyIconW(NIM_MODIFY, &data);
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kMenuTasks, L"Show tasks");
  AppendMenuW(menu, MF_STRING, kMenuOpen, L"Open Folders");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kMenuQuit, L"Quit");
  POINT cursor;
  GetCursorPos(&cursor);
  // The menu closes when clicked elsewhere only if the window is in front.
  SetForegroundWindow(GetHandle());
  UINT chosen = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                               cursor.x, cursor.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
  const char* method = chosen == kMenuTasks  ? "clicked"
                       : chosen == kMenuOpen ? "open"
                       : chosen == kMenuQuit ? "quit"
                                             : nullptr;
  if (method && tray_channel_) tray_channel_->InvokeMethod(method, nullptr);
}

void FlutterWindow::OnDestroy() {
  HideTray();
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
    case kTrayMessage:
      switch (LOWORD(lparam)) {
        case WM_LBUTTONUP:
        case NIN_SELECT:
        case NIN_KEYSELECT:
        case NIN_BALLOONUSERCLICK:
          if (tray_channel_) tray_channel_->InvokeMethod("clicked", nullptr);
          return 0;
        case WM_CONTEXTMENU:
        case WM_RBUTTONUP:
          ShowTrayMenu();
          return 0;
      }
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
