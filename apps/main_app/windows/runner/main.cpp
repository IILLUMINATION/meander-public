#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shellapi.h>
#include <shlobj.h>
#include <windows.h>
#include <string>

#include "flutter_window.h"
#include "resource.h"
#include "utils.h"

namespace {

constexpr wchar_t kMeanderProgId[] = L"Meander.mndfile";

bool SetRegistryDefaultString(HKEY root, const wchar_t* sub_key,
                              const std::wstring& value) {
  HKEY key = nullptr;
  if (::RegCreateKeyExW(root, sub_key, 0, nullptr, 0, KEY_SET_VALUE, nullptr,
                        &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const auto* raw = reinterpret_cast<const BYTE*>(value.c_str());
  const DWORD size =
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  const LONG result =
      ::RegSetValueExW(key, nullptr, 0, REG_SZ, raw, size);
  ::RegCloseKey(key);
  return result == ERROR_SUCCESS;
}

void RegisterMndFileAssociation() {
  wchar_t exe_path[MAX_PATH];
  if (::GetModuleFileNameW(nullptr, exe_path, MAX_PATH) == 0) {
    return;
  }

  const std::wstring open_command =
      std::wstring(L"\"") + exe_path + L"\" \"%1\"";
  // Значок документа берётся из своего ресурса (IDI_MND_ICON), а не из
  // иконки приложения: `.mnd` в проводнике должен выглядеть как файл
  // Meander. Отрицательный индекс — это номер ресурса, а не позиция.
  const std::wstring default_icon =
      std::wstring(exe_path) + L"," + L"-" + std::to_wstring(IDI_MND_ICON);

  bool ok = true;
  ok &= SetRegistryDefaultString(HKEY_CURRENT_USER, L"Software\\Classes\\.mnd",
                                 kMeanderProgId);
  ok &= SetRegistryDefaultString(HKEY_CURRENT_USER,
                                 L"Software\\Classes\\Meander.mndfile",
                                 L"Meander Quest File");
  ok &= SetRegistryDefaultString(
      HKEY_CURRENT_USER,
      L"Software\\Classes\\Meander.mndfile\\DefaultIcon",
      default_icon);
  ok &= SetRegistryDefaultString(
      HKEY_CURRENT_USER,
      L"Software\\Classes\\Meander.mndfile\\shell\\open\\command",
      open_command);

  if (ok) {
    ::SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
  }
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
  RegisterMndFileAssociation();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"canvas_app", origin, size)) {
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
