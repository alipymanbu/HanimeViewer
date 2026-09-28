import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

/// 播放器快捷键（内嵌播放器和全屏播放器共用一套行为）。
///
/// 空格        播放 / 暂停
/// ESC         退出全屏（非全屏时不处理）
/// ↑ / ↓       音量 +-（步长见 [AppSettings.volumeStep]）
/// ← / →       快退 / 快进（步长见 [AppSettings.seekStep]）
/// 长按 →      倍速播放，松手恢复
///
/// **只有调音量时会在播放器正中显示一下当前音量**，其余操作不显示任何东西。
/// 音量是唯一"看不见"的操作（画面和进度条都没变化），不给反馈会让人不确定
/// 按到没有；快进/倍速/暂停都能从画面上直接看出来。
///
/// 注意：本组件**自己不画那个提示**，只负责把音量变化通过
/// [onVolumeChanged] 报出去。提示必须画在**播放器自己的 Stack 里** ——
/// 之前画在这里，而详情页的这个组件包的是整页（播放器 + 操作条 + 简介 +
/// 相关影片），于是提示落在整页正中，窗口化时跟播放器对不上。
///
/// 为什么包一层 Focus：
/// Flutter 的键盘事件只发给「当前有焦点」的节点。不主动拿焦点的话，
/// 用户得先点一下播放器才有反应 —— 那不是快捷键该有的手感。
/// 所以这里 autofocus，并且在用户点击画面时把焦点抢回来。
class PlayerShortcuts extends StatefulWidget {
  final Widget child;

  /// 当前播放器。
  ///
  /// 特意用回调取而不是直接传对象 —— 切画质时整个 controller
  /// 会被换掉，缓存旧的那个就会对着已经释放的播放器操作。
  final VideoPlayerController? Function() player;

  /// 是否处于全屏（决定 ESC 的行为）
  final bool fullscreen;

  /// 按 ESC 时调用；为空表示不处理 ESC
  final VoidCallback? onExitFullscreen;

  /// 当前音量（0~1）
  final double volume;

  /// 音量变了。
  ///
  /// 注意：**音量已经由本组件设到播放器上了**，
  /// 这里只需要 setState 更新界面显示（以及顺手弹一下提示），
  /// 不用再 setVolume 一次。
  final ValueChanged<double> onVolumeChanged;

  /// 有任何播放操作时调用（用来把隐藏的控件唤出来）
  final VoidCallback? onActivity;

  /// 左右键步长（秒），不传就用设置里的值
  final int? seekStep;

  /// 长按右键的倍速，不传就用设置里的值
  final double? holdSpeed;

  /// 按住多久算长按
  final Duration holdDelay;

  const PlayerShortcuts({
    super.key,
    required this.child,
    required this.player,
    required this.volume,
    required this.onVolumeChanged,
    this.fullscreen = false,
    this.onExitFullscreen,
    this.onActivity,
    this.seekStep,
    this.holdSpeed,
    this.holdDelay = const Duration(milliseconds: 400),
  });

  @override
  State<PlayerShortcuts> createState() => _PlayerShortcutsState();
}

class _PlayerShortcutsState extends State<PlayerShortcuts> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'player-shortcuts');

  /// 正在长按右键（已进入倍速）
  bool _holdingFast = false;
  Timer? _holdTimer;

  /// 倍速前的速度，松手要还原
  double _speedBeforeHold = 1.0;

  @override
  void dispose() {
    _holdTimer?.cancel();
    _focusNode.dispose();

    super.dispose();
  }

  void _togglePlay() {
    final player = widget.player();

    if (player == null || !player.value.isInitialized) return;

    if (player.value.isPlaying) {
      player.pause();
    } else {
      player.play();
    }

    widget.onActivity?.call();
  }

  void _changeVolume(double delta) {
    var next = (widget.volume + delta).clamp(0.0, 1.0);

    // 避开 0.4999 这种浮点误差让显示变成 49%
    next = (next * 100).round() / 100;

    // 播放器可能还没初始化好，但音量状态照样要更新，
    // 否则界面上的音量和实际值会对不上
    widget.player()?.setVolume(next);

    widget.onVolumeChanged(next);
    widget.onActivity?.call();
  }

  void _seek(int seconds) {
    final player = widget.player();

    if (player == null || !player.value.isInitialized) return;

    final duration = player.value.duration;

    var target = player.value.position + Duration(seconds: seconds);

    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;

    player.seekTo(target);
    widget.onActivity?.call();
  }

  void _startFastForward() {
    final player = widget.player();

    if (player == null || !player.value.isInitialized) return;

    if (_holdingFast) return;

    _speedBeforeHold = player.value.playbackSpeed;

    player.setPlaybackSpeed(widget.holdSpeed ?? 2.0);

    _holdingFast = true;
  }

  void _stopFastForward() {
    _holdTimer?.cancel();

    if (!_holdingFast) return;

    _holdingFast = false;

    final player = widget.player();

    if (player != null && player.value.isInitialized) {
      player.setPlaybackSpeed(_speedBeforeHold);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;

    // ---- 空格：播放 / 暂停 ----
    if (key == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) {
        _togglePlay();
      }

      return KeyEventResult.handled;
    }

    // ---- ESC：退出全屏 ----
    if (key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent && widget.onExitFullscreen != null) {
        widget.onExitFullscreen!.call();

        return KeyEventResult.handled;
      }

      return widget.onExitFullscreen == null
          ? KeyEventResult.ignored
          : KeyEventResult.handled;
    }

    // ---- 上下：音量（按住可以连续调）----
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        _changeVolume(key == LogicalKeyboardKey.arrowUp ? 0.05 : -0.05);

        return KeyEventResult.handled;
      }

      return KeyEventResult.handled;
    }

    // ---- 左：快退 ----
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (event is KeyDownEvent) {
        _seek(-(widget.seekStep ?? 10));

        return KeyEventResult.handled;
      }

      return KeyEventResult.handled;
    }

    // ---- 右：快进；长按变倍速 ----
    if (key == LogicalKeyboardKey.arrowRight) {
      if (event is KeyDownEvent) {
        // 先按一下就给一次快进，手感才跟得上；
        // 如果一直按着不放，超过 holdDelay 就转成倍速。
        _seek(widget.seekStep ?? 10);

        _holdTimer?.cancel();
        _holdTimer = Timer(widget.holdDelay, _startFastForward);

        return KeyEventResult.handled;
      }

      if (event is KeyRepeatEvent) {
        // 已经在倍速里就不再叠加快进，否则会一路飞到底
        return KeyEventResult.handled;
      }

      if (event is KeyUpEvent) {
        _stopFastForward();

        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // 这里只做按键分发，提示交给页面画在**播放器自己的 Stack 里**。
    // 画在这里的话，详情页的这个组件包的是整页，提示会落在整页正中，
    // 窗口化时跟播放器对不上（用户报过）。
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Listener(
        // 点一下画面就把焦点抢回来，免得焦点跑到别处后快捷键失灵
        onPointerDown: (_) {
          if (!_focusNode.hasFocus) _focusNode.requestFocus();
        },
        child: widget.child,
      ),
    );
  }
}

/// 音量提示的显示状态。
///
/// 页面持有一个，在 [PlayerShortcuts.onVolumeChanged] 里调 [show]，
/// 然后把 [VolumeToast] 放进**播放器自己的 Stack**。
///
/// 这样提示天然跟着播放器的位置和大小走 —— 窗口化、全屏、
/// 拖动窗口边框都不会跑偏。
class VolumeToastController extends ChangeNotifier {
  double? _volume;
  Timer? _timer;

  /// 当前要显示的音量；null 表示不显示
  double? get volume => _volume;

  bool get visible => _volume != null;

  void show(double value) {
    _timer?.cancel();

    _volume = value;
    notifyListeners();

    _timer = Timer(const Duration(milliseconds: 900), () {
      _volume = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// 音量提示（一个小圆角块）。
///
/// 放进播放器的 Stack 里、用 `Positioned.fill` + `Center` 包住即可；
/// 会按播放器宽度稍微缩放，全屏时不至于显得太小。
class VolumeToast extends StatelessWidget {
  final double volume;

  const VolumeToast({super.key, required this.volume});

  IconData get _icon {
    if (volume <= 0) return Icons.volume_off;
    if (volume < 0.4) return Icons.volume_down;
    return Icons.volume_up;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 跟着播放器大小缩放：小窗口别太占地方，全屏时也别小得像蚂蚁
        final scale = (constraints.maxWidth / 900).clamp(0.85, 1.7);

        final percent = (volume * 100).round();

        return DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(10 * scale),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 18 * scale,
              vertical: 12 * scale,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_icon, color: Colors.white, size: 22 * scale),
                SizedBox(width: 10 * scale),
                Text(
                  '$percent%',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18 * scale,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
