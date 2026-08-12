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
}
