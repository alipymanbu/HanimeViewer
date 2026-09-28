import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

/// 应用偏好设置（播放器 / 下载 / 窗口）。
///
/// 用 [ValueNotifier] 暴露，界面改了就立刻生效，不用重启。
///
/// 这些偏好**不跟账号走** —— 和主题一样属于「这台机器怎么用」，
/// 换个账号登录不该把播放器设置也换掉。
class AppSettings {
  AppSettings._();

  // ---------- 播放器 ----------

  /// 左右方向键快进/快退的步长（秒）
  static final ValueNotifier<int> seekStep = ValueNotifier<int>(10);

  /// 长按右方向键时的倍速
  static final ValueNotifier<double> holdSpeed = ValueNotifier<double>(2.0);

  /// 上下方向键每次调整的音量
  static final ValueNotifier<double> volumeStep = ValueNotifier<double>(0.05);

  /// 打开影片时自动从上次位置续播
  static final ValueNotifier<bool> autoResume = ValueNotifier<bool>(true);

  /// 上次用的音量（0~1），下次打开影片接着用
  static final ValueNotifier<double> lastVolume = ValueNotifier<double>(1.0);

  // ---------- 下载 ----------

  /// 下载时默认选的清晰度（空 = 最高画质）
  static final ValueNotifier<String> downloadQuality =
      ValueNotifier<String>('');

  // ---------- 首页 ----------

  /// 首页栏目的自定义顺序（栏目名列表，空 = 用网站给的顺序）。
  ///
  /// 存**栏目名**而不是下标：网站的栏目会增删，
  /// 存下标的话网站一改就整体错位了。
  ///
  /// 首页监听它，在设置页拖完顺序回来立刻生效（首页是常驻页面，
  /// 不监听的话它还停在旧顺序上）。
  static final ValueNotifier<List<String>> homeSectionOrder =
      ValueNotifier<List<String>>(const []);

  // ---------- 窗口 ----------

  /// 上次关闭时的窗口大小（逻辑像素）
  static final ValueNotifier<Size?> windowSize = ValueNotifier<Size?>(null);

  /// 窗口默认大小（第一次启动时用）
  static const Size defaultWindowSize = Size(1280, 720);

  /// 窗口最小大小 —— 再小界面就挤坏了
  static const Size minimumWindowSize = Size(900, 600);

  /// 可选步长（给设置页用）
  static const List<int> seekStepOptions = [5, 10, 15, 30, 60];

  /// 可选倍速（给设置页用）
  static const List<double> holdSpeedOptions = [1.5, 2.0, 2.5, 3.0];

  static const String _kSeekStep = 'player_seek_step';
  static const String _kHoldSpeed = 'player_hold_speed';
  static const String _kVolumeStep = 'player_volume_step';
  static const String _kAutoResume = 'player_auto_resume';
  static const String _kLastVolume = 'player_last_volume';
  static const String _kDownloadQuality = 'download_quality';
  static const String _kHomeSectionOrder = 'home_section_order';
  static const String _kWindowWidth = 'window_width';
  static const String _kWindowHeight = 'window_height';

  /// 启动时读一次。
  static Future<void> load() async {
    SharedPreferences prefs;

    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      // 拿不到就别读了，全用默认值
      return;
    }

    // 每一项都**单独**读、单独兜底。
    //
    // 以前整个 load() 包在一个 try 里：只要有一个值读失败
    // （比如存档里的 0 是 int、而代码用 getDouble 去取，
    //  会直接抛类型错误），后面所有设置就一起被带回默认值 ——
    // 一个坏值连累全部。
    seekStep.value = _readInt(prefs, _kSeekStep) ?? 10;
    holdSpeed.value = _readDouble(prefs, _kHoldSpeed) ?? 2.0;
    volumeStep.value = _readDouble(prefs, _kVolumeStep) ?? 0.05;
    autoResume.value = _readBool(prefs, _kAutoResume) ?? true;
    downloadQuality.value = _readString(prefs, _kDownloadQuality) ?? '';
    homeSectionOrder.value = _readStringList(prefs, _kHomeSectionOrder);

    final volume = _readDouble(prefs, _kLastVolume);

    if (volume != null) lastVolume.value = volume.clamp(0.0, 1.0);

    final width = _readDouble(prefs, _kWindowWidth);
    final height = _readDouble(prefs, _kWindowHeight);

    if (width != null && height != null && width >= 200 && height >= 200) {
      windowSize.value = Size(width, height);
    }

    if (!seekStepOptions.contains(seekStep.value)) seekStep.value = 10;

    if (!holdSpeedOptions.contains(holdSpeed.value)) {
      holdSpeed.value = 2.0;
    }
  }

  // ---------- 宽容的类型读取 ----------
  //
  // 直接用 prefs.getDouble 遇到整数会抛类型错误（JSON 里的 `0` 是 int）。
  // 手上这份存档被人手工改过、或者以后换了存储实现，都可能出现这种情况。

  static double? _readDouble(SharedPreferences prefs, String key) {
    try {
      final value = prefs.get(key);

      if (value is double) return value;
      if (value is int) return value.toDouble();
      if (value is String) return double.tryParse(value);
    } catch (_) {}

    return null;
  }

  static int? _readInt(SharedPreferences prefs, String key) {
    try {
      final value = prefs.get(key);

      if (value is int) return value;
      if (value is double) return value.round();
      if (value is String) return int.tryParse(value);
    } catch (_) {}

    return null;
  }

  static bool? _readBool(SharedPreferences prefs, String key) {
    try {
      final value = prefs.get(key);

      if (value is bool) return value;
      if (value is String) return value.toLowerCase() == 'true';
    } catch (_) {}

    return null;
  }

  static String? _readString(SharedPreferences prefs, String key) {
    try {
      final value = prefs.get(key);

      if (value is String) return value;
      if (value != null) return value.toString();
    } catch (_) {}

    return null;
  }

  /// 读一个字符串列表（存的是 `List<String>`）。
  ///
  /// 老存档里可能是别的类型，逐项 toString 兜底，读不出来就当没排过。
  static List<String> _readStringList(SharedPreferences prefs, String key) {
    try {
      final value = prefs.get(key);

      if (value is List) {
        return [
          for (final item in value)
            if (item != null && item.toString().isNotEmpty) item.toString(),
        ];
      }
    } catch (_) {}

    return const [];
  }

  static Future<void> _save(String key, Object value) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (value is int) await prefs.setInt(key, value);
      if (value is double) await prefs.setDouble(key, value);
      if (value is bool) await prefs.setBool(key, value);
      if (value is String) await prefs.setString(key, value);
      if (value is List<String>) await prefs.setStringList(key, value);
    } catch (_) {}
  }

  static Future<void> setSeekStep(int value) async {
    seekStep.value = value;
    await _save(_kSeekStep, value);
  }

  static Future<void> setHoldSpeed(double value) async {
    holdSpeed.value = value;
    await _save(_kHoldSpeed, value);
  }

  static Future<void> setVolumeStep(double value) async {
    volumeStep.value = value;
    await _save(_kVolumeStep, value);
  }

  static Future<void> setAutoResume(bool value) async {
    autoResume.value = value;
    await _save(_kAutoResume, value);
  }

  static Future<void> setDownloadQuality(String value) async {
    downloadQuality.value = value;
    await _save(_kDownloadQuality, value);
  }

  // ---------- 首页栏目顺序 ----------

  /// 存下用户排的栏目顺序（传空列表 = 恢复成网站给的顺序）。
  static Future<void> setHomeSectionOrder(List<String> order) async {
    homeSectionOrder.value = List<String>.unmodifiable(order);

    await _save(_kHomeSectionOrder, order);
  }

  /// 把 [items] 按用户排的顺序重排，用 [nameOf] 取每一项的名字。
  ///
  /// 规则：
  /// - 排过的按用户的顺序；
  /// - **没排过的排在最后**（网站新加了栏目时不会把它弄丢），
  ///   并保持它们原来彼此的先后；
  /// - 顺序为空 = 没排过，原样返回。
  ///
  /// 用「原下标」当次要关键字，因为 Dart 的 `List.sort` **不保证稳定**
  /// （元素少时是插入排序、多了会换成快排）。
  static List<T> applyHomeOrder<T>(
    List<T> items,
    String Function(T) nameOf,
  ) {
    final order = homeSectionOrder.value;

    if (order.isEmpty || items.length < 2) return items;

    final rank = <String, int>{
      for (var i = 0; i < order.length; i++) order[i]: i,
    };

    final decorated = <(int rank, int original, T item)>[
      for (var i = 0; i < items.length; i++)
        (rank[nameOf(items[i])] ?? order.length, i, items[i]),
    ];

    decorated.sort((a, b) {
      final byRank = a.$1.compareTo(b.$1);

      return byRank != 0 ? byRank : a.$2.compareTo(b.$2);
    });

    return [for (final entry in decorated) entry.$3];
  }

  // ---------- 音量（防抖写盘）----------

  static Timer? _volumeTimer;

  /// 记下当前音量。
  ///
  /// 按住 ↑/↓ 会连续触发，每次都写盘太浪费，所以防抖 400ms 再存。
  static void setLastVolume(double value) {
    final clamped = value.clamp(0.0, 1.0);

    if (lastVolume.value == clamped) return;

    lastVolume.value = clamped;

    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(milliseconds: 400), () {
      _save(_kLastVolume, lastVolume.value);
    });
  }

  /// 立刻把音量写盘（退出前用，别让防抖里的那次丢掉）
  static Future<void> flushVolume() async {
    _volumeTimer?.cancel();
    await _save(_kLastVolume, lastVolume.value);
  }

  // ---------- 窗口大小 ----------

  static Future<void> setWindowSize(double width, double height) async {
    if (width < 200 || height < 200) return;

    windowSize.value = Size(width, height);

    final prefs = await SharedPreferences.getInstance();

    await prefs.setDouble(_kWindowWidth, width);
    await prefs.setDouble(_kWindowHeight, height);
  }

  /// 供「恢复默认设置」用。
  static Future<void> resetAll() async {
    await setSeekStep(10);
    await setHoldSpeed(2.0);
    await setVolumeStep(0.05);
    await setAutoResume(true);
    await setDownloadQuality('');
  }
}