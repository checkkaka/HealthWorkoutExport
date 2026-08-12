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

typedef AutoSyncRemoteActivities =
    Future<List<rust.StravaRemoteActivityResult>> Function({
      required DateTime after,
      required DateTime before,
    });

typedef AutoSyncIsLocallyUploaded = Future<bool> Function(String fingerprint);

typedef AutoSyncStableDedupe =
    bool Function({
      required double startASeconds,
      required double distanceAMeters,
      required double startBSeconds,
      required double distanceBMeters,
      double? durationASeconds,
      double? durationBSeconds,
    });

typedef AutoSyncMarkRemoteDuplicate =
    Future<void> Function({
      required SyncPendingRecord record,
      required String remoteId,
    });

/// 最小健康首传：仅跳过已同步和稳定近似的远端活动；不做补源、覆盖或删除。
/// 当前调用入口不支持取消；调用方必须在开始前取得用户确认。
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
    AutoSyncRemoteActivities? remoteActivities,
    AutoSyncMarkRemoteDuplicate? markRemoteDuplicate,
    AutoSyncIsLocallyUploaded? isLocallyUploaded,
    AutoSyncStableDedupe? stableDedupe,
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
       _markFailed = markFailed,
       // ignore: prefer_initializing_formals
       _remoteActivities = remoteActivities,
       // ignore: prefer_initializing_formals
       _markRemoteDuplicate = markRemoteDuplicate,
       // ignore: prefer_initializing_formals
       _isLocallyUploadedOverride = isLocallyUploaded,
       // ignore: prefer_initializing_formals
       _stableDedupe = stableDedupe ?? rust.stableDedupeMatches;

  final HealthKitChannel _healthKit;
  final SyncStateStore _stateStore;
  final HealthFitEncoder _fitEncoder;
  final AutoSyncFingerprint _fingerprint;
  final StravaUploadSession _uploadSession;
  final AutoSyncUpload? _upload;
  final AutoSyncPersist? _persist;
  final AutoSyncMarkUploaded? _markUploaded;
  final AutoSyncMarkFailed? _markFailed;
  final AutoSyncRemoteActivities? _remoteActivities;
  final AutoSyncMarkRemoteDuplicate? _markRemoteDuplicate;
  final AutoSyncIsLocallyUploaded? _isLocallyUploadedOverride;
  final AutoSyncStableDedupe _stableDedupe;
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
      if (await _isLocallyUploaded(fingerprint)) {
        return AutoSyncResult(
          workoutId: summary.uuid,
          fingerprint: fingerprint,
          remoteId: null,
          isDuplicate: true,
          message: '本地已有同指纹同步记录，未重复上传',
        );
      }
      final remote = await _stableRemoteMatch(summary, fingerprint);
      if (remote != null) {
        final pending = _pendingRecord(summary, fingerprint);
        await _markRemoteAsDuplicate(pending, remote.id);
        return AutoSyncResult(
          workoutId: summary.uuid,
          fingerprint: fingerprint,
          remoteId: remote.id,
          isDuplicate: true,
          message: 'Strava 已有稳定近似活动，未重复上传',
        );
      }
      final fit = await _fitEncoder(
        bundleJson: utf8.encode(jsonEncode(healthWorkoutFitInput(bundle))),
        timezoneOffsetSeconds: DateTime.fromMillisecondsSinceEpoch(
          summary.endMs,
        ).toLocal().timeZoneOffset.inSeconds,
      );
      final pending = _pendingRecord(summary, fingerprint);
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

  SyncPendingRecord _pendingRecord(
    HealthWorkoutSummary summary,
    String fingerprint,
  ) => SyncPendingRecord(
    fingerprint: fingerprint,
    primarySourceId: summary.sourceBundleId ?? 'healthkit',
    primaryActivityId: summary.uuid,
    updatedAt: DateTime.now(),
    startDate: DateTime.fromMillisecondsSinceEpoch(summary.startMs),
    title: summary.activityName,
    distanceMeters: summary.totalDistanceMeters,
    durationSeconds: summary.durationSeconds,
  );

  Future<bool> _isLocallyUploaded(String fingerprint) async {
    final override = _isLocallyUploadedOverride;
    if (override != null) return override(fingerprint);
    final record = (await _stateStore.allRecords())[fingerprint];
    return record is Map && record['status'] == 'uploaded';
  }

  Future<void> _markRemoteAsDuplicate(
    SyncPendingRecord record,
    String remoteId,
  ) async {
    final override = _markRemoteDuplicate;
    if (override != null) return override(record: record, remoteId: remoteId);
    await _stateStore.markPending(record);
    await _stateStore.markDeduped(
      fingerprint: record.fingerprint,
      updatedAt: DateTime.now(),
      reason: 'Strava 已有开始、距离和时长近似的活动',
      remoteId: remoteId,
    );
  }

  Future<rust.StravaRemoteActivityResult?> _stableRemoteMatch(
    HealthWorkoutSummary summary,
    String fingerprint,
  ) async {
    final distance = summary.totalDistanceMeters;
    if (distance == null || distance <= 0) return null;
    final start = DateTime.fromMillisecondsSinceEpoch(summary.startMs);
    final end = DateTime.fromMillisecondsSinceEpoch(summary.endMs);
    final activities =
        await (_remoteActivities?.call(
              after: start.subtract(const Duration(days: 1)),
              before: end.add(const Duration(days: 1)),
            ) ??
            _loadRemoteActivities(
              fingerprint: fingerprint,
              after: start.subtract(const Duration(days: 1)),
              before: end.add(const Duration(days: 1)),
            ));
    for (final activity in activities) {
      final remoteDistance = activity.distanceMeters;
      if (remoteDistance != null &&
          _stableDedupe(
            startASeconds: summary.startMs / 1000,
            distanceAMeters: distance,
            startBSeconds: activity.startTimeSeconds,
            distanceBMeters: remoteDistance,
            durationASeconds: summary.durationSeconds,
            durationBSeconds:
                activity.endTimeSeconds - activity.startTimeSeconds,
          )) {
        return activity;
      }
    }
    return null;
  }

  Future<List<rust.StravaRemoteActivityResult>> _loadRemoteActivities({
    required String fingerprint,
    required DateTime after,
    required DateTime before,
  }) async {
    final reservation = rust.stravaReserveRemoteRead(
      operationId: 'sync-preflight-$fingerprint',
    );
    try {
      return await rust.stravaListRemoteActivities(
        operationHandle: reservation.handle,
        accessToken: await _uploadSession.accessToken(),
        afterSeconds: after.millisecondsSinceEpoch ~/ 1000,
        beforeSeconds: before.millisecondsSinceEpoch ~/ 1000,
      );
    } finally {
      rust.stravaReleaseRemoteRead(operationHandle: reservation.handle);
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
  }) : failed = false;

  const AutoSyncResult.failed({
    required this.workoutId,
    required this.fingerprint,
    required this.message,
  }) : remoteId = null,
       isDuplicate = false,
       failed = true;

  final String workoutId;
  final String? fingerprint;
  final String? remoteId;
  final bool isDuplicate;
  final String? message;
  final bool failed;
  bool get succeeded => !failed;
}

final class AutoSyncUploadException implements Exception {
  const AutoSyncUploadException(this.message);

  final String message;

  @override
  String toString() => message;
}
