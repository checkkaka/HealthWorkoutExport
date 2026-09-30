import 'dart:convert';
import 'dart:typed_data';

import 'src/rust/api/simple.dart' as rust;
import 'sync_state_store.dart';

/// Resumes only verified, durably saved bytes. No deletion is allowed before the
/// pending record and final FIT exist. Once remoteDeleted/uploading is durable,
/// the old remote ID is never deleted again.
final class SyncRecoveryRunner {
  const SyncRecoveryRunner(this.store);
  final SyncStateStore store;

  Future<rust.StravaUploadFfiResponse> run({
    required String fingerprint,
    required Future<rust.StravaUploadFfiResponse> Function(
      RecoveryUploadData data,
      String externalId,
    )
    upload,
    required Future<void> Function(String remoteId) deleteRemote,
    bool Function()? cancelled,
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
        (transaction.remoteIdToReplace == null ||
            (transaction.phase == SyncRecoveryPhase.uploading &&
                record['remoteId'] != transaction.remoteIdToReplace))) {
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
    final response = await upload(data, transaction.externalId);
    if (response.status == rust.StravaUploadFfiStatus.cancelled) {
      throw const RecoveryCancelled();
    }
    if (response.status != rust.StravaUploadFfiStatus.completed) {
      throw const RecoveryIncomplete();
    }
    // Do not lose a completed remote effect when Stop was pressed in flight.
    await store.markUploaded(
      fingerprint: fingerprint,
      updatedAt: DateTime.now(),
      remoteId: response.remoteId,
      isDuplicate: response.isDuplicate,
      distanceMeters: data.distanceMeters,
      durationSeconds: data.durationSeconds,
      message: data.message,
      uploadChannel: data.channel,
      hasVirtualPower: data.hasVirtualPower,
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
      commute: value['commute'] as bool,
      channel: value['uploadChannel'] == 'web'
          ? SyncUploadChannel.web
          : SyncUploadChannel.api,
      hasVirtualPower: value['hasVirtualPower'] == true,
      activityDescription: description as String?,
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
  );
}
