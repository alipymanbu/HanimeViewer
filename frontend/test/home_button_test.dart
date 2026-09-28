import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/controllers/home_request.dart';
import 'package:frontend/main.dart';

void main() {
  group('回到首页（HomeRequest）', () {
    test('go 会通知监听者', () {
      var notified = 0;

      void listener() => notified++;

      HomeRequest.requests.addListener(listener);
      addTearDown(() => HomeRequest.requests.removeListener(listener));

      HomeRequest.go();
      HomeRequest.go();

      expect(notified, 2);
    });
  });

  group('影片详情页左上角', () {
    testWidgets('返回按钮右边有「回到首页」', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VideoDetailPage(videoId: '1')),
      );

      // 只要一帧：详情接口在测试里会失败，但 AppBar 一定会渲染
      await tester.pump();

      // 两个按钮都在
      expect(
        find.byIcon(Icons.arrow_back),
        findsOneWidget,
        reason: '应该有返回按钮',
      );

      expect(
        find.byIcon(Icons.home_outlined),
        findsOneWidget,
        reason: '返回按钮右边应该有「回到首页」',
      );

      // 「回到首页」在返回按钮的右边
      final backX = tester.getCenter(find.byIcon(Icons.arrow_back)).dx;
      final homeX = tester.getCenter(find.byIcon(Icons.home_outlined)).dx;

      expect(
        homeX,
        greaterThan(backX),
        reason: '「回到首页」应该在返回按钮右侧',
      );

      // 点它会发出「回到首页」请求
      var requested = 0;

      void listener() => requested++;

      HomeRequest.requests.addListener(listener);
      addTearDown(() => HomeRequest.requests.removeListener(listener));

      await tester.tap(find.byIcon(Icons.home_outlined));
      await tester.pump();

      expect(requested, 1, reason: '点一下应该发出一次回到首页请求');
    });
  });
}
