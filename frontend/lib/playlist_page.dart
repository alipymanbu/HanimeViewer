import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'playlist_detail_page.dart';
import 'widgets/windows11_loading.dart';
import 'controllers/app_config.dart';
import './widgets/app_toast.dart';
import 'widgets/pager_bar.dart';
import 'controllers/data_revision.dart';
import 'widgets/video_card.dart';

class PlaylistPage extends StatefulWidget {
  const PlaylistPage({super.key});

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  List<Map<String, dynamic>> _playlists = [];

  int _page = 1;

  /// 总页数。
  ///
  /// 以前这里写死 8（还有个「不足 8 也按 8 算」的下限），
  /// 结果只有 1 页的账号也会显示 8 页页码，点第 2 页就空白。
  /// 现在完全由服务端返回的 total_pages 决定，没有数据就保持 1（等于不显示分页）。
  int _totalPages = 1;

  /// 服务端是否已经回过至少一次（没回过就不显示分页）
  bool _loadedOnce = false;

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();

    // 别处改了数据（储存/取消储存/新建清单）时静默刷新
    DataRevision.revision.addListener(_onDataChanged);

    _loadPlaylists();
  }

  @override
  void dispose() {
    DataRevision.revision.removeListener(_onDataChanged);
    super.dispose();
  }

  /// 全局数据变了：静默刷新清单列表（影片数会变）
  void _onDataChanged() {
    if (!mounted) return;

    _loadPlaylists(page: _page, silent: true);
  }

  /// [silent] 为 true 时保留当前列表、不显示加载转圈，
  /// 后台取到新数据后原地替换（用在"从详情页返回"这类场景）。
  Future<void> _loadPlaylists({int? page, bool silent = false}) async {
    final targetPage = page ?? _page;

    if (targetPage < 1 || targetPage > _totalPages) {
      return;
    }

    setState(() {
      _loading = !silent;
      _error = null;
    });

    try {
      final uri = Uri.parse(
        '${AppConfig.backendBase}/api/playlists',
      ).replace(
        queryParameters: {
          'page': targetPage.toString(),
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

      final currentPage =
          int.tryParse(
                data['page']?.toString() ?? '',
              ) ??
              targetPage;

      final serverTotalPages =
          int.tryParse(
                data['total_pages']?.toString() ?? '',
              ) ??
              1;

      if (!mounted) return;

      setState(() {
        _playlists = results;
        _page = currentPage;

        // 用服务端真实页数，不再有「最少 8 页」这种下限
        _totalPages = serverTotalPages < 1 ? 1 : serverTotalPages;
        _loadedOnce = true;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = '播放清单加载失败：$e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _openPlaylist(
    Map<String, dynamic> playlist,
  ) {
    final name =
        playlist['name']?.toString() ?? '';

    final url =
        playlist['url']?.toString() ?? '';

    if (url.isEmpty) {
      return;
    }

    final uri = Uri.tryParse(url);

    if (uri == null) {
      return;
    }

    final listId =
        uri.queryParameters['list'] ?? '';

    if (listId.isEmpty) {
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) {
          return PlaylistDetailPage(
            listId: listId,
            playlistName: name,
          );
        },
      ),
    );
    // 不用手动刷新：清单里的影片被改动时会 DataRevision.bump()
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _playlists.isEmpty) {
      return const Center(
        child: Windows11Loading(size: 48),
      );
    }
    
    if (_error != null && _playlists.isEmpty) {
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
              onPressed: _loadPlaylists,
              icon: const Icon(Icons.refresh),
              label: const Text('重新加载'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        if (_loading)
          const LinearProgressIndicator(),

        Expanded(
          child: RefreshIndicator(
            onRefresh: () {
              return _loadPlaylists(
                page: _page,
              );
            },
            child: LayoutBuilder(
              builder: (
                context,
                constraints,
              ) {
                // 尺寸和首页统一（见 widgets/video_card.dart）
                final metrics = videoCardMetrics(
                  maxWidth: constraints.maxWidth,
                  horizontalPadding: 36,
                );

                return GridView.builder(
                  padding: const EdgeInsets.all(18),
                  gridDelegate:
                      SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: metrics.columns,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    mainAxisExtent: metrics.itemHeight,
                  ),
                  itemCount: _playlists.length,
                  itemBuilder: (
                    context,
                    index,
                  ) {
                    final playlist =
                        _playlists[index];

                    final name =
                        playlist['name']
                                ?.toString() ??
                            '';

                    final videoCount =
                        playlist['video_count']
                                ?.toString() ??
                            '';

                    final thumbnail =
                        playlist['thumbnail']
                                ?.toString() ??
                            '';

                    return _PlaylistCard(
                      name: name,
                      videoCount: videoCount,
                      thumbnail: thumbnail,
                      onTap: () {
                        _openPlaylist(
                          playlist,
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ),

        // 只有真的存在多页时才显示分页条。
        // 没有播放清单（或只有一页）就不显示，「有多少页显示多少页」。
        if (_loadedOnce && _playlists.isNotEmpty)
          PagerBar(
            page: _page,
            totalPages: _totalPages,
            loading: _loading,
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 14),
            onGoToPage: (target) => _loadPlaylists(page: target),
          ),
      ],
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  final String name;
  final String videoCount;
  final String thumbnail;
  final VoidCallback onTap;

  const _PlaylistCard({
    required this.name,
    required this.videoCount,
    required this.thumbnail,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 缩略图统一 16:9（和其它影片卡片一致）。
            // 以前是 Expanded flex 6/4，缩略图比例会随卡片高度变化。
            AspectRatio(
              aspectRatio: 16 / 9,
              child: _buildThumbnail(),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(
                10,
                7,
                8,
                7,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),

                    if (videoCount.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.video_library_outlined,
                              size: 15,
                              color: Colors.grey,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                videoCount,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.1,
                                  color: Colors.grey,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail() {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumbnail.isEmpty)
          Container(
            color: Colors.black12,
            child: const Icon(
              Icons.image_not_supported,
              size: 36,
            ),
          )
        else
          Image.network(
            thumbnail,
            fit: BoxFit.cover,
            errorBuilder: (
              context,
              error,
              stackTrace,
            ) {
              return Container(
                color: Colors.black12,
                child: const Icon(
                  Icons.broken_image,
                  size: 36,
                ),
              );
            },
            loadingBuilder: (
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
                  child: CircularProgressIndicator(),
                ),
              );
            },
          ),

        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 5,
            ),
            color: Colors.black54,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Icon(
                  Icons.playlist_play,
                  color: Colors.white,
                  size: 16,
                ),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    videoCount.isEmpty
                        ? '影片数量未知'
                        : videoCount,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PageJumpDialog extends StatefulWidget {
  final int currentPage;
  final int totalPages;

  const _PageJumpDialog({
    required this.currentPage,
    required this.totalPages,
  });

  @override
  State<_PageJumpDialog> createState() =>
      _PageJumpDialogState();
}

class _PageJumpDialogState
    extends State<_PageJumpDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();

    _controller = TextEditingController(
      text: widget.currentPage.toString(),
    );
  }

  void _submit() {
    final page = int.tryParse(
      _controller.text.trim(),
    );

    if (page == null ||
        page < 1 ||
        page > widget.totalPages) {
      AppToast.error(
        context,
        '请输入 1~${widget.totalPages} 之间的页码',
      );
      return;
    }

    Navigator.of(context).pop(page);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('跳转到页码'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: '页码',
          hintText: '请输入 1~${widget.totalPages}',
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('跳转'),
        ),
      ],
    );
  }
}