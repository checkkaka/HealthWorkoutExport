import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/auto_sync_controller.dart';
import 'package:health_workout_export/src/rust/api/simple.dart' as rust;

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
