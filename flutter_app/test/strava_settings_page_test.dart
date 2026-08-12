import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/src/rust/api/simple.dart';
import 'package:health_workout_export/strava_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const keychainChannel = MethodChannel('health_workout_export/keychain');
  const preferencesChannel = MethodChannel('health_workout_export/preferences');
  const oauthChannel = MethodChannel('health_workout_export/strava_oauth');
  const webChannel = MethodChannel('health_workout_export/strava_web');

  setUp(() {
    messenger.setMockMethodCallHandler(webChannel, (_) async => false);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(keychainChannel, null);
    messenger.setMockMethodCallHandler(preferencesChannel, null);
    messenger.setMockMethodCallHandler(oauthChannel, null);
    messenger.setMockMethodCallHandler(webChannel, null);
  });

  testWidgets('保存旧键、完成 OAuth 并原子持久化 token', (tester) async {
    final secrets = <String, String>{};
    final preferences = <String, Object>{};
    Uri? authorizationUri;
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
      final account = arguments['account']! as String;
      if (call.method == 'read') return secrets[account];
      if (call.method == 'write') {
        secrets[account] = arguments['value']! as String;
      }
      if (call.method == 'delete') secrets.remove(account);
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
    messenger.setMockMethodCallHandler(oauthChannel, (call) async {
      authorizationUri = Uri.parse(
        (call.arguments! as Map<Object?, Object?>)['authorizationUrl']!
            as String,
      );
      return 'authorization-code';
    });

    await tester.pumpWidget(
      MaterialApp(
        home: StravaSettingsPage(
          exchangeCode:
              ({
                required clientId,
                required clientSecret,
                required code,
              }) async {
                expect(clientId, '123');
                expect(clientSecret, 'secret');
                expect(code, 'authorization-code');
                return const StravaTokenResult(
                  accessToken: 'access',
                  refreshToken: 'refresh',
                  expiresAt: 2000000000.0,
                );
              },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('stravaClientId')), ' 123 ');
    await tester.enterText(
      find.byKey(const Key('stravaClientSecret')),
      ' secret ',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, '保存并授权 Strava'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('保存并授权 Strava'));
    await tester.pumpAndSettle();

    expect(secrets['strava.clientId'], '123');
    expect(secrets['strava.clientSecret'], 'secret');
    expect(secrets['strava.accessToken'], 'access');
    expect(secrets['strava.refreshToken'], 'refresh');
    expect(preferences['strava.expiresAt'], 2000000000.0);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('stravaClientSecret')))
          .controller
          ?.text,
      isEmpty,
    );
    expect(find.text('Client Secret 已保存'), findsOneWidget);
    expect(find.text('secret'), findsNothing);
    expect(
      authorizationUri?.queryParameters['scope'],
      'activity:read_all,activity:write,read',
    );
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
    expect(find.text('Strava API 授权成功'), findsOneWidget);
  });

  testWidgets('取消 OAuth 不覆盖已有授权', (tester) async {
    final secrets = <String, String>{
      'strava.clientId': 'old-id',
      'strava.clientSecret': 'old-secret',
      'strava.accessToken': 'old-access',
      'strava.refreshToken': 'old-refresh',
    };
    final preferences = <String, Object>{'strava.expiresAt': 100.0};
    var wroteAuthorization = false;
    var exchangedCode = false;
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
        wroteAuthorization = true;
        return null;
      }
      return secrets[arguments['account']];
    });
    messenger.setMockMethodCallHandler(preferencesChannel, (call) async {
      final arguments = call.arguments! as Map<Object?, Object?>;
      return preferences[arguments['key']];
    });
    messenger.setMockMethodCallHandler(oauthChannel, (_) async {
      throw PlatformException(
        code: 'oauth_cancelled',
        message: '已取消 Strava 授权',
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: StravaSettingsPage(
          exchangeCode:
              ({
                required clientId,
                required clientSecret,
                required code,
              }) async {
                exchangedCode = true;
                throw StateError('不应交换 token');
              },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('stravaClientId')), 'new-id');
    await tester.enterText(
      find.byKey(const Key('stravaClientSecret')),
      'new-secret',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, '保存并授权 Strava'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.ensureVisible(find.text('保存并授权 Strava'));
    await tester.tap(find.text('保存并授权 Strava'));
    await tester.pumpAndSettle();

    expect(wroteAuthorization, isFalse);
    expect(exchangedCode, isFalse);
    expect(secrets['strava.clientId'], 'old-id');
    expect(secrets['strava.clientSecret'], 'old-secret');
    expect(secrets['strava.accessToken'], 'old-access');
    expect(secrets['strava.refreshToken'], 'old-refresh');
    expect(preferences['strava.expiresAt'], 100.0);
    final message = tester.widget<Text>(
      find.byKey(const Key('stravaSettingsMessage'), skipOffstage: false),
    );
    expect(message.data, contains('已取消 Strava 授权'));
  });

  testWidgets('网页模式登录与彻底清除只展示 readiness 且 busy 防重入', (tester) async {
    final secrets = <String, String>{};
    final preferences = <String, Object>{'strava.uploadMode': 'web'};
    final login = Completer<bool>();
    final webCalls = <String>[];
    messenger.setMockMethodCallHandler(keychainChannel, (call) async {
      if (call.method == 'stravaStatus') {
        return <String, Object?>{
          'clientId': '',
          'hasClientSecret': false,
          'hasAccessToken': false,
          'hasRefreshToken': false,
          'expiresAtSeconds': 0.0,
        };
      }
      return null;
    });
    messenger.setMockMethodCallHandler(preferencesChannel, (call) async {
      final arguments = call.arguments! as Map<Object?, Object?>;
      return preferences[arguments['key']];
    });
    messenger.setMockMethodCallHandler(webChannel, (call) async {
      webCalls.add(call.method);
      if (call.method == 'hasCookie') {
        return secrets.containsKey('strava.webCookie');
      }
      if (call.method == 'login') {
        secrets['strava.webCookie'] = 'session=secret';
        return login.future;
      }
      if (call.method == 'clearCookies') {
        secrets.remove('strava.webCookie');
      }
      return null;
    });

    await tester.pumpWidget(const MaterialApp(home: StravaSettingsPage()));
    await tester.pumpAndSettle();
    expect(find.text('无网页登录凭据'), findsOneWidget);

    await tester.tap(find.byKey(const Key('stravaWebLogin')));
    await tester.tap(find.byKey(const Key('stravaWebLogin')));
    await tester.pump();
    expect(webCalls, ['hasCookie', 'login']);

    login.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('已有网页登录凭据'), findsOneWidget);
    expect(find.text('session=secret'), findsNothing);
    expect(find.text('Strava 网页登录成功'), findsOneWidget);

    await tester.tap(find.byKey(const Key('stravaWebClear')));
    await tester.pumpAndSettle();
    expect(webCalls, [
      'hasCookie',
      'login',
      'hasCookie',
      'clearCookies',
      'hasCookie',
    ]);
    expect(find.text('无网页登录凭据'), findsOneWidget);
    expect(find.text('Strava 网页登录已彻底清除'), findsOneWidget);
  });
}
