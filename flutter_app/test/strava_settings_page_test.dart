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

  tearDown(() {
    messenger.setMockMethodCallHandler(keychainChannel, null);
    messenger.setMockMethodCallHandler(preferencesChannel, null);
    messenger.setMockMethodCallHandler(oauthChannel, null);
  });

  testWidgets('保存旧键、完成 OAuth 并原子持久化 token', (tester) async {
    final secrets = <String, String>{};
    final preferences = <String, Object>{};
    Uri? authorizationUri;
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
    await tester.tap(find.text('保存并授权 Strava'));
    await tester.pumpAndSettle();

    expect(wroteAuthorization, isFalse);
    expect(exchangedCode, isFalse);
    expect(secrets['strava.clientId'], 'old-id');
    expect(secrets['strava.clientSecret'], 'old-secret');
    expect(secrets['strava.accessToken'], 'old-access');
    expect(secrets['strava.refreshToken'], 'old-refresh');
    expect(preferences['strava.expiresAt'], 100.0);
    expect(find.textContaining('已取消 Strava 授权'), findsOneWidget);
  });
}
