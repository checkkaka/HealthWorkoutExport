import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/src/rust/api/simple.dart' as rust;
import 'package:health_workout_export/sync_recovery_runner.dart';
import 'package:health_workout_export/sync_state_store.dart';

const fingerprint =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  setUp(() {
    h = Harness();
  });
  tearDown(() {
    h.dispose();
  });
  test(
    'first upload saves pending FIT and uploading phase before network and preserves description',
    () async {
      final response = await h.run();
      expect(response.remoteId, '222');
      expect(h.events, [
        'fit',
        'pending',
        'uploading',
        'upload:stable',
        'uploaded',
        'cleanup',
      ]);
      expect(h.description, 'virtual power note');
      expect(h.recovery, isNull);
    },
  );
  test(
    'overwrite saves bytes before deletion, then persists deletion before upload',
    () async {
      h.seed(remote: '111');
      h.state[fingerprint] = {'status': 'uploaded', 'remoteId': '111'};
      await h.run();
      expect(h.events, [
        'fit',
        'pending',
        'delete:111',
        'remoteDeleted',
        'uploading',
        'upload:stable',
        'uploaded',
        'cleanup',
      ]);
    },
  );
  for (final phase in ['remoteDeleted', 'uploading']) {
    test('recovered $phase never deletes old activity again', () async {
      h.seed(remote: '111', phase: phase);
      await h.run();
      expect(h.events.where((s) => s.startsWith('delete:')), isEmpty);
      expect(h.events, contains('upload:stable'));
    });
  }
  test('invalid recovery integrity stops before saving or deleting', () async {
    h.seed(remote: '111');
    h.rejectRecovery = true;
    await expectLater(h.run(), throwsFormatException);
    expect(h.events, isEmpty);
  });
  test(
    'pending write failure prevents remote deletion and rolls back new FIT',
    () async {
      h.seed(remote: '111');
      h.failPending = true;
      await expectLater(h.run(), throwsStateError);
      expect(h.events, ['fit', 'pending', 'rollback-fit']);
      expect(h.fit, isNull);
    },
  );
  test(
    'delete failure leaves prepared transaction and never uploads',
    () async {
      h.seed(remote: '111');
      h.failDelete = true;
      await expectLater(h.run(), throwsStateError);
      expect(h.recovery!['phase'], 'prepared');
      expect(h.events, ['fit', 'pending', 'delete:111']);
    },
  );
  test(
    'cancellation during successful delete still persists remoteDeleted; resume does not delete again',
    () async {
      h.seed(remote: '111');
      h.cancelAfterDelete = true;
      await expectLater(h.run(), throwsA(isA<RecoveryCancelled>()));
      expect(h.recovery!['phase'], 'remoteDeleted');
      expect(h.events, ['fit', 'pending', 'delete:111', 'remoteDeleted']);
      h.cancelled = false;
      h.cancelAfterDelete = false;
      h.events.clear();
      await h.run();
      expect(h.events.where((s) => s.startsWith('delete:')), isEmpty);
    },
  );
  test(
    'failed upload retains exact external ID and uploading phase for retry',
    () async {
      h.failUpload = true;
      await expectLater(h.run(), throwsA(isA<RecoveryIncomplete>()));
      expect(h.recovery!['phase'], 'uploading');
      h.failUpload = false;
      await h.run();
      expect(h.events.where((s) => s.startsWith('upload:')), [
        'upload:stable',
        'upload:stable',
      ]);
    },
  );
  test(
    'cleanup failure keeps completed record; next resume only cleans',
    () async {
      h.failCleanup = true;
      await expectLater(h.run(), throwsA(isA<RecoveryCleanupFailed>()));
      expect(h.state[fingerprint]!['status'], 'uploaded');
      h.failCleanup = false;
      h.events.clear();
      await h.run();
      expect(h.events, ['cleanup']);
    },
  );
  test('cancel before reading cannot mutate or invoke remote calls', () async {
    h.cancelled = true;
    await expectLater(h.run(), throwsA(isA<RecoveryCancelled>()));
    expect(h.events, isEmpty);
  });
  test(
    'completion state failure retains upload intent for idempotent replay',
    () async {
      h.failCompleted = true;
      await expectLater(h.run(), throwsStateError);
      expect(h.recovery!['externalId'], 'stable');
      expect(h.recovery!['phase'], 'uploading');
      h.failCompleted = false;
      await h.run();
      expect(h.events.where((s) => s.startsWith('upload:')).length, 2);
    },
  );
}

final class Harness {
  Harness() {
    seed();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map?;
          switch (call.method) {
            case 'readState':
              return bytes(state);
            case 'writeState':
              state = Map<String, Map<String, dynamic>>.from(
                (jsonDecode(utf8.decode(args!['bytes'] as Uint8List)) as Map)
                    .map(
                      (k, v) => MapEntry(
                        k as String,
                        Map<String, dynamic>.from(v as Map),
                      ),
                    ),
              );
              return null;
            case 'readRecovery':
              if (recovery == null) {
                throw PlatformException(code: 'sync_file_missing');
              }
              return bytes(recovery);
            case 'writeRecovery':
              recovery =
                  jsonDecode(utf8.decode(args!['bytes'] as Uint8List))
                      as Map<String, dynamic>;
              events.add(recovery!['phase'] as String);
              return null;
            case 'readSyncedFit':
              if (fit == null) {
                throw PlatformException(code: 'sync_file_missing');
              }
              return fit;
            case 'writeSyncedFit':
              fit = args!['bytes'] as Uint8List;
              events.add('fit');
              return null;
            case 'deleteSyncedFit':
              fit = null;
              events.add('rollback-fit');
              return null;
            case 'deleteRecovery':
              events.add('cleanup');
              if (failCleanup) throw StateError('cleanup');
              recovery = null;
              return null;
          }
          throw MissingPluginException(call.method);
        });
    store = SyncStateStore.withDependencies(
      const SyncFilesChannel.withChannel(channel),
      ({required stateJson, required commandJson}) {
        final current =
            jsonDecode(utf8.decode(stateJson)) as Map<String, dynamic>;
        final command =
            jsonDecode(utf8.decode(commandJson)) as Map<String, dynamic>;
        switch (command['operation']) {
          case 'validate':
            break;
          case 'markPending':
            events.add('pending');
            if (failPending) throw StateError('pending');
            current[fingerprint] = command['record'];
          case 'markUploaded':
            events.add('uploaded');
            if (failCompleted) throw StateError('uploaded');
            current[fingerprint] = {
              ...current[fingerprint] as Map,
              ...command['update'] as Map,
              'status': 'uploaded',
            };
          default:
            throw StateError('unexpected command');
        }
        return bytes(current);
      },
      ({required recoveryJson}) {
        if (rejectRecovery) throw const FormatException('invalid FIT/hash');
        return Uint8List.fromList(recoveryJson);
      },
      ({required recoveryJson, required commandJson}) {
        if (rejectRecovery) throw const FormatException('invalid FIT/hash');
        final value =
            jsonDecode(utf8.decode(recoveryJson)) as Map<String, dynamic>;
        final command = jsonDecode(utf8.decode(commandJson)) as Map;
        if (command['operation'] == 'markRemoteDeleted') {
          value['phase'] = 'remoteDeleted';
        }
        if (command['operation'] == 'markUploading') {
          value['phase'] = 'uploading';
        }
        return bytes(value);
      },
    );
  }
  static const channel = MethodChannel('test/recovery-runner');
  late final SyncStateStore store;
  Map<String, Map<String, dynamic>> state = {};
  Map<String, dynamic>? recovery;
  Uint8List? fit;
  final events = <String>[];
  bool rejectRecovery = false,
      failPending = false,
      failDelete = false,
      failUpload = false,
      failCleanup = false,
      failCompleted = false,
      cancelled = false,
      cancelAfterDelete = false;
  String? description;
  static Uint8List bytes(Object? value) =>
      Uint8List.fromList(utf8.encode(jsonEncode(value)));
  void seed({String? remote, String phase = 'prepared'}) {
    recovery = {
      'primarySourceId': 'healthkit',
      'primaryActivityId': 'activity',
      'title': 'ride',
      'startDate': 0,
      'endDate': 3600,
      'supplementSourceIds': <String>[],
      'durationSeconds': 3600,
      'uploadData': 'AQID',
      'filename': 'activity.fit',
      'commute': false,
      'uploadChannel': 'api',
      'hasVirtualPower': true,
      'activityDescription': 'virtual power note',
      'phase': phase,
      'externalId': 'stable',
      'fitSha256': 'e' * 64,
      'remoteIdToReplace': remote,
    };
  }

  Future<rust.StravaUploadFfiResponse> run() => SyncRecoveryRunner(store).run(
    fingerprint: fingerprint,
    cancelled: () => cancelled,
    deleteRemote: (id) async {
      events.add('delete:$id');
      if (failDelete) throw StateError('delete');
      if (cancelAfterDelete) cancelled = true;
    },
    upload: (data, externalId) async {
      events.add('upload:$externalId');
      description = data.activityDescription;
      return rust.StravaUploadFfiResponse(
        status: failUpload
            ? rust.StravaUploadFfiStatus.failed
            : rust.StravaUploadFfiStatus.completed,
        remoteId: '222',
        isDuplicate: false,
      );
    },
  );
  void dispose() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null);
}
