import 'package:flutter_test/flutter_test.dart';

import 'package:minireel/domain/models/preferences.dart';
import 'package:minireel/features/shared/watch_reminder.dart';

void main() {
  final base = Preferences(
    watchReminderEnabled: true,
    watchDailyLimitMinutes: 1,
    bedtimeReminderEnabled: false,
    watchUsageDate: '20260101',
    watchUsageMinutes: 0,
  );

  test('playing 状态按秒累计并触发每日上限提醒', () async {
    final reminder = WatchReminder();
    addTearDown(reminder.dispose);
    var saved = base;
    await reminder.tick(
      playing: true,
      preferences: saved,
      save: (preferences) async => saved = preferences,
    );
    // 同一秒内的重复 tick 不重复累计。
    await reminder.tick(
      playing: true,
      preferences: saved,
      save: (preferences) async => saved = preferences,
    );
    expect(saved.watchUsageMinutes, 1);
    expect(saved.watchUsageDate, hasLength(8));
    expect(reminder.message, contains('休息'));
  });

  test('未播放不累计', () async {
    final reminder = WatchReminder();
    addTearDown(reminder.dispose);
    var saved = base;
    await reminder.tick(
      playing: false,
      preferences: saved,
      save: (preferences) async => saved = preferences,
    );
    expect(saved.watchUsageMinutes, 0);
    expect(reminder.message, isNull);
  });

  test('consume 清空提醒文案', () async {
    final reminder = WatchReminder();
    addTearDown(reminder.dispose);
    var saved = base;
    await reminder.tick(
      playing: true,
      preferences: saved,
      save: (preferences) async => saved = preferences,
    );
    expect(reminder.message, isNotNull);
    reminder.consume();
    expect(reminder.message, isNull);
  });

  test('提醒关闭时不出现文案', () async {
    final reminder = WatchReminder();
    addTearDown(reminder.dispose);
    var saved = Preferences(
      watchReminderEnabled: false,
      bedtimeReminderEnabled: false,
      watchUsageDate: '20260101',
    );
    await reminder.tick(
      playing: true,
      preferences: saved,
      save: (preferences) async => saved = preferences,
    );
    expect(saved.watchUsageMinutes, 1);
    expect(reminder.message, isNull);
  });

  test('睡觉时间跨午夜判定', () {
    final reminder = WatchReminder();
    addTearDown(reminder.dispose);
    // 23:00 睡觉 → 23:30 命中，12:00 不命中。
    final lateNight = DateTime(2026, 1, 1, 23, 30);
    final noon = DateTime(2026, 1, 1, 12, 0);
    expect(reminder.pastBedtimeForTest(lateNight, 23 * 60), isTrue);
    expect(reminder.pastBedtimeForTest(noon, 23 * 60), isFalse);
    // 01:00 在 23:00 的跨午夜窗口内。
    expect(
      reminder.pastBedtimeForTest(DateTime(2026, 1, 2, 1, 0), 23 * 60),
      isTrue,
    );
  });
}
