import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/main.dart';
import 'package:frontend/new_release_page.dart';

void main() {
  group('相关影片卡片比例（需求7）', () {
    testWidgets('竖版封面按自己的比例渲染，不被裁成横版', (tester) async {
      // 后端量出来的真实尺寸：268x394 → 0.68
      final video = <String, dynamic>{
        'video_id': '1',
        'title': '竖版封面的影片',
        'url': 'https://hanime1.me/watch?v=1',
        'thumbnail': '',
        'thumb_ratio': 0.6802,
        'thumb_orientation': 'portrait',
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 400,
                child: RelatedVideoCard(video: video, onTap: () {}),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final ratios = tester
          .widgetList<AspectRatio>(find.byType(AspectRatio))
          .map((a) => a.aspectRatio)
          .toList();

      expect(ratios, isNotEmpty);

      expect(
        ratios.any((r) => (r - 0.6802).abs() < 0.01),
        isTrue,
        reason: '竖版封面应该按 0.68 渲染，实际：$ratios',
      );
    });

    testWidgets('没有尺寸信息时退回 16:9', (tester) async {
      final video = <String, dynamic>{
        'video_id': '2',
        'title': '没有尺寸信息',
        'url': 'https://hanime1.me/watch?v=2',
        'thumbnail': '',
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 400,
                child: RelatedVideoCard(video: video, onTap: () {}),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final ratios = tester
          .widgetList<AspectRatio>(find.byType(AspectRatio))
          .map((a) => a.aspectRatio)
          .toList();

      expect(
        ratios.any((r) => (r - 16 / 9).abs() < 0.01),
        isTrue,
        reason: '缺尺寸时应退回 16:9，实际：$ratios',
      );
    });
  });

  group('影片信息图标（需求9）', () {
    testWidgets('播放量用圆角矩形+居中三角，点赞用大拇指', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                InfoChip(kind: InfoChipKind.play, text: '188.2万次'),
                InfoChip(kind: InfoChipKind.like, text: '99%'),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('188.2万次'), findsOneWidget);
      expect(find.text('99%'), findsOneWidget);

      // 播放量：内部有一个播放三角
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      // 点赞：竖大拇指
      expect(find.byIcon(Icons.thumb_up_alt_outlined), findsOneWidget);
    });
  });

  group('缩略图尺寸', () {
    testWidgets('列表卡片缩略图固定 16:9（不随卡片高度变化）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: VideoGridCard(
                  title: '一段比较长的标题会换行两行来测试布局是否还被撑开',
                  thumbnail: '',
                  duration: '20:40',
                  views: '188 万次',
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final ratios = tester
          .widgetList<AspectRatio>(find.byType(AspectRatio))
          .map((a) => a.aspectRatio)
          .toList();

      expect(ratios, isNotEmpty, reason: '缩略图应该用 AspectRatio 约束');

      expect(
        ratios.any((r) => (r - 16 / 9).abs() < 0.01),
        isTrue,
        reason: '缩略图应该保持 16:9，实际比例：$ratios',
      );
    });
  });
}
