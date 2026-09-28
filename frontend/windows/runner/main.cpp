#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

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
  project.set_ui_thread_policy(flutter::UIThreadPolicy::RunOnSeparateThread);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);

  // Create the window centered on the primary monitor using a default size.
  //
  // The real size is restored from settings on the Dart side (see
  // windowManager.waitUntilReadyToShow in lib/main.dart), but the window is
  // already made visible here, before the Flutter engine runs. Centering it
  // now avoids the window appearing at the top-left corner and then jumping
  // to the middle a moment later.
  //
  // NOTE: keep comments in this file ASCII-only. The runner sources are not
  // compiled with /utf-8, so MSVC reads them using the system code page and
  // non-ASCII bytes can swallow the following line of code.
  const int default_width = 1280;
  const int default_height = 720;
  const int screen_width = ::GetSystemMetrics(SM_CXSCREEN);
  const int screen_height = ::GetSystemMetrics(SM_CYSCREEN);

  Win32Window::Point origin(
      (screen_width > default_width ? screen_width - default_width : 0) / 2,
      (screen_height > default_height ? screen_height - default_height : 0) / 2);
  Win32Window::Size size(default_width, default_height);
  if (!window.Create(L"HanimeViewer", origin, size)) {
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
