import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/third_party_source_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const vault = MethodChannel('health_workout_export/third_party_vault');

  tearDown(() => messenger.setMockMethodCallHandler(vault, null));

  testWidgets('登录后加载顽鹿活动，页面不回显密码或会话', (tester) async {
    messenger.setMockMethodCallHandler(vault, (call) async {
      if (call.method == 'onelapStatus') {
        return <String, Object?>{
          'hasAccount': false,
          'hasPassword': false,
          'hasToken': false,
          'hasUid': false,
        };
      }
      return null;
    });
    String? receivedPassword;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThirdPartySourcePage(
            source: ThirdPartySourceType.onelap,
            login:
                ({required source, required account, required password}) async {
                  expect(source, ThirdPartySourceType.onelap);
                  expect(account, 'rider');
                  receivedPassword = password;
                },
            load:
                ({
                  required source,
                  required interval,
                  required operationId,
                }) async => [
                  const ThirdPartyWorkout(
                    id: 'ride-1',
                    title: '晨骑',
                    startTimeSeconds: 1_700_000_000,
                    durationSeconds: 3_600,
                    distanceMeters: 21_300,
                  ),
                ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('onelapAccount')), 'rider');
    await tester.enterText(
      find.byKey(const Key('onelapPassword')),
      'not-a-displayable-password',
    );
    await tester.pump();
    final loginButton = find.widgetWithText(FilledButton, '登录顽鹿');
    expect(tester.widget<FilledButton>(loginButton).onPressed, isNotNull);
    await tester.ensureVisible(loginButton);
    await tester.tap(loginButton);
    await tester.pumpAndSettle();

    expect(receivedPassword, 'not-a-displayable-password');
    expect(find.text('晨骑'), findsOneWidget);
    expect(find.text('not-a-displayable-password'), findsNothing);
    expect(find.textContaining('token'), findsNothing);
  });

  testWidgets('已登录行者仅按范围加载列表', (tester) async {
    messenger.setMockMethodCallHandler(vault, (call) async {
      if (call.method == 'xingzheStatus') {
        return <String, Object?>{
          'hasAccount': true,
          'hasPassword': true,
          'hasSessionId': true,
        };
      }
      return null;
    });
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThirdPartySourcePage(
            source: ThirdPartySourceType.xingzhe,
            load:
                ({
                  required source,
                  required interval,
                  required operationId,
                }) async {
                  loads += 1;
                  expect(source, ThirdPartySourceType.xingzhe);
                  expect(interval.endExclusive.isAfter(interval.start), isTrue);
                  expect(operationId, startsWith('xingzhe-'));
                  return const [
                    ThirdPartyWorkout(
                      id: 'xing-1',
                      title: '周末骑行',
                      startTimeSeconds: 1_700_000_000,
                      durationSeconds: 900,
                    ),
                  ];
                },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loads, 1);
    expect(find.text('周末骑行'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
    expect(find.text('自动同步所选'), findsOneWidget);
  });
}
