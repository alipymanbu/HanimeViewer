import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'controllers/app_config.dart';
import 'widgets/app_toast.dart';
import 'widgets/windows11_loading.dart';

/// 下载管理页。
///
/// 后端会把下载记录落盘（`<Hanime 根目录>/downloads.json`），
/// 所以这里不只显示「正在下的」，也显示以前下过的 ——
/// 重启客户端甚至重启后端之后记录都还在。
///
/// 正在下载的任务会自动轮询刷新，其余情况不动（省得一直发请求）。
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  List<Map<String, dynamic>> _jobs = [];
  String _dir = '';

  bool _loading = true;
  String? _error;

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final response = await http
          .get(Uri.parse('${AppConfig.backendBase}/api/downloads'))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw Exception('服务器返回错误: ${response.statusCode}');
      }

      final data = jsonDecode(response.body);

      if (!mounted) return;

      setState(() {
        _dir = data['dir']?.toString() ?? '';
        _jobs = List<Map<String, dynamic>>.from(data['jobs'] ?? []);
        _loading = false;
      });

      _schedulePoll();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;

        // 已经有列表时不要把整页换成错误页
        if (_jobs.isEmpty) _error = '加载失败：$e';
      });
    }
  }

  /// 有任务在下载就定时刷新，没有就停掉定时器。
  void _schedulePoll() {
    _pollTimer?.cancel();

    final busy = _jobs.any(
      (job) => job['status']?.toString() == 'downloading',
    );

    if (!busy) return;

    _pollTimer = Timer(
      const Duration(seconds: 1),
      () => _load(silent: true),
    );
  }

  Future<void> _openFolder([String? path]) async {
    try {
      if (path != null && path.isNotEmpty) {
        // 直接选中这个文件
        await Process.run('explorer.exe', ['/select,', path]);
      } else if (_dir.isNotEmpty) {
        await Process.run('explorer.exe', [_dir]);
      }
    } catch (e) {
      if (mounted) AppToast.error(context, '打不开：$e');
    }
  }

  Future<void> _openFile(String path) async {
    if (path.isEmpty || !File(path).existsSync()) {
      AppToast.error(context, '文件不存在，可能已经被移走或删掉了');

      await _load(silent: true);

      return;
    }

    try {
      await Process.run('explorer.exe', [path]);
    } catch (e) {
      if (mounted) AppToast.error(context, '打不开：$e');
    }
  }

  Future<void> _cancel(Map<String, dynamic> job) async {
    final videoId = job['video_id']?.toString() ?? '';

    if (videoId.isEmpty) return;

    try {
      await http
          .post(
            Uri.parse(
              '${AppConfig.backendBase}/api/download/$videoId/cancel',
            ),
          )
          .timeout(const Duration(seconds: 30));

      if (mounted) AppToast.success(context, '已取消下载');

      await _load(silent: true);
    } catch (e) {
      if (mounted) AppToast.error(context, '$e');
    }
  }

  Future<void> _remove(Map<String, dynamic> job) async {
    final videoId = job['video_id']?.toString() ?? '';

    if (videoId.isEmpty) return;

    final exists = job['file_exists'] == true;

    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条下载记录？'),
        content: Text(
          exists
              ? '硬盘上的文件也可以一起删掉。\n\n${job['path'] ?? ''}'
              : '文件已经不在硬盘上了，只会删掉这条记录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('record'),
            child: const Text('只删记录'),
          ),
          if (exists)
            FilledButton(
              onPressed: () => Navigator.of(context).pop('both'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('记录和文件都删'),
            ),
        ],
      ),
    );

    if (choice == null || !mounted) return;

    try {
      final response = await http
          .post(
            Uri.parse(
              '${AppConfig.backendBase}/api/downloads/$videoId/remove',
            ),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'delete_file': choice == 'both'}),
          )
          .timeout(const Duration(seconds: 60));

      final data = jsonDecode(response.body);

      if (!mounted) return;

      if (response.statusCode != 200) {
        throw Exception(
          data is Map ? (data['detail'] ?? '删除失败') : '删除失败',
        );
      }

      AppToast.success(
        context,
        choice == 'both' ? '记录和文件都删掉了' : '记录已删掉',
      );

      await _load(silent: true);
    } catch (e) {
      if (mounted) AppToast.error(context, '$e');
    }
  }

  // ---------- 显示辅助 ----------

  (String, Color) _statusOf(Map<String, dynamic> job) {
    final theme = Theme.of(context);
    final status = job['status']?.toString() ?? '';

    switch (status) {
      case 'downloading':
        return ('下载中', theme.colorScheme.primary);
      case 'done':
        return ('已完成', Colors.green);
      case 'failed':
        return ('失败', theme.colorScheme.error);
      case 'cancelled':
        return ('已取消', theme.colorScheme.onSurfaceVariant);
      case 'interrupted':
        return ('已中断', theme.colorScheme.error);
      case 'missing':
        return ('文件已丢失', theme.colorScheme.error);
      default:
        return (status.isEmpty ? '未知' : status,
            theme.colorScheme.onSurfaceVariant);
    }
  }

  String _formatBytes(dynamic value) {
    final bytes = (value as num?)?.toDouble() ?? 0;

    if (bytes <= 0) return '';

    const units = ['B', 'KB', 'MB', 'GB'];

    var size = bytes;
    var unit = 0;

    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }

    return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---- 顶部：目录 + 打开文件夹 ----
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '下载',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _dir.isEmpty ? '读取目录中…' : _dir,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _loading ? null : () => _load(),
                icon: const Icon(Icons.refresh),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _openFolder(),
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('打开文件夹'),
              ),
            ],
          ),
        ),

        const Divider(height: 1),

        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading && _jobs.isEmpty) {
      return const Center(child: Windows11Loading(size: 48));
    }

    if (_error != null && _jobs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => _load(),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_jobs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.download_done_outlined,
              size: 44,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(
              '还没有下载记录',
              style: TextStyle(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '在影片详情页点「下载」就会出现在这里',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(24),
      itemCount: _jobs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _buildRow(_jobs[index]),
    );
  }

  Widget _buildRow(Map<String, dynamic> job) {
    final theme = Theme.of(context);

    final title = job['title']?.toString() ?? '(没有标题)';
    final quality = job['quality']?.toString() ?? '';
    final thumbnail = job['thumbnail']?.toString() ?? '';
    final path = job['path']?.toString() ?? '';
    final error = job['error']?.toString() ?? '';

    final status = job['status']?.toString() ?? '';
    final (statusText, statusColor) = _statusOf(job);

    final percent = (job['percent'] as num?)?.toDouble() ?? 0;

    final sizeText = _formatBytes(job['total']);

    final downloading = status == 'downloading';

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 132,
                height: 74,
                child: thumbnail.isEmpty
                    ? Container(
                        color: Colors.black12,
                        child: const Icon(Icons.movie_outlined),
                      )
                    : Image.network(
                        thumbnail,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: Colors.black12,
                          child: const Icon(Icons.broken_image_outlined),
                        ),
                      ),
              ),
            ),

            const SizedBox(width: 14),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          statusText,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: statusColor,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 6),

                  Text(
                    [
                      if (quality.isNotEmpty) quality,
                      if (sizeText.isNotEmpty) sizeText,
                      if (downloading) '${percent.toStringAsFixed(0)}%',
                    ].join('  ·  '),
                    style: theme.textTheme.bodySmall,
                  ),

                  if (downloading) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: percent <= 0 ? null : percent / 100,
                        minHeight: 5,
                      ),
                    ),
                  ],

                  if (error.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      error,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],

                  if (path.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(width: 8),

            // 操作
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (downloading)
                  IconButton(
                    tooltip: '取消下载',
                    onPressed: () => _cancel(job),
                    icon: const Icon(Icons.stop_circle_outlined),
                  )
                else
                  IconButton(
                    tooltip: '打开文件',
                    onPressed: job['file_exists'] == true
                        ? () => _openFile(path)
                        : null,
                    icon: const Icon(Icons.play_circle_outline),
                  ),
                IconButton(
                  tooltip: '打开所在文件夹',
                  onPressed: () => _openFolder(path.isEmpty ? null : path),
                  icon: const Icon(Icons.folder_open, size: 20),
                ),
                IconButton(
                  tooltip: '删除记录',
                  onPressed: () => _remove(job),
                  icon: const Icon(Icons.delete_outline, size: 20),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
