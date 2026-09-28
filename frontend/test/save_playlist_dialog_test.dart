import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/widgets/save_playlist_dialog.dart';

/// 打开弹窗并返回它关闭时的结果
Future<List<String>?> _open(
  WidgetTester tester, {
  required List<Map<String, dynamic>> playlists,
  required void Function(List<PlaylistChange>) onApply,
  Future<String?> Function(String, String)? onCreate,
}) async {
  List<String>? result;

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showDialog<List<String>>(
                context: context,
                builder: (_) => SaveToPlaylistDialog(
                  playlists: playlists,
                  onApply: onApply,
                  onCreate: onCreate,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  return result;
}

void main() {
  group('储存弹窗：点选只标记 + 确认才生效（需求A）', () {
    testWidgets('已储存显示打钩+变色，未储存显示空方框',
        (WidgetTester tester) async {
      await _open(
        tester,
        playlists: [
          {'list_id': 'save', 'name': '稍后观看', 'checked': true},
          {'list_id': '613235', 'name': '同人', 'checked': false},
        ],
        onApply: (_) {},
      );

      expect(find.byIcon(Icons.check_box), findsOneWidget);
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);

      final theme = Theme.of(
        tester.element(find.byType(SaveToPlaylistDialog)),
      );

      expect(
        tester.widget<Text>(find.text('稍后观看')).style?.color,
        theme.colorScheme.primary,
      );

      expect(
        tester.widget<Text>(find.text('同人')).style?.color,
        isNot(theme.colorScheme.primary),
      );
    });

    testWidgets('只点选不提交：点一下只是改标记，onApply 不会被调用',
        (WidgetTester tester) async {
      final applied = <PlaylistChange>[];

      await _open(
        tester,
        playlists: [
          {'list_id': '1', 'name': '同人', 'checked': false},
        ],
        onApply: (changes) {
          applied.addAll(changes);
        },
      );

      await tester.tap(find.text('同人'));
      await tester.pumpAndSettle();

      // 标记变了（勾上了）
      expect(find.byIcon(Icons.check_box), findsOneWidget);

      // 但还没提交
      expect(applied, isEmpty, reason: '点选不应该立刻提交');

      // 点「确认」才提交
      await tester.tap(find.textContaining('确认'));
      await tester.pumpAndSettle();

      expect(applied.length, 1);
      expect(applied.first.name, '同人');
      expect(applied.first.save, isTrue);
    });

    testWidgets('取消勾选 + 确认 -> 提交 unsave', (WidgetTester tester) async {
      final applied = <PlaylistChange>[];

      await _open(
        tester,
        playlists: [
          {'list_id': '1', 'name': '同人', 'checked': true},
        ],
        onApply: (changes) {
          applied.addAll(changes);
        },
      );

      // 点一下 -> 勾号变方框
      await tester.tap(find.text('同人'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.check_box), findsNothing);
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);

      await tester.tap(find.textContaining('确认'));
      await tester.pumpAndSettle();

      expect(applied.length, 1);
      expect(applied.first.save, isFalse, reason: '应该提交取消储存');
    });

    testWidgets('没有改动时点确认不提交任何东西', (WidgetTester tester) async {
      final applied = <PlaylistChange>[];

      await _open(
        tester,
        playlists: [
          {'list_id': '1', 'name': '同人', 'checked': true},
        ],
        onApply: (changes) {
          applied.addAll(changes);
        },
      );

      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      expect(applied, isEmpty);
    });

    testWidgets('只提交有变化的清单（其余不动）', (WidgetTester tester) async {
      final applied = <PlaylistChange>[];

      await _open(
        tester,
        playlists: [
          {'list_id': '1', 'name': '甲', 'checked': true},
          {'list_id': '2', 'name': '乙', 'checked': false},
        ],
        onApply: (changes) {
          applied.addAll(changes);
        },
      );

      // 只把「乙」勾上
      await tester.tap(find.text('乙'));
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('确认'));
      await tester.pumpAndSettle();

      expect(applied.length, 1);
      expect(applied.first.name, '乙');
      expect(applied.first.save, isTrue);
    });

    testWidgets('确认后立刻关窗，不等后台同步', (WidgetTester tester) async {
      List<PlaylistChange>? sent;
      var backgroundFinished = false;

      await _open(
        tester,
        playlists: [
          {'list_id': '1', 'name': '同人', 'checked': false},
        ],
        onApply: (changes) {
          sent = changes;

          // 模拟"后台还在慢慢同步"
          backgroundFinished = false;
        },
      );

      await tester.tap(find.text('同人'));
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('确认'));

      // 只走退场动画（几百毫秒），不等任何后台同步
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byType(SaveToPlaylistDialog),
        findsNothing,
        reason: '点确认应该立刻关窗，不等同步完成',
      );

      expect(sent, isNotNull);
      expect(sent!.length, 1);

      // 顺带确认：同步是"交出去"的，弹窗不关心它完成没有
      expect(backgroundFinished, isFalse);
    });
  });

  group('新建播放清单（需求C）', () {
    testWidgets('顶部有「新建播放清单」按钮', (WidgetTester tester) async {
      await _open(
        tester,
        playlists: [
          {'list_id': '1', 'name': '同人', 'checked': false},
        ],
        onApply: (_) {},
        onCreate: (_, _) async => null,
      );

      expect(find.text('新建播放清单'), findsOneWidget);
    });

    testWidgets('标题必填：留空会被拦下', (WidgetTester tester) async {
      String? createdTitle;

      await _open(
        tester,
        playlists: const [],
        onApply: (_) {},
        onCreate: (title, _) async {
          createdTitle = title;
          return title;
        },
      );

      await tester.tap(find.text('新建播放清单'));
      await tester.pumpAndSettle();

      // 直接建立，标题为空 -> 应该报错
      await tester.tap(find.text('建立'));
      await tester.pumpAndSettle();

      expect(find.text('标题不能为空'), findsOneWidget);
      expect(createdTitle, isNull);
    });

    testWidgets('填了标题就能建立，并出现在清单里（已勾选）',
        (WidgetTester tester) async {
      String? gotTitle;
      String? gotDesc;

      await _open(
        tester,
        playlists: [
          {'list_id': '1', 'name': '同人', 'checked': false},
        ],
        onApply: (_) {},
        onCreate: (title, desc) async {
          gotTitle = title;
          gotDesc = desc;
          return title;
        },
      );

      await tester.tap(find.text('新建播放清单'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, '新清单');
      await tester.enterText(find.byType(TextFormField).last, '说明文字');

      await tester.tap(find.text('建立'));
      await tester.pumpAndSettle();

      expect(gotTitle, '新清单');
      expect(gotDesc, '说明文字');

      // 新清单出现在列表里
      expect(find.text('新清单'), findsOneWidget);

      // 官网建清单时会顺手把影片加进去，所以这里应该是已勾选
      expect(find.byIcon(Icons.check_box), findsOneWidget);
    });
  });
}
