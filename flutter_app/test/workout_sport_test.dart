import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/workout_sport.dart';

void main() {
  test('running family matches runs but never cycles or unknown sport', () {
    expect(compatibleWorkoutSports('Run', 'TrailRun'), true);
    expect(compatibleWorkoutSports('Run', 'Ride'), false);
    expect(compatibleWorkoutSports('Run', null), false);
    expect(compatibleWorkoutSports(null, null), false);
    expect(compatibleWorkoutSports('Ride', 'VirtualRide'), true);
  });
  test(
    'explicit sport wins; fixed source fallback and HealthKit type are stable',
    () {
      expect(sourceSportType('keep'), 'Run');
      expect(sourceSportType('onelap'), 'Ride');
      expect(sourceSportType('healthkit'), null);
      expect(sourceSportType('keep', sportType: 'Walk'), 'Walk');
      expect(healthKitSportType(37), 'Run');
      expect(healthKitSportType(13), 'Ride');
      expect(healthKitSportType(999), null);
    },
  );
}
