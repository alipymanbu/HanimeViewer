import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/widgets/pager_bar.dart';

void main() {
  group('统一翻页条（需求1）', () {
    testWidgets('只有一页时不显示', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PagerBar(
              page: 1,
              totalPages: 1,
              onGoToPage: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('上一页'), findsNothing);
      expect(find.text('下一页'), findsNothing);
    });

    testWidgets('多页时显示上一页/下一页和页码', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PagerBar(
              page: 2,
              totalPages: 5,
              onGoToPage: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('上一页'), findsOneWidget);
      expect(find.text('下一页'), findsOneWidget);
      expect(find.text('第 2 / 5 页'), findsOneWidget);
    });

    testWidgets('第一页时上一页不可点，最后一页时下一页不可点',
        (WidgetTester tester) async {
      final calls = <int>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PagerBar(
              page: 1,
              totalPages: 3,
              onGoToPage: calls.add,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('上一页'));
      await tester.pump();

      expect(calls, isEmpty, reason: '第一页不该能往前翻');

      await tester.tap(find.text('下一页'));
      await tester.pump();

      expect(calls, [2], reason: '下一页应该请求第 2 页');
    });

    testWidgets('点页码能跳出跳转框并跳到指定页（需求1 的跳页功能）',
        (WidgetTester tester) async {
      final calls = <int>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PagerBar(
              page: 1,
              totalPages: 30,
              onGoToPage: calls.add,
            ),
          ),
        ),
      );
      await tester.pump();

      // 点「第 1 / 30 页」
      await tester.tap(find.text('第 1 / 30 页'));
      await tester.pumpAndSettle();

      expect(find.text('跳转页码'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField), '12');
      await tester.tap(find.text('跳转'));
      await tester.pumpAndSettle();

      expect(calls, [12], reason: '应该跳到第 12 页');
    });

    testWidgets('跳转框会拒绝越界页码', (WidgetTester tester) async {
      final calls = <int>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PagerBar(
              page: 1,
              totalPages: 5,
              onGoToPage: calls.add,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('第 1 / 5 页'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField), '99');
      await tester.tap(find.text('跳转'));
      await tester.pumpAndSettle();

      expect(calls, isEmpty, reason: '越界不应触发翻页');
      expect(find.text('请输入 1~5 之间的页码'), findsOneWidget);
    });
  });
}
