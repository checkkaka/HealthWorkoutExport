import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import 'src/rust/api/simple.dart' as rust;

typedef SyncStateApply =
    Uint8List Function({
      required List<int> stateJson,
      required List<int> commandJson,
    });
typedef SyncRecoveryCodec =
    Uint8List Function({required List<int> recoveryJson});
typedef SyncRecoveryApply =
    Uint8List Function({
      required List<int> recoveryJson,
      required List<int> commandJson,
    });

/// iOS 上复用旧应用的 Application Support 文件；其他平台接入等价插件时复用同一契约。
final class SyncFilesChannel {
  const SyncFilesChannel()
    : _channel = const MethodChannel('health_workout_export/sync_files');

  const SyncFilesChannel.withChannel(this._channel);

  final MethodChannel _channel;

  Future<Uint8List> readState() => _read('readState');

  Future<void> writeState(Uint8List bytes) => _write('writeState', bytes);

  Future<void> deleteState() => _channel.invokeMethod<void>('deleteState');

  Future<Uint8List> readSyncedFit(String fingerprint) =>
      _read('readSyncedFit', fingerprint);

  Future<void> writeSyncedFit(String fingerprint, Uint8List bytes) =>
      _write('writeSyncedFit', bytes, fingerprint);

  Future<void> deleteSyncedFit(String fingerprint) => _channel
      .invokeMethod<void>('deleteSyncedFit', {'fingerprint': fingerprint});

  Future<Uint8List> readRecovery(String fingerprint) =>
      _read('readRecovery', fingerprint);

  Future<void> writeRecovery(String fingerprint, Uint8List bytes) =>
      _write('writeRecovery', bytes, fingerprint);

  Future<void> deleteRecovery(String fingerprint) => _channel
      .invokeMethod<void>('deleteRecovery', {'fingerprint': fingerprint});

  Future<Uint8List> _read(String method, [String? fingerprint]) async {
    final bytes = await _channel.invokeMethod<Uint8List>(method, {
      'fingerprint': ?fingerprint,
    });
    if (bytes == null) throw const FormatException('原生同步文件返回空数据');
    return bytes;
  }

  Future<void> _write(String method, Uint8List bytes, [String? fingerprint]) =>
      _channel.invokeMethod<void>(method, {
        'fingerprint': ?fingerprint,
        'bytes': bytes,
      });
}

enum SyncUploadChannel { api, web }

final class SyncPendingRecord {
  const SyncPendingRecord({
    required this.fingerprint,
    required this.primarySourceId,
    required this.primaryActivityId,
    required this.updatedAt,
    this.startDate,
    this.title,
    this.supplementSourceIds,
    this.distanceMeters,
    this.durationSeconds,
    this.batchAt,
  });

  final String fingerprint;
  final String primarySourceId;
  final String primaryActivityId;
  final DateTime updatedAt;
  final DateTime? startDate;
  final String? title;
  final List<String>? supplementSourceIds;
  final double? distanceMeters;
  final double? durationSeconds;
  final DateTime? batchAt;

  Map<String, Object?> toJson() => {
    'fingerprint': fingerprint,
    'status': 'pending',
    'primarySourceId': primarySourceId,
    'primaryActivityId': primaryActivityId,
    'updatedAt': _appleSeconds(updatedAt),
    if (startDate != null) 'startDate': _appleSeconds(startDate!),
    if (title != null) 'title': title,
    if (supplementSourceIds != null) 'supplementSourceIds': supplementSourceIds,
    if (distanceMeters != null) 'distanceMeters': distanceMeters,
    if (durationSeconds != null) 'durationSeconds': durationSeconds,
    if (batchAt != null) 'batchAt': _appleSeconds(batchAt!),
  };
}

/// 串行执行原生读取 → Rust 校验/转换 → 原生原子写，防止并发更新互相覆盖。
final class SyncStateStore {
  SyncStateStore()
    : _files = const SyncFilesChannel(),
      _applyRust = rust.syncStateApply,
      _recoveryCodec = rust.syncRecoveryReencode,
      _applyRecoveryRust = rust.syncRecoveryApply;

  SyncStateStore.withDependencies(
    this._files,
    this._applyRust, [
    this._recoveryCodec = rust.syncRecoveryReencode,
    this._applyRecoveryRust = rust.syncRecoveryApply,
  ]);

  final SyncFilesChannel _files;
  final SyncStateApply _applyRust;
  final SyncRecoveryCodec _recoveryCodec;
  final SyncRecoveryApply _applyRecoveryRust;
  Future<void> _tail = Future<void>.value();

  Future<Map<String, Object?>> allRecords() => _serialized(() async {
    final validated = _applyRust(
      stateJson: await _readStateOrEmpty(),
      commandJson: _command({'operation': 'validate'}),
    );
    final value = jsonDecode(utf8.decode(validated));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Rust 同步状态不是对象');
    }
    return Map<String, Object?>.unmodifiable(value);
  });

  Future<void> markPending(SyncPendingRecord record) =>
      _mutate({'operation': 'markPending', 'record': record.toJson()});

  Future<void> markUploaded({
    required String fingerprint,
    required DateTime updatedAt,
    String? remoteId,
    bool isDuplicate = false,
    double? distanceMeters,
    double? durationSeconds,
    String? message,
    SyncUploadChannel? uploadChannel,
    bool? hasVirtualPower,
  }) => _mutate({
    'operation': 'markUploaded',
    'update': {
      'fingerprint': fingerprint,
      'updatedAt': _appleSeconds(updatedAt),
      'remoteId': remoteId,
      'isDuplicate': isDuplicate,
      'distanceMeters': distanceMeters,
      'durationSeconds': durationSeconds,
      'message': message,
      'uploadChannel': uploadChannel?.name,
      'hasVirtualPower': hasVirtualPower,
    },
  });

  Future<void> markDeduped({
    required String fingerprint,
    required DateTime updatedAt,
    required String reason,
    String? remoteId,
  }) => _mutate({
    'operation': 'markDeduped',
    'fingerprint': fingerprint,
    'updatedAt': _appleSeconds(updatedAt),
    'reason': reason,
    'remoteId': remoteId,
  });

  Future<void> markFailed({
    required String fingerprint,
    required DateTime updatedAt,
    required String message,
  }) => _mutate({
    'operation': 'markFailed',
    'fingerprint': fingerprint,
    'updatedAt': _appleSeconds(updatedAt),
    'message': message,
  });

  Future<void> remove(String fingerprint) => _serialized(() async {
    await _files.deleteSyncedFit(fingerprint);
    await _files.deleteRecovery(fingerprint);
    await _mutateUnlocked({'operation': 'remove', 'fingerprint': fingerprint});
  });

  Future<void> clear() => _serialized(() async {
    final state = await _readStateOrEmpty();
    final decoded =
        jsonDecode(
              utf8.decode(
                _applyRust(
                  stateJson: state,
                  commandJson: _command({'operation': 'validate'}),
                ),
              ),
            )
            as Map<String, dynamic>;
    for (final fingerprint in decoded.keys) {
      await _files.deleteSyncedFit(fingerprint);
      await _files.deleteRecovery(fingerprint);
    }
    final cleared = _applyRust(
      stateJson: state,
      commandJson: _command({'operation': 'clear'}),
    );
    await _files.writeState(cleared);
  });

  Future<Uint8List> readRecovery(String fingerprint) => _serialized(() async {
    final bytes = await _files.readRecovery(fingerprint);
    return _recoveryCodec(recoveryJson: bytes);
  });

  Future<void> writeRecovery(String fingerprint, Uint8List bytes) =>
      _serialized(() async {
        final validated = _recoveryCodec(recoveryJson: bytes);
        await _files.writeRecovery(fingerprint, validated);
      });

  Future<void> deleteRecovery(String fingerprint) =>
      _serialized(() => _files.deleteRecovery(fingerprint));

  /// 首次落盘生成一次 externalId；后续重复调用始终保留已落盘值。
  Future<SyncRecoveryTransaction> prepareRecovery({
    required String fingerprint,
    required Uint8List recoveryJson,
    String? remoteIdToReplace,
  }) => _serialized(() async {
    final source = await _readRecoveryOrInitial(fingerprint, recoveryJson);
    final updated = _applyRecoveryRust(
      recoveryJson: source,
      commandJson: _command({
        'operation': 'prepare',
        'externalId': '$fingerprint-resync-${_randomHex(16)}',
        'remoteIdToReplace': remoteIdToReplace,
      }),
    );
    await _files.writeRecovery(fingerprint, updated);
    return SyncRecoveryTransaction.fromJson(updated);
  });

  Future<Uint8List> _readRecoveryOrInitial(
    String fingerprint,
    Uint8List initial,
  ) async {
    try {
      return await _files.readRecovery(fingerprint);
    } on PlatformException catch (error) {
      if (error.code == 'sync_file_missing') return initial;
      rethrow;
    }
  }

  Future<SyncRecoveryTransaction> loadRecoveryTransaction(String fingerprint) =>
      _serialized(() async {
        final updated = _applyRecoveryRust(
          recoveryJson: await _files.readRecovery(fingerprint),
          commandJson: _command({'operation': 'validate'}),
        );
        return SyncRecoveryTransaction.fromJson(updated);
      });

  /// 远端删除成功后立即持久化；重复执行不会倒退 uploading 阶段。
  Future<SyncRecoveryTransaction> markRecoveryRemoteDeleted(
    String fingerprint,
  ) => _advanceRecovery(fingerprint, 'markRemoteDeleted');

  /// 上传调用前持久化；崩溃恢复必须复用返回的同一个 externalId。
  Future<SyncRecoveryTransaction> markRecoveryUploading(String fingerprint) =>
      _advanceRecovery(fingerprint, 'markUploading');

  Future<SyncRecoveryTransaction> _advanceRecovery(
    String fingerprint,
    String operation,
  ) => _serialized(() async {
    final updated = _applyRecoveryRust(
      recoveryJson: await _files.readRecovery(fingerprint),
      commandJson: _command({'operation': operation}),
    );
    await _files.writeRecovery(fingerprint, updated);
    return SyncRecoveryTransaction.fromJson(updated);
  });

  Future<void> _mutate(Map<String, Object?> command) =>
      _serialized(() => _mutateUnlocked(command));

  Future<void> _mutateUnlocked(Map<String, Object?> command) async {
    final updated = _applyRust(
      stateJson: await _readStateOrEmpty(),
      commandJson: _command(command),
    );
    await _files.writeState(updated);
  }

  Future<Uint8List> _readStateOrEmpty() async {
    try {
      return await _files.readState();
    } on PlatformException catch (error) {
      if (error.code == 'sync_file_missing') {
        return Uint8List.fromList(utf8.encode('{}'));
      }
      rethrow;
    }
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return (() async {
      await previous;
      try {
        return await action();
      } finally {
        done.complete();
      }
    })();
  }

  static Uint8List _command(Map<String, Object?> value) =>
      Uint8List.fromList(utf8.encode(jsonEncode(value)));
}

enum SyncRecoveryPhase { prepared, remoteDeleted, uploading }

final class SyncRecoveryTransaction {
  const SyncRecoveryTransaction({
    required this.phase,
    required this.externalId,
    required this.fitSha256,
    required this.remoteIdToReplace,
  });

  factory SyncRecoveryTransaction.fromJson(Uint8List bytes) {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('恢复事务不是 JSON 对象');
    }
    final phase = switch (value['phase']) {
      'prepared' => SyncRecoveryPhase.prepared,
      'remoteDeleted' => SyncRecoveryPhase.remoteDeleted,
      'uploading' => SyncRecoveryPhase.uploading,
      _ => throw const FormatException('恢复事务阶段缺失或未知'),
    };
    final externalId = value['externalId'];
    final fitSha256 = value['fitSha256'];
    final remoteId = value['remoteIdToReplace'];
    if (externalId is! String ||
        externalId.isEmpty ||
        fitSha256 is! String ||
        fitSha256.length != 64 ||
        (remoteId != null && remoteId is! String)) {
      throw const FormatException('恢复事务元数据不完整');
    }
    return SyncRecoveryTransaction(
      phase: phase,
      externalId: externalId,
      fitSha256: fitSha256,
      remoteIdToReplace: remoteId as String?,
    );
  }

  final SyncRecoveryPhase phase;
  final String externalId;
  final String fitSha256;
  final String? remoteIdToReplace;
}

String _randomHex(int byteCount) {
  final random = Random.secure();
  return List.generate(
    byteCount,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    growable: false,
  ).join();
}

double _appleSeconds(DateTime value) =>
    value.toUtc().microsecondsSinceEpoch / Duration.microsecondsPerSecond -
    978307200.0;
