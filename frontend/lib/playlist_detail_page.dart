import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'main.dart';
import 'controllers/auth_controller.dart';
import 'login_dialog.dart';
import 'widgets/app_toast.dart';
import 'widgets/windows11_loading.dart';
import 'controllers/app_config.dart';
import 'controllers/data_revision.dart';

class PlaylistDetailPage extends StatefulWidget {
  final String listId;
  final String playlistName;

  const PlaylistDetailPage({
    super.key,
    required this.listId,
    required this.playlistName,
  });

  @override
  State<PlaylistDetailPage> createState() =>
      _PlaylistDetailPageState();
}

class _PlaylistDetailPageState
    extends State<PlaylistDetailPage> {
  List<Map<String, dynamic>> _videos = [];

  bool _loading = true;
  String? _error;

  /// 这个播放清单是否已收藏（右上角书签：实心=已收藏，空心=未收藏）
  bool _bookmarked = false;

  /// 这个清单能不能收藏。
  ///
  /// 官网在**自己的**播放清单页面上不放书签表单（自己的清单没什么可收藏的），
  /// 这时按钮置灰并说明原因，而不是点了报错。
  bool _canBookmark = true;

  @override
  void initState() {
    super.initState();
    _loadPlaylist();
  }

  /// 收藏 / 取消收藏这个播放清单。
  ///
  /// 对应官网播放清单页右上角的书签：
  ///
  ///     <form id="playlist-show-add-form" method="POST"
  ///           action="https://hanime1.me/addPlaylist">
  ///       <input name="_token" ...>
  ///       <input name="playlist-reference-id" value="976998">
  ///     </form>
  ///
  /// 点一下书签 = POST 一次，状态**翻转**。图标随之在实心/空心之间切换。
  ///
  /// 和点赞一样做乐观更新：图标立刻翻转，后台才去同步官网。
  Future<void> _toggleBookmark() async {
    if (!AuthController.isLoggedIn) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => const LoginDialog(),
      );

      if (ok != true || !mounted) return;
    }

    final previous = _bookmarked;

    // 乐观翻转
    setState(() => _bookmarked = !previous);

    AppToast.show(
      context,
      previous ? '正在取消收藏…' : '正在收藏…',
    );

    try {
      final response = await http.post(
        Uri.parse(
          '${AppConfig.backendBase}/api/playlist/${widget.listId}/bookmark',
        ),
        headers: const {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 120));

      final data = jsonDecode(response.body);

      if (!mounted) return;

      if (response.statusCode != 200) {
        final detail = data is Map ? data['detail']?.toString() : null;

        throw Exception(detail ?? '操作失败（${response.statusCode}）');
      }

      final saved = (data is Map ? data['state'] : null);

      setState(() {
        if (saved is Map && saved['bookmarked'] is bool) {
          _bookmarked = saved['bookmarked'] as bool;
        }
      });

      // 收藏状态会影响个人主页的播放清单列表，通知它们刷新
      DataRevision.bump();

      AppToast.success(
        context,
        (data is Map ? data['message']?.toString() : null) ??
            (_bookmarked ? '已收藏' : '已取消收藏'),
      );
    } catch (e) {
      if (!mounted) return;

      // 失败回滚
      setState(() => _bookmarked = previous);

      AppToast.error(context, '收藏失败：$e');
    }
  }

  Future<void> _loadPlaylist() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final uri = Uri.parse(
        '${AppConfig.backendBase}/api/playlist',
      ).replace(
        queryParameters: {
          'list_id': widget.listId,
        },
      );

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

      if (!mounted) return;

      setState(() {
        _videos = results;
        _bookmarked = data['bookmarked'] == true;
        _canBookmark = data['can_bookmark'] != false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = '播放清单加载失败：$e';
      });
    }
  }

  /// 标题下面那一行（影片数量 + 收藏书签）的高度。
  ///
  /// 40 而不是 IconButton 默认的 48：这一行只是为了把书签从
  /// 右上角挪下来，尽量少占竖向空间。
  static const double _infoRowHeight = 40;

  /// 收藏 / 取消收藏的书签按钮。
  ///
  /// **不放在 AppBar 的 actions 里**：无边框窗口 + 自绘标题栏之后
  /// AppBar 是顶到 y=0 的，而窗口右上角那三个按钮（最小化/最大化/关闭）
  /// 是浮在最上面的实心控件、占着右上角 138x38 ——
  /// 放 actions 里会被压住，往左让开 138px 又会孤零零悬在中间。
  ///
  /// 所以放到下面那一行的**右端**（和个人主页的刷新/退出一个思路）：
  /// 它落在 y≈56~96，已经避开窗口按钮，而且仍然贴着右边。
  Widget _buildBookmarkButton(BuildContext context) {
    // 官网播放清单页右上角就是这个书签：
    // 实心 = 已收藏，空心 = 未收藏。点一下切换。
    // 自己的清单没有这个书签（没得收藏），这时置灰并说明。
    return IconButton(
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      tooltip: !_canBookmark
          ? '这是你自己的播放清单，不需要收藏'
          : (_bookmarked ? '已收藏（点击取消）' : '收藏这个播放清单'),
      onPressed: _canBookmark ? _toggleBookmark : null,
      icon: Icon(
        _bookmarked ? Icons.bookmark : Icons.bookmark_border,
        color: _bookmarked ? Theme.of(context).colorScheme.primary : null,
      ),
    );
  }

  /// 标题下面那一行：左边影片数量，右边收藏书签。
  Widget _buildInfoRow(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      height: _infoRowHeight,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 8),
        child: Row(
          children: [
            if (!_loading && _error == null && _videos.isNotEmpty)
              Text(
                '共 ${_videos.length} 部',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const Spacer(),
            _buildBookmarkButton(context),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.playlistName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(_infoRowHeight),
          child: _buildInfoRow(context),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
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
              style: const TextStyle(
                color: Colors.red,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _loadPlaylist,
              icon: const Icon(Icons.refresh),
              label: const Text('重新加载'),
            ),
          ],
        ),
      );
    }

    if (_videos.isEmpty) {
      return const Center(
        child: Text('这个播放清单没有影片'),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(24),
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        final video = _videos[index];

        final title =
            video['title']?.toString() ?? '';

        final videoId =
            video['video_id']?.toString() ?? '';

        final thumbnail =
            video['thumbnail']?.toString() ?? '';

        final duration =
            video['duration']?.toString() ?? '';

        final rating =
            video['rating']?.toString() ?? '';

        final views =
            video['views']?.toString() ?? '';

        return Padding(
          padding: const EdgeInsets.only(
            bottom: 16,
          ),
          child: Material(
            color: Theme.of(context)
                .colorScheme
                .surface,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () {
                if (videoId.isEmpty) {
                  return;
                }

                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) {
                      return VideoDetailPage(
                        videoId: videoId,
                      );
                    },
                  ),
                );
              },
              child: SizedBox(
                height: 180,
                child: Row(
                  crossAxisAlignment:
                      CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 300,
                      child: _buildThumbnail(
                        thumbnail,
                        duration,
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding:
                            const EdgeInsets.fromLTRB(
                          18,
                          14,
                          18,
                          14,
                        ),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 3,
                              overflow:
                                  TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight:
                                    FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            Wrap(
                              spacing: 18,
                              runSpacing: 8,
                              children: [
                                if (rating.isNotEmpty)
                                  _buildMetaItem(
                                    Icons.thumb_up_outlined,
                                    rating,
                                  ),
                                if (views.isNotEmpty)
                                  _buildMetaItem(
                                    Icons.visibility_outlined,
                                    views,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '视频 ID：$videoId',
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(
                        right: 14,
                      ),
                      child: Center(
                        child: Icon(
                          Icons.chevron_right,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildThumbnail(
    String thumbnail,
    String duration,
  ) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumbnail.isEmpty)
          Container(
            color: Colors.black12,
            child: const Icon(
              Icons.image_not_supported,
              size: 48,
            ),
          )
        else
          Image.network(
            thumbnail,
            fit: BoxFit.cover,
            errorBuilder:
                (
                  context,
                  error,
                  stackTrace,
                ) {
              return Container(
                color: Colors.black12,
                child: const Icon(
                  Icons.broken_image,
                  size: 48,
                ),
              );
            },
            loadingBuilder:
                (
                  context,
                  child,
                  loadingProgress,
                ) {
              if (loadingProgress == null) {
                return child;
              }

              return Container(
                color: Colors.black12,
                child: const Center(
                  child:
                      CircularProgressIndicator(),
                ),
              );
            },
          ),
        if (duration.isNotEmpty)
          Positioned(
            right: 10,
            bottom: 10,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 7,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius:
                    BorderRadius.circular(4),
              ),
              child: Text(
                duration,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMetaItem(
    IconData icon,
    String text,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 17,
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade700,
          ),
        ),
      ],
    );
  }
}