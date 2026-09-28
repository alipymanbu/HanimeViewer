import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/controllers/app_settings.dart';

void main() {
  group('播放器 / 下载偏好设置', () {
    setUp(() {
      // 每个用例都从干净状态开始
      SharedPreferences.setMockInitialValues({});

      AppSettings.seekStep.value = 10;
      AppSettings.holdSpeed.value = 2.0;
      AppSettings.volumeStep.value = 0.05;
      AppSettings.autoResume.value = true;
      AppSettings.downloadQuality.value = '';
    });

    test('没有存过时用默认值', () async {
      await AppSettings.load();

      expect(AppSettings.seekStep.value, 10);
      expect(AppSettings.holdSpeed.value, 2.0);
      expect(AppSettings.autoResume.value, isTrue);
      expect(AppSettings.downloadQuality.value, '');
    });

    test('存过之后能读回来', () async {
      SharedPreferences.setMockInitialValues({
        'player_seek_step': 30,
        'player_hold_speed': 3.0,
        'player_auto_resume': false,
        'download_quality': '720p',
      });

      await AppSettings.load();

      expect(AppSettings.seekStep.value, 30);
      expect(AppSettings.holdSpeed.value, 3.0);
      expect(AppSettings.autoResume.value, isFalse);
      expect(AppSettings.downloadQuality.value, '720p');
    });

    test('改设置会立刻生效并落盘', () async {
      await AppSettings.setSeekStep(15);
      await AppSettings.setHoldSpeed(2.5);
      await AppSettings.setAutoResume(false);
      await AppSettings.setDownloadQuality('1080p');

      expect(AppSettings.seekStep.value, 15);
      expect(AppSettings.holdSpeed.value, 2.5);
      expect(AppSettings.autoResume.value, isFalse);
      expect(AppSettings.downloadQuality.value, '1080p');

      // 重新读一次应该还是改过的值
      AppSettings.seekStep.value = 10;

      await AppSettings.load();

      expect(AppSettings.seekStep.value, 15, reason: '应该从磁盘读回 15');
    });

    test('存档里是非法值时回落到默认值', () async {
      SharedPreferences.setMockInitialValues({
        'player_seek_step': 7, // 不在可选项里
        'player_hold_speed': 9.9, // 不在可选项里
      });

      await AppSettings.load();

      expect(AppSettings.seekStep.value, 10);
      expect(AppSettings.holdSpeed.value, 2.0);
    });

    test('恢复默认设置', () async {
      await AppSettings.setSeekStep(60);
      await AppSettings.setHoldSpeed(3.0);

      await AppSettings.resetAll();

      expect(AppSettings.seekStep.value, 10);
      expect(AppSettings.holdSpeed.value, 2.0);
      expect(AppSettings.autoResume.value, isTrue);
    });
  });

  group('记住上次的音量', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AppSettings.lastVolume.value = 1.0;
    });

    test('没存过时是满音量', () async {
      await AppSettings.load();

      expect(AppSettings.lastVolume.value, 1.0);
    });

    test('存过之后能读回来', () async {
      SharedPreferences.setMockInitialValues({'player_last_volume': 0.35});

      await AppSettings.load();

      expect(AppSettings.lastVolume.value, closeTo(0.35, 0.001));
    });

    test('设置后 flush 会落盘，下次读得到', () async {
      AppSettings.setLastVolume(0.42);

      expect(AppSettings.lastVolume.value, closeTo(0.42, 0.001));

      // 防抖还没到点，先手动落盘（相当于退出前那一下）
      await AppSettings.flushVolume();

      AppSettings.lastVolume.value = 1.0;

      await AppSettings.load();

      expect(
        AppSettings.lastVolume.value,
        closeTo(0.42, 0.001),
        reason: '应该从磁盘读回 0.42',
      );
    });

    test('超出 0~1 会被夹住', () {
      AppSettings.setLastVolume(3.0);
      expect(AppSettings.lastVolume.value, 1.0);

      AppSettings.setLastVolume(-2.0);
      expect(AppSettings.lastVolume.value, 0.0);
    });
  });

  group('记住窗口大小', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AppSettings.windowSize.value = null;
    });

    test('没存过时不设尺寸（用默认值）', () async {
      await AppSettings.load();

      expect(AppSettings.windowSize.value, isNull);
    });

    test('存过之后能读回来', () async {
      SharedPreferences.setMockInitialValues({
        'window_width': 1600.0,
        'window_height': 900.0,
      });

      await AppSettings.load();

      expect(AppSettings.windowSize.value?.width, 1600.0);
      expect(AppSettings.windowSize.value?.height, 900.0);
    });

    test('写入后能读回来', () async {
      await AppSettings.setWindowSize(1440, 810);

      expect(AppSettings.windowSize.value?.width, 1440);

      AppSettings.windowSize.value = null;

      await AppSettings.load();

      expect(AppSettings.windowSize.value?.width, 1440);
      expect(AppSettings.windowSize.value?.height, 810);
    });

    test('小到不合理的尺寸会被忽略（避免窗口打不开）', () async {
      await AppSettings.setWindowSize(50, 50);

      expect(AppSettings.windowSize.value, isNull);
    });

    test('存档里尺寸太小时不采用', () async {
      SharedPreferences.setMockInitialValues({
        'window_width': 10.0,
        'window_height': 10.0,
      });

      await AppSettings.load();

      expect(AppSettings.windowSize.value, isNull);
    });
  });

  group('存档里类型不对也不能连累别的设置', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AppSettings.seekStep.value = 10;
      AppSettings.holdSpeed.value = 2.0;
      AppSettings.autoResume.value = true;
      AppSettings.lastVolume.value = 1.0;
      AppSettings.windowSize.value = null;
    });

    test('音量存成整数 0 也能读出来（静音）', () async {
      // JSON 里的 `0` 是 int，直接 getDouble 会抛类型错误。
      // 以前整个 load() 包一个 try，一个坏值会让**所有**设置回默认。
      SharedPreferences.setMockInitialValues({
        'player_last_volume': 0, // int，不是 double
        'player_seek_step': 30, // 这个是对的，不该被连累
      });

      await AppSettings.load();

      expect(
        AppSettings.lastVolume.value,
        0.0,
        reason: '整数 0 要当成音量 0（静音）',
      );

      expect(
        AppSettings.seekStep.value,
        30,
        reason: '别的设置不该被连累回默认值',
      );
    });

    test('窗口尺寸存成整数也能读', () async {
      SharedPreferences.setMockInitialValues({
        'window_width': 1600,
        'window_height': 900,
      });

      await AppSettings.load();

      expect(AppSettings.windowSize.value?.width, 1600.0);
      expect(AppSettings.windowSize.value?.height, 900.0);
    });

    test('数值存成字符串也能读', () async {
      SharedPreferences.setMockInitialValues({
        'player_last_volume': '0.25',
        'player_seek_step': '15',
      });

      await AppSettings.load();

      expect(AppSettings.lastVolume.value, closeTo(0.25, 0.001));
      expect(AppSettings.seekStep.value, 15);
    });

    test('彻底读不了的值只用默认值，其它照旧', () async {
      SharedPreferences.setMockInitialValues({
        'player_last_volume': 'not a number',
        'player_hold_speed': 3.0,
      });

      await AppSettings.load();

      expect(AppSettings.lastVolume.value, 1.0, reason: '读不了就用默认');
      expect(
        AppSettings.holdSpeed.value,
        3.0,
        reason: '其它设置照常读出',
      );
    });
  });
}
