import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/sync_history_logic.dart';
import 'package:health_workout_export/src/rust/api/simple.dart' as rust;

rust.StravaRemoteActivityResult remote(String id, double appleStart) =>
    rust.StravaRemoteActivityResult(
      id: id,
      startTimeSeconds: 978307200 + appleStart,
      endTimeSeconds: 978307200 + appleStart + 3600,
    );
void main() {
  test(
    'closest within strict120seconds wins, occupied and duplicate IDs never reused',
    () {
      final records = <String, Map<String, Object?>>{
        'occupied': {'remoteId': '9', 'startDate': 0},
        'a': {'startDate': 100},
        'b': {'startDate': 105},
        'c': {'startDate': 400},
      };
      final assigned = remoteIdAssignments(records, [
        remote('9', 100),
        remote('1', 103),
        remote('1', 105),
        remote('2', 119),
        remote('3', 520),
      ]);
      expect(assigned, {'a': '1', 'b': '2'});
    },
  );
  test('invalid remote IDs never written', () {
    expect(
      remoteIdAssignments(
        {
          'a': {'startDate': 0},
        },
        [remote('x', 0), remote('../42', 0)],
      ),
      isEmpty,
    );
  });
  test(
    'cycling thresholds exclude running and single uncorroborated peaks',
    () {
      rust.StravaActivitySpeedResult info({
        String sport = 'Ride',
        double listed = 0,
        double best = 0,
        double peak = 0,
        double average = 0,
      }) => rust.StravaActivitySpeedResult(
        id: '1',
        name: 'ride',
        sportType: sport,
        listedMaxSpeedMps: listed,
        bestEffortPeakMps: best,
        maxSpeedMps: peak,
        averageSpeedMps: average,
      );
      expect(isAnomalousStravaSpeed(info(listed: 80 / 3.6)), isTrue);
      expect(isAnomalousStravaSpeed(info(best: 80 / 3.6)), isTrue);
      expect(
        isAnomalousStravaSpeed(info(peak: 80 / 3.6, average: 40 / 3.6)),
        isTrue,
      );
      expect(isAnomalousStravaSpeed(info(peak: 1000, average: 5)), isFalse);
      expect(isAnomalousStravaSpeed(info(sport: 'Run', listed: 1000)), isFalse);
    },
  );
}
