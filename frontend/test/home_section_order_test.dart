import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/controllers/app_settings.dart';

/// 首页栏目排序。
///
/// 这块的坑都在「网站改了栏目」的时候：网站的栏目会增删，
/// 所以存的是**栏目名**、而且没排过的一定要排在最后且不能丢。
void main() {
  setUp(() {
    AppSettings.homeSectionOrder.value = const [];
  });

  List<String> apply(List<String> items) =>
      AppSettings.applyHomeOrder<String>(items, (name) => name);

  const siteOrder = ['A', 'B', 'C', 'D', 'E'];

  test('没排过时原样返回（用网站给的顺序）', () {
    expect(apply(siteOrder), siteOrder);
  });

  test('排过的按用户顺序', () {
    AppSettings.homeSectionOrder.value = const ['C', 'A', 'B', 'D', 'E'];

    expect(apply(siteOrder), ['C', 'A', 'B', 'D', 'E']);
  });

  test('只排了一部分：排过的在前，没排过的按原相对顺序排在后面', () {
    AppSettings.homeSectionOrder.value = const ['D', 'A'];

    // B / C / E 没排过 -> 排在后面，且保持 B、C、E 的原有先后
    expect(apply(siteOrder), ['D', 'A', 'B', 'C', 'E']);
  });

  test('网站新加了栏目（顺序里没有它）不会丢，排在最后', () {
    AppSettings.homeSectionOrder.value = const ['C', 'A'];

    // F 是网站新加的
    final withNew = [...siteOrder, 'F'];

    expect(apply(withNew), ['C', 'A', 'B', 'D', 'E', 'F']);
  });

  test('顺序里有网站已经删掉的栏目也不会出错', () {
    AppSettings.homeSectionOrder.value = const ['C', 'ZZZ', 'A'];

    expect(apply(siteOrder), ['C', 'A', 'B', 'D', 'E']);
  });

  test('两个没排过的栏目之间保持原来的先后（排序要稳定）', () {
    // Dart 的 List.sort 不保证稳定，所以实现里用「原下标」当次要关键字。
    // 这里放足够多的元素，逼它走快排那条路径。
    final many = [for (var i = 0; i < 40; i++) 'S$i'];

    AppSettings.homeSectionOrder.value = const ['S39'];

    final result = apply(many);

    expect(result.first, 'S39');

    final rest = result.sublist(1);

    expect(
      rest,
      [for (var i = 0; i < 39; i++) 'S$i'],
      reason: '没排过的部分必须保持原顺序',
    );
  });

  test('设置写入后能读到，并且会通知监听者', () async {
    var notified = 0;

    void listener() => notified++;

    AppSettings.homeSectionOrder.addListener(listener);
    addTearDown(() => AppSettings.homeSectionOrder.removeListener(listener));

    await AppSettings.setHomeSectionOrder(const ['B', 'A']);

    expect(AppSettings.homeSectionOrder.value, ['B', 'A']);
    expect(notified, 1);

    // 存进去的列表要拷贝一份，外面改原列表不能影响设置
    final outside = ['C'];
    await AppSettings.setHomeSectionOrder(outside);

    outside.add('D');

    expect(AppSettings.homeSectionOrder.value, ['C']);
  });
}
