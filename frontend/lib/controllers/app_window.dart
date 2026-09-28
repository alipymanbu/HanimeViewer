import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 窗口状态与操作。
///
/// 现在用的是**无边框窗口 + 自绘标题栏**，所以最小化/最大化/关闭、
/// 拖动、拖边框改大小这些系统本来提供的东西都得自己接上。
///
/// 好消息是 window_manager 底层用的是**原生消息**：
///   - `startDragging()` → `WM_SYSCOMMAND / SC_MOVE|HTCAPTION`
///   - `startResizing()` → `WM_NCLBUTTONDOWN / HT*`
/// 所以 Aero 贴边（拖到屏幕边缘自动分屏）、双击标题栏最大化、
/// 拖着边框改大小这些系统行为都还在，不是自己模拟的。
class AppWindow {
  AppWindow._();

  /// 自绘标题栏的高度
  static const double titleBarHeight = 38;

  /// 标题栏上一个窗口按钮的宽度
  static const double windowButtonWidth = 46;

  /// 右上角三个窗口按钮一共占多宽（最小化 / 最大化 / 关闭）。
  ///
  /// 页面 `AppBar` 的 `actions` 要在最后留出这么多，否则会被窗口按钮压住 ——
  /// 标题栏是浮在最上面的，而且窗口按钮是不透明的
  /// （个人主页的刷新/退出、播放清单详情页的书签都会撞上）。
  static const double windowButtonsWidth = windowButtonWidth * 3;

  /// 拖边框改大小的热区宽度
  static const double resizeBorderWidth = 5;

  /// 四个角的热区边长（比边宽一点，方便抓角）
  static const double resizeCornerSize = 12;

  /// 是否最大化（决定最大化按钮画"最大化"还是"还原"）
  static final ValueNotifier<bool> maximized = ValueNotifier<bool>(false);

  /// 是否全屏（全屏时要把标题栏和边框热区都收起来）
  static final ValueNotifier<bool> fullscreen = ValueNotifier<bool>(false);

  // ---------- 操作 ----------

  static Future<void> minimize() async {
    await windowManager.minimize();
  }

  static Future<void> toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }

    await refresh();
  }

  /// 关闭窗口。
  ///
  /// 走 `close()`（发 WM_CLOSE）而不是 `destroy()` —— 后者只是丢一个
  /// WM_QUIT、窗口并没被销毁，退出会拖好几秒（踩过，见 dev/README）。
  static Future<void> close() async {
    await windowManager.close();
  }

  static Future<void> startDragging() async {
    await windowManager.startDragging();
  }

  static Future<void> startResizing(ResizeEdge edge) async {
    // 最大化状态下拖边框没有意义（Windows 上插件也会直接忽略）
    if (maximized.value) return;

    await windowManager.startResizing(edge);
  }

  /// 重新读一遍窗口状态（最大化事件不一定每次都发得准）
  static Future<void> refresh() async {
    try {
      maximized.value = await windowManager.isMaximized();
      fullscreen.value = await windowManager.isFullScreen();
    } catch (_) {
      // 窗口还没准备好就算了
    }
  }
}

/// 监听窗口事件，把状态同步到 [AppWindow] 的 notifier 上。
///
/// 在 main() 里注册一次：`windowManager.addListener(AppWindowListener())`。
class AppWindowListener with WindowListener {
  @override
  void onWindowMaximize() => AppWindow.maximized.value = true;

  @override
  void onWindowUnmaximize() => AppWindow.maximized.value = false;

  @override
  void onWindowRestore() => AppWindow.refresh();

  @override
  void onWindowEnterFullScreen() => AppWindow.fullscreen.value = true;

  @override
  void onWindowLeaveFullScreen() => AppWindow.fullscreen.value = false;

  /// 拖动/缩放结束时顺手校一次，避免事件漏掉导致按钮图标不对
  @override
  void onWindowResized() => AppWindow.refresh();
}
