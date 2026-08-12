import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/sync_state_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methodChannel = MethodChannel('test/sync_files');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(methodChannel, null));

  test('损坏状态直接上抛且不调用 Rust、不覆盖原文件', () async {
    var applied = false;
    var writes = 0;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      if (call.method == 'readState') {
        throw PlatformException(code: 'sync_file_corrupt');
      }
      if (call.method == 'writeState') writes += 1;
      return null;
    });
    final store = SyncStateStore.withDependencies(
      const SyncFilesChannel.withChannel(methodChannel),
      ({required stateJson, required commandJson}) {
        applied = true;
        return Uint8List.fromList(utf8.encode('{}'));
      },
      ({required recoveryJson}) => Uint8List.fromList(recoveryJson),
    );

    await expectLater(
      store.markPending(
        SyncPendingRecord(
          fingerprint: 'a' * 64,
          primarySourceId: 'healthkit',
          primaryActivityId: 'activity-1',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(applied, isFalse);
    expect(writes, 0);
  });

  test('明确 missing 才创建空库，且并发转换按读取写入顺序串行', () async {
    Uint8List? state;
    var activeApplies = 0;
    var maximumActiveApplies = 0;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      if (call.method == 'readState') {
        if (state == null) throw PlatformException(code: 'sync_file_missing');
        return state;
      }
      if (call.method == 'writeState') {
        state =
            (call.arguments as Map<Object?, Object?>)['bytes']! as Uint8List;
      }
      return null;
    });
    final store = SyncStateStore.withDependencies(
      const SyncFilesChannel.withChannel(methodChannel),
      ({required stateJson, required commandJson}) {
        activeApplies += 1;
        maximumActiveApplies = maximumActiveApplies < activeApplies
            ? activeApplies
            : maximumActiveApplies;
        final current =
            jsonDecode(utf8.decode(stateJson)) as Map<String, dynamic>;
        final command =
            jsonDecode(utf8.decode(commandJson)) as Map<String, dynamic>;
        final record = command['record'] as Map<String, dynamic>;
        current[record['fingerprint']! as String] = record;
        activeApplies -= 1;
        return Uint8List.fromList(utf8.encode(jsonEncode(current)));
      },
      ({required recoveryJson}) => Uint8List.fromList(recoveryJson),
    );

    await Future.wait([
      for (final value in ['a', 'b'])
        store.markPending(
          SyncPendingRecord(
            fingerprint: value * 64,
            primarySourceId: 'healthkit',
            primaryActivityId: value,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          ),
        ),
    ]);
    expect((jsonDecode(utf8.decode(state!)) as Map).length, 2);
    expect(maximumActiveApplies, 1);
  });

  test('pending 状态写入失败时删除刚写入的同步 FIT', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call.method);
      if (call.method == 'readSyncedFit') {
        throw PlatformException(code: 'sync_file_missing');
      }
      if (call.method == 'readState') {
        throw PlatformException(code: 'sync_file_missing');
      }
      if (call.method == 'writeState') {
        throw PlatformException(code: 'sync_file_io');
      }
      return null;
    });
    final store = SyncStateStore.withDependencies(
      const SyncFilesChannel.withChannel(methodChannel),
      ({required stateJson, required commandJson}) =>
          Uint8List.fromList(utf8.encode('{}')),
      ({required recoveryJson}) => Uint8List.fromList(recoveryJson),
    );

    await expectLater(
      store.savePendingFit(
        record: SyncPendingRecord(
          fingerprint: 'e' * 64,
          primarySourceId: 'healthkit',
          primaryActivityId: 'activity-1',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
        fit: Uint8List.fromList(const [1, 2, 3]),
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(calls, [
      'readSyncedFit',
      'writeSyncedFit',
      'readState',
      'writeState',
      'deleteSyncedFit',
    ]);
  });

  test('附件删除失败时保留状态清单供下次重试', () async {
    final fingerprint = 'c' * 64;
    var state = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          fingerprint: {'fingerprint': fingerprint},
        }),
      ),
    );
    var recoveryAttempts = 0;
    var stateWrites = 0;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      switch (call.method) {
        case 'readState':
          return state;
        case 'deleteSyncedFit':
          return null;
        case 'deleteRecovery':
          recoveryAttempts += 1;
          if (recoveryAttempts == 1) {
            throw PlatformException(code: 'sync_file_io');
          }
          return null;
        case 'writeState':
          stateWrites += 1;
          state =
              (call.arguments as Map<Object?, Object?>)['bytes']! as Uint8List;
          return null;
      }
      return null;
    });
    final store = SyncStateStore.withDependencies(
      const SyncFilesChannel.withChannel(methodChannel),
      ({required stateJson, required commandJson}) {
        final command = jsonDecode(utf8.decode(commandJson)) as Map;
        return Uint8List.fromList(
          utf8.encode(
            command['operation'] == 'clear' ? '{}' : utf8.decode(stateJson),
          ),
        );
      },
      ({required recoveryJson}) => Uint8List.fromList(recoveryJson),
    );

    await expectLater(store.clear(), throwsA(isA<PlatformException>()));
    expect(stateWrites, 0);
    expect(
      (jsonDecode(utf8.decode(state)) as Map).containsKey(fingerprint),
      isTrue,
    );

    await store.clear();
    expect(stateWrites, 1);
    expect(recoveryAttempts, 2);
    expect(jsonDecode(utf8.decode(state)), isEmpty);
  });

  test('恢复阶段原子落盘并始终复用首次 externalId', () async {
    final fingerprint = 'd' * 64;
    Uint8List? recovery;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      switch (call.method) {
        case 'readRecovery':
          if (recovery == null) {
            throw PlatformException(code: 'sync_file_missing');
          }
          return recovery;
        case 'writeRecovery':
          recovery =
              (call.arguments as Map<Object?, Object?>)['bytes']! as Uint8List;
          return null;
      }
      return null;
    });
    Uint8List applyRecovery({
      required List<int> recoveryJson,
      required List<int> commandJson,
    }) {
      final value =
          jsonDecode(utf8.decode(recoveryJson)) as Map<String, dynamic>;
      final command =
          jsonDecode(utf8.decode(commandJson)) as Map<String, dynamic>;
      switch (command['operation']) {
        case 'prepare':
          value.putIfAbsent('phase', () => 'prepared');
          value.putIfAbsent('externalId', () => command['externalId']);
          value.putIfAbsent('fitSha256', () => 'e' * 64);
          value.putIfAbsent(
            'remoteIdToReplace',
            () => command['remoteIdToReplace'],
          );
          break;
        case 'markRemoteDeleted':
          if (value['phase'] != 'uploading') value['phase'] = 'remoteDeleted';
          break;
        case 'markUploading':
          value['phase'] = 'uploading';
          break;
      }
      return Uint8List.fromList(utf8.encode(jsonEncode(value)));
    }

    final store = SyncStateStore.withDependencies(
      const SyncFilesChannel.withChannel(methodChannel),
      ({required stateJson, required commandJson}) =>
          Uint8List.fromList(stateJson),
      ({required recoveryJson}) => Uint8List.fromList(recoveryJson),
      applyRecovery,
    );
    final legacy = Uint8List.fromList(utf8.encode('{"uploadData":"AQID"}'));
    final prepared = await store.prepareRecovery(
      fingerprint: fingerprint,
      recoveryJson: legacy,
      remoteIdToReplace: '123',
    );
    expect(prepared.phase, SyncRecoveryPhase.prepared);
    final externalId = prepared.externalId;
    final repeated = await store.prepareRecovery(
      fingerprint: fingerprint,
      recoveryJson: Uint8List.fromList(utf8.encode('{"uploadData":"BAUG"}')),
      remoteIdToReplace: '456',
    );
    expect(repeated.externalId, externalId);
    expect(utf8.decode(recovery!), contains('"uploadData":"AQID"'));

    final deleted = await store.markRecoveryRemoteDeleted(fingerprint);
    expect(deleted.phase, SyncRecoveryPhase.remoteDeleted);
    final uploading = await store.markRecoveryUploading(fingerprint);
    expect(uploading.phase, SyncRecoveryPhase.uploading);
    expect(uploading.externalId, externalId);
    final resumed = await store.loadRecoveryTransaction(fingerprint);
    expect(resumed.externalId, externalId);
    expect(resumed.fitSha256, 'e' * 64);
  });
}
