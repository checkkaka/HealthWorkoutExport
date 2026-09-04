import 'package:flutter/foundation.dart';

import 'auto_sync_controller.dart';
import 'native_channels.dart';
import 'src/rust/api/simple.dart' as rust;
import 'workout_source.dart';

/// 全局单批次同步会话；页签切换不取消。
final class AutoSyncSession extends ChangeNotifier {
  AutoSyncSession({AutoSyncController? controller})
    : _controller = controller ?? AutoSyncController();

  static final instance = AutoSyncSession();

  final AutoSyncController _controller;
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

  void cancel() {
    cancelled = true;
    notifyListeners();
  }

  Future<AutoSyncResult> resumeRecovery(String fingerprint) =>
      _controller.resumeRecovery(fingerprint);

  Future<List<AutoSyncResult>> run({
    required WorkoutSource primary,
    required List<WorkoutSource> supplements,
    required List<WorkoutActivity> activities,
    bool gcjEnabled = false,
    rust.VirtualPowerFillInput? virtualPower,
    DuplicatePrompt? onDuplicate,
  }) async {
    if (isRunning) {
      throw const AutoSyncUploadException('已有同步批次在运行');
    }
    isRunning = true;
    cancelled = false;
    results = const [];
    notifyListeners();
    try {
      results = await _controller.syncBatch(
        primary: primary,
        supplements: supplements,
        activities: activities,
        gcjEnabled: gcjEnabled,
        virtualPower: virtualPower,
        onDuplicate: onDuplicate,
        cancelled: () => cancelled,
        onProgress: (value) {
          progress = value;
          notifyListeners();
        },
        upload: await _uploadForCurrentMode(),
      );
      return results;
    } finally {
      isRunning = false;
      notifyListeners();
    }
  }

  Future<AutoSyncUpload?> _uploadForCurrentMode() async {
    final settings = await const StravaSettingsStore().load();
    if (settings.mode != StravaUploadMode.web) return null;
    return ({
      required logicalOperationId,
      required fit,
      required externalId,
      required filename,
      required commute,
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
    };
  }
}
