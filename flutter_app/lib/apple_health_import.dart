import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;

/// Kept independent of generated Rust bindings so this flow is testable without
/// loading the native library. Callers wire these hooks to the native adapters
/// and the serialized SyncStateStore; only the three Health flags may change.
typedef HealthDraftDecoder =
    FutureOr<Uint8List> Function({
      required List<int> data,
      required String fingerprint,
    });
typedef FindNearbyHealthWorkouts =
    Future<List<HealthNearbyWorkout>> Function({
      required int startMs,
      required int endMs,
    });
typedef WriteHealthWorkout =
    Future<String> Function({required Uint8List draftJson});
typedef HealthRecordReader =
    Future<Map<String, Object?>?> Function(String fingerprint);
typedef MarkHealthWritten =
    Future<void> Function({
      required String fingerprint,
      required String uuid,
      required DateTime updatedAt,
    });
typedef MarkHealthSkipped =
    Future<void> Function({
      required String fingerprint,
      required DateTime updatedAt,
    });
typedef MarkHealthFailed =
    Future<void> Function({
      required String fingerprint,
      required String message,
      required DateTime updatedAt,
    });
typedef HealthNearbyDecisionHandler =
    Future<AppleHealthNearbyDecision> Function(AppleHealthNearbyPrompt prompt);

enum AppleHealthNearbyDecision {
  write,
  writeRestOfBatch,
  skip,
  skipRestOfBatch,
  skipOnce,
  cancelBatch,
}

enum AppleHealthImportOutcome { written, writtenWithWarning, skipped, failed }

final class AppleHealthNearbyPrompt {
  const AppleHealthNearbyPrompt({
    required this.activityTitle,
    required this.nearbySummary,
    this.nearby = const [],
  });
  final String activityTitle;
  final String nearbySummary;
  final List<HealthNearbyWorkout> nearby;
}

final class AppleHealthImportResult {
  const AppleHealthImportResult({
    required this.outcome,
    required this.message,
    this.uuid,
    this.error,
  });
  final AppleHealthImportOutcome outcome;
  final String message;
  final String? uuid;
  final Object? error;
}

final class AppleHealthImportCancelled implements Exception {
  const AppleHealthImportCancelled();
  @override
  String toString() => '已停止本批健康写入';
}

/// Lightweight read-only native summary. This type deliberately has no delete
/// operation: a nearby Apple Watch workout can never be overwritten by this pass.
final class HealthNearbyWorkout {
  const HealthNearbyWorkout({
    required this.uuid,
    required this.startMs,
    required this.endMs,
    required this.durationSeconds,
    this.distanceMeters,
    this.sourceName,
    this.syncIdentifier,
  });

  factory HealthNearbyWorkout.fromObject(Object? value) {
    if (value is! Map) throw const FormatException('健康训练摘要不是对象');
    final uuid = _requiredText(value, 'uuid');
    if (!_validUuid(uuid)) throw const FormatException('健康训练 UUID 无效');
    final startMs = _requiredMilliseconds(value, 'startMs');
    final endMs = _requiredMilliseconds(value, 'endMs');
    if (endMs < startMs) throw const FormatException('健康训练结束早于开始');
    return HealthNearbyWorkout(
      uuid: uuid,
      startMs: startMs,
      endMs: endMs,
      durationSeconds: _nonNegativeNumber(value, 'durationSeconds'),
      distanceMeters: value['distanceMeters'] == null
          ? null
          : _nonNegativeNumber(value, 'distanceMeters'),
      sourceName: _optionalText(value, 'sourceName'),
      syncIdentifier: _optionalText(value, 'syncIdentifier'),
    );
  }

  final String uuid;
  final int startMs;
  final int endMs;
  final double durationSeconds;
  final double? distanceMeters;
  final String? sourceName;
  final String? syncIdentifier;
}

/// The Swift HealthProximity / ActivityMatcher thresholds, including the IoU
/// branch before start-time and duration tolerance. Distance is not a filter.
abstract final class HealthProximity {
  static const maxStartDelta = Duration(minutes: 15);
  static const minOverlapRatio = 0.5;
  static const maxDurationRatio = 0.20;

  static HealthNearbyWorkout? alreadyImported({
    required String fingerprint,
    required List<HealthNearbyWorkout> nearby,
  }) {
    for (final candidate in nearby) {
      if (candidate.syncIdentifier == fingerprint) return candidate;
    }
    return null;
  }

  static List<HealthNearbyWorkout> overlapping({
    required DateTime start,
    required DateTime end,
    required double duration,
    required List<HealthNearbyWorkout> nearby,
  }) {
    final pStart = start.millisecondsSinceEpoch;
    final pEnd = end.millisecondsSinceEpoch;
    final pDuration = math.max(math.max((pEnd - pStart) / 1000, duration), 1.0);
    return nearby
        .where((candidate) {
          final overlap =
              math.min(pEnd, candidate.endMs) -
              math.max(pStart, candidate.startMs);
          if (overlap > 0) {
            final union =
                math.max(pEnd, candidate.endMs) -
                math.min(pStart, candidate.startMs);
            if (union > 0 && overlap / union >= minOverlapRatio) return true;
          }
          if ((pStart - candidate.startMs).abs() >
              maxStartDelta.inMilliseconds) {
            return false;
          }
          final cDuration = math.max(
            math.max(
              (candidate.endMs - candidate.startMs) / 1000,
              candidate.durationSeconds,
            ),
            1.0,
          );
          return (pDuration - cDuration).abs() /
                  math.max(pDuration, cDuration) <=
              maxDurationRatio;
        })
        .toList(growable: false);
  }
}

/// Sequential second pass for final, already-saved FIT bytes. It never contacts
/// a source account, changes Strava state, or deletes an existing workout.
///
/// Call beginBatch before a new batch; process records sequentially. Cancelling
/// stops later side effects, but a completed native write is always recorded.
final class AppleHealthImportPass {
  AppleHealthImportPass({
    required this.canWriteWorkouts,
    required this.requestWriteAuthorization,
    required this.findNearbyWorkouts,
    required this.writeWorkout,
    required this.decodeFitHealthDraft,
    required this.recordFor,
    required this.markWritten,
    required this.markSkipped,
    required this.markFailed,
    required this.onNearby,
    this.cancelled,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Future<bool> Function() canWriteWorkouts;
  final Future<void> Function() requestWriteAuthorization;
  final FindNearbyHealthWorkouts findNearbyWorkouts;
  final WriteHealthWorkout writeWorkout;
  final HealthDraftDecoder decodeFitHealthDraft;
  final HealthRecordReader recordFor;
  final MarkHealthWritten markWritten;
  final MarkHealthSkipped markSkipped;
  final MarkHealthFailed markFailed;
  final HealthNearbyDecisionHandler onNearby;
  final bool Function()? cancelled;
  final DateTime Function() _now;
  bool _writeRest = false;
  bool _skipRest = false;
  bool _authorizationReady = false;
  bool _cancelRequested = false;
  bool _processing = false;

  // If local persistence fails after a remote effect, retries on this pass must
  // retry persistence only, even when Health privacy hides that native workout.
  final Map<String, ({String uuid, bool partial})> _unpersistedWrites = {};

  void beginBatch() {
    if (_processing) throw StateError('健康写入尚未结束，无法重置批次');
    _writeRest = false;
    _skipRest = false;
    _authorizationReady = false;
    _cancelRequested = false;
  }

  void cancel() {
    _cancelRequested = true;
  }

  void _checkCancelled() {
    if (_cancelRequested || cancelled?.call() == true) {
      throw const AppleHealthImportCancelled();
    }
  }

  Future<AppleHealthImportResult> process({
    required String fingerprint,
    required Uint8List fit,
    required String title,
    required DateTime start,
    required DateTime end,
    required double duration,
    double? distance,
  }) async {
    if (_processing) throw StateError('请依次处理健康写入记录');
    _processing = true;
    var hasRecord = false;
    String? completedUuid;
    try {
      _checkCancelled();
      if (fingerprint.trim().isEmpty) {
        throw const FormatException('本地 FIT 指纹为空');
      }
      final record = await recordFor(fingerprint);
      _checkCancelled();
      if (record == null) throw const FormatException('找不到已保存的本地记录');
      hasRecord = true;
      final savedUuid = record['appleHealthUUID'];
      if ((savedUuid is String && savedUuid.isNotEmpty) ||
          record['appleHealthSkipped'] == true) {
        return AppleHealthImportResult(
          outcome: AppleHealthImportOutcome.skipped,
          message: '健康已处理，跳过：$title',
          uuid: savedUuid is String ? savedUuid : null,
        );
      }
      final pending = _unpersistedWrites[fingerprint];
      if (pending != null) {
        completedUuid = pending.uuid;
        await _persistWritten(
          fingerprint,
          pending.uuid,
          partial: pending.partial,
        );
        return _writtenResult(title, pending.uuid, partial: pending.partial);
      }
      if (fit.isEmpty) throw const FormatException('本地没有已保存 FIT');
      if (end.isBefore(start) ||
          !duration.isFinite ||
          duration < 0 ||
          (distance != null && (!distance.isFinite || distance < 0))) {
        throw const FormatException('本地训练时间或距离无效');
      }
      if (!_authorizationReady) {
        final available = await canWriteWorkouts();
        _checkCancelled();
        if (!available) throw const FormatException('当前平台不支持写入苹果健康');
        await requestWriteAuthorization();
        _checkCancelled();
        _authorizationReady = true;
      }
      final draftJson = await decodeFitHealthDraft(
        data: fit,
        fingerprint: fingerprint,
      );
      _checkCancelled();
      final draft = _HealthDraftReference.fromJson(draftJson, fingerprint);
      final nearby = await findNearbyWorkouts(
        startMs: draft.startMs - HealthProximity.maxStartDelta.inMilliseconds,
        endMs: draft.endMs + HealthProximity.maxStartDelta.inMilliseconds,
      );
      _checkCancelled();
      final ours = HealthProximity.alreadyImported(
        fingerprint: fingerprint,
        nearby: nearby,
      );
      if (ours != null) {
        if (!_validUuid(ours.uuid)) throw const FormatException('健康训练 UUID 无效');
        completedUuid = ours.uuid;
        _unpersistedWrites[fingerprint] = (uuid: ours.uuid, partial: false);
        await _persistWritten(fingerprint, ours.uuid);
        return AppleHealthImportResult(
          outcome: AppleHealthImportOutcome.skipped,
          message: '健康已有本 App 记录：$title',
          uuid: ours.uuid,
        );
      }
      final overlaps = HealthProximity.overlapping(
        start: DateTime.fromMillisecondsSinceEpoch(draft.startMs, isUtc: true),
        end: DateTime.fromMillisecondsSinceEpoch(draft.endMs, isUtc: true),
        duration: draft.duration,
        nearby: nearby,
      );
      var shouldWrite = overlaps.isEmpty || _writeRest;
      var persistSkip = false;
      if (overlaps.isNotEmpty && !_writeRest && !_skipRest) {
        final summary = overlaps
            .take(3)
            .map((item) {
              final minutes = (item.startMs - draft.startMs).abs() / 60000;
              return '${item.sourceName ?? '健康'}（开始差 ${minutes.toStringAsFixed(1)} 分钟）';
            })
            .join('、');
        final choice = await onNearby(
          AppleHealthNearbyPrompt(
            activityTitle: title,
            nearbySummary:
                '健康里已有接近训练：$summary。写入会多一条记录，不能覆盖或删除 Apple Watch 的数据。',
            nearby: List.unmodifiable(overlaps),
          ),
        );
        _checkCancelled();
        switch (choice) {
          case AppleHealthNearbyDecision.write:
            shouldWrite = true;
          case AppleHealthNearbyDecision.writeRestOfBatch:
            _writeRest = true;
            shouldWrite = true;
          case AppleHealthNearbyDecision.skip:
            shouldWrite = false;
            persistSkip = true;
          case AppleHealthNearbyDecision.skipRestOfBatch:
            _skipRest = true;
            shouldWrite = false;
            persistSkip = true;
          case AppleHealthNearbyDecision.skipOnce:
            shouldWrite = false;
          case AppleHealthNearbyDecision.cancelBatch:
            cancel();
            throw const AppleHealthImportCancelled();
        }
      } else if (overlaps.isNotEmpty && _skipRest) {
        shouldWrite = false;
        persistSkip = true;
      }
      _checkCancelled();
      if (!shouldWrite) {
        if (persistSkip) {
          await markSkipped(fingerprint: fingerprint, updatedAt: _now());
        }
        return AppleHealthImportResult(
          outcome: AppleHealthImportOutcome.skipped,
          message: persistSkip ? '已跳过健康写入：$title' : '本次未写健康：$title',
        );
      }
      String uuid;
      var partial = false;
      try {
        // Last cancellation barrier is immediately above the irreversible write.
        uuid = await writeWorkout(draftJson: draftJson);
      } on PlatformException catch (error) {
        final details = error.details;
        if (error.code != 'healthkit_write_partial' ||
            details is! Map ||
            details['fingerprint'] != fingerprint ||
            details['uuid'] is! String ||
            !_validUuid(details['uuid'] as String)) {
          rethrow;
        }
        uuid = details['uuid'] as String;
        partial = true;
      }
      if (!_validUuid(uuid)) throw const FormatException('健康写入返回的 UUID 无效');
      completedUuid = uuid;
      _unpersistedWrites[fingerprint] = (uuid: uuid, partial: partial);
      // Never check cancellation here: the external write already happened.
      await _persistWritten(fingerprint, uuid, partial: partial);
      return _writtenResult(title, uuid, partial: partial);
    } on AppleHealthImportCancelled {
      rethrow;
    } catch (error) {
      // Cancellation is not failure, except that a successful write whose local
      // persistence failed must still be reported, with its known native UUID.
      if (completedUuid == null) _checkCancelled();
      var message = completedUuid == null
          ? '健康写入失败：$title（$error）'
          : '训练已写入健康，但本地记录保存失败：$title（$error）；请勿重复写入';
      if (hasRecord && completedUuid == null) {
        try {
          await markFailed(
            fingerprint: fingerprint,
            message: message,
            updatedAt: _now(),
          );
        } catch (saveError) {
          message = '$message；错误状态保存失败：$saveError';
        }
      }
      return AppleHealthImportResult(
        outcome: AppleHealthImportOutcome.failed,
        message: message,
        uuid: completedUuid,
        error: error,
      );
    } finally {
      _processing = false;
    }
  }

  Future<void> _persistWritten(
    String fingerprint,
    String uuid, {
    bool partial = false,
  }) async {
    await markWritten(fingerprint: fingerprint, uuid: uuid, updatedAt: _now());
    if (partial) {
      // The UUID is already durable; this records a warning without clearing it
      // or changing the independent Strava upload status.
      await markFailed(
        fingerprint: fingerprint,
        message: '训练已写入，路线未完成/需检查',
        updatedAt: _now(),
      );
    }
    _unpersistedWrites.remove(fingerprint);
  }

  AppleHealthImportResult _writtenResult(
    String title,
    String uuid, {
    required bool partial,
  }) => AppleHealthImportResult(
    outcome: partial
        ? AppleHealthImportOutcome.writtenWithWarning
        : AppleHealthImportOutcome.written,
    message: partial ? '已写训练，路线未完成/需检查：$title' : '已写入健康：$title',
    uuid: uuid,
  );
}

final class _HealthDraftReference {
  const _HealthDraftReference(this.startMs, this.endMs, this.duration);
  factory _HealthDraftReference.fromJson(Uint8List bytes, String fingerprint) {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map || value['fingerprint'] != fingerprint) {
      throw const FormatException('健康 FIT 草稿指纹不匹配');
    }
    final startMs = _requiredMilliseconds(value, 'startMs');
    final endMs = _requiredMilliseconds(value, 'endMs');
    if (endMs < startMs) throw const FormatException('健康 FIT 草稿结束早于开始');
    if (value['distanceMeters'] != null) {
      _nonNegativeNumber(value, 'distanceMeters');
    }
    return _HealthDraftReference(
      startMs,
      endMs,
      _nonNegativeNumber(value, 'durationSeconds'),
    );
  }
  final int startMs;
  final int endMs;
  final double duration;
}

bool _validUuid(String value) => RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
).hasMatch(value);
String _requiredText(Map value, String key) {
  final field = value[key];
  if (field is! String || field.trim().isEmpty) {
    throw FormatException('健康训练 $key 为空');
  }
  return field;
}

String? _optionalText(Map value, String key) {
  final field = value[key];
  if (field == null) return null;
  if (field is! String) throw FormatException('健康训练 $key 无效');
  return field;
}

int _requiredMilliseconds(Map value, String key) {
  final field = value[key];
  if (field is! int || field.abs() > 8640000000000000 - 900000) {
    throw FormatException('健康训练 $key 无效');
  }
  return field;
}

double _nonNegativeNumber(Map value, String key) {
  final field = value[key];
  if (field is! num || !field.isFinite || field < 0) {
    throw FormatException('健康训练 $key 无效');
  }
  return field.toDouble();
}
