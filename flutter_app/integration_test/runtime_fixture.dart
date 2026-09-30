import 'dart:convert';
import 'dart:typed_data';

import 'package:health_workout_export/src/rust/api/simple.dart';

const _startMs = 1704067200000;

// These fixtures are invented. Every operation stays in memory; no HealthKit,
// source authentication, weather, upload, or remote deletion is involved.
Future<Uint8List> fixtureFit({bool sensors = true, int heartRate = 140}) {
  List<Map<String, Object>> samples(num first, num last) => [
    {'dateMs': _startMs, 'value': first},
    {'dateMs': _startMs + 60000, 'value': last},
  ];
  return encodeHealthWorkoutFit(
    bundleJson: utf8.encode(
      jsonEncode({
        'uuid': '123e4567-e89b-12d3-a456-426614174000',
        'startMs': _startMs,
        'endMs': _startMs + 60000,
        'durationSeconds': 50,
        'activityType': 13,
        'totalDistanceMeters': 1000,
        'totalEnergyKcal': 123,
        'events': [
          {'type': 'pause', 'dateMs': _startMs + 20000},
          {'type': 'resume', 'dateMs': _startMs + 30000},
        ],
        'series': sensors
            ? {
                'HKQuantityTypeIdentifierHeartRate': samples(
                  heartRate,
                  heartRate + 10,
                ),
                'HKQuantityTypeIdentifierCyclingCadence': samples(80, 90),
                'HKQuantityTypeIdentifierRunningPower': samples(200, 220),
              }
            : <String, Object>{},
        'route': [
          {
            'latitude': 31.2,
            'longitude': 121.5,
            'altitudeMeters': 12,
            'timestampMs': _startMs,
            'speedMetersPerSecond': 3.2,
          },
          {
            'latitude': 31.2001,
            'longitude': 121.5001,
            'altitudeMeters': 13,
            'timestampMs': _startMs + 60000,
            'speedMetersPerSecond': 3.4,
          },
        ],
      }),
    ),
    timezoneOffsetSeconds: 8 * 3600,
  );
}
