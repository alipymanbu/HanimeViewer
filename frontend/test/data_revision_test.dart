import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/controllers/data_revision.dart';

void main() {
  group('全局数据版本号（DataRevision）', () {
    test('bump 会通知监听者', () {
      var notified = 0;

      void listener() => notified++;

      DataRevision.revision.addListener(listener);
      addTearDown(() => DataRevision.revision.removeListener(listener));

      final before = DataRevision.revision.value;

      DataRevision.bump();
      DataRevision.bump();

      expect(notified, 2);
      expect(DataRevision.revision.value, before + 2);
    });

    test('移除监听后不再收到通知', () {
      var notified = 0;

      void listener() => notified++;

      DataRevision.revision.addListener(listener);
      DataRevision.bump();

      DataRevision.revision.removeListener(listener);
      DataRevision.bump();

      expect(notified, 1, reason: '移除后不该再被通知');
    });
  });
}
