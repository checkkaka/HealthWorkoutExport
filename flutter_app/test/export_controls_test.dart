import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/export_controls.dart';
import 'package:health_workout_export/workout_export.dart';

WorkoutExportActivity _activity() => WorkoutExportActivity(
  id: '1',
  sourceId: 'onelap',
  title: '测试骑行',
  start: DateTime.utc(2024),
  end: DateTime.utc(2024, 1, 1, 1),
  durationSeconds: 3600,
);

void main() {
  testWidgets('缺同步文件禁选同步版，摘要 JSON 仍可选择', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              WorkoutExportControls(
                initialFormat: WorkoutExportFormat.fit,
                activities: [_activity()],
                syncedStore: SyncedFitExportStore(loadRecords: () async => {}),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = tester
        .widget<DropdownButtonFormField<WorkoutFitExportSource>>(
          find.byType(DropdownButtonFormField<WorkoutFitExportSource>),
        );
    // Items belong to the DropdownButton built by the form field.
    expect(field.enabled, isTrue);
    final dropdown = tester.widget<DropdownButton<WorkoutFitExportSource>>(
      find.byType(DropdownButton<WorkoutFitExportSource>),
    );
    expect(
      dropdown.items!
          .singleWhere((item) => item.value == WorkoutFitExportSource.synced)
          .enabled,
      isFalse,
    );
    await tester.tap(find.byType(DropdownButtonFormField<WorkoutExportFormat>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JSON').last);
    await tester.pumpAndSettle();
    expect(find.text('第三方源 JSON 仅为活动摘要；完整轨迹请导出 FIT。'), findsOneWidget);
  });

  testWidgets('分享结果可重试，失败新导出保留旧结果，删除需确认', (tester) async {
    final item = _activity();
    var failDownload = false;
    var shareCount = 0;
    WorkoutExportResult? result;
    var exportBusy = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              WorkoutExportControls(
                initialFormat: WorkoutExportFormat.fit,
                activities: [item],
                syncedStore: SyncedFitExportStore(loadRecords: () async => {}),
                loadOriginalFit: (_) async {
                  if (failDownload) throw StateError('下载失败');
                  return Uint8List.fromList([1, 2, 3]);
                },
                shareResult: (value) async {
                  result = value;
                  shareCount++;
                },
                onBusyChanged: (busy) {
                  exportBusy = busy;
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('导出并分享'));
    await tester.tap(find.text('导出并分享'));
    await _settleFileWork(tester, () => !exportBusy);
    await tester.pumpAndSettle();
    expect(shareCount, 1);
    expect(result, isNotNull);
    addTearDown(() => result?.dispose());

    await tester.ensureVisible(find.text('再次分享'));
    await tester.tap(find.text('再次分享'));
    await tester.pumpAndSettle();
    expect(shareCount, 2);
    failDownload = true;
    await tester.ensureVisible(find.text('导出并分享'));
    await tester.tap(find.text('导出并分享'));
    await _settleFileWork(tester, () => !exportBusy);
    await tester.pumpAndSettle();
    expect(find.textContaining('下载失败'), findsOneWidget);
    expect(shareCount, 2);
    expect(await tester.runAsync(() => result!.file.exists()), isTrue);

    await tester.ensureVisible(find.text('删除本次导出'));
    await tester.tap(find.text('删除本次导出'));
    await tester.pumpAndSettle();
    expect(find.text('删除本次导出？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => result!.file.exists()), isTrue);
    await tester.tap(find.text('删除本次导出'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await _settleFileWork(tester, () => find.text('再次分享').evaluate().isEmpty);
    await tester.pumpAndSettle();
    expect(find.text('再次分享'), findsNothing);
  });

  testWidgets('选择同步版后检查发现文件已丢失则拒绝导出', (tester) async {
    final item = _activity();
    final fingerprint = 'a' * 64;
    var exists = true;
    var originalDownloads = 0;
    var shares = 0;
    final store = SyncedFitExportStore(
      loadRecords: () async => exists
          ? {
              fingerprint: {
                'status': 'uploaded',
                'primarySourceId': item.sourceId,
                'primaryActivityId': item.id,
                'updatedAt': 1,
              },
            }
          : {},
      readFit: (_) async => Uint8List.fromList([1]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              WorkoutExportControls(
                initialFormat: WorkoutExportFormat.fit,
                activities: [item],
                syncedStore: store,
                loadOriginalFit: (_) async {
                  originalDownloads++;
                  return Uint8List(1);
                },
                shareResult: (_) async {
                  shares++;
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byType(DropdownButtonFormField<WorkoutFitExportSource>),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Strava 同步版').last);
    await tester.pumpAndSettle();
    exists = false;
    await tester.ensureVisible(find.text('导出并分享'));
    await tester.tap(find.text('导出并分享'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有保存 Strava 同步版 FIT'), findsOneWidget);
    expect(originalDownloads, 0);
    expect(shares, 0);
  });
}

Future<void> _settleFileWork(
  WidgetTester tester,
  bool Function() complete,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (complete()) return;
  }
  fail('异步文件操作未完成');
}
