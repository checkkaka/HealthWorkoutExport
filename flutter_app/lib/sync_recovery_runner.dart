import 'dart:convert';
import 'dart:typed_data';

import 'src/rust/api/simple.dart' as rust;
import 'sync_state_store.dart';
import 'workout_sport.dart';

/// Resumes only verified, durably saved bytes. No deletion is allowed before the
/// pending record and final FIT exist. Once remoteDeleted/uploading is durable,
/// the old remote ID is never deleted again.
final class SyncRecoveryRunner {
  SyncRecoveryRunner(
    this.store, {
    Duration Function()? elapsed,
    Future<void> Function(Duration duration)? delay,
    // Keep the injected clock private while retaining a readable constructor.
    // ignore: prefer_initializing_formals
  }) : _elapsed = elapsed,
       _delay = delay ?? ((duration) => Future<void>.delayed(duration));
  final SyncStateStore store;
  final Duration Function()? _elapsed;
  final Future<void> Function(Duration duration) _delay;

  Future<rust.StravaUploadFfiResponse> run({
    required String fingerprint,
    required Future<rust.StravaUploadFfiResponse> Function(
      RecoveryUploadData data,
      String externalId,
    )
    upload,
    required Future<void> Function(String remoteId) deleteRemote,
    bool Function()? cancelled,
    Future<bool?> Function(String remoteId)? remoteExists,
  }) async {
    void checkCancelled() {
      if (cancelled?.call() == true) throw const RecoveryCancelled();
    }

    checkCancelled();
    var transaction = await store.loadRecoveryTransaction(fingerprint);
    final data = RecoveryUploadData.fromJson(
      await store.readRecovery(fingerprint),
    );
    final record = (await store.allRecords())[fingerprint];
    // A crash after recording completion must only clean up. A freshly prepared
    // overwrite still has the old uploaded record and must not be mistaken for it.
    if (record is Map &&
        record['status'] == 'uploaded' &&
        transaction.phase == SyncRecoveryPhase.uploading &&
        (transaction.remoteIdToReplace == null ||
            record['remoteId'] != transaction.remoteIdToReplace)) {
      // A newly resumed queue can adopt this already-completed upload. Persist
      // its proof before removing the last recovery file, so a crash before the
      // queue checkpoint cannot lose per-destination completion.
      if (data.recoveryBatchId != null &&
          (record['recoveryBatchId'] != data.recoveryBatchId ||
              record['uploadExternalId'] != transaction.externalId)) {
        await store.markUploaded(
          fingerprint: fingerprint,
          updatedAt: DateTime.now(),
          remoteId: record['remoteId'] as String?,
          isDuplicate: record['isDuplicate'] == true,
          distanceMeters: (record['distanceMeters'] as num?)?.toDouble(),
          durationSeconds: (record['durationSeconds'] as num?)?.toDouble(),
          message: record['message'] as String?,
          uploadChannel: switch (record['uploadChannel']) {
            'api' => SyncUploadChannel.api,
            'web' => SyncUploadChannel.web,
            _ => null,
          },
          hasVirtualPower: record['hasVirtualPower'] as bool?,
          coordinatesWgs84: record['coordinatesWgs84'] as bool?,
          recoveryBatchId: data.recoveryBatchId,
          uploadExternalId: transaction.externalId,
        );
      }
      try {
        await store.deleteRecovery(fingerprint);
      } catch (_) {
        throw const RecoveryCleanupFailed();
      }
      return rust.StravaUploadFfiResponse(
        status: rust.StravaUploadFfiStatus.completed,
        remoteId: record['remoteId'] as String?,
        isDuplicate: record['isDuplicate'] == true,
      );
    }
    checkCancelled();
    await store.savePendingFit(
      record: data.pending(fingerprint),
      fit: data.fit,
    );
    checkCancelled();
    if (transaction.phase == SyncRecoveryPhase.prepared &&
        transaction.remoteIdToReplace != null) {
      await deleteRemote(transaction.remoteIdToReplace!);
      // Persist the successful delete even if cancellation arrived in flight.
      transaction = await store.markRecoveryRemoteDeleted(fingerprint);
    }
    checkCancelled();
    if (transaction.phase != SyncRecoveryPhase.uploading) {
      transaction = await store.markRecoveryUploading(fingerprint);
    }
    checkCancelled();
    var response = await upload(data, transaction.externalId);
    Stopwatch? ghostClock;
    Duration? injectedStart;
    var retries = 0;
    while (true) {
      if (response.status == rust.StravaUploadFfiStatus.cancelled) {
        throw const RecoveryCancelled();
      }
      if (response.status != rust.StravaUploadFfiStatus.completed) {
        throw const RecoveryIncomplete();
      }
      if (!response.isDuplicate || transaction.remoteIdToReplace == null) break;
      final duplicateId = response.remoteId;
      bool ghost = duplicateId == transaction.remoteIdToReplace;
      if (!ghost) {
        checkCancelled();
        if (duplicateId == null ||
            !RegExp(r'^[0-9]{1,32}$').hasMatch(duplicateId)) {
          throw const RecoveryUnverifiedDuplicate();
        }
        final exists = await remoteExists?.call(duplicateId);
        checkCancelled();
        if (exists == null) throw const RecoveryUnverifiedDuplicate();
        ghost = !exists;
      }
      if (!ghost) break;
      ghostClock ??= Stopwatch()..start();
      injectedStart ??= _elapsed?.call();
      Duration elapsed() => _elapsed == null
          ? ghostClock!.elapsed
          : _elapsed() - (injectedStart ?? Duration.zero);
      if (elapsed() >= const Duration(seconds: 10) || retries >= 5) {
        throw const RecoveryGhostDuplicate();
      }
      // Short waits make Stop responsive without starting a new POST or delete.
      for (var step = 0; step < 20; step++) {
        checkCancelled();
        await _delay(const Duration(milliseconds: 100));
      }
      checkCancelled();
      if (elapsed() >= const Duration(seconds: 10)) {
        throw const RecoveryGhostDuplicate();
      }
      transaction = await store.renewRecoveryExternalId(
        fingerprint,
        expectedExternalId: transaction.externalId,
      );
      checkCancelled();
      retries++;
      response = await upload(data, transaction.externalId);
    }
    // Do not lose a completed remote effect when Stop was pressed in flight.
    await store.markUploaded(
      fingerprint: fingerprint,
      updatedAt: DateTime.now(),
      remoteId: response.remoteId,
      isDuplicate: response.isDuplicate,
      distanceMeters: data.distanceMeters,
      durationSeconds: data.durationSeconds,
      message: response.error?.message ?? data.message,
      uploadChannel: data.channel,
      hasVirtualPower: data.hasVirtualPower,
      coordinatesWgs84: data.coordinatesWgs84,
      recoveryBatchId: data.recoveryBatchId,
      uploadExternalId: data.recoveryBatchId == null
          ? null
          : transaction.externalId,
    );
    try {
      await store.deleteRecovery(fingerprint);
    } catch (_) {
      throw const RecoveryCleanupFailed();
    }
    return response;
  }
}

final class RecoveryCleanupFailed implements Exception {
  const RecoveryCleanupFailed();
}

final class RecoveryGhostDuplicate implements Exception {
  const RecoveryGhostDuplicate();
}

final class RecoveryUnverifiedDuplicate implements Exception {
  const RecoveryUnverifiedDuplicate();
}

final class RecoveryCancelled implements Exception {
  const RecoveryCancelled();
}

final class RecoveryIncomplete implements Exception {
  const RecoveryIncomplete();
}

final class RecoveryUploadData {
  const RecoveryUploadData({
    required this.primarySourceId,
    required this.primaryActivityId,
    required this.title,
    required this.startDate,
    required this.supplementSourceIds,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.fit,
    required this.message,
    required this.filename,
    required this.commute,
    required this.channel,
    required this.hasVirtualPower,
    this.activityDescription,
    this.batchAt,
    this.coordinatesWgs84,
    this.sportType,
    this.recoveryBatchId,
  });
  factory RecoveryUploadData.fromJson(Uint8List bytes) {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('恢复上传包不是对象');
    }
    String text(String key) {
      final field = value[key];
      if (field is! String || field.trim().isEmpty) {
        throw FormatException('恢复上传包缺少 $key');
      }
      return field;
    }

    double number(String key) {
      final field = value[key];
      if (field is! num || !field.isFinite) {
        throw FormatException('恢复上传包的 $key 无效');
      }
      return field.toDouble();
    }

    final supplements = value['supplementSourceIds'];
    final message = value['uploadMessage'];
    final distance = value['distanceMeters'];
    final description = value['activityDescription'];
    final channel = value['uploadChannel'];
    final coordinates = value['coordinatesWgs84'];
    final sport = value['sportType'];
    if (sport != null &&
        (sport is! String ||
            !RegExp(r'^[A-Za-z][A-Za-z0-9]{0,63}$').hasMatch(sport))) {
      throw const FormatException('恢复运动类型无效');
    }
    final batchId = value['recoveryBatchId'];
    if ((coordinates != null && coordinates is! bool) ||
        (batchId != null &&
            (batchId is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(batchId)))) {
      throw const FormatException('恢复来源或批次标识无效');
    }
    if (channel != null && channel != 'api' && channel != 'web') {
      throw const FormatException('恢复上传通道未知，未执行任何网络操作');
    }
    if (supplements is! List ||
        supplements.any((item) => item is! String) ||
        (message != null && message is! String) ||
        (description != null && description is! String) ||
        (distance != null && (distance is! num || !distance.isFinite)) ||
        value['commute'] is! bool) {
      throw const FormatException('恢复上传包字段无效');
    }
    return RecoveryUploadData(
      primarySourceId: text('primarySourceId'),
      primaryActivityId: text('primaryActivityId'),
      title: text('title'),
      startDate: DateTime.fromMillisecondsSinceEpoch(
        ((number('startDate') + 978307200) * 1000).round(),
        isUtc: true,
      ),
      supplementSourceIds: supplements.cast<String>(),
      distanceMeters: distance?.toDouble(),
      durationSeconds: number('durationSeconds'),
      fit: Uint8List.fromList(base64Decode(text('uploadData'))),
      message: message as String?,
      filename: text('filename'),
      commute:
          normalizedWorkoutSport(
                sourceSportType(
                  value['primarySourceId'] as String?,
                  sportType: sport as String?,
                ),
              ) ==
              'Run'
          ? false
          : value['commute'] as bool,
      channel: value['uploadChannel'] == 'web'
          ? SyncUploadChannel.web
          : SyncUploadChannel.api,
      hasVirtualPower: value['hasVirtualPower'] == true,
      activityDescription: description as String?,
      coordinatesWgs84: coordinates as bool?,
      sportType: sourceSportType(
        value['primarySourceId'] as String?,
        sportType: sport,
      ),
      recoveryBatchId: batchId as String?,
      batchAt: value['batchAt'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (((value['batchAt'] as num).toDouble() + 978307200) * 1000)
                  .round(),
            )
          : null,
    );
  }
  final String primarySourceId;
  final String primaryActivityId;
  final String title;
  final DateTime startDate;
  final List<String> supplementSourceIds;
  final double? distanceMeters;
  final double durationSeconds;
  final Uint8List fit;
  final String? message;
  final String filename;
  final bool commute;
  final SyncUploadChannel channel;
  final bool hasVirtualPower;
  final String? activityDescription;
  final DateTime? batchAt;
  final bool? coordinatesWgs84;
  final String? sportType;
  final String? recoveryBatchId;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'primarySourceId': primarySourceId,
        'primaryActivityId': primaryActivityId,
        'title': title,
        'startDate': startDate.millisecondsSinceEpoch / 1000 - 978307200,
        'endDate':
            startDate.millisecondsSinceEpoch / 1000 -
            978307200 +
            durationSeconds,
        'supplementSourceIds': supplementSourceIds,
        'distanceMeters': distanceMeters,
        'durationSeconds': durationSeconds,
        'uploadData': base64Encode(fit),
        'uploadMessage': message,
        'filename': filename,
        'commute': commute,
        'uploadChannel': channel.name,
        'hasVirtualPower': hasVirtualPower,
        'activityDescription': activityDescription,
        if (coordinatesWgs84 != null) 'coordinatesWgs84': coordinatesWgs84,
        if (sportType != null) 'sportType': sportType,
        if (recoveryBatchId != null) 'recoveryBatchId': recoveryBatchId,
        if (batchAt != null)
          'batchAt': batchAt!.millisecondsSinceEpoch / 1000 - 978307200,
      }),
    ),
  );

  SyncPendingRecord pending(String fingerprint) => SyncPendingRecord(
    fingerprint: fingerprint,
    primarySourceId: primarySourceId,
    primaryActivityId: primaryActivityId,
    updatedAt: DateTime.now(),
    startDate: startDate,
    title: title,
    supplementSourceIds: supplementSourceIds,
    distanceMeters: distanceMeters,
    durationSeconds: durationSeconds,
    uploadChannel: channel,
    hasVirtualPower: hasVirtualPower,
    batchAt: batchAt,
    coordinatesWgs84: coordinatesWgs84,
    sportType: sportType,
    recoveryBatchId: recoveryBatchId,
  );
}
