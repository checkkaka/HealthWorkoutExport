import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// A recovery generation checkpoints each target separately. Aggregate progress
/// is derived, never used as evidence that a remote side effect did not happen.
final class RecoveryBatchCheckpoint {
  RecoveryBatchCheckpoint({
    required List<String> fingerprints,
    required this.replaceExisting,
    this.uploadToStrava = true,
    this.writeToHealth = false,
    this.customTitle,
    String? generationId,
    Map<String, String?> stravaCompleted = const {},
    Set<String> healthCompleted = const {},
  }) : fingerprints = List.unmodifiable(fingerprints),
       generationId = generationId ?? newGenerationId(),
       stravaCompleted = Map.unmodifiable(stravaCompleted),
       healthCompleted = Set.unmodifiable(healthCompleted);
  final List<String> fingerprints;
  final bool replaceExisting, uploadToStrava, writeToHealth;
  final String? customTitle;
  final String generationId;
  final Map<String, String?> stravaCompleted;
  final Set<String> healthCompleted;
  late final Set<String> completed = Set.unmodifiable(
    fingerprints.where((id) => !needsStrava(id) && !needsHealth(id)),
  );
  bool needsStrava(String id) =>
      uploadToStrava && !stravaCompleted.containsKey(id);
  bool needsHealth(String id) => writeToHealth && !healthCompleted.contains(id);

  RecoveryBatchCheckpoint _copy({
    Map<String, String?>? strava,
    Set<String>? health,
  }) => RecoveryBatchCheckpoint(
    fingerprints: fingerprints,
    replaceExisting: replaceExisting,
    uploadToStrava: uploadToStrava,
    writeToHealth: writeToHealth,
    customTitle: customTitle,
    generationId: generationId,
    stravaCompleted: strava ?? stravaCompleted,
    healthCompleted: health ?? healthCompleted,
  );
  RecoveryBatchCheckpoint markStrava(String id, String? remoteId) {
    if (!fingerprints.contains(id) ||
        remoteId != null && !RegExp(r'^[0-9]{1,32}$').hasMatch(remoteId)) {
      throw const FormatException('恢复成功记录无效');
    }
    return _copy(strava: {...stravaCompleted, id: remoteId});
  }

  RecoveryBatchCheckpoint markHealth(String id) {
    if (!fingerprints.contains(id)) throw const FormatException('恢复健康记录无效');
    return _copy(health: {...healthCompleted, id});
  }

  RecoveryBatchCheckpoint reconcileUploaded(
    String id,
    Map<String, Object?>? record,
  ) {
    if (!needsStrava(id) ||
        record?['status'] != 'uploaded' ||
        record?['recoveryBatchId'] != generationId) {
      return this;
    }
    final external = record?['uploadExternalId'];
    if (external is! String ||
        external.trim().isEmpty ||
        utf8.encode(external).length > 8192 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(external)) {
      return this;
    }
    final remote = record?['remoteId'];
    if (remote != null && remote is! String) {
      throw const FormatException('恢复成功远端 ID 无效');
    }
    return markStrava(id, remote as String?);
  }

  RecoveryBatchCheckpoint reconcileHealth(
    String id,
    Map<String, Object?>? record,
  ) {
    if (!needsHealth(id)) return this;
    final uuid = record?['appleHealthUUID'];
    if (record?['appleHealthSkipped'] == true ||
        uuid is String &&
            RegExp(
              r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
            ).hasMatch(uuid)) {
      return markHealth(id);
    }
    return this;
  }

  RecoveryBatchCheckpoint retryAll() => RecoveryBatchCheckpoint(
    fingerprints: fingerprints,
    replaceExisting: replaceExisting,
    uploadToStrava: uploadToStrava,
    writeToHealth: writeToHealth,
    customTitle: customTitle,
  );

  Uint8List encode() {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 2,
          'kind': 'recovery',
          'fingerprints': fingerprints,
          'generationId': generationId,
          'stravaCompleted': stravaCompleted,
          'healthCompleted': healthCompleted.toList()..sort(),
          'replaceExisting': replaceExisting,
          'uploadToStrava': uploadToStrava,
          'writeToHealth': writeToHealth,
          'customTitle': customTitle,
        }),
      ),
    );
    RecoveryBatchCheckpoint.decode(bytes);
    return bytes;
  }

  factory RecoveryBatchCheckpoint.decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 4 * 1024 * 1024) {
      throw const FormatException('恢复队列大小无效');
    }
    final value = jsonDecode(utf8.decode(bytes));
    const keys = {
      'version',
      'kind',
      'fingerprints',
      'generationId',
      'stravaCompleted',
      'healthCompleted',
      'replaceExisting',
      'uploadToStrava',
      'writeToHealth',
      'customTitle',
    };
    if (value is! Map ||
        value.keys.any((key) => !keys.contains(key)) ||
        value['version'] != 2 ||
        value['kind'] != 'recovery' ||
        value['fingerprints'] is! List ||
        value['stravaCompleted'] is! Map ||
        value['healthCompleted'] is! List ||
        value['replaceExisting'] is! bool ||
        value['uploadToStrava'] is! bool ||
        value['writeToHealth'] is! bool) {
      throw const FormatException('恢复队列缺少逐目标进度；请重新选择记录，未执行网络操作');
    }
    final pattern = RegExp(r'^[a-f0-9]{64}$');
    final generation = value['generationId'];
    if (generation is! String || !pattern.hasMatch(generation)) {
      throw const FormatException('恢复批次标识无效');
    }
    final ids = value['fingerprints'] as List;
    final strava = value['stravaCompleted'] as Map;
    final health = value['healthCompleted'] as List;
    if (ids.isEmpty ||
        ids.length > 10000 ||
        ids.any((id) => id is! String || !pattern.hasMatch(id)) ||
        ids.toSet().length != ids.length ||
        health.toSet().length != health.length ||
        health.any((id) => !ids.contains(id)) ||
        strava.entries.any(
          (e) =>
              !ids.contains(e.key) ||
              e.value != null &&
                  (e.value is! String ||
                      !RegExp(r'^[0-9]{1,32}$').hasMatch(e.value as String)),
        )) {
      throw const FormatException('恢复队列目标进度无效');
    }
    if (value['uploadToStrava'] == false && value['writeToHealth'] != true) {
      throw const FormatException('恢复目标无效');
    }
    final title = value['customTitle'];
    if (title != null &&
        (title is! String ||
            utf8.encode(title).length > 8192 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(title))) {
      throw const FormatException('恢复标题无效');
    }
    return RecoveryBatchCheckpoint(
      fingerprints: ids.cast<String>(),
      generationId: generation,
      replaceExisting: value['replaceExisting'] as bool,
      uploadToStrava: value['uploadToStrava'] as bool,
      writeToHealth: value['writeToHealth'] as bool,
      customTitle: title as String?,
      stravaCompleted: Map<String, String?>.from(strava),
      healthCompleted: health.cast<String>().toSet(),
    );
  }
  static String newGenerationId() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

enum LegacyRecoveryDecision { uploadOnly, replaceRemote, skip, stop }

final class LegacyRecoveryPrompt {
  const LegacyRecoveryPrompt({required this.title, required this.remoteId});
  final String title;
  final String? remoteId;
}

typedef LegacyRecoveryChooser =
    Future<LegacyRecoveryDecision> Function(LegacyRecoveryPrompt prompt);

Set<String> completedBeforeRetry(
  Set<String> completed,
  List<String> retryIds,
) => completed.difference(retryIds.toSet());
