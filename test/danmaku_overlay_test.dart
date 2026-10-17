import 'package:flutter_test/flutter_test.dart';
import 'package:minireel/data/sources/hongguo/hongguo_danmaku_service.dart';
import 'package:minireel/features/danmaku/danmaku_overlay.dart';

/// 纯算法测试：不访问网络、不创建播放器。
HongguoDanmakuItem item(String id, int timeMs, {String? text}) =>
    HongguoDanmakuItem(id: id, text: text ?? id, timeMs: timeMs);

DanmakuFlight flight(
  String id,
  int timeMs, {
  int lane = 0,
  double width = 100,
  int lifetimeMs = 8000,
}) => DanmakuFlight(
  item: item(id, timeMs),
  text: id,
  lane: lane,
  width: width,
  lifetimeMs: lifetimeMs,
);

double measure(String text) => text.runes.length * 10.0;

void main() {
  group('planDanmaku 轨道分配', () {
    test('参数非法时返回空计划', () {
      final items = [item('a', 0)];
      expect(planDanmaku(items, width: 0, rows: 2, measure: measure), isEmpty);
      expect(
        planDanmaku(items, width: 100, rows: 0, measure: measure),
        isEmpty,
      );
      expect(
        planDanmaku(
          items,
          width: 100,
          rows: 2,
          measure: measure,
          lifetimeMs: 0,
        ),
        isEmpty,
      );
      expect(
        planDanmaku(const [], width: 100, rows: 2, measure: measure),
        isEmpty,
      );
    });

    test('同一时刻的弹幕分配到不同轨道', () {
      final flights = planDanmaku(
        [item('a', 0), item('b', 0)],
        width: 1000,
        rows: 2,
        measure: measure,
      );
      expect(flights.length, 2);
      expect(flights[0].lane, 0);
      expect(flights[1].lane, 1);
    });

    test('同轨道间距不足时丢弃该条', () {
      final flights = planDanmaku(
        [item('aaaa', 0), item('bbbb', 100)],
        width: 1000,
        rows: 1,
        measure: measure,
      );
      expect(flights.length, 1);
      expect(flights.single.item.id, 'aaaa');
    });

    test('间隔超过飞行时长后复用同一轨道', () {
      final flights = planDanmaku(
        [item('a', 0), item('b', 8000)],
        width: 1000,
        rows: 1,
        measure: measure,
      );
      expect(flights.length, 2);
      expect(flights.every((entry) => entry.lane == 0), isTrue);
    });

    test('按时间排序并跳过重复 id、空文本与负时间', () {
      final flights = planDanmaku(
        [
          item('b', 500),
          item('a', 0),
          item('a', 100),
          item('', 0),
          item('c', -1),
          item('d', 0, text: '   '),
        ],
        width: 1000,
        rows: 3,
        measure: measure,
      );
      expect(flights.map((entry) => entry.item.id), ['a', 'b']);
      expect(flights[0].item.timeMs, 0);
      expect(flights[1].item.timeMs, 500);
    });

    test('同屏活跃弹幕不超过上限', () {
      final items = [
        for (var index = 0; index < 40; index++) item('d$index', index * 10),
      ];
      final flights = planDanmaku(
        items,
        width: 10000,
        rows: 12,
        measure: measure,
      );
      expect(flights.length, 30);
    });

    test('轨道数量不超过上限', () {
      final items = [
        for (var index = 0; index < 20; index++) item('d$index', 0),
      ];
      final flights = planDanmaku(
        items,
        width: 1000,
        rows: 50,
        measure: measure,
      );
      // 同一时刻最多只能放进 12 条轨道。
      expect(flights.length, 12);
    });
  });

  group('visibleDanmakuFlights 可见性', () {
    final flights = [flight('a', 0), flight('b', 5000)];

    test('弹幕在进入时间之前不可见', () {
      expect(
        visibleDanmakuFlights(flights, positionMs: 0, lifetimeMs: 8000),
        hasLength(1),
      );
      expect(
        visibleDanmakuFlights(
          flights,
          positionMs: 0,
          lifetimeMs: 8000,
        ).single.item.id,
        'a',
      );
    });

    test('弹幕进入后到飞行结束前可见', () {
      expect(
        visibleDanmakuFlights(flights, positionMs: 5000, lifetimeMs: 8000),
        hasLength(2),
      );
      final atEnd = visibleDanmakuFlights(
        flights,
        positionMs: 8000,
        lifetimeMs: 8000,
      );
      expect(atEnd.map((entry) => entry.item.id), ['b']);
      expect(
        visibleDanmakuFlights(flights, positionMs: 12999, lifetimeMs: 8000),
        hasLength(1),
      );
      expect(
        visibleDanmakuFlights(flights, positionMs: 13000, lifetimeMs: 8000),
        isEmpty,
      );
    });

    test('最多返回 maxVisible 条，保留最新进入的', () {
      final visible = visibleDanmakuFlights(
        flights,
        positionMs: 5000,
        lifetimeMs: 8000,
        maxVisible: 1,
      );
      expect(visible.single.item.id, 'b');
    });

    test('参数非法时返回空结果', () {
      expect(
        visibleDanmakuFlights(const [], positionMs: 0, lifetimeMs: 8000),
        isEmpty,
      );
      expect(
        visibleDanmakuFlights(flights, positionMs: 5000, lifetimeMs: 0),
        isEmpty,
      );
      expect(
        visibleDanmakuFlights(
          flights,
          positionMs: 5000,
          lifetimeMs: 8000,
          maxVisible: 0,
        ),
        isEmpty,
      );
    });
  });
}
