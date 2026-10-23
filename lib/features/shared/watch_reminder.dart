import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/models/preferences.dart';

/// 观看提醒（移植自参考实现的每日时长/睡觉提醒）。
///
/// 播放页在播放状态变化时调用 [tick]；本类按真实播放秒数累计「今日
/// 已看时长」（跨会话持久化在偏好里），到量或到达睡觉时间后给出一条
/// 提醒文案，同一分钟内不重复打扰。
final class WatchReminder extends ChangeNotifier {
  String? _message;
  int _lastTickSecond = -1;
  int _lastTickMinute = -1;

  String? get message => _message;

  /// 播放页每次会话状态变化时调用；[playing] 表示视频正在播放，
  /// [save] 把累计结果落盘（偏好本身带节流写入）。
  Future<void> tick({
    required bool playing,
    required Preferences preferences,
    required Future<void> Function(Preferences preferences) save,
  }) async {
    final now = DateTime.now();
    if (now.second == _lastTickSecond) return;
    _lastTickSecond = now.second;

    if (!playing) return;

    final today = _dateKey(now);
    var minutes = preferences.watchUsageMinutes;
    if (preferences.watchUsageDate != today) minutes = 0;
    minutes = (minutes + 1).clamp(0, 1440);
    final updated = preferences.copyWith(
      watchUsageDate: today,
      watchUsageMinutes: minutes,
    );
    if (updated != preferences) {
      unawaited(save(updated));
    }

    if (now.minute == _lastTickMinute) return;
    _lastTickMinute = now.minute;

    String? message;
    if (preferences.bedtimeReminderEnabled &&
        _pastBedtime(now, preferences.bedtimeMinute)) {
      message = '已经很晚了，该休息了，注意身体哦';
    } else if (preferences.watchReminderEnabled &&
        minutes >= preferences.watchDailyLimitMinutes) {
      final hours = preferences.watchDailyLimitMinutes ~/ 60;
      final rest = preferences.watchDailyLimitMinutes % 60;
      message = rest == 0
          ? '今天已观看 $hours 小时，休息一下吧'
          : '今天已观看 $hours 小时 $rest 分钟，休息一下吧';
    }
    if (message == null || message == _message) return;
    _message = message;
    notifyListeners();
  }

  /// 睡觉时间支持跨午夜：23:00 提醒意味着 23:00-次日 05:00 都算夜间。
  @visibleForTesting
  bool pastBedtimeForTest(DateTime now, int bedtimeMinute) =>
      _pastBedtime(now, bedtimeMinute);

  bool _pastBedtime(DateTime now, int bedtimeMinute) {
    final nowMinute = now.hour * 60 + now.minute;
    const windowMinutes = 6 * 60;
    final diff = (nowMinute - bedtimeMinute + 1440) % 1440;
    return diff < windowMinutes;
  }

  /// 播放页展示完提醒后调用，清空当前文案。
  void consume() {
    if (_message == null) return;
    _message = null;
    notifyListeners();
  }

  String _dateKey(DateTime now) =>
      '${now.year.toString().padLeft(4, '0')}'
      '${now.month.toString().padLeft(2, '0')}'
      '${now.day.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _message = null;
    super.dispose();
  }
}
