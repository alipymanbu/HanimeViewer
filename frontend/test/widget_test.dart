// HanimeViewer 基础测试。
//
// 目标：
// 1. 应用能启动、主界面能构建
// 2. 搜索页的搜索框在任何窗口宽度下都居中
// 3. 主题偏好能保存并读回
//
// 这里刻意不做真实网络请求：页面会在 initState 里请求后端，
// 测试环境里请求会失败，但页面自身有错误处理，不应该让 App 崩掉。
//
// 运行：
//   cd frontend
//   flutter test

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/controllers/account_scope.dart';
import 'package:frontend/controllers/app_cache.dart';
import 'package:frontend/controllers/auth_controller.dart';
import 'package:frontend/controllers/theme_controller.dart';
import 'package:frontend/main.dart';
import 'package:frontend/startup_gate.dart';
import 'package:frontend/utils/format.dart';
import 'package:frontend/utils/user_tabs.dart';

/// 找出搜索框：它是 SearchPage 里唯一一个 labelText 是这个的 TextField。
final _searchField = find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      widget.decoration?.labelText == '主人点击我就能色色了哦',
);

/// 把窗口尺寸设成指定大小。
Future<void> _setWindowSize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;

  addTearDown(tester.view.reset);
}

void main() {
  setUp(() {
    // SharedPreferences 在测试里没有平台实现，必须先塞入假数据。
    SharedPreferences.setMockInitialValues({});

    // 每个测试都从干净缓存开始，避免互相影响
    AppCache.clear();
  });

  // 注意：不要直接 pump HanimeViewerApp。
  // 它的 home 是 StartupGate，会先等后端和调试浏览器就绪才显示主界面，
  // 在测试环境里会一直停在启动页。
  // 这里测的是主界面本身，所以直接 pump MainShell。
  testWidgets('应用可以构建，主界面显示七个导航入口', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MainShell())),
    );
    await tester.pump();

    // 根节点是 MaterialApp
    expect(find.byType(MaterialApp), findsOneWidget);

    // 七个主导航入口的标题都应该存在
    for (final label in <String>[
      '首页',
      '搜索',
      '观看记录',
      '播放清单',
      '新番预告',
      '下载',
      '设置',
    ]) {
      expect(
        find.text(label),
        findsWidgets,
        reason: '导航栏应该有「$label」入口',
      );
    }

    // 老的叫法不应该再出现
    expect(
      find.text('观看历史'),
      findsNothing,
      reason: '「观看历史」已更名为「观看记录」',
    );
  });

  testWidgets('构建过程不应该抛出异常', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MainShell())),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('启动页在启动失败时显示错误和重试按钮', (WidgetTester tester) async {
    // 注意：这里直接给一个「已经失败」的 Future，让启动页进入失败态。
    // 不测「等待就绪」那条路：它会起 45 秒轮询定时器，
    // 测试结束时定时器还挂着会直接判定失败（Pending timer）。
    await tester.pumpWidget(
      MaterialApp(
        home: StartupGate(
          backendStart: Future.value((false, false, '测试用的启动失败原因')),
          child: const SizedBox.shrink(),
        ),
      ),
    );

    // Future 是异步完成的，要 pump 两次：一次让它 resolve，一次重建
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('测试用的启动失败原因'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 失败态不应该显示「就绪后的页面」
    expect(find.byType(SizedBox), findsWidgets);
  });

  group('搜索框居中', () {
    // 覆盖「窄窗口 / 典型窗口 / 宽窗口 / 超宽窗口」
    for (final width in <double>[420, 700, 1000, 1440, 1920, 2560]) {
      testWidgets('窗口宽 ${width.toInt()} 时左右留白相等', (WidgetTester tester) async {
        await _setWindowSize(tester, Size(width, 900));

        // 用 Scaffold 包一层：真实 App 里页面外面有 Scaffold，
        // TextField 需要一个 Material 祖先。
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: SearchPage()),
          ),
        );
        await tester.pump();

        final box = _searchField.evaluate().single.renderObject;

        expect(box, isNotNull, reason: '应该能找到搜索框');

        final rect = (box as RenderBox).localToGlobal(Offset.zero) & box.size;

        final leftGap = rect.left;
        final rightGap = width - rect.right;

        // 允许 1 像素的取整误差
        expect(
          (leftGap - rightGap).abs(),
          lessThanOrEqualTo(1.0),
          reason: '窗口宽 $width 时搜索框应该居中：'
              '左边留白 $leftGap，右边留白 $rightGap',
        );

        // 同时确认搜索框没有跑出屏幕
        expect(rect.left, greaterThanOrEqualTo(0.0));
        expect(rect.right, lessThanOrEqualTo(width));
      });
    }
  });

  test('主题模式可以保存并读回', () async {
    SharedPreferences.setMockInitialValues({});

    await ThemeController.setMode(ThemeMode.dark);
    expect(ThemeController.mode.value, ThemeMode.dark);

    // 模拟重启：把当前值丢掉，重新从存储加载
    ThemeController.mode.value = ThemeMode.system;
    await ThemeController.load();

    expect(
      ThemeController.mode.value,
      ThemeMode.dark,
      reason: '保存过的主题应该在重新加载后恢复',
    );
  });

  group('个人中心 tab 映射', () {
    test('自己的个人中心有 5 个 tab，第一个是「主页」', () {
      expect(selfProfileTabs.length, 5);
      expect(selfProfileTabs.first.key, 'home');
      expect(selfProfileTabs.first.label, '主页');

      // 顺序要和官网一致
      expect(
        selfProfileTabs.map((t) => t.key).toList(),
        ['home', 'histories', 'saves', 'likes', 'playlists'],
      );
    });

    test('别人的主页不显示私密 tab', () {
      final keys = otherProfileTabs.map((t) => t.key).toList();

      expect(keys, ['home', 'uploaded', 'playlists']);
      expect(keys, isNot(contains('histories')));
      expect(keys, isNot(contains('saves')));
      expect(keys, isNot(contains('likes')));
    });

    test('「查看更多」链接能正确对应到 tab', () {
      const uid = '715321';

      expect(
        tabKeyFromUrl('https://hanime1.me/user/$uid/histories', uid),
        'histories',
      );
      expect(
        tabKeyFromUrl('https://hanime1.me/user/$uid/saves', uid),
        'saves',
      );
      expect(
        tabKeyFromUrl('https://hanime1.me/user/$uid/likes', uid),
        'likes',
      );
      expect(
        tabKeyFromUrl('https://hanime1.me/user/$uid/playlists', uid),
        'playlists',
      );
      expect(
        tabKeyFromUrl('https://hanime1.me/user/$uid/uploaded', uid),
        'uploaded',
      );
    });

    test('个人中心首页链接对应 home', () {
      expect(
        tabKeyFromUrl('https://hanime1.me/user/715321', '715321'),
        'home',
      );
      // 结尾多一个斜杠也要认得出来
      expect(
        tabKeyFromUrl('https://hanime1.me/user/715321/', '715321'),
        'home',
      );
    });

    test('认不出来的链接返回 null（调用方据此不显示「查看更多」）', () {
      expect(
        tabKeyFromUrl('https://hanime1.me/user/715321/edit', '715321'),
        isNull,
      );
      expect(tabKeyFromUrl('', '715321'), isNull);
      expect(tabKeyFromUrl('not a url', '715321'), isNull);
    });
  });

  // 缩略图尺寸 / 相关影片比例 / 信息图标 的测试在 layout_test.dart
  group('账号数据隔离', () {
    tearDown(() {
      // 每个测试后恢复成未登录，避免影响别的用例
      AuthController.account.value = AccountInfo.guest;
    });

    test('未登录时用 guest 前缀', () {
      AuthController.account.value = AccountInfo.guest;

      expect(AccountScope.prefix, 'guest');
      expect(AccountScope.key('watch_history'), 'guest_watch_history');
      expect(
        AccountScope.scopedKey('video_position', '408116'),
        'guest_video_position_408116',
      );
    });

    test('登录后 key 带账号 ID，不会和别的账号撞', () {
      AuthController.account.value = const AccountInfo(
        loggedIn: true,
        userId: '111',
        username: 'A',
      );

      expect(AccountScope.key('watch_history'), 'u_111_watch_history');

      final keyA = AccountScope.scopedKey('video_position', '408116');

      // 换成另一个账号
      AuthController.account.value = const AccountInfo(
        loggedIn: true,
        userId: '222',
        username: 'B',
      );

      final keyB = AccountScope.scopedKey('video_position', '408116');

      expect(keyB, 'u_222_video_position_408116');
      expect(
        keyA,
        isNot(keyB),
        reason: '同一个影片在不同账号下必须是不同的存储 key，'
            '否则进度会互相串',
      );
    });

    test('有 loggedIn 但没有 userId 时退回 guest', () {
      AuthController.account.value = const AccountInfo(
        loggedIn: true,
        userId: '',
      );

      expect(AccountScope.prefix, 'guest');
    });
  });

  group('播放进度格式化', () {
    // 这段逻辑决定进度条上的时间显示是否正确，值得锁住
    test('不足一小时只显示 分:秒', () {
      expect(formatPlaybackDuration(Duration.zero), '00:00');
      expect(formatPlaybackDuration(const Duration(seconds: 5)), '00:05');
      expect(formatPlaybackDuration(const Duration(minutes: 1, seconds: 5)),
          '01:05');
      expect(formatPlaybackDuration(const Duration(minutes: 22, seconds: 55)),
          '22:55');
      expect(formatPlaybackDuration(const Duration(minutes: 59, seconds: 59)),
          '59:59');
    });

    test('超过一小时显示 时:分:秒', () {
      expect(
        formatPlaybackDuration(
          const Duration(hours: 1, minutes: 5, seconds: 3),
        ),
        '1:05:03',
      );
      expect(
        formatPlaybackDuration(const Duration(hours: 2)),
        '2:00:00',
      );
      // 分钟和秒都要补零，但小时不补
      expect(
        formatPlaybackDuration(
          const Duration(hours: 10, minutes: 0, seconds: 7),
        ),
        '10:00:07',
      );
    });

    test('刚好 60 分钟进位成 1 小时而不是 60:00', () {
      expect(
        formatPlaybackDuration(const Duration(minutes: 60)),
        '1:00:00',
      );
    });
  });

  group('AppCache 接口缓存', () {
    setUp(AppCache.clear);

    test('写进去能读出来', () {
      AppCache.set('k', [1, 2, 3]);

      expect(AppCache.get('k'), [1, 2, 3]);
    });

    test('没写过的 key 返回 null', () {
      expect(AppCache.get('从来没有过的key'), isNull);
    });

    test('过期后返回 null 并被清掉', () async {
      AppCache.set('k', 'value', ttl: const Duration(milliseconds: 60));

      expect(AppCache.get('k'), 'value');

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(AppCache.get('k'), isNull, reason: '过期后不应该再返回旧值');
      expect(AppCache.size, 0, reason: '过期的条目应该被清掉');
    });

    test('removeWherePrefix 只清掉指定前缀', () {
      AppCache.set('/api/filter?a=1', 'x');
      AppCache.set('/api/filter?a=2', 'y');
      AppCache.set('/api/video?id=1', 'z');

      AppCache.removeWherePrefix('/api/filter');

      expect(AppCache.get('/api/filter?a=1'), isNull);
      expect(AppCache.get('/api/filter?a=2'), isNull);
      expect(AppCache.get('/api/video?id=1'), 'z', reason: '不该误删别的接口');
    });

    test('buildKey 与参数顺序无关，且不同接口不会撞 key', () {
      final a = AppCache.buildKey('/api/filter', {'genre': '裏番', 'sort': ''});
      final b = AppCache.buildKey('/api/filter', {'sort': '', 'genre': '裏番'});

      expect(a, b, reason: '同一组参数不管顺序都应该算出同一个 key');

      final c = AppCache.buildKey('/api/home_sections', {'genre': '裏番', 'sort': ''});

      expect(
        a,
        isNot(c),
        reason: '不同接口即使参数相同也不能共用 key',
      );
    });
  });
}
