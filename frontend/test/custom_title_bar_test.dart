import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/controllers/app_window.dart';
import 'package:frontend/widgets/custom_title_bar.dart';
import 'package:frontend/widgets/window_resize_border.dart';

/// 标题栏是透明浮层，底下是应用背景 —— 测试里铺一块背景色模拟
Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.teal)),
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: AppWindow.titleBarHeight,
              child: CustomTitleBar(),
            ),
          ],
        ),
      ),
    ),
  );

  await tester.pump();
}

void main() {
  group('自绘标题栏', () {
    setUp(() {
      AppWindow.maximized.value = false;
      AppWindow.fullscreen.value = false;
    });

    testWidgets('只有三个窗口按钮，不再显示程序名和图标',
        (WidgetTester tester) async {
      await _pump(tester);

      expect(find.byIcon(Icons.remove), findsOneWidget);
      expect(find.byIcon(Icons.crop_square), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);

      // 程序名和左上角图标已经去掉了（改由侧边栏承担）
      expect(find.text('HanimeViewer'), findsNothing);
      expect(find.byIcon(Icons.play_circle_fill), findsNothing);
    });

    testWidgets('自己是透明的：不画背景、不画分隔线',
        (WidgetTester tester) async {
      await _pump(tester);

      // 整条里不该出现 Material / DecoratedBox / Container 这类会盖住背景的东西
      // （窗口按钮的悬停底色是 Container，但没悬停时是 transparent）
      final decorations = tester
          .widgetList<DecoratedBox>(find.descendant(
            of: find.byType(CustomTitleBar),
            matching: find.byType(DecoratedBox),
          ))
          .toList();

      expect(decorations, isEmpty, reason: '标题栏不该自己画背景或边框');
    });

    testWidgets('高度是约定的值', (WidgetTester tester) async {
      await _pump(tester);

      final size = tester.getSize(find.byType(CustomTitleBar));

      expect(size.height, AppWindow.titleBarHeight);
    });

    testWidgets('最大化之后按钮变成「向下还原」图标',
        (WidgetTester tester) async {
      await _pump(tester);

      expect(find.byIcon(Icons.crop_square), findsOneWidget);

      AppWindow.maximized.value = true;
      await tester.pump();

      expect(
        find.byIcon(Icons.filter_none),
        findsOneWidget,
        reason: '最大化后应该显示"还原"图标',
      );

      expect(find.byIcon(Icons.crop_square), findsNothing);
    });

    testWidgets('拖动区占满除按钮以外的整条', (WidgetTester tester) async {
      await _pump(tester);

      final dragArea = tester.getSize(
        find.descendant(
          of: find.byType(CustomTitleBar),
          matching: find.byType(GestureDetector),
        ).first,
      );

      final bar = tester.getSize(find.byType(CustomTitleBar));

      // 三个按钮一共 46*3 = 138
      expect(dragArea.width, bar.width - 138);
      expect(dragArea.height, AppWindow.titleBarHeight);
    });

    testWidgets('悬停窗口按钮不会炸（真实结构里标题栏外面没有 Overlay）',
        (WidgetTester tester) async {
      // 这条是回归测试，对应一个真实 bug：
      //
      // 标题栏挂在 MaterialApp.builder 里，也就是 Navigator **外面** ——
      // 那里没有 Overlay 祖先。而 Tooltip 弹提示时要去 Overlay.of(context)，
      // 悬停超过 waitDuration 就抛异常，release 下整个标题栏会被换成一块
      // 灰盒子（用户看到的就是"鼠标一悬停标题栏就蒙了一层灰、按钮也错位"）。
      //
      // 所以这里**故意不给 Overlay**，复刻真实环境。
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 900,
                height: AppWindow.titleBarHeight,
                child: CustomTitleBar(),
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      expect(
        Overlay.maybeOf(tester.element(find.byType(CustomTitleBar))),
        isNull,
        reason: '真实结构里标题栏确实没有 Overlay 祖先',
      );

      // 把鼠标停到关闭按钮上，并等到超过 Tooltip 的 waitDuration
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(tester.getCenter(find.byIcon(Icons.close)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));

      expect(
        tester.takeException(),
        isNull,
        reason: '悬停不该抛异常（Tooltip 会因为没有 Overlay 而炸）',
      );

      // 按钮还在原来的位置，没有被替换成灰盒子
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.remove), findsOneWidget);
    });

    testWidgets('悬停时按钮位置不变（不会"错位"）',
        (WidgetTester tester) async {
      await _pump(tester);

      final closeBefore = tester.getRect(find.byIcon(Icons.close));
      final minBefore = tester.getRect(find.byIcon(Icons.remove));
      final maxBefore = tester.getRect(find.byIcon(Icons.crop_square));

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(tester.getCenter(find.byIcon(Icons.close)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));

      expect(tester.getRect(find.byIcon(Icons.close)), closeBefore);
      expect(tester.getRect(find.byIcon(Icons.remove)), minBefore);
      expect(tester.getRect(find.byIcon(Icons.crop_square)), maxBefore);
    });
  });

  group('标题栏不挡下面的内容', () {
    /// 复刻真实结构：标题栏浮在应用上面，占窗口最顶上那一条。
    /// 下层故意放一个**正好落在这一条里**的按钮
    /// （详情页 AppBar 的返回、个人主页的返回就是这个位置）。
    Future<void> pumpWithButtonUnderBar(
      WidgetTester tester,
      VoidCallback onTap,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 300,
              child: Stack(
                children: [
                  Positioned(
                    left: 8,
                    top: 0,
                    child: TextButton(
                      onPressed: onTap,
                      child: const Text('返回'),
                    ),
                  ),
                  const Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: AppWindow.titleBarHeight,
                    child: CustomTitleBar(),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.pump();
    }

    testWidgets('拖动区下面的按钮仍然点得到', (WidgetTester tester) async {
      // 以前拖动区是 HitTestBehavior.opaque，把标题栏那一条变成了
      // "点击黑洞" —— 页面顶部只要有按钮就点不到。
      // 所以页面只能整体下移 38px 让开，结果每个页面顶上一条空白。
      // 改成 translucent 之后点击穿得过去，页面就能从 y=0 开始了。
      var tapped = false;

      await pumpWithButtonUnderBar(tester, () => tapped = true);

      await tester.tap(find.text('返回'));
      await tester.pump();

      expect(
        tapped,
        isTrue,
        reason: '标题栏的拖动区不能吞掉点击（opaque 就会吞掉）',
      );
    });

    testWidgets('按钮确实压在标题栏那一条里（否则这条测试没意义）',
        (WidgetTester tester) async {
      await pumpWithButtonUnderBar(tester, () {});

      final button = tester.getRect(find.text('返回'));
      final bar = tester.getRect(find.byType(CustomTitleBar));

      expect(
        button.top,
        lessThan(bar.bottom),
        reason: '按钮要真的落在标题栏范围内，不然测不出穿透',
      );
    });
  });

  group('无边框窗口的缩放热区', () {
    setUp(() {
      AppWindow.fullscreen.value = false;
    });

    /// 热区是盖在内容上的 Stack，需要有界约束
    /// （真实运行时它包的是整个窗口，永远是满的）。
    Future<void> pumpBorder(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: WindowResizeBorder(child: SizedBox.expand()),
            ),
          ),
        ),
      );

      await tester.pump();
    }

    testWidgets('四条边 + 四个角一共 8 个热区', (WidgetTester tester) async {
      await pumpBorder(tester);

      final regions = tester.widgetList<MouseRegion>(
        find.descendant(
          of: find.byType(WindowResizeBorder),
          matching: find.byType(MouseRegion),
        ),
      );

      expect(regions.length, 8);
    });

    testWidgets('全屏时热区全部收起来（不然会挡住画面边缘）',
        (WidgetTester tester) async {
      await pumpBorder(tester);

      AppWindow.fullscreen.value = true;
      await tester.pump();

      final regions = tester.widgetList<MouseRegion>(
        find.descendant(
          of: find.byType(WindowResizeBorder),
          matching: find.byType(MouseRegion),
        ),
      );

      expect(regions, isEmpty);
    });
  });
}
