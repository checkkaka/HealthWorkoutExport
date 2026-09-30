import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/auto_sync_checkpoint.dart';

Map<String, Object?> configuration() => {
  'primary': 'onelap',
  'supplements': ['healthkit'],
  'gcjEnabled': true,
  'skipLocalHistory': false,
  'mode': 'web',
  'activities': [
    {
      'id': '1',
      'title': 'ride',
      'startMs': 1700000000000,
      'endMs': 1700003600000,
      'durationSeconds': 3600,
      'distanceMeters': 10000,
    },
  ],
  'virtualPower': {
    'riderMassKg': 70,
    'bikeMassKg': 8.5,
    'cda': 0.3,
    'includeInertia': true,
  },
};
void main() {
  test(
    'round trip retains source, options, range and completed progress without credentials',
    () {
      final original = AutoSyncCheckpoint(
        configuration: configuration(),
        completedIds: {'1'},
      );
      final bytes = original.encode();
      final saved = AutoSyncCheckpoint.decode(bytes);
      expect(saved.configuration, original.configuration);
      expect(saved.completedIds, {'1'});
      expect(utf8.decode(bytes), isNot(contains('token')));
    },
  );
  test(
    'unknown source, invalid date, duplicate or mismatched activity IDs rejected',
    () {
      for (final mutate in <void Function(Map<String, Object?>)>[
        (c) => c['primary'] = 'unknown',
        (c) => (c['activities'] as List).add((c['activities'] as List).first),
        (c) => ((c['activities'] as List).first as Map)['endMs'] = 0,
        (c) => c['supplements'] = ['onelap'],
        (c) => c['mode'] = 'unknown',
        (c) => (c['virtualPower'] as Map)['cda'] = 0,
      ]) {
        final config = configuration();
        mutate(config);
        expect(
          () => AutoSyncCheckpoint(
            configuration: config,
            completedIds: {},
          ).encode(),
          throwsFormatException,
        );
      }
      expect(
        () => AutoSyncCheckpoint(
          configuration: configuration(),
          completedIds: {'other'},
        ).encode(),
        throwsFormatException,
      );
    },
  );
  test(
    'unknown root, configuration, activity and power fields cannot persist credentials',
    () {
      for (final mutate in <void Function(Map<String, Object?>)>[
        (c) => c['accessToken'] = 'placeholder',
        (c) =>
            ((c['activities'] as List).first as Map)['cookie'] = 'placeholder',
        (c) => (c['virtualPower'] as Map)['password'] = 'placeholder',
      ]) {
        final config = configuration();
        mutate(config);
        expect(
          () => AutoSyncCheckpoint(
            configuration: config,
            completedIds: {},
          ).encode(),
          throwsFormatException,
        );
      }
      final encoded = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'configuration': configuration(),
            'completedIds': [],
            'refreshToken': 'placeholder',
          }),
        ),
      );
      expect(() => AutoSyncCheckpoint.decode(encoded), throwsFormatException);
    },
  );
  test('oversize and malformed snapshots fail closed', () {
    for (final value in [
      Uint8List(AutoSyncCheckpoint.maxBytes + 1),
      Uint8List.fromList(utf8.encode('{broken')),
      Uint8List.fromList(utf8.encode(jsonEncode({'version': 99}))),
    ]) {
      expect(() => AutoSyncCheckpoint.decode(value), throwsFormatException);
    }
  });
}
