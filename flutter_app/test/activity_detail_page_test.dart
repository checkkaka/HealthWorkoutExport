import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/activity_detail_page.dart';
import 'package:health_workout_export/sync_preview_models.dart';

FitPreviewInspection inspection(Uint8List data) => FitPreviewInspection(
  summary: {
    'distanceMeters': data.first * 1000.0,
    'durationSeconds': 60,
    'gpsCount': 2,
  },
  issues: const [FitQualityIssue('missing-power', 'info', '缺少功率', '没有功率记录')],
  series: const {
    'speed': [FitPreviewPoint(0, 10), FitPreviewPoint(1, 20)],
  },
);
void main() {
  testWidgets(
    'health destination reports partial saved UUID without hiding warning',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ActivityHealthStatusView(uuid: 'saved-id', error: '路线未完成'),
          ),
        ),
      );
      expect(find.text('已写入健康（有警告）'), findsOneWidget);
      expect(find.text('路线未完成'), findsOneWidget);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ActivityHealthStatusView(skipped: true)),
        ),
      );
      expect(find.text('已跳过健康写入'), findsOneWidget);
    },
  );

  testWidgets(
    'original and synced versions keep byte-exact export and inspection',
    (tester) async {
      List<int>? exported;
      bool? synced;
      await tester.pumpWidget(
        MaterialApp(
          home: WorkoutActivityDetailPage(
            title: '活动',
            sourceTitle: '健康',
            loadOriginal: () async => Uint8List.fromList([1]),
            loadSynced: () async => Uint8List.fromList([2]),
            inspect: (data) async => inspection(data),
            onExport: (_, data, version) async {
              exported = data.toList();
              synced = version;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1.00 公里'), findsOneWidget);
      await tester.tap(find.text('Strava 同步版'));
      await tester.pumpAndSettle();
      expect(find.text('2.00 公里'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('导出 Strava 同步版 FIT'), 300);
      await tester.tap(find.text('导出 Strava 同步版 FIT'));
      await tester.pumpAndSettle();
      expect(exported, [2]);
      expect(synced, isTrue);
    },
  );
  testWidgets('synced inspection remains usable when original source fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WorkoutActivityDetailPage(
          title: '活动',
          sourceTitle: '行者',
          loadOriginal: () async =>
              throw StateError('private token must not appear'),
          loadSynced: () async => Uint8List.fromList([2]),
          inspect: (data) async => inspection(data),
          onExport: (_, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2.00 公里'), findsOneWidget);
    expect(find.text('原始 FIT 读取失败，可重试或查看已保存同步版'), findsOneWidget);
    expect(find.textContaining('private token'), findsNothing);
  });
  testWidgets('overwrite requires consequence confirmation before callback', (
    tester,
  ) async {
    var overwritten = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WorkoutActivityDetailPage(
          title: '活动',
          sourceTitle: '顽鹿',
          loadOriginal: () async => Uint8List.fromList([1]),
          inspect: (data) async => inspection(data),
          onExport: (_, _, _) async {},
          onOverwrite: () async {
            overwritten++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('重新生成并配置覆盖'), 300);
    await tester.tap(find.text('重新生成并配置覆盖'));
    await tester.pumpAndSettle();
    expect(overwritten, 0);
    expect(find.textContaining('点赞、评论和照片'), findsOneWidget);
    await tester.tap(find.text('继续配置'));
    await tester.pumpAndSettle();
    expect(overwritten, 1);
  });
}
