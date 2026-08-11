import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/date_range.dart';

void main() {
  final now = DateTime(2026, 8, 11, 15, 30);

  test('近7天、30天和今年以当前时刻为半开区间终点', () {
    expect(
      ActivityDatePreset.days7.resolve(now: now),
      DateInterval(DateTime(2026, 8, 4, 15, 30), now),
    );
    expect(
      ActivityDatePreset.days30.resolve(now: now),
      DateInterval(DateTime(2026, 7, 12, 15, 30), now),
    );
    expect(
      ActivityDatePreset.thisYear.resolve(now: now),
      DateInterval(DateTime(2026), now),
    );
  });

  test('全部从本地日历的2000年1月1日开始', () {
    expect(
      ActivityDatePreset.all.resolve(now: now),
      DateInterval(DateTime(2000), now),
    );
  });

  test('自定义范围会归一反向日期并包含结束日', () {
    expect(
      ActivityDatePreset.custom.resolve(
        now: now,
        customStart: DateTime(2026, 8, 11, 23),
        customEnd: DateTime(2026, 8, 8, 9),
      ),
      DateInterval(DateTime(2026, 8, 8), DateTime(2026, 8, 12)),
    );
  });
}
