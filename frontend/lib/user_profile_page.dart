import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'controllers/app_cache.dart';
import 'controllers/auth_controller.dart';
import 'main.dart';
import 'playlist_detail_page.dart';
import 'utils/user_tabs.dart';
import 'widgets/windows11_loading.dart';
import 'controllers/app_config.dart';
import 'login_dialog.dart';
import './widgets/app_toast.dart';
import 'widgets/pager_bar.dart';
import 'controllers/data_revision.dart';
import 'widgets/video_card.dart';

/// 用户 / 发行商主页。
///
/// 同一个页面同时服务于两种场景：
/// - 从详情页点发行商头像进来 → 看别人上传的影片
/// - 从左下角点自己的头像进来 → 看自己点赞过的影片、储存的播放清单
///
/// 数据来自后端 `/api/user/{id}?tab=...`，由真实浏览器抓取，
/// 所以登录后需要登录才能看到的内容（点赞列表等）也能拿到。
class UserProfilePage extends StatefulWidget {
  final String userId;
  final String initialTab;

  /// 已知的显示名（从详情页带过来，能立刻显示，不用等接口）
  final String initialName;

  const UserProfilePage({
    super.key,
    required this.userId,
    this.initialTab = 'home',
    this.initialName = '',
  });

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage>
    with SingleTickerProviderStateMixin {
  String get _base => AppConfig.backendBase;

  TabController? _tabController;

  late String _tab;

  bool _loading = true;
  String? _error;

  String _name = '';
  String _avatar = '';

  List<Map<String, dynamic>> _videos = [];
  List<Map<String, dynamic>> _playlists = [];

  /// 「主页」上的栏目段（觀看紀錄 / 稍後觀看 / 讚好的影片 / 播放清單）
  List<Map<String, dynamic>> _sections = [];

  /// 列表类 tab 的分页状态
  int _page = 1;
  int _totalPages = 1;

  /// 点赞过的影片只有登录自己的主页才看得到
  bool get _isSelf {
    // 退出登录后就地切换时，用覆盖值判断（此时账号已经没了）
    if (_selfOverride) return true;

    final mine = AuthController.account.value.userId;

    return mine.isNotEmpty && mine == _effectiveUserId;
  }

  /// 当前页面实际作用的用户 id。
  ///
  /// 平时等于 widget.userId，但退出登录后要就地切回「自己」，
  /// 这时候 widget 的值已经过期了，所以用这个可变字段。
  String _effectiveUserId = '';

  /// 退出登录 / 就地登录之后用来覆盖 tab 列表（null 表示按 _isSelf 推导）
  List<({String key, String label, IconData icon})>? _tabsOverride;

  /// 是否把自己当作「本人主页」（退出登录后仍为 true，好显示登录引导）
  bool _selfOverride = false;

  /// 栏目段各自的横向滚动控制器（滑块需要它）。
  ///
  /// key 用「序号 + 栏目名」：官网偶尔会有重名栏目，
  /// 只用名字会让两个栏目共用同一个 controller。
  final Map<String, ScrollController> _sectionControllers = {};

  ScrollController controllerForSection(int index, String name) {
    return _sectionControllers.putIfAbsent(
      '$index::$name',
      () => ScrollController(),
    );
  }

  /// 个人中心的那 5 个 tab（顺序和官网一致）。
  ///
  /// 看别人的主页时，觀看紀錄 / 稍後觀看 / 讚好的影片 是私密的、拿不到，
  /// 所以只保留主页 + 上传的影片 + 播放清单。
  List<({String key, String label, IconData icon})> get _tabs {
    if (_tabsOverride != null) return _tabsOverride!;

    const icons = {
      'home': Icons.dashboard_outlined,
      'histories': Icons.history,
      'saves': Icons.watch_later_outlined,
      'likes': Icons.thumb_up_outlined,
      'playlists': Icons.playlist_play,
      'uploaded': Icons.movie_outlined,
    };

    final source = _isSelf ? selfProfileTabs : otherProfileTabs;

    return [
      for (final t in source)
        (
          key: t.key,
          label: t.label,
          icon: icons[t.key] ?? Icons.circle_outlined,
        ),
    ];
  }

  /// 生成 tab 列表（带图标），给需要直接赋值的场景用
  List<({String key, String label, IconData icon})> _buildTabs({
    required bool self,
  }) {
    const icons = {
      'home': Icons.dashboard_outlined,
      'histories': Icons.history,
      'saves': Icons.watch_later_outlined,
      'likes': Icons.thumb_up_outlined,
      'playlists': Icons.playlist_play,
      'uploaded': Icons.movie_outlined,
    };

    final source = self ? selfProfileTabs : otherProfileTabs;

    return [
      for (final t in source)
        (
          key: t.key,
          label: t.label,
          icon: icons[t.key] ?? Icons.circle_outlined,
        ),
    ];
  }

  /// 栏目段的「查看更多」要跳到哪个 tab。
  ///
  /// 规则见 utils/user_tabs.dart（那里可以单独测）。
  String? _tabKeyFromUrl(String url) =>
      tabKeyFromUrl(url, _effectiveUserId);

  @override
  void initState() {
    super.initState();

    _effectiveUserId = widget.userId;
    _tab = widget.initialTab;
    _name = widget.initialName;

    _tabController = TabController(
      length: _tabs.length,
      vsync: this,
    );

    final index = _tabs.indexWhere((t) => t.key == _tab);

    if (index >= 0) {
      _tabController!.index = index;
    }

    // 别处改了数据（比如在影片详情里取消储存）时静默刷新，
    // 这样返回本页看到的就是最新的，不用手动点刷新。
    DataRevision.revision.addListener(_onDataChanged);

    _load();
  }

  @override
  void dispose() {
    DataRevision.revision.removeListener(_onDataChanged);

    _tabController?.dispose();

    for (final c in _sectionControllers.values) {
      c.dispose();
    }

    _sectionControllers.clear();

    super.dispose();
  }

  /// 全局数据变了：静默刷新当前 tab（保留内容、不转圈）
  void _onDataChanged() {
    if (!mounted) return;

    // 没登录时这个页面是登录引导页，没什么可刷新的
    if (!AuthController.isLoggedIn) return;

    _load(tab: _tab, page: _page, silent: true);
  }

  /// 退出登录（只有自己的主页才会显示这个入口）。
  ///
  /// 退出后**不关闭页面**，而是就地刷新成「未登录」的个人主页 ——
  /// 这样用户能直接看到登录入口，而不是被弹回主界面。
  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text(
          '退出后会回到未登录状态。\n'
          '各账号的观看记录、搜索记录、播放进度都是分开保存的，'
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

    // 清掉本地缓存的账号资料，避免退出后还显示旧账号内容。
    //
    // 注意前缀要和实际写入的 key 对得上：用户主页的 key 是
    // `/api/user/{id}?tab=...`（见 AppCache.buildKey 的用法）。
    // 之前这里写的是 'user_' 和 'video_detail_' —— 两个都匹配不到任何
    // 真实 key，等于没清（`video_detail_` 更是早就不用了）。
    AppCache.removeWherePrefix('/api/user/');

    await AuthController.logout();

    if (!mounted) return;

    // 就地切成「未登录」视图
    setState(() {
      _selfOverride = true;
      _tabsOverride = _buildTabs(self: true);
      _sections = [];
      _videos = [];
      _playlists = [];
      _error = null;
      _loading = false;
      _tab = _tabsOverride!.first.key;

      _tabController?.dispose();
      _tabController = TabController(
        length: _tabsOverride!.length,
        vsync: this,
      );
    });

    AppToast.show(context, '已退出登录');
  }

  /// 未登录时的个人主页：告诉用户登录后能看到什么，并给登录入口。
  Widget _buildLoggedOut(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.account_circle_outlined,
              size: 76,
              color: theme.colorScheme.primary.withValues(alpha: 0.55),
            ),
            const SizedBox(height: 18),
            const Text(
              '还没有登录',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: 380,
              child: Text(
                '登录后可以查看自己的观看记录、稍后观看、赞好的影片和播放清单，'
                '也能直接对影片点赞和储存（会同步到官网账号）。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.65),
                ),
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: _openLogin,
              icon: const Icon(Icons.login),
              label: const Text('登录'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 26,
                  vertical: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 在当前页面里登录，登录成功后自动加载自己的资料。
  Future<void> _openLogin() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const LoginDialog(),
    );

    if (ok != true || !mounted) return;

    final info = AuthController.account.value;

    setState(() {
      _effectiveUserId = info.userId;
      _selfOverride = true;
      _tabsOverride = _buildTabs(self: true);
      _name = info.username;
      _avatar = info.avatar;
      _error = null;
      _loading = true;
      _tab = _tabsOverride!.first.key;

      _tabController?.dispose();
      _tabController = TabController(
        length: _tabsOverride!.length,
        vsync: this,
      );
    });

    await _load();
  }

  /// 加载某个 tab 的内容。
  ///
  /// [page] 只对列表类 tab 有效（每页 60 条）；主页不需要翻页。
  ///
  /// [silent] 为 true 时是「静默刷新」：保留屏幕上已有的内容，
  /// 不显示整页转圈，后台取到新数据后原地替换。
  /// 用在「从影片详情返回」这类场景 —— 用户可能刚改了储存状态，
  /// 列表要跟着变，但不该先白屏一次。
  Future<void> _load({
    String? tab,
    int page = 1,
    bool silent = false,
  }) async {
    final target = tab ?? _tab;

    // 主页没有分页，固定第 1 页
    final targetPage = target == 'home' ? 1 : (page < 1 ? 1 : page);

    // 「主页」走栏目段接口，其余 tab 走普通列表接口
    final path = target == 'home'
        ? '/api/user/$_effectiveUserId/home'
        : '/api/user/$_effectiveUserId';

    final cacheKey = AppCache.buildKey(
      path,
      target == 'home' ? {'tab': target} : {'tab': target, 'page': targetPage},
    );

    final switching = target != _tab || targetPage != _page;

    // 先拿缓存：有的话立刻显示，不用等请求
    Map<String, dynamic>? cached;

    if (!silent) {
      final hit = AppCache.get(cacheKey);

      if (hit is Map) cached = Map<String, dynamic>.from(hit);
    }

    setState(() {
      _tab = target;
      _page = targetPage;
      _error = null;

      // 换 tab / 翻页才清掉旧内容（避免显示上一个 tab 的数据）
      if (switching) {
        _videos = [];
        _playlists = [];
        _sections = [];
      }

      // 静默刷新时有内容可看，就不转圈
      _loading = !silent && cached == null;
    });

    if (cached != null) {
      _apply(cached);
    }

    try {
      final uri = Uri.parse('$_base$path').replace(
        queryParameters: target == 'home'
            ? null
            : {'tab': target, 'page': '$targetPage'},
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

      final map = Map<String, dynamic>.from(data);

      AppCache.set(cacheKey, map, ttl: AppCache.userTtl);

      _apply(map);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;

        // 屏幕上已经有内容（缓存或刷新的旧数据）时不要把整页换成错误页
        final hasContent = _videos.isNotEmpty ||
            _playlists.isNotEmpty ||
            _sections.isNotEmpty;

        if (!hasContent) {
          _error = '加载失败：$e';
        }
      });
    }
  }

  void _apply(Map<String, dynamic> data) {
    if (!mounted) return;

    setState(() {
      _loading = false;

      final name = data['name']?.toString() ?? '';

      if (name.isNotEmpty) _name = name;

      final avatar = data['avatar']?.toString() ?? '';

      if (avatar.isNotEmpty) _avatar = avatar;

      _videos = List<Map<String, dynamic>>.from(
        data['videos'] ?? [],
      );

      _playlists = List<Map<String, dynamic>>.from(
        data['playlists'] ?? [],
      );

      _sections = List<Map<String, dynamic>>.from(
        data['sections'] ?? [],
      );

      _totalPages =
          int.tryParse(data['total_pages']?.toString() ?? '') ?? 1;

      if (_totalPages < 1) _totalPages = 1;
    });
  }

  String? _extractVideoId(String url) {
    final uri = Uri.tryParse(url);

    return uri?.queryParameters['v'];
  }

  void _openVideo(String url) {
    final id = _extractVideoId(url);

    if (id == null || id.isEmpty) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoDetailPage(videoId: id),
      ),
    );
    // 不用在这里手动刷新：详情页改了储存状态会 DataRevision.bump()，
    // 本页监听到就静默刷新了（见 _onDataChanged）。
  }

  void _openPlaylist(String url, String name) {
    if (url.isEmpty) return;

    // 播放清单用后端的 list_id 打开
    final uri = Uri.tryParse(url);
    final listId = uri?.queryParameters['list'];

    if (listId == null || listId.isEmpty) return;

    _openPlaylistId(listId, name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_name.isEmpty ? '用户主页' : _name),
        // 这里**不**放 actions。
        //
        // 无边框窗口 + 自绘标题栏之后 AppBar 是顶到 y=0 的，
        // 而窗口右上角那三个按钮（最小化/最大化/关闭）是浮在最上面的
        // 实心控件、占着右上角 138x38：放在 actions 里的图标会被压住，
        // 往左让开 138px 又会让图标孤零零悬在中间。
        // 所以刷新/退出挪到了下面标签页那一行的右端 ——
        // 那里本来就空着（标签页是从左边排的），而且已经避开了窗口按钮。
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(_tabRowHeight),
          child: SizedBox(
            height: _tabRowHeight,
            child: Row(
              children: [
                Expanded(
                  child: TabBar(
                    controller: _tabController,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    onTap: (index) {
                      final key = _tabs[index].key;

                      if (key != _tab) _load(tab: key);
                    },
                    tabs: [
                      for (final t in _tabs)
                        Tab(
                          icon: Icon(t.icon, size: 18),
                          text: t.label,
                          height: 52,
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: () => _load(),
                  icon: const Icon(Icons.refresh),
                ),
                // 只有看自己的主页时才给登出入口
                if (_isSelf)
                  IconButton(
                    tooltip: '退出登录',
                    onPressed: _logout,
                    icon: const Icon(Icons.logout),
                  ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
      body: _buildBody(theme),
    );
  }

  /// 标签页那一行的高度（TabBar 的 52 + 底下 2px 指示条）
  static const double _tabRowHeight = 54;

  Widget _buildBody(ThemeData theme) {
    // 未登录：显示登录引导，而不是空的 tab 页
    if (!AuthController.isLoggedIn) {
      return _buildLoggedOut(theme);
    }

    if (_loading) {
      return const Center(child: Windows11Loading(size: 48));
    }

    return Column(
      children: [
        _buildHeader(theme),
        Expanded(
          child: _error != null
              ? _buildError()
              : _buildContent(theme),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _load(),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Row(
        children: [
          CircleAvatar(
            radius: 34,
            backgroundColor:
                theme.colorScheme.primary.withValues(alpha: 0.15),
            backgroundImage:
                _avatar.isEmpty ? null : NetworkImage(_avatar),
            child: _avatar.isEmpty
                ? Icon(
                    Icons.person_outline,
                    size: 32,
                    color: theme.colorScheme.primary,
                  )
                : null,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _name.isEmpty ? '用户 $_effectiveUserId' : _name,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'ID $_effectiveUserId',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    // 「主页」：显示各栏目段（每段最多 10 个），右边有「查看更多」
    if (_tab == 'home') {
      if (_sections.isEmpty) {
        return _buildEmpty('这个账号还没有公开内容');
      }

      return _buildSections(theme);
    }

    if (_tab == 'playlists') {
      if (_playlists.isEmpty) {
        return _buildEmpty('这个账号还没有播放清单');
      }

      return _buildPaged(_buildPlaylistGrid(theme));
    }

    if (_videos.isEmpty) {
      switch (_tab) {
        case 'likes':
          return _buildEmpty('还没有赞好的影片');
        case 'histories':
          return _buildEmpty('还没有观看纪录');
        case 'saves':
          return _buildEmpty('稍后观看是空的');
        default:
          return _buildEmpty('这里还没有内容');
      }
    }

    return _buildPaged(_buildVideoGrid(theme));
  }

  /// 给列表内容套上分页条（每页 60 条，历史记录有 30 页，不翻页看不完）。
  ///
  /// 用统一的 PagerBar，和观看记录 / 播放清单的外观一致。
  Widget _buildPaged(Widget content) {
    if (_totalPages <= 1) return content;

    return Column(
      children: [
        Expanded(child: content),
        const Divider(height: 1),
        PagerBar(
          page: _page,
          totalPages: _totalPages,
          loading: _loading,
          onGoToPage: (target) => _load(page: target),
        ),
      ],
    );
  }

  /// 「主页」的栏目段列表。
  ///
  /// 和 APP 首页的栏目段一个意思：横向一排卡片 + 右边「查看更多」。
  Widget _buildSections(ThemeData theme) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      itemCount: _sections.length,
      itemBuilder: (context, index) {
        final section = _sections[index];

        final name = section['name']?.toString() ?? '';
        final url = section['url']?.toString() ?? '';
        final kind = section['kind']?.toString() ?? 'videos';

        final videos = List<Map<String, dynamic>>.from(
          section['videos'] ?? [],
        );
        final playlists = List<Map<String, dynamic>>.from(
          section['playlists'] ?? [],
        );

        final targetTab = _tabKeyFromUrl(url);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行：左边名字，右边「查看更多」
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (targetTab != null)
                    TextButton.icon(
                      onPressed: () => _goToTab(targetTab),
                      iconAlignment: IconAlignment.end,
                      icon: const Icon(
                        Icons.arrow_forward_ios,
                        size: 13,
                      ),
                      label: const Text('查看更多'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                        ),
                        minimumSize: const Size(0, 32),
                        tapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                    ),
                ],
              ),
            ),

            // 响应式网格（和 APP 首页栏目段一致）
            _SectionsGridView(
              videos: kind == 'playlists' ? playlists : videos,
              isPlaylist: kind == 'playlists',
              onOpenVideo: (url) => _openVideo(url),
              onOpenPlaylist: _openPlaylistId,
            ),
          ],
        );
      },
    );
  }

  /// 切到指定 tab（「查看更多」用）
  void _goToTab(String key) {
    final index = _tabs.indexWhere((t) => t.key == key);

    if (index < 0) return;

    _tabController?.animateTo(index);

    _load(tab: key);
  }

  void _openPlaylistId(String listId, String name) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(
          listId: listId,
          playlistName: name,
        ),
      ),
    );
  }

  Widget _buildEmpty(String text) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inbox_outlined,
            size: 44,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: 0.3),
          ),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  /// 个人主页的网格统一用首页那套尺寸（见 widgets/video_card.dart）。
  ///
  /// 以前这里用的是 maxCrossAxisExtent: 240 + childAspectRatio: 0.95，
  /// 和首页的「按宽度分列 + 固定文字区高度」不是一套算法，
  /// 于是同一个视频在首页和个人主页里卡片大小对不上。
  Widget _cardGrid({
    required int count,
    required Widget Function(BuildContext context, int index) itemBuilder,
    EdgeInsets padding = const EdgeInsets.all(24),
    bool shrinkWrap = false,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = videoCardMetrics(
          maxWidth: constraints.maxWidth,
          horizontalPadding: padding.left + padding.right,
        );

        return GridView.builder(
          shrinkWrap: shrinkWrap,
          physics: shrinkWrap
              ? const NeverScrollableScrollPhysics()
              : null,
          padding: padding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: metrics.columns,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            mainAxisExtent: metrics.itemHeight,
          ),
          itemCount: count,
          itemBuilder: itemBuilder,
        );
      },
    );
  }

  Widget _buildVideoGrid(ThemeData theme) {
    return _cardGrid(
      count: _videos.length,
      itemBuilder: (context, index) {
        return _ProfileCard(
          title: _videos[index]['title']?.toString() ?? '',
          thumbnail: _videos[index]['thumbnail']?.toString() ?? '',
          subtitle: _videos[index]['duration']?.toString() ?? '',
          trailing: _videos[index]['views']?.toString() ?? '',
          onTap: () =>
              _openVideo(_videos[index]['url']?.toString() ?? ''),
        );
      },
    );
  }

  Widget _buildPlaylistGrid(ThemeData theme) {
    return _cardGrid(
      count: _playlists.length,
      itemBuilder: (context, index) {
        final count = _playlists[index]['video_count']?.toString() ?? '';

        return _ProfileCard(
          title: _playlists[index]['name']?.toString() ?? '',
          thumbnail:
              _playlists[index]['thumbnail']?.toString() ?? '',
          subtitle: count.isEmpty ? '' : '$count 部影片',
          icon: Icons.playlist_play,
          onTap: () => _openPlaylist(
            _playlists[index]['url']?.toString() ?? '',
            _playlists[index]['name']?.toString() ?? '',
          ),
        );
      },
    );
  }
}

/// 用户主页上的卡片（影片 / 播放清单共用）
class _ProfileCard extends StatefulWidget {
  final String title;
  final String thumbnail;
  final String subtitle;
  final String trailing;
  final IconData? icon;
  final VoidCallback onTap;

  const _ProfileCard({
    required this.title,
    required this.thumbnail,
    this.subtitle = '',
    this.trailing = '',
    this.icon,
    required this.onTap,
  });

  @override
  State<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<_ProfileCard> {
  /// 卡片内边距
  static const double _cardPadding = 6;

  /// 缩略图长宽比，和 APP 首页 / 观看记录保持一致（16:9）
  static const double thumbAspect = 16 / 9;

  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(_cardPadding),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: _hovering
                ? theme.colorScheme.primary.withValues(alpha: 0.08)
                : Colors.transparent,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 缩略图统一按 16:9 画（跟 APP 首页、观看记录一致）。
              //
              // 以前这里用 Expanded：缩略图会「撑满标题之外剩下的高度」，
              // 于是标题一行/两行、有没有副标题都会改变缩略图高度，
              // 同一页里缩略图大小就不一样了。
              // 改成 AspectRatio 后，高度只由宽度决定，处处一致。
              AspectRatio(
                aspectRatio: thumbAspect,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                          if (widget.thumbnail.isEmpty)
                            Container(
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
                          else
                            Image.network(
                              widget.thumbnail,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Container(
                                color: isDark
                                    ? Colors.white10
                                    : Colors.black12,
                                child: const Icon(
                                  Icons.broken_image_outlined,
                                  color: Colors.white38,
                                ),
                              ),
                            ),
                          if (widget.icon != null)
                            Positioned(
                              right: 6,
                              top: 6,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Icon(
                                  widget.icon,
                                  size: 14,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          if (widget.subtitle.isNotEmpty &&
                              widget.icon != null)
                            Positioned(
                              left: 6,
                              bottom: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color:
                                      Colors.black.withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  widget.subtitle,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, height: 1.35),
                  ),
                  if (widget.icon == null &&
                      (widget.subtitle.isNotEmpty ||
                          widget.trailing.isNotEmpty))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        [widget.subtitle, widget.trailing]
                            .where((s) => s.isNotEmpty)
                            .join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.55),
                        ),
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 个人主页栏目段的响应式网格。
///
/// 列数和卡片宽度随窗口宽度变化，和 APP 首页的栏目段一致
/// （用户要求去掉横向滑块，改回网格）。
class _SectionsGridView extends StatelessWidget {
  final List<Map<String, dynamic>> videos;
  final bool isPlaylist;
  final void Function(String url) onOpenVideo;
  final void Function(String listId, String name) onOpenPlaylist;

  const _SectionsGridView({
    required this.videos,
    required this.isPlaylist,
    required this.onOpenVideo,
    required this.onOpenPlaylist,
  });

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        // 尺寸和首页统一（见 widgets/video_card.dart）
        final metrics = videoCardMetrics(
          maxWidth: constraints.maxWidth,
          horizontalPadding: 48,
        );

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: metrics.columns,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            mainAxisExtent: metrics.itemHeight,
          ),
          itemCount: videos.length,
          itemBuilder: (context, i) {
            if (isPlaylist) {
              final pl = videos[i];

              return _ProfileCard(
                title: pl['name']?.toString() ?? '',
                thumbnail: pl['thumbnail']?.toString() ?? '',
                subtitle: pl['video_count']?.toString() ?? '',
                icon: Icons.playlist_play,
                onTap: () {
                  final id = pl['list_id']?.toString();

                  if (id == null || id.isEmpty) return;

                  onOpenPlaylist(id, pl['name']?.toString() ?? '');
                },
              );
            }

            final v = videos[i];

            return _ProfileCard(
              title: v['title']?.toString() ?? '',
              thumbnail: v['thumbnail']?.toString() ?? '',
              subtitle: v['duration']?.toString() ?? '',
              trailing: v['views']?.toString() ?? '',
              onTap: () => onOpenVideo(v['url']?.toString() ?? ''),
            );
          },
        );
      },
    );
  }
}