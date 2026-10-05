import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/activity_detail_page.dart';
import 'package:health_workout_export/activity_sync_status.dart';
import 'package:health_workout_export/auto_sync_page.dart';
import 'package:health_workout_export/main.dart';
import 'package:health_workout_export/native_channels.dart';
import 'package:health_workout_export/route_map.dart';
import 'package:health_workout_export/src/rust/frb_generated.dart';
import 'package:health_workout_export/sync_preview_models.dart';
import 'package:health_workout_export/sync_state_store.dart';
import 'package:health_workout_export/workout_source.dart';

// Only state decoding is needed to reach the detail navigation callbacks. FIT
// loading intentionally fails offline; these tests never request real records.
class _StateOnlyRustApi implements WorkoutCoreRustLibApi {
  @override
  Uint8List crateApiSimpleSyncStateApply({
    required List<int> stateJson,
    required List<int> commandJson,
  }) => Uint8List.fromList(stateJson);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const healthKit = MethodChannel('health_workout_export/healthkit');
  const syncFiles = MethodChannel('health_workout_export/sync_files');
  const vault = MethodChannel('health_workout_export/third_party_vault');
  const preferences = MethodChannel('health_workout_export/preferences');
  var records = <String, Object?>{};
  var activityType = 37;
  final start = DateTime(2026, 10, 1, 8);
  final end = start.add(const Duration(minutes: 30));

  setUpAll(() => WorkoutCoreRustLib.initMock(api: _StateOnlyRustApi()));
  tearDownAll(WorkoutCoreRustLib.dispose);
  setUp(() async {
    records = {};
    messenger.setMockMethodCallHandler(preferences, (_) async => null);
    messenger.setMockMethodCallHandler(vault, (call) async {
      throw MissingPluginException(call.method);
    });
    activityType = 37;
    SyncStateStore.changes.value++;
    messenger.setMockMethodCallHandler(syncFiles, (call) async {
      return switch (call.method) {
        'readState' => Uint8List.fromList(utf8.encode(jsonEncode(records))),
        'readSyncedFit' => Uint8List.fromList([1]),
        _ => throw PlatformException(code: 'sync_file_missing'),
      };
    });
    messenger.setMockMethodCallHandler(healthKit, (call) async {
      return switch (call.method) {
        'isAvailable' => true,
        'requestAuthorization' => null,
        'canWriteWorkouts' => false,
        'listWorkouts' => [
          {
            'uuid': 'activity-1',
            'activityName': 'Title is not sport provenance',
            'activityType': activityType,
            'startMs': start.millisecondsSinceEpoch,
            'endMs': end.millisecondsSinceEpoch,
            'durationSeconds': 1800.0,
            'totalDistanceMeters': 4200.0,
          },
        ],
        _ => throw MissingPluginException(call.method),
      };
    });
    // Initialize the store's shared serial queue outside widget fake-async zones.
    await SyncStateStore().allRecords();
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(healthKit, null);
    messenger.setMockMethodCallHandler(syncFiles, null);
    messenger.setMockMethodCallHandler(vault, null);
    messenger.setMockMethodCallHandler(preferences, null);
  });

  void saveStatus(String sourceId, bool? coordinatesWgs84) {
    records['saved-fit'] = {
      'primarySourceId': sourceId,
      'primaryActivityId': 'activity-1',
      'status': 'uploaded',
      'updatedAt': 1,
      'remoteId': '123456789',
      'coordinatesWgs84': ?coordinatesWgs84,
    };
  }

  Future<WorkoutActivityDetailPage> openDetail(
    WidgetTester tester, {
    required String sourceId,
    WorkoutActivity? activity,
  }) async {
    await tester.runAsync(ActivitySyncIndex.load);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showWorkoutActivityDetails(
              context,
              sourceId: sourceId,
              sourceTitle: sourceId,
              activityId: 'activity-1',
              title: 'Activity',
              start: start,
              durationSeconds: 1800,
              workout: activity,
            ),
            child: const Text('Open detail'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open detail'));
    await tester.runAsync(() => tester.pumpAndSettle());
    return tester.widget<WorkoutActivityDetailPage>(
      find.byType(WorkoutActivityDetailPage),
    );
  }

  for (final (source, explicitWgs84, expected) in [
    (WorkoutSourceId.keep, null, RouteCoordinateSystem.wgs84),
    (WorkoutSourceId.healthkit, false, RouteCoordinateSystem.unknown),
    (WorkoutSourceId.xingzhe, true, RouteCoordinateSystem.wgs84),
    (WorkoutSourceId.onelap, null, RouteCoordinateSystem.unknown),
  ]) {
    testWidgets('original map honors $source WGS84=$explicitWgs84', (
      tester,
    ) async {
      final detail = await openDetail(
        tester,
        sourceId: source.value,
        activity: WorkoutActivity(
          id: 'activity-1',
          sourceId: source,
          title: 'Activity',
          start: start,
          end: end,
          durationSeconds: 1800,
          coordinatesWgs84: explicitWgs84,
        ),
      );
      final map =
          detail.mapBuilder!(
                tester.element(find.byType(WorkoutActivityDetailPage)),
                const FitPreviewInspection(),
                false,
              )
              as WorkoutRouteMap;
      expect(map.lines.single.coordinateSystem, expected);
    });
  }

  for (final savedWgs84 in [true, false, null]) {
    testWidgets('synced Keep map uses saved WGS84=$savedWgs84', (tester) async {
      saveStatus('keep', savedWgs84);
      final detail = await openDetail(tester, sourceId: 'keep');
      expect(detail.loadSynced, isNotNull);
      final map =
          detail.mapBuilder!(
                tester.element(find.byType(WorkoutActivityDetailPage)),
                const FitPreviewInspection(),
                true,
              )
              as WorkoutRouteMap;
      expect(
        map.lines.single.coordinateSystem,
        savedWgs84 == true
            ? RouteCoordinateSystem.wgs84
            : RouteCoordinateSystem.unknown,
      );
    });
  }

  testWidgets('legacy source ID retains HealthKit fallback', (tester) async {
    final detail = await openDetail(tester, sourceId: 'com.apple.health');
    final map =
        detail.mapBuilder!(
              tester.element(find.byType(WorkoutActivityDetailPage)),
              const FitPreviewInspection(),
              false,
            )
            as WorkoutRouteMap;
    expect(map.lines.single.coordinateSystem, RouteCoordinateSystem.wgs84);
    unawaited(detail.onPreview!());
    await tester.runAsync(() => tester.pumpAndSettle());
    final page = tester.widget<AutoSyncPage>(find.byType(AutoSyncPage));
    expect(page.entrySource, WorkoutSourceId.healthkit);
    expect(page.selected.single.sportType, isNull);
  });

  for (final (type, sport) in [(13, 'Ride'), (37, 'Run'), (999, null)]) {
    for (final overwrite in [false, true]) {
      testWidgets('HealthKit type $type survives detail overwrite=$overwrite', (
        tester,
      ) async {
        activityType = type;
        saveStatus('healthkit', true);
        await tester.runAsync(ActivitySyncIndex.load);
        await tester.pumpWidget(
          const HealthWorkoutExportApp(healthKit: HealthKitChannel()),
        );
        await tester.runAsync(() => tester.pumpAndSettle());
        await tester.tap(find.byTooltip('活动详情'));
        await tester.runAsync(() => tester.pumpAndSettle());
        final detail = tester.widget<WorkoutActivityDetailPage>(
          find.byType(WorkoutActivityDetailPage),
        );
        unawaited((overwrite ? detail.onOverwrite : detail.onPreview)!());
        await tester.runAsync(() => tester.pumpAndSettle());
        final page = tester.widget<AutoSyncPage>(find.byType(AutoSyncPage));
        final activity = page.selected.single;
        expect(activity.sportType, sport);
        expect(activity.coordinatesWgs84, isTrue);
        expect(activity.id, 'activity-1');
        expect(activity.sourceId, WorkoutSourceId.healthkit);
        expect(activity.start, start);
        expect(activity.end, end);
        expect(activity.durationSeconds, 1800);
        expect(activity.distanceMeters, 4200);
        expect(page.initialPreviewPolicy, SyncPreviewPolicy.everyActivity);
        expect(page.initialSkipLocalHistory, !overwrite);
      });
    }
  }
}
