import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/widgets/video_card.dart';

void main() {
  group('横版视频卡片尺寸（统一到首页那套）', () {
    test('列数随宽度变化', () {
      expect(videoCardColumns(1700), 6);
      expect(videoCardColumns(1400), 5);
      expect(videoCardColumns(1100), 4);
      expect(videoCardColumns(900), 3);
      expect(videoCardColumns(600), 2);
      expect(videoCardColumns(400), 1);
    });

    test('卡片宽度 = 去掉留白和间距后按列均分', () {
      const width = 1200.0;
      final m = videoCardMetrics(maxWidth: width, horizontalPadding: 48);

      expect(m.columns, 4);

      final expectedWidth = (width - 48 - 16 * (m.columns - 1)) / m.columns;

      expect(m.itemWidth, closeTo(expectedWidth, 0.01));
    });

    test('卡片高度 = 缩略图高度 + 文字区', () {
      final m = videoCardMetrics(maxWidth: 1200, horizontalPadding: 48);

      expect(
        m.itemHeight,
        closeTo(m.itemWidth * 9 / 16 + 74, 0.01),
      );
    });

    test('留白在父容器上时算出来的卡片一样大', () {
      // 首页：自己带 24 的横向留白，拿到的是整个宽度
      // 搜索结果：父容器已经有 24 的留白，自己留白为 0
      // 两种情况卡片必须一样大 —— 这正是以前不一致的地方。
      for (final width in [400.0, 600.0, 900.0, 1100.0, 1400.0, 1700.0]) {
        final home = videoCardMetrics(
          maxWidth: width,
          horizontalPadding: 48,
        );

        final nested = videoCardMetrics(
          maxWidth: width - 48,
          horizontalPadding: 0,
        );

        expect(
          nested.columns,
          home.columns,
          reason: '宽度 $width 时列数应该一样',
        );

        expect(
          nested.itemWidth,
          closeTo(home.itemWidth, 0.01),
          reason: '宽度 $width 时卡片宽度应该一样',
        );

        expect(
          nested.itemHeight,
          closeTo(home.itemHeight, 0.01),
          reason: '宽度 $width 时卡片高度应该一样',
        );
      }
    });

    test('竖版栏目保持自己那套，不跟着横版变', () {
      final portrait = videoCardMetrics(
        maxWidth: 1700,
        horizontalPadding: 48,
        portrait: true,
      );

      expect(portrait.columns, 8);
      expect(videoCardColumns(1700), 6);
    });
  });

  group('VideoCard', () {
    testWidgets('显示标题和一行信息', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 260,
              child: VideoCard(
                title: '测试影片',
                thumbnail: '',
                duration: '24:00',
                rating: '4.5',
                onTap: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('测试影片'), findsOneWidget);
      expect(find.text('24:00 · 4.5'), findsOneWidget);
    });

    testWidgets('点击会回调', (WidgetTester tester) async {
      var tapped = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 260,
              child: VideoCard(
                title: '测试影片',
                thumbnail: '',
                onTap: () => tapped++,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('测试影片'));
      await tester.pump();

      expect(tapped, 1);
    });
  });
}
