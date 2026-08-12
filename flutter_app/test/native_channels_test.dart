import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/native_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('StravaVaultChannel', () {
    const channel = MethodChannel('health_workout_export/keychain');

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('只暴露安全状态、按用途租约、typed commit 与 typed clear', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'stravaStatus' => <String, Object?>{
            'clientId': '123',
            'hasClientSecret': true,
            'hasAccessToken': true,
            'hasRefreshToken': true,
            'expiresAtSeconds': 42.0,
          },
          'stravaLease'
              when (call.arguments! as Map<Object?, Object?>)['purpose'] ==
                  'refresh' =>
            <String, Object?>{
              'clientId': '123',
              'clientSecret': 'secret',
              'refreshToken': 'refresh',
              'expiresAtSeconds': 42.0,
            },
          'stravaLease' => <String, Object?>{
            'accessToken': 'access',
            'expiresAtSeconds': 42.0,
          },
          _ => null,
        };
      });

      const vault = StravaVaultChannel();
      final status = await vault.status();
      expect(status.clientId, '123');
      expect(status.hasClientSecret, isTrue);
      expect(status.hasAccessToken, isTrue);
      expect(status.hasRefreshToken, isTrue);
      expect(status.expiresAtSeconds, 42);

      final refresh = await vault.lease(StravaLeasePurpose.refresh);
      expect(refresh.clientId, '123');
      expect(refresh.clientSecret, 'secret');
      expect(refresh.refreshToken, 'refresh');
      expect(refresh.accessToken, isNull);
      expect(refresh.toString(), isNot(contains('secret')));
      expect(refresh.toString(), isNot(contains('refresh-token')));
      final upload = await vault.lease(StravaLeasePurpose.upload);
      expect(upload.accessToken, 'access');
      expect(upload.clientSecret, isNull);
      expect(upload.refreshToken, isNull);

      await vault.commitAuthorization(
        clientId: '123',
        clientSecret: 'secret',
        accessToken: 'access',
        refreshToken: 'refresh',
        expiresAtSeconds: 42,
      );
      await vault.clearAuthorization();

      expect(calls.map((call) => call.method), [
        'stravaStatus',
        'stravaLease',
        'stravaLease',
        'writeStravaAuthorization',
        'clearStravaAuthorization',
      ]);
      expect(calls[3].arguments, {
        'clientId': '123',
        'clientSecret': 'secret',
        'accessToken': 'access',
        'refreshToken': 'refresh',
        'expiresAtSeconds': 42.0,
      });
      expect(calls[4].arguments, isNull);
    });

    test('秘密参数校验错误与租约字符串不会泄漏秘密', () async {
      expect(
        () => const StravaVaultChannel().commitAuthorization(
          clientId: '123',
          clientSecret: 'highly-sensitive-client-secret',
          accessToken: '',
          refreshToken: 'highly-sensitive-refresh-token',
          expiresAtSeconds: 42,
        ),
        throwsA(
          predicate(
            (error) =>
                !error.toString().contains('highly-sensitive-client-secret') &&
                !error.toString().contains('highly-sensitive-refresh-token'),
          ),
        ),
      );
    });
  });

  group('ThirdPartyVaultChannel', () {
    const channel = MethodChannel('health_workout_export/third_party_vault');

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('行者和顽鹿只通过固定 typed 方法读写凭据', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'xingzheStatus' => <String, Object?>{
            'hasAccount': true,
            'hasPassword': true,
            'hasSessionId': true,
          },
          'xingzheLease' => <String, Object?>{
            'account': 'xingzhe-account',
            'password': 'xingzhe-password',
            'sessionId': 'xingzhe-session',
          },
          'onelapStatus' => <String, Object?>{
            'hasAccount': true,
            'hasPassword': true,
            'hasToken': true,
            'hasUid': true,
          },
          'onelapLease' => <String, Object?>{
            'account': 'onelap-account',
            'password': 'onelap-password',
            'token': 'onelap-token',
            'uid': '42',
          },
          _ => null,
        };
      });

      const xingzhe = XingzheVaultChannel();
      expect((await xingzhe.status()).isConfigured, isTrue);
      expect(
        (await xingzhe.lease()).toString(),
        isNot(contains('xingzhe-password')),
      );
      await xingzhe.commitAuthorization(
        account: 'xingzhe-account',
        password: 'xingzhe-password',
        sessionId: 'xingzhe-session',
      );
      await xingzhe.clearAuthorization();

      const onelap = OnelapVaultChannel();
      expect((await onelap.status()).isConfigured, isTrue);
      expect(
        (await onelap.lease()).toString(),
        isNot(contains('onelap-token')),
      );
      await onelap.commitAuthorization(
        account: 'onelap-account',
        password: 'onelap-password',
        token: 'onelap-token',
        uid: '42',
      );
      await onelap.clearAuthorization();

      expect(calls.map((call) => call.method), [
        'xingzheStatus',
        'xingzheLease',
        'writeXingzheAuthorization',
        'clearXingzheAuthorization',
        'onelapStatus',
        'onelapLease',
        'writeOnelapAuthorization',
        'clearOnelapAuthorization',
      ]);
      expect(calls[2].arguments, {
        'account': 'xingzhe-account',
        'password': 'xingzhe-password',
        'sessionId': 'xingzhe-session',
      });
      expect(calls[6].arguments, {
        'account': 'onelap-account',
        'password': 'onelap-password',
        'token': 'onelap-token',
        'uid': '42',
      });
    });

    test('typed 凭据校验和字符串表示不泄漏秘密', () {
      expect(
        () => const XingzheVaultChannel().commitAuthorization(
          account: 'account',
          password: '',
          sessionId: 'sensitive-session',
        ),
        throwsA(
          predicate((error) => !error.toString().contains('sensitive-session')),
        ),
      );
      expect(
        () => const OnelapVaultChannel().commitAuthorization(
          account: 'account',
          password: 'password',
          token: '',
          uid: 'sensitive-uid',
        ),
        throwsA(
          predicate((error) => !error.toString().contains('sensitive-uid')),
        ),
      );
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
      await preferences.delete('virtualPower.enabled');

      expect(calls.map((call) => call.method), ['read', 'write', 'delete']);
      expect(calls[0].arguments, {'key': 'strava.gcjCorrectionEnabled'});
      expect(calls[1].arguments, {'key': 'strava.uploadMode', 'value': 'web'});
      expect(calls[2].arguments, {'key': 'virtualPower.enabled'});
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
    const webChannel = MethodChannel('health_workout_export/strava_web');

    tearDown(() async {
      messenger.setMockMethodCallHandler(keychainChannel, null);
      messenger.setMockMethodCallHandler(preferencesChannel, null);
      messenger.setMockMethodCallHandler(webChannel, null);
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
        if (call.method == 'stravaStatus') {
          return <String, Object?>{
            'clientId': secrets['strava.clientId'] ?? '',
            'hasClientSecret': secrets.containsKey('strava.clientSecret'),
            'hasAccessToken': secrets.containsKey('strava.accessToken'),
            'hasRefreshToken': secrets.containsKey('strava.refreshToken'),
            'expiresAtSeconds': preferences['strava.expiresAt'] ?? 0.0,
          };
        }
        final arguments = call.arguments! as Map<Object?, Object?>;
        if (call.method == 'writeStravaAuthorization') {
          secrets['strava.clientId'] = arguments['clientId']! as String;
          secrets['strava.clientSecret'] = arguments['clientSecret']! as String;
          secrets['strava.accessToken'] = arguments['accessToken']! as String;
          secrets['strava.refreshToken'] = arguments['refreshToken']! as String;
          preferences['strava.expiresAt'] = arguments['expiresAtSeconds']!;
          return null;
        }
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
      messenger.setMockMethodCallHandler(
        webChannel,
        (call) async => call.method == 'hasCookie',
      );

      const store = StravaSettingsStore();
      final snapshot = await store.load();
      expect(snapshot.mode, StravaUploadMode.web);
      expect(snapshot.clientId, '123');
      expect(snapshot.hasClientSecret, isTrue);
      expect(snapshot.hasAccessToken, isTrue);
      expect(snapshot.hasRefreshToken, isTrue);
      expect(snapshot.expiresAtSeconds, 42);
      expect(snapshot.hasWebCookie, isTrue);
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

      messenger.setMockMethodCallHandler(
        keychainChannel,
        (_) async => <String, Object?>{
          'clientId': '',
          'hasClientSecret': false,
          'hasAccessToken': false,
          'hasRefreshToken': false,
          'expiresAtSeconds': 0.0,
        },
      );
      messenger.setMockMethodCallHandler(webChannel, (_) async => false);
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

    test('检查可用性、请求授权、读取系统时区并打开系统设置', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'isAvailable' => true,
          'currentTimeZoneIdentifier' => 'Asia/Shanghai',
          _ => null,
        };
      });

      const healthKit = HealthKitChannel();
      expect(await healthKit.isAvailable(), isTrue);
      await healthKit.requestAuthorization();
      expect(await healthKit.currentTimeZoneIdentifier(), 'Asia/Shanghai');
      await healthKit.openSettings();

      expect(calls.map((call) => call.method), [
        'isAvailable',
        'requestAuthorization',
        'currentTimeZoneIdentifier',
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

  group('StravaWebChannel', () {
    const channel = MethodChannel('health_workout_export/strava_web');

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('登录与持久化状态只返回 readiness，彻底清除使用固定方法', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'login' => true,
          'hasCookie' => true,
          _ => null,
        };
      });

      const web = StravaWebChannel();
      expect(await web.login(), isTrue);
      expect(await web.hasCookie(), isTrue);
      await web.clearCookies();

      expect(calls.map((call) => call.method), [
        'login',
        'hasCookie',
        'clearCookies',
      ]);
      expect(calls.every((call) => call.arguments == null), isTrue);
    });

    test('登录 readiness 为空时拒绝静默成功', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => null);

      expect(
        () => const StravaWebChannel().login(),
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
