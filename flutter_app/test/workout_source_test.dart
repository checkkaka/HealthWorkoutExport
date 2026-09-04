import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/date_range.dart';
import 'package:health_workout_export/workout_source.dart';

const _uuid = 'A4B64E8C-0012-4A0B-993E-140FC6B721C0';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const healthChannel = MethodChannel('health_workout_export/healthkit');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(healthChannel, null));

  test('健康源把摘要列表映射为统一活动并按 bundle 编码 FIT', () async {
    messenger.setMockMethodCallHandler(healthChannel, (call) async {
      return switch (call.method) {
        'isAvailable' => true,
        'listWorkouts' => [
          {
            'uuid': _uuid,
            'startMs': 1704067200000,
            'endMs': 1704070800000,
            'durationSeconds': 3600.0,
            'activityType': 13,
            'activityName': '骑车',
            'sourceName': 'Apple Watch',
            'sourceBundleId': 'com.apple.health',
            'totalEnergyKcal': 42.0,
            'totalDistanceMeters': 1234.5,
          },
        ],
        'fetchWorkoutBundles' => [
          {
            'uuid': _uuid,
            'startMs': 1704067200000,
            'endMs': 1704070800000,
            'durationSeconds': 3600.0,
            'activityType': 13,
            'activityName': '骑车',
            'sourceName': 'Apple Watch',
            'sourceBundleId': 'com.apple.health',
            'totalEnergyKcal': 42.0,
            'totalDistanceMeters': 1234.5,
            'metadata': <String, Object?>{},
            'events': <Object?>[],
            'series': <String, Object?>{},
            'route': <Object?>[],
          },
        ],
        _ => throw MissingPluginException(call.method),
      };
    });

    final encoded = <String>[];
    final source = HealthKitWorkoutSource(
      fitEncoder: ({required bundleJson, required timezoneOffsetSeconds}) async {
        encoded.add(utf8.decode(bundleJson));
        return Uint8List.fromList(const [0x0E]);
      },
    );
    expect(source.id, WorkoutSourceId.healthkit);
    expect(await source.isAuthenticated(), isTrue);
    final activities = await source.listActivities(
      DateInterval(
        DateTime.fromMillisecondsSinceEpoch(1704067200000),
        DateTime.fromMillisecondsSinceEpoch(1704070800000),
      ),
    );
    expect(activities, hasLength(1));
    expect(activities.single.id, _uuid);
    expect(activities.single.title, '骑车');
    expect(await source.fetchFit(activities.single), Uint8List.fromList(const [0x0E]));
    expect(encoded.single, contains(_uuid));
  });
}
