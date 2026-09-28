import 'package:flutter/material.dart';

import 'controllers/auth_controller.dart';
import 'controllers/saved_accounts.dart';
import 'widgets/app_toast.dart';

/// 登录对话框。
///
/// 登录实际发生在后端的真实 Chrome 里（提交官网登录表单）。
///
/// 登录过的账号会记下来，下次直接点一下就填好邮箱，
/// 省得每次重新输。密码默认不保存（勾「记住密码」才存本机）。
class LoginDialog extends StatefulWidget {
  const LoginDialog({super.key});

  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<LoginDialog> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _busy = false;
  bool _obscure = true;
  bool _rememberPassword = false;
  String? _error;

  List<SavedAccount> _saved = [];
  bool _loadingSaved = true;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final saved = await SavedAccounts.load();

    if (!mounted) return;

    setState(() {
      _saved = saved;
      _loadingSaved = false;

      // 只有一个账号就直接填好邮箱，少点一次
      if (saved.length == 1) {
        _emailController.text = saved.first.email;
        _rememberPassword = saved.first.hasPassword;

        if (saved.first.hasPassword) {
          _passwordController.text = saved.first.password;
        }
      }
    });
  }

  void _useAccount(SavedAccount account) {
    setState(() {
      _emailController.text = account.email;
      _error = null;
      _rememberPassword = account.hasPassword;

      if (account.hasPassword) {
        _passwordController.text = account.password;
      } else {
        _passwordController.clear();
      }
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;

    if (!(_formKey.currentState?.validate() ?? false)) return;

    final email = _emailController.text.trim();
    final password = _passwordController.text;

    setState(() {
      _busy = true;
      _error = null;
    });

    final (ok, error) = await AuthController.login(email, password);

    if (!mounted) return;

    if (ok) {
      // 登录成功：记住这个账号（密码只在用户勾选时才存）
      final info = AuthController.account.value;

      await SavedAccounts.remember(
        email: email,
        password: _rememberPassword ? password : '',
        username: info.username,
        avatar: info.avatar,
        userId: info.userId,
      );

      if (!mounted) return;

      Navigator.of(context).pop(true);

      return;
    }

    setState(() {
      _busy = false;
      _error = error;
    });
  }

  Future<void> _forget(SavedAccount account) async {
    await SavedAccounts.remove(account.email);

    final saved = await SavedAccounts.load(force: true);

    if (!mounted) return;

    setState(() => _saved = saved);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.login,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          const Text('登录 Hanime'),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '登录会在你的调试 Chrome 里完成，'
                  '登录状态保存于浏览器。',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.65),
                  ),
                ),

                // 快捷登录：之前登录过的账号
                if (_loadingSaved)
                  const Padding(
                    padding: EdgeInsets.only(top: 14),
                    child: LinearProgressIndicator(),
                  )
                else if (_saved.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    '快捷登录',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final account in _saved)
                        _SavedAccountChip(
                          account: account,
                          enabled: !_busy,
                          onTap: () => _useAccount(account),
                          onForget: () => _forget(account),
                        ),
                    ],
                  ),
                ],

                const SizedBox(height: 18),
                TextFormField(
                  controller: _emailController,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  autofocus: _saved.isEmpty,
                  decoration: const InputDecoration(
                    labelText: '邮箱',
                    prefixIcon: Icon(Icons.email_outlined),
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    final value = v?.trim() ?? '';

                    if (value.isEmpty) return '请输入邮箱';

                    if (!value.contains('@')) return '邮箱格式不正确';

                    return null;
                  },
                  onFieldSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _passwordController,
                  enabled: !_busy,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: '密码',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      tooltip: _obscure ? '显示密码' : '隐藏密码',
                      onPressed: () =>
                          setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? '请输入密码' : null,
                  onFieldSubmitted: (_) => _submit(),
                ),

                const SizedBox(height: 6),
                InkWell(
                  onTap: _busy
                      ? null
                      : () => setState(
                            () => _rememberPassword = !_rememberPassword,
                          ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Checkbox(
                          value: _rememberPassword,
                          onChanged: _busy
                              ? null
                              : (v) => setState(
                                    () => _rememberPassword = v ?? false,
                                  ),
                        ),
                        Expanded(
                          child: Text(
                            '记住密码（明文存在本机，方便下次快捷登录）',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error
                          .withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 18,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('登录'),
        ),
      ],
    );
  }
}

/// 快捷登录的一个账号小卡片
class _SavedAccountChip extends StatelessWidget {
  final SavedAccount account;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onForget;

  const _SavedAccountChip({
    required this.account,
    required this.enabled,
    required this.onTap,
    required this.onForget,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: account.email,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 13,
                backgroundColor:
                    theme.colorScheme.primary.withValues(alpha: 0.15),
                backgroundImage: account.avatar.isEmpty
                    ? null
                    : NetworkImage(account.avatar),
                child: account.avatar.isEmpty
                    ? Icon(
                        Icons.person,
                        size: 14,
                        color: theme.colorScheme.primary,
                      )
                    : null,
              ),
              const SizedBox(width: 7),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 130),
                child: Text(
                  account.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              if (account.hasPassword)
                Padding(
                  padding: const EdgeInsets.only(left: 5),
                  child: Icon(
                    Icons.lock,
                    size: 12,
                    color: theme.colorScheme.primary
                        .withValues(alpha: 0.7),
                  ),
                ),
              const SizedBox(width: 4),
              InkWell(
                onTap: enabled
                    ? () {
                        AppToast.show(context, '已移除「${account.title}」');
                        onForget();
                      }
                    : null,
                child: Icon(
                  Icons.close,
                  size: 14,
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
