import 'dart:convert';

import 'package:flutter/services.dart';

import 'date_range.dart';
import 'native_channels.dart';
import 'src/rust/api/simple.dart' as rust;
import 'strava_upload_api.dart';
import 'sync_state_store.dart';
import 'sync_recovery_runner.dart';
import 'sync_history_logic.dart';
import 'sync_preview_models.dart';
import 'recovery_batch_checkpoint.dart';
export 'sync_history_logic.dart' show isAnomalousStravaSpeed;
import 'workout_export.dart';
import 'workout_source.dart';

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
      String? description,
      String? name,
    });

typedef AutoSyncPersist =
    Future<void> Function({
      required SyncPendingRecord record,
      required Uint8List fit,
    });

typedef AutoSyncHealthImport =
    Future<AutoSyncResult> Function({
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

typedef AutoSyncRemoteSpeed =
    Future<rust.StravaActivitySpeedResult?> Function(String remoteId);

typedef AutoSyncIsLocallyUploaded = Future<bool> Function(String fingerprint);

typedef AutoSyncRemoteMatchIndex =
    int? Function({
      required double startTimeSeconds,
      required double endTimeSeconds,
      double? distanceMeters,
      required List<rust.StravaRemoteActivityResult> candidates,
    });

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

enum DuplicateDecision { skip, skipAll, overwrite, overwriteAll }

final class AutoSyncProgress {
  const AutoSyncProgress({
    required this.total,
    required this.processed,
    required this.uploaded,
    required this.deduped,
    required this.failed,
    this.message = '',
  });

  final int total;
  final int processed;
  final int uploaded;
  final int deduped;
  final int failed;
  final String message;
}

typedef FitPreparer =
    Future<rust.PreparedFitResult> Function({
      required List<int> primary,
      required List<Uint8List> supplements,
      required bool gcjEnabled,
      rust.VirtualPowerFillInput? virtualPower,
    });

typedef AutoSyncMatchIndex =
    int? Function({
      required rust.ActivityIntervalInput primary,
      required List<rust.ActivityIntervalInput> candidates,
    });

typedef DuplicatePrompt =
    Future<DuplicateDecision> Function({
      required String title,
      required String remoteId,
      required String reason,
    });

/// 健康首传、补源合并与恢复重传；每次副作用前检查取消。
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
    AutoSyncRemoteSpeed? remoteSpeed,
    AutoSyncRemoteMatchIndex? remoteMatchIndex,
    bool Function({double? distanceMeters, required double durationSeconds})?
    commute,
    FitPreparer? prepareFit,
    Future<String> Function({required List<int> data})? inspectFit,
    AutoSyncMatchIndex? matchIndex,
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
       _stableDedupe = stableDedupe ?? rust.stableDedupeMatches,
       // ignore: prefer_initializing_formals
       _prepareFit = prepareFit,
       _inspectFit = inspectFit ?? rust.inspectFitPreview,
       _matchIndex = matchIndex ?? rust.bestActivityMatchIndex,
       // ignore: prefer_initializing_formals
       _remoteSpeed = remoteSpeed,
       _remoteMatchIndex =
           remoteMatchIndex ?? rust.stravaBestRemoteActivityMatchIndex;

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
  final FitPreparer? _prepareFit;
  final Future<String> Function({required List<int> data}) _inspectFit;
  final AutoSyncMatchIndex _matchIndex;
  final AutoSyncRemoteSpeed? _remoteSpeed;
  final AutoSyncRemoteMatchIndex _remoteMatchIndex;
  final bool Function({double? distanceMeters, required double durationSeconds})
  _commute;

  StravaUploadTask? _activeUploadTask;
  String? _activeRemoteHandle;
  String? _activePreparationHandle;
  var _uploadCancellationGeneration = 0;

  /// 中止可取消的原生 Rust 请求；不可取消的读取返回后也不会开始下一步。
  void cancelActiveOperations() {
    _uploadCancellationGeneration++;
    _activeUploadTask?.cancel();
    final handle = _activeRemoteHandle;
    if (handle != null) rust.stravaCancelRemoteRead(operationHandle: handle);
    final preparation = _activePreparationHandle;
    if (preparation != null) {
      rust.stravaCancelRemoteRead(operationHandle: preparation);
    }
  }

  Future<rust.PreparedFitResult> _prepareWithCancellation({
    required List<int> primary,
    required List<Uint8List> supplements,
    required bool gcjEnabled,
    rust.VirtualPowerFillInput? virtualPower,
  }) async {
    final reservation = rust.stravaReserveRemoteRead(
      operationId: 'prepare-fit-${DateTime.now().microsecondsSinceEpoch}',
    );
    _activePreparationHandle = reservation.handle;
    try {
      return await rust.prepareFitForUploadCancellable(
        operationHandle: reservation.handle,
        primary: primary,
        supplements: supplements,
        gcjEnabled: gcjEnabled,
        virtualPower: virtualPower,
      );
    } finally {
      _activePreparationHandle = null;
      rust.stravaReleaseRemoteRead(operationHandle: reservation.handle);
    }
  }

  static void _checkCancelled(bool Function()? cancelled) {
    if (cancelled?.call() == true) throw const _AutoSyncCancelled();
  }

  /// 返回逐条结果。调用方可继续处理失败项；当前控制器绝不伪装为远端去重成功。
  Future<List<AutoSyncResult>> sync(List<String> workoutIds) async {
    final results = <AutoSyncResult>[];
    for (final uuid in workoutIds) {
      results.add(await _syncOne(uuid));
    }
    return results;
  }

  /// 主源 + 可选补源的完整批次。取消后不再开始新的上传。
  Future<List<AutoSyncResult>> syncBatch({
    required WorkoutSource primary,
    required List<WorkoutSource> supplements,
    required List<WorkoutActivity> activities,
    bool gcjEnabled = false,
    rust.VirtualPowerFillInput? virtualPower,
    DuplicatePrompt? onDuplicate,
    bool Function()? cancelled,
    void Function(AutoSyncProgress progress)? onProgress,
    AutoSyncUpload? upload,
    SyncUploadChannel uploadChannel = SyncUploadChannel.api,
    bool performRemotePreflight = true,
    bool skipLocalHistory = true,
    AutoSyncRemoteActivities? remoteActivities,
    Future<void> Function(String remoteId)? deleteRemote,
    Future<void> Function(AutoSyncResult result)? onResult,
    SyncPreviewPolicy previewPolicy = SyncPreviewPolicy.issuesOnly,
    SyncPreviewChooser? onPreview,
    String? customTitle,
    bool uploadToStrava = true,
    AutoSyncHealthImport? healthImport,
  }) async {
    if (!uploadToStrava && healthImport == null) {
      throw const AutoSyncUploadException('没有可执行的同步目标');
    }
    if (activities.any((activity) => activity.sourceId != primary.id)) {
      throw const AutoSyncUploadException('已选活动与主数据源不一致');
    }
    final results = <AutoSyncResult>[];
    var uploaded = 0;
    var deduped = 0;
    var failed = 0;
    var skipRemaining = false;
    var overwriteRemaining = false;
    final batchAt = DateTime.now();
    final supplementCache = <WorkoutSourceId, List<WorkoutActivity>>{};
    for (final supplement in supplements) {
      if (activities.isEmpty || cancelled?.call() == true) break;
      final start = activities
          .map((activity) => activity.start)
          .reduce((a, b) => a.isBefore(b) ? a : b)
          .subtract(const Duration(hours: 2));
      final end = activities
          .map((activity) => activity.end)
          .reduce((a, b) => a.isAfter(b) ? a : b)
          .add(const Duration(hours: 2));
      try {
        supplementCache[supplement.id] = await supplement.listActivities(
          DateInterval(start, end),
        );
      } catch (_) {
        supplementCache[supplement.id] = const [];
      }
    }
    for (var index = 0; index < activities.length; index++) {
      if (cancelled?.call() == true) break;
      final activity = activities[index];
      onProgress?.call(
        AutoSyncProgress(
          total: activities.length,
          processed: index,
          uploaded: uploaded,
          deduped: deduped,
          failed: failed,
          message: activity.title,
        ),
      );
      final result = await _syncActivity(
        primary: primary,
        supplements: supplements,
        supplementCache: supplementCache,
        activity: activity,
        gcjEnabled: gcjEnabled,
        virtualPower: virtualPower,
        skipDuplicate: skipRemaining,
        overwriteDuplicate: overwriteRemaining,
        onDuplicate: onDuplicate,
        upload: upload,
        uploadChannel: uploadChannel,
        performRemotePreflight: performRemotePreflight,
        cancelled: cancelled,
        batchAt: batchAt,
        skipLocalHistory: skipLocalHistory,
        remoteActivities: remoteActivities,
        deleteRemote: deleteRemote,
        previewPolicy: previewPolicy,
        onPreview: onPreview,
        customTitle: customTitle,
        uploadToStrava: uploadToStrava,
        healthImport: healthImport,
      );
      if (result.cancelled) break;
      results.add(result);
      await onResult?.call(result);
      if (result.failed) {
        failed += 1;
      } else if (result.isDuplicate) {
        deduped += 1;
      } else {
        uploaded += 1;
      }
      if (result.message == 'skip-all') skipRemaining = true;
      if (result.message == 'overwrite-all') overwriteRemaining = true;
    }
    onProgress?.call(
      AutoSyncProgress(
        total: activities.length,
        processed: results.length,
        uploaded: uploaded,
        deduped: deduped,
        failed: failed,
        message: cancelled?.call() == true ? '已停止' : '完成',
      ),
    );
    return results;
  }

  Future<AutoSyncResult> _syncActivity({
    required WorkoutSource primary,
    required List<WorkoutSource> supplements,
    required Map<WorkoutSourceId, List<WorkoutActivity>> supplementCache,
    required WorkoutActivity activity,
    required bool gcjEnabled,
    required rust.VirtualPowerFillInput? virtualPower,
    required bool skipDuplicate,
    required bool overwriteDuplicate,
    required DuplicatePrompt? onDuplicate,
    AutoSyncUpload? upload,
    required SyncUploadChannel uploadChannel,
    required bool performRemotePreflight,
    required bool Function()? cancelled,
    required DateTime batchAt,
    required bool skipLocalHistory,
    AutoSyncRemoteActivities? remoteActivities,
    Future<void> Function(String remoteId)? deleteRemote,
    required SyncPreviewPolicy previewPolicy,
    SyncPreviewChooser? onPreview,
    String? customTitle,
    required bool uploadToStrava,
    AutoSyncHealthImport? healthImport,
  }) async {
    String? fingerprint;
    var persisted = false;
    final effectiveGcjEnabled = gcjEnabled && !activity.hasWgs84Coordinates;
    final isCommute =
        activity.isCycling &&
        _commute(
          distanceMeters: activity.distanceMeters,
          durationSeconds: activity.durationSeconds,
        );
    try {
      _checkCancelled(cancelled);
      final supplementIds = supplements
          .map((source) => source.id.value)
          .toList();
      fingerprint = _fingerprint(
        primarySourceId: primary.id.value,
        primaryActivityId: activity.id,
        startDateUnixSeconds: activity.start.millisecondsSinceEpoch / 1000,
        supplementSourceIds: supplementIds,
        destination: 'strava',
      );
      if (!uploadToStrava) {
        final record = await _stateStore.recordFor(fingerprint);
        if (record?['appleHealthUUID'] != null ||
            record?['appleHealthSkipped'] == true) {
          return AutoSyncResult(
            workoutId: activity.id,
            fingerprint: fingerprint,
            remoteId: null,
            isDuplicate: true,
            message: '健康已处理，未重复写入',
          );
        }
        try {
          final fit = await _stateStore.readFitForHealth(fingerprint);
          _checkCancelled(cancelled);
          return await healthImport!(
            record: SyncPendingRecord(
              fingerprint: fingerprint,
              primarySourceId: primary.id.value,
              primaryActivityId: activity.id,
              sportType: activity.effectiveSportType,
              updatedAt: DateTime.now(),
              startDate: activity.start,
              title: activity.title,
              supplementSourceIds: supplementIds,
              distanceMeters: activity.distanceMeters,
              durationSeconds: activity.durationSeconds,
            ),
            fit: fit,
          );
        } on PlatformException catch (error) {
          if (error.code != 'sync_file_missing') rethrow;
        }
      }
      if (uploadToStrava && _persist == null) {
        try {
          await _stateStore.readRecovery(fingerprint);
          return await resumeRecovery(
            fingerprint,
            uploadOverride: upload,
            deleteRemote: deleteRemote,
            cancelled: cancelled,
          );
        } on PlatformException catch (error) {
          if (error.code != 'sync_file_missing') rethrow;
        }
      }
      final local = uploadToStrava && skipLocalHistory
          ? await _localDuplicate(activity, fingerprint)
          : (matches: false, remoteId: null);
      _checkCancelled(cancelled);
      if (local.matches) {
        if (local.remoteId != null) {
          await _markRemoteAsDuplicate(
            SyncPendingRecord(
              fingerprint: fingerprint,
              primarySourceId: primary.id.value,
              primaryActivityId: activity.id,
              sportType: activity.effectiveSportType,
              updatedAt: DateTime.now(),
              startDate: activity.start,
              title: activity.title,
              supplementSourceIds: supplementIds,
              distanceMeters: activity.distanceMeters,
              durationSeconds: activity.durationSeconds,
              batchAt: batchAt,
              uploadChannel: uploadChannel,
            ),
            local.remoteId!,
          );
        }
        return AutoSyncResult(
          workoutId: activity.id,
          fingerprint: fingerprint,
          remoteId: local.remoteId,
          isDuplicate: true,
          message: '本地已有同步记录，未重复上传',
        );
      }
      var overwriteRemainingAfter = overwriteDuplicate;
      final remote = uploadToStrava && performRemotePreflight
          ? await _stableRemoteMatchActivity(
              activity,
              fingerprint,
              remoteActivities,
            )
          : null;
      _checkCancelled(cancelled);
      if (remote != null && !overwriteDuplicate) {
        if (skipDuplicate) {
          await _markRemoteAsDuplicate(
            SyncPendingRecord(
              fingerprint: fingerprint,
              primarySourceId: primary.id.value,
              primaryActivityId: activity.id,
              sportType: activity.effectiveSportType,
              updatedAt: DateTime.now(),
              startDate: activity.start,
              title: activity.title,
              batchAt: batchAt,
              uploadChannel: uploadChannel,
              supplementSourceIds: supplementIds,
              distanceMeters: activity.distanceMeters,
              durationSeconds: activity.durationSeconds,
            ),
            remote.id,
          );
          return AutoSyncResult(
            workoutId: activity.id,
            fingerprint: fingerprint,
            remoteId: remote.id,
            isDuplicate: true,
            message: 'skip-all',
          );
        }
        final decision =
            await onDuplicate?.call(
              title: activity.title,
              remoteId: remote.id,
              reason: 'Strava 已有稳定近似活动',
            ) ??
            DuplicateDecision.skip;
        _checkCancelled(cancelled);
        if (decision == DuplicateDecision.skip ||
            decision == DuplicateDecision.skipAll) {
          await _markRemoteAsDuplicate(
            SyncPendingRecord(
              fingerprint: fingerprint,
              primarySourceId: primary.id.value,
              primaryActivityId: activity.id,
              sportType: activity.effectiveSportType,
              updatedAt: DateTime.now(),
              startDate: activity.start,
              title: activity.title,
              batchAt: batchAt,
              uploadChannel: uploadChannel,
              supplementSourceIds: supplementIds,
              distanceMeters: activity.distanceMeters,
              durationSeconds: activity.durationSeconds,
            ),
            remote.id,
          );
          return AutoSyncResult(
            workoutId: activity.id,
            fingerprint: fingerprint,
            remoteId: remote.id,
            isDuplicate: true,
            message: decision == DuplicateDecision.skipAll
                ? 'skip-all'
                : 'Strava 已有稳定近似活动，未重复上传',
          );
        }
        if (decision == DuplicateDecision.overwriteAll) {
          overwriteRemainingAfter = true;
        }
      }
      if (remote != null && deleteRemote == null) {
        throw const AutoSyncUploadException('覆盖上传需要 Strava 网页登录以删除原活动');
      }
      if (remote != null && _persist != null) {
        throw const AutoSyncUploadException('覆盖需要持久化恢复存储，不能绕过事务');
      }
      _checkCancelled(cancelled);
      final primaryFit = await primary.fetchFit(activity);
      _checkCancelled(cancelled);
      final original = FitPreviewInspection.decode(
        await _inspectFit(data: primaryFit),
      );
      _checkCancelled(cancelled);
      PreviewCandidate candidate(WorkoutActivity value) => PreviewCandidate(
        id: value.id,
        title: value.title,
        start: value.start,
        end: value.end,
        durationSeconds: value.durationSeconds,
      );
      final ranked = <WorkoutSourceId, List<PreviewCandidate>>{};
      final selected = <String, String>{};
      for (final source in supplements) {
        final candidates =
            (supplementCache[source.id] ?? const <WorkoutActivity>[])
                .where(
                  (candidate) => compatibleWorkoutSports(
                    activity.effectiveSportType,
                    candidate.effectiveSportType,
                  ),
                )
                .toList();
        ranked[source.id] = rankPreviewCandidates(
          candidate(activity),
          candidates.map(candidate).toList(),
        );
        final index = _matchIndex(
          primary: activity.interval,
          candidates: [for (final item in candidates) item.interval],
        );
        if (index != null &&
            ranked[source.id]!.any((item) => item.id == candidates[index].id)) {
          selected[source.id.value] = candidates[index].id;
        }
      }
      final fitCache = <String, Uint8List>{};
      var manuallyResolved = false;
      var forcePreview = false;
      late rust.PreparedFitResult prepared;
      while (true) {
        final supplementFits = <Uint8List>[];
        final successfulSupplementNames = <String>[];
        final issues = <FitQualityIssue>[];
        for (final source in supplements) {
          _checkCancelled(cancelled);
          final id = selected[source.id.value];
          if (id == null || id.isEmpty) continue;
          final selectedActivity =
              (supplementCache[source.id] ?? const <WorkoutActivity>[])
                  .where((item) => item.id == id)
                  .firstOrNull;
          if (selectedActivity == null) continue;
          try {
            final key = '${source.id.value}:$id';
            supplementFits.add(
              fitCache[key] ??= await source.fetchFit(selectedActivity),
            );
            successfulSupplementNames.add(source.id.title);
          } catch (_) {
            issues.add(
              FitQualityIssue(
                'supplement-fetch-${source.id.value}',
                'warning',
                '补源读取失败',
                '${source.id.title}未参与本次合并',
              ),
            );
          }
        }
        _checkCancelled(cancelled);
        if (original.issues.any((i) => i.severity == 'error')) {
          prepared = rust.PreparedFitResult(
            data: primaryFit,
            repairedSpeedCount: 0,
            rewrittenCoordinateCount: 0,
            virtualPowerFilledCount: 0,
            powerSourceVirtual: false,
            averageCoordinateDisplacementMeters: 0,
            supplementReportsJson: '[]',
          );
        } else {
          prepared = await (_prepareFit ?? _prepareWithCancellation)(
            primary: primaryFit,
            supplements: supplementFits,
            gcjEnabled: effectiveGcjEnabled,
            virtualPower: activity.isCycling ? virtualPower : null,
          );
        }
        _checkCancelled(cancelled);
        final finalFit = FitPreviewInspection.decode(
          await _inspectFit(data: prepared.data),
        );
        _checkCancelled(cancelled);
        issues.addAll(original.issues.where((i) => i.severity == 'error'));
        issues.addAll(finalFit.issues);
        issues.addAll(
          processingQualityIssues(
            original: original,
            finalFit: finalFit,
            gcjEnabled: effectiveGcjEnabled,
            repairedSpeedCount: prepared.repairedSpeedCount,
            rewrittenCoordinateCount: prepared.rewrittenCoordinateCount,
            virtualPowerCount: prepared.virtualPowerFilledCount,
            averageCoordinateDisplacementMeters:
                prepared.averageCoordinateDisplacementMeters,
          ),
        );
        final reportNames = original.issues.any((i) => i.severity == 'error')
            ? const <String>[]
            : successfulSupplementNames;
        final reports = parseSupplementReports(
          prepared.supplementReportsJson,
          expectedCount: reportNames.length,
        );
        issues.addAll(supplementQualityIssues(reports, reportNames));
        final fieldSources = previewFieldSources(
          primaryName: primary.id.title,
          original: original,
          finalFit: finalFit,
          reports: reports,
          supplementNames: reportNames,
          virtualPower: prepared.powerSourceVirtual,
        );
        final prompt = SyncPreviewPrompt(
          title: activity.title,
          original: original,
          finalFit: finalFit,
          issues: issues,
          fieldSources: fieldSources,
          originalCoordinatesWgs84: activity.hasWgs84Coordinates,
          finalCoordinatesWgs84:
              activity.hasWgs84Coordinates ||
              prepared.rewrittenCoordinateCount > 0,
          groups: [
            for (final source in supplements)
              if ((ranked[source.id] ?? []).isNotEmpty)
                PreviewCandidateGroup(
                  sourceId: source.id.value,
                  sourceTitle: source.id.title,
                  candidates: ranked[source.id]!,
                  selectedId: selected[source.id.value],
                ),
          ],
        );
        final ambiguous =
            !manuallyResolved && ranked.values.any(requiresMatchConfirmation);
        final show =
            forcePreview ||
            previewPolicy == SyncPreviewPolicy.everyActivity ||
            prompt.hasErrors ||
            prompt.hasWarnings ||
            ambiguous;
        if (!show) break;
        forcePreview = false;
        final decision =
            await onPreview?.call(prompt) ??
            const SyncPreviewDecision(SyncPreviewAction.stop);
        _checkCancelled(cancelled);
        switch (decision.action) {
          case SyncPreviewAction.stop:
            throw const _AutoSyncCancelled();
          case SyncPreviewAction.skip:
            return AutoSyncResult(
              workoutId: activity.id,
              fingerprint: fingerprint,
              remoteId: null,
              isDuplicate: true,
              message: '预览后跳过',
            );
          case SyncPreviewAction.rebuild:
            selected.clear();
            for (final group in prompt.groups) {
              final id = decision.selections[group.sourceId];
              if (id != null && group.candidates.any((c) => c.id == id)) {
                selected[group.sourceId] = id;
              }
            }
            manuallyResolved = true;
            forcePreview = true;
            continue;
          case SyncPreviewAction.upload:
            if (prompt.hasErrors || prompt.hasWarnings) continue;
          case SyncPreviewAction.forceUpload:
            if (prompt.hasErrors) continue;
        }
        break;
      }
      final effectiveTitle = customTitle?.trim().isNotEmpty == true
          ? customTitle!.trim()
          : isCommute
          ? '通勤🚲'
          : activity.title;
      if (!uploadToStrava) {
        final record = SyncPendingRecord(
          fingerprint: fingerprint,
          primarySourceId: primary.id.value,
          primaryActivityId: activity.id,
          sportType: activity.effectiveSportType,
          updatedAt: DateTime.now(),
          startDate: activity.start,
          title: activity.title,
          supplementSourceIds: supplementIds,
          distanceMeters: activity.distanceMeters,
          durationSeconds: activity.durationSeconds,
          batchAt: batchAt,
          hasVirtualPower: prepared.powerSourceVirtual,
          coordinatesWgs84:
              activity.hasWgs84Coordinates ||
              prepared.rewrittenCoordinateCount > 0,
        );
        await _stateStore.saveHealthFit(record: record, fit: prepared.data);
        _checkCancelled(cancelled);
        return await healthImport!(record: record, fit: prepared.data);
      }
      if (_persist == null) {
        final recovery = RecoveryUploadData(
          primarySourceId: primary.id.value,
          primaryActivityId: activity.id,
          sportType: activity.effectiveSportType,
          title: effectiveTitle,
          startDate: activity.start,
          supplementSourceIds: supplementIds,
          distanceMeters: activity.distanceMeters,
          durationSeconds: activity.durationSeconds,
          fit: prepared.data,
          message: null,
          filename: '$fingerprint.fit',
          commute: isCommute,
          channel: uploadChannel,
          hasVirtualPower: prepared.powerSourceVirtual,
          activityDescription: prepared.activityDescription,
          batchAt: batchAt,
          coordinatesWgs84:
              activity.hasWgs84Coordinates ||
              prepared.rewrittenCoordinateCount > 0,
          recoveryBatchId: RecoveryBatchCheckpoint.newGenerationId(),
        );
        await _stateStore.prepareRecovery(
          fingerprint: fingerprint,
          recoveryJson: recovery.encode(),
          remoteIdToReplace: remote?.id,
          externalId: remote == null ? fingerprint : null,
        );
        persisted = true;
        final result = await resumeRecovery(
          fingerprint,
          uploadOverride: upload,
          deleteRemote: deleteRemote,
          cancelled: cancelled,
        );
        if (result.succeeded && overwriteRemainingAfter) {
          return AutoSyncResult(
            workoutId: result.workoutId,
            fingerprint: result.fingerprint,
            remoteId: result.remoteId,
            isDuplicate: result.isDuplicate,
            message: 'overwrite-all',
          );
        }
        return result;
      }
      final pending = SyncPendingRecord(
        fingerprint: fingerprint,
        primarySourceId: primary.id.value,
        primaryActivityId: activity.id,
        sportType: activity.effectiveSportType,
        updatedAt: DateTime.now(),
        startDate: activity.start,
        title: effectiveTitle,
        batchAt: batchAt,
        supplementSourceIds: supplementIds,
        distanceMeters: activity.distanceMeters,
        durationSeconds: activity.durationSeconds,
        uploadChannel: uploadChannel,
        hasVirtualPower: prepared.powerSourceVirtual,
        coordinatesWgs84:
            activity.hasWgs84Coordinates ||
            prepared.rewrittenCoordinateCount > 0,
      );
      await _persist(record: pending, fit: prepared.data);
      persisted = true;
      _checkCancelled(cancelled);
      final response = await _uploadFit(
        logicalOperationId: 'sync-$fingerprint',
        cancelled: cancelled,
        fit: prepared.data,
        externalId: fingerprint,
        filename: '$fingerprint.fit',
        description: prepared.activityDescription,
        name: effectiveTitle,
        commute: isCommute,
        upload: upload,
      );
      if (response.status == rust.StravaUploadFfiStatus.cancelled) {
        throw const _AutoSyncCancelled();
      }
      if (response.status != rust.StravaUploadFfiStatus.completed) {
        throw const AutoSyncUploadException('Strava 上传未完成');
      }
      await (_markUploaded?.call(
            fingerprint: fingerprint,
            updatedAt: DateTime.now(),
            remoteId: response.remoteId,
            isDuplicate: response.isDuplicate,
            distanceMeters: activity.distanceMeters,
            durationSeconds: activity.durationSeconds,
          ) ??
          _stateStore.markUploaded(
            fingerprint: fingerprint,
            updatedAt: DateTime.now(),
            remoteId: response.remoteId,
            isDuplicate: response.isDuplicate,
            distanceMeters: activity.distanceMeters,
            durationSeconds: activity.durationSeconds,
            uploadChannel: uploadChannel,
            hasVirtualPower: prepared.powerSourceVirtual,
          ));
      return AutoSyncResult(
        workoutId: activity.id,
        fingerprint: fingerprint,
        remoteId: response.remoteId,
        isDuplicate: response.isDuplicate,
        message: overwriteRemainingAfter ? 'overwrite-all' : null,
      );
    } on _AutoSyncCancelled {
      return AutoSyncResult.cancelled(
        workoutId: activity.id,
        fingerprint: fingerprint,
      );
    } catch (error) {
      if (cancelled?.call() == true) {
        return AutoSyncResult.cancelled(
          workoutId: activity.id,
          fingerprint: fingerprint,
        );
      }
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
                message: _safeFailureMessage(error),
              ));
        } catch (_) {}
      }
      return AutoSyncResult.failed(
        workoutId: activity.id,
        fingerprint: fingerprint,
        message: _safeFailureMessage(error),
      );
    }
  }

  Future<rust.StravaRemoteActivityResult?> _stableRemoteMatchActivity(
    WorkoutActivity activity,
    String fingerprint,
    AutoSyncRemoteActivities? remoteActivities,
  ) async {
    final distance = activity.distanceMeters;
    final remoteList =
        await ((remoteActivities ?? _remoteActivities)?.call(
              after: activity.start.subtract(const Duration(days: 1)),
              before: activity.end.add(const Duration(days: 1)),
            ) ??
            _loadRemoteActivities(
              fingerprint: fingerprint,
              after: activity.start.subtract(const Duration(days: 1)),
              before: activity.end.add(const Duration(days: 1)),
            ));
    final activities = remoteList
        .where(
          (remote) => compatibleWorkoutSports(
            activity.effectiveSportType,
            remote.sportType,
          ),
        )
        .toList();
    if (activities.isEmpty) return null;
    final index = _remoteMatchIndex(
      startTimeSeconds: activity.start.millisecondsSinceEpoch / 1000,
      endTimeSeconds: activity.end.millisecondsSinceEpoch / 1000,
      distanceMeters: distance,
      candidates: activities,
    );
    return index == null ? null : activities[index];
  }

  /// 仅恢复已落盘的最终 FIT。需要删除远端活动的恢复包必须交由网页流程处理。
  Future<AutoSyncResult> resumeRecovery(
    String fingerprint, {
    AutoSyncUpload? uploadOverride,
    Future<void> Function(String remoteId)? deleteRemote,
    bool Function()? cancelled,
    bool replaceExisting = false,
    String? customTitle,
    String? recoveryBatchId,
  }) async {
    String? workoutId;
    String? remoteId;
    var uploadedRecorded = false;
    try {
      final existing = (await _stateStore.allRecords())[fingerprint];
      try {
        await _stateStore.readRecovery(fingerprint);
      } on PlatformException catch (error) {
        if (error.code != 'sync_file_missing') rethrow;
        if (existing is! Map ||
            (existing['status'] != 'pending' &&
                existing['status'] != 'failed' &&
                !(replaceExisting && existing['status'] == 'uploaded'))) {
          throw const AutoSyncRecoveryException('没有可恢复的上传记录');
        }
        if (replaceExisting &&
            !isValidStravaActivityId(existing['remoteId'] as String? ?? '')) {
          throw const AutoSyncRecoveryException('该记录缺少有效远端 ID，请先补全后覆盖');
        }
        final start = existing['startDate'];
        final duration = existing['durationSeconds'];
        final sourceId = existing['primarySourceId'];
        final activityId = existing['primaryActivityId'];
        if (start is! num ||
            duration is! num ||
            sourceId is! String ||
            activityId is! String) {
          throw const AutoSyncRecoveryException('旧记录缺少恢复所需的活动信息');
        }
        final fit = await _stateStore.readSyncedFit(fingerprint);
        final payload = Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'primarySourceId': sourceId,
              'primaryActivityId': activityId,
              'title': existing['title'] ?? activityId,
              'startDate': start,
              'endDate': start + duration,
              'supplementSourceIds':
                  existing['supplementSourceIds'] ?? <String>[],
              'distanceMeters': existing['distanceMeters'],
              'durationSeconds': duration,
              'uploadData': base64Encode(fit),
              'filename': '$fingerprint.fit',
              'sportType': sourceSportType(
                sourceId,
                sportType: existing['sportType'] as String?,
              ),
              'commute':
                  normalizedWorkoutSport(
                        sourceSportType(
                          sourceId,
                          sportType: existing['sportType'] as String?,
                        ),
                      ) ==
                      'Ride' &&
                  _commute(
                    distanceMeters: (existing['distanceMeters'] as num?)
                        ?.toDouble(),
                    durationSeconds: duration.toDouble(),
                  ),
              'uploadChannel': existing['uploadChannel'] ?? 'api',
              'hasVirtualPower': existing['hasVirtualPower'] ?? false,
              'coordinatesWgs84': existing['coordinatesWgs84'],
              'recoveryBatchId':
                  recoveryBatchId ?? RecoveryBatchCheckpoint.newGenerationId(),
              'activityDescription': existing['hasVirtualPower'] == true
                  ? '功率计还在许愿清单里，本场瓦特是风、坡和速度一起算的，看看就好～（出自 HealthWorkoutExport）'
                  : null,
            }),
          ),
        );
        await _stateStore.prepareRecovery(
          fingerprint: fingerprint,
          recoveryJson: payload,
          externalId: replaceExisting ? null : fingerprint,
          remoteIdToReplace:
              replaceExisting &&
                  isValidStravaActivityId(existing['remoteId'] as String? ?? '')
              ? existing['remoteId'] as String
              : null,
        );
      }
      final data = RecoveryUploadData.fromJson(
        await _stateStore.readRecovery(fingerprint),
      );
      workoutId = data.primaryActivityId;
      if (customTitle?.trim().isNotEmpty == true &&
          customTitle!.trim() != data.title) {
        final title = customTitle.trim();
        if (utf8.encode(title).length > 8192 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(title)) {
          throw const AutoSyncRecoveryException('标题包含控制字符或过长');
        }
        final payload =
            jsonDecode(utf8.decode(await _stateStore.readRecovery(fingerprint)))
                as Map<String, dynamic>;
        payload['title'] = title;
        await _stateStore.writeRecovery(
          fingerprint,
          Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        );
      }
      if (recoveryBatchId != null && recoveryBatchId != data.recoveryBatchId) {
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(recoveryBatchId)) {
          throw const AutoSyncRecoveryException('恢复批次标识无效');
        }
        final payload =
            jsonDecode(utf8.decode(await _stateStore.readRecovery(fingerprint)))
                as Map<String, dynamic>;
        payload['recoveryBatchId'] = recoveryBatchId;
        await _stateStore.writeRecovery(
          fingerprint,
          Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        );
      }
      if (data.channel == SyncUploadChannel.web && uploadOverride == null) {
        throw const AutoSyncRecoveryException('该记录需要 Strava 网页登录后恢复');
      }
      final response = await SyncRecoveryRunner(_stateStore).run(
        fingerprint: fingerprint,
        cancelled: cancelled,
        remoteExists: (id) async {
          try {
            return await const StravaWebChannel().readActivitySpeedData(id) !=
                null;
          } catch (_) {
            // Only an authenticated native HTTP 404 proves absence. Network,
            // authorization and parsing failures never authorize another POST.
            return null;
          }
        },
        deleteRemote:
            deleteRemote ??
            (_) async {
              throw const AutoSyncRecoveryException('删除原活动需要 Strava 网页登录');
            },
        upload: (saved, externalId) => _uploadFit(
          logicalOperationId: 'recovery-$fingerprint',
          cancelled: cancelled,
          fit: saved.fit,
          externalId: externalId,
          filename: saved.filename,
          commute: saved.commute,
          description: saved.activityDescription,
          name: saved.title,
          upload: saved.channel == SyncUploadChannel.web
              ? uploadOverride
              : null,
        ),
      );
      remoteId = response.remoteId;
      uploadedRecorded = true;
      return AutoSyncResult(
        workoutId: workoutId,
        fingerprint: fingerprint,
        remoteId: remoteId,
        isDuplicate: response.isDuplicate,
        message: response.error?.message,
      );
    } on RecoveryCancelled {
      return AutoSyncResult.cancelled(
        workoutId: workoutId ?? fingerprint,
        fingerprint: fingerprint,
      );
    } catch (error) {
      if (!uploadedRecorded) {
        try {
          final saved = (await _stateStore.allRecords())[fingerprint];
          if (error is RecoveryCleanupFailed) {
            uploadedRecorded = true;
          } else if (saved is Map && saved['status'] != 'uploaded') {
            await _stateStore.markFailed(
              fingerprint: fingerprint,
              updatedAt: DateTime.now(),
              message: _safeRecoveryFailureMessage(error),
            );
          }
        } catch (_) {
          // 缺少本地记录或保护文件不可用时，保留原恢复包以便稍后继续。
        }
      }
      return AutoSyncResult.failed(
        workoutId: workoutId ?? fingerprint,
        fingerprint: fingerprint,
        message: uploadedRecorded
            ? 'Strava 上传已完成，但恢复文件清理失败；再次重传只会清理'
            : _safeRecoveryFailureMessage(error),
      );
    }
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
        commute:
            healthKitSportType(summary.activityType) == 'Ride' &&
            _commute(
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
                message: _safeFailureMessage(error),
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
    sportType: healthKitSportType(summary.activityType),
    coordinatesWgs84: true,
    updatedAt: DateTime.now(),
    startDate: DateTime.fromMillisecondsSinceEpoch(summary.startMs),
    title: summary.activityName,
    distanceMeters: summary.totalDistanceMeters,
    durationSeconds: summary.durationSeconds,
  );

  Future<({bool matches, String? remoteId})> _localDuplicate(
    WorkoutActivity activity,
    String fingerprint,
  ) async {
    final override = _isLocallyUploadedOverride;
    if (override != null) {
      return (matches: await override(fingerprint), remoteId: null);
    }
    final records = await _stateStore.allRecords();
    final matches = <Map>[];
    for (final entry in records.entries) {
      if (entry.value is! Map) continue;
      final record = entry.value as Map;
      if (record['status'] != 'uploaded') continue;
      var matched =
          entry.key == fingerprint ||
          (record['primarySourceId'] == activity.sourceId.value &&
              record['primaryActivityId'] == activity.id);
      final start = record['startDate'];
      final distance = record['distanceMeters'];
      if (!matched &&
          compatibleWorkoutSports(
            activity.effectiveSportType,
            sourceSportType(
              record['primarySourceId'] as String?,
              sportType: record['sportType'] as String?,
            ),
          ) &&
          start is num &&
          distance is num &&
          activity.distanceMeters != null) {
        matched = _stableDedupe(
          startASeconds: activity.start.millisecondsSinceEpoch / 1000,
          distanceAMeters: activity.distanceMeters!,
          startBSeconds: start.toDouble() + 978307200,
          distanceBMeters: distance.toDouble(),
          durationASeconds: activity.durationSeconds,
          durationBSeconds: (record['durationSeconds'] as num?)?.toDouble(),
        );
      }
      if (matched) matches.add(record);
    }
    if (matches.isEmpty) return (matches: false, remoteId: null);
    final remoteIds = {
      for (final record in matches)
        if (record['remoteId'] case final String id)
          if (isValidStravaActivityId(id)) id,
    };
    for (final remoteId in remoteIds) {
      try {
        final speed =
            await (_remoteSpeed?.call(remoteId) ?? _loadRemoteSpeed(remoteId));
        if (speed != null && isAnomalousStravaSpeed(speed)) {
          return (matches: false, remoteId: null);
        }
      } catch (_) {
        /* 无 API 授权或详情失败时保守保持本地去重。 */
      }
    }
    return (matches: true, remoteId: remoteIds.firstOrNull);
  }

  Future<rust.StravaActivitySpeedResult?> _loadRemoteSpeed(
    String remoteId,
  ) async {
    final reservation = rust.stravaReserveRemoteRead(
      operationId: 'speed-$remoteId-${DateTime.now().microsecondsSinceEpoch}',
    );
    _activeRemoteHandle = reservation.handle;
    try {
      return await rust.stravaFetchRemoteActivitySpeed(
        operationHandle: reservation.handle,
        accessToken: await _uploadSession.accessToken(),
        activityId: remoteId,
      );
    } finally {
      _activeRemoteHandle = null;
      rust.stravaReleaseRemoteRead(operationHandle: reservation.handle);
    }
  }

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
    final existing = (await _stateStore.allRecords())[record.fingerprint];
    if (existing is! Map || existing['status'] != 'uploaded') {
      await _stateStore.markPending(record);
    }
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
    final start = DateTime.fromMillisecondsSinceEpoch(summary.startMs);
    final end = DateTime.fromMillisecondsSinceEpoch(summary.endMs);
    final remoteList =
        await (_remoteActivities?.call(
              after: start.subtract(const Duration(days: 1)),
              before: end.add(const Duration(days: 1)),
            ) ??
            _loadRemoteActivities(
              fingerprint: fingerprint,
              after: start.subtract(const Duration(days: 1)),
              before: end.add(const Duration(days: 1)),
            ));
    final activities = remoteList
        .where(
          (remote) => compatibleWorkoutSports(
            healthKitSportType(summary.activityType),
            remote.sportType,
          ),
        )
        .toList();
    if (activities.isEmpty) return null;
    final index = _remoteMatchIndex(
      startTimeSeconds: summary.startMs / 1000,
      endTimeSeconds: summary.endMs / 1000,
      distanceMeters: distance,
      candidates: activities,
    );
    return index == null ? null : activities[index];
  }

  Future<List<rust.StravaRemoteActivityResult>> _loadRemoteActivities({
    required String fingerprint,
    required DateTime after,
    required DateTime before,
  }) async {
    final reservation = rust.stravaReserveRemoteRead(
      operationId: 'sync-preflight-$fingerprint',
    );
    _activeRemoteHandle = reservation.handle;
    try {
      return await rust.stravaListRemoteActivities(
        operationHandle: reservation.handle,
        accessToken: await _uploadSession.accessToken(),
        afterSeconds: after.millisecondsSinceEpoch ~/ 1000,
        beforeSeconds: before.millisecondsSinceEpoch ~/ 1000,
      );
    } finally {
      _activeRemoteHandle = null;
      rust.stravaReleaseRemoteRead(operationHandle: reservation.handle);
    }
  }

  static String _safeFailureMessage(Object error) => switch (error) {
    AutoSyncUploadException() => error.message,
    _ => '同步首传失败',
  };

  static String _safeRecoveryFailureMessage(Object error) => switch (error) {
    AutoSyncRecoveryException() => error.message,
    AutoSyncUploadException() => error.message,
    RecoveryGhostDuplicate() => 'Strava 暂时仍返回已删除活动；恢复文件已保留，请稍后继续',
    RecoveryUnverifiedDuplicate() => '无法确认重复活动是否存在；恢复文件已保留，请检查 Strava 后继续',
    _ => '重传恢复失败',
  };

  Future<rust.StravaUploadFfiResponse> _uploadFit({
    required String logicalOperationId,
    required Uint8List fit,
    required String externalId,
    required String filename,
    required bool commute,
    AutoSyncUpload? upload,
    bool Function()? cancelled,
    String? description,
    String? name,
  }) async {
    final generation = _uploadCancellationGeneration;
    var effectiveCommute = commute;
    if (commute) {
      // Legacy recovery files predate sport metadata. Classify their saved final
      // bytes once so the same false flag reaches upload AND metadata finalization.
      try {
        final preview = jsonDecode(await _inspectFit(data: fit));
        if (preview is Map && preview['allSessionsRunning'] == true) {
          effectiveCommute = false;
        }
      } catch (_) {
        // Unknown/invalid classification must not change legacy cycling intent.
      }
    }
    if (generation != _uploadCancellationGeneration ||
        cancelled?.call() == true) {
      return const rust.StravaUploadFfiResponse(
        status: rust.StravaUploadFfiStatus.cancelled,
        isDuplicate: false,
      );
    }
    final uploader = upload ?? _upload;
    if (uploader != null) {
      return uploader(
        logicalOperationId: logicalOperationId,
        fit: fit,
        externalId: externalId,
        filename: filename,
        commute: effectiveCommute,
        description: description,
        name: name,
      );
    }
    final task = _uploadSession.start(
      logicalOperationId: logicalOperationId,
      fit: fit,
      externalId: externalId,
      filename: filename,
      commute: effectiveCommute,
      description: description,
      name: name,
    );
    _activeUploadTask = task;
    try {
      return await task.result;
    } finally {
      if (identical(_activeUploadTask, task)) _activeUploadTask = null;
    }
  }
}

final class AutoSyncResult {
  const AutoSyncResult({
    required this.workoutId,
    required this.fingerprint,
    required this.remoteId,
    required this.isDuplicate,
    this.message,
  }) : failed = false,
       cancelled = false;

  const AutoSyncResult.failed({
    required this.workoutId,
    required this.fingerprint,
    required this.message,
  }) : remoteId = null,
       isDuplicate = false,
       failed = true,
       cancelled = false;

  const AutoSyncResult.cancelled({
    required this.workoutId,
    required this.fingerprint,
  }) : remoteId = null,
       isDuplicate = false,
       message = '已停止',
       failed = false,
       cancelled = true;

  final String workoutId;
  final String? fingerprint;
  final String? remoteId;
  final bool isDuplicate;
  final String? message;
  final bool failed;
  final bool cancelled;
  bool get succeeded => !failed && !cancelled;
}

final class _AutoSyncCancelled implements Exception {
  const _AutoSyncCancelled();
}

final class AutoSyncUploadException implements Exception {
  const AutoSyncUploadException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class AutoSyncRecoveryException implements Exception {
  const AutoSyncRecoveryException(this.message);

  final String message;

  @override
  String toString() => message;
}
