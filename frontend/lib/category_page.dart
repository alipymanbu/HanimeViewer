import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'main.dart';
import 'controllers/app_cache.dart';
import 'widgets/windows11_loading.dart';
import 'controllers/app_config.dart';
import './widgets/app_toast.dart';
import 'widgets/pager_bar.dart';
import 'widgets/video_card.dart';

class CategoryPage extends StatefulWidget {
  final String title;
  final String genre;
  final String sort;

  const CategoryPage({
    super.key,
    required this.title,
    this.genre = '',
    this.sort = '',
  });

  @override
  State<CategoryPage> createState() =>
      _CategoryPageState();
}

class _CategoryPageState
    extends State<CategoryPage> {
  List<Map<String, dynamic>> _videos = [];

  int _page = 1;
  int _totalPages = 1;

  String _selectedSort = '';
  String _selectedDate = '';
  String _selectedDuration = '';

  List<String> _selectedTags = [];
  bool _broadMatch = false;

  bool _loading = true;
  String? _error;

  bool get _isPortraitCategory =>
      widget.genre == '裏番' || widget.genre == '泡麵番';

  List<Map<String, dynamic>> _tagGroups = [];
  bool _tagsLoaded = false;

  /// 标签分组缓存 key（与搜索页共用，标签列表本来就是同一份）
  static const String _tagCacheKey = 'search_tag_groups';

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

  @override
  void initState() {
    super.initState();
    _selectedSort = widget.sort;
    _loadVideos();
  }

  Future<void> _loadVideos({int? page}) async {
    final targetPage = page ?? _page;

    if (targetPage < 1 || targetPage > _totalPages) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final params = <String, String>{};

      if (widget.genre.isNotEmpty) {
        params['genre'] = widget.genre;
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

      if (params.isEmpty) {
        params['genre'] = '';
      }

      params['page'] = targetPage.toString();

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

      // 标签分组随搜索结果一起返回（后端从同一个页面解析出来的），
      // 存下来后点「標籤」就不用再等一次请求，弹窗可以秒开。
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

      final currentPage =
          int.tryParse(data['page']?.toString() ?? '') ??
              targetPage;

      final serverTotalPages =
          int.tryParse(
                data['total_pages']?.toString() ?? '',
              ) ??
              1;

      if (!mounted) return;

      setState(() {
        _videos = results;
        _page = currentPage;
        _totalPages =
            serverTotalPages < 1 ? 1 : serverTotalPages;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _loadTags() async {
    if (_tagsLoaded) return;

    // 先看缓存（搜索时已经顺手存下来了，正常情况都走这里）
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

  void _applyFilter() {
    _page = 1;
    _loadVideos(page: 1);
  }

  Future<void> _showTagDialog() async {
    await _loadTags();

    if (!mounted) return;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) {
        return _TagSelectionDialog(
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

    _applyFilter();
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


  Widget _buildFilterBar() {
    final hasActiveFilter = _selectedSort != widget.sort ||
        _selectedDate.isNotEmpty ||
        _selectedDuration.isNotEmpty ||
        _selectedTags.isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _buildFilterMenu(
            label: '排序',
            currentValue: _selectedSort,
            options: _sortOptions,
            onChanged: (v) {
              setState(() => _selectedSort = v);
              _applyFilter();
            },
          ),
          _buildFilterMenu(
            label: '日期',
            currentValue: _selectedDate,
            options: _dateOptions,
            onChanged: (v) {
              setState(() => _selectedDate = v);
              _applyFilter();
            },
          ),
          _buildFilterMenu(
            label: '時長',
            currentValue: _selectedDuration,
            options: _durationOptions,
            onChanged: (v) {
              setState(() => _selectedDuration = v);
              _applyFilter();
            },
          ),
          _buildTagButton(),
          if (hasActiveFilter) _buildResetButton(),
        ],
      ),
    );
  }

  Widget _buildFilterMenu({
    required String label,
    required String currentValue,
    required List<Map<String, String>> options,
    required ValueChanged<String> onChanged,
  }) {
    final active = currentValue.isNotEmpty;
    final displayText =
        active ? '$label · $currentValue' : label;

    final theme = Theme.of(context);

    return PopupMenuButton<String>(
      tooltip: label,
      onSelected: onChanged,
      itemBuilder: (context) {
        return options.map((o) {
          final isCurrent = o['value'] == currentValue;

          return PopupMenuItem<String>(
            value: o['value'],
            height: 40,
            child: Row(
              children: [
                if (isCurrent)
                  const Icon(
                    Icons.check,
                    size: 16,
                    color: Colors.green,
                  )
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(o['label']!),
              ],
            ),
          );
        }).toList();
      },
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active
              ? theme.colorScheme.primary.withValues(alpha: 0.1)
              : Colors.transparent,
          border: Border.all(
            color: active
                ? theme.colorScheme.primary
                : Colors.grey.shade400,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              displayText,
              style: TextStyle(
                fontSize: 13,
                color: active
                    ? theme.colorScheme.primary
                    : null,
                fontWeight: active
                    ? FontWeight.w600
                    : FontWeight.normal,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.arrow_drop_down,
              size: 18,
              color: active
                  ? theme.colorScheme.primary
                  : Colors.grey.shade700,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTagButton() {
    final active = _selectedTags.isNotEmpty;
    final displayText =
        active ? '標籤 · ${_selectedTags.length}' : '標籤';

    final theme = Theme.of(context);

    return InkWell(
      onTap: _showTagDialog,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active
              ? theme.colorScheme.primary.withValues(alpha: 0.1)
              : Colors.transparent,
          border: Border.all(
            color: active
                ? theme.colorScheme.primary
                : Colors.grey.shade400,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              displayText,
              style: TextStyle(
                fontSize: 13,
                color: active
                    ? theme.colorScheme.primary
                    : null,
                fontWeight: active
                    ? FontWeight.w600
                    : FontWeight.normal,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.arrow_drop_down,
              size: 18,
              color: active
                  ? theme.colorScheme.primary
                  : Colors.grey.shade700,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResetButton() {
    return TextButton.icon(
      onPressed: () {
        setState(() {
          _selectedSort = widget.sort;
          _selectedDate = '';
          _selectedDuration = '';
          _selectedTags = [];
          _broadMatch = false;
        });
        _applyFilter();
      },
      icon: const Icon(Icons.close, size: 16),
      label: const Text('重置'),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        foregroundColor: Colors.grey.shade700,
        textStyle: const TextStyle(fontSize: 13),
      ),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _videos.isEmpty) {
      return Column(
        children: [
          _buildFilterBar(),
          const Expanded(
            child: Center(
              child: Windows11Loading(size: 48),
            ),
          ),
        ],
      );
    }

    if (_error != null && _videos.isEmpty) {      
      return Column(
        children: [
          _buildFilterBar(),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _loadVideos,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新加载'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (_videos.isEmpty) {
      return Column(
        children: [
          _buildFilterBar(),
          const Expanded(
            child: Center(
              child: Text('没有找到视频'),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        _buildFilterBar(),

        Expanded(
          child: _loading
              ? const Center(
                  child: Windows11Loading(size: 48),
                )
              : RefreshIndicator(            
            onRefresh: () {
              return _loadVideos(page: _page);
            },
            // 尺寸和首页统一（见 widgets/video_card.dart）
            child: VideoCardGrid(
              videos: _videos,
              padding: const EdgeInsets.all(24),
              portrait: _isPortraitCategory,
              aspectRatio: _isPortraitCategory ? 268 / 394 : 16 / 9,
              onTap: _openVideo,
            ),
          ),
        ),

        PagerBar(
          page: _page,
          totalPages: _totalPages,
          loading: _loading,
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 14),
          onGoToPage: (target) => _loadVideos(page: target),
        ),
      ],
    );
  }
}

class _TagSelectionDialog extends StatefulWidget {
  final List<Map<String, dynamic>> groups;
  final List<String> initialTags;
  final bool initialBroad;

  const _TagSelectionDialog({
    required this.groups,
    required this.initialTags,
    required this.initialBroad,
  });

  @override
  State<_TagSelectionDialog> createState() =>
      _TagSelectionDialogState();
}

class _TagSelectionDialogState
    extends State<_TagSelectionDialog> {
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
            // 顶部：广泛匹配开关 + 清空按钮
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
                  child: Text('廣泛配對（符合任一標籤即可，預設需全部符合）'),
                ),
                TextButton.icon(
                  onPressed: _selected.isEmpty ? null : _clear,
                  icon: const Icon(Icons.clear, size: 18),
                  label: const Text('清空'),
                ),
              ],
            ),
            const Divider(),
            // 标签列表
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