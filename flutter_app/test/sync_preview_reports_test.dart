import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/sync_preview_models.dart';

Map<String, Object?> report(
  int index, {
  int heart = 0,
  int power = 0,
  int? offset = 0,
}) => {
  'index': index,
  'offsetSeconds': offset,
  'filledCounts': {
    'heartRate': heart,
    'cadence': 0,
    'power': power,
    'temperature': 0,
    'grade': 0,
  },
  'notes': <String>[],
};
void main() {
  test(
    'ordered reports preserve actual counts and nullable failed alignment offset',
    () {
      final reports = parseSupplementReports(
        jsonEncode([report(0, heart: 3, offset: null)]),
        expectedCount: 1,
      );
      expect(reports.single.filledCounts['heartRate'], 3);
      expect(reports.single.offsetSeconds, isNull);
    },
  );
  test(
    'bad count or index mismatch is rejected instead of misattributing data',
    () {
      expect(
        () => parseSupplementReports(jsonEncode([report(1)]), expectedCount: 1),
        throwsFormatException,
      );
      expect(
        () => parseSupplementReports(
          jsonEncode([report(0, heart: -1)]),
          expectedCount: 1,
        ),
        throwsFormatException,
      );
      expect(
        () => parseSupplementReports('[]', expectedCount: 1),
        throwsFormatException,
      );
    },
  );
  test(
    'field ownership follows successful-input indices, not configured source indices',
    () {
      final reports = parseSupplementReports(
        jsonEncode([report(0, heart: 3), report(1, power: 5)]),
        expectedCount: 2,
      );
      final sources = previewFieldSources(
        primaryName: '健康',
        original: const FitPreviewInspection(),
        finalFit: const FitPreviewInspection(
          summary: {'heartRateCount': 3, 'powerCount': 5},
        ),
        reports: reports,
        supplementNames: ['顽鹿实际下载', '行者实际下载'],
        virtualPower: false,
      );
      expect(sources['heartRate'], '顽鹿实际下载');
      expect(sources['power'], '行者实际下载');
    },
  );
  test(
    'virtual power overrides supplement power attribution and zero filled report warns',
    () {
      final reports = parseSupplementReports(
        jsonEncode([report(0), report(1, power: 5)]),
        expectedCount: 2,
      );
      final issues = supplementQualityIssues(reports, ['空补源', '功率补源']);
      expect(
        issues.where((i) => i.severity == 'warning').single.title,
        '补源未补入字段',
      );
      expect(
        issues.where((i) => i.severity == 'warning').single.detail,
        contains('空补源'),
      );
      expect(
        previewFieldSources(
          primaryName: '主源',
          original: const FitPreviewInspection(),
          finalFit: const FitPreviewInspection(),
          reports: reports,
          supplementNames: ['空补源', '功率补源'],
          virtualPower: true,
        )['power'],
        '虚拟功率',
      );
    },
  );
}
