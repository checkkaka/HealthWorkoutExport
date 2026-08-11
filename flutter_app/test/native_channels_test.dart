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

    test('一次提交完整 Strava 授权', () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return null;
      });

      await const KeychainChannel().writeStravaAuthorization(
        clientId: '123',
        clientSecret: 'secret',
        accessToken: 'access',
        refreshToken: 'refresh',
        expiresAtSeconds: 42,
      );

      expect(received?.method, 'writeStravaAuthorization');
      expect(received?.arguments, {
        'clientId': '123',
        'clientSecret': 'secret',
        'accessToken': 'access',
        'refreshToken': 'refresh',
        'expiresAtSeconds': 42.0,
      });
    });
  });

  group('PreferencesChannel', () {
    const channel = MethodChannel('health_workout_export/preferences');

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('通过原生 UserDefaults 读写并删除旧应用键', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'read' ? true : null;
      });

      const preferences = PreferencesChannel();
      expect(await preferences.read('strava.gcjCorrectionEnabled'), isTrue);
      await preferences.write('strava.uploadMode', 'web');
      await preferences.delete('strava.expiresAt');

      expect(calls.map((call) => call.method), ['read', 'write', 'delete']);
      expect(calls[0].arguments, {'key': 'strava.gcjCorrectionEnabled'});
      expect(calls[1].arguments, {'key': 'strava.uploadMode', 'value': 'web'});
      expect(calls[2].arguments, {'key': 'strava.expiresAt'});
    });

    test('拒绝空键、未知键和 UserDefaults 不支持的对象', () async {
      const preferences = PreferencesChannel();

      expect(() => preferences.read(' '), throwsArgumentError);
      expect(() => preferences.read('arbitrary.key'), throwsArgumentError);
      expect(
        () => preferences.write('strava.uploadMode', const <String, String>{}),
        throwsArgumentError,
      );
    });
  });

  group('StravaSettingsStore', () {
    const keychainChannel = MethodChannel('health_workout_export/keychain');
    const preferencesChannel = MethodChannel(
      'health_workout_export/preferences',
    );

    tearDown(() async {
      messenger.setMockMethodCallHandler(keychainChannel, null);
      messenger.setMockMethodCallHandler(preferencesChannel, null);
    });

    test('读取并更新旧应用使用的原始设置键', () async {
      final secrets = <String, String>{
        'strava.clientId': '123',
        'strava.clientSecret': 'secret',
        'strava.accessToken': 'access',
        'strava.refreshToken': 'refresh',
        'strava.webCookie': 'cookie=value',
      };
      final preferences = <String, Object>{
        'strava.uploadMode': 'web',
        'strava.expiresAt': 42.0,
        'strava.gcjCorrectionEnabled': true,
      };
      messenger.setMockMethodCallHandler(keychainChannel, (call) async {
        final arguments = call.arguments! as Map<Object?, Object?>;
        if (call.method == 'writeStravaAuthorization') {
          secrets['strava.clientId'] = arguments['clientId']! as String;
          secrets['strava.clientSecret'] = arguments['clientSecret']! as String;
          secrets['strava.accessToken'] = arguments['accessToken']! as String;
          secrets['strava.refreshToken'] = arguments['refreshToken']! as String;
          preferences['strava.expiresAt'] = arguments['expiresAtSeconds']!;
          return null;
        }
        final key = arguments['account']! as String;
        if (call.method == 'read') return secrets[key];
        if (call.method == 'write') {
          secrets[key] = arguments['value']! as String;
        }
        if (call.method == 'delete') secrets.remove(key);
        return null;
      });
      messenger.setMockMethodCallHandler(preferencesChannel, (call) async {
        final arguments = call.arguments! as Map<Object?, Object?>;
        final key = arguments['key']! as String;
        if (call.method == 'read') return preferences[key];
        if (call.method == 'write') preferences[key] = arguments['value']!;
        if (call.method == 'delete') preferences.remove(key);
        return null;
      });

      const store = StravaSettingsStore();
      final snapshot = await store.load();
      expect(snapshot.mode, StravaUploadMode.web);
      expect(snapshot.clientId, '123');
      expect(snapshot.clientSecret, 'secret');
      expect(snapshot.accessToken, 'access');
      expect(snapshot.refreshToken, 'refresh');
      expect(snapshot.expiresAtSeconds, 42);
      expect(snapshot.webCookieHeader, 'cookie=value');
      expect(snapshot.gcjCorrectionEnabled, isTrue);
      expect(snapshot.isApiReady, isTrue);

      await store.saveAuthorization(
        clientId: ' 456 ',
        clientSecret: ' next ',
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
        expiresAtSeconds: 84,
      );
      await store.setMode(StravaUploadMode.api);
      await store.setGcjCorrectionEnabled(false);

      expect(secrets['strava.clientId'], '456');
      expect(secrets['strava.clientSecret'], 'next');
      expect(secrets['strava.accessToken'], 'new-access');
      expect(secrets['strava.refreshToken'], 'new-refresh');
      expect(secrets['strava.webCookie'], 'cookie=value');
      expect(preferences['strava.expiresAt'], 84.0);
      expect(preferences['strava.uploadMode'], 'api');
      expect(preferences['strava.gcjCorrectionEnabled'], isFalse);
    });

    test('拒绝空凭据和无效过期时间，非法旧模式回退 API', () async {
      const store = StravaSettingsStore();
      expect(
        () => store.saveAuthorization(
          clientId: ' ',
          clientSecret: 'secret',
          accessToken: 'access',
          refreshToken: 'refresh',
          expiresAtSeconds: 42,
        ),
        throwsArgumentError,
      );
      expect(
        () => store.saveAuthorization(
          clientId: '123',
          clientSecret: 'secret',
          accessToken: 'access',
          refreshToken: 'refresh',
          expiresAtSeconds: double.nan,
        ),
        throwsArgumentError,
      );

      messenger.setMockMethodCallHandler(keychainChannel, (_) async => null);
      messenger.setMockMethodCallHandler(preferencesChannel, (call) async {
        final arguments = call.arguments! as Map<Object?, Object?>;
        return arguments['key'] == 'strava.uploadMode' ? 'invalid' : null;
      });
      expect((await store.load()).mode, StravaUploadMode.api);
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

    test('生成与旧应用一致且正确编码的 Strava 授权地址', () {
      final url = StravaOAuthChannel.authorizationUri('123');

      expect(url.scheme, 'https');
      expect(url.host, 'www.strava.com');
      expect(url.path, '/oauth/mobile/authorize');
      expect(url.queryParameters, {
        'client_id': '123',
        'redirect_uri': 'healthworkoutexport://localhost/callback',
        'response_type': 'code',
        'approval_prompt': 'auto',
        'scope': 'activity:read_all,activity:write,read',
      });
      expect(
        () => StravaOAuthChannel.authorizationUri(' '),
        throwsArgumentError,
      );
    });

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
