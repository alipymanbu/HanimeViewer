import 'package:flutter/material.dart';

import '../controllers/app_window.dart';

/// 自绘标题栏。
///
/// 窗口是无边框的（`windowManager.setAsFrameless()`），系统不再画标题栏，
/// 所以拖动、双击最大化、三个窗口按钮都得自己来。
///
/// **它是「透明地浮在应用上面」的一条**，不是一条独立颜色的横杠：
/// - 不画背景、不画分隔线 —— 底下的应用背景（以及左侧侧边栏）直接透上来；
/// - 不显示程序名和图标 —— 那些交给侧边栏；
/// - 只保留两样东西：中间一大片拖动区 + 右边的窗口按钮。
///
/// 因为浮在最上层，它盖住的 38px 里可能正好有页面自己的按钮
/// （详情页的返回、个人主页的返回…）。所以拖动区用 `translucent`——
/// 点击会**穿过去**，页面不需要为它让位。
///
/// 但**双击最大化不能用 `GestureDetector.onDoubleTap`**：
/// 那个识别器会占住手势竞技场，把下面的按钮的点击一起吞掉
/// （实测：translucent + onDoubleTap 时下层按钮点不到，
/// 去掉 onDoubleTap 就点得到）。所以双击是自己用 `Listener` 数的。
class CustomTitleBar extends StatefulWidget {
  const CustomTitleBar({super.key});

  @override
  State<CustomTitleBar> createState() => _CustomTitleBarState();
}

class _CustomTitleBarState extends State<CustomTitleBar> {
  /// 上一次按下的时间和位置，用来自己判断双击
  DateTime? _lastDownAt;
  Offset? _lastDownPos;

  /// 两次按下间隔小于这个就算双击（和系统默认差不多）
  static const Duration _doubleClickGap = Duration(milliseconds: 400);

  /// 两次按下位置差小于这个才算同一处
  static const double _doubleClickSlop = 8;

  void _handlePointerDown(PointerDownEvent event) {
    final now = DateTime.now();
    final pos = event.position;

    final previous = _lastDownAt;
    final previousPos = _lastDownPos;

    final isDoubleClick = previous != null &&
        previousPos != null &&
        now.difference(previous) < _doubleClickGap &&
        (pos - previousPos).distance < _doubleClickSlop;

    if (isDoubleClick) {
      _lastDownAt = null;
      _lastDownPos = null;

      AppWindow.toggleMaximize();

      return;
    }

    _lastDownAt = now;
    _lastDownPos = pos;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // ---- 拖动区：除按钮以外的整条 ----
        //
        // 用 **translucent** 而不是 opaque：opaque 会把这一条变成
        // "点击黑洞"，压在它下面的页面按钮（详情页 AppBar 的返回等）
        // 就都点不到了。
        //
        // translucent 下这两个都仍然收得到指针事件（能拖窗口、
        // 能数双击），但 hitTest 返回 false，所以下层内容**也**收得到 ——
        // 拖动 / 双击 / 点页面按钮互不干扰。
        Expanded(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _handlePointerDown,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => AppWindow.startDragging(),
              child: const SizedBox.expand(),
            ),
          ),
        ),

        // ---- 窗口按钮 ----
        ValueListenableBuilder<bool>(
          valueListenable: AppWindow.maximized,
          builder: (context, maximized, _) => Row(
            children: [
              _WindowButton(
                icon: Icons.remove,
                onTap: AppWindow.minimize,
              ),
              _WindowButton(
                icon: maximized ? Icons.filter_none : Icons.crop_square,
                iconSize: maximized ? 13 : 15,
                onTap: AppWindow.toggleMaximize,
              ),
              _WindowButton(
                icon: Icons.close,
                isClose: true,
                onTap: AppWindow.close,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 标题栏上的一个窗口按钮
///
/// **刻意不用 `Tooltip`**：标题栏在 `MaterialApp.builder` 里，也就是在
/// Navigator **外面** —— 那里没有 `Overlay` 祖先，而 `Tooltip` 弹提示时
/// 要去 `Overlay.of(context)`。悬停超过 waitDuration 就会抛异常，
/// release 下整个标题栏会被换成一块灰盒子（用户看到的就是
/// "鼠标一悬停标题栏就蒙了一层灰、按钮也不对了"）。
/// 三个按钮本来就是通用的窗口符号，不需要文字提示。
class _WindowButton extends StatefulWidget {
  final IconData icon;
  final double iconSize;

  /// 关闭按钮：悬停时变红（和系统一致）
  final bool isClose;

  final VoidCallback onTap;

  const _WindowButton({
    required this.icon,
    required this.onTap,
    this.iconSize = 15,
    this.isClose = false,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Color background = Colors.transparent;

    if (_hovering) {
      if (widget.isClose) {
        background = const Color(0xFFE81123);
      } else {
        // 背景是透的，悬停底色要跟着主题走，不然深色下看不见
        background = isDark ? Colors.white24 : Colors.black12;
      }
    }

    final iconColor = _hovering && widget.isClose
        ? Colors.white
        : theme.colorScheme.onSurface.withValues(alpha: 0.8);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: AppWindow.titleBarHeight,
          color: background,
          alignment: Alignment.center,
          child: Icon(widget.icon, size: widget.iconSize, color: iconColor),
        ),
      ),
    );
  }
}
