import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 保存过的账号。
///
/// 用户在 App 上登录过之后，下次打开登录框就能直接点一下快捷登录，
/// 不用再输一遍邮箱。
///
/// 关于密码：**默认不保存**。登录本身是在后端的真实 Chrome 里提交官网
/// 表单完成的，客户端保存密码并不会让"自动登录"变得更容易 ——
/// 同样要经过一次表单提交。所以这里把选择权交给用户：
/// 登录框里有一个「记住密码」勾选项，勾了才会把密码存在本机
/// （明文存于 SharedPreferences，仅本机可见）。
///
/// 这是本机个人使用的工具，所以提供了这个便利；但也正因为是明文，
/// 默认是关闭的。
class SavedAccount {
  final String email;

  /// 最近一次登录成功时拿到的昵称/头像，用来把快捷入口显示得好看一点
  final String username;
  final String avatar;
  final String userId;

  /// 只有用户勾了「记住密码」才有值
  final String password;

  final int lastUsed;

  const SavedAccount({
    required this.email,
    this.username = '',
    this.avatar = '',
    this.userId = '',
    this.password = '',
    this.lastUsed = 0,
  });

  bool get hasPassword => password.isNotEmpty;

  String get title => username.isNotEmpty ? username : email;

  Map<String, dynamic> toJson() => {
        'email': email,
        'username': username,
        'avatar': avatar,
        'user_id': userId,
        'password': password,
        'last_used': lastUsed,
      };

  static SavedAccount fromJson(Map<String, dynamic> json) => SavedAccount(
        email: json['email']?.toString() ?? '',
        username: json['username']?.toString() ?? '',
        avatar: json['avatar']?.toString() ?? '',
        userId: json['user_id']?.toString() ?? '',
        password: json['password']?.toString() ?? '',
        lastUsed: int.tryParse('${json['last_used']}') ?? 0,
      );
}

class SavedAccounts {
  SavedAccounts._();

  static const String _key = 'saved_accounts';

  static List<SavedAccount> _cache = [];
  static bool _loaded = false;

  static Future<List<SavedAccount>> load({bool force = false}) async {
    if (_loaded && !force) return _cache;

    try {
      final prefs = await SharedPreferences.getInstance();

      final raw = prefs.getStringList(_key) ?? [];

      final result = <SavedAccount>[];

      for (final item in raw) {
        try {
          final decoded = jsonDecode(item);

          if (decoded is Map) {
            result.add(
              SavedAccount.fromJson(Map<String, dynamic>.from(decoded)),
            );
          }
        } catch (_) {}
      }

      // 最近用的排前面
      result.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));

      _cache = result;
      _loaded = true;
    } catch (_) {
      _cache = [];
      _loaded = true;
    }

    return _cache;
  }

  static Future<void> _persist(List<SavedAccount> accounts) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setStringList(
      _key,
      accounts.map((a) => jsonEncode(a.toJson())).toList(),
    );

    _cache = accounts;
    _loaded = true;
  }

  /// 记住一个账号（登录成功后调用）。
  static Future<void> remember({
    required String email,
    required String password,
    String username = '',
    String avatar = '',
    String userId = '',
  }) async {
    if (email.trim().isEmpty) return;

    final accounts = [...await load(force: true)];

    final index = accounts.indexWhere(
      (a) => a.email.toLowerCase() == email.trim().toLowerCase(),
    );

    // 没勾「记住密码」时要把之前存的密码清掉
    final savedPassword = password.trim();

    final entry = SavedAccount(
      email: email.trim(),
      username: username,
      avatar: avatar,
      userId: userId,
      password: savedPassword,
      lastUsed: DateTime.now().millisecondsSinceEpoch,
    );

    if (index >= 0) {
      accounts[index] = entry;
    } else {
      accounts.add(entry);
    }

    await _persist(accounts);
  }

  static Future<void> remove(String email) async {
    final accounts = [...await load(force: true)];

    accounts.removeWhere(
      (a) => a.email.toLowerCase() == email.trim().toLowerCase(),
    );

    await _persist(accounts);
  }

  /// 退出登录时清掉所有保存的密码，但保留账号条目
  /// （这样下次仍能快捷登录，只是要重新输密码）。
  static Future<void> forgetPasswords() async {
    final accounts = await load(force: true);

    final updated = [
      for (final a in accounts)
        SavedAccount(
          email: a.email,
          username: a.username,
          avatar: a.avatar,
          userId: a.userId,
          password: '',
          lastUsed: a.lastUsed,
        ),
    ];

    await _persist(updated);
  }

  static Future<void> clear() async => _persist([]);
}
