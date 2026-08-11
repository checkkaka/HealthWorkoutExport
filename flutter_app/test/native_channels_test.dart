import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/native_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('KeychainChannel', () {
    const channel = MethodChannel('health_workout_export/keychain');

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('通过约定方法读写和删除非空键值', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'read' ? 'secret' : null;
      });

      const keychain = KeychainChannel();
      expect(await keychain.read('token'), 'secret');
      await keychain.write('token', 'updated');
      await keychain.delete('token');

      expect(calls.map((call) => call.method), ['read', 'write', 'delete']);
      expect(calls[0].arguments, {'account': 'token'});
      expect(calls[1].arguments, {'account': 'token', 'value': 'updated'});
      expect(calls[2].arguments, {'account': 'token'});
    });

    test('空白键和值在进入原生边界前被拒绝', () async {
      const keychain = KeychainChannel();

      expect(() => keychain.read('  '), throwsArgumentError);
      expect(() => keychain.write('token', ''), throwsArgumentError);
      expect(() => keychain.delete(''), throwsArgumentError);
    });
  });

  group('HealthKitChannel', () {
    const channel = MethodChannel('health_workout_export/healthkit');

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('检查可用性、请求授权并打开系统设置', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'isAvailable';
      });

      const healthKit = HealthKitChannel();
      expect(await healthKit.isAvailable(), isTrue);
      await healthKit.requestAuthorization();
      await healthKit.openSettings();

      expect(calls.map((call) => call.method), [
        'isAvailable',
        'requestAuthorization',
        'openSettings',
      ]);
      expect(calls.every((call) => call.arguments == null), isTrue);
    });

    test('用毫秒半开区间查询并解析完整训练摘要', () async {
      final start = DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true);
      final end = DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true);
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return <Object?>[
          <String, Object?>{
            'uuid': 'A4B64E8C-0012-4A0B-993E-140FC6B721C0',
            'startMs': 1100,
            'endMs': 2900,
            'durationSeconds': 1.8,
            'activityType': 13,
            'activityName': '骑车',
            'sourceName': 'Apple Watch',
            'sourceBundleId': 'com.apple.health',
            'totalEnergyKcal': 42,
            'totalDistanceMeters': 1234.5,
          },
        ];
      });

      final workouts = await const HealthKitChannel().listWorkouts(
        start: start,
        endExclusive: end,
      );

      expect(received?.method, 'listWorkouts');
      expect(received?.arguments, {'startMs': 1000, 'endMs': 3000});
      expect(workouts, const [
        HealthWorkoutSummary(
          uuid: 'A4B64E8C-0012-4A0B-993E-140FC6B721C0',
          startMs: 1100,
          endMs: 2900,
          durationSeconds: 1.8,
          activityType: 13,
          activityName: '骑车',
          sourceName: 'Apple Watch',
          sourceBundleId: 'com.apple.health',
          totalEnergyKcal: 42,
          totalDistanceMeters: 1234.5,
        ),
      ]);
    });

    test('保留可选统计空值并拒绝无效范围或畸形摘要', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => [
          <String, Object?>{
            'uuid': 'workout-id',
            'startMs': 1000,
            'endMs': 2000,
            'durationSeconds': 1,
            'activityType': 1,
            'activityName': '跑步',
            'sourceName': null,
            'sourceBundleId': null,
            'totalEnergyKcal': null,
            'totalDistanceMeters': null,
          },
        ],
      );
      final healthKit = const HealthKitChannel();

      final workouts = await healthKit.listWorkouts(
        start: DateTime.fromMillisecondsSinceEpoch(1000),
        endExclusive: DateTime.fromMillisecondsSinceEpoch(2000),
      );
      expect(workouts.single.totalEnergyKcal, isNull);
      expect(workouts.single.totalDistanceMeters, isNull);

      expect(
        () => healthKit.listWorkouts(
          start: DateTime.fromMillisecondsSinceEpoch(2000),
          endExclusive: DateTime.fromMillisecondsSinceEpoch(2000),
        ),
        throwsArgumentError,
      );

      messenger.setMockMethodCallHandler(
        channel,
        (_) async => [
          <String, Object?>{'uuid': 'missing-fields'},
        ],
      );
      expect(
        () => healthKit.listWorkouts(
          start: DateTime.fromMillisecondsSinceEpoch(1000),
          endExclusive: DateTime.fromMillisecondsSinceEpoch(2000),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('按 UUID 批量读取并解析完整训练明细', () async {
      const uuid = 'A4B64E8C-0012-4A0B-993E-140FC6B721C0';
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return <Object?>[
          <String, Object?>{
            'uuid': uuid,
            'startMs': 1000,
            'endMs': 2000,
            'durationSeconds': 1,
            'activityType': 13,
            'activityName': '骑车',
            'sourceName': 'Apple Watch',
            'sourceBundleId': 'com.apple.health',
            'totalEnergyKcal': 42,
            'totalDistanceMeters': 1234.5,
            'metadata': <String, Object?>{'HKIndoorWorkout': 'true'},
            'events': <Object?>[
              <String, Object?>{'type': 'pause', 'dateMs': 1250},
            ],
            'series': <String, Object?>{
              'HKQuantityTypeIdentifierHeartRate': <Object?>[
                <String, Object?>{
                  'dateMs': 1300,
                  'value': 143,
                  'unit': 'count/min',
                },
              ],
            },
            'route': <Object?>[
              <String, Object?>{
                'latitude': 31.34,
                'longitude': 120.55,
                'altitudeMeters': 8.5,
                'timestampMs': 1400,
                'speedMetersPerSecond': 4.2,
              },
            ],
          },
        ];
      });

      final bundles = await const HealthKitChannel().fetchWorkoutBundles([
        uuid,
      ]);

      expect(received?.method, 'fetchWorkoutBundles');
      expect(received?.arguments, {
        'uuids': [uuid],
      });
      final bundle = bundles.single;
      expect(bundle.summary.uuid, uuid);
      expect(bundle.metadata, {'HKIndoorWorkout': 'true'});
      expect(
        bundle.events.single,
        const HealthWorkoutEvent(type: 'pause', dateMs: 1250),
      );
      expect(
        bundle.series['HKQuantityTypeIdentifierHeartRate']?.single,
        const HealthQuantitySample(dateMs: 1300, value: 143, unit: 'count/min'),
      );
      expect(
        bundle.route.single,
        const HealthRoutePoint(
          latitude: 31.34,
          longitude: 120.55,
          altitudeMeters: 8.5,
          timestampMs: 1400,
          speedMetersPerSecond: 4.2,
        ),
      );
    });

    test('完整训练明细拒绝空 UUID、重复 UUID 和错序响应', () async {
      const first = 'A4B64E8C-0012-4A0B-993E-140FC6B721C0';
      const second = 'C369A834-FF0B-4D46-BB79-39246FA8A589';
      const healthKit = HealthKitChannel();

      expect(
        () => healthKit.fetchWorkoutBundles(const []),
        throwsArgumentError,
      );
      expect(
        () => healthKit.fetchWorkoutBundles(const [first, first]),
        throwsArgumentError,
      );
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => [_bundlePayload(second), _bundlePayload(first)],
      );
      expect(
        () => healthKit.fetchWorkoutBundles(const [first, second]),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('StravaOAuthChannel', () {
    const channel = MethodChannel('health_workout_export/strava_oauth');

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('仅把固定 Strava HTTPS 授权地址交给原生并返回授权码', () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return 'authorization-code';
      });
      final url = Uri.https('www.strava.com', '/oauth/mobile/authorize', {
        'client_id': '123',
        'redirect_uri': 'healthworkoutexport://localhost/callback',
      });

      expect(
        await const StravaOAuthChannel().authorize(url),
        'authorization-code',
      );
      expect(received?.method, 'authorize');
      expect(received?.arguments, {
        'authorizationUrl': url.toString(),
        'callbackScheme': 'healthworkoutexport',
      });
    });

    test('拒绝非 Strava 地址和空授权码', () async {
      const oauth = StravaOAuthChannel();
      expect(
        () => oauth.authorize(
          Uri.parse('https://evil.example/oauth/mobile/authorize'),
        ),
        throwsArgumentError,
      );

      messenger.setMockMethodCallHandler(channel, (_) async => '');
      expect(
        () => oauth.authorize(
          Uri.parse('https://www.strava.com/oauth/mobile/authorize'),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

Map<String, Object?> _bundlePayload(String uuid) => {
  'uuid': uuid,
  'startMs': 1000,
  'endMs': 2000,
  'durationSeconds': 1,
  'activityType': 13,
  'activityName': '骑车',
  'sourceName': null,
  'sourceBundleId': null,
  'totalEnergyKcal': null,
  'totalDistanceMeters': null,
  'metadata': <String, Object?>{},
  'events': <Object?>[],
  'series': <String, Object?>{},
  'route': <Object?>[],
};
