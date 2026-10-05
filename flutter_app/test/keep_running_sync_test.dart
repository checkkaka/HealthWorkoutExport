import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/auto_sync_checkpoint.dart';
import 'package:health_workout_export/auto_sync_controller.dart';
import 'package:health_workout_export/src/rust/api/simple.dart' as rust;
import 'package:health_workout_export/sync_history_logic.dart';
import 'package:health_workout_export/sync_preview_models.dart';
import 'package:health_workout_export/sync_recovery_runner.dart';
import 'package:health_workout_export/workout_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Keep batch checkpoint retains sport, datum, indoor and exact string ID',
    () {
      final configuration = <String, Object?>{
        'primary': 'keep',
        'supplements': <String>[],
        'gcjEnabled': true,
        'skipLocalHistory': true,
        'mode': 'api',
        'activities': [
          {
            'id': 'run-90071992547409931-1',
            'title': 'Keep 室内跑步',
            'startMs': 1704067200000,
            'endMs': 1704069000000,
            'durationSeconds': 1800,
            'distanceMeters': 3000,
            'sportType': 'Run',
            'coordinatesWgs84': true,
            'indoor': true,
          },
        ],
      };
      final bytes = AutoSyncCheckpoint(
        configuration: configuration,
        completedIds: {},
      ).encode();
      expect(AutoSyncCheckpoint.decode(bytes).configuration, configuration);
      expect(utf8.decode(bytes), isNot(contains('token')));
    },
  );

  test(
    'running recovery preserves sport, final FIT bytes and false commute',
    () {
      final original = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'primarySourceId': 'keep',
            'primaryActivityId': 'run-1',
            'title': 'Keep 跑步',
            'startDate': 725760000,
            'endDate': 725761800,
            'supplementSourceIds': <String>[],
            'durationSeconds': 1800,
            'distanceMeters': 3000,
            'uploadData': base64Encode([1, 2, 3, 4]),
            'filename': 'run.fit',
            'commute': false,
            'uploadChannel': 'api',
            'sportType': 'Run',
            'coordinatesWgs84': true,
          }),
        ),
      );
      final recovered = RecoveryUploadData.fromJson(original);
      final encoded = jsonDecode(utf8.decode(recovered.encode())) as Map;
      expect(encoded['sportType'], 'Run');
      expect(encoded['commute'], false);
      expect(recovered.fit, [1, 2, 3, 4]);
      expect(recovered.pending('a' * 64).toJson()['sportType'], 'Run');
    },
  );

  test('running history never assigns a cycling or unknown remote ID', () {
    final result = remoteIdAssignments(
      {
        'run': {
          'startDate': 100,
          'sportType': 'Run',
          'primarySourceId': 'keep',
        },
      },
      const [
        rust.StravaRemoteActivityResult(
          id: '1',
          startTimeSeconds: 978307300,
          endTimeSeconds: 978309100,
          sportType: 'Ride',
        ),
        rust.StravaRemoteActivityResult(
          id: '2',
          startTimeSeconds: 978307301,
          endTimeSeconds: 978309101,
        ),
        rust.StravaRemoteActivityResult(
          id: '3',
          startTimeSeconds: 978307305,
          endTimeSeconds: 978309105,
          sportType: 'Run',
        ),
      ],
    );
    expect(result, {'run': '3'});
  });

  test(
    'Keep Run keeps title, ignores cycling supplement, GCJ option and virtual power',
    () async {
      final run = WorkoutActivity(
        id: 'run-1',
        sourceId: WorkoutSourceId.keep,
        title: 'Keep 跑步',
        start: DateTime.utc(2024),
        end: DateTime.utc(2024, 1, 1, 0, 30),
        durationSeconds: 1800,
        distanceMeters: 3000,
        sportType: 'Run',
        coordinatesWgs84: true,
      );
      final ride = WorkoutActivity(
        id: 'ride-1',
        sourceId: WorkoutSourceId.onelap,
        title: '骑行',
        start: run.start,
        end: run.end,
        durationSeconds: 1800,
        distanceMeters: 3000,
        sportType: 'Ride',
      );
      final source = _Source(WorkoutSourceId.keep, [run]);
      final supplement = _Source(WorkoutSourceId.onelap, [ride]);
      var uploads = 0;
      var prepared = 0;
      var remoteMatchCalls = 0;
      final controller = AutoSyncController(
        fingerprint:
            ({
              required primarySourceId,
              required primaryActivityId,
              required startDateUnixSeconds,
              required supplementSourceIds,
              required destination,
            }) => 'a' * 64,
        inspectFit: ({required data}) async =>
            '{"summary":{},"issues":[],"track":[],"series":{}}',
        isLocallyUploaded: (_) async => false,
        remoteActivities: ({required after, required before}) async => [
          rust.StravaRemoteActivityResult(
            id: '77',
            startTimeSeconds: run.start.millisecondsSinceEpoch / 1000,
            endTimeSeconds: run.end.millisecondsSinceEpoch / 1000,
            distanceMeters: 3000,
            sportType: 'Ride',
          ),
        ],
        remoteMatchIndex:
            ({
              required startTimeSeconds,
              required endTimeSeconds,
              distanceMeters,
              required candidates,
            }) {
              remoteMatchCalls++;
              expect(candidates, isEmpty);
              return null;
            },
        commute: ({distanceMeters, required durationSeconds}) => true,
        matchIndex: ({required primary, required candidates}) =>
            candidates.isEmpty ? null : 0,
        prepareFit:
            ({
              required primary,
              required supplements,
              required gcjEnabled,
              virtualPower,
            }) async {
              prepared++;
              expect(supplements, isEmpty);
              expect(gcjEnabled, false);
              expect(virtualPower, isNull);
              return rust.PreparedFitResult(
                data: Uint8List.fromList([9]),
                repairedSpeedCount: 0,
                rewrittenCoordinateCount: 0,
                virtualPowerFilledCount: 0,
                powerSourceVirtual: false,
                averageCoordinateDisplacementMeters: 0,
                supplementReportsJson: '[]',
              );
            },
        persist: ({required record, required fit}) async {
          expect(record.title, 'Keep 跑步');
          expect(record.toJson()['sportType'], 'Run');
          expect(record.coordinatesWgs84, true);
        },
        upload:
            ({
              required logicalOperationId,
              required fit,
              required externalId,
              required filename,
              required commute,
              description,
              name,
            }) async {
              uploads++;
              expect(name, 'Keep 跑步');
              expect(commute, false);
              return const rust.StravaUploadFfiResponse(
                status: rust.StravaUploadFfiStatus.completed,
                remoteId: '42',
                isDuplicate: false,
              );
            },
        markUploaded:
            ({
              required fingerprint,
              required updatedAt,
              required remoteId,
              required isDuplicate,
              required distanceMeters,
              required durationSeconds,
            }) async {},
        markFailed:
            ({
              required fingerprint,
              required updatedAt,
              required message,
            }) async => fail(message),
      );
      final results = await controller.syncBatch(
        primary: source,
        supplements: [supplement],
        activities: [run],
        gcjEnabled: true,
        virtualPower: const rust.VirtualPowerFillInput(
          riderMassKg: 70,
          bikeMassKg: 8,
          cda: .3,
          includeInertia: true,
        ),
        onPreview: (_) async =>
            const SyncPreviewDecision(SyncPreviewAction.forceUpload),
      );
      expect(results.single.succeeded, true);
      expect(uploads, 1);
      expect(prepared, 1);
      expect(supplement.fetches, 0);
      expect(remoteMatchCalls, lessThanOrEqualTo(1));
    },
  );
}

final class _Source implements WorkoutSource {
  _Source(this.id, this.activities);
  @override
  final WorkoutSourceId id;
  final List<WorkoutActivity> activities;
  var fetches = 0;
  @override
  Future<bool> isAuthenticated() async => true;
  @override
  Future<void> logout() async {}
  @override
  Future<List<WorkoutActivity>> listActivities(interval) async => activities;
  @override
  Future<Uint8List> fetchFit(WorkoutActivity activity) async {
    fetches++;
    return Uint8List.fromList([1]);
  }
}
