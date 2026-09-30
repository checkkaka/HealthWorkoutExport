import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/sync_state_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/health-archive');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'Health-only preparation never changes uploaded Strava archive bytes or metadata',
    () async {
      final fp = 'a' * 64;
      final uploaded = Uint8List.fromList([1, 2, 3]);
      var archive = uploaded;
      Uint8List? healthPrepared;
      final state = {
        fp: {
          'fingerprint': fp,
          'status': 'uploaded',
          'remoteId': '42',
          'coordinatesWgs84': true,
        },
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'readState':
            return Uint8List.fromList(utf8.encode(jsonEncode(state)));
          case 'readSyncedFit':
            return archive;
          case 'writeSyncedFit':
            archive = (call.arguments as Map)['bytes'] as Uint8List;
            return null;
          case 'readHealthPreparedFit':
            if (healthPrepared == null) {
              throw PlatformException(code: 'sync_file_missing');
            }
            return healthPrepared;
          case 'writeHealthPreparedFit':
            healthPrepared = (call.arguments as Map)['bytes'] as Uint8List;
            return null;
          default:
            throw StateError('unexpected state mutation ${call.method}');
        }
      });
      final store = SyncStateStore.withDependencies(
        const SyncFilesChannel.withChannel(channel),
        ({required stateJson, required commandJson}) {
          expect(jsonDecode(utf8.decode(commandJson))['operation'], 'validate');
          return Uint8List.fromList(stateJson);
        },
      );
      await store.saveHealthFit(
        record: SyncPendingRecord(
          fingerprint: fp,
          primarySourceId: 'onelap',
          primaryActivityId: '1',
          updatedAt: DateTime.now(),
        ),
        fit: Uint8List.fromList([9, 8, 7]),
      );
      expect(archive, uploaded);
      expect(healthPrepared, Uint8List.fromList([9, 8, 7]));
      expect(state[fp]!['status'], 'uploaded');
      expect(state[fp]!['remoteId'], '42');
      expect(state[fp]!['coordinatesWgs84'], isTrue);
    },
  );
}
