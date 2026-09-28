import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/widgets/player_shortcuts.dart';

/// 把 PlayerShortcuts 挂起来。
///
/// 传 null 播放器 —— 测试环境里建不出真的 VideoPlayerController，
/// 而且 ESC / 焦点 / 不崩 这些行为本来就不依赖播放器。
Future<void> _pump(
  WidgetTester tester, {
  bool fullscreen = false,
  VoidCallback? onExitFullscreen,
  ValueChanged<double>? onVolumeChanged,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PlayerShortcuts(
          player: () => null,
          volume: 0.5,
          onVolumeChanged: onVolumeChanged ?? (_) {},
          fullscreen: fullscreen,
          onExitFullscreen: onExitFullscreen,
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );

  await tester.pump();
}

void main() {
  group('播放器快捷键', () {
    testWidgets('正常显示内容', (WidgetTester tester) async {
      await _pump(tester);

      expect(find.byType(PlayerShortcuts), findsOneWidget);
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('全屏下按 ESC 会退出全屏', (WidgetTester tester) async {
      var exited = 0;

      await _pump(
        tester,
        fullscreen: true,
        onExitFullscreen: () => exited++,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(exited, 1, reason: 'ESC 应该触发退出全屏');
    });

    testWidgets('非全屏时按 ESC 不做事', (WidgetTester tester) async {
      var exited = 0;

      await _pump(
        tester,
        fullscreen: false,
        onExitFullscreen: null,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(exited, 0);
    });

    testWidgets('没有播放器时按各种键都不崩', (WidgetTester tester) async {
      await _pump(tester);

      for (final key in [
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pump();
      }

      // 走到这里没抛异常就算通过
      expect(find.byType(PlayerShortcuts), findsOneWidget);
    });

    testWidgets('会自动拿到焦点（不然快捷键不生效）',
        (WidgetTester tester) async {
      await _pump(tester);

      // MaterialApp / Navigator 内部也有 autofocus 的 Focus，
      // 所以按 debugLabel 认准自己那一个
      final focus = tester.widget<Focus>(
        find.byWidgetPredicate(
          (w) => w is Focus && w.focusNode?.debugLabel == 'player-shortcuts',
        ),
      );

      expect(
        focus.focusNode?.hasPrimaryFocus,
        isTrue,
        reason: '没有焦点的话键盘事件根本不会送到播放器',
      );
    });

    testWidgets('本组件自己不画任何浮层（提示交给页面放进播放器里）',
        (WidgetTester tester) async {
      var volume = 0.5;

      await _pump(tester, onVolumeChanged: (v) => volume = v);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();

      // 音量值报出去了
      expect(volume, closeTo(0.55, 0.001));

      // 但提示不该由它来画 —— 它包的是整页，画在这里会落在整页正中，
      // 窗口化时跟播放器对不上（用户报过这个问题）
      expect(find.byType(VolumeToast), findsNothing);
    });
  });

  group('音量提示（由页面放进播放器 Stack 里）', () {
    testWidgets('显示当前音量百分比和对应图标',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: VolumeToast(volume: 0.55))),
        ),
      );

      expect(find.text('55%'), findsOneWidget);
      expect(find.byIcon(Icons.volume_up), findsOneWidget);
    });

    testWidgets('静音和低音量用不同图标', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: VolumeToast(volume: 0.0))),
        ),
      );

      expect(find.byIcon(Icons.volume_off), findsOneWidget);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: VolumeToast(volume: 0.2))),
        ),
      );

      expect(find.byIcon(Icons.volume_down), findsOneWidget);
    });

    testWidgets('放在播放器 Stack 里会居中，且随宽度缩放',
        (WidgetTester tester) async {
      Future<Size> pumpAt(double width) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  height: width * 9 / 16,
                  child: Stack(
                    fit: StackFit.expand,
                    children: const [
                      ColoredBox(color: Colors.black),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Center(child: VolumeToast(volume: 0.6)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.pump();

        return tester.getSize(find.byType(VolumeToast));
      }

      final small = await pumpAt(600);
      final large = await pumpAt(1800);

      // 关键：提示跟着播放器走，不是跟着整页
      final smallCenter = tester.getCenter(find.byType(VolumeToast));

      expect(small.width, lessThan(400), reason: '小窗口下别太占地方');
      expect(
        large.width,
        greaterThan(small.width),
        reason: '播放器变大时提示也该跟着变大',
      );

      // 居中于播放器
      expect(smallCenter.dx, closeTo(400, 1));
    });
  });

  group('VolumeToastController', () {
    test('show 之后可见，过一会儿自动隐藏', () {
      fakeAsync((async) {
        final controller = VolumeToastController();

        expect(controller.visible, isFalse);

        controller.show(0.4);
        expect(controller.visible, isTrue);
        expect(controller.volume, 0.4);

        async.elapse(const Duration(milliseconds: 1200));

        expect(controller.visible, isFalse);

        controller.dispose();
      });
    });

    test('连续 show 会重置计时，不会提前消失', () {
      fakeAsync((async) {
        final controller = VolumeToastController();

        controller.show(0.4);
        async.elapse(const Duration(milliseconds: 600));

        controller.show(0.5);
        async.elapse(const Duration(milliseconds: 600));

        expect(controller.visible, isTrue, reason: '第二次 show 应该重新计时');

        async.elapse(const Duration(milliseconds: 600));
        expect(controller.visible, isFalse);

        controller.dispose();
      });
    });
  });
}
