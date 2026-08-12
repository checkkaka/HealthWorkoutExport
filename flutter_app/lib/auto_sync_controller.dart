import 'dart:convert';
import 'dart:typed_data';

import 'native_channels.dart';
import 'src/rust/api/simple.dart' as rust;
import 'strava_upload_api.dart';
import 'sync_state_store.dart';
import 'workout_export.dart';

typedef AutoSyncFingerprint =
    String Function({
      required String primarySourceId,
      required String primaryActivityId,
      required double startDateUnixSeconds,
      required List<String> supplementSourceIds,
      required String destination,
    });

typedef AutoSyncUpload =
    Future<rust.StravaUploadFfiResponse> Function({
      required String logicalOperationId,
      required Uint8List fit,
      required String externalId,
      required String filename,
      required bool commute,
    });

typedef AutoSyncPersist =
    Future<void> Function({
      required SyncPendingRecord record,
      required Uint8List fit,
    });

typedef AutoSyncMarkUploaded =
    Future<void> Function({
      required String fingerprint,
      required DateTime updatedAt,
      required String? remoteId,
      required bool isDuplicate,
      required double? distanceMeters,
      required double durationSeconds,
    });

typedef AutoSyncMarkFailed =
    Future<void> Function({
      required String fingerprint,
      required DateTime updatedAt,
      required String message,
    });

/// 最小健康首传：不做远端预检、补源合并或覆盖删除；每次仅串行处理给定 UUID。
final class AutoSyncController {
  AutoSyncController({
    HealthKitChannel? healthKit,
    SyncStateStore? stateStore,
    StravaUploadSession? uploadSession,
    HealthFitEncoder? fitEncoder,
    AutoSyncFingerprint? fingerprint,
    AutoSyncUpload? upload,
    AutoSyncPersist? persist,
    AutoSyncMarkUploaded? markUploaded,
    AutoSyncMarkFailed? markFailed,
    bool Function({double? distanceMeters, required double durationSeconds})?
    commute,
  }) : _healthKit = healthKit ?? const HealthKitChannel(),
       _stateStore = stateStore ?? SyncStateStore(),
       _fitEncoder = fitEncoder ?? rust.encodeHealthWorkoutFit,
       _fingerprint = fingerprint ?? rust.syncFingerprint,
       _commute = commute ?? rust.isCommute,
       _uploadSession = uploadSession ?? stravaUploadSession,
       // ignore: prefer_initializing_formals
       _upload = upload,
       // ignore: prefer_initializing_formals
       _persist = persist,
       // ignore: prefer_initializing_formals
       _markUploaded = markUploaded,
       // ignore: prefer_initializing_formals
       _markFailed = markFailed;

  final HealthKitChannel _healthKit;
  final SyncStateStore _stateStore;
  final HealthFitEncoder _fitEncoder;
  final AutoSyncFingerprint _fingerprint;
  final StravaUploadSession _uploadSession;
  final AutoSyncUpload? _upload;
  final AutoSyncPersist? _persist;
  final AutoSyncMarkUploaded? _markUploaded;
  final AutoSyncMarkFailed? _markFailed;
  final bool Function({double? distanceMeters, required double durationSeconds})
  _commute;

  /// 返回逐条结果。调用方可继续处理失败项；当前控制器绝不伪装为远端去重成功。
  Future<List<AutoSyncResult>> sync(List<String> workoutIds) async {
    final results = <AutoSyncResult>[];
    for (final uuid in workoutIds) {
      results.add(await _syncOne(uuid));
    }
    return results;
  }

  Future<AutoSyncResult> _syncOne(String uuid) async {
    String? fingerprint;
    var persisted = false;
    try {
      final bundle = (await _healthKit.fetchWorkoutBundles([uuid])).single;
      final summary = bundle.summary;
      fingerprint = _fingerprint(
        primarySourceId: summary.sourceBundleId ?? 'healthkit',
        primaryActivityId: summary.uuid,
        startDateUnixSeconds: summary.startMs / 1000,
        supplementSourceIds: const [],
        destination: 'strava',
      );
      final fit = await _fitEncoder(
        bundleJson: utf8.encode(jsonEncode(healthWorkoutFitInput(bundle))),
        timezoneOffsetSeconds: DateTime.fromMillisecondsSinceEpoch(
          summary.endMs,
        ).toLocal().timeZoneOffset.inSeconds,
      );
      final pending = SyncPendingRecord(
        fingerprint: fingerprint,
        primarySourceId: summary.sourceBundleId ?? 'healthkit',
        primaryActivityId: summary.uuid,
        updatedAt: DateTime.now(),
        startDate: DateTime.fromMillisecondsSinceEpoch(summary.startMs),
        title: summary.activityName,
        distanceMeters: summary.totalDistanceMeters,
        durationSeconds: summary.durationSeconds,
      );
      await (_persist?.call(record: pending, fit: fit) ??
          _stateStore.savePendingFit(record: pending, fit: fit));
      persisted = true;
      final response = await _uploadFit(
        logicalOperationId: 'sync-$fingerprint',
        fit: fit,
        externalId: fingerprint,
        filename: '${summary.uuid}.fit',
        commute: _commute(
          distanceMeters: summary.totalDistanceMeters,
          durationSeconds: summary.durationSeconds,
        ),
      );
      if (response.status != rust.StravaUploadFfiStatus.completed) {
        throw const AutoSyncUploadException('Strava 上传未完成');
      }
      await (_markUploaded?.call(
            fingerprint: fingerprint,
            updatedAt: DateTime.now(),
            remoteId: response.remoteId,
            isDuplicate: response.isDuplicate,
            distanceMeters: summary.totalDistanceMeters,
            durationSeconds: summary.durationSeconds,
          ) ??
          _stateStore.markUploaded(
            fingerprint: fingerprint,
            updatedAt: DateTime.now(),
            remoteId: response.remoteId,
            isDuplicate: response.isDuplicate,
            distanceMeters: summary.totalDistanceMeters,
            durationSeconds: summary.durationSeconds,
            uploadChannel: SyncUploadChannel.api,
          ));
      return AutoSyncResult(
        workoutId: summary.uuid,
        fingerprint: fingerprint,
        remoteId: response.remoteId,
        isDuplicate: response.isDuplicate,
      );
    } catch (error) {
      if (persisted && fingerprint != null) {
        try {
          await (_markFailed?.call(
                fingerprint: fingerprint,
                updatedAt: DateTime.now(),
                message: _safeFailureMessage(error),
              ) ??
              _stateStore.markFailed(
                fingerprint: fingerprint,
                updatedAt: DateTime.now(),
                message: error.toString(),
              ));
        } catch (_) {
          // 原始错误优先返回；待处理记录与 FIT 仍在，后续恢复流程可再次处理。
        }
      }
      return AutoSyncResult.failed(
        workoutId: uuid,
        fingerprint: fingerprint,
        message: _safeFailureMessage(error),
      );
    }
  }

  static String _safeFailureMessage(Object error) => switch (error) {
    AutoSyncUploadException() => error.message,
    _ => '同步首传失败',
  };

  Future<rust.StravaUploadFfiResponse> _uploadFit({
    required String logicalOperationId,
    required Uint8List fit,
    required String externalId,
    required String filename,
    required bool commute,
  }) =>
      _upload?.call(
        logicalOperationId: logicalOperationId,
        fit: fit,
        externalId: externalId,
        filename: filename,
        commute: commute,
      ) ??
      _uploadSession
          .start(
            logicalOperationId: logicalOperationId,
            fit: fit,
            externalId: externalId,
            filename: filename,
            commute: commute,
          )
          .result;
}

final class AutoSyncResult {
  const AutoSyncResult({
    required this.workoutId,
    required this.fingerprint,
    required this.remoteId,
    required this.isDuplicate,
    this.message,
  });

  const AutoSyncResult.failed({
    required this.workoutId,
    required this.fingerprint,
    required this.message,
  }) : remoteId = null,
       isDuplicate = false;

  final String workoutId;
  final String? fingerprint;
  final String? remoteId;
  final bool isDuplicate;
  final String? message;
  bool get succeeded => message == null;
}

final class AutoSyncUploadException implements Exception {
  const AutoSyncUploadException(this.message);

  final String message;

  @override
  String toString() => message;
}
