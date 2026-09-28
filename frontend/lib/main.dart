import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'playlist_page.dart';
import 'downloads_page.dart';
import 'widgets/windows11_loading.dart';
import 'controllers/theme_controller.dart';
import 'controllers/app_cache.dart';
import 'controllers/auth_controller.dart';
import 'controllers/saved_accounts.dart';
import 'controllers/account_scope.dart';
import 'controllers/backend_launcher.dart';
import 'login_dialog.dart';
import 'new_release_page.dart';
import 'startup_gate.dart';
import 'user_profile_page.dart';
import 'utils/format.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'controllers/app_config.dart';
import 'controllers/data_revision.dart';
import 'controllers/home_request.dart';
import './widgets/app_toast.dart';
import 'widgets/pager_bar.dart';
import 'widgets/video_card.dart';
import 'widgets/player_shortcuts.dart';
import 'widgets/custom_title_bar.dart';
import 'widgets/hanime_logo.dart';
import 'widgets/window_resize_border.dart';
import 'controllers/app_window.dart';
import 'controllers/app_settings.dart';
import 'widgets/save_playlist_dialog.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();

  // 允许用环境变量覆盖端口，方便排错或同时跑多个实例
  AppConfig.applyEnvironment(Platform.environment);

  await ThemeController.load();

  // 播放器 / 下载偏好（快捷键步长、倍速、上次音量、上次窗口大小）
  await AppSettings.load();

  // 恢复上次的窗口大小，并且**每次都居中**。
  //
  // 这里只做准备（尺寸 / 无边框 / 阴影），**不显示窗口** ——
  // 显示推迟到第一帧画完之后，见下面 runApp 后面的 post-frame 回调。
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: AppSettings.windowSize.value ?? AppSettings.defaultWindowSize,
      center: true,
      minimumSize: AppSettings.minimumWindowSize,
      title: 'HanimeViewer',
    ),
    () async {
      // 去掉系统标题栏，改用自绘的（见 widgets/custom_title_bar.dart）。
      //
      // 用 setAsFrameless() 而不是 TitleBarStyle.hidden：
      // hidden 会通过 WM_NCCALCSIZE 在左/右/下各留 8px 非客户区边框，
      // 那圈边框是窗口类背景色画的，深色主题下很明显。
      await windowManager.setAsFrameless();

      // 无边框之后系统不再画阴影，用 DWM 把边框重新延伸出来补上，
      // 不然窗口和桌面糊在一起、看不出边界。
      await windowManager.setHasShadow(true);
    },
  );

  // 自绘标题栏要靠这些事件知道「现在是不是最大化 / 全屏」
  windowManager.addListener(AppWindowListener());

  // 先读本地缓存的账号信息（立刻能显示头像），再异步向后端确认
  await AuthController.load();

  // 关窗口时把后端一起收掉，否则端口会一直被占着。
  // 只收我们自己启动的那个：如果后端是外部起的就不动它。
  windowManager.addListener(_LifecycleCleaner());

  // 关窗时先拦住，等 _LifecycleCleaner 把后端和设置处理完再真的关。
  // 没有这一句的话，窗口一关进程就退，onWindowClose 里的异步收尾
  // 会被直接掐断（清理就白做了）。
  await windowManager.setPreventClose(true);

  // 自己把后端拉起来（后端再去把调试 Chrome 拉起来）。
  // 如果后端已经在跑（比如开发时手动起的），会直接复用。
  //
  // **拿到 Future 就走，不等它** —— 实测这一步冷启动要 2100ms
  // （`isBackendAlive()` 探测端口有 2 秒超时），而前面所有初始化
  // 加起来才 33ms。在这里 await 的话首帧要等到 2 秒之后，
  // 窗口就一直不出现。等它的活儿交给启动页（StartupGate）。
  final backendStart = BackendLauncher.startWithStatus();

  runApp(HanimeViewerApp(backendStart: backendStart));

  // 等**第一帧真的画完**再显示窗口。
  //
  // 以前是在 waitUntilReadyToShow 的回调里就 show()，那会儿 Flutter 还
  // 什么都没画；而窗口类的背景刷是空的（win32_window.cpp 里
  // `hbrBackground = 0`），所以露出来的是一块**全透明的窗口** ——
  // 只有 DWM 阴影勾出个轮廓，用户看到的就是"一个能看见边框的透明窗口"，
  // 过一会儿才变成界面（而且因为后端那 2 秒，这一眼要持续 5 秒多）。
  // 放在首帧之后再显示就没这一眼了。
  //
  // 窗口一直隐藏着也会正常渲染（引擎照常出帧），所以这个回调一定会到。
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await windowManager.show();
    await windowManager.focus();
    await AppWindow.refresh();
  });
}

/// 负责在 App 退出时清理我们启动的后端进程，并记下窗口大小。
class _LifecycleCleaner with WindowListener {
  Timer? _saveSizeTimer;

  /// 拖动窗口边框时会连续触发（对应 WM_SIZING），防抖一下再写盘。
  ///
  /// 注意：**程序化的改尺寸不会触发这个事件**（比如 `setSize`
  /// 或系统的 MoveWindow 都只发 WM_SIZE）。所以真正兜底的是
  /// [_onWindowResized]（拖拽结束时那一次）。
  @override
  void onWindowResize() => _scheduleSaveSize();

  /// 拖拽调整大小结束（WM_EXITSIZEMOVE）—— 用户拖完松手那一下。
  @override
  void onWindowResized() => _scheduleSaveSize();

  void _scheduleSaveSize() {
    _saveSizeTimer?.cancel();
    _saveSizeTimer = Timer(const Duration(milliseconds: 400), _rememberSize);
  }

  /// 记住当前窗口大小。
  ///
  /// 最大化 / 全屏时不记 —— 那记下来的是"屏幕大小"，
  /// 下次启动会以一个占满屏的窗口开始，不是用户想要的效果。
  Future<void> _rememberSize() async {
    try {
      if (await windowManager.isMaximized()) return;
      if (await windowManager.isFullScreen()) return;

      final size = await windowManager.getSize();

      await AppSettings.setWindowSize(size.width, size.height);
    } catch (_) {
      // 拿不到就算了，不该因为记窗口大小影响退出
    }
  }

  /// 已经在走关闭流程了（防止重复收尾）
  bool _closing = false;

  @override
  void onWindowClose() {
    // 取消拦截后再 close() 会再收到一次 close 事件，这里挡掉
    if (_closing) return;

    _closing = true;

    // 立刻把窗口藏起来。
    //
    // 用户点了关闭就该马上看到窗口消失。但后面还有收尾要做
    // （写设置、请后端退出），而开着 preventClose 时窗口会一直
    // 杵在屏幕上，看起来就是"点了关闭没反应，要等几秒"。
    try {
      windowManager.hide();
    } catch (_) {}

    _saveSizeTimer?.cancel();

    // 关后端的请求必须**立刻**发出去。
    //
    // 窗口一旦关掉，进程随时会结束、Dart 隔离区跟着没。
    // 之前把它挂在 _rememberSize().then(...) 后面，结果还没轮到它
    // 进程就退了 —— 后端和 12 个隐藏 chrome 全留在后台（实测踩到）。
    //
    // 注意 stop() 现在只是"把请求发出去"就返回，不再等浏览器收尾
    // （后端是独立进程，收到请求后会自己收干净），所以这里等它不费时间。
    final stopping = BackendLauncher.stop();

    // 记窗口大小和音量是"顺手做的事"，跟关后端并行跑
    final saving = _rememberSize().then((_) => AppSettings.flushVolume());

    void closeWindow() => unawaited(_finishClose());

    // 两件都快（一个是本机 HTTP 往返、一个是几次本地写盘），
    // 都完成了再关窗，保证设置一定落盘。
    //
    // 兜底定时器在正常路径上要**取消掉**：留着一个待触发的 Timer
    // 会让 Dart 隔离区多活一会儿，进程也就退得慢。
    final safety = Timer(const Duration(seconds: 2), closeWindow);

    Future.wait<void>([stopping, saving]).whenComplete(() {
      safety.cancel();
      closeWindow();
    });
  }

  /// 收尾做完之后，真正把窗口关掉。
  ///
  /// 这里**不用 `destroy()`**：它只是往消息队列丢一个 WM_QUIT，
  /// 窗口本身并没有被销毁，进程退出时还得额外拆一遍 ——
  /// 实测从调用到进程真正消失要拖 4.7 秒（用户反馈"要等四五秒"）。
  ///
  /// 改成「先取消拦截、再走正常关窗」：窗口会被真正销毁，
  /// 引擎收到 OnDestroy，进程很快就退了。
  Future<void> _finishClose() async {
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (_) {
      try {
        windowManager.destroy();
      } catch (_) {}
    }
  }
}

class HanimeViewerApp extends StatelessWidget {
  /// 启动后端的 Future —— 界面先出来，等它的活儿交给启动页。
  ///
  /// 不在这里算好再传：后端冷启动要 2 秒左右，算好再传的话首帧
  /// 就得等 2 秒，窗口一直不出现（见 main() 里的注释）。
  final Future<BackendStart>? backendStart;

  const HanimeViewerApp({super.key, this.backendStart});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'HanimeViewer',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.deepPurple,
              brightness: Brightness.light,
            ),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.deepPurple,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          themeMode: themeMode,

          // 自绘标题栏放在 Navigator **外面**（MaterialApp.builder 包的就是
          // Navigator）。放在 home 里的话，push 出来的页面（影片详情、
          // 全屏播放器）会整个盖住它 —— 标题栏就没了。
          //
          // 它是一条**透明浮层**：底下的应用（含左侧侧边栏）直接透上来，
          // 而且拖动区是 `translucent` 的（点得到下面的内容），
          // 所以页面**不需要**为它让出顶部 —— 各页面就从 y=0 开始，
          // 不会白白留一条 38px 的空白。
          builder: (context, child) {
            return ValueListenableBuilder<bool>(
              valueListenable: AppWindow.fullscreen,
              builder: (context, fullscreen, _) {
                return WindowResizeBorder(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: child ?? const SizedBox.shrink(),
                      ),

                      // 全屏看片时整条收起来
                      if (!fullscreen)
                        const Positioned(
                          left: 0,
                          right: 0,
                          top: 0,
                          height: AppWindow.titleBarHeight,
                          child: CustomTitleBar(),
                        ),
                    ],
                  ),
                );
              },
            );
          },

          home: StartupGate(
            backendStart: backendStart,
            child: const MainShell(),
          ),
        );        
      },
    );
  }
}

enum _MainSection {
  home,
  search,
  history,
  playlist,
  newRelease,
  downloads,
  settings,
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  _MainSection _section = _MainSection.home;

  Map<String, String>? _searchPreset;

  /// 已经创建过的页面。
  ///
  /// 以前 _buildPage() 用 switch 只返回当前页面，切走时旧页面会被销毁，
  /// 切回来重新 initState -> 重新请求接口，所以每次切换都要重新等一遍。
  /// 现在把页面放进 IndexedStack 保留 State，切回来时内容还在，
  /// 配合 AppCache 也就不会重复请求了。
  final Map<_MainSection, Widget> _pages = {};

  /// 创建这些页面时用的是哪个账号。
  ///
  /// 观看历史 / 搜索记录 / 播放清单 / 播放进度都是跟着账号走的，
  /// 所以换账号时必须把已经建好的页面丢掉重建，
  /// 否则会一直显示上一个账号的数据。
  String _pagesScope = AccountScope.prefix;

  @override
  void initState() {
    super.initState();

    // 别的页面（影片详情页等）可以请求「回到首页」
    HomeRequest.requests.addListener(_onHomeRequested);
  }

  @override
  void dispose() {
    HomeRequest.requests.removeListener(_onHomeRequested);

    super.dispose();
  }

  /// 有页面请求回首页：把栏目切到「首页」。
  ///
  /// 不必在这层操心导航栈 —— 调用方会把 push 出来的页面关掉，
  /// 露出主壳时它已经在首页了。
  void _onHomeRequested() {
    if (!mounted) return;

    setState(() {
      _section = _MainSection.home;
      _searchPreset = null;
    });
  }

  /// 账号变了就清掉缓存页面（下次 build 会用新账号重建）。
  void _resetPagesIfAccountChanged() {
    final current = AccountScope.prefix;

    if (current == _pagesScope) return;

    _pagesScope = current;
    _pages.clear();

    // 接口结果也按账号隔离：里面可能含播放清单等私有数据
    AppCache.clear();
  }

  void _select(_MainSection section) {
    setState(() {
      _section = section;
      _searchPreset = null;
    });
    if (MediaQuery.sizeOf(context).width < 800) {
      Navigator.of(context).maybePop();
    }
  }

  void _openCategory(String title, String genre, String sort) {
    setState(() {
      _section = _MainSection.search;
      _searchPreset = {
        'genre': genre,
        'sort': sort,
        'key': DateTime.now().microsecondsSinceEpoch.toString(),
      };

      // 换了筛选条件，搜索页需要重建（key 变了）
      _pages.remove(_MainSection.search);
    });
  }

  Widget _pageFor(_MainSection section) {
    // 先查已创建的页面，存在就直接复用（IndexedStack 会保留它的 State）
    final existing = _pages[section];

    if (existing != null) {
      return existing;
    }

    final created = _createPage(section);

    _pages[section] = created;

    return created;
  }

  Widget _createPage(_MainSection section) {
    switch (section) {
      case _MainSection.home:
        return HomePage(onOpenCategory: _openCategory);
      case _MainSection.search:
        return SearchPage(
          key: ValueKey(
            _searchPreset == null
                ? 'search_default'
                : 'search_${_searchPreset!['key']}',
          ),
          initialGenre: _searchPreset?['genre'] ?? '',
          initialSort: _searchPreset?['sort'] ?? '',
        );
      case _MainSection.history:
        return const HistoryPage();
      case _MainSection.playlist:
        return const PlaylistPage();
      case _MainSection.newRelease:
        return const NewReleasePage();
      case _MainSection.downloads:
        return const DownloadsPage();
      case _MainSection.settings:
        return const SettingsPage();        
    }
  }

  /// 用 IndexedStack 承载所有「已经打开过」的页面：
  /// 只有当前页可见，其余页面保持存活但不可见，
  /// 这样切回来时滚动位置、输入内容、已加载的数据都还在。
  ///
  /// 没打开过的页面不会创建，所以不会在启动时把所有接口都请求一遍。
  Widget _buildPage() {
    // 换了账号就把旧页面丢掉，用新账号重建
    _resetPagesIfAccountChanged();

    // 确保当前页面已经创建（第一次进入某个栏目时在这里创建）
    final current = _pageFor(_section);

    final opened = [
      for (final section in _MainSection.values)
        if (_pages.containsKey(section)) section,
    ];

    if (opened.length <= 1) {
      return current;
    }

    return IndexedStack(
      index: opened.indexOf(_section),
      children: [
        for (final section in opened) _pages[section]!,
      ],
    );
  }

  Widget _buildNavigation({bool drawer = false}) {
    final items = <(
      _MainSection,
      IconData,
      IconData,
      String
    )>[
      (
        _MainSection.home,
        Icons.home_outlined,
        Icons.home,
        '首页'
      ),
      (
        _MainSection.search,
        Icons.search_outlined,
        Icons.search,
        '搜索'
      ),
      (
        _MainSection.history,
        Icons.history_outlined,
        Icons.history,
        '观看记录'
      ),
      (
        _MainSection.playlist,
        Icons.playlist_play_outlined,
        Icons.playlist_play,
        '播放清单'
      ),
      (
        _MainSection.newRelease,
        Icons.new_releases_outlined,
        Icons.new_releases,
        '新番预告'
      ),
      (
        _MainSection.downloads,
        Icons.download_outlined,
        Icons.download,
        '下载'
      ),
      (
        _MainSection.settings,
        Icons.settings_outlined,
        Icons.settings,
        '设置'
      ),
    ];

    if (drawer) {
      return SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 12),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 8, 20, 20),
                    child: Text(
                      'HanimeViewer',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  for (final item in items)
                    ListTile(
                      leading: Icon(
                        _section == item.$1
                            ? item.$3
                            : item.$2,
                      ),
                      title: Text(item.$4),
                      selected: _section == item.$1,
                      onTap: () => _select(item.$1),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            _AccountTile(
              onOpenProfile: _openMyProfile,
              onLogout: _logout,
            ),
          ],
        ),
      );
    }

    // 侧边栏：NavigationRail 占上方，账号入口固定在底部。
    // 外面套一个固定宽度的 SizedBox，保证 NavigationRail 拿到明确的宽度约束
    // （否则在窄窗口下它会算出非法约束导致布局断言失败）。
    return SizedBox(
      width: 88,
      child: Stack(
        // expand：让下面的 Column 铺满整个侧边栏
        fit: StackFit.expand,
        children: [
          Column(
            children: [
              // 顶部让出程序图标的位置：图标占 y 29..59，导航从它下面开始。
              // （侧边栏是从窗口 y=0 开始的，这里就是窗口坐标）
              SizedBox(height: SidebarLogo.reservedHeight),
              Expanded(
                child: NavigationRail(
                  selectedIndex:
                      _MainSection.values.indexOf(_section),
                  onDestinationSelected: (index) =>
                      _select(_MainSection.values[index]),
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final item in items)
                      NavigationRailDestination(
                        icon: Icon(item.$2),
                        selectedIcon: Icon(item.$3),
                        label: Text(item.$4),
                      ),
                  ],
                ),
              ),
              // 左下角的账号头像：未登录显示登录入口，登录后点进自己的主页
              // （刻意不加分隔线，保持干净）
              _AccountTile(
                onOpenProfile: _openMyProfile,
                onLogout: _logout,
              ),
            ],
          ),

          // 程序图标：只有红色的 H（不带底），**浮在导航之上**。
          //
          // 为什么要单独抽成 SidebarLogo：直接放在上面那个 Column 里时，
          // 图标要比 NavigationRail 的起点更靠下，下半截会被导航的
          // 背景 Material 盖掉（实测只画出 12x15，少了一半）。
          // 它是 Stack 里后画的那个，位置细节见 widgets/hanime_logo.dart。
          const SidebarLogo(),
        ],
      ),
    );
  }

  /// 退出登录。
  ///
  /// 会让浏览器登出，然后把本地数据切回「未登录」作用域 ——
  /// 这样下一个人登录时不会看到上一个账号的历史和播放清单。
  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text(
          '退出后会回到未登录状态。\n'
          '各账号的观看历史、搜索记录、播放进度都是分开保存的，'
          '重新登录仍会看到自己的数据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await AuthController.logout();

    // 退出后清掉本地保存的密码（账号条目保留，下次仍能快捷登录）
    await SavedAccounts.forgetPasswords();

    if (!mounted) return;

    // 切回未登录作用域，页面按新作用域重建
    setState(() {});

    AppToast.show(context, '已退出登录');
  }

  /// 打开「我的主页」（点赞过的影片、储存的播放清单都在这里）
  void _openMyProfile() {
    final info = AuthController.account.value;

    if (!info.loggedIn || info.userId.isEmpty) {
      _showLogin();

      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UserProfilePage(
          userId: info.userId,
          initialName: info.username,
          initialTab: 'home',
        ),
      ),
    );
  }

  Future<void> _showLogin() async {
    final before = AccountScope.prefix;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const LoginDialog(),
    );

    if (!mounted) return;

    // 登录对话框内部会更新 AuthController.account。
    // 这里显式重建一次，保证：
    // - 侧边栏头像立刻更新
    // - 已经缓存的页面按新账号重建（见 _resetPagesIfAccountChanged）
    setState(() {});

    final changed = AccountScope.prefix != before;

    if (ok == true || changed) {
      AppToast.success(
        context,
        ok == true ? '登录成功，数据已切换到该账号' : '账号已切换',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide =
        MediaQuery.sizeOf(context).width >= 800;

    // 账号（登录/登出/换号）变化时整壳重建：
    // 观看历史、搜索记录、播放清单、播放进度都跟着账号走，
    // 不重建的话会一直显示上一个账号的数据。
    return ValueListenableBuilder<AccountInfo>(
      valueListenable: AuthController.account,
      builder: (context, _, _) => _buildShell(wide),
    );
  }

  /// 内容区顶部要不要给右上角那三个窗口按钮让位。
  ///
  /// 窗口按钮是浮在最上面的实心控件（各 46x38，占右上角 138x38），
  /// 所以页面顶部**靠右有通栏内容**时会和它们叠在一起。
  ///
  /// 实测过每一个页面：
  /// - 首页（"最新上市 / 查看更多"那一行）、观看记录、播放清单、
  ///   新番预告、下载页 —— 顶部都是通栏内容，**要让**；
  /// - 搜索页（顶部只有居中的搜索框，离右边很远）、
  ///   设置页（顶部只有左边一段说明文字，第一张卡片从 y≈95 才开始）
  ///   —— **不用让**，让了就是白留一条。
  ///
  /// 窄窗口下不用管：那里有 AppBar（40 高），内容本来就从 40 开始。
  double _topInsetFor(_MainSection section) {
    switch (section) {
      case _MainSection.search:
      case _MainSection.settings:
        return 0;

      case _MainSection.home:
      case _MainSection.history:
      case _MainSection.playlist:
      case _MainSection.newRelease:
      case _MainSection.downloads:
        return AppWindow.titleBarHeight;
    }
  }

  Widget _buildShell(bool wide) {
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            _buildNavigation(),
            const VerticalDivider(width: 1),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: _topInsetFor(_section)),
                child: _buildPage(),
              ),
            ),
          ],
        ),
      );
    }

    // 窄窗口：AppBar 自己会吃掉 MediaQuery 的顶部留白，不用额外处理
    return Scaffold(
      appBar: AppBar(
        title: const SizedBox.shrink(),
        toolbarHeight: 40,
      ),
      drawer: Drawer(        
        child: _buildNavigation(drawer: true),
      ),
      body: _buildPage(),
    );    
  }
}

class HomePage extends StatefulWidget {
  final void Function(String title, String genre, String sort)?
      onOpenCategory;

  const HomePage({
    super.key,
    this.onOpenCategory,
  });

  @override
  State<HomePage> createState() =>
      _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Map<String, dynamic>> _sections = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();

    // 设置页里拖完栏目顺序要立刻生效。
    // 首页是常驻页面（IndexedStack 里活着），不监听的话回来还是旧顺序。
    AppSettings.homeSectionOrder.addListener(_onOrderChanged);

    // 先看缓存：有就直接显示，避免启动时白屏等网络
    final cached = AppCache.get(AppCache.homeSectionsKey);

    if (cached is List) {
      _sections = List<Map<String, dynamic>>.from(cached);
      _loading = false;

      return;
    }

    _loadHomeVideos();
  }

  @override
  void dispose() {
    AppSettings.homeSectionOrder.removeListener(_onOrderChanged);

    super.dispose();
  }

  void _onOrderChanged() {
    if (mounted) setState(() {});
  }

  /// 按用户在设置里排的顺序整理栏目，视频跟着栏目一起走。
  ///
  /// 具体的排序规则（没排过的排最后、保证稳定）在
  /// [AppSettings.applyHomeOrder] 里，那边有测试。
  List<Map<String, dynamic>> get _orderedSections =>
      AppSettings.applyHomeOrder(
        _sections,
        (section) => section['name']?.toString() ?? '',
      );

  Future<void> _loadHomeVideos() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http.get(
        Uri.parse(
          '${AppConfig.backendBase}/api/home_sections',
        ),
      );

      if (response.statusCode != 200) {
        throw Exception(
          '服务器返回错误: ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body);

      final sections = List<Map<String, dynamic>>.from(
        data['sections'] ?? [],
      );

      if (sections.isNotEmpty) {
        AppCache.set(
          AppCache.homeSectionsKey,
          sections,
          ttl: AppCache.homeTtl,
        );
      }

      if (mounted) {
        setState(() => _sections = sections);
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = '首页加载失败：$e',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String? _extractVideoId(String url) {
    final uri = Uri.tryParse(url);
    return uri?.queryParameters['v'];
  }

  void _openVideo(Map<String, dynamic> video) {
    final id = _extractVideoId(
      video['url']?.toString() ?? '',
    );

    if (id == null || id.isEmpty) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoDetailPage(videoId: id),
      ),
    );
  }

  void _openCategory(String name, String url) {
    final uri = Uri.tryParse(url);

    if (uri == null) return;

    final genre = uri.queryParameters['genre'] ?? '';
    String sort = uri.queryParameters['sort'] ?? '';

    // 有 genre 时忽略 sort，避免官网 URL 自带的 sort 干扰
    if (genre.isNotEmpty) {
      sort = '';
    }

    if (widget.onOpenCategory != null) {
      widget.onOpenCategory!(name, genre, sort);
    }
  }

  Widget _buildSection(
    Map<String, dynamic> section,
    double maxWidth,
  ) {
    final name = section['name']?.toString() ?? '';
    final url = section['url']?.toString() ?? '';
    final videos = List<Map<String, dynamic>>.from(
      section['videos'] ?? [],
    );

    if (videos.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                name,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (url.isNotEmpty)
                TextButton(
                  onPressed: () {
                    _openCategory(name, url);
                  },
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('查看更多'),
                      Icon(Icons.chevron_right, size: 18),
                    ],
                  ),
                ),
            ],
          ),
        ),

        // 尺寸由 widgets/video_card.dart 统一提供，
        // 首页就是这套尺寸的标准，别的页面都向它对齐。
        VideoCardGrid(
          videos: videos,
          shrinkWrap: true,
          onTap: _openVideo,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Windows11Loading(size: 48),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: const TextStyle(color: Colors.red),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _loadHomeVideos,
              icon: const Icon(Icons.refresh),
              label: const Text('重新加载'),
            ),
          ],
        ),
      );
    }

    if (_sections.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadHomeVideos,
        child: ListView(
          children: const [
            SizedBox(height: 180),
            Center(child: Text('暂无内容')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadHomeVideos,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final sections = _orderedSections;

          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: sections.length,
            itemBuilder: (_, index) => _buildSection(
              sections[index],
              constraints.maxWidth,
            ),
          );
        },
      ),
    );
  }
}

/// 首页栏目排序对话框：拖着重排，即时生效。
///
/// 单独一个 StatefulWidget 是因为拖动过程中要记住当前顺序。
class _HomeSectionOrderDialog extends StatefulWidget {
  /// 当前顺序（已经是用户排过的了）
  final List<String> names;

  const _HomeSectionOrderDialog({required this.names});

  @override
  State<_HomeSectionOrderDialog> createState() =>
      _HomeSectionOrderDialogState();
}

class _HomeSectionOrderDialogState extends State<_HomeSectionOrderDialog> {
  late final List<String> _names = [...widget.names];

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    setState(() {
      // 用 onReorderItem 而不是旧的 onReorder：它给的 newIndex
      // **已经**是移除之后的下标了，不用自己再减一。
      final moved = _names.removeAt(oldIndex);

      _names.insert(newIndex, moved);
    });

    await AppSettings.setHomeSectionOrder(_names);
  }

  Future<void> _reset() async {
    await AppSettings.setHomeSectionOrder(const []);

    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('首页栏目排序'),
      content: SizedBox(
        width: 420,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '按住右边的把手上下拖。视频会跟着栏目一起移动。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                itemCount: _names.length,
                onReorderItem: (oldIndex, newIndex) {
                  _onReorder(oldIndex, newIndex);
                },
                itemBuilder: (context, index) => Card(
                  key: ValueKey(_names[index]),
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    dense: true,
                    leading: Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    title: Text(_names[index]),
                    trailing: ReorderableDragStartListener(
                      index: index,
                      child: const Icon(Icons.drag_handle),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _reset,
          child: const Text('恢复默认顺序'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

class SearchPage extends StatefulWidget {
  final String initialGenre;
  final String initialSort;

  const SearchPage({
    super.key,
    this.initialGenre = '',
    this.initialSort = '',
  });

  @override
  State<SearchPage> createState() =>
      _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller =
      TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  List<Map<String, dynamic>> _results = [];
  bool _loading = false;
  String? _error;

  String _selectedGenre = '';
  String _selectedSort = '';
  String _selectedDate = '';
  String _selectedDuration = '';
  List<String> _selectedTags = [];
  bool _broadMatch = false;

  List<Map<String, dynamic>> _tagGroups = [];
  bool _tagsLoaded = false;
  bool _tagsLoading = false;

  /// 标签分组的缓存 key（后端把标签随搜索结果一起返回，这里缓存下来复用）
  static const String _tagCacheKey = 'search_tag_groups';

  bool get _isPortraitCategory =>
      _selectedGenre == '裏番' || _selectedGenre == '泡麵番';

  /// 搜索历史跟着账号走（见 account_scope.dart）
  String get _historyKey => AccountScope.key('search_history');

  static const int _maxHistoryCount = 20;
  List<String> _searchHistory = [];
  bool _showHistoryPanel = false;
  
  @override
  void initState() {
    super.initState();
    _selectedGenre = widget.initialGenre;
    _selectedSort = widget.initialSort;
    _searchFocusNode.addListener(_onSearchFocusChanged);
    _loadSearchHistory();

    // 进入搜索页：无条件加载一次（显示默认搜索结果）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _search();
    });
  }

  void _onSearchFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  static const List<Map<String, String>> _genreOptions = [
    {'label': '全部', 'value': ''},
    {'label': '裏番', 'value': '裏番'},
    {'label': '泡麵番', 'value': '泡麵番'},
    {'label': 'Motion Anime', 'value': 'Motion Anime'},
    {'label': '3DCG', 'value': '3DCG'},
    {'label': '2.5D動畫', 'value': '2.5D'},
    {'label': '2D動畫', 'value': '2D動畫'},
    {'label': 'AI生成', 'value': 'AI生成'},
    {'label': 'MMD', 'value': 'MMD'},
    {'label': 'Cosplay', 'value': 'Cosplay'},
  ];

  static const List<Map<String, String>> _sortOptions = [

    {'label': '默认排序', 'value': ''},
    {'label': '最新上市', 'value': '最新上市'},
    {'label': '最新上傳', 'value': '最新上傳'},
    {'label': '本日排行', 'value': '本日排行'},
    {'label': '本週排行', 'value': '本週排行'},
    {'label': '本月排行', 'value': '本月排行'},
    {'label': '觀看次數', 'value': '觀看次數'},
    {'label': '讚好比例', 'value': '讚好比例'},
    {'label': '時長最長', 'value': '時長最長'},
    {'label': '他們在看', 'value': '他們在看'},
  ];

  static const List<Map<String, String>> _dateOptions = [
    {'label': '全部', 'value': ''},
    {'label': '過去 24 小時', 'value': '過去 24 小時'},
    {'label': '過去 2 天', 'value': '過去 2 天'},
    {'label': '過去 1 週', 'value': '過去 1 週'},
    {'label': '過去 1 個月', 'value': '過去 1 個月'},
    {'label': '過去 3 個月', 'value': '過去 3 個月'},
    {'label': '過去 1 年', 'value': '過去 1 年'},
  ];

  static const List<Map<String, String>> _durationOptions = [
    {'label': '全部', 'value': ''},
    {'label': '1 分鐘 +', 'value': '1 分鐘 +'},
    {'label': '5 分鐘 +', 'value': '5 分鐘 +'},
    {'label': '10 分鐘 +', 'value': '10 分鐘 +'},
    {'label': '20 分鐘 +', 'value': '20 分鐘 +'},
    {'label': '30 分鐘 +', 'value': '30 分鐘 +'},
    {'label': '60 分鐘 +', 'value': '60 分鐘 +'},
    {'label': '0 - 10 分鐘', 'value': '0 - 10 分鐘'},
    {'label': '0 - 20 分鐘', 'value': '0 - 20 分鐘'},
  ];

  String? _extractVideoId(String url) {
    final uri = Uri.tryParse(url);
    return uri?.queryParameters['v'];
  }

  Future<void> _search() async {
    final query = _controller.text.trim();

    // 无条件执行搜索：即使没有任何筛选，也加载默认结果

    final params = <String, String>{};

    if (query.isNotEmpty) {
      params['query'] = query;
    }

    if (_selectedGenre.isNotEmpty) {
      params['genre'] = _selectedGenre;
    }

    if (_selectedSort.isNotEmpty) {
      params['sort'] = _selectedSort;
    }

    if (_selectedDate.isNotEmpty) {
      params['date'] = _selectedDate;
    }

    if (_selectedDuration.isNotEmpty) {
      params['duration'] = _selectedDuration;
    }

    if (_selectedTags.isNotEmpty) {
      params['tags'] = _selectedTags.join('|');
    }

    if (_broadMatch && _selectedTags.isNotEmpty) {
      params['broad'] = 'on';
    }

    // 后端要求 query/genre/sort 至少有一个
    if (!params.containsKey('query') &&
        !params.containsKey('sort') &&
        !params.containsKey('genre')) {
      params['query'] = '';
    }

    // 同一组筛选条件在短时间内重复请求时，直接用上次的结果，
    // 不用再等一次「CDP -> 解析」的往返
    final cacheKey = AppCache.buildKey('/api/filter', params);

    final cached = AppCache.get(cacheKey);

    if (cached is Map && cached['results'] is List) {
      setState(() {
        _results = List<Map<String, dynamic>>.from(
          cached['results'],
        );
        _loading = false;
        _error = null;
      });

      if (query.isNotEmpty) {
        _saveSearchHistory(query);
      }

      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _results = [];
    });

    try {
      final uri = Uri.parse(
        '${AppConfig.backendBase}/api/filter',
      ).replace(queryParameters: params);

      final response = await http.get(uri);

      if (response.statusCode != 200) {
        throw Exception(
          '服务器返回错误: ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body);

      final results = List<Map<String, dynamic>>.from(
        data['results'] ?? [],
      );

      // 标签分组是搜索响应的附赠品（后端从同一个页面里解析出来的），
      // 这里顺手存下来，点「標籤」时就不用再单独请求一次了。
      final tagGroups = data['tag_groups'];

      if (tagGroups is List && tagGroups.isNotEmpty) {
        AppCache.set(
          _tagCacheKey,
          tagGroups,
          ttl: AppCache.tagsTtl,
        );

        if (mounted) {
          setState(() {
            _tagGroups = List<Map<String, dynamic>>.from(tagGroups);
            _tagsLoaded = true;
          });
        }
      }

      if (results.isNotEmpty) {
        AppCache.set(
          cacheKey,
          {
            'results': results,
            'total_pages': data['total_pages'],
          },
          ttl: AppCache.searchTtl,
        );
      }

      if (mounted) {
        setState(() {
          _results = results;
        });

        if (query.isNotEmpty) {
          _saveSearchHistory(query);
        }
      }      
    } catch (e) {
      if (mounted) {
        setState(() => _error = '搜索失败：$e');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final history = prefs.getStringList(_historyKey) ?? [];

      if (mounted) {
        setState(() => _searchHistory = history);
      }
    } catch (_) {
      // 加载失败就用空列表
    }
  }

  Future<void> _saveSearchHistory(String keyword) async {
    final trimmed = keyword.trim();

    if (trimmed.isEmpty) return;

    // 去重 + 最新排前
    final updated = [
      trimmed,
      ..._searchHistory.where((k) => k != trimmed),
    ];

    if (updated.length > _maxHistoryCount) {
      updated.removeRange(_maxHistoryCount, updated.length);
    }

    setState(() => _searchHistory = updated);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_historyKey, updated);
    } catch (_) {
      // 持久化失败只影响下次启动
    }
  }

  Future<void> _removeSearchHistory(String keyword) async {
    final updated =
        _searchHistory.where((k) => k != keyword).toList();

    setState(() => _searchHistory = updated);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_historyKey, updated);
    } catch (_) {}
  }

  Future<void> _clearSearchHistory() async {
    setState(() => _searchHistory = []);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyKey);
    } catch (_) {}
  }

  Future<void> _loadTags() async {
    if (_tagsLoaded) return;

    // 先看缓存（第一次搜索时已经顺手存下来了，正常情况都走这里，瞬间打开）
    final cached = AppCache.get(_tagCacheKey);

    if (cached is List && cached.isNotEmpty) {
      setState(() {
        _tagGroups = List<Map<String, dynamic>>.from(cached);
        _tagsLoaded = true;
      });

      return;
    }

    try {
      final response = await http.get(
        Uri.parse('${AppConfig.backendBase}/api/tags'),
      );

      if (response.statusCode != 200) {
        throw Exception(
          '服务器返回错误: ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body);

      final groups = List<Map<String, dynamic>>.from(
        data['groups'] ?? [],
      );

      if (groups.isNotEmpty) {
        AppCache.set(
          _tagCacheKey,
          groups,
          ttl: AppCache.tagsTtl,
        );
      }

      if (!mounted) return;

      setState(() {
        _tagGroups = groups;
        _tagsLoaded = true;
      });
    } catch (e) {
      if (!mounted) return;

      AppToast.error(context, '标签加载失败：$e');
    }
  }

  Future<void> _showTagDialog() async {
    // 正常情况下标签已经在第一次搜索时随结果一起拿到了，
    // _loadTags() 会立刻返回，弹窗秒开。
    // 只有「搜索还没回来就先点标签」这种情况才会真的等待。
    final firstLoad = !_tagsLoaded;

    if (firstLoad) {
      // 先给个反馈，避免用户以为没点到
      setState(() => _tagsLoading = true);
    }

    await _loadTags();

    if (mounted) {
      setState(() => _tagsLoading = false);
    }

    if (!mounted) return;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) {
        return SearchTagDialog(
          groups: _tagGroups,
          initialTags: _selectedTags,
          initialBroad: _broadMatch,
        );
      },
    );

    if (result == null) return;

    setState(() {
      _selectedTags =
          List<String>.from(result['tags'] ?? []);
      _broadMatch = result['broad'] == true;
    });

    if (_controller.text.trim().isNotEmpty) {
      _search();
    }
  }

  @override
  void dispose() {
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    _searchFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 筛选栏：始终靠左排列，视觉上统一成一组胶囊按钮。
  Widget _buildFilterBar() {
    final hasActiveFilter = _selectedGenre.isNotEmpty ||
        _selectedSort.isNotEmpty ||
        _selectedDate.isNotEmpty ||
        _selectedDuration.isNotEmpty ||
        _selectedTags.isNotEmpty;

    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        alignment: WrapAlignment.start,
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _buildDropdownFilter(
            label: '影片类型',
            currentValue: _selectedGenre,
            options: _genreOptions,
            onChanged: (v) {
              setState(() => _selectedGenre = v);
              _search();
            },
          ),
          _buildDropdownFilter(
            label: '排序',
            currentValue: _selectedSort,
            options: _sortOptions,
            onChanged: (v) {
              setState(() => _selectedSort = v);
              _search();
            },
          ),
          _buildDropdownFilter(
            label: '日期',
            currentValue: _selectedDate,
            options: _dateOptions,
            onChanged: (v) {
              setState(() => _selectedDate = v);
              _search();
            },
          ),
          _buildDropdownFilter(
            label: '時長',
            currentValue: _selectedDuration,
            options: _durationOptions,
            onChanged: (v) {
              setState(() => _selectedDuration = v);
              _search();
            },
          ),
          _buildTagButton(),
          if (hasActiveFilter) ...[
            // 和筛选按钮之间加一条细分隔线，把「重置」区分开
            Container(
              width: 1,
              height: 20,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
            ),
            _buildResetButton(),
          ],
        ],
      ),
    );
  }

  Widget _buildResetButton() {
    final theme = Theme.of(context);

    return TextButton.icon(
      onPressed: () {
        setState(() {
          _selectedGenre = '';
          _selectedSort = '';
          _selectedDate = '';
          _selectedDuration = '';
          _selectedTags = [];
          _broadMatch = false;
        });
        _search();
      },
      icon: const Icon(Icons.refresh, size: 15),
      label: const Text('重置'),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, _FilterChipStyle.height),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: theme.colorScheme.error,
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_FilterChipStyle.radius),
        ),
      ),
    );
  }

  /// 统一下拉筛选按钮：和「標籤」按钮共用同一套外观。
  Widget _buildDropdownFilter({
    required String label,
    required String currentValue,
    required List<Map<String, String>> options,
    required ValueChanged<String> onChanged,
  }) {
    final active = currentValue.isNotEmpty;

    return PopupMenuButton<String>(
      tooltip: label,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      onSelected: onChanged,
      itemBuilder: (context) {
        return _buildMenuItems(
          options: options,
          currentValue: currentValue,
        );
      },
      child: _FilterChip(
        labelPrefix: label,
        text: active ? currentValue : '',
        active: active,
        trailing: Icons.keyboard_arrow_down_rounded,
      ),
    );
  }

  /// 下拉菜单项：统一的圆角、选中高亮和图标。
  List<PopupMenuEntry<String>> _buildMenuItems({
    required List<Map<String, String>> options,
    required String currentValue,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return options.map((o) {
      final value = o['value']!;
      final isCurrent = value == currentValue;

      return PopupMenuItem<String>(
        value: value,
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Icon(
                isCurrent
                    ? Icons.check_rounded
                    : Icons.circle_outlined,
                size: 16,
                color: isCurrent
                    ? theme.colorScheme.primary
                    : (isDark
                        ? Colors.white24
                        : Colors.black26),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  o['label']!,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: isCurrent
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: isCurrent
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }

  Widget _buildTagButton() {
    final active = _selectedTags.isNotEmpty;

    return InkWell(
      onTap: _tagsLoading ? null : _showTagDialog,
      borderRadius: BorderRadius.circular(_FilterChipStyle.radius),
      child: _FilterChip(
        labelPrefix: '標籤',
        text: active ? '已选 ${_selectedTags.length} 个' : '',
        active: active,
        trailing: Icons.keyboard_arrow_down_rounded,
        loading: _tagsLoading,
      ),
    );
  }


  Widget _buildHistoryPanel() {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),      
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.history,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              const Text(
                '搜索历史',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _clearSearchHistory,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('清空'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _searchHistory.map((keyword) {
              return InputChip(
                label: Text(keyword),
                mouseCursor: SystemMouseCursors.click,
                deleteButtonTooltipMessage: '',
                onPressed: () {
                  _controller.text = keyword;
                  _searchFocusNode.unfocus();
                  setState(
                    () => _showHistoryPanel = false,
                  );
                  _search();
                },
                onDeleted: () => _removeSearchHistory(keyword),
                deleteIcon: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: const Icon(Icons.close, size: 16),
                ),
              );
            }).toList(),
          ),                   
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Text('没有找到视频'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.maxWidth;

            // 搜索框宽度：窗口越宽越长，但不会无限拉长
            final searchBoxWidth =
                (availableWidth * 0.40).clamp(260.0, 520.0);

            // 搜索框永远居中，所以它的左边缘就是这个位置。
            // 历史浮层也按这个位置对齐。
            final searchBoxLeft =
                ((availableWidth - searchBoxWidth) / 2)
                    .clamp(0.0, availableWidth);

            return Stack(
              clipBehavior: Clip.none,
              children: [
                // ---- 主内容 ----
                Column(
                  children: [
                    // 搜索框单独占一行并居中：
                    // 这样无论窗口多宽多窄，左右留白都是相等的。
                    // （之前搜索框和筛选栏挤在同一行，宽度一变就偏了）
                    Center(
                      child: SizedBox(
                        height: 56,
                        width: searchBoxWidth,
                        child: TapRegion(
                          groupId: 'search_history',
                          child: TextField(
                            controller: _controller,
                            focusNode: _searchFocusNode,
                            textAlignVertical:
                                TextAlignVertical.center,
                            decoration: InputDecoration(
                              labelText: '主人点击我就能色色了哦',
                              hintText: 'Hentai杂鱼主人又在看羞羞的东西',
                              border: const OutlineInputBorder(),
                              // 给右侧的搜索/清空按钮留出位置，
                              // 否则输入的文字会被按钮压住
                              contentPadding: const EdgeInsets.only(
                                left: 12,
                                right: 88,
                                top: 16,
                                bottom: 16,
                              ),
                              suffixIconConstraints:
                                  const BoxConstraints(
                                minWidth: 0,
                                minHeight: 0,
                              ),
                              suffixIcon: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_controller.text.isNotEmpty)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.clear,
                                        size: 20,
                                      ),
                                      tooltip: '清空',
                                      onPressed: () {
                                        setState(() {
                                          _controller.clear();
                                        });
                                      },
                                    ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.search,
                                      size: 20,
                                    ),
                                    tooltip: '搜索',
                                    onPressed:
                                        _loading ? null : _search,
                                  ),
                                ],
                              ),
                            ),
                            onChanged: (_) {
                              setState(() {});
                            },
                            onTap: () {
                              setState(
                                () => _showHistoryPanel = true,
                              );
                            },
                            onSubmitted: (_) => _search(),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // 筛选栏占满整行并靠左排列：
                    // 不再跟着搜索框一起居中，这样窗口怎么变都是贴左边对齐的。
                    _buildFilterBar(),

                    const SizedBox(height: 20),

                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),

                    // ---- 结果区 ----
                    Expanded(
                      child: _loading
                          ? const Align(
                              alignment: Alignment(0, -0.2),
                              child: Windows11Loading(size: 56),
                            )
                          : _results.isEmpty
                              ? _buildEmptyState()
                              : VideoCardGrid(
                                  videos: _results,
                                  // 竖版栏目（比如新番预告）保持竖版那套，
                                  // 其余一律和首页一样的横版卡片
                                  portrait: _isPortraitCategory,
                                  aspectRatio: _isPortraitCategory
                                      ? 268 / 394
                                      : 16 / 9,
                                  padding: EdgeInsets.zero,
                                  onTap: (video) {
                                    final id = _extractVideoId(
                                      video['url']?.toString() ?? '',
                                    );

                                    if (id == null) return;

                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            VideoDetailPage(videoId: id),
                                      ),
                                    );
                                  },
                                ),
                    ),
                  ],
                ),

                // ---- 搜索历史浮层（Stack 最上层） ----
                if (_showHistoryPanel && _searchHistory.isNotEmpty)
                  Positioned(
                    top: 64,
                    left: searchBoxLeft,
                    width: searchBoxWidth,
                    child: TapRegion(
                      groupId: 'search_history',
                      onTapOutside: (_) {
                        if (mounted) {
                          setState(
                            () => _showHistoryPanel = false,
                          );
                        }
                      },
                      child: Material(
                        elevation: 8,
                        borderRadius: BorderRadius.circular(12),
                        color: Theme.of(context).brightness ==
                                Brightness.dark
                            ? const Color(0xFF2A2A2A)
                            : Colors.white,
                        clipBehavior: Clip.antiAlias,
                        child: _buildHistoryPanel(),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class SearchTagDialog extends StatefulWidget {
  final List<Map<String, dynamic>> groups;
  final List<String> initialTags;
  final bool initialBroad;

  const SearchTagDialog({
    super.key,
    required this.groups,
    required this.initialTags,
    required this.initialBroad,
  });

  @override
  State<SearchTagDialog> createState() =>
      _SearchTagDialogState();
}

class _SearchTagDialogState
    extends State<SearchTagDialog> {
  late Set<String> _selected;
  late bool _broad;

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.initialTags);
    _broad = widget.initialBroad;
  }

  void _toggle(String tag) {
    setState(() {
      if (_selected.contains(tag)) {
        _selected.remove(tag);
      } else {
        _selected.add(tag);
      }
    });
  }

  void _clear() {
    setState(() => _selected.clear());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择标签'),
      content: SizedBox(
        width: 700,
        height: 600,
        child: Column(
          children: [
            Row(
              children: [
                Switch(
                  value: _broad,
                  onChanged: (v) {
                    setState(() => _broad = v);
                  },
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '廣泛配對（符合任一標籤即可，預設需全部符合）',
                  ),
                ),
                TextButton.icon(
                  onPressed: _selected.isEmpty ? null : _clear,
                  icon: const Icon(Icons.clear, size: 18),
                  label: const Text('清空'),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: widget.groups.length,
                itemBuilder: (_, index) {
                  final group = widget.groups[index];
                  final name =
                      group['name']?.toString() ?? '';
                  final tags = List<String>.from(
                    group['tags'] ?? [],
                  );

                  return Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          0,
                          12,
                          0,
                          8,
                        ),
                        child: Text(
                          name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: tags.map((tag) {
                          final checked =
                              _selected.contains(tag);

                          return FilterChip(
                            label: Text(tag),
                            selected: checked,
                            onSelected: (_) => _toggle(tag),
                          );
                        }).toList(),
                      ),
                      const Divider(height: 24),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop({
              'tags': _selected.toList(),
              'broad': _broad,
            });
          },
          child: const Text('確定'),
        ),
      ],
    );
  }
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() =>
      _HistoryPageState();
}

class _HistoryPageState
    extends State<HistoryPage> {
  List<Map<String, dynamic>> _history = [];
  bool _loading = true;

  /// 数据来自哪里。
  ///
  /// - `online`：登录后直接读官网的「觀看紀錄」，和「个人主页 → 观看记录」
  ///   是同一份数据（同一个接口）。
  /// - `local`：未登录时用本地记录兜底
  ///   （本地只记自己看过的，没有账号也就没有官网记录）。
  String _source = 'local';

  int _page = 1;
  int _totalPages = 1;

  bool get _isOnline => _source == 'online';

  @override
  void initState() {
    super.initState();

    // 账号切换后要重新取（这个页面会被重建，但保险起见仍然监听）
    AuthController.account.addListener(_onAccountChanged);

    _loadHistory();
  }

  @override
  void dispose() {
    AuthController.account.removeListener(_onAccountChanged);
    super.dispose();
  }

  void _onAccountChanged() {
    if (mounted) _loadHistory();
  }

  Future<void> _loadHistory({int page = 1}) async {
    final info = AuthController.account.value;

    if (info.loggedIn && info.userId.isNotEmpty) {
      await _loadOnline(info.userId, page: page);
    } else {
      await _loadLocal();
    }
  }

  /// 读官网的观看记录（和个人主页「观看记录」同一个接口、同一份数据）。
  Future<void> _loadOnline(String userId, {int page = 1}) async {
    final target = page < 1 ? 1 : page;

    setState(() {
      _loading = true;
    });

    try {
      final uri = Uri.parse('${AppConfig.backendBase}/api/user/$userId')
          .replace(
        queryParameters: {
          'tab': 'histories',
          'page': '$target',
        },
      );

      final response = await http.get(uri).timeout(
            const Duration(seconds: 90),
          );

      if (response.statusCode != 200) {
        throw Exception('服务器返回错误: ${response.statusCode}');
      }

      final data = jsonDecode(response.body);

      if (data is! Map) {
        throw Exception('返回数据格式不正确');
      }

      final videos = List<Map<String, dynamic>>.from(
        data['videos'] ?? [],
      );

      final totalPages =
          int.tryParse('${data['total_pages']}') ?? 1;

      if (!mounted) return;

      setState(() {
        _history = videos;
        _source = 'online';
        _page = target;
        _totalPages = totalPages < 1 ? 1 : totalPages;
        _loading = false;
      });
    } catch (_) {
      // 网络失败时退回本地，至少还能看到自己看过的
      await _loadLocal();
    }
  }

  /// 未登录时的本地记录。
  Future<void> _loadLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final raw = prefs.getStringList(
            AccountScope.key('watch_history'),
          ) ??
          [];

      final result = <Map<String, dynamic>>[];

      for (final item in raw) {
        try {
          final decoded = jsonDecode(item);

          if (decoded is Map) {
            result.add(Map<String, dynamic>.from(decoded));
          }
        } catch (_) {}
      }

      if (!mounted) return;

      setState(() {
        _history = result;
        _source = 'local';
        _page = 1;
        _totalPages = 1;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String _formatTime(
    String? value,
  ) {
    if (value == null ||
        value.isEmpty) {
      return '';
    }

    final time =
        DateTime.tryParse(value);

    if (time == null) {
      return value;
    }

    final local =
        time.toLocal();

    String two(int n) =>
        n.toString().padLeft(
          2,
          '0',
        );

    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  void _open(
    Map<String, dynamic> item,
  ) {
    // 本地记录存的是 video_id；官网记录给的是 url，这里两种都支持
    var id = item['video_id']?.toString() ?? '';

    if (id.isEmpty) {
      final url = item['url']?.toString() ?? '';

      if (url.isNotEmpty) {
        id = Uri.tryParse(url)?.queryParameters['v'] ?? '';
      }
    }

    if (id.isEmpty) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoDetailPage(videoId: id),
      ),
    ).then((_) => _loadHistory());
  }

  Future<void> _clearHistory() async {
    // 官网的观看记录只能到官网上清，本地没有权限改，
    // 所以登录状态下不发这个按钮（见 build）。
    if (_isOnline) return;

    final prefs = await SharedPreferences.getInstance();

    await prefs.remove(
      AccountScope.key('watch_history'),
    );

    if (mounted) {
      setState(() => _history = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Windows11Loading(size: 48),
      );
    }

    if (_history.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadHistory,
        child: ListView(
          children: [
            const SizedBox(height: 180),
            Center(
              child: Text(
                _isOnline ? '这个账号还没有观看记录' : '暂无观看记录',
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // 「观看记录（与个人主页一致）」那行说明文字去掉了 ——
        // 侧边栏已经写着"观看记录"，顶上再挂一行只是白占地方。
        // 「清空历史」是有用的功能，保留，靠右对齐。
        // （只在本地记录时才有，官网记录要去官网上清）
        if (!_isOnline)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _clearHistory,
                icon: const Icon(Icons.delete_outline),
                label: const Text('清空历史'),
              ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding:
                const EdgeInsets.all(24),
            itemCount:
                _history.length,
            itemBuilder: (_, index) {
              final item =
                  _history[index];

              final title =
                  item['title']
                          ?.toString() ??
                      '';

              final thumbnail =
                  item['thumbnail']
                          ?.toString() ??
                      '';

              final brand =
                  item['brand']
                          ?.toString() ??
                      '';

              final lastWatched =
                  item['last_watched']
                      ?.toString();

              // 官网记录带的是时长/播放量，本地记录带的是品牌/观看时间
              final duration =
                  item['duration']?.toString() ?? '';

              final views =
                  item['views']?.toString() ?? '';

              // 用 Row 手写而不是 ListTile：
              // ListTile 会对 leading 施加自己的尺寸约束，
              // 我们想要的 16:9 缩略图有可能被压/被裁。
              // 手写 Row 能保证缩略图就是固定 160x90（16:9）。
              final meta = [
                if (brand.isNotEmpty) '品牌：$brand',
                if (lastWatched != null)
                  '观看时间：${_formatTime(lastWatched)}',
                if (_isOnline) ...[
                  if (duration.isNotEmpty) duration,
                  if (views.isNotEmpty) views,
                ],
              ];

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _open(item),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 缩略图固定 16:9，和首页/个人中心保持一致
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            width: 160,
                            height: 90,
                            child: thumbnail.isNotEmpty
                                ? Image.network(
                                    thumbnail,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Container(
                                      color: Colors.black12,
                                      alignment: Alignment.center,
                                      child: const Icon(
                                        Icons.broken_image,
                                      ),
                                    ),
                                  )
                                : Container(
                                    color: Colors.black12,
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      Icons.play_circle_outline,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (meta.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  meta.join('\n'),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.5,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.62),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        // 官网观看记录每页 60 条，页数多，必须能翻页
        if (_isOnline)
          PagerBar(
            page: _page,
            totalPages: _totalPages,
            loading: _loading,
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            onGoToPage: (target) => _loadHistory(page: target),
          ),
      ],
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 后端设置（下载目录）
  String _downloadDir = '';
  String _defaultDownloadDir = '';
  String _hanimeRoot = '';
  bool _settingsLoading = true;

  /// 缓存情况
  int _cacheEntries = 0;
  Map<String, dynamic> _cacheDetail = {};
  bool _cacheLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBackendSettings();
    _loadCacheStats();
  }

  Future<void> _loadBackendSettings() async {
    try {
      final response = await http
          .get(Uri.parse('${AppConfig.backendBase}/api/settings'))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final data = jsonDecode(response.body);

      if (!mounted) return;

      setState(() {
        _downloadDir = data['download_dir']?.toString() ?? '';
        _defaultDownloadDir =
            data['default_download_dir']?.toString() ?? '';
        _hanimeRoot = data['hanime_root']?.toString() ?? '';
        _settingsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() => _settingsLoading = false);
    }
  }

  Future<void> _loadCacheStats() async {
    setState(() => _cacheLoading = true);

    try {
      final response = await http
          .get(Uri.parse('${AppConfig.backendBase}/api/cache_stats'))
          .timeout(const Duration(seconds: 30));

      final data = jsonDecode(response.body);

      if (!mounted) return;

      setState(() {
        _cacheDetail = Map<String, dynamic>.from(data);
        _cacheEntries = _countCacheEntries(data);
        _cacheLoading = false;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() => _cacheLoading = false);
    }
  }

  /// 后端返回的是 {"home": {"entries": N, "hits": ...}, ...} 这种嵌套结构
  int _countCacheEntries(dynamic data) {
    if (data is! Map) return 0;

    var total = 0;

    for (final value in data.values) {
      if (value is Map) {
        final n = value['entries'];

        if (n is int) total += n;
      } else if (value is int) {
        total += value;
      }
    }

    return total;
  }

  int _entriesOf(String key) {
    final value = _cacheDetail[key];

    if (value is Map) {
      final n = value['entries'];

      if (n is int) return n;
    }

    return 0;
  }

  Future<void> _clearCache() async {
    try {
      await http
          .get(Uri.parse('${AppConfig.backendBase}/api/cache_clear'))
          .timeout(const Duration(seconds: 60));

      // 客户端自己那层缓存也一起清掉，不然界面还是旧的
      AppCache.clear();

      if (!mounted) return;

      AppToast.success(context, '缓存已清空');

      await _loadCacheStats();
    } catch (e) {
      if (mounted) AppToast.error(context, '清空失败：$e');
    }
  }

  Future<void> _changeDownloadDir() async {
    final controller = TextEditingController(text: _downloadDir);

    final target = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改下载目录'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '目录路径',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '目录不存在会自动建出来。默认是 $_defaultDownloadDir',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_defaultDownloadDir),
            child: const Text('恢复默认'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    controller.dispose();

    if (target == null || target.isEmpty || !mounted) return;

    if (target == _downloadDir) return;

    try {
      final response = await http
          .post(
            Uri.parse('${AppConfig.backendBase}/api/settings'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'download_dir': target}),
          )
          .timeout(const Duration(seconds: 60));

      final data = jsonDecode(response.body);

      if (!mounted) return;

      if (response.statusCode != 200) {
        throw Exception(
          data is Map ? (data['detail'] ?? '保存失败') : '保存失败',
        );
      }

      setState(() => _downloadDir = data['download_dir']?.toString() ?? target);

      AppToast.success(context, '下载目录已修改');
    } catch (e) {
      if (mounted) AppToast.error(context, '$e');
    }
  }

  Future<void> _openDownloadDir() async {
    if (_downloadDir.isEmpty) return;

    try {
      // 目录可能还没建（一次都没下载过），先让后端建出来
      await http
          .post(
            Uri.parse('${AppConfig.backendBase}/api/settings'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'download_dir': _downloadDir}),
          )
          .timeout(const Duration(seconds: 30));

      await Process.run('explorer.exe', [_downloadDir]);

      if (mounted) AppToast.success(context, '已打开下载目录');
    } catch (e) {
      if (mounted) AppToast.error(context, '打不开：$e');
    }
  }

  Widget _sectionTitle(String title, [String? subtitle]) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 28),
        Text(
          title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }

  /// 一行设置项：左边图标 + 标题/说明，右边是当前值（可点开选择）
  Widget _settingTile({
    required IconData icon,
    required String title,
    required String value,
    String subtitle = '',
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(title),
        subtitle: subtitle.isEmpty
            ? null
            : Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: trailing ??
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (onTap != null) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ],
            ),
        onTap: onTap,
      ),
    );
  }

  /// 让用户拖着重排首页栏目。
  ///
  /// 栏目名从首页的缓存里拿（设置页自己没有那份数据）；
  /// 缓存过期了（5 分钟）就现拉一次接口 —— 排顺序只需要栏目名。
  ///
  /// 拖动是**即时生效**的：每拖一次就写一次设置，首页那边监听着立刻重排。
  /// 不搞「保存/取消」那一套，省得用户拖完忘了点保存。
  Future<void> _reorderHomeSections() async {
    final names = await _loadHomeSectionNames();

    if (!mounted) return;

    if (names.isEmpty) {
      AppToast.error(
        context,
        '还没拿到首页栏目。先打开一次「首页」再回来排。',
      );

      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _HomeSectionOrderDialog(names: names),
    );
  }

  /// 取首页栏目名（按用户已经排过的顺序）。
  Future<List<String>> _loadHomeSectionNames() async {
    List<String> namesOf(List<dynamic> raw) => [
          for (final item in raw)
            if (item is Map && (item['name']?.toString() ?? '').isNotEmpty)
              item['name'].toString(),
        ];

    final cached = AppCache.get(AppCache.homeSectionsKey);

    if (cached is List && cached.isNotEmpty) {
      return AppSettings.applyHomeOrder<String>(
        namesOf(cached),
        (name) => name,
      );
    }

    try {
      final response = await http.get(
        Uri.parse('${AppConfig.backendBase}/api/home_sections'),
      );

      if (response.statusCode != 200) return const [];

      final data = jsonDecode(response.body);

      final sections = List<Map<String, dynamic>>.from(
        data['sections'] ?? [],
      );

      if (sections.isEmpty) return const [];

      AppCache.set(
        AppCache.homeSectionsKey,
        sections,
        ttl: AppCache.homeTtl,
      );

      return AppSettings.applyHomeOrder<String>(
        [
          for (final section in sections)
            if ((section['name']?.toString() ?? '').isNotEmpty)
              section['name'].toString(),
        ],
        (name) => name,
      );
    } catch (_) {
      return const [];
    }
  }

  /// 从一组选项里挑一个
  Future<T?> _pickOption<T>({
    required String title,
    required List<T> options,
    required T current,
    required String Function(T) label,
  }) {
    return showDialog<T>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          for (final option in options)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(option),
              child: Row(
                children: [
                  Icon(
                    option == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: option == current
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Text(label(option)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          '外观',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '选择应用的配色方案',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        ValueListenableBuilder<ThemeMode>(
          valueListenable: ThemeController.mode,
          builder: (context, mode, _) {
            return Column(
              children: [
                _ThemeOptionTile(
                  icon: Icons.brightness_auto,
                  title: '跟随系统',
                  subtitle: '根据系统设置自动切换',
                  selected: mode == ThemeMode.system,
                  onTap: () => ThemeController.setMode(
                    ThemeMode.system,
                  ),
                ),
                _ThemeOptionTile(
                  icon: Icons.light_mode_outlined,
                  title: '浅色',
                  subtitle: '始终使用浅色主题',
                  selected: mode == ThemeMode.light,
                  onTap: () => ThemeController.setMode(
                    ThemeMode.light,
                  ),
                ),
                _ThemeOptionTile(
                  icon: Icons.dark_mode_outlined,
                  title: '深色',
                  subtitle: '始终使用深色主题',
                  selected: mode == ThemeMode.dark,
                  onTap: () => ThemeController.setMode(
                    ThemeMode.dark,
                  ),
                ),
              ],
            );
          },
        ),

        // ---------------- 首页 ----------------
        _sectionTitle('首页', '首页上各栏目的顺序'),

        ValueListenableBuilder<List<String>>(
          valueListenable: AppSettings.homeSectionOrder,
          builder: (context, order, _) => _settingTile(
            icon: Icons.reorder,
            title: '栏目排序',
            subtitle: '拖动调整首页栏目的先后（视频跟着栏目一起走）',
            value: order.isEmpty ? '网站默认' : '已自定义 ${order.length} 项',
            onTap: _reorderHomeSections,
          ),
        ),

        // ---------------- 播放器 ----------------
        _sectionTitle('播放器', '键盘快捷键和播放行为'),

        ValueListenableBuilder<int>(
          valueListenable: AppSettings.seekStep,
          builder: (context, step, _) => _settingTile(
            icon: Icons.fast_forward_outlined,
            title: '左右键快进步长',
            subtitle: '按一下 ← / → 跳过多少秒',
            value: '$step 秒',
            onTap: () async {
              final picked = await _pickOption<int>(
                title: '左右键快进步长',
                options: AppSettings.seekStepOptions,
                current: step,
                label: (v) => '$v 秒',
              );

              if (picked != null) await AppSettings.setSeekStep(picked);
            },
          ),
        ),

        ValueListenableBuilder<double>(
          valueListenable: AppSettings.holdSpeed,
          builder: (context, speed, _) => _settingTile(
            icon: Icons.speed,
            title: '长按右键倍速',
            subtitle: '按住 → 不放时的播放速度',
            value: '${speed}x',
            onTap: () async {
              final picked = await _pickOption<double>(
                title: '长按右键倍速',
                options: AppSettings.holdSpeedOptions,
                current: speed,
                label: (v) => '${v}x',
              );

              if (picked != null) await AppSettings.setHoldSpeed(picked);
            },
          ),
        ),

        ValueListenableBuilder<bool>(
          valueListenable: AppSettings.autoResume,
          builder: (context, enabled, _) => _settingTile(
            icon: Icons.restore,
            title: '自动续播',
            subtitle: '打开影片时从上次看到的位置继续',
            value: enabled ? '已开启' : '已关闭',
            trailing: Switch(
              value: enabled,
              onChanged: (v) => AppSettings.setAutoResume(v),
            ),
          ),
        ),

        // ---------------- 下载 ----------------
        _sectionTitle('下载', '文件保存位置和默认清晰度'),

        _settingTile(
          icon: Icons.folder_outlined,
          title: '下载目录',
          subtitle: _settingsLoading ? '读取中…' : _downloadDir,
          value: '',
          trailing: _settingsLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '打开目录',
                      onPressed: _downloadDir.isEmpty
                          ? null
                          : _openDownloadDir,
                      icon: const Icon(Icons.open_in_new, size: 20),
                    ),
                    IconButton(
                      tooltip: '修改',
                      onPressed: _changeDownloadDir,
                      icon: const Icon(Icons.edit_outlined, size: 20),
                    ),
                  ],
                ),
        ),

        ValueListenableBuilder<String>(
          valueListenable: AppSettings.downloadQuality,
          builder: (context, quality, _) => _settingTile(
            icon: Icons.high_quality_outlined,
            title: '默认下载清晰度',
            subtitle: '下载时默认选中的清晰度',
            value: quality.isEmpty ? '最高可用' : quality,
            onTap: () async {
              final picked = await _pickOption<String>(
                title: '默认下载清晰度',
                options: const ['', '1080p', '720p', '480p'],
                current: quality,
                label: (v) => v.isEmpty ? '最高可用' : v,
              );

              if (picked != null) {
                await AppSettings.setDownloadQuality(picked);
              }
            },
          ),
        ),

        // ---------------- 缓存 ----------------
        _sectionTitle('缓存', '后端会把取到的页面缓存一段时间，避免重复访问网站'),

        _settingTile(
          icon: Icons.cleaning_services_outlined,
          title: '清空接口缓存',
          subtitle: _cacheLoading
              ? '统计中…'
              : '当前缓存 $_cacheEntries 项'
                  '（详情 ${_entriesOf('detail')} / 搜索 ${_entriesOf('search')} / 首页 ${_entriesOf('home')} / 清单 ${_entriesOf('playlist')}）',
          value: '',
          trailing: FilledButton.tonal(
            onPressed: _cacheLoading ? null : _clearCache,
            child: const Text('清空'),
          ),
        ),

        // ---------------- 关于 ----------------
        _sectionTitle('关于'),

        _settingTile(
          icon: Icons.folder_special_outlined,
          title: '应用数据目录',
          subtitle: _hanimeRoot.isEmpty ? '读取中…' : _hanimeRoot,
          value: '',
        ),
      ],
    );
  }
}

class _ThemeOptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeOptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.1)
            : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            decoration: BoxDecoration(
              border: Border.all(
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: selected
                              ? theme.colorScheme.primary
                              : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Icon(
                    Icons.check_circle,
                    color: theme.colorScheme.primary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


class VideoDetailPage
    extends StatefulWidget {
  final String videoId;

  const VideoDetailPage({
    super.key,
    required this.videoId,
  });

  @override
  State<VideoDetailPage>
      createState() =>
          _VideoDetailPageState();
}

class _VideoDetailPageState
    extends State<VideoDetailPage> {
  Map<String, dynamic>? _video;

  List<Map<String, dynamic>> _playlist = [];

  bool _loading = true;
  String? _error;

  /// 下载进行中 + 百分比
  bool _downloading = false;
  int _downloadPercent = 0;

  /// 当前账号对这部影片的互动状态（用来点亮图标）
  bool _liked = false;
  bool _saved = false;
  String _savedPlaylist = '';

  VideoPlayerController?
      _videoPlayerController;

  DateTime? _lastSavedPosition;

  bool _showVideoCover = true;

  /// 播完当前影片是否自动播下一集（目前固定开启，暂无设置项）
  final bool _autoPlayNext = true;

  final ScrollController _playlistScrollController =
      ScrollController();

  final Map<String, GlobalKey> _playlistKeys = {};

  // 音量沿用上次的（用户要求记住上次播放设置的音量）
  double _volume = AppSettings.lastVolume.value;

  /// 音量提示：放进播放器自己的 Stack 里，才跟得上播放器的位置
  final VolumeToastController _volumeToast = VolumeToastController();

  bool _showVolumeSlider = false;
  Timer? _volumeHideTimer;
  bool _showControls = true;
  Timer? _controlsTimer;

  List<Map<String, dynamic>> _availableSources = [];
  String _currentQuality = '';
  bool _switchingQuality = false;
  bool _progressHovering = false;
  double _progressHoverRatio = 0.0;

  @override
  void initState() {
    super.initState();
    _loadVideo();
  }

  Future<void> _loadVideo() async {
    try {
      final uri = Uri.parse(
        '${AppConfig.backendBase}/api/video/${widget.videoId}',
      );

      final response =
          await http.get(uri);

      if (response.statusCode != 200) {
        throw Exception(
          '服务器返回错误: ${response.statusCode}',
        );
      }

      final data =
          jsonDecode(response.body);

      final playlist =
          List<Map<String, dynamic>>.from(
        data['playlist'] ?? [],
      );

      if (!mounted) return;

      setState(() {
        _video =
            Map<String, dynamic>.from(
          data,
        );

        _playlist = playlist;

        // 互动状态直接来自详情接口（后端已从 HTML 里解析好），
        // 不再单独调 /state 导航浏览器。
        _liked = data['liked'] == true;
        _saved = data['saved'] == true;
        _savedPlaylist = data['saved_playlist']?.toString() ?? '';

        _availableSources =
            List<Map<String, dynamic>>.from(
          data['sources'] ?? [],
        );

        if (_availableSources.isNotEmpty) {
          _currentQuality =
              _availableSources.first['quality']
                      ?.toString() ??
                  '';
        }
      });

      // 详情数据到位后把「正在播放的这一个」滚到列表中间。
      // 等一帧再开始，因为上面这次 setState 还没触发 build。
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCurrentVideo(),
      );

      final videoSource =
          data['video_source']
                  ?.toString() ??
              '';

      if (videoSource.isEmpty) {
        throw Exception(
          '没有获取到视频地址',
        );
      }

      await _saveToWatchHistory(
        data,
      );

      await _initializePlayer(
        videoSource,
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error =
            '加载视频详情失败：$e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _saveToWatchHistory(
    Map<String, dynamic> data,
  ) async {
    final prefs =
        await SharedPreferences
            .getInstance();

    final history =
        prefs.getStringList(
              AccountScope.key('watch_history'),
            ) ??
            [];

    final title =
        data['title']
                ?.toString() ??
            '';

    final thumbnail =
        data['thumbnail']
                ?.toString() ??
            '';

    final brand =
        data['brand']
                ?.toString() ??
            '';

    final item = jsonEncode({
      'video_id':
          widget.videoId,
      'title': title,
      'thumbnail':
          thumbnail,
      'brand': brand,
      'last_watched':
          DateTime.now()
              .toIso8601String(),
    });

    history.removeWhere((value) {
      try {
        final oldItem =
            jsonDecode(value);

        return oldItem[
                    'video_id']
                ?.toString() ==
            widget.videoId;
      } catch (_) {
        return false;
      }
    });

    history.insert(
      0,
      item,
    );

    if (history.length > 100) {
      history.removeRange(
        100,
        history.length,
      );
    }

    await prefs.setStringList(
      AccountScope.key('watch_history'),
      history,
    );
  }

  Future<void> _initializePlayer(
    String videoSource,
  ) async {
    final uri =
        Uri.tryParse(videoSource);

    if (uri == null) {
      throw Exception(
        '视频地址无效',
      );
    }

    final controller =
        VideoPlayerController
            .networkUrl(uri);

    _videoPlayerController =
        controller;

    await controller.initialize();

    // 把上次记住的音量**真正设到播放器上**。
    //
    // 少了这一句就会出现：界面音量图标显示静音（因为 _volume 是 0），
    // 但视频照样出声 —— 播放器还停在默认的满音量。
    // 以前只有切画质 / 点静音 / 拖滑块时才 setVolume，
    // 所以"上次设成静音、重启进来还是有声音"。
    await controller.setVolume(_volume);

    await _restorePlaybackPosition();

    controller.addListener(
      _onVideoPositionChanged,
    );

    controller.addListener(
      _onVideoCompleted,
    );

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _changeQuality(String newQuality) async {
    if (_switchingQuality) {
      return;
    }

    final source = _availableSources.firstWhere(
      (s) => s['quality'] == newQuality,
      orElse: () => <String, dynamic>{},
    );

    final newUrl = source['url']?.toString();

    if (newUrl == null || newUrl.isEmpty) {
      return;
    }

    final oldController = _videoPlayerController;

    if (oldController == null) {
      return;
    }

    final wasPlaying = oldController.value.isPlaying;
    final position = oldController.value.position;

    setState(() {
      _currentQuality = newQuality;
      _switchingQuality = true;
    });

    // 移除旧监听，避免 dispose 后仍被回调
    oldController.removeListener(_onVideoPositionChanged);
    oldController.removeListener(_onVideoCompleted);

    // 先准备好新控制器（此时 UI 显示中转画面，不再引用旧控制器）
    final newController = VideoPlayerController.networkUrl(
      Uri.parse(newUrl),
    );

    await newController.initialize();
    await newController.seekTo(position);
    newController.setVolume(_volume);

    newController.addListener(_onVideoPositionChanged);
    newController.addListener(_onVideoCompleted);

    _videoPlayerController = newController;

    if (wasPlaying) {
      await newController.play();
    }

    // 新控制器就绪后，才销毁旧的
    await oldController.pause();
    await oldController.dispose();

    if (mounted) {
      setState(() {
        _switchingQuality = false;
      });
    }
  }
  
  Future<void>
      _restorePlaybackPosition() async {
    final controller =
        _videoPlayerController;

    if (controller == null ||
        !controller
            .value
            .isInitialized) {
      return;
    }

    final prefs =
        await SharedPreferences
            .getInstance();

    // 播放进度也要跟着账号走：
    // 同一个影片，账号 A 看到 12:30，账号 B 不该被带过去
    final key = AccountScope.scopedKey(
      'video_position',
      widget.videoId,
    );

    // 用户可以在设置里关掉自动续播
    if (!AppSettings.autoResume.value) return;

    final savedSeconds =
        prefs.getInt(key);

    if (savedSeconds == null ||
        savedSeconds <= 0) {
      return;
    }

    final duration =
        controller.value.duration;

    if (duration ==
        Duration.zero) {
      return;
    }

    final savedPosition =
        Duration(
      seconds: savedSeconds,
    );

    if (savedPosition < duration) {
      await controller.seekTo(
        savedPosition,
      );
    }
  }

  void _onVideoPositionChanged() {
    final controller = _videoPlayerController;

    if (controller == null ||
        !controller.value.isInitialized) {
      return;
    }

    final position = controller.value.position;

    if (position <= Duration.zero) {
      return;
    }

    final now = DateTime.now();

    if (_lastSavedPosition != null &&
        now.difference(_lastSavedPosition!).inSeconds < 2) {
      return;
    }

    _lastSavedPosition = now;

    _savePlaybackPosition();

    if (controller.value.position >= controller.value.duration) {
      _onVideoCompleted();
    }
  }

  void _onVideoCompleted() {
    final controller = _videoPlayerController;

    if (controller == null ||
        !controller.value.isInitialized) {
      return;
    }

    if (!_autoPlayNext) {
      return;
    }

    if (controller.value.position >=
        controller.value.duration) {
      _playNextVideo();
    }
  }

  Future<void> _playNextVideo() async {
    final currentIndex =
        _playlist.indexWhere(
      (item) =>
          item['video_id']?.toString() ==
          widget.videoId,
    );

    if (currentIndex == -1) {
      return;
    }

    final nextIndex = currentIndex - 1;

    if (nextIndex < 0) {
      return;
    }

    final nextVideoId =
        _playlist[nextIndex]['video_id']
            ?.toString();

    if (nextVideoId == null ||
        nextVideoId.isEmpty) {
      return;
    }

    await Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) =>
            VideoDetailPage(
          videoId: nextVideoId,
        ),
      ),
    );
  }

  Future<void>
      _savePlaybackPosition() async {
    final controller =
        _videoPlayerController;

    if (controller == null ||
        !controller
            .value
            .isInitialized) {
      return;
    }

    final position =
        controller.value.position;

    if (position <=
        Duration.zero) {
      return;
    }

    final prefs =
        await SharedPreferences
            .getInstance();

    // 播放进度也要跟着账号走：
    // 同一个影片，账号 A 看到 12:30，账号 B 不该被带过去
    final key = AccountScope.scopedKey(
      'video_position',
      widget.videoId,
    );

    await prefs.setInt(
      key,
      position.inSeconds,
    );
  }

  Future<void> _startVideo() async {
    final controller =
        _videoPlayerController;

    if (controller == null ||
        !controller
            .value
            .isInitialized) {
      return;
    }

    setState(() {
      _showVideoCover = false;
    });

    await controller.play();
  }

  Future<void> _openPlaylistVideo(
    String videoId,
  ) async {
    if (videoId.isEmpty ||
        videoId == widget.videoId) {
      return;
    }

    await Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) =>
            VideoDetailPage(
          videoId: videoId,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _savePlaybackPosition();

    _controlsTimer?.cancel();
    _volumeHideTimer?.cancel();

    _videoPlayerController
        ?.removeListener(
      _onVideoPositionChanged,
    );

    _videoPlayerController
        ?.dispose();

    _playlistScrollController.dispose();
    _volumeToast.dispose();

    super.dispose();
  }

  String _formatDuration(Duration duration) {
    return formatPlaybackDuration(duration);
  }

  void _showPlayerControls() {
    setState(() {
      _showControls = true;
    });

    _controlsTimer?.cancel();
    _controlsTimer = Timer(
      const Duration(seconds: 3),
      () {
        if (mounted) {
          setState(() {
            _showControls = false;
          });
        }
      },
    );
  }

  Widget _buildVideoPlayer() {
    if (_switchingQuality) {
      return Container(
        width: double.infinity,
        height: 420,
        color: Colors.black,
        alignment: Alignment.center,
        child: const Windows11Loading(
          size: 48,
          color: Colors.white,
        ),
      );
    }

    final controller = _videoPlayerController;

    if (controller == null || !controller.value.isInitialized) {
      return Container(
        width: double.infinity,
        height: 420,
        color: Colors.black,
        alignment: Alignment.center,
        child: const Windows11Loading(
          size: 48,
          color: Colors.white,
        ),
      );
    }

    final thumbnail =
        _video?['thumbnail']?.toString() ?? '';

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: Colors.black),
            MouseRegion(
              onHover: (_) => _showPlayerControls(),
              child: Center(
                child: AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              ),
            ),
            ValueListenableBuilder(
              valueListenable: controller,
              builder: (context, value, child) {
                if (!value.isInitialized ||
                    value.duration.inMilliseconds <= 0) {
                  return const SizedBox();
                }

                final progress = value.position.inMilliseconds /
                    value.duration.inMilliseconds;

                return Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _showControls ? 0.0 : 1.0,
                      duration: const Duration(milliseconds: 200),
                      child: LinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        minHeight: 4,
                        backgroundColor: Colors.white24,
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(
                          Colors.red,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            if (_showControls)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildPlayerControls(),
              ),
            if (_showVideoCover)
              Positioned.fill(
                child: GestureDetector(
                  onTap: _startVideo,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (thumbnail.isNotEmpty)
                        Image.network(
                          thumbnail,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: Colors.black,
                          ),
                        )
                      else
                        Container(color: Colors.black),
                      Container(color: Colors.black26),
                      const Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Icon(
                              Icons.play_arrow,
                              color: Colors.white,
                              size: 42,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // 调音量时在**播放器正中**显示（不是整页正中）。
            // 放在这个 Stack 的最后，才会盖在画面和控制条上面。
            _buildVolumeToast(),
          ],
        ),
      ),
    );
  }

  /// 音量提示：跟着播放器走，窗口缩放时位置和大小都跟着变
  Widget _buildVolumeToast() {
    return ListenableBuilder(
      listenable: _volumeToast,
      builder: (context, _) {
        if (!_volumeToast.visible) return const SizedBox.shrink();

        return Positioned.fill(
          child: IgnorePointer(
            child: Center(
              child: VolumeToast(volume: _volumeToast.volume!),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlayerControls() {
    final controller = _videoPlayerController;

    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }

    final position = controller.value.position;
    final duration = controller.value.duration;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IgnorePointer(
          child: Container(
            height: 16,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black54,
                ],
              ),
            ),
          ),
        ),
        Container(
          color: Colors.black54,
          padding: const EdgeInsets.only(left: 4, right: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final trackWidth = constraints.maxWidth;

                  return MouseRegion(
                    onHover: (event) {
                      final dx = event.localPosition.dx;
                      final ratio = (dx / trackWidth).clamp(0.0, 1.0);

                      if (!_progressHovering ||
                          (_progressHoverRatio - ratio).abs() > 0.002) {
                        setState(() {
                          _progressHovering = true;
                          _progressHoverRatio = ratio;
                        });
                      }
                    },
                    onExit: (_) {
                      if (_progressHovering) {
                        setState(() {
                          _progressHovering = false;
                        });
                      }
                    },
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        VideoProgressIndicator(
                          controller,
                          allowScrubbing: true,
                          padding: const EdgeInsets.symmetric(vertical: 2),
                        ),
                        if (_progressHovering)
                          Positioned(
                            left: (trackWidth * _progressHoverRatio - 30)
                                .clamp(0.0, trackWidth - 60),
                            top: -26,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                _formatDuration(
                                  Duration(
                                    milliseconds: (duration.inMilliseconds *
                                            _progressHoverRatio)
                                        .round(),
                                  ),
                                ),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
              Row(
                children: [
                  IconButton(
                    color: Colors.white,
                    icon: Icon(
                      controller.value.isPlaying
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                    onPressed: () {
                      setState(() {
                        if (controller.value.isPlaying) {
                          controller.pause();
                        } else {
                          controller.play();
                          _showVideoCover = false;
                        }
                      });
                    },
                  ),
                  MouseRegion(
                    onEnter: (_) {
                      _volumeHideTimer?.cancel();
                      if (!_showVolumeSlider) {
                        setState(() => _showVolumeSlider = true);
                      }
                    },
                    onExit: (_) {
                      _volumeHideTimer?.cancel();
                      _volumeHideTimer = Timer(
                        const Duration(milliseconds: 150),
                        () {
                          if (mounted && _showVolumeSlider) {
                            setState(() => _showVolumeSlider = false);
                          }
                        },
                      );
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          color: Colors.white,
                          icon: Icon(
                            _volume == 0
                                ? Icons.volume_off
                                : Icons.volume_up,
                          ),
                          onPressed: () {
                            setState(() {
                              _volume = _volume == 0 ? 1 : 0;
                              controller.setVolume(_volume);
                              AppSettings.setLastVolume(_volume);
                            });
                          },
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                          alignment: Alignment.centerLeft,
                          child: _showVolumeSlider
                              ? SizedBox(
                                  width: 80,
                                  height: 40,
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 2.0,
                                      activeTrackColor: Colors.red,
                                      inactiveTrackColor: Colors.white24,
                                      thumbColor: Colors.red,
                                      overlayColor:
                                          Colors.red.withValues(alpha: 0.2),
                                      thumbShape:
                                          const RoundSliderThumbShape(
                                        enabledThumbRadius: 6.0,
                                      ),
                                      overlayShape:
                                          const RoundSliderOverlayShape(
                                        overlayRadius: 12.0,
                                      ),
                                    ),
                                    child: Slider(
                                      value: _volume,
                                      min: 0,
                                      max: 1,
                                      onChanged: (value) {
                                        setState(() {
                                          _volume = value;
                                          controller.setVolume(value);
                                        });

                                        AppSettings.setLastVolume(value);
                                      },
                                    ),
                                  ),
                                )
                              : const SizedBox(width: 0, height: 40),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      '${_formatDuration(position)} / ${_formatDuration(duration)}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  const Spacer(),
                  if (_availableSources.isNotEmpty)
                    PopupMenuButton<String>(
                      icon: const Icon(
                        Icons.high_quality,
                        color: Colors.white,
                      ),
                      tooltip: '选择画质',
                      onSelected: _changeQuality,
                      itemBuilder: (context) {
                        return _availableSources.map((source) {
                          final quality =
                              source['quality']?.toString() ?? '';

                          return PopupMenuItem<String>(
                            value: quality,
                            child: Row(
                              children: [
                                if (quality == _currentQuality)
                                  const Icon(
                                    Icons.check,
                                    size: 18,
                                    color: Colors.green,
                                  )
                                else
                                  const SizedBox(width: 18),
                                const SizedBox(width: 8),
                                Text(quality),
                              ],
                            ),
                          );
                        }).toList();
                      },
                    ),
                  IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.fullscreen),
                    onPressed: _showFullscreenPlayer,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showFullscreenPlayer() async {
    final controller = _videoPlayerController;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    await windowManager.setFullScreen(true);

    // setFullScreen 是异步的，这期间页面可能已经被关掉，
    // 所以用 context 之前必须确认还挂着。
    if (!mounted) return;

    final navigator = Navigator.of(context);

    await navigator.push(
      MaterialPageRoute(
        builder: (_) => _FullscreenPlayerPage(
          controller: controller,
          availableSources: _availableSources,
          currentQuality: _currentQuality,
          volume: _volume,
          onControllerChanged: (newController, newQuality) {
            if (!mounted) return;

            setState(() {
              _videoPlayerController = newController;
              _currentQuality = newQuality;
            });

            newController.addListener(_onVideoPositionChanged);
            newController.addListener(_onVideoCompleted);
          },
          onVolumeChanged: (newVolume) {
            if (!mounted) return;

            setState(() {
              _volume = newVolume;
            });

            AppSettings.setLastVolume(newVolume);
          },
        ),
      ),
    );

    await windowManager.setFullScreen(false);
  }
  /// 把「正在播放的这一个」滚到列表中间。
  ///
  /// 两个坑：
  ///  1. 数据刚 setState 完时 ListView 还没 build，GlobalKey 的
  ///     currentContext 是 null —— 只试一次会静默失败。所以这里重试几帧。
  ///  2. 列表是懒加载的：当前项如果还没被创建，ensureVisible 也无从下手。
  ///     所以先在**外层**滚动容器里滚到面板位置，让列表有机会渲染出来，
  ///     再对列表内部做居中对齐。
  void _scrollToCurrentVideo({int attempt = 0}) {
    if (!mounted || attempt > 12) return;

    final key = _playlistKeys[widget.videoId];
    final context = key?.currentContext;

    if (context == null) {
      // 还没建出来，下一帧再试
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCurrentVideo(attempt: attempt + 1),
      );

      return;
    }

    // 让列表里这一项居中（alignment 0.5 = 居中）
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
      alignment: 0.5,
    );
  }

  Widget _buildPlaylistPanel() {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.stretch,
        children: [
          Container(
            padding:
                const EdgeInsets.fromLTRB(
              14,
              12,
              14,
              12,
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.playlist_play,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '播放清单',
                    style:
                        const TextStyle(
                      fontSize: 16,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  '${_playlist.length} 集',
                  style: TextStyle(
                    fontSize: 13,
                    color:
                        Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
          const Divider(
            height: 1,
          ),
          if (_playlist.isEmpty)
            const Padding(
              padding:
                  EdgeInsets.all(20),
              child: Text(
                '没有获取到播放清单',
                textAlign:
                    TextAlign.center,
              ),
            )
          else
            ConstrainedBox(
              constraints:
                  const BoxConstraints(
                maxHeight: 520,
              ),
              child: ListView.builder(
                controller: _playlistScrollController,
                shrinkWrap: true,
                itemCount:
                    _playlist.length,
                itemBuilder: (
                  context,
                  index,
                ) {
                  return _buildPlaylistItem(
                    _playlist[index],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlaylistItem(
    Map<String, dynamic> item,
  ) {
    final videoId =
        item['video_id']
                ?.toString() ??
            '';

    final title =
        item['title']
                ?.toString() ??
            '';

    final thumbnail =
        item['thumbnail']
                ?.toString() ??
            '';

    final duration =
        item['duration']
                ?.toString() ??
            '';

    final rating =
        item['rating']
                ?.toString() ??
            '';

    final views =
        item['views']
                ?.toString() ??
            '';

    final current =
        videoId == widget.videoId;

    final itemKey =
        _playlistKeys.putIfAbsent(
          videoId,
          () => GlobalKey(),
        );

    return Material(
      key: itemKey,
      color: current
          ? Theme.of(context)
              .colorScheme
              .primaryContainer
          : Colors.transparent,
      child: InkWell(
        onTap: current
            ? null
            : () => _openPlaylistVideo(
                  videoId,
                ),
        child: Padding(
          padding:
              const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 112,
                height: 70,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (thumbnail.isNotEmpty)
                      Image.network(
                        thumbnail,
                        fit: BoxFit.cover,
                        errorBuilder: (
                          _,
                          _,
                          _,
                        ) =>
                            Container(
                          color:
                              Colors.black12,
                          alignment:
                              Alignment.center,
                          child: const Icon(
                            Icons
                                .broken_image,
                          ),
                        ),
                      )
                    else
                      Container(
                        color:
                            Colors.black12,
                        alignment:
                            Alignment.center,
                        child: const Icon(
                          Icons.image,
                        ),
                      ),
                    if (duration.isNotEmpty)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding:
                              const EdgeInsets
                                  .symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          color:
                              Colors.black87,
                          child: Text(
                            duration,
                            style:
                                const TextStyle(
                              color:
                                  Colors.white,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    if (current)
                      Positioned.fill(
                        child: Container(
                          color:
                              Colors.black38,
                          alignment:
                              Alignment.center,
                          child:
                              const Icon(
                            Icons
                                .play_arrow,
                            color:
                                Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow:
                          TextOverflow.ellipsis,
                      style:
                          TextStyle(
                        fontSize: 13,
                        fontWeight: current
                            ? FontWeight.bold
                            : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(
                      height: 6,
                    ),
                    if (rating.isNotEmpty)
                      Text(
                        rating,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors
                              .grey.shade700,
                        ),
                      ),
                    if (views.isNotEmpty)
                      Text(
                        views,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors
                              .grey.shade700,
                        ),
                      ),
                    if (current)
                      Padding(
                        padding:
                            const EdgeInsets
                                .only(
                          top: 4,
                        ),
                        child: Text(
                          '正在播放',
                          style:
                              TextStyle(
                            fontSize: 11,
                            fontWeight:
                                FontWeight.bold,
                            color: Theme.of(
                                    context)
                                .colorScheme
                                .primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoSection() {
    final video = _video!;

    final brand =
        video['brand']
                ?.toString() ??
            '';

    final releaseDate =
        video['release_date']
                ?.toString() ??
            '';

    final uploader =
        video['uploader']
                ?.toString() ??
            '';

    final views =
        video['views']
                ?.toString() ??
            '';

    final tags =
        List<String>.from(
      video['tags'] ?? [],
    );

    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        _InfoRow(
          label: '品牌',
          value: brand,
          icon: Icons.storefront_outlined,
        ),
        _InfoRow(
          label: '上传者',
          value: uploader,
          icon: Icons.person_outline,
        ),
        _InfoRow(
          label: '观看次数',
          value: views,
          icon: Icons.play_circle_outline,
        ),
        _InfoRow(
          label: '发行日期',
          value: releaseDate,
          icon: Icons.calendar_today_outlined,
        ),
        const SizedBox(
          height: 16,
        ),
        const Text(
          '标签',
          style: TextStyle(
            fontSize: 18,
            fontWeight:
                FontWeight.bold,
          ),
        ),
        const SizedBox(
          height: 8,
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: tags
              .map(
                (tag) => Chip(
                  label: Text(tag),
                ),
              )
              .toList(),
        ),
      ],
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: const SizedBox.shrink(),
        // 左上角：返回按钮右边再放一个「回到首页」。
        // 默认 leading 只有一格宽（约 56），放两个按钮要自己加宽。
        leadingWidth: 96,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '返回',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back),
            ),
            IconButton(
              tooltip: '回到首页',
              onPressed: _goToHome,
              icon: const Icon(Icons.home_outlined),
            ),
          ],
        ),
      ),
      body: PlayerShortcuts(
        player: () => _videoPlayerController,
        volume: _volume,
        onVolumeChanged: (v) {
          setState(() => _volume = v);
          AppSettings.setLastVolume(v);
          _volumeToast.show(v);
        },
        seekStep: AppSettings.seekStep.value,
        holdSpeed: AppSettings.holdSpeed.value,
        // 详情页不是全屏，ESC 不做事（全屏播放器里才有用）
        child: _buildBody(),
      ),
    );
  }

  /// 回到首页：先把主页壳切到「首页」，再关掉所有 push 出来的页面。
  ///
  /// 顺序很重要 —— 先通知主壳切栏目，等它重建好了再 pop，
  /// 这样露出主壳时就已经在首页，不会先闪一下原来的栏目。
  void _goToHome() {
    HomeRequest.go();

    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: Windows11Loading(size: 48),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding:
              const EdgeInsets.all(24),
          child: Text(
            _error!,
            style:
                const TextStyle(
              color: Colors.red,
            ),
          ),
        ),
      );
    }

    if (_video == null) {
      return const Center(
        child: Text(
          '没有获取到视频信息',
        ),
      );
    }

    final title =
        _video!['title']
                ?.toString() ??
            '';

    return LayoutBuilder(
      builder: (
        context,
        constraints,
      ) {
        final wide =
            constraints.maxWidth >= 1000;

        return SingleChildScrollView(
          padding:
              const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                        context)
                    .textTheme
                    .headlineMedium,
              ),
              const SizedBox(
                height: 20,
              ),
              if (wide)
                Row(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 7,
                      child: Column(
                        children: [
                          _buildVideoPlayer(),
                        ],
                      ),
                    ),
                    const SizedBox(
                      width: 16,
                    ),
                    SizedBox(
                      width: 340,
                      child:
                          _buildPlaylistPanel(),
                    ),
                  ],
                )
              else
                Column(
                  children: [
                    _buildVideoPlayer(),
                    const SizedBox(
                      height: 16,
                    ),
                    _buildPlaylistPanel(),
                  ],
                ),
              const SizedBox(
                height: 16,
              ),

              // 播放器下方的操作条：发行商头像 + 点赞/储存/下载
              // 对应官网播放器下面那一排按钮
              _buildActionBar(),

              const SizedBox(
                height: 24,
              ),
              _buildInfoSection(),

              const SizedBox(
                height: 32,
              ),

              // 相关影片（和官网一样放在详情下方）
              _buildRelatedSection(),
            ],
          ),
        );
      },
    );
  }

  /// 播放器下方操作条：左边是发行商头像（可点击进入主页），
  /// 右边是点赞比例、储存、下载。
  Widget _buildActionBar() {
    final video = _video!;

    final artistName = video['brand']?.toString() ?? '';
    final artistUrl = video['artist_url']?.toString() ?? '';
    final artistAvatar = video['artist_avatar']?.toString() ?? '';

    final likeRatio = video['like_ratio']?.toString() ?? '';
    final likeCount = video['like_count']?.toString() ?? '';
    final views = video['views']?.toString() ?? '';
    final duration = video['duration']?.toString() ?? '';
    final fileSize = video['file_size']?.toString() ?? '';

    final sources = (video['sources'] as List?) ?? const [];
    final canDownload = sources.isNotEmpty;

    final hasArtist = artistName.isNotEmpty;
    final hasLike = likeCount.isNotEmpty || likeRatio.isNotEmpty;

    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 影片信息条：每一项都带图标
        //
        // 这里**不再**放「点赞率」—— 它在发行商头像上方单独占一格，
        // 而下面那排按钮里的「点赞」右边已经带着同一个数字了
        // （重复显示，用户要求去掉上面那个）。
        if (views.isNotEmpty || duration.isNotEmpty || fileSize.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // 播放量：圆角矩形里一个居中的三角
                if (views.isNotEmpty)
                  InfoChip(
                    kind: InfoChipKind.play,
                    text: views,
                    tooltip: '播放次数',
                  ),
                if (duration.isNotEmpty)
                  InfoChip(
                    kind: InfoChipKind.duration,
                    text: duration,
                    tooltip: '片长',
                  ),
                if (fileSize.isNotEmpty)
                  InfoChip(
                    kind: InfoChipKind.size,
                    text: fileSize,
                    tooltip: '文件大小',
                  ),
              ],
            ),
          ),

        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (hasArtist)
              _buildArtistChip(artistName, artistAvatar, artistUrl),

            // 点赞 / 储存 / 下载：都会真正作用到官网账号
            if (hasLike)
              _ActionChip(
                // 未点赞 = 空心大拇指；已点赞 = 实心大拇指。
                // 刻意**不改变颜色**（原来点赞后会变绿）——
                // 只靠图标形状区分状态，和点踩按钮的观感一致。
                //
                // 这里不传 color：让它用中性的 onSurface 色，
                // 深色/浅色模式下都清晰。
                icon: _liked
                    ? Icons.thumb_up
                    : Icons.thumb_up_outlined,
                label: _liked ? '已点赞' : '点赞',
                tooltip: _liked
                    ? '已点赞（再点一次取消）'
                    : '点赞会同步到官网账号',
                trailing: likeRatio.isNotEmpty
                    ? '$likeRatio${likeCount.isNotEmpty ? ' · $likeCount' : ''}'
                    : likeCount,
                onTap: () => _doVideoAction(_liked ? 'unlike' : 'like'),
              ),

            _ActionChip(
              // 未储存 = 空心书签；已储存 = 实心书签。
              // 和点赞一样**只换图标形状、不变颜色**。
              icon: _saved ? Icons.bookmark : Icons.bookmark_border,
              label: _saved ? '已储存' : '储存',
              tooltip: _saved
                  ? (_savedPlaylist.isEmpty
                      ? '已储存到播放清单（点击可取消）'
                      : '已储存到「$_savedPlaylist」（点击可取消）')
                  : '把影片存进官网的播放清单',
              onTap: _choosePlaylistAndSave,
            ),

            if (canDownload)
              _ActionChip(
                icon: Icons.download_outlined,
                label: _downloading ? '$_downloadPercent%' : '下载',
                tooltip: canDownload
                    ? '选择清晰度并下载到本机'
                    : '这个影片没有可下载的地址',
                onTap: _downloading ? null : _chooseQualityAndDownload,
              ),
          ],
        ),

        if (_downloading)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: _downloadPercent > 0
                      ? _downloadPercent / 100
                      : null,
                ),
                const SizedBox(height: 4),
                Text(
                  '正在下载 $_downloadPercent%',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.65),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 打开「储存到播放清单」弹窗。
  ///
  /// 清单列表直接用**详情接口带回来的** `save_playlists`。
  /// 那正是官网储存弹窗里的内容：**稍后观看 + 自己创建的清单**。
  /// （收藏来的、别人建的清单不会出现在这里 —— 之前我额外去拉"全部清单"，
  /// 结果把几百个收藏的清单也塞了进来，是错的。）
  ///
  /// 弹窗里点选只是标记，点「确认」才按差异统一提交。
  Future<void> _choosePlaylistAndSave() async {
    final video = _video ?? {};

    var playlists = List<Map<String, dynamic>>.from(
      video['save_playlists'] ?? [],
    );

    // 兜底：详情里没带清单（比如老的缓存）才去问后端
    if (playlists.isEmpty) {
      try {
        final response = await http.get(
          Uri.parse(
            '${AppConfig.backendBase}/api/video/${widget.videoId}/playlists',
          ),
        ).timeout(const Duration(seconds: 90));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);

          playlists = List<Map<String, dynamic>>.from(
            data['playlists'] ?? [],
          );
        }
      } catch (_) {}
    }

    if (!mounted) return;

    // 一个清单都没有也允许打开 —— 可以直接在里面新建
    final checked = await showDialog<List<String>>(
      context: context,
      builder: (_) => SaveToPlaylistDialog(
        playlists: playlists,
        videoTitle: video['title']?.toString() ?? '',
        onApply: _applyPlaylistChangesInBackground,
        onCreate: _createPlaylist,
      ),
    );

    if (!mounted || checked == null) return;

    // 先按用户的选择把本地状态更新掉（乐观）。
    //
    // 关键：**必须把 `save_playlists` 里的 checked 也改掉**。
    // 否则下次再点「储存」，弹窗还是拿这份旧数据，
    // 于是明明刚取消储存、却仍然显示打钩+变色（之前就是这个 bug）。
    setState(() {
      final updated = <Map<String, dynamic>>[];

      for (final p in playlists) {
        final name = p['name']?.toString() ?? '';

        updated.add({...p, 'checked': checked.contains(name)});
      }

      // 弹窗里新建出来的清单不在原始列表里，补进去
      final known = {for (final p in updated) p['name']?.toString() ?? ''};

      for (final name in checked) {
        if (name.isEmpty || known.contains(name)) continue;

        updated.add({'list_id': '', 'name': name, 'checked': true});
      }

      final videoMap = Map<String, dynamic>.from(_video ?? {});

      videoMap['save_playlists'] = updated;
      videoMap['saved'] = checked.isNotEmpty;

      _video = videoMap;

      _saved = checked.isNotEmpty;
      _savedPlaylist = checked.isNotEmpty ? checked.first : '';
    });
  }

  /// 把弹窗里算好的差异丢到后台提交。
  ///
  /// 不阻塞界面 —— 每次提交都要开一次浏览器页面（几秒），
  /// 让用户干等没意义。失败时弹提示并把该项的勾选回滚。
  void _applyPlaylistChangesInBackground(List<PlaylistChange> changes) {
    unawaited(_applyPlaylistChanges(changes));
  }

  Future<void> _applyPlaylistChanges(
    List<PlaylistChange> changes,
  ) async {
    final failed = <PlaylistChange>[];

    for (final change in changes) {
      final ok = await _toggleSaveInPlaylist(change.name, change.save);

      if (!ok) failed.add(change);
    }

    if (!mounted) return;

    // 有成功的就通知别的页面：稍后观看 / 播放清单这些列表的数据变了，
    // 它们会静默刷新，不用用户手动点刷新或重新进页面。
    if (failed.length < changes.length) {
      DataRevision.bump();
    }

    if (failed.isEmpty) {
      AppToast.success(
        context,
        changes.length == 1
            ? (changes.first.save ? '已储存' : '已取消储存')
            : '已更新 ${changes.length} 个清单',
      );

      return;
    }

    // 有失败：把这几项的显示改回去，并说明是哪几个
    setState(() {
      final videoMap = Map<String, dynamic>.from(_video ?? {});

      final list = List<Map<String, dynamic>>.from(
        videoMap['save_playlists'] ?? [],
      );

      for (final change in failed) {
        for (final p in list) {
          if (p['name']?.toString() == change.name) {
            p['checked'] = !change.save;
          }
        }
      }

      videoMap['save_playlists'] = list;

      // 重新算「有没有存在任何清单里」
      final anyChecked = list.any((p) => p['checked'] == true);

      videoMap['saved'] = anyChecked;

      _video = videoMap;
      _saved = anyChecked;
      _savedPlaylist = anyChecked
          ? (list.firstWhere(
              (p) => p['checked'] == true,
              orElse: () => const {'name': ''},
            )['name']?.toString() ??
                '')
          : '';
    });

    AppToast.error(
      context,
      '这些清单没同步成功：${failed.map((c) => c.name).join('、')}',
    );
  }

  /// 新建播放清单。成功返回新清单名，失败返回 null。
  Future<String?> _createPlaylist(String title, String description) async {
    if (!AuthController.isLoggedIn) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => const LoginDialog(),
      );

      if (ok != true || !mounted) return null;
    }

    try {
      final response = await http
          .post(
            Uri.parse('${AppConfig.backendBase}/api/playlist/create'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'title': title,
              'description': description,
              'video_id': widget.videoId,
            }),
          )
          .timeout(const Duration(seconds: 180));

      final data = jsonDecode(response.body);

      if (!mounted) return null;

      if (response.statusCode != 200) {
        final detail = data is Map ? data['detail']?.toString() : null;

        throw Exception(detail ?? '新建失败（${response.statusCode}）');
      }

      AppToast.success(
        context,
        (data is Map ? data['message']?.toString() : null) ?? '已新建',
      );

      // 清单列表变了，缓存作废
      AppCache.removeWherePrefix('/api/user/');
      AppCache.removeWherePrefix('/api/playlist');

      // 通知别的页面（个人主页的播放清单、侧边栏播放清单）刷新
      DataRevision.bump();

      final state = data is Map ? data['state'] : null;

      return state is Map ? state['name']?.toString() : title;
    } catch (e) {
      if (mounted) AppToast.error(context, '$e');

      return null;
    }
  }

  /// 把「加入/移出某个清单」提交给后端。
  ///
  /// 返回是否成功 —— 弹窗据此决定哪几个清单要标成失败。
  Future<bool> _toggleSaveInPlaylist(String playlistName, bool save) async {
    if (!AuthController.isLoggedIn) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => const LoginDialog(),
      );

      if (ok != true || !mounted) return false;
    }

    try {
      final response = await http
          .post(
            Uri.parse(
              '${AppConfig.backendBase}/api/video/'
              '${widget.videoId}/action',
            ),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'action': save ? 'save' : 'unsave',
              'playlist': playlistName,
            }),
          )
          .timeout(const Duration(seconds: 180));

      final data = jsonDecode(response.body);

      if (!mounted) return false;

      if (response.statusCode != 200) {
        final detail = data is Map ? data['detail']?.toString() : null;

        throw Exception(detail ?? '操作失败（${response.statusCode}）');
      }

      // 清单内容变了，用户主页与详情缓存作废
      AppCache.removeWherePrefix('/api/user/');

      return true;
    } catch (e) {
      // 这里不弹提示 —— 由 _applyPlaylistChanges 统一汇总报错，
      // 否则一次提交会连弹好几条。
      debugPrint('储存到「$playlistName」失败：$e');

      return false;
    }
  }

  /// 下载到本机。
  /// 选择清晰度后开始下载。
  ///
  /// 官网的播放地址是按清晰度分开的（1080p/720p/480p 各一条 mp4），
  /// 详情接口已经把它们带回来了，所以这里直接列出来给用户挑，
  /// 不选就用设置里的默认值（再不然用最高画质）。
  Future<void> _chooseQualityAndDownload() async {
    final video = _video ?? {};

    final sources = List<Map<String, dynamic>>.from(
      video['sources'] ?? [],
    );

    if (sources.isEmpty) {
      AppToast.error(context, '这个影片没有可直接下载的地址');
      return;
    }

    // 只有一种清晰度就没必要问了
    if (sources.length == 1) {
      await _startDownload(quality: sources.first['quality']?.toString() ?? '');

      return;
    }

    final preferred = AppSettings.downloadQuality.value;

    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择下载清晰度'),
        children: [
          for (final source in sources)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.of(context).pop(source['quality']?.toString() ?? ''),
              child: Row(
                children: [
                  Icon(
                    source['quality']?.toString() == preferred
                        ? Icons.star
                        : Icons.high_quality_outlined,
                    size: 20,
                    color: source['quality']?.toString() == preferred
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Text(source['quality']?.toString() ?? '未知'),
                  const SizedBox(width: 8),
                  if (source['quality']?.toString() == preferred)
                    Text(
                      '默认',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );

    if (picked == null || picked.isEmpty || !mounted) return;

    await _startDownload(quality: picked);
  }

  Future<void> _startDownload({String quality = ''}) async {
    final videoId = widget.videoId;

    setState(() {
      _downloading = true;
      _downloadPercent = 0;
    });

    try {
      final response = await http.post(
        Uri.parse('${AppConfig.backendBase}/api/download/$videoId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          if (quality.isNotEmpty) 'quality': quality,
        }),
      ).timeout(const Duration(seconds: 180));

      if (response.statusCode != 200) {
        throw Exception('服务器返回错误: ${response.statusCode}');
      }

      // 轮询进度
      while (mounted) {
        await Future<void>.delayed(const Duration(milliseconds: 800));

        final status = await http.get(
          Uri.parse('${AppConfig.backendBase}/api/download/$videoId'),
        ).timeout(const Duration(seconds: 30));

        final job = (jsonDecode(status.body)['job'] ?? {}) as Map;

        final percent = (job['percent'] as num?)?.toInt() ?? 0;
        final state = job['status']?.toString() ?? '';

        if (mounted) {
          setState(() => _downloadPercent = percent);
        }

        if (state == 'done') {
          if (mounted) {
            setState(() => _downloading = false);

            AppToast.success(context, '下载完成，已保存到下载文件夹');
          }

          return;
        }

        if (state == 'failed' || state == 'cancelled') {
          if (mounted) {
            setState(() => _downloading = false);

            AppToast.error(
              context,
              state == 'cancelled'
                  ? '下载已取消'
                  : '下载失败：${job['error'] ?? '未知原因'}',
            );
          }

          return;
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _downloading = false);

        AppToast.error(context, '下载失败：$e');
      }
    }
  }

  /// 执行点赞 / 储存。
  ///
  /// **乐观更新**：点一下图标立刻点亮，不等待后端，也不显示转圈；
  /// 真正的同步在后台跑，失败再回滚。
  Future<void> _doVideoAction(String action, {String playlist = ''}) async {
    if (!AuthController.isLoggedIn) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => const LoginDialog(),
      );

      if (ok != true || !mounted) return;
    }

    // 立即点亮图标（乐观）
    setState(() {
      switch (action) {
        case 'like':
          _liked = true;
        case 'unlike':
          _liked = false;
        case 'save':
          _saved = true;
          _savedPlaylist = playlist;
      }
    });

    // 后台同步，不阻塞 UI
    _syncVideoAction(action, playlist: playlist);
  }

  /// 真正把点赞/储存同步到官网账号（后台运行）。
  Future<void> _syncVideoAction(
    String action, {
    String playlist = '',
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse(
              '${AppConfig.backendBase}/api/video/${widget.videoId}/action',
            ),
            headers: const {
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'action': action,
              if (playlist.isNotEmpty) 'playlist': playlist,
            }),
          )
          .timeout(const Duration(seconds: 120));

      final data = jsonDecode(response.body);

      if (response.statusCode != 200) {
        final detail =
            data is Map ? data['detail']?.toString() : null;

        throw Exception(detail ?? '操作失败（${response.statusCode}）');
      }

      if (!mounted) return;

      final message =
          (data is Map ? data['message']?.toString() : null) ?? '完成';

      AppToast.success(context, message);

      // 播放清单会变，清掉用户主页缓存
      AppCache.removeWherePrefix('/api/user/');

      // 用后端返回的最新点赞数就地更新，不再重新加载整页
      final state = data is Map ? data['state'] : null;

      if (state is Map && mounted) {
        final ratio = state['like_ratio']?.toString() ?? '';
        final count = state['like_count']?.toString() ?? '';

        if (ratio.isNotEmpty || count.isNotEmpty) {
          setState(() {
            final video = Map<String, dynamic>.from(_video ?? {});

            if (ratio.isNotEmpty) video['like_ratio'] = ratio;
            if (count.isNotEmpty) video['like_count'] = count;

            _video = video;
          });
        }
      }
    } catch (e) {
      if (!mounted) return;

      // 同步失败：回滚乐观更新
      setState(() {
        switch (action) {
          case 'like':
            _liked = false;
          case 'unlike':
            _liked = true;
          case 'save':
            _saved = false;
            _savedPlaylist = '';
        }
      });

      AppToast.error(context, '$e');
    }
  }

  /// 发行商/品牌：头像 + 名称，点击在 APP 内打开发行商主页。
  Widget _buildArtistChip(
    String name,
    String avatar,
    String url,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final artistId = _video!['artist_id']?.toString() ?? '';

    return Tooltip(
      message: artistId.isEmpty ? name : '查看 $name 的主页',
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: artistId.isEmpty
            ? null
            : () {
                // 在 APP 内打开，不再跳到外部浏览器
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => UserProfilePage(
                      userId: artistId,
                      initialName: name,
                    ),
                  ),
                );
              },
        child: Container(
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark ? Colors.white12 : const Color(0xFFE2E4E8),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipOval(
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: avatar.isEmpty
                      ? Container(
                          color: theme.colorScheme.primary
                              .withValues(alpha: 0.15),
                          child: Icon(
                            Icons.storefront_outlined,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                        )
                      : Image.network(
                          avatar,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.15),
                            child: Icon(
                              Icons.storefront_outlined,
                              size: 18,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '发行商',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 相关影片：官网从同一个页面里就能解析出来，不需要额外请求。
  Widget _buildRelatedSection() {
    final related = List<Map<String, dynamic>>.from(
      _video!['related'] ?? [],
    );

    if (related.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            const Text(
              '相关影片',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${related.length}',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurface
                    .withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            // 卡片宽度固定，列数随可用宽度变化
            const cardWidth = 200.0;
            const spacing = 12.0;

            final columns = ((constraints.maxWidth + spacing) /
                    (cardWidth + spacing))
                .floor()
                .clamp(1, 8);

            // 卡片高度按封面的真实比例算，竖版和横版都能正好装下。
            //
            // 官网相关影片的封面基本是竖版（实测 268x394，比例 0.68），
            // 固定用 0.72 的话竖图会被裁；这里取所有封面比例的中位数，
            // 混排时也能落在合理值上。
            final cardAspect = _medianThumbAspect(related);

            // 卡片 = 封面 + 标题两行
            final thumbHeight = cardWidth / cardAspect;
            final cardHeight = thumbHeight + 52;
            final gridAspect = cardWidth / cardHeight;

            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate:
                  SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: spacing,
                mainAxisSpacing: spacing,
                childAspectRatio: gridAspect,
              ),
              itemCount: related.length,
              itemBuilder: (context, index) {
                return RelatedVideoCard(
                  video: related[index],
                  onTap: () {
                    final id = related[index]['video_id']
                        ?.toString();

                    if (id == null || id.isEmpty) return;

                    // 用 push 打开新页面，返回时回到当前视频
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => VideoDetailPage(videoId: id),
                      ),
                    );
                  },
                );
              },
            );
          },
        ),
      ],
    );
  }

}

/// 取一组影片封面比例的中位数（拿不到就用 16:9）。
///
/// 用中位数而不是平均值：相关影片里偶尔混进个别比例奇怪的封面，
/// 平均值会被带偏。
double _medianThumbAspect(List<Map<String, dynamic>> videos) {
  final ratios = <double>[];

  for (final v in videos) {
    final r = v['thumb_ratio'];

    if (r is num && r > 0.2 && r < 5) {
      ratios.add(r.toDouble());
    }
  }

  if (ratios.isEmpty) return 16 / 9;

  ratios.sort();

  return ratios[ratios.length ~/ 2];
}

/// 影片信息小标签（带图标的那种）。
///
/// 用户希望信息更好扫读，所以每项都配一个图标：
/// 播放量用「圆角矩形 + 居中三角」，点赞率用竖大拇指。
class InfoChip extends StatelessWidget {
  final InfoChipKind kind;
  final String text;
  final String tooltip;
  final Color? color;

  const InfoChip({
    super.key,
    required this.kind,
    required this.text,
    this.tooltip = '',
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.onSurface.withValues(alpha: 0.7);

    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildIcon(tint),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: tint,
            ),
          ),
        ],
      ),
    );

    if (tooltip.isEmpty) return body;

    return Tooltip(message: tooltip, child: body);
  }

  Widget _buildIcon(Color tint) {
    // 播放量：一个圆角矩形，中间一个居中的三角（像播放按钮）
    if (kind == InfoChipKind.play) {
      return Container(
        width: 22,
        height: 15,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: tint, width: 1.2),
        ),
        child: Center(
          child: Icon(Icons.play_arrow_rounded, size: 11, color: tint),
        ),
      );
    }

    return Icon(_iconFor(kind), size: 16, color: tint);
  }

  IconData _iconFor(InfoChipKind kind) => switch (kind) {
        InfoChipKind.play => Icons.play_arrow_rounded,
        // 竖着的大拇指
        InfoChipKind.like => Icons.thumb_up_alt_outlined,
        InfoChipKind.duration => Icons.schedule,
        InfoChipKind.size => Icons.sd_storage_outlined,
        InfoChipKind.views => Icons.visibility_outlined,
      };
}

enum InfoChipKind { play, like, duration, size, views }

class _InfoRow
    extends StatelessWidget {
  final String label;
  final String value;

  /// 行首的小图标（让信息更好扫读）
  final IconData? icon;

  const _InfoRow({
    required this.label,
    required this.value,
    this.icon,
  });

  @override
  Widget build(
    BuildContext context,
  ) {
    // 值为空时整行不显示，避免出现「品牌 / 发行日期」后面空一片
    if (value.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);

    return Padding(
      padding:
          const EdgeInsets.only(
        bottom: 10,
      ),
      child: Row(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
          ],
          SizedBox(
            width: icon != null ? 84 : 90,
            child: Text(
              label,
              style:
                  const TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty
                  ? '-'
                  : value,
            ),
          ),
        ],
      ),
    );
  }
}


class _FullscreenPlayerPage extends StatefulWidget {
  final VideoPlayerController controller;
  final List<Map<String, dynamic>> availableSources;
  final String currentQuality;
  final double volume;
  final void Function(VideoPlayerController, String) onControllerChanged;
  final ValueChanged<double> onVolumeChanged;

  const _FullscreenPlayerPage({
    required this.controller,
    required this.availableSources,
    required this.currentQuality,
    required this.volume,
    required this.onControllerChanged,
    required this.onVolumeChanged,
  });

  @override
  State<_FullscreenPlayerPage> createState() =>
      _FullscreenPlayerPageState();
}

class _FullscreenPlayerPageState
    extends State<_FullscreenPlayerPage> {
  late VideoPlayerController _controller;
  late List<Map<String, dynamic>> _availableSources;
  late String _currentQuality;
  late double _volume;

  /// 音量提示（放进本页的 Stack，居中于画面）
  final VolumeToastController _volumeToast = VolumeToastController();

  bool _showControls = true;
  bool _showVolumeSlider = false;
  bool _switchingQuality = false;
  bool _progressHovering = false;
  double _progressHoverRatio = 0.0;
  Timer? _controlsTimer;
  Timer? _volumeHideTimer;

  @override
  void initState() {
    super.initState();

    _controller = widget.controller;
    _availableSources = widget.availableSources;
    _currentQuality = widget.currentQuality;
    _volume = widget.volume;

    _controller.addListener(_onControllerTick);

    _restartHideTimer();
  }

  void _onControllerTick() {
    if (mounted) {
      setState(() {});
    }
  }

  void _restartHideTimer() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _showControls = false);
      }
    });
  }

  void _onMouseMove() {
    if (!_showControls) {
      setState(() => _showControls = true);
    }
    _restartHideTimer();
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _volumeHideTimer?.cancel();
    _controller.removeListener(_onControllerTick);
    _volumeToast.dispose();
    super.dispose();
  }

  Future<void> _exitFullscreen() async {
    await windowManager.setFullScreen(false);

    if (mounted) {
      Navigator.pop(context);
    }
  }

  String _formatDuration(Duration duration) {
    final minutes =
        duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds =
        duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = duration.inHours;

    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }

    return '$minutes:$seconds';
  }

  Future<void> _changeQuality(String newQuality) async {
    if (_switchingQuality || newQuality == _currentQuality) {
      return;
    }

    final source = _availableSources.firstWhere(
      (s) => s['quality'] == newQuality,
      orElse: () => <String, dynamic>{},
    );

    final newUrl = source['url']?.toString();

    if (newUrl == null || newUrl.isEmpty) {
      return;
    }

    final oldController = _controller;
    final wasPlaying = oldController.value.isPlaying;
    final position = oldController.value.position;

    setState(() {
      _currentQuality = newQuality;
      _switchingQuality = true;
    });

    oldController.removeListener(_onControllerTick);

    final newController = VideoPlayerController.networkUrl(
      Uri.parse(newUrl),
    );

    await newController.initialize();
    await newController.seekTo(position);
    newController.setVolume(_volume);

    _controller = newController;
    newController.addListener(_onControllerTick);

    widget.onControllerChanged(newController, newQuality);

    if (wasPlaying) {
      await newController.play();
    }

    await oldController.pause();
    await oldController.dispose();

    if (mounted) {
      setState(() {
        _switchingQuality = false;
      });
    }
  }


  Widget _buildControls() {
    final position = _controller.value.position;
    final duration = _controller.value.duration;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 视频到控制栏的渐变过渡层
        IgnorePointer(
          child: Container(
            height: 16,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black54,
                ],
              ),
            ),
          ),
        ),
        // 控制栏本体
        Container(
          color: Colors.black54,
          padding: const EdgeInsets.only(left: 4, right: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final trackWidth = constraints.maxWidth;

                  return MouseRegion(
                    onHover: (event) {
                      final dx = event.localPosition.dx;
                      final ratio = (dx / trackWidth).clamp(0.0, 1.0);

                      if (!_progressHovering ||
                          (_progressHoverRatio - ratio).abs() > 0.002) {
                        setState(() {
                          _progressHovering = true;
                          _progressHoverRatio = ratio;
                        });
                      }
                    },
                    onExit: (_) {
                      if (_progressHovering) {
                        setState(() {
                          _progressHovering = false;
                        });
                      }
                    },
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        VideoProgressIndicator(
                          _controller,
                          allowScrubbing: true,
                          padding: const EdgeInsets.symmetric(vertical: 2),
                        ),
                        if (_progressHovering)
                          Positioned(
                            left: (trackWidth * _progressHoverRatio - 30)
                                .clamp(0.0, trackWidth - 60),
                            top: -26,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                _formatDuration(
                                  Duration(
                                    milliseconds: (duration.inMilliseconds *
                                            _progressHoverRatio)
                                        .round(),
                                  ),
                                ),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
              Row(
                children: [
                  IconButton(
                    color: Colors.white,
                    icon: Icon(
                      _controller.value.isPlaying
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                    onPressed: () {
                      setState(() {
                        if (_controller.value.isPlaying) {
                          _controller.pause();
                        } else {
                          _controller.play();
                        }
                      });
                      _restartHideTimer();
                    },
                  ),
                  MouseRegion(
                    onEnter: (_) {
                      _volumeHideTimer?.cancel();
                      if (!_showVolumeSlider) {
                        setState(() => _showVolumeSlider = true);
                      }
                    },
                    onExit: (_) {
                      _volumeHideTimer?.cancel();
                      _volumeHideTimer = Timer(
                        const Duration(milliseconds: 150),
                        () {
                          if (mounted && _showVolumeSlider) {
                            setState(() => _showVolumeSlider = false);
                          }
                        },
                      );
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          color: Colors.white,
                          icon: Icon(
                            _volume == 0
                                ? Icons.volume_off
                                : Icons.volume_up,
                          ),
                          onPressed: () {
                            setState(() {
                              _volume = _volume == 0 ? 1 : 0;
                              _controller.setVolume(_volume);
                              AppSettings.setLastVolume(_volume);
                              widget.onVolumeChanged(_volume);
                            });
                          },
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                          alignment: Alignment.centerLeft,
                          child: _showVolumeSlider
                              ? SizedBox(
                                  width: 80,
                                  height: 40,
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 2.0,
                                      activeTrackColor: Colors.red,
                                      inactiveTrackColor: Colors.white24,
                                      thumbColor: Colors.red,
                                      overlayColor:
                                          Colors.red.withValues(alpha: 0.2),
                                      thumbShape:
                                          const RoundSliderThumbShape(
                                        enabledThumbRadius: 6.0,
                                      ),
                                      overlayShape:
                                          const RoundSliderOverlayShape(
                                        overlayRadius: 12.0,
                                      ),
                                    ),
                                    child: Slider(
                                      value: _volume,
                                      min: 0,
                                      max: 1,
                                      onChanged: (value) {
                                        setState(() {
                                          _volume = value;
                                          _controller.setVolume(value);
                                          widget.onVolumeChanged(value);
                                        });

                                        AppSettings.setLastVolume(value);
                                      },
                                    ),
                                  ),
                                )
                              : const SizedBox(width: 0, height: 40),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      '${_formatDuration(position)} / ${_formatDuration(duration)}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  const Spacer(),
                  if (_availableSources.isNotEmpty)
                    PopupMenuButton<String>(
                      icon: const Icon(
                        Icons.high_quality,
                        color: Colors.white,
                      ),
                      tooltip: '选择画质',
                      onSelected: _changeQuality,
                      itemBuilder: (context) {
                        return _availableSources.map((source) {
                          final quality =
                              source['quality']?.toString() ?? '';

                          return PopupMenuItem<String>(
                            value: quality,
                            child: Row(
                              children: [
                                if (quality == _currentQuality)
                                  const Icon(
                                    Icons.check,
                                    size: 18,
                                    color: Colors.green,
                                  )
                                else
                                  const SizedBox(width: 18),
                                const SizedBox(width: 8),
                                Text(quality),
                              ],
                            ),
                          );
                        }).toList();
                      },
                    ),
                  IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.fullscreen_exit),
                    onPressed: _exitFullscreen,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PlayerShortcuts(
      // 全屏页：ESC 退出全屏（这里就是关掉本页）
      fullscreen: true,
      onExitFullscreen: () => Navigator.of(context).maybePop(),
      player: () => _controller,
      volume: _volume,
      onVolumeChanged: (v) {
        setState(() => _volume = v);
        AppSettings.setLastVolume(v);
        _volumeToast.show(v);
      },
      onActivity: _onMouseMove,
      child: Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        onHover: (_) => _onMouseMove(),
        onEnter: (_) => _onMouseMove(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: _switchingQuality
                    ? Container(
                        color: Colors.black,
                        alignment: Alignment.center,
                        child: const Windows11Loading(
                          size: 48,
                          color: Colors.white,
                        ),
                      )
                    : VideoPlayer(_controller),
              ),              
            ),

            // 底部常驻细进度条（控制栏出现时淡出）
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _showControls ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 200),
                  child: VideoProgressIndicator(
                    _controller,
                    allowScrubbing: false,
                    colors: const VideoProgressColors(
                      playedColor: Colors.red,
                      bufferedColor: Colors.white38,
                      backgroundColor: Colors.white24,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),

            // 底部控制栏（淡入淡出）
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: _buildControls(),
                ),
              ),
            ),

            // 调音量时在画面正中显示
            ListenableBuilder(
              listenable: _volumeToast,
              builder: (context, _) {
                if (!_volumeToast.visible) return const SizedBox.shrink();

                return Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: VolumeToast(volume: _volumeToast.volume!),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
      ),
    );
  }
}

// ==========================================================
// 筛选按钮的统一外观
// ==========================================================
//
// 五个筛选项（影片类型 / 排序 / 日期 / 時長 / 標籤）共用这一套尺寸和配色，
// 保证美术风格一致。要整体调整筛选栏的样子，改这里就够了。
// ==========================================================
// 侧边栏底部的账号入口
// ==========================================================

/// 未登录：一个「登录」按钮。
/// 已登录：显示头像 + 名字，点击进入自己的主页，右键可退出登录。
class _AccountTile extends StatelessWidget {
  final VoidCallback onOpenProfile;
  final Future<void> Function() onLogout;

  const _AccountTile({
    required this.onOpenProfile,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 跟着登录状态自动重建
    return ValueListenableBuilder<AccountInfo>(
      valueListenable: AuthController.account,
      builder: (context, info, _) {
        if (!info.loggedIn) {
          return Padding(
            padding: const EdgeInsets.all(8),
            child: Tooltip(
              message: '登录后可以点赞、储存、查看自己的收藏',
              child: TextButton.icon(
                onPressed: onOpenProfile,
                icon: const Icon(Icons.login, size: 18),
                label: const Text('登录'),
                style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(40),
                ),
              ),
            ),
          );
        }

        // 昵称不显示在头像下面（只保留头像，更干净）
        return PopupMenuButton<String>(
          tooltip: '打开我的主页（右键可登出）',
          position: PopupMenuPosition.over,
          onSelected: (value) {
            if (value == 'logout') {
              onLogout();
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'profile',
              height: 40,
              child: Row(
                children: [
                  Icon(Icons.person_outline, size: 18),
                  SizedBox(width: 10),
                  Text('我的主页'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'logout',
              height: 40,
              child: Row(
                children: [
                  Icon(Icons.logout, size: 18),
                  SizedBox(width: 10),
                  Text('退出登录'),
                ],
              ),
            ),
          ],
          child: InkWell(
            onTap: onOpenProfile,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 10,
              ),
              // 只显示头像，不显示昵称
              child: CircleAvatar(
                radius: 20,
                backgroundColor:
                    theme.colorScheme.primary.withValues(alpha: 0.15),
                backgroundImage:
                    info.avatar.isEmpty ? null : NetworkImage(info.avatar),
                child: info.avatar.isEmpty
                    ? Icon(
                        Icons.person,
                        size: 22,
                        color: theme.colorScheme.primary,
                      )
                    : null,
              ),
            ),
          ),
        );
      },
    );
  }
}

// ==========================================================
// 详情页操作条 / 相关影片
// ==========================================================

/// 详情页操作条上的一个按钮（点赞 / 储存 / 下载）。
///
/// 点赞和储存会真正作用到官网账号。
///
/// 状态**只靠图标形状**表达（空心 ↔ 实心），刻意不做变色/高亮 ——
/// 之前点赞和储存会整块变绿，看起来像和背景撞色，观感也乱。
/// 图标用的中性 `onSurface` 色在深色和浅色主题下都有足够对比度。
class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String trailing;
  final String tooltip;
  final VoidCallback? onTap;

  const _ActionChip({
    required this.icon,
    required this.label,
    this.trailing = '',
    this.tooltip = '',
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final tint = theme.colorScheme.onSurface.withValues(alpha: 0.7);

    Widget chip = Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? Colors.white12 : const Color(0xFFE2E4E8),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 不显示转圈：无论是否在同步，图标都保持可见
          Icon(icon, size: 18, color: tint),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (trailing.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              trailing,
              style: TextStyle(
                fontSize: 12,
                color: tint,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );

    // 可点击时才包 InkWell（下载那种纯展示的就不包）
    if (onTap != null) {
      chip = InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: chip,
      );
    }

    if (tooltip.isEmpty) return chip;

    return Tooltip(message: tooltip, child: chip);
  }
}

/// 相关影片卡片：封面 + 标题。
class RelatedVideoCard extends StatefulWidget {
  final Map<String, dynamic> video;
  final VoidCallback onTap;

  const RelatedVideoCard({
    super.key,
    required this.video,
    required this.onTap,
  });

  @override
  State<RelatedVideoCard> createState() => _RelatedVideoCardState();
}

class _RelatedVideoCardState extends State<RelatedVideoCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final title = widget.video['title']?.toString() ?? '';
    final thumbnail = widget.video['thumbnail']?.toString() ?? '';

    // 按封面真实比例渲染。
    //
    // 相关影片区混着两种封面：
    //   - 竖版（官网实测 268x394，比例 0.68）
    //   - 横版（16:9）
    // 以前一律按 16:9 画，竖图会被 BoxFit.cover 裁掉一大半。
    // 后端已经在浏览器里量过每张图的真实尺寸，这里直接用；
    // 量不到就退回 16:9。
    final rawRatio = widget.video['thumb_ratio'];

    var aspect = 16 / 9;

    if (rawRatio is num && rawRatio > 0.2 && rawRatio < 5) {
      aspect = rawRatio.toDouble();
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: _hovering
                ? theme.colorScheme.primary.withValues(alpha: 0.08)
                : Colors.transparent,
          ),
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 竖版封面就别硬塞进横版框里
              AspectRatio(
                aspectRatio: aspect,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: thumbnail.isEmpty
                      ? Container(
                          color: isDark
                              ? Colors.white10
                              : Colors.black12,
                          child: const Center(
                            child: Icon(
                              Icons.movie_outlined,
                              color: Colors.white38,
                            ),
                          ),
                        )
                      : Image.network(
                          thumbnail,
                          // 竖版封面用 contain 会留黑边，用 cover 又裁；
                          // 框本身已经按真实比例，所以 cover 不会裁掉内容
                          fit: BoxFit.cover,
                          width: double.infinity,
                          errorBuilder: (_, _, _) => Container(
                            color: isDark
                                ? Colors.white10
                                : Colors.black12,
                            child: const Center(
                              child: Icon(
                                Icons.broken_image_outlined,
                                color: Colors.white38,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterChipStyle {
  _FilterChipStyle._();

  static const double height = 34;
  static const double radius = 17;
  static const EdgeInsets padding =
      EdgeInsets.symmetric(horizontal: 12);
}

/// 筛选栏上的胶囊按钮。
///
/// - 未选中：中性描边，低调
/// - 已选中：主色描边 + 浅主色底，并把选中的值显示出来
class _FilterChip extends StatelessWidget {
  /// 前缀文字，例如「排序」
  final String labelPrefix;

  /// 选中的值，空字符串表示未选中
  final String text;

  final bool active;
  final IconData trailing;
  final bool loading;

  const _FilterChip({
    required this.labelPrefix,
    this.text = '',
    this.active = false,
    this.trailing = Icons.keyboard_arrow_down_rounded,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final primary = theme.colorScheme.primary;

    final borderColor = active
        ? primary.withValues(alpha: 0.75)
        : (isDark ? Colors.white24 : const Color(0xFFD5D7DB));

    final fillColor = active
        ? primary.withValues(alpha: isDark ? 0.20 : 0.10)
        : (isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.white);

    final textColor = active
        ? primary
        : (isDark
            ? Colors.white.withValues(alpha: 0.82)
            : const Color(0xFF44464B));

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: _FilterChipStyle.height,
      padding: _FilterChipStyle.padding,
      decoration: BoxDecoration(
        color: fillColor,
        borderRadius: BorderRadius.circular(_FilterChipStyle.radius),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            labelPrefix,
            style: TextStyle(
              fontSize: 13,
              color: textColor,
              fontWeight:
                  active ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
          if (text.isNotEmpty) ...[
            const SizedBox(width: 6),
            // 选中的值单独用一个小色块强调
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 1,
              ),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: isDark ? 0.28 : 0.16),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  color: primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          const SizedBox(width: 4),
          if (loading)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: primary,
              ),
            )
          else
            Icon(
              trailing,
              size: 18,
              color: active
                  ? primary
                  : (isDark ? Colors.white54 : Colors.black45),
            ),
        ],
      ),
    );
  }
}