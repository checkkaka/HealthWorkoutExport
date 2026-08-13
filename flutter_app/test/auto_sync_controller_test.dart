import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/auto_sync_controller.dart';
import 'package:health_workout_export/src/rust/api/simple.dart' as rust;
import 'package:health_workout_export/sync_state_store.dart';

const _uuid = 'A4B64E8C-0012-4A0B-993E-140FC6B721C0';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const healthChannel = MethodChannel('health_workout_export/healthkit');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final fingerprint = 'a' * 64;

  setUp(() {
    messenger.setMockMethodCallHandler(healthChannel, (call) async {
      if (call.method != 'fetchWorkoutBundles') {
        throw MissingPluginException(call.method);
      }
      return [_bundle()];
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(healthChannel, null));

  AutoSyncController controller({
    required List<String> order,
    required Future<void> Function() persist,
    required Future<void> Function() markUploaded,
    required Future<void> Function() markFailed,
    required rust.StravaUploadFfiResponse response,
    bool locallyUploaded = false,
    List<rust.StravaRemoteActivityResult> remoteActivities = const [],
    Future<void> Function()? markRemoteDuplicate,
  }) => AutoSyncController(
    fingerprint:
        ({
          required primarySourceId,
          required primaryActivityId,
          required startDateUnixSeconds,
          required supplementSourceIds,
          required destination,
        }) => fingerprint,
    fitEncoder: ({required bundleJson, required timezoneOffsetSeconds}) async {
      expect(jsonDecode(utf8.decode(bundleJson))['uuid'], _uuid);
      return Uint8List.fromList(const [1, 2, 3]);
    },
    persist: ({required record, required fit}) async {
      order.add('fit-pending');
      expect(record.fingerprint, fingerprint);
      expect(fit, Uint8List.fromList(const [1, 2, 3]));
      await persist();
    },
    upload:
        ({
          required logicalOperationId,
          required fit,
          required externalId,
          required filename,
          required commute,
        }) async {
          order.add('upload');
          expect(externalId, fingerprint);
          return response;
        },
    markUploaded:
        ({
          required fingerprint,
          required updatedAt,
          required remoteId,
          required isDuplicate,
          required distanceMeters,
          required durationSeconds,
        }) async {
          order.add('uploaded');
          await markUploaded();
        },
    markFailed:
        ({required fingerprint, required updatedAt, required message}) async {
          order.add('failed');
          expect(message, isNot(contains('secret-token')));
          await markFailed();
        },
    isLocallyUploaded: (_) async => locallyUploaded,
    remoteActivities: ({required after, required before}) async =>
        remoteActivities,
    markRemoteDuplicate: ({required record, required remoteId}) async {
      order.add('remote-duplicate');
      expect(record.fingerprint, fingerprint);
      await markRemoteDuplicate?.call();
    },
    stableDedupe:
        ({
          required startASeconds,
          required distanceAMeters,
          required startBSeconds,
          required distanceBMeters,
          durationASeconds,
          durationBSeconds,
        }) =>
            (startASeconds - startBSeconds).abs() <= 300 &&
            (distanceAMeters - distanceBMeters).abs() <= 100,
    commute: ({distanceMeters, required durationSeconds}) => false,
  );

  test('首传先落 FIT/pending，上传完成后才标记 uploaded', () async {
    final order = <String>[];
    final results = await controller(
      order: order,
      persist: () async {},
      markUploaded: () async {},
      markFailed: () async {},
      response: const rust.StravaUploadFfiResponse(
        status: rust.StravaUploadFfiStatus.completed,
        remoteId: '42',
        isDuplicate: false,
      ),
    ).sync([_uuid]);

    expect(results.single.succeeded, isTrue, reason: results.single.message);
    expect(order, ['fit-pending', 'upload', 'uploaded']);
    expect(results.single.succeeded, isTrue);
    expect(results.single.remoteId, '42');
  });

  test('状态落盘失败时不启动上传，保留由存储层完成的 FIT 回滚', () async {
    final order = <String>[];
    final results = await controller(
      order: order,
      persist: () async => throw StateError('state write failed'),
      markUploaded: () async {},
      markFailed: () async {},
      response: const rust.StravaUploadFfiResponse(
        status: rust.StravaUploadFfiStatus.completed,
        isDuplicate: false,
      ),
    ).sync([_uuid]);

    expect(order, ['fit-pending']);
    expect(results.single.succeeded, isFalse);
    expect(results.single.message, '同步首传失败');
  });

  test('上传失败后保留已持久化 FIT，并标记 failed 但不泄漏响应内容', () async {
    final order = <String>[];
    final results = await controller(
      order: order,
      persist: () async {},
      markUploaded: () async {},
      markFailed: () async {},
      response: const rust.StravaUploadFfiResponse(
        status: rust.StravaUploadFfiStatus.failed,
        isDuplicate: false,
        error: rust.StravaUploadFfiError(
          code: rust.StravaUploadFfiErrorCode.transport,
          message: 'secret-token',
        ),
      ),
    ).sync([_uuid]);

    expect(order, ['fit-pending', 'upload', 'failed']);
    expect(results.single.succeeded, isFalse);
    expect(results.single.message, 'Strava 上传未完成');
  });

  test('已有同指纹本地记录时不读取远端也不重新上传', () async {
    final order = <String>[];
    final results = await controller(
      order: order,
      persist: () async {},
      markUploaded: () async {},
      markFailed: () async {},
      locallyUploaded: true,
      response: const rust.StravaUploadFfiResponse(
        status: rust.StravaUploadFfiStatus.completed,
        isDuplicate: false,
      ),
    ).sync([_uuid]);

    expect(results.single.succeeded, isTrue);
    expect(results.single.isDuplicate, isTrue);
    expect(order, isEmpty);
  });

  test('Strava 稳定近似活动会落本地去重状态而不上传 FIT', () async {
    final order = <String>[];
    final results = await controller(
      order: order,
      persist: () async {},
      markUploaded: () async {},
      markFailed: () async {},
      remoteActivities: const [
        rust.StravaRemoteActivityResult(
          id: '42',
          startTimeSeconds: 1704067210,
          endTimeSeconds: 1704070800,
          distanceMeters: 1235,
        ),
      ],
      response: const rust.StravaUploadFfiResponse(
        status: rust.StravaUploadFfiStatus.completed,
        isDuplicate: false,
      ),
    ).sync([_uuid]);

    expect(results.single.succeeded, isTrue);
    expect(results.single.isDuplicate, isTrue);
    expect(results.single.remoteId, '42');
    expect(order, ['remote-duplicate']);
  });

  test('恢复重传复用已落盘 externalId，上传前持久化阶段并在完成后清理', () async {
    const syncChannel = MethodChannel('health_workout_export/sync_files');
    final recovery = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'primarySourceId': 'healthkit',
          'primaryActivityId': _uuid,
          'title': '骑车',
          'startDate': 0,
          'endDate': 3600,
          'supplementSourceIds': <String>[],
          'durationSeconds': 3600,
          'uploadData': 'AQID',
          'filename': 'recovery.fit',
          'commute': false,
          'phase': 'prepared',
          'externalId': 'stable-recovery-id',
          'fitSha256': 'e' * 64,
        }),
      ),
    );
    var state = Uint8List.fromList(utf8.encode('{}'));
    var deletedRecovery = false;
    Uint8List? savedFit;
    final phases = <String>[];
    messenger.setMockMethodCallHandler(syncChannel, (call) async {
      switch (call.method) {
        case 'readState':
          return state;
        case 'writeState':
          state =
              (call.arguments as Map<Object?, Object?>)['bytes']! as Uint8List;
          return null;
        case 'readSyncedFit':
          throw PlatformException(code: 'sync_file_missing');
        case 'writeSyncedFit':
          savedFit =
              (call.arguments as Map<Object?, Object?>)['bytes']! as Uint8List;
          return null;
        case 'readRecovery':
          return recovery;
        case 'writeRecovery':
          phases.add(
            (jsonDecode(
                      utf8.decode(
                        (call.arguments as Map<Object?, Object?>)['bytes']!
                            as Uint8List,
                      ),
                    )
                    as Map<String, dynamic>)['phase']
                as String,
          );
          return null;
        case 'deleteRecovery':
          deletedRecovery = true;
          return null;
      }
      throw MissingPluginException(call.method);
    });

    Uint8List applyState({
      required List<int> stateJson,
      required List<int> commandJson,
    }) {
      final records =
          jsonDecode(utf8.decode(stateJson)) as Map<String, dynamic>;
      final command =
          jsonDecode(utf8.decode(commandJson)) as Map<String, dynamic>;
      switch (command['operation']) {
        case 'markPending':
          final record = command['record'] as Map<String, dynamic>;
          records[record['fingerprint'] as String] = record;
          break;
        case 'markUploaded':
          final update = command['update'] as Map<String, dynamic>;
          final record =
              records[update['fingerprint'] as String] as Map<String, dynamic>;
          record['status'] = 'uploaded';
          record['remoteId'] = update['remoteId'];
          break;
        case 'markFailed':
          final record =
              records[command['fingerprint'] as String]
                  as Map<String, dynamic>?;
          if (record != null) record['status'] = 'failed';
          break;
      }
      return Uint8List.fromList(utf8.encode(jsonEncode(records)));
    }

    Uint8List applyRecovery({
      required List<int> recoveryJson,
      required List<int> commandJson,
    }) {
      final value =
          jsonDecode(utf8.decode(recoveryJson)) as Map<String, dynamic>;
      final command =
          jsonDecode(utf8.decode(commandJson)) as Map<String, dynamic>;
      if (command['operation'] == 'markUploading') value['phase'] = 'uploading';
      return Uint8List.fromList(utf8.encode(jsonEncode(value)));
    }

    try {
      final store = SyncStateStore.withDependencies(
        const SyncFilesChannel.withChannel(syncChannel),
        applyState,
        ({required recoveryJson}) => Uint8List.fromList(recoveryJson),
        applyRecovery,
      );
      String? uploadedExternalId;
      final result = await AutoSyncController(
        stateStore: store,
        upload:
            ({
              required logicalOperationId,
              required fit,
              required externalId,
              required filename,
              required commute,
            }) async {
              uploadedExternalId = externalId;
              expect(logicalOperationId, 'recovery-$fingerprint');
              expect(filename, 'recovery.fit');
              expect(fit, Uint8List.fromList(const [1, 2, 3]));
              return const rust.StravaUploadFfiResponse(
                status: rust.StravaUploadFfiStatus.completed,
                remoteId: '42',
                isDuplicate: false,
              );
            },
      ).resumeRecovery(fingerprint);

      expect(result.succeeded, isTrue, reason: result.message);
      expect(uploadedExternalId, 'stable-recovery-id');
      expect(phases, ['uploading']);
      expect(savedFit, Uint8List.fromList(const [1, 2, 3]));
      expect(deletedRecovery, isTrue);
      expect(
        (jsonDecode(utf8.decode(state)) as Map)[fingerprint]['status'],
        'uploaded',
      );
    } finally {
      messenger.setMockMethodCallHandler(syncChannel, null);
    }
  });
}

Map<String, Object?> _bundle() => const {
  'uuid': _uuid,
  'startMs': 1704067200000,
  'endMs': 1704070800000,
  'durationSeconds': 3600.0,
  'activityType': 13,
  'activityName': '骑车',
  'sourceName': 'Apple Watch',
  'sourceBundleId': 'com.apple.health',
  'totalEnergyKcal': 42.0,
  'totalDistanceMeters': 1234.5,
  'metadata': <String, Object?>{},
  'events': <Object?>[],
  'series': <String, Object?>{},
  'route': <Object?>[],
};
