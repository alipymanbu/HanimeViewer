import 'package:flutter/material.dart';

/// 统一的翻页条。
///
/// 四个列表页（观看记录 / 播放清单 / 分类 / 新番预告）原本各写了一套，
/// 外观和交互都不一样：有的只有箭头图标、有的有文字，
/// 有的页码能点、有的不能。这里统一成一个组件。
///
/// 交互：
/// - 上一页 / 下一页：`OutlinedButton.icon`（带文字，比只有箭头好认）
/// - 中间的「第 N / M 页」：**可点击**，点开输页码直接跳
class PagerBar extends StatelessWidget {
  final int page;
  final int totalPages;
  final bool loading;
  final ValueChanged<int> onGoToPage;

  /// 左右留白
  final EdgeInsets padding;

  const PagerBar({
    super.key,
    required this.page,
    required this.totalPages,
    required this.onGoToPage,
    this.loading = false,
    this.padding = const EdgeInsets.fromLTRB(18, 6, 18, 14),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 只有一页就没必要显示翻页条
    if (totalPages <= 1) return const SizedBox.shrink();

    final canPrev = page > 1 && !loading;
    final canNext = page < totalPages && !loading;

    return Padding(
      padding: padding,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: canPrev ? () => onGoToPage(page - 1) : null,
            icon: const Icon(Icons.chevron_left),
            label: const Text('上一页'),
          ),
          const SizedBox(width: 16),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: loading ? null : () => _showJumpDialog(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              child: Tooltip(
                message: '点击可跳到指定页',
                child: Text(
                  '第 $page / $totalPages 页',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: loading
                        ? Colors.grey
                        : theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          OutlinedButton.icon(
            onPressed: canNext ? () => onGoToPage(page + 1) : null,
            icon: const Icon(Icons.chevron_right),
            label: const Text('下一页'),
          ),
        ],
      ),
    );
  }

  Future<void> _showJumpDialog(BuildContext context) async {
    final target = await showDialog<int>(
      context: context,
      builder: (_) => PageJumpDialog(
        currentPage: page,
        totalPages: totalPages,
      ),
    );

    if (target == null || target == page) return;

    onGoToPage(target);
  }
}

/// 页码跳转对话框
class PageJumpDialog extends StatefulWidget {
  final int currentPage;
  final int totalPages;

  const PageJumpDialog({
    super.key,
    required this.currentPage,
    required this.totalPages,
  });

  @override
  State<PageJumpDialog> createState() => _PageJumpDialogState();
}

class _PageJumpDialogState extends State<PageJumpDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: '${widget.currentPage}',
  );

  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    Navigator.of(context).pop(int.parse(_controller.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('跳转页码'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 260,
          child: TextFormField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '页码',
              helperText: '范围 1 ~ ${widget.totalPages}',
              border: const OutlineInputBorder(),
            ),
            validator: (v) {
              final value = int.tryParse((v ?? '').trim());

              if (value == null) return '请输入数字';

              if (value < 1 || value > widget.totalPages) {
                return '请输入 1~${widget.totalPages} 之间的页码';
              }

              return null;
            },
            onFieldSubmitted: (_) => _submit(),
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
          child: const Text('跳转'),
        ),
      ],
    );
  }
}
