import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/auto_sync_controller.dart';
import 'package:health_workout_export/src/rust/api/simple.dart' as rust;
import 'package:health_workout_export/sync_state_store.dart';
import 'package:health_workout_export/workout_source.dart';
import 'package:health_workout_export/sync_preview_models.dart';

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
    inspectFit: ({required data}) async =>
        '{"summary":{},"issues":[],"track":[],"series":{}}',
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
          description,
          name,
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
    remoteMatchIndex:
        ({
          required startTimeSeconds,
          required endTimeSeconds,
          distanceMeters,
          required candidates,
        }) => candidates.isEmpty ? null : 0,
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
          sportType: 'Ride',
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

  for (final cancelDuringInspection in [false, true]) {
    test(
      'legacy Run recovery keeps bytes/id and suppresses commute; cancel=$cancelDuringInspection',
      () async {
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
              'commute': true,
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
                  (call.arguments as Map<Object?, Object?>)['bytes']!
                      as Uint8List;
              return null;
            case 'readSyncedFit':
              throw PlatformException(code: 'sync_file_missing');
            case 'writeSyncedFit':
              savedFit =
                  (call.arguments as Map<Object?, Object?>)['bytes']!
                      as Uint8List;
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
                  records[update['fingerprint'] as String]
                      as Map<String, dynamic>;
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
          if (command['operation'] == 'markUploading') {
            value['phase'] = 'uploading';
          }
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
          late AutoSyncController recoveryController;
          recoveryController = AutoSyncController(
            inspectFit: ({required data}) async {
              if (cancelDuringInspection) {
                recoveryController.cancelActiveOperations();
              }
              return '{"allSessionsRunning":true,"summary":{},"issues":[],"track":[],"series":{}}';
            },
            stateStore: store,
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
                  uploadedExternalId = externalId;
                  expect(logicalOperationId, 'recovery-$fingerprint');
                  expect(filename, 'recovery.fit');
                  expect(
                    commute,
                    false,
                    reason:
                        'legacy Run FIT must stay non-commute through upload and metadata finalization',
                  );
                  expect(fit, Uint8List.fromList(const [1, 2, 3]));
                  return const rust.StravaUploadFfiResponse(
                    status: rust.StravaUploadFfiStatus.completed,
                    remoteId: '42',
                    isDuplicate: false,
                  );
                },
          );
          final result = await recoveryController.resumeRecovery(fingerprint);
          if (cancelDuringInspection) {
            expect(result.cancelled, true);
            expect(uploadedExternalId, isNull);
            expect(deletedRecovery, false);
            expect(savedFit, Uint8List.fromList(const [1, 2, 3]));
            return;
          }
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
      },
    );
  }

  WorkoutActivity activity(
    String id, {
    WorkoutSourceId sourceId = WorkoutSourceId.healthkit,
  }) => WorkoutActivity(
    id: id,
    sourceId: sourceId,
    sportType: 'Ride',
    title: id,
    start: DateTime.fromMillisecondsSinceEpoch(1704067200000),
    end: DateTime.fromMillisecondsSinceEpoch(1704070800000),
    durationSeconds: 3600,
    distanceMeters: 1234.5,
  );

  AutoSyncController batchController({
    required List<String> order,
    void Function(String stage)? onStage,
    List<rust.StravaRemoteActivityResult> remotes = const [],
  }) => AutoSyncController(
    inspectFit: ({required data}) async =>
        '{"summary":{},"issues":[],"track":[],"series":{}}',
    fingerprint:
        ({
          required primarySourceId,
          required primaryActivityId,
          required startDateUnixSeconds,
          required supplementSourceIds,
          required destination,
        }) => fingerprint,
    isLocallyUploaded: (_) async {
      onStage?.call('local');
      return false;
    },
    remoteActivities: ({required after, required before}) async {
      order.add('remote');
      onStage?.call('remote');
      return remotes;
    },
    remoteMatchIndex:
        ({
          required startTimeSeconds,
          required endTimeSeconds,
          distanceMeters,
          required candidates,
        }) => candidates.isEmpty ? null : 0,
    stableDedupe:
        ({
          required startASeconds,
          required distanceAMeters,
          required startBSeconds,
          required distanceBMeters,
          durationASeconds,
          durationBSeconds,
        }) => true,
    markRemoteDuplicate: ({required record, required remoteId}) async {
      order.add('duplicate-${record.primaryActivityId}');
    },
    prepareFit:
        ({
          required primary,
          required supplements,
          required gcjEnabled,
          virtualPower,
        }) async {
          order.add('prepare');
          onStage?.call('prepare');
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
      order.add('persist');
      onStage?.call('persist');
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
          order.add('upload');
          onStage?.call('upload');
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
        }) async {
          order.add('uploaded');
        },
    markFailed:
        ({required fingerprint, required updatedAt, required message}) async {
          order.add('failed');
        },
    commute: ({distanceMeters, required durationSeconds}) => false,
  );

  for (final stage in ['local', 'remote', 'prepare', 'persist']) {
    test('在 $stage 阶段停止后不会启动上传或记作失败', () async {
      final order = <String>[];
      var stopped = false;
      final value = activity('one');
      final progress = <AutoSyncProgress>[];
      final results =
          await batchController(
            order: order,
            onStage: (value) {
              if (value == stage) stopped = true;
            },
          ).syncBatch(
            primary: _FakeSource(WorkoutSourceId.healthkit, [
              value,
            ], Uint8List.fromList([1])),
            supplements: const [],
            activities: [value],
            cancelled: () => stopped,
            onProgress: progress.add,
          );
      expect(results, isEmpty);
      expect(order, isNot(contains('upload')));
      expect(order, isNot(contains('failed')));
      expect(progress.last.processed, 0);
      expect(progress.last.failed, 0);
      expect(progress.last.message, '已停止');
    });
  }

  test('上传返回成功时即使收到停止也保留成功状态', () async {
    final order = <String>[];
    var stopped = false;
    final value = activity('one');
    final results =
        await batchController(
          order: order,
          onStage: (stage) {
            if (stage == 'upload') stopped = true;
          },
        ).syncBatch(
          primary: _FakeSource(WorkoutSourceId.healthkit, [
            value,
          ], Uint8List.fromList([1])),
          supplements: const [],
          activities: [value],
          cancelled: () => stopped,
        );
    expect(results.single.succeeded, isTrue);
    expect(order.last, 'uploaded');
  });

  test('主源与选择活动不一致时在任何读取或上传之前拒绝', () async {
    final order = <String>[];
    await expectLater(
      batchController(order: order).syncBatch(
        primary: _FakeSource(
          WorkoutSourceId.onelap,
          [],
          Uint8List.fromList([1]),
        ),
        supplements: const [],
        activities: [activity('one')],
      ),
      throwsA(isA<AutoSyncUploadException>()),
    );
    expect(order, isEmpty);
  });

  test('覆盖决定没有删除与恢复流程时拒绝，绝不伪装为第二次上传', () async {
    final order = <String>[];
    final value = activity('one');
    final results =
        await batchController(
          order: order,
          remotes: const [
            rust.StravaRemoteActivityResult(
              sportType: 'Ride',
              id: '42',
              startTimeSeconds: 1704067200,
              endTimeSeconds: 1704070800,
              distanceMeters: 1234.5,
            ),
          ],
        ).syncBatch(
          primary: _FakeSource(WorkoutSourceId.healthkit, [
            value,
          ], Uint8List.fromList([1])),
          supplements: const [],
          activities: [value],
          onDuplicate:
              ({required title, required remoteId, required reason}) async =>
                  DuplicateDecision.overwrite,
        );
    expect(results.single.failed, isTrue);
    expect(results.single.message, contains('网页登录'));
    expect(order, ['remote']);
  });

  test('整批跳过对每条活动持久化远端关联', () async {
    final order = <String>[];
    final values = [activity('one'), activity('two')];
    var prompts = 0;
    final results =
        await batchController(
          order: order,
          remotes: const [
            rust.StravaRemoteActivityResult(
              sportType: 'Ride',
              id: '42',
              startTimeSeconds: 1704067200,
              endTimeSeconds: 1704070800,
              distanceMeters: 1234.5,
            ),
          ],
        ).syncBatch(
          primary: _FakeSource(
            WorkoutSourceId.healthkit,
            values,
            Uint8List.fromList([1]),
          ),
          supplements: const [],
          activities: values,
          onDuplicate:
              ({required title, required remoteId, required reason}) async {
                prompts++;
                return DuplicateDecision.skipAll;
              },
        );
    expect(results, hasLength(2));
    expect(prompts, 1);
    expect(order, ['remote', 'duplicate-one', 'remote', 'duplicate-two']);
  });

  test('网页模式不借用 API 凭证做预检', () async {
    final order = <String>[];
    final value = activity('one');
    final results = await batchController(order: order).syncBatch(
      primary: _FakeSource(WorkoutSourceId.healthkit, [
        value,
      ], Uint8List.fromList([1])),
      supplements: const [],
      activities: [value],
      performRemotePreflight: false,
      uploadChannel: SyncUploadChannel.web,
    );
    expect(results.single.succeeded, isTrue);
    expect(order, ['prepare', 'persist', 'upload', 'uploaded']);
  });

  test('批次同步会合并补源、允许单条补源失败，并按取消停止后续条目', () async {
    final order = <String>[];
    WorkoutActivity activity(String id) => WorkoutActivity(
      id: id,
      sourceId: WorkoutSourceId.healthkit,
      sportType: 'Ride',
      title: id,
      start: DateTime.fromMillisecondsSinceEpoch(1704067200000),
      end: DateTime.fromMillisecondsSinceEpoch(1704070800000),
      durationSeconds: 3600,
      distanceMeters: 1234.5,
    );
    final primary = _FakeSource(WorkoutSourceId.healthkit, [
      activity('one'),
      activity('two'),
    ], Uint8List.fromList(const [1]));
    final supplement = _FakeSource(
      WorkoutSourceId.xingzhe,
      [activity('one')],
      Uint8List.fromList(const [2]),
      failFetchIds: {'one'},
    );
    final results =
        await AutoSyncController(
          inspectFit: ({required data}) async =>
              '{"summary":{},"issues":[],"track":[],"series":{}}',
          fingerprint:
              ({
                required primarySourceId,
                required primaryActivityId,
                required startDateUnixSeconds,
                required supplementSourceIds,
                required destination,
              }) => fingerprint,
          persist: ({required record, required fit}) async {
            order.add('pending-${record.primaryActivityId}');
            expect(fit, Uint8List.fromList(const [9]));
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
                order.add('upload-$filename');
                return const rust.StravaUploadFfiResponse(
                  status: rust.StravaUploadFfiStatus.completed,
                  remoteId: '7',
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
              }) async {
                order.add('uploaded');
              },
          isLocallyUploaded: (_) async => false,
          remoteActivities: ({required after, required before}) async =>
              const [],
          commute: ({distanceMeters, required durationSeconds}) => false,
          prepareFit:
              ({
                required primary,
                required supplements,
                required gcjEnabled,
                virtualPower,
              }) async {
                expect(supplements, isEmpty, reason: '补源失败不得拖垮主活动');
                return rust.PreparedFitResult(
                  data: Uint8List.fromList(const [9]),
                  repairedSpeedCount: 0,
                  rewrittenCoordinateCount: 0,
                  virtualPowerFilledCount: 0,
                  powerSourceVirtual: false,
                  averageCoordinateDisplacementMeters: 0,
                  supplementReportsJson: '[]',
                );
              },
          matchIndex: ({required primary, required candidates}) =>
              candidates.isEmpty ? null : 0,
        ).syncBatch(
          primary: primary,
          supplements: [supplement],
          activities: [activity('one'), activity('two')],
          cancelled: () => order.contains('uploaded'),
          onPreview: (_) async =>
              const SyncPreviewDecision(SyncPreviewAction.forceUpload),
        );

    expect(results, hasLength(1));
    expect(results.single.succeeded, isTrue);
    expect(order, ['pending-one', 'upload-$fingerprint.fit', 'uploaded']);
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

final class _FakeSource implements WorkoutSource {
  _FakeSource(
    this.id,
    this.activities,
    this.fit, {
    this.failFetchIds = const {},
  });

  @override
  final WorkoutSourceId id;
  final List<WorkoutActivity> activities;
  final Uint8List fit;
  final Set<String> failFetchIds;

  @override
  Future<bool> isAuthenticated() async => true;

  @override
  Future<void> logout() async {}

  @override
  Future<List<WorkoutActivity>> listActivities(interval) async => activities;

  @override
  Future<Uint8List> fetchFit(WorkoutActivity activity) async {
    if (failFetchIds.contains(activity.id)) {
      throw StateError('supplement missing');
    }
    return fit;
  }
}
