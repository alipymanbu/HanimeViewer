import 'package:flutter/material.dart';

/// 储存时要做的一次改动
class PlaylistChange {
  final String name;

  /// true = 加入该清单，false = 从该清单移出
  final bool save;

  const PlaylistChange({required this.name, required this.save});
}

/// 「储存到播放清单」对话框。
///
/// 交互：**点选只是标记，最后统一按「确认」才生效**。
/// 每行是一个复选框：
///   - 已储存 -> 主色文字 + 打钩
///   - 未储存 -> 普通颜色 + 空方框
/// 点一下只是把这个标记切来切去，真正提交发生在点「确认」时
/// （只提交与打开弹窗时相比**有变化**的那些清单）。
///
/// **点「确认」后弹窗立刻关闭**，不会等后台同步完。
/// 同步（要开浏览器页面，比较慢）交给 [onApply] 在后台跑，
/// 失败时由调用方弹提示并回滚。
///
/// 顶部有「新建播放清单」，可以直接建一个新清单（标题必填、说明选填）。
/// 官网在影片页建清单时会顺手把影片加进去，所以新建成功后
/// 这里也把它当作"已储存"。
///
/// 清单列表来自影片详情接口的 `save_playlists` —— 那正是官网
/// 储存弹窗里的内容：**稍后观看 + 自己创建的清单**。
/// （那些收藏来的、别人建的清单不会出现在这里。）
class SaveToPlaylistDialog extends StatefulWidget {
  /// [{"list_id": "...", "name": "...", "checked": bool}, ...]
  final List<Map<String, dynamic>> playlists;

  /// 影片标题，显示在顶部
  final String videoTitle;

  /// 点「确认」时把差异交给调用方去后台提交。
  ///
  /// 刻意设计成**不返回 Future** —— 弹窗不等它，
  /// 立刻关掉并把状态按用户的选择先更新掉（乐观更新）。
  final void Function(List<PlaylistChange> changes) onApply;

  /// 新建播放清单。返回新清单名；返回 null 表示失败（调用方已提示）。
  final Future<String?> Function(String title, String description)? onCreate;

  const SaveToPlaylistDialog({
    super.key,
    required this.playlists,
    required this.onApply,
    this.videoTitle = '',
    this.onCreate,
  });

  @override
  State<SaveToPlaylistDialog> createState() => _SaveToPlaylistDialogState();
}

class _SaveToPlaylistDialogState extends State<SaveToPlaylistDialog> {
  late List<Map<String, dynamic>> _items = [
    for (final p in widget.playlists) {...p},
  ];

  /// 打开弹窗时的勾选状态，用来算差异
  late final Map<String, bool> _original = {
    for (final p in widget.playlists)
      p['name']?.toString() ?? '': p['checked'] == true,
  };

  /// 正在新建清单（这个要等，因为要拿到新清单名）
  bool _creating = false;

  /// 新建清单对话框里输入的内容
  Future<void> _openCreateDialog() async {
    final created = await showDialog<({String title, String description})>(
      context: context,
      builder: (_) => const CreatePlaylistDialog(),
    );

    if (created == null || !mounted) return;

    if (widget.onCreate == null) return;

    setState(() => _creating = true);

    final name = await widget.onCreate!(created.title, created.description);

    if (!mounted) return;

    setState(() => _creating = false);

    if (name == null || name.isEmpty) return;

    // 官网建清单时会顺手把影片加进去，所以这里也标记为已储存
    setState(() {
      _items = [
        ..._items,
        {'list_id': '', 'name': name, 'checked': true},
      ];

      // 关键：把"原始状态"也设成已储存，
      // 这样点确认时不会重复提交一次 save。
      _original[name] = true;
    });
  }

  /// 当前应该提交的改动（和打开时相比有变化的）
  List<PlaylistChange> get _pendingChanges {
    final changes = <PlaylistChange>[];

    for (final p in _items) {
      final name = p['name']?.toString() ?? '';

      if (name.isEmpty) continue;

      final now = p['checked'] == true;
      final was = _original[name] == true;

      if (now != was) {
        changes.add(PlaylistChange(name: name, save: now));
      }
    }

    return changes;
  }

  Future<void> _confirm() async {
    final changes = _pendingChanges;

    // 立刻关掉，把最终选择回传给调用方。
    //
    // **不等后台同步**：同步要开浏览器页面，一次要好几秒；
    // 让用户干等没有任何意义。调用方会先把界面按用户的选择更新掉，
    // 再去后台提交，失败时弹提示并回滚。
    Navigator.of(context).pop(<String>[
      for (final p in _items)
        if (p['checked'] == true) p['name']?.toString() ?? '',
    ]);

    if (changes.isNotEmpty) {
      widget.onApply(changes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = _pendingChanges.length;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.bookmark_add_outlined, size: 20),
          const SizedBox(width: 8),
          const Expanded(child: Text('储存到播放清单')),
          if (_creating)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.videoTitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  widget.videoTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.65),
                  ),
                ),
              ),

            // 新建播放清单（放在最上方）
            if (widget.onCreate != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: OutlinedButton.icon(
                  onPressed: _creating ? null : _openCreateDialog,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新建播放清单'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(38),
                    alignment: Alignment.centerLeft,
                  ),
                ),
              ),

            const Divider(height: 12),

            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final p in _items)
                      _PlaylistToggleRow(
                        name: p['name']?.toString() ?? '',
                        checked: p['checked'] == true,
                        enabled: !_creating,
                        onTap: () => setState(
                          () => p['checked'] = p['checked'] != true,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _creating ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          // 点确认立刻关窗，不等后台同步
          onPressed: _creating ? null : _confirm,
          child: Text(pending == 0 ? '确认' : '确认（$pending 项改动）'),
        ),
      ],
    );
  }
}

/// 新建播放清单对话框：标题必填、详细说明选填。
class CreatePlaylistDialog extends StatefulWidget {
  const CreatePlaylistDialog({super.key});

  @override
  State<CreatePlaylistDialog> createState() => _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends State<CreatePlaylistDialog> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    Navigator.of(context).pop((
      title: _titleController.text.trim(),
      description: _descriptionController.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.playlist_add, size: 20),
          SizedBox(width: 8),
          Text('新建播放清单'),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _titleController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '标题',
                  hintText: '例如：同人',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '标题不能为空' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _descriptionController,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '详细说明（选填）',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('建立'),
        ),
      ],
    );
  }
}

/// 清单列表里的一项：复选框 + 名字。
///
/// 已勾选 = 主色文字 + 实心勾选框；未勾选 = 普通文字 + 空方框。
class _PlaylistToggleRow extends StatelessWidget {
  final String name;
  final bool checked;
  final bool enabled;
  final VoidCallback onTap;

  const _PlaylistToggleRow({
    required this.name,
    required this.checked,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: enabled ? onTap : null,
      leading: Icon(
        checked ? Icons.check_box : Icons.check_box_outline_blank,
        size: 21,
        color: checked
            ? primary
            : theme.colorScheme.onSurface.withValues(alpha: 0.45),
      ),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          color: checked ? primary : null,
          fontWeight: checked ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}
