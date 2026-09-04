enum ActivityDatePreset { today, days7, days30, days90, thisYear, all, custom }

extension ActivityDatePresetValue on ActivityDatePreset {
  String get title => switch (this) {
    ActivityDatePreset.today => '当天',
    ActivityDatePreset.days7 => '近7天',
    ActivityDatePreset.days30 => '近30天',
    ActivityDatePreset.days90 => '近90天',
    ActivityDatePreset.thisYear => '今年',
    ActivityDatePreset.all => '全部',
    ActivityDatePreset.custom => '自定义',
  };

  /// 解析为半开区间 [start, endExclusive)，自定义结束日包含全天。
  DateInterval resolve({
    required DateTime now,
    DateTime? customStart,
    DateTime? customEnd,
  }) {
    return switch (this) {
      ActivityDatePreset.today => DateInterval(
        _startOfDay(now),
        _addDays(_startOfDay(now), 1),
      ),
      ActivityDatePreset.days7 => DateInterval(_addDays(now, -7), now),
      ActivityDatePreset.days30 => DateInterval(_addDays(now, -30), now),
      ActivityDatePreset.days90 => DateInterval(_addDays(now, -90), now),
      ActivityDatePreset.thisYear => DateInterval(DateTime(now.year), now),
      ActivityDatePreset.all => DateInterval(DateTime(2000), now),
      ActivityDatePreset.custom => _customRange(
        customStart ?? now,
        customEnd ?? now,
      ),
    };
  }
}

final class DateInterval {
  const DateInterval(this.start, this.endExclusive);

  final DateTime start;
  final DateTime endExclusive;

  @override
  bool operator ==(Object other) {
    return other is DateInterval &&
        other.start == start &&
        other.endExclusive == endExclusive;
  }

  @override
  int get hashCode => Object.hash(start, endExclusive);
}

DateInterval _customRange(DateTime first, DateTime second) {
  final earlier = first.isBefore(second) ? first : second;
  final later = first.isBefore(second) ? second : first;
  return DateInterval(_startOfDay(earlier), _addDays(_startOfDay(later), 1));
}

DateTime _startOfDay(DateTime date) =>
    DateTime(date.year, date.month, date.day);

DateTime _addDays(DateTime date, int days) => DateTime(
  date.year,
  date.month,
  date.day + days,
  date.hour,
  date.minute,
  date.second,
  date.millisecond,
  date.microsecond,
);
