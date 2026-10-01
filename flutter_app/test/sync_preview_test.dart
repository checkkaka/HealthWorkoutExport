import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/sync_preview_models.dart';
import 'package:health_workout_export/sync_preview_page.dart';

void main() {
  test(
    'explicit missing distance and duration flags override numeric zero placeholders',
    () {
      final value = FitPreviewInspection.decode(
        jsonEncode({
          'summary': {
            'distanceMeters': 0,
            'durationSeconds': 0,
            'hasDistance': false,
            'hasDuration': false,
          },
          'issues': [],
          'track': [],
          'series': {},
        }),
      );
      expect(value.hasDistance, isFalse);
      expect(value.hasDuration, isFalse);
      expect(
        const FitPreviewInspection(summary: {'distanceMeters': 12}).hasDistance,
        isTrue,
      );
    },
  );

  test('explicit detail preview policy wins saved async settings', () {
    expect(
      resolveSyncPreviewPolicy(
        'issuesOnly',
        explicit: SyncPreviewPolicy.everyActivity,
      ),
      SyncPreviewPolicy.everyActivity,
    );
    expect(
      resolveSyncPreviewPolicy(
        'everyActivity',
        explicit: SyncPreviewPolicy.issuesOnly,
      ),
      SyncPreviewPolicy.issuesOnly,
    );
  });

  testWidgets(
    'offline route supports pan zoom and resetting to the whole track',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SyncPreviewPage(
            prompt: const SyncPreviewPrompt(
              title: 'ride',
              original: FitPreviewInspection(),
              finalFit: FitPreviewInspection(
                track: [FitPreviewPoint(120, 30), FitPreviewPoint(121, 31)],
              ),
              issues: [],
              groups: [],
              fieldSources: {},
            ),
          ),
        ),
      );
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.textContaining('离线轨迹示意'), findsOneWidget);
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      final controller = viewer.transformationController!;
      controller.value = controller.value.clone()..setEntry(0, 3, 100);
      await tester.tap(find.text('回到轨迹'));
      await tester.pump();
      expect(controller.value.entry(0, 3), 0);
    },
  );

  test('GCJ report includes measured average displacement when supplied', () {
    final issues = processingQualityIssues(
      original: const FitPreviewInspection(),
      finalFit: const FitPreviewInspection(),
      gcjEnabled: true,
      repairedSpeedCount: 0,
      rewrittenCoordinateCount: 2,
      virtualPowerCount: 0,
      averageCoordinateDisplacementMeters: 123.4,
    );
    expect(issues.single.detail, contains('123.4'));
  });

  test(
    'stop preview cancels the entire dual-destination session before returning',
    () async {
      var stops = 0;
      const prompt = SyncPreviewPrompt(
        title: 'ride',
        original: FitPreviewInspection(),
        finalFit: FitPreviewInspection(),
        issues: [],
        groups: [],
        fieldSources: {},
      );
      await coordinateSyncPreview(
        prompt,
        chooser: (_) async => const SyncPreviewDecision(SyncPreviewAction.stop),
        onStop: () => stops++,
      );
      expect(stops, 1);
    },
  );

  test(
    'bounded inspection parser rejects malformed severities and overlarge track',
    () {
      Map<String, Object> raw() => {
        'summary': {'gpsCount': 1},
        'issues': [],
        'track': [],
        'series': {},
      };
      expect(
        FitPreviewInspection.decode(jsonEncode(raw())).summary['gpsCount'],
        1,
      );
      final bad = raw()
        ..['issues'] = [
          {
            'id': 'bad',
            'severity': 'safe',
            'title': 'title',
            'detail': 'detail',
          },
        ];
      expect(
        () => FitPreviewInspection.decode(jsonEncode(bad)),
        throwsFormatException,
      );
      final oversized = raw()
        ..['track'] = List.generate(
          2001,
          (_) => {'latitude': 1, 'longitude': 2},
        );
      expect(
        () => FitPreviewInspection.decode(jsonEncode(oversized)),
        throwsFormatException,
      );
    },
  );
  test(
    'coordinate modification while disabled and sensor loss are non-forceable errors',
    () {
      final original = FitPreviewInspection(
        summary: const {'gpsCount': 2, 'heartRateCount': 3},
        coordinateShapeHash: 'a' * 64,
        coordinateValueHash: 'b' * 64,
      );
      final finalFit = FitPreviewInspection(
        summary: const {'gpsCount': 1, 'heartRateCount': 2},
        coordinateShapeHash: 'a' * 64,
        coordinateValueHash: 'c' * 64,
      );
      final issues = processingQualityIssues(
        original: original,
        finalFit: finalFit,
        gcjEnabled: false,
        repairedSpeedCount: 0,
        rewrittenCoordinateCount: 0,
        virtualPowerCount: 0,
      );
      expect(
        issues.map((i) => i.id),
        containsAll([
          'coordinate-changed-while-disabled',
          'gpsCount-lost',
          'heartRateCount-lost',
        ]),
      );
      expect(issues.every((i) => i.severity == 'error'), isTrue);
    },
  );
  test('GCJ enabled allows values only, never shape changes', () {
    final issues = processingQualityIssues(
      original: FitPreviewInspection(
        coordinateShapeHash: 'a' * 64,
        coordinateValueHash: 'b' * 64,
      ),
      finalFit: FitPreviewInspection(
        coordinateShapeHash: 'c' * 64,
        coordinateValueHash: 'd' * 64,
      ),
      gcjEnabled: true,
      repairedSpeedCount: 0,
      rewrittenCoordinateCount: 1,
      virtualPowerCount: 0,
    );
    expect(
      issues.any(
        (i) => i.id == 'coordinate-shape-changed' && i.severity == 'error',
      ),
      isTrue,
    );
  });
  test(
    'ranking includes manual alternatives and flags ambiguous eligible choices',
    () {
      final start = DateTime.utc(2026);
      PreviewCandidate c(String id, int seconds) => PreviewCandidate(
        id: id,
        title: id,
        start: start.add(Duration(seconds: seconds)),
        end: start.add(Duration(seconds: 3600 + seconds)),
        durationSeconds: 3600,
      );
      final ranked = rankPreviewCandidates(c('p', 0), [
        c('close', 10),
        c('also-close', 20),
        c('manual', 1500),
        c('far', 5000),
      ]);
      expect(ranked.map((c) => c.id), ['close', 'also-close', 'manual']);
      expect(requiresMatchConfirmation(ranked), isTrue);
      expect(requiresMatchConfirmation([ranked.first]), isFalse);
    },
  );
  testWidgets('fatal issue disables upload and still permits stopping', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncPreviewPage(
          prompt: const SyncPreviewPrompt(
            title: 'ride',
            original: FitPreviewInspection(),
            finalFit: FitPreviewInspection(),
            fieldSources: {},
            groups: [],
            issues: [FitQualityIssue('fatal', 'error', '错误', '不可强传')],
          ),
        ),
      ),
    );
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认上传'),
    );
    expect(button.onPressed, isNull);
    expect(find.text('停止本批'), findsOneWidget);
  });
  testWidgets('changed source requires rebuild before upload', (tester) async {
    final start = DateTime.utc(2026);
    await tester.pumpWidget(
      MaterialApp(
        home: SyncPreviewPage(
          prompt: SyncPreviewPrompt(
            title: 'ride',
            original: const FitPreviewInspection(),
            finalFit: const FitPreviewInspection(),
            issues: const [],
            fieldSources: const {},
            groups: [
              PreviewCandidateGroup(
                sourceId: 'onelap',
                sourceTitle: '顽鹿',
                selectedId: 'a',
                candidates: [
                  PreviewCandidate(
                    id: 'a',
                    title: 'A',
                    start: start,
                    end: start.add(const Duration(hours: 1)),
                    durationSeconds: 3600,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本条不使用该补源').last);
    await tester.pumpAndSettle();
    expect(find.text('按所选补源重新生成并检查'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认上传'))
          .onPressed,
      isNull,
    );
  });
}
