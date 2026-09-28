import 'dart:async';

import 'package:flutter/material.dart';

/// 悬浮提示（Toast）。
///
/// 为什么不直接用 SnackBar：SnackBar 会贴在窗口底部形成一条横幅，
/// 还会挤占布局空间。这里改成**浮在内容上方**的圆角提示条，
/// 淡入淡出、不改变任何布局。
///
/// 用法：`AppToast.show(context, '登录成功');`
class AppToast {
  AppToast._();

  /// 同一时间只保留一个提示，新的会顶掉旧的
  static OverlayEntry? _entry;
  static Timer? _timer;

  static void show(
    BuildContext context,
    String message, {
    ToastKind kind = ToastKind.info,
    Duration duration = const Duration(seconds: 2),
  }) {
    final overlay = Overlay.maybeOf(context);

    if (overlay == null || message.isEmpty) return;

    // 先清掉上一个
    dismiss();

    final entry = OverlayEntry(
      builder: (context) => _ToastView(
        message: message,
        kind: kind,
      ),
    );

    _entry = entry;
    overlay.insert(entry);

    _timer = Timer(duration, dismiss);
  }

  static void success(BuildContext context, String message) =>
      show(context, message, kind: ToastKind.success);

  static void error(BuildContext context, String message) =>
      show(context, message, kind: ToastKind.error, duration: const Duration(seconds: 3));

  static void dismiss() {
    _timer?.cancel();
    _timer = null;

    _entry?.remove();
    _entry = null;
  }
}

enum ToastKind { info, success, error }

class _ToastView extends StatefulWidget {
  final String message;
  final ToastKind kind;

  const _ToastView({required this.message, required this.kind});

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final (IconData icon, Color tint) = switch (widget.kind) {
      ToastKind.success => (Icons.check_circle_outline, Colors.green),
      ToastKind.error => (Icons.error_outline, theme.colorScheme.error),
      ToastKind.info => (Icons.info_outline, theme.colorScheme.primary),
    };

    return Positioned(
      left: 0,
      right: 0,
      // 浮在底部稍上一点的位置，不贴边
      bottom: 48,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _controller,
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF32343A)
                      : const Color(0xFF3C4048),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 18, color: tint),
                    const SizedBox(width: 9),
                    Flexible(
                      child: Text(
                        widget.message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
