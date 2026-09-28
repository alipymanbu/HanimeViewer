import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/widgets/hanime_logo.dart';

/// 把图标画出来，返回像素访问器 + H 的包围盒。
///
/// 有些问题（比如"横杠两端比竖笔鼓出来一点"）只有真的看像素才发现得了，
/// widget 树层面完全正常，所以这里直接读渲染结果。
Future<({ByteData bytes, int width, int height, Rect bbox})> _render(
  WidgetTester tester, {
  double height = 80,
}) async {
  final key = GlobalKey();

  // 固定 1.0：不然边缘会落在整数物理像素上，抗锯齿根本不出现，
  // 下面那条"齐平"的回归测试就永远是绿的（踩过这个坑）。
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: const Color(0xFF151218),
          child: Center(child: HanimeLogo(height: height)),
        ),
      ),
    ),
  );

  await tester.pumpAndSettle();

  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;

  late ByteData bytes;
  late int width;
  late int height_;

  await tester.runAsync(() async {
    final image = await boundary.toImage();
    width = image.width;
    height_ = image.height;
    bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  });

  int red(int x, int y) => bytes.getUint8((y * width + x) * 4);
  int green(int x, int y) => bytes.getUint8((y * width + x) * 4 + 1);

  // 找红色像素的范围
  int minX = 1 << 30, maxX = -1, minY = 1 << 30, maxY = -1;

  for (var y = 0; y < height_; y++) {
    for (var x = 0; x < width; x++) {
      final rr = red(x, y);

      if (rr > 100 && rr - green(x, y) > 40) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }

  return (
    bytes: bytes,
    width: width,
    height: height_,
    bbox: Rect.fromLTRB(
      minX.toDouble(),
      minY.toDouble(),
      maxX.toDouble(),
      maxY.toDouble(),
    ),
  );
}

void main() {
  group('HanimeViewer 图标', () {
    testWidgets('是画出来的，不是贴图片', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: HanimeLogo(height: 80))),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(HanimeLogo),
          matching: find.byType(CustomPaint),
        ),
        findsWidgets,
      );

      expect(
        find.descendant(
          of: find.byType(HanimeLogo),
          matching: find.byType(Image),
        ),
        findsNothing,
        reason: '不能用位图（原图只有 33x38，放大会糊）',
      );
    });

    testWidgets('默认不带底，只有红色的 H', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: HanimeLogo(height: 62))),
        ),
      );

      final size = tester.getSize(find.byType(HanimeLogo));

      expect(size.height, 62);
      expect(size.width, closeTo(62 * HanimeLogo.glyphAspectRatio, 0.01));
      expect(HanimeLogo.glyphAspectRatio, closeTo(13 / 31, 0.0001));
    });

    testWidgets('带底时用原图的宽高比（33:38）', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: HanimeLogo(height: 38, withBackground: true),
            ),
          ),
        ),
      );

      final size = tester.getSize(find.byType(HanimeLogo));

      expect(size.height, 38);
      expect(size.width, closeTo(38 * HanimeLogo.plateAspectRatio, 0.01));
      expect(HanimeLogo.plateAspectRatio, closeTo(33 / 38, 0.0001));
    });

    testWidgets('横杠两端和竖笔**齐平**（不会鼓出来一截）',
        (WidgetTester tester) async {
      // 回归测试：以前三个矩形是分三次 drawRect 画的，
      // 竖笔和横杠在两端重叠，重叠处的抗锯齿边缘像素被合成两次
      // （alpha = 1-(1-a)² > a），横杠两端就比竖笔更"实"，
      // 看起来像横杠凸出来。现在合成一条路径只填一次。
      final result = await _render(tester);
      final bbox = result.bbox;

      int red(int x, int y) => result.bytes.getUint8((y * result.width + x) * 4);

      final top = bbox.top.toInt();
      final bottom = bbox.bottom.toInt();
      final left = bbox.left.toInt();
      final right = bbox.right.toInt();

      // 靠顶部的一行肯定在竖笔上；正中间那行在横杠上
      final stemRow = top + 3;
      final barRow = (top + bottom) ~/ 2;

      // bbox 最外那一列是"整个图形最靠外的地方"。
      // 如果横杠比竖笔宽，那么这一列在竖笔那一行就会是背景色。
      expect(
        red(left, stemRow),
        greaterThan(100),
        reason: '最左那一列在竖笔行不是红的 —— 说明横杠鼓到竖笔左边去了',
      );

      expect(
        red(right, stemRow),
        greaterThan(100),
        reason: '最右那一列在竖笔行不是红的 —— 说明横杠鼓到竖笔右边去了',
      );

      // 更直接一条：同一个 x，竖笔行和横杠行的颜色必须一样
      // （以前分三次 drawRect，重叠处的抗锯齿被叠加两次，横杠行明显更实）
      expect(
        red(left, barRow),
        red(left, stemRow),
        reason: '横杠左端和竖笔在同一列深浅不一致（抗锯齿叠加的鼓包）',
      );

      expect(
        red(right, barRow),
        red(right, stemRow),
        reason: '横杠右端和竖笔在同一列深浅不一致',
      );
    });

    testWidgets('界面里用到的尺寸都能正常渲染', (WidgetTester tester) async {
      for (final height in [22.0, 30.0, 62.0, 80.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: Center(child: HanimeLogo(height: height))),
          ),
        );

        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(HanimeLogo)).height, height);
      }
    });

    testWidgets('侧边栏里的位置和尺寸（用户标注过的那块）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 88,
              height: 600,
              child: Stack(
                fit: StackFit.expand,
                children: const [
                  ColoredBox(color: Color(0xFF151218)),
                  SidebarLogo(),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      final rect = tester.getRect(find.byType(HanimeLogo));

      expect(rect.height, SidebarLogo.size, reason: '要完整画出来，不能被裁一半');
      expect(rect.top, SidebarLogo.top);
      expect(rect.center.dx, closeTo(44, 0.5), reason: '在 88 宽的侧边栏里横向居中');
      expect(rect.center.dy, greaterThan(38), reason: '要比标题栏那一条低');
      expect(
        rect.bottom,
        lessThanOrEqualTo(SidebarLogo.reservedHeight),
        reason: '导航从 reservedHeight 开始，图标不能越过它，否则第一项会被压住',
      );
    });

    testWidgets('侧边栏图标要让点击穿过去', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 88,
              height: 600,
              child: Stack(
                fit: StackFit.expand,
                children: const [
                  ColoredBox(color: Color(0xFF151218)),
                  SidebarLogo(),
                ],
              ),
            ),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(SidebarLogo),
          matching: find.byType(IgnorePointer),
        ),
        findsOneWidget,
      );
    });
  });
}
