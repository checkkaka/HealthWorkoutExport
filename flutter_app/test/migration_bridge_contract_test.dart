import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:health_workout_export/auto_sync_controller.dart';
import 'package:health_workout_export/sync_state_store.dart';
import 'package:health_workout_export/src/rust/api/simple.dart';
import 'package:health_workout_export/src/rust/api/keep.dart' as keep;
import 'package:health_workout_export/src/rust/frb_generated.dart';

const _startMs = 1704067200000;
final _fingerprint = 'a' * 64;

// These fixtures are invented. Every operation stays in memory; no HealthKit,
// source authentication, weather, upload, or remote deletion is involved.
Future<Uint8List> _fixtureFit({
  bool sensors = true,
  int heartRate = 140,
  int activityType = 13,
}) {
  List<Map<String, Object>> samples(num first, num last) => [
    {'dateMs': _startMs, 'value': first},
    {'dateMs': _startMs + 60000, 'value': last},
  ];
  return encodeHealthWorkoutFit(
    bundleJson: utf8.encode(
      jsonEncode({
        'uuid': '123e4567-e89b-12d3-a456-426614174000',
        'startMs': _startMs,
        'endMs': _startMs + 60000,
        'durationSeconds': 50,
        'activityType': activityType,
        'totalDistanceMeters': 1000,
        'totalEnergyKcal': 123,
        'events': [
          {'type': 'pause', 'dateMs': _startMs + 20000},
          {'type': 'resume', 'dateMs': _startMs + 30000},
        ],
        'series': sensors
            ? {
                'HKQuantityTypeIdentifierHeartRate': samples(
                  heartRate,
                  heartRate + 10,
                ),
                'HKQuantityTypeIdentifierCyclingCadence': samples(80, 90),
                'HKQuantityTypeIdentifierRunningPower': samples(200, 220),
              }
            : <String, Object>{},
        'route': [
          {
            'latitude': 31.2,
            'longitude': 121.5,
            'altitudeMeters': 12,
            'timestampMs': _startMs,
            'speedMetersPerSecond': 3.2,
          },
          {
            'latitude': 31.2001,
            'longitude': 121.5001,
            'altitudeMeters': 13,
            'timestampMs': _startMs + 60000,
            'speedMetersPerSecond': 3.4,
          },
        ],
      }),
    ),
    timezoneOffsetSeconds: 8 * 3600,
  );
}

Map<String, dynamic> _jsonObject(String value) =>
    jsonDecode(value) as Map<String, dynamic>;

Uint8List _jsonBytes(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final rustRoot = Directory('../rust/workout_core').absolute;
    final build = await Process.run('cargo', [
      'build',
      '--offline',
      '--locked',
    ], workingDirectory: rustRoot.path);
    expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');

    final fileName = Platform.isWindows
        ? 'rust_lib_health_workout_export.dll'
        : Platform.isMacOS
        ? 'librust_lib_health_workout_export.dylib'
        : 'librust_lib_health_workout_export.so';
    final library = File(
      '${rustRoot.path}${Platform.pathSeparator}target'
      '${Platform.pathSeparator}debug${Platform.pathSeparator}$fileName',
    );
    expect(library.existsSync(), isTrue);
    // Flutter test files run in separate isolates. Initialize once for this file.
    await WorkoutCoreRustLib.init(
      externalLibrary: ExternalLibrary.open(library.path),
    );
  });

  test(
    'preview crosses real FFI with summary, series and coordinate hashes',
    () async {
      final fit = await _fixtureFit();
      final preview = _jsonObject(await inspectFitPreview(data: fit));
      final summary = preview['summary'] as Map<String, dynamic>;
      expect(summary['recordCount'], 2);
      expect(summary['gpsCount'], 2);
      expect(summary['heartRateCount'], 2);
      expect(summary['cadenceCount'], 2);
      expect(summary['powerCount'], 2);
      expect(summary['durationSeconds'], 50);
      expect(summary['distanceMeters'], 1000);
      expect(summary['averageHeartRateBpm'], 145);
      expect(summary['maximumHeartRateBpm'], 150);
      final track = preview['track'] as List<dynamic>;
      expect(track, hasLength(2));
      expect(track.first['timeSeconds'], _startMs / 1000);
      expect(track.first['latitude'], closeTo(31.2, 0.000001));
      expect(track.first['longitude'], closeTo(121.5, 0.000001));
      expect(preview['series']['speed'].first['value'], closeTo(11.52, 0.001));
      expect(preview['series']['heartRate'].last['value'], 150);
      expect(
        preview['coordinateShapeHash'],
        matches(RegExp(r'^[a-f0-9]{64}$')),
      );
      expect(
        preview['coordinateValueHash'],
        matches(RegExp(r'^[a-f0-9]{64}$')),
      );
      expect(_jsonObject(await inspectFitPreview(data: fit)), preview);
    },
  );

  test(
    'invalid preview produces a bounded diagnostic through real FFI',
    () async {
      final preview = _jsonObject(
        await inspectFitPreview(data: utf8.encode('synthetic-invalid-fit')),
      );
      expect(preview['summary'], isEmpty);
      expect(preview['track'], isEmpty);
      expect(preview['series'], isEmpty);
      expect(preview['issues'], hasLength(1));
      expect(preview['issues'].single['id'], 'invalid-fit');
      expect(preview['issues'].single['severity'], 'error');
    },
  );

  test(
    'Health draft crosses real FFI with explicit units and timer events',
    () async {
      final draft = _jsonObject(
        utf8.decode(
          await decodeFitHealthDraft(
            data: await _fixtureFit(),
            fingerprint: _fingerprint,
          ),
        ),
      );
      expect(draft['fingerprint'], _fingerprint);
      expect(draft['activityType'], 13);
      expect(draft['startMs'], _startMs);
      expect(draft['endMs'], _startMs + 60000);
      expect(draft['durationSeconds'], 50);
      expect(draft['distanceMeters'], 1000);
      expect(draft['energyKilocalories'], 123);
      for (final sample in <({String key, String unit, num value})>[
        (key: 'heartRate', unit: 'count/min', value: 140),
        (key: 'cadence', unit: 'rpm', value: 80),
        (key: 'power', unit: 'W', value: 200),
        (key: 'speed', unit: 'm/s', value: 3.2),
      ]) {
        expect(draft[sample.key], hasLength(2));
        expect(draft[sample.key].first, {
          'dateMs': _startMs,
          'value': sample.value,
          'unit': sample.unit,
        });
      }
      expect(draft['locations'], hasLength(2));
      expect(draft['locations'].first['timestampMs'], _startMs);
      expect(draft['locations'].first['altitudeMeters'], 12);
      expect(draft['locations'].first['latitude'], closeTo(31.2, 0.000001));
      expect(draft['locations'].first['longitude'], closeTo(121.5, 0.000001));
      expect(draft['events'], [
        {'type': 'pause', 'dateMs': _startMs + 20000},
        {'type': 'resume', 'dateMs': _startMs + 30000},
      ]);
    },
  );

  test(
    'Health draft rejects malformed inputs across the async FFI boundary',
    () async {
      await expectLater(
        decodeFitHealthDraft(
          data: await _fixtureFit(),
          fingerprint: 'invalid-synthetic-fingerprint',
        ),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('InvalidFingerprint'),
          ),
        ),
      );
      await expectLater(
        decodeFitHealthDraft(data: const [1, 2, 3], fingerprint: _fingerprint),
        throwsA(
          predicate<Object>((error) => error.toString().contains('InvalidFit')),
        ),
      );
    },
  );

  test('preparation transports ordered actual supplement reports', () async {
    final prepared = await prepareFitForUpload(
      primary: await _fixtureFit(sensors: false),
      supplements: [await _fixtureFit(), await _fixtureFit(heartRate: 180)],
      gcjEnabled: false,
      virtualPower: null,
    );
    expect(isValidFit(data: prepared.data), isTrue);
    final reports = jsonDecode(prepared.supplementReportsJson) as List<dynamic>;
    expect(reports, hasLength(2));
    expect(reports[0]['index'], 0);
    expect(reports[0]['offsetSeconds'], 0);
    expect(reports[0]['filledCounts'], {
      'heartRate': 2,
      'cadence': 2,
      'power': 2,
      'temperature': 0,
      'grade': 0,
    });
    expect(reports[1]['index'], 1);
    expect(reports[1]['offsetSeconds'], 0);
    expect(reports[1]['filledCounts'].values, everyElement(0));
    final preview = _jsonObject(await inspectFitPreview(data: prepared.data));
    expect(preview['series']['heartRate'].first['value'], 140);
    expect(preview['series']['heartRate'].last['value'], 150);
    expect(prepared.averageCoordinateDisplacementMeters, 0);
    expect(prepared.rewrittenCoordinateCount, 0);
    expect(prepared.repairedSpeedCount, 0);
    expect(prepared.virtualPowerFilledCount, 0);
    expect(prepared.powerSourceVirtual, isFalse);
    expect(prepared.activityDescription, isNull);
  });

  test(
    'sparse same-clock fixtures reject auto but merge absolute through FFI',
    () async {
      final primary = await _fixtureFit(sensors: false);
      final supplement = await _fixtureFit();
      await expectLater(
        mergeFitFilesDetailed(
          primary: primary,
          supplements: [supplement],
          sensorsOnly: false,
          alignment: 'auto',
          manualOffsetSeconds: 0,
        ),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('InsufficientReliableData'),
          ),
        ),
      );
      final merged = await mergeFitFilesDetailed(
        primary: primary,
        supplements: [supplement],
        sensorsOnly: false,
        alignment: 'absolute',
        manualOffsetSeconds: 0,
      );
      expect(merged.offsetsSeconds, [0]);
      expect(isValidFit(data: merged.data), isTrue);
      final inspected = _jsonObject(await inspectFitPreview(data: merged.data));
      expect(inspected['summary']['heartRateCount'], 2);
    },
  );

  test('GCJ preparation transports nonzero coordinate displacement', () async {
    final fit = await _fixtureFit();
    final before = _jsonObject(await inspectFitPreview(data: fit));
    final prepared = await prepareFitForUpload(
      primary: fit,
      supplements: const [],
      gcjEnabled: true,
      virtualPower: null,
    );
    expect(isValidFit(data: prepared.data), isTrue);
    expect(jsonDecode(prepared.supplementReportsJson), isEmpty);
    expect(prepared.rewrittenCoordinateCount, greaterThanOrEqualTo(2));
    expect(
      prepared.averageCoordinateDisplacementMeters,
      inExclusiveRange(100, 1000),
    );
    expect(prepared.virtualPowerFilledCount, 0);
    expect(prepared.powerSourceVirtual, isFalse);
    expect(prepared.activityDescription, isNull);
    final after = _jsonObject(await inspectFitPreview(data: prepared.data));
    expect(after['coordinateShapeHash'], before['coordinateShapeHash']);
    expect(after['coordinateValueHash'], isNot(before['coordinateValueHash']));
  });

  test(
    'Health state commands preserve independent Strava outcome over FFI',
    () {
      var state = _jsonBytes({
        _fingerprint: {
          'fingerprint': _fingerprint,
          'status': 'uploaded',
          'primarySourceId': 'onelap',
          'primaryActivityId': 'synthetic-activity',
          'remoteId': 'synthetic-remote-id',
          'message': 'existing Strava outcome',
          'updatedAt': 721692800,
          'futureField': {'keep': true},
        },
      });
      Map<String, dynamic> apply(String operation, Map<String, Object> extra) {
        state = syncStateApply(
          stateJson: state,
          commandJson: _jsonBytes({
            'operation': operation,
            'fingerprint': _fingerprint,
            'updatedAt': 721692900,
            ...extra,
          }),
        );
        final record =
            _jsonObject(utf8.decode(state))[_fingerprint]
                as Map<String, dynamic>;
        expect(record['status'], 'uploaded');
        expect(record['remoteId'], 'synthetic-remote-id');
        expect(record['message'], 'existing Strava outcome');
        expect(record['updatedAt'], 721692900);
        expect(record['futureField'], {'keep': true});
        return record;
      }

      final failed = apply('markAppleHealthFailed', {
        'message': 'permission denied',
      });
      expect(failed['appleHealthError'], 'permission denied');
      final skipped = apply('markAppleHealthSkipped', {});
      expect(skipped['appleHealthSkipped'], isTrue);
      expect(skipped.containsKey('appleHealthError'), isFalse);
      const uuid = '12345678-1234-1234-ABCD-123456789ABC';
      final written = apply('markAppleHealthWritten', {'uuid': uuid});
      expect(written['appleHealthUUID'], uuid);
      expect(written.containsKey('appleHealthUuid'), isFalse);
      expect(written.containsKey('appleHealthSkipped'), isFalse);
      expect(written.containsKey('appleHealthError'), isFalse);

      final beforeInvalidCommand = Uint8List.fromList(state);
      expect(
        () => apply('markAppleHealthWritten', {'uuid': 'not-a-uuid'}),
        throwsA(anything),
      );
      expect(state, beforeInvalidCommand);
      expect(
        syncStateApply(
          stateJson: state,
          commandJson: _jsonBytes({'operation': 'validate'}),
        ),
        beforeInvalidCommand,
      );
    },
  );
  test(
    'Keep bridge cancellation never starts account/network work and cannot reuse handles',
    () async {
      final login = keep.keepReserveOperation(operationId: 'keep-ffi-login');
      expect(keep.keepCancelOperation(operationHandle: login.handle), true);
      await expectLater(
        keep.keepLogin(
          operationHandle: login.handle,
          account: 'synthetic-account',
          password: 'synthetic-password',
        ),
        throwsA(
          predicate((error) => error.toString().contains('KeepCancelled')),
        ),
      );
      expect(keep.keepReleaseOperation(operationHandle: login.handle), false);
      final list = keep.keepReserveOperation(operationId: 'keep-ffi-login');
      expect(list.handle, isNot(login.handle));
      expect(keep.keepCancelOperation(operationHandle: login.handle), false);
      expect(keep.keepCancelOperation(operationHandle: list.handle), true);
      await expectLater(
        keep.keepListWorkouts(
          operationHandle: list.handle,
          token: 'synthetic-token',
          fromSeconds: 1704067200,
          toSeconds: 1704070800,
        ),
        throwsA(
          predicate((error) => error.toString().contains('KeepCancelled')),
        ),
      );
      final detail = keep.keepReserveOperation(operationId: 'keep-ffi-detail');
      expect(keep.keepCancelOperation(operationHandle: detail.handle), true);
      await expectLater(
        keep.keepDownloadFit(
          operationHandle: detail.handle,
          token: 'synthetic-token',
          workoutId: '90071992547409931',
        ),
        throwsA(
          predicate((error) => error.toString().contains('KeepCancelled')),
        ),
      );
    },
  );

  test(
    'Run remote sport and Keep idempotent fingerprint cross the real bridge',
    () {
      final activities = stravaParseWebRemoteActivities(
        responseJson: _jsonBytes([
          {
            'id': 42,
            'start_date': '2024-01-01T00:00:00Z',
            'elapsed_time': 1800,
            'distance': 3000,
            'sport_type': 'Run',
          },
          {
            'id': 43,
            'start_date': '2024-01-01T00:00:00Z',
            'elapsed_time': 1800,
            'distance': 3000,
            'type': 'Ride',
          },
        ]),
      );
      expect(activities.map((a) => a.sportType), ['Run', 'Ride']);
      String fingerprint(List<String> supplements) => syncFingerprint(
        primarySourceId: 'keep',
        primaryActivityId: '90071992547409931',
        startDateUnixSeconds: 1704067200,
        supplementSourceIds: supplements,
        destination: 'strava',
      );
      expect(
        fingerprint(['healthkit', 'xingzhe']),
        fingerprint(['xingzhe', 'healthkit']),
      );
      expect(fingerprint([]), isNot(fingerprint(['healthkit'])));
    },
  );
  test(
    'final FIT running classification crosses FFI without modifying bytes',
    () async {
      final running = await _fixtureFit(activityType: 37);
      final original = List<int>.from(running);
      final runPreview = _jsonObject(await inspectFitPreview(data: running));
      expect(runPreview['allSessionsRunning'], true);
      expect(running, original);
      expect(
        _jsonObject(
          await inspectFitPreview(data: await _fixtureFit()),
        )['allSessionsRunning'],
        false,
      );
      expect(
        _jsonObject(
          await inspectFitPreview(data: [1, 2, 3]),
        )['allSessionsRunning'],
        false,
      );
    },
  );
  for (final activityType in [13, 37]) {
    for (final sourceId in ['healthkit', 'legacy.watch.bundle']) {
      for (final replace in [false, true]) {
        test(
          'legacy saved FIT reconstructs sport safely: type=$activityType source=$sourceId replace=$replace',
          () async {
            const channel = MethodChannel('health_workout_export/sync_files');
            final messenger = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
            final fit = await _fixtureFit(activityType: activityType);
            Uint8List state = _jsonBytes({
              _fingerprint: {
                'fingerprint': _fingerprint,
                'status': replace ? 'uploaded' : 'failed',
                'primarySourceId': sourceId,
                'primaryActivityId': 'legacy-workout',
                'updatedAt': 725760000,
                'startDate': 725760000,
                'durationSeconds': 50,
                'distanceMeters': 1000,
                'title': 'Legacy workout',
                if (replace) 'remoteId': '900',
              },
            });
            Uint8List? recovery;
            String? transactionExternalId;
            var uploads = 0, deletes = 0;
            messenger.setMockMethodCallHandler(channel, (call) async {
              final arguments = call.arguments as Map?;
              switch (call.method) {
                case 'readState':
                  return state;
                case 'writeState':
                  state = arguments!['bytes'] as Uint8List;
                  return null;
                case 'readSyncedFit':
                  return fit;
                case 'writeSyncedFit':
                  expect(arguments!['bytes'], fit);
                  return null;
                case 'readRecovery':
                  if (recovery == null) {
                    throw PlatformException(code: 'sync_file_missing');
                  }
                  return recovery;
                case 'writeRecovery':
                  recovery = arguments!['bytes'] as Uint8List;
                  final saved = jsonDecode(utf8.decode(recovery!)) as Map;
                  transactionExternalId = saved['externalId'] as String?;
                  return null;
                case 'deleteRecovery':
                  recovery = null;
                  return null;
                default:
                  throw MissingPluginException(call.method);
              }
            });
            try {
              final controller = AutoSyncController(
                stateStore: SyncStateStore.withDependencies(
                  const SyncFilesChannel.withChannel(channel),
                  syncStateApply,
                  syncRecoveryReencode,
                  syncRecoveryApply,
                ),
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
                      expect(
                        commute,
                        activityType == 13,
                        reason:
                            'legacy cycling keeps commute; Run final bytes suppress it',
                      );
                      expect(externalId, transactionExternalId);
                      expect(
                        fit,
                        await _fixtureFit(activityType: activityType),
                      );
                      return const StravaUploadFfiResponse(
                        status: StravaUploadFfiStatus.completed,
                        remoteId: '901',
                        isDuplicate: false,
                      );
                    },
              );
              final result = await controller.resumeRecovery(
                _fingerprint,
                replaceExisting: replace,
                deleteRemote: (id) async {
                  expect(id, '900');
                  deletes++;
                },
              );
              expect(result.succeeded, true, reason: result.message);
              expect(uploads, 1);
              expect(deletes, replace ? 1 : 0);
              expect(recovery, isNull);
              final saved =
                  (jsonDecode(utf8.decode(state)) as Map)[_fingerprint] as Map;
              expect(saved['status'], 'uploaded');
              expect(saved['remoteId'], '901');
            } finally {
              messenger.setMockMethodCallHandler(channel, null);
            }
          },
        );
      }
    }
  }
}
