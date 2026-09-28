import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'controllers/app_cache.dart';
import 'controllers/app_config.dart';
import 'main.dart';
import 'widgets/windows11_loading.dart';
import 'widgets/pager_bar.dart';

/// 新番预告。
///
/// 对应官网的
/// `https://hanime1.me/search?genre=%E6%96%B0%E7%95%AA%E9%A0%90%E5%91%8A`
/// （genre = 新番預告）。
///
/// 数据走已有的 `/api/filter`，所以缓存、分页行为都和其它列表页一致。
class NewReleasePage extends StatefulWidget {
  const NewReleasePage({super.key});

  /// 官网的 genre 参数值
  static const String genre = '新番預告';

  @override
  State<NewReleasePage> createState() => _NewReleasePageState();
}

class _NewReleasePageState extends State<NewReleasePage> {
  List<Map<String, dynamic>> _videos = [];

  int _page = 1;
  int _totalPages = 1;

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({int page = 1}) async {
    final target = page < 1 ? 1 : page;

    setState(() {
      _loading = true;
      _error = null;
    });

    final params = {
      'genre': NewReleasePage.genre,
      'page': '$target',
    };

    final cacheKey = AppCache.buildKey('/api/filter', params);
    final cached = AppCache.get(cacheKey);

    if (cached is Map && cached['results'] is List) {
      setState(() {
        _videos = List<Map<String, dynamic>>.from(cached['results']);
        _totalPages =
            int.tryParse('${cached['total_pages']}') ?? 1;

        if (_totalPages < 1) _totalPages = 1;

        _page = target;
        _loading = false;
      });

      return;
    }

    try {
      final uri = Uri.parse('${AppConfig.backendBase}/api/filter')
          .replace(queryParameters: params);

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

      final results = List<Map<String, dynamic>>.from(
        data['results'] ?? [],
      );

      final totalPages =
          int.tryParse('${data['total_pages']}') ?? 1;

      AppCache.set(
        cacheKey,
        {
          'results': results,
          'total_pages': totalPages,
        },
        ttl: AppCache.searchTtl,
      );

      if (!mounted) return;

      setState(() {
        _videos = results;
        _page = target;
        _totalPages = totalPages < 1 ? 1 : totalPages;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = '新番预告加载失败：$e';
      });
    }
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
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Center(child: Windows11Loading(size: 48));
    }

    if (_error != null) {
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

    if (_videos.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.new_releases_outlined,
              size: 44,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(
              '暂时没有新番预告',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      );
    }

    // 这里**没有**页内标题栏：侧边栏已经写着"新番预告"了，
    // 再加一行"图标 + 新番预告 + 刷新"纯属占地方（用户要求去掉）。
    // 刷新用下拉刷新，见 _buildGrid 外面的 RefreshIndicator。
    return Column(
      children: [
        Expanded(child: _buildGrid()),
        if (_totalPages > 1) _buildPager(theme),
      ],
    );
  }

  /// 这一页封面的统一比例（新番预告是竖版 0.68）。
  ///
  /// 用中位数而不是取第一张：万一某张图加载失败就没有比例信息，
  /// 取第一张会不稳。
  double get _coverAspect {
    final ratios = <double>[];

    for (final v in _videos) {
      final r = v['thumb_ratio'];

      if (r is num && r > 0.2 && r < 5) ratios.add(r.toDouble());
    }

    if (ratios.isEmpty) return 16 / 9;

    ratios.sort();

    return ratios[ratios.length ~/ 2];
  }

  Widget _buildGrid() {
    // 卡片宽度用 maxCrossAxisExtent 决定，高度按封面比例算出来。
    // 竖版封面要留出足够高度，否则标题会被挤出屏幕。
    const maxCardWidth = 200.0;
    final coverHeight = maxCardWidth / _coverAspect;

    // 封面 + 标题两行 + 一行信息
    final cardHeight = coverHeight + 56;

    // 右上角那个刷新按钮已经去掉了，改成下拉刷新 ——
    // 不然这一页就没法刷新了（它不会像列表那样自己重载）。
    return RefreshIndicator(
      onRefresh: () => _load(page: _page),
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: maxCardWidth,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
          mainAxisExtent: cardHeight,
        ),
        itemCount: _videos.length,
        itemBuilder: (context, index) {
          final video = _videos[index];

          final rawRatio = video['thumb_ratio'];

          return VideoGridCard(
            title: video['title']?.toString() ?? '',
            thumbnail: video['thumbnail']?.toString() ?? '',
            duration: video['duration']?.toString() ?? '',
            views: video['views']?.toString() ?? '',
            aspectRatio: rawRatio is num && rawRatio > 0.2 && rawRatio < 5
                ? rawRatio.toDouble()
                : null,
            onTap: () => _openVideo(video['url']?.toString() ?? ''),
          );
        },
      ),
    );
  }

  Widget _buildPager(ThemeData theme) {
    return Column(
      children: [
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
}

/// 影片栅格卡片（封面 + 标题 + 时长/播放量）。
///
/// 抽成公开组件，方便别的列表页复用同一套外观。
class VideoGridCard extends StatefulWidget {
  final String title;
  final String thumbnail;
  final String duration;
  final String views;
  final VoidCallback onTap;

  /// 封面真实宽高比。
  ///
  /// 「新番預告」的封面是竖版（实测 268x394，约 0.68），
  /// 硬按 16:9 画会把竖图裁掉一大半。为 null 时退回 16:9。
  final double? aspectRatio;

  const VideoGridCard({
    super.key,
    required this.title,
    required this.thumbnail,
    this.duration = '',
    this.views = '',
    this.aspectRatio,
    required this.onTap,
  });

  @override
  State<VideoGridCard> createState() => _VideoGridCardState();
}

class _VideoGridCardState extends State<VideoGridCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final meta = [
      if (widget.duration.isNotEmpty) widget.duration,
      if (widget.views.isNotEmpty) widget.views,
    ].join(' · ');

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(6),
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
              // 按封面真实比例画（竖版就画竖版）。
              // 用 AspectRatio 而不是 Expanded：Expanded 会让缩略图
              // 随标题行数变化高度，同一页里大小不一。
              AspectRatio(
                aspectRatio: widget.aspectRatio ?? 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (widget.thumbnail.isEmpty)
                        Container(
                          color: isDark ? Colors.white10 : Colors.black12,
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
                      if (widget.duration.isNotEmpty)
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              widget.duration,
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
              if (meta.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    meta,
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
