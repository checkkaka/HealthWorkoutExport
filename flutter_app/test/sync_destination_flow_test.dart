import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/sync_destination_flow.dart';

void main() {
  test(
    'unsupported health writer ignores saved preference and completes Strava',
    () async {
      const savedHealthPreference = true;
      var healthCalls = 0;
      final result = await runSyncDestinations(
        ids: ['android-activity'],
        uploadToStrava: true,
        writeToHealth: healthWriteEnabled(
          requested: savedHealthPreference,
          canWriteHealth: false,
          sourceIsHealth: false,
        ),
        runStrava: () async => {'android-activity': true},
        runHealth: () async {
          healthCalls++;
          return {'android-activity': false};
        },
      );

      expect(result.completedIds, {'android-activity'});
      expect(result.health, isEmpty);
      expect(healthCalls, 0);
    },
  );

  test('capable Apple writer preserves an enabled preference', () {
    expect(
      healthWriteEnabled(
        requested: true,
        canWriteHealth: true,
        sourceIsHealth: false,
      ),
      isTrue,
    );
  });

  test('health source never writes its activities back to health', () {
    expect(
      healthWriteEnabled(
        requested: true,
        canWriteHealth: true,
        sourceIsHealth: true,
      ),
      isFalse,
    );
  });

  test('capable Apple writer preserves an opted-out preference', () {
    expect(
      healthWriteEnabled(
        requested: false,
        canWriteHealth: true,
        sourceIsHealth: false,
      ),
      isFalse,
    );
  });

  test('health-only never executes Strava and completes written IDs', () async {
    final calls = <String>[];
    final result = await runSyncDestinations(
      ids: ['a'],
      uploadToStrava: false,
      writeToHealth: true,
      runStrava: () async {
        calls.add('strava');
        return {'a': true};
      },
      runHealth: () async {
        calls.add('health');
        return {'a': true};
      },
    );
    expect(calls, ['health']);
    expect(result.completedIds, {'a'});
  });
  test(
    'both targets complete only IDs successful at each requested target',
    () async {
      final calls = <String>[];
      final result = await runSyncDestinations(
        ids: ['a', 'b'],
        uploadToStrava: true,
        writeToHealth: true,
        runStrava: () async {
          calls.add('strava');
          return {'a': true, 'b': false};
        },
        runHealth: () async {
          calls.add('health');
          return {'a': true, 'b': true};
        },
      );
      expect(calls, ['strava', 'health']);
      expect(result.completedIds, {'a'});
    },
  );
  test(
    'cancel between targets starts no health operation and keeps batch incomplete',
    () async {
      var cancelled = false;
      var healthCalls = 0;
      final result = await runSyncDestinations(
        ids: ['a'],
        uploadToStrava: true,
        writeToHealth: true,
        cancelled: () => cancelled,
        runStrava: () async {
          cancelled = true;
          return {'a': true};
        },
        runHealth: () async {
          healthCalls++;
          return {'a': true};
        },
      );
      expect(healthCalls, 0);
      expect(result.completedIds, isEmpty);
      expect(result.strava, {'a': true});
    },
  );
  test('no destination is rejected before any effects', () async {
    await expectLater(
      runSyncDestinations(
        ids: ['a'],
        uploadToStrava: false,
        writeToHealth: false,
        runStrava: () async => {},
        runHealth: () async => {},
      ),
      throwsArgumentError,
    );
  });
}
