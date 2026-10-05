import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'auto_sync_controller.dart';
import 'auto_sync_checkpoint.dart';
import 'recovery_batch_checkpoint.dart';
import 'sync_preview_models.dart';
import 'sync_destination_flow.dart';
import 'apple_health_import.dart';
import 'strava_remote_repository.dart';
import 'strava_upload_api.dart' show stravaUploadSession;
import 'package:flutter/services.dart' show PlatformException;
import 'native_channels.dart';
import 'src/rust/api/simple.dart' as rust;
import 'workout_source.dart';
import 'sync_state_store.dart';

/// 全局单批次同步会话；页签切换不取消。
final class AutoSyncSession extends ChangeNotifier {
  AutoSyncSession({AutoSyncController? controller}) {
    _controller = controller ?? AutoSyncController(remoteSpeed: _remote.speed);
  }

  static final instance = AutoSyncSession();

  late final AutoSyncController _controller;
  final _remote = StravaRemoteRepository();
  final _files = const SyncFilesChannel();
  final _stateStore = SyncStateStore();
  RecoveryBatchCheckpoint? _lastRecovery;
  AppleHealthImportPass? _healthPass;
  HealthNearbyDecisionHandler? _onHealthNearby;

  AppleHealthImportPass _createHealthPass() {
    const channel = HealthKitChannel();
    return AppleHealthImportPass(
      canWriteWorkouts: channel.canWriteWorkouts,
      requestWriteAuthorization: channel.requestWriteAuthorization,
      findNearbyWorkouts: ({required startMs, required endMs}) async =>
          (await channel.findNearbyWorkouts(
            startMs: startMs,
            endMs: endMs,
          )).map(HealthNearbyWorkout.fromObject).toList(),
      writeWorkout: channel.writeWorkout,
      decodeFitHealthDraft: rust.decodeFitHealthDraft,
      recordFor: _stateStore.recordFor,
      markWritten: _stateStore.markAppleHealthWritten,
      markSkipped: _stateStore.markAppleHealthSkipped,
      markFailed: _stateStore.markAppleHealthFailed,
      cancelled: () => cancelled,
      onNearby: (prompt) =>
          _onHealthNearby?.call(prompt) ??
          Future.value(AppleHealthNearbyDecision.skipOnce),
    );
  }

  Future<void>? _restoration;
  String? restoreError;

  Future<void> restore() => _restoration ??= _restore();
  Future<void> _restore() async {
    try {
      final bytes = await _files.readBatchSession();
      final root = jsonDecode(utf8.decode(bytes));
      if (root is Map && root['kind'] == 'recovery') {
        _lastRecovery = RecoveryBatchCheckpoint.decode(bytes);
        progress = AutoSyncProgress(
          total: _lastRecovery!.fingerprints.length,
          processed: _lastRecovery!.completed.length,
          uploaded: 0,
          deduped: 0,
          failed: 0,
          message: '已恢复上次恢复队列，继续将按原选择处理',
        );
        notifyListeners();
        return;
      }
      final snapshot = AutoSyncCheckpoint.decode(bytes);
      _lastBatch = _BatchConfiguration.fromJson(snapshot.configuration);
      _completedActivityIds.addAll(snapshot.completedIds);
      progress = AutoSyncProgress(
        total: _lastBatch!.activities.length,
        processed: _completedActivityIds.length,
        uploaded: 0,
        deduped: 0,
        failed: 0,
        message: '已恢复上次配置，可手动继续剩余活动',
      );
    } on PlatformException catch (error) {
      if (error.code != 'sync_file_missing') {
        restoreError = '无法读取上次批次；请检查本机存储后重试';
      }
    } catch (_) {
      restoreError = '上次批次文件无效，未自动执行任何同步';
    }
    notifyListeners();
  }

  Future<void> _saveCheckpoint() async {
    final recovery = _lastRecovery;
    if (recovery != null) {
      await _files.writeBatchSession(recovery.encode());
      return;
    }
    final batch = _lastBatch;
    if (batch == null) return;
    await _files.writeBatchSession(
      AutoSyncCheckpoint(
        configuration: batch.toJson(),
        completedIds: _completedActivityIds,
      ).encode(),
    );
    restoreError = null;
  }

  var isRunning = false;
  var cancelled = false;
  AutoSyncProgress progress = const AutoSyncProgress(
    total: 0,
    processed: 0,
    uploaded: 0,
    deduped: 0,
    failed: 0,
  );
  List<AutoSyncResult> results = const [];
  _BatchConfiguration? _lastBatch;
  final _completedActivityIds = <String>{};

  bool get canRetry =>
      !isRunning && (_lastBatch != null || _lastRecovery != null);
  bool get canContinue =>
      canRetry &&
      (_lastRecovery != null
          ? _lastRecovery!.fingerprints.any(
              (id) => !_lastRecovery!.completed.contains(id),
            )
          : _lastBatch!.activities.any(
              (activity) => !_completedActivityIds.contains(activity.id),
            ));

  void cancel() {
    cancelled = true;
    _controller.cancelActiveOperations();
    _remote.cancel();
    _healthPass?.cancel();
    for (final source in [_lastBatch?.primary, ...?_lastBatch?.supplements]) {
      if (source is CancellableWorkoutSource) source.cancelPending();
    }
    notifyListeners();
  }

  Future<AutoSyncResult> resumeRecovery(
    String fingerprint, {
    bool replaceExisting = false,
  }) async {
    final result = await runRecoveryBatch([
      fingerprint,
    ], replaceExisting: replaceExisting);
    return result.isEmpty
        ? AutoSyncResult.cancelled(
            workoutId: fingerprint,
            fingerprint: fingerprint,
          )
        : result.single;
  }

  Future<List<AutoSyncResult>> runRecoveryBatch(
    List<String> fingerprints, {
    bool replaceExisting = false,
    bool uploadToStrava = true,
    bool writeToHealth = false,
    String? customTitle,
    LegacyRecoveryChooser? onLegacy,
    HealthNearbyDecisionHandler? onHealthNearby,
  }) async {
    await restore();
    if (isRunning) throw const AutoSyncUploadException('已有同步批次在运行');
    final queue = RecoveryBatchCheckpoint(
      fingerprints: List.unmodifiable(fingerprints),
      replaceExisting: replaceExisting,
      uploadToStrava: uploadToStrava,
      writeToHealth: writeToHealth,
      customTitle: customTitle,
    );
    queue.encode();
    _lastRecovery = queue;
    _lastBatch = null;
    return _runRecoveryQueue(
      queue,
      ids: queue.fingerprints,
      onLegacy: onLegacy,
      onHealthNearby: onHealthNearby,
    );
  }

  Future<void> _adoptLegacyRecovery(
    String fingerprint,
    LegacyRecoveryChooser? onLegacy,
  ) async {
    Uint8List bytes;
    try {
      bytes = await _stateStore.readRecovery(fingerprint);
    } on PlatformException catch (error) {
      if (error.code == 'sync_file_missing') return;
      rethrow;
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> || value['phase'] != null) return;
    final record = (await _stateStore.allRecords())[fingerprint];
    final rawId = record is Map ? record['remoteId'] : null;
    final remoteId = rawId is String && isValidStravaActivityId(rawId)
        ? rawId
        : null;
    final decision =
        await onLegacy?.call(
          LegacyRecoveryPrompt(
            title: value['title'] as String? ?? fingerprint,
            remoteId: remoteId,
          ),
        ) ??
        LegacyRecoveryDecision.stop;
    if (cancelled || decision == LegacyRecoveryDecision.stop) {
      cancel();
      return;
    }
    if (decision == LegacyRecoveryDecision.skip) {
      throw const AutoSyncRecoveryException('已跳过旧恢复包，未改变原文件');
    }
    if (decision == LegacyRecoveryDecision.replaceRemote && remoteId == null) {
      throw const AutoSyncRecoveryException('旧恢复包缺少可确认的远端 ID');
    }
    // Older Swift payloads do not encode destination channel or deletion phase.
    // The explicit choice above supplies that missing intent, never an inference.
    final settings = await const StravaSettingsStore().load();
    if (cancelled) return;
    value['uploadChannel'] ??= record is Map
        ? record['uploadChannel'] ?? settings.mode.name
        : settings.mode.name;
    await _stateStore.writeRecovery(
      fingerprint,
      Uint8List.fromList(utf8.encode(jsonEncode(value))),
    );
    await _stateStore.prepareRecovery(
      fingerprint: fingerprint,
      recoveryJson: bytes,
      remoteIdToReplace: decision == LegacyRecoveryDecision.replaceRemote
          ? remoteId
          : null,
    );
  }

  Future<List<AutoSyncResult>> _runRecoveryQueue(
    RecoveryBatchCheckpoint queue, {
    required List<String> ids,
    LegacyRecoveryChooser? onLegacy,
    HealthNearbyDecisionHandler? onHealthNearby,
  }) async {
    if (isRunning) throw const AutoSyncUploadException('已有同步批次在运行');
    isRunning = true;
    cancelled = false;
    results = const [];
    var uploaded = 0, deduped = 0, failed = 0;
    var activeQueue = queue;
    _lastRecovery = activeQueue;
    _onHealthNearby = onHealthNearby;
    final current = <AutoSyncResult>[];
    progress = AutoSyncProgress(
      total: ids.length,
      processed: 0,
      uploaded: 0,
      deduped: 0,
      failed: 0,
      message: '准备恢复队列',
    );
    notifyListeners();
    try {
      await _saveCheckpoint();
      if (queue.writeToHealth) {
        if (!await const HealthKitChannel().canWriteWorkouts()) {
          throw const AutoSyncUploadException('本平台不支持写入苹果健康');
        }
        (_healthPass ??= _createHealthPass()).beginBatch();
      }
      for (final fingerprint in ids) {
        if (cancelled) break;
        AutoSyncResult result;

        try {
          AutoSyncResult? stravaResult, healthResult;
          final persisted = await _stateStore.recordFor(fingerprint);
          activeQueue = activeQueue
              .reconcileUploaded(fingerprint, persisted)
              .reconcileHealth(fingerprint, persisted);
          _lastRecovery = activeQueue;
          await _saveCheckpoint();
          await runSyncDestinations(
            ids: [fingerprint],
            uploadToStrava: queue.uploadToStrava,
            writeToHealth: queue.writeToHealth,
            cancelled: () => cancelled,
            runStrava: () async {
              if (!activeQueue.needsStrava(fingerprint)) {
                stravaResult = AutoSyncResult(
                  workoutId: fingerprint,
                  fingerprint: fingerprint,
                  remoteId: activeQueue.stravaCompleted[fingerprint],
                  isDuplicate: true,
                  message: '本批 Strava 已完成，仅继续其余目标',
                );
                return {fingerprint: true};
              }
              await _adoptLegacyRecovery(fingerprint, onLegacy);
              if (cancelled) return {};
              stravaResult = await _controller.resumeRecovery(
                fingerprint,
                uploadOverride: _webUpload,
                deleteRemote: const StravaWebChannel().deleteActivity,
                cancelled: () => cancelled,
                replaceExisting: queue.replaceExisting,
                customTitle: queue.customTitle,
                recoveryBatchId: activeQueue.generationId,
              );
              if (stravaResult!.succeeded) {
                activeQueue = activeQueue.markStrava(
                  fingerprint,
                  stravaResult!.remoteId,
                );
                _lastRecovery = activeQueue;
                await _saveCheckpoint();
              }
              return {fingerprint: stravaResult!.succeeded};
            },
            runHealth: () async {
              if (!activeQueue.needsHealth(fingerprint)) {
                healthResult = AutoSyncResult(
                  workoutId: fingerprint,
                  fingerprint: fingerprint,
                  remoteId: null,
                  isDuplicate: true,
                  message: '本批健康写入已完成',
                );
                return {fingerprint: true};
              }
              healthResult = await _importStoredHealth(fingerprint);
              final saved = await _stateStore.recordFor(fingerprint);
              final success =
                  healthResult!.succeeded &&
                  (saved?['appleHealthUUID'] != null ||
                      saved?['appleHealthSkipped'] == true);
              if (success) {
                activeQueue = activeQueue.markHealth(fingerprint);
                _lastRecovery = activeQueue;
                await _saveCheckpoint();
              }
              return {fingerprint: success};
            },
          );

          result = stravaResult?.failed == true
              ? stravaResult!
              : healthResult ??
                    stravaResult ??
                    AutoSyncResult.cancelled(
                      workoutId: fingerprint,
                      fingerprint: fingerprint,
                    );
        } catch (error) {
          result = AutoSyncResult.failed(
            workoutId: fingerprint,
            fingerprint: fingerprint,
            message: error is AutoSyncRecoveryException
                ? error.message
                : '恢复准备失败，原文件已保留',
          );
        }
        if (result.cancelled) break;
        current.add(result);
        if (result.failed) {
          failed++;
        } else {
          // Per-target proof was already persisted before starting the next target.
          if (result.isDuplicate) {
            deduped++;
          } else {
            uploaded++;
          }
        }
        _lastRecovery = activeQueue;
        await _saveCheckpoint();
        progress = AutoSyncProgress(
          total: ids.length,
          processed: current.length,
          uploaded: uploaded,
          deduped: deduped,
          failed: failed,
          message: '恢复 ${current.length}/${ids.length}',
        );
        results = List.unmodifiable(current);
        notifyListeners();
      }
      return List.unmodifiable(current);
    } finally {
      isRunning = false;
      notifyListeners();
    }
  }

  Future<void> _cleanupHealthPreparation(String fingerprint) async {
    try {
      final record = await _stateStore.recordFor(fingerprint);
      if (record?['appleHealthUUID'] != null ||
          record?['appleHealthSkipped'] == true) {
        await _stateStore.deleteHealthPreparedFit(fingerprint);
      }
    } catch (_) {
      /* Persisted UUID remains authoritative; cleanup never retries a Health write. */
    }
  }

  Future<AutoSyncResult> _importStoredHealth(String fingerprint) async {
    final record = await _stateStore.recordFor(fingerprint);
    final start = record?['startDate'], duration = record?['durationSeconds'];
    if (record == null ||
        start is! num ||
        duration is! num ||
        !start.isFinite ||
        !duration.isFinite) {
      return AutoSyncResult.failed(
        workoutId: fingerprint,
        fingerprint: fingerprint,
        message: '健康写入缺少本地训练元数据',
      );
    }
    final startDate = DateTime.fromMillisecondsSinceEpoch(
      ((start + 978307200) * 1000).round(),
    );
    final id = record['primaryActivityId'] as String? ?? fingerprint;
    try {
      final result = await _healthPass!.process(
        fingerprint: fingerprint,
        fit: await _stateStore.readFitForHealth(fingerprint),
        title: record['title'] as String? ?? id,
        start: startDate,
        end: startDate.add(Duration(milliseconds: (duration * 1000).round())),
        duration: duration.toDouble(),
        distance: (record['distanceMeters'] as num?)?.toDouble(),
      );
      await _cleanupHealthPreparation(fingerprint);
      if (result.outcome == AppleHealthImportOutcome.failed) {
        return AutoSyncResult.failed(
          workoutId: id,
          fingerprint: fingerprint,
          message: result.message,
        );
      }
      return AutoSyncResult(
        workoutId: id,
        fingerprint: fingerprint,
        remoteId: null,
        isDuplicate: result.outcome == AppleHealthImportOutcome.skipped,
        message: result.message,
      );
    } on AppleHealthImportCancelled {
      cancelled = true;
      return AutoSyncResult.cancelled(workoutId: id, fingerprint: fingerprint);
    }
  }

  Future<List<AutoSyncResult>> continueRemaining({
    DuplicatePrompt? onDuplicate,
    SyncPreviewChooser? onPreview,
    HealthNearbyDecisionHandler? onHealthNearby,
    LegacyRecoveryChooser? onLegacy,
  }) {
    final recovery = _lastRecovery;
    if (recovery != null) {
      return _runRecoveryQueue(
        recovery,
        ids: [
          for (final id in recovery.fingerprints)
            if (!recovery.completed.contains(id)) id,
        ],
        onLegacy: onLegacy,
        onHealthNearby: onHealthNearby,
      );
    }
    final batch = _lastBatch;
    if (batch == null) throw const AutoSyncUploadException('没有可继续的同步批次');
    return _runBatch(
      batch,
      activities: [
        for (final activity in batch.activities)
          if (!_completedActivityIds.contains(activity.id)) activity,
      ],
      onDuplicate: onDuplicate,
      onPreview: onPreview,
      onHealthNearby: onHealthNearby,
    );
  }

  Future<List<AutoSyncResult>> retryLastBatch({
    DuplicatePrompt? onDuplicate,
    SyncPreviewChooser? onPreview,
    HealthNearbyDecisionHandler? onHealthNearby,
    LegacyRecoveryChooser? onLegacy,
  }) {
    final recovery = _lastRecovery;
    if (recovery != null) {
      return _runRecoveryQueue(
        recovery.retryAll(),
        ids: recovery.fingerprints,
        onLegacy: onLegacy,
        onHealthNearby: onHealthNearby,
      );
    }
    final batch = _lastBatch;
    if (batch == null) throw const AutoSyncUploadException('没有可重试的同步批次');
    return _runBatch(
      batch,
      activities: batch.activities,
      onDuplicate: onDuplicate,
      onPreview: onPreview,
      onHealthNearby: onHealthNearby,
    );
  }

  Future<List<AutoSyncResult>> run({
    required WorkoutSource primary,
    required List<WorkoutSource> supplements,
    required List<WorkoutActivity> activities,
    bool gcjEnabled = false,
    bool skipLocalHistory = true,
    rust.VirtualPowerFillInput? virtualPower,
    DuplicatePrompt? onDuplicate,
    SyncPreviewChooser? onPreview,
    HealthNearbyDecisionHandler? onHealthNearby,
    SyncPreviewPolicy previewPolicy = SyncPreviewPolicy.issuesOnly,
    String? customTitle,
    bool uploadToStrava = true,
    bool writeToHealth = false,
  }) async {
    await restore();
    if (isRunning) throw const AutoSyncUploadException('已有同步批次在运行');
    final settings = await const StravaSettingsStore().load();
    if (isRunning) throw const AutoSyncUploadException('已有同步批次在运行');
    final batch = _BatchConfiguration(
      primary: primary,
      supplements: List.unmodifiable(supplements),
      activities: List.unmodifiable(activities),
      gcjEnabled: gcjEnabled,
      virtualPower: virtualPower,
      mode: settings.mode,
      skipLocalHistory: skipLocalHistory,
      customTitle: customTitle,
      previewPolicy: previewPolicy,
      uploadToStrava: uploadToStrava,
      writeToHealth: writeToHealth,
    );
    _lastRecovery = null;
    _lastBatch = batch;
    _completedActivityIds.clear();
    return _runBatch(
      batch,
      activities: batch.activities,
      onDuplicate: onDuplicate,
      onPreview: onPreview,
      onHealthNearby: onHealthNearby,
    );
  }

  Future<List<AutoSyncResult>> _runBatch(
    _BatchConfiguration batch, {
    required List<WorkoutActivity> activities,
    DuplicatePrompt? onDuplicate,
    SyncPreviewChooser? onPreview,
    HealthNearbyDecisionHandler? onHealthNearby,
  }) async {
    if (isRunning) {
      throw const AutoSyncUploadException('已有同步批次在运行');
    }
    isRunning = true;
    cancelled = false;
    results = const [];
    final preserved = completedBeforeRetry(
      _completedActivityIds,
      activities.map((a) => a.id).toList(),
    );
    _completedActivityIds
      ..clear()
      ..addAll(preserved);
    progress = AutoSyncProgress(
      total: activities.length,
      processed: 0,
      uploaded: 0,
      deduped: 0,
      failed: 0,
      message: '准备中',
    );
    notifyListeners();
    try {
      await _saveCheckpoint();
      if (!batch.uploadToStrava && !batch.writeToHealth) {
        throw const AutoSyncUploadException('请至少选择一个同步目标');
      }
      if (batch.writeToHealth &&
          (batch.primary.id == WorkoutSourceId.healthkit ||
              !await const HealthKitChannel().canWriteWorkouts())) {
        throw const AutoSyncUploadException('当前主源或平台不支持写入苹果健康');
      }
      _onHealthNearby = onHealthNearby;
      final web = batch.mode == StravaUploadMode.web;
      final stravaResults = <String, AutoSyncResult>{};
      final healthResults = <String, AutoSyncResult>{};
      final healthCompleted = <String, bool>{};
      void progressChanged(AutoSyncProgress value) {
        progress = value;
        notifyListeners();
      }

      final targetResult = await runSyncDestinations(
        ids: activities.map((a) => a.id).toList(),
        uploadToStrava: batch.uploadToStrava,
        writeToHealth: batch.writeToHealth,
        cancelled: () => cancelled,
        runStrava: () async {
          final outcome = await _controller.syncBatch(
            primary: batch.primary,
            supplements: batch.supplements,
            activities: activities,
            gcjEnabled: batch.gcjEnabled,
            virtualPower: batch.virtualPower,
            onDuplicate: onDuplicate,
            onPreview: (prompt) => coordinateSyncPreview(
              prompt,
              chooser: onPreview,
              onStop: cancel,
            ),
            previewPolicy: batch.previewPolicy,
            customTitle: batch.customTitle,
            cancelled: () => cancelled,
            onProgress: progressChanged,
            upload: web ? _webUpload : null,
            uploadChannel: web ? SyncUploadChannel.web : SyncUploadChannel.api,
            performRemotePreflight: true,
            remoteActivities: ({required after, required before}) =>
                _remote.list(after: after, before: before, webOnly: web),
            deleteRemote: const StravaWebChannel().deleteActivity,
            skipLocalHistory: batch.skipLocalHistory,
            onResult: (result) async {
              stravaResults[result.workoutId] = result;
              if (result.succeeded && !batch.writeToHealth) {
                _completedActivityIds.add(result.workoutId);
              }
              await _saveCheckpoint();
            },
          );
          return {
            for (final result in outcome) result.workoutId: result.succeeded,
          };
        },
        runHealth: () async {
          final pass = _healthPass ??= _createHealthPass();
          pass.beginBatch();
          await _controller.syncBatch(
            primary: batch.primary,
            supplements: batch.supplements,
            activities: activities,
            gcjEnabled: batch.gcjEnabled,
            virtualPower: batch.virtualPower,
            onPreview: (prompt) => coordinateSyncPreview(
              prompt,
              chooser: onPreview,
              onStop: cancel,
            ),
            previewPolicy: batch.previewPolicy,
            cancelled: () => cancelled,
            onProgress: progressChanged,
            uploadToStrava: false,
            performRemotePreflight: false,
            skipLocalHistory: false,
            healthImport: ({required record, required fit}) async {
              try {
                final result = await pass.process(
                  fingerprint: record.fingerprint,
                  fit: fit,
                  title: record.title ?? record.primaryActivityId,
                  start: record.startDate!,
                  end: record.startDate!.add(
                    Duration(
                      milliseconds: ((record.durationSeconds ?? 1) * 1000)
                          .round(),
                    ),
                  ),
                  duration: record.durationSeconds ?? 1,
                  distance: record.distanceMeters,
                );
                await _cleanupHealthPreparation(record.fingerprint);
                if (result.outcome == AppleHealthImportOutcome.failed) {
                  return AutoSyncResult.failed(
                    workoutId: record.primaryActivityId,
                    fingerprint: record.fingerprint,
                    message: result.message,
                  );
                }
                return AutoSyncResult(
                  workoutId: record.primaryActivityId,
                  fingerprint: record.fingerprint,
                  remoteId: null,
                  isDuplicate:
                      result.outcome == AppleHealthImportOutcome.skipped,
                  message: result.message,
                );
              } on AppleHealthImportCancelled {
                cancelled = true;
                return AutoSyncResult.cancelled(
                  workoutId: record.primaryActivityId,
                  fingerprint: record.fingerprint,
                );
              }
            },
            onResult: (result) async {
              healthResults[result.workoutId] = result;
              final record = result.fingerprint == null
                  ? null
                  : await _stateStore.recordFor(result.fingerprint!);
              final committed =
                  result.succeeded &&
                  (record?['appleHealthUUID'] != null ||
                      record?['appleHealthSkipped'] == true);
              healthCompleted[result.workoutId] = committed;
              if (committed &&
                  (!batch.uploadToStrava ||
                      stravaResults[result.workoutId]?.succeeded == true)) {
                _completedActivityIds.add(result.workoutId);
              }
              await _saveCheckpoint();
            },
          );
          return healthCompleted;
        },
      );
      _completedActivityIds.addAll(targetResult.completedIds);
      results = [
        for (final activity in activities)
          if (stravaResults.containsKey(activity.id) ||
              healthResults.containsKey(activity.id))
            if (stravaResults[activity.id]?.failed == true)
              stravaResults[activity.id]!
            else if (healthResults[activity.id]?.failed == true)
              healthResults[activity.id]!
            else
              healthResults[activity.id] ?? stravaResults[activity.id]!,
      ];
      return results;
    } finally {
      isRunning = false;
      notifyListeners();
    }
  }

  Future<rust.StravaUploadFfiResponse> _webUpload({
    required String logicalOperationId,
    required Uint8List fit,
    required String externalId,
    required String filename,
    required bool commute,
    String? description,
    String? name,
  }) async {
    final result = await const StravaWebChannel().uploadFit(
      data: fit,
      filename: filename,
      externalId: externalId,
    );
    final response = rust.StravaUploadFfiResponse(
      status: rust.StravaUploadFfiStatus.completed,
      remoteId: result.remoteId,
      isDuplicate: result.isDuplicate,
    );
    return stravaUploadSession.finalizeWebUpload(
      response,
      name: name,
      commute: commute,
      description: description,
      cancelled: () => cancelled,
    );
  }
}

final class _BatchConfiguration {
  const _BatchConfiguration({
    required this.primary,
    required this.supplements,
    required this.activities,
    required this.gcjEnabled,
    required this.virtualPower,
    required this.mode,
    required this.skipLocalHistory,
    this.customTitle,
    this.previewPolicy = SyncPreviewPolicy.issuesOnly,
    this.uploadToStrava = true,
    this.writeToHealth = false,
  });
  factory _BatchConfiguration.fromJson(Map<String, Object?> value) {
    final primary = WorkoutSourceId.values.byName(value['primary'] as String);
    final power = value['virtualPower'] as Map?;
    return _BatchConfiguration(
      primary: workoutSourceFor(primary),
      supplements: [
        for (final id in value['supplements'] as List)
          workoutSourceFor(WorkoutSourceId.values.byName(id as String)),
      ],
      activities: [
        for (final raw in value['activities'] as List)
          WorkoutActivity(
            id: raw['id'] as String,
            sourceId: primary,
            title: raw['title'] as String,
            start: DateTime.fromMillisecondsSinceEpoch(raw['startMs'] as int),
            end: DateTime.fromMillisecondsSinceEpoch(raw['endMs'] as int),
            durationSeconds: (raw['durationSeconds'] as num).toDouble(),
            distanceMeters: (raw['distanceMeters'] as num?)?.toDouble(),
            sportType: raw['sportType'] as String?,
            coordinatesWgs84: raw['coordinatesWgs84'] as bool?,
            indoor: raw['indoor'] as bool? ?? false,
          ),
      ],
      gcjEnabled: value['gcjEnabled'] as bool,
      skipLocalHistory: value['skipLocalHistory'] as bool,
      customTitle: value['customTitle'] as String?,
      previewPolicy: SyncPreviewPolicy.values.byName(
        value['previewPolicy'] as String? ?? 'issuesOnly',
      ),
      uploadToStrava: value['uploadToStrava'] as bool? ?? true,
      writeToHealth: value['writeToHealth'] as bool? ?? false,
      mode: StravaUploadMode.values.byName(value['mode'] as String),
      virtualPower: power == null
          ? null
          : rust.VirtualPowerFillInput(
              riderMassKg: (power['riderMassKg'] as num).toDouble(),
              bikeMassKg: (power['bikeMassKg'] as num).toDouble(),
              cda: (power['cda'] as num).toDouble(),
              includeInertia: power['includeInertia'] as bool,
            ),
    );
  }
  Map<String, Object?> toJson() => {
    'primary': primary.id.value,
    'supplements': [for (final source in supplements) source.id.value],
    'activities': [
      for (final a in activities)
        {
          'id': a.id,
          'title': a.title,
          'startMs': a.start.millisecondsSinceEpoch,
          'endMs': a.end.millisecondsSinceEpoch,
          'durationSeconds': a.durationSeconds,
          'distanceMeters': a.distanceMeters,
          if (a.effectiveSportType != null) 'sportType': a.effectiveSportType,
          'coordinatesWgs84': a.hasWgs84Coordinates,
          'indoor': a.indoor,
        },
    ],
    'customTitle': customTitle,
    'previewPolicy': previewPolicy.name,
    'uploadToStrava': uploadToStrava,
    'writeToHealth': writeToHealth,
    'gcjEnabled': gcjEnabled,
    'skipLocalHistory': skipLocalHistory,
    'mode': mode.name,
    'virtualPower': virtualPower == null
        ? null
        : {
            'riderMassKg': virtualPower!.riderMassKg,
            'bikeMassKg': virtualPower!.bikeMassKg,
            'cda': virtualPower!.cda,
            'includeInertia': virtualPower!.includeInertia,
          },
  };
  final WorkoutSource primary;
  final List<WorkoutSource> supplements;
  final List<WorkoutActivity> activities;
  final bool gcjEnabled;
  final rust.VirtualPowerFillInput? virtualPower;
  final StravaUploadMode mode;
  final bool skipLocalHistory;
  final String? customTitle;
  final SyncPreviewPolicy previewPolicy;
  final bool uploadToStrava, writeToHealth;
}
