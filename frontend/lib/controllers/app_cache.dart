/// 内存版接口结果缓存。
///
/// 为什么需要它：
/// 后端每次请求都要经过「真实 Chrome → CDP → 解析 HTML」，
/// 即使后端有缓存，网络往返和 JSON 解析也还是有开销。
/// 客户端再缓存一层，来回切换页面时就能立刻出内容，
/// 不用每次都等一个请求。
///
/// 说明：
/// - 只存在内存里，App 重启即清空，不会留下过期数据。
/// - TTL 故意设得比较短，避免数据太旧（后端自己也有一层缓存）。
/// - 需要强制刷新时调用 [clear] 或 [remove]。
class AppCache {
  AppCache._();

  /// 首页栏目（首页内容变化不频繁）
  static const Duration homeTtl = Duration(minutes: 5);

  /// 首页栏目的缓存 key。
  ///
  /// 设置页里排栏目顺序时也要读它拿栏目名，所以放在这里当公共常量，
  /// 不要在两处各写一遍字符串。
  static const String homeSectionsKey = 'home_sections';

  /// 搜索/筛选结果
  static const Duration searchTtl = Duration(minutes: 3);

  /// 视频详情（播放直链有过期时间，缓存要短）
  static const Duration detailTtl = Duration(minutes: 2);

  /// 标签分组（基本不变）
  static const Duration tagsTtl = Duration(minutes: 30);

  /// 用户/发行商主页
  static const Duration userTtl = Duration(minutes: 5);

  static final Map<String, _Entry> _store = {};

  /// 取缓存，过期返回 null 并顺手清掉。
  static dynamic get(String key) {
    final entry = _store[key];

    if (entry == null) return null;

    if (DateTime.now().isAfter(entry.expireAt)) {
      _store.remove(key);
      return null;
    }

    return entry.value;
  }

  /// 写缓存。
  static void set(
    String key,
    dynamic value, {
    Duration ttl = const Duration(minutes: 3),
  }) {
    _store[key] = _Entry(
      value: value,
      expireAt: DateTime.now().add(ttl),
    );
  }

  static void remove(String key) {
    _store.remove(key);
  }

  /// 清掉某一类缓存（按 key 前缀）。
  static void removeWherePrefix(String prefix) {
    _store.removeWhere((key, _) => key.startsWith(prefix));
  }

  static void clear() {
    _store.clear();
  }

  /// 用接口路径 + 参数拼一个稳定且不会互相冲突的 key。
  ///
  /// 参数会按名字排序，保证同一组参数永远得到同一个 key
  /// （否则 Map 顺序不同会算出不同 key，缓存就失效了）。
  static String buildKey(String path, Map<String, dynamic> params) {
    if (params.isEmpty) return path;

    final sorted = params.keys.toList()..sort();

    final parts = sorted.map((k) => '$k=${params[k]}').join('&');

    return '$path?$parts';
  }

  /// 供调试查看当前缓存了多少条。
  static int get size => _store.length;
}

class _Entry {
  final dynamic value;
  final DateTime expireAt;

  _Entry({required this.value, required this.expireAt});
}
