import 'package:flutter/foundation.dart';

import 'auto_sync_controller.dart';
import 'auto_sync_checkpoint.dart';
import 'strava_remote_repository.dart';
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
  Future<void>? _restoration;
  String? restoreError;

  Future<void> restore() => _restoration ??= _restore();
  Future<void> _restore() async {
    try {
      final snapshot = AutoSyncCheckpoint.decode(
        await _files.readBatchSession(),
      );
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

  bool get canRetry => !isRunning && _lastBatch != null;
  bool get canContinue =>
      canRetry &&
      _lastBatch!.activities.any(
        (activity) => !_completedActivityIds.contains(activity.id),
      );

  void cancel() {
    cancelled = true;
    _controller.cancelActiveOperations();
    _remote.cancel();
    for (final source in [_lastBatch?.primary, ...?_lastBatch?.supplements]) {
      if (source is CancellableWorkoutSource) source.cancelPending();
    }
    notifyListeners();
  }

  Future<AutoSyncResult> resumeRecovery(
    String fingerprint, {
    bool replaceExisting = false,
  }) async {
    if (isRunning) throw const AutoSyncUploadException('已有同步批次在运行');
    isRunning = true;
    cancelled = false;
    notifyListeners();
    try {
      return await _controller.resumeRecovery(
        fingerprint,
        uploadOverride: _webUpload,
        deleteRemote: const StravaWebChannel().deleteActivity,
        cancelled: () => cancelled,
        replaceExisting: replaceExisting,
      );
    } finally {
      isRunning = false;
      notifyListeners();
    }
  }

  Future<List<AutoSyncResult>> continueRemaining({
    DuplicatePrompt? onDuplicate,
  }) {
    final batch = _lastBatch;
    if (batch == null) throw const AutoSyncUploadException('没有可继续的同步批次');
    return _runBatch(
      batch,
      activities: [
        for (final activity in batch.activities)
          if (!_completedActivityIds.contains(activity.id)) activity,
      ],
      onDuplicate: onDuplicate,
    );
  }

  Future<List<AutoSyncResult>> retryLastBatch({DuplicatePrompt? onDuplicate}) {
    final batch = _lastBatch;
    if (batch == null) throw const AutoSyncUploadException('没有可重试的同步批次');
    return _runBatch(
      batch,
      activities: batch.activities,
      onDuplicate: onDuplicate,
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
    );
    _lastBatch = batch;
    _completedActivityIds.clear();
    return _runBatch(
      batch,
      activities: batch.activities,
      onDuplicate: onDuplicate,
    );
  }

  Future<List<AutoSyncResult>> _runBatch(
    _BatchConfiguration batch, {
    required List<WorkoutActivity> activities,
    DuplicatePrompt? onDuplicate,
  }) async {
    if (isRunning) {
      throw const AutoSyncUploadException('已有同步批次在运行');
    }
    isRunning = true;
    cancelled = false;
    results = const [];
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
      final web = batch.mode == StravaUploadMode.web;
      results = await _controller.syncBatch(
        primary: batch.primary,
        supplements: batch.supplements,
        activities: activities,
        gcjEnabled: batch.gcjEnabled,
        virtualPower: batch.virtualPower,
        onDuplicate: onDuplicate,
        cancelled: () => cancelled,
        onProgress: (value) {
          progress = value;
          notifyListeners();
        },
        upload: web ? _webUpload : null,
        uploadChannel: web ? SyncUploadChannel.web : SyncUploadChannel.api,
        performRemotePreflight: true,
        remoteActivities: ({required after, required before}) =>
            _remote.list(after: after, before: before, webOnly: web),
        deleteRemote: const StravaWebChannel().deleteActivity,
        onResult: (result) async {
          if (result.succeeded) _completedActivityIds.add(result.workoutId);
          await _saveCheckpoint();
        },
        skipLocalHistory: batch.skipLocalHistory,
      );
      _completedActivityIds.addAll(
        results
            .where((result) => result.succeeded)
            .map((result) => result.workoutId),
      );
      return results;
    } finally {
      isRunning = false;
      notifyListeners();
    }
  }

  static Future<rust.StravaUploadFfiResponse> _webUpload({
    required String logicalOperationId,
    required Uint8List fit,
    required String externalId,
    required String filename,
    required bool commute,
    String? description,
  }) async {
    final result = await const StravaWebChannel().uploadFit(
      data: fit,
      filename: filename,
      externalId: externalId,
    );
    return rust.StravaUploadFfiResponse(
      status: rust.StravaUploadFfiStatus.completed,
      remoteId: result.remoteId,
      isDuplicate: result.isDuplicate,
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
          ),
      ],
      gcjEnabled: value['gcjEnabled'] as bool,
      skipLocalHistory: value['skipLocalHistory'] as bool,
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
        },
    ],
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
}
