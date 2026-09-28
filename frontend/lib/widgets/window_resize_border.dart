import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../controllers/app_window.dart';

/// 给无边框窗口补上「拖边框改大小」的热区。
///
/// 无边框之后系统不再提供可拖的边框，所以要在窗口四边和四角各盖一条
/// 透明的热区。按下时调 `windowManager.startResizing(edge)`，
/// 它内部走的是原生 `WM_NCLBUTTONDOWN / HT*` —— 所以拖起来跟系统窗口
/// 一模一样（有最小尺寸限制、有边界吸附），不是自己算的。
///
/// 布局用 Stack 盖在内容上面：热区只有几像素宽，压不到正常控件。
class WindowResizeBorder extends StatelessWidget {
  final Widget child;

  const WindowResizeBorder({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppWindow.fullscreen,
      builder: (context, fullscreen, _) {
        // 全屏时没有边框可拖，也别让热区挡住画面边缘
        if (fullscreen) return child;

        const t = AppWindow.resizeBorderWidth;
        const c = AppWindow.resizeCornerSize;

        return Stack(
          children: [
            Positioned.fill(child: child),

            // ---- 四条边 ----
            Positioned(
              left: c,
              right: c,
              top: 0,
              height: t,
              child: _handle(ResizeEdge.top, SystemMouseCursors.resizeUp),
            ),
            Positioned(
              left: c,
              right: c,
              bottom: 0,
              height: t,
              child:
                  _handle(ResizeEdge.bottom, SystemMouseCursors.resizeDown),
            ),
            Positioned(
              top: c,
              bottom: c,
              left: 0,
              width: t,
              child: _handle(ResizeEdge.left, SystemMouseCursors.resizeLeft),
            ),
            Positioned(
              top: c,
              bottom: c,
              right: 0,
              width: t,
              child: _handle(ResizeEdge.right, SystemMouseCursors.resizeRight),
            ),

            // ---- 四个角 ----
            Positioned(
              left: 0,
              top: 0,
              width: c,
              height: c,
              child: _handle(
                ResizeEdge.topLeft,
                SystemMouseCursors.resizeUpLeft,
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              width: c,
              height: c,
              child: _handle(
                ResizeEdge.topRight,
                SystemMouseCursors.resizeUpRight,
              ),
            ),
            Positioned(
              left: 0,
              bottom: 0,
              width: c,
              height: c,
              child: _handle(
                ResizeEdge.bottomLeft,
                SystemMouseCursors.resizeDownLeft,
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              width: c,
              height: c,
              child: _handle(
                ResizeEdge.bottomRight,
                SystemMouseCursors.resizeDownRight,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _handle(ResizeEdge edge, MouseCursor cursor) {
    return MouseRegion(
      cursor: cursor,
      child: GestureDetector(
        // opaque：这里没有子控件，不设的话点不到
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => AppWindow.startResizing(edge),
        child: const SizedBox.expand(),
      ),
    );
  }
}
