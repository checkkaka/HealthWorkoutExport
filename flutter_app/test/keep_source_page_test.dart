import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/date_range.dart';
import 'package:health_workout_export/keep_source_page.dart';
import 'package:health_workout_export/workout_source.dart';

final class FakeKeepSource implements CancellableWorkoutSource {
  Future<List<WorkoutActivity>> Function()? load;
  var cancellations = 0;
  var loads = 0;
  @override
  WorkoutSourceId get id => WorkoutSourceId.keep;
  @override
  void cancelPending() => cancellations++;
  @override
  Future<bool> isAuthenticated() async => true;
  @override
  Future<void> logout() async {}
  @override
  Future<List<WorkoutActivity>> listActivities(DateInterval interval) async {
    loads++;
    return await load?.call() ?? [activity()];
  }

  @override
  Future<Uint8List> fetchFit(WorkoutActivity activity) async => Uint8List(0);
}

WorkoutActivity activity([String id = 'run-1']) => WorkoutActivity(
  id: id,
  sourceId: WorkoutSourceId.keep,
  title: '晨跑 $id',
  start: DateTime(2026, 10, 1, 8),
  end: DateTime(2026, 10, 1, 8, 30),
  durationSeconds: 1800,
  distanceMeters: 4200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const vault = MethodChannel('health_workout_export/third_party_vault');
  final calls = <MethodCall>[];
  var configured = false;
  var failClear = false;
  setUp(() {
    calls.clear();
    configured = false;
    failClear = false;
    messenger.setMockMethodCallHandler(vault, (call) async {
      calls.add(call);
      if (call.method == 'keepStatus') {
        return {'hasAccount': configured, 'hasToken': configured};
      }
      if (call.method == 'writeKeepAuthorization') configured = true;
      if (call.method == 'clearKeepAuthorization') {
        if (failClear) throw PlatformException(code: 'vault_unavailable');
        configured = false;
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(vault, null));

  Future<void> mount(
    WidgetTester tester,
    FakeKeepSource source, {
    KeepLogin? login,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KeepSourcePage(login: login, sourceFactory: () => source),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> enterLogin(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('keepAccount')),
      'synthetic-account',
    );
    await tester.enterText(
      find.byKey(const Key('keepPassword')),
      'synthetic-password',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '登录 Keep'));
    await tester.pump();
  }

  testWidgets('UTC Keep timestamps display in the device local day and time', (
    tester,
  ) async {
    configured = true;
    final starts = [
      DateTime.utc(2026, 10, 1, 2),
      DateTime.utc(2026, 9, 30, 17),
    ];
    if (Platform.environment['TZ'] == 'Asia/Shanghai') {
      expect(starts.first.toLocal().timeZoneOffset, const Duration(hours: 8));
    }
    final workouts = [
      for (var index = 0; index < starts.length; index++)
        WorkoutActivity(
          id: 'utc-run-$index',
          sourceId: WorkoutSourceId.keep,
          title: 'UTC fixture $index',
          start: starts[index],
          end: starts[index].add(const Duration(minutes: 30)),
          durationSeconds: 1800,
        ),
    ];
    final source = FakeKeepSource()..load = () async => workouts;
    await mount(tester, source);
    for (final workout in workouts) {
      final localMinute = workout.start
          .toLocal()
          .toIso8601String()
          .substring(0, 16)
          .replaceFirst('T', ' ');
      expect(find.textContaining('$localMinute ·'), findsOneWidget);
      // Formatting is a display boundary; the source's absolute instants stay UTC.
      expect(workout.start.isUtc, isTrue);
      expect(
        workout.start,
        starts[int.parse(workout.id.substring('utc-run-'.length))],
      );
    }
  });

  testWidgets(
    'Keep login saves only account/token and shows running source controls',
    (tester) async {
      final source = FakeKeepSource();
      var attempts = 0;
      await mount(
        tester,
        source,
        login: ({required account, required password}) async {
          attempts++;
          expect(account, 'synthetic-account');
          expect(password, 'synthetic-password');
          return 'synthetic-token';
        },
      );
      expect(find.text('Keep 使用非官方接口，可能随平台变更失效'), findsOneWidget);
      await enterLogin(tester);
      await tester.pumpAndSettle();
      expect(attempts, 1);
      expect(
        calls
            .where((call) => call.method == 'writeKeepAuthorization')
            .single
            .arguments,
        {'account': 'synthetic-account', 'token': 'synthetic-token'},
      );
      expect(find.text('晨跑 run-1'), findsOneWidget);
      expect(find.byIcon(Icons.directions_run), findsWidgets);
      expect(find.text('自动同步所选'), findsOneWidget);
      expect(find.byKey(const ValueKey('keepExport')), findsOneWidget);
      expect(find.textContaining('synthetic-password'), findsNothing);
      expect(find.textContaining('synthetic-token'), findsNothing);
    },
  );

  testWidgets(
    'cancelled login ignores late credentials and clears password immediately',
    (tester) async {
      final result = Completer<String>();
      await mount(
        tester,
        FakeKeepSource(),
        login: ({required account, required password}) => result.future,
      );
      await enterLogin(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('keepPassword')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.tap(find.text('取消登录'));
      await tester.pump();
      result.complete('late-token');
      await tester.pumpAndSettle();
      expect(
        calls.where((call) => call.method == 'writeKeepAuthorization'),
        isEmpty,
      );
      expect(find.byKey(const Key('keepAccount')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disposed login cannot persist a late token or update disposed controller',
    (tester) async {
      final result = Completer<String>();
      await mount(
        tester,
        FakeKeepSource(),
        login: ({required account, required password}) => result.future,
      );
      await enterLogin(tester);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      result.complete('late-token');
      await tester.pumpAndSettle();
      expect(
        calls.where((call) => call.method == 'writeKeepAuthorization'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'expired session requires explicit new login without password retry',
    (tester) async {
      configured = true;
      final source = FakeKeepSource()
        ..load = () async => throw StateError('KeepSessionExpired');
      var logins = 0;
      await mount(
        tester,
        source,
        login: ({required account, required password}) async {
          logins++;
          return 'new-token';
        },
      );
      expect(find.text('Keep 登录已失效，请重新登录'), findsOneWidget);
      expect(logins, 0);
      await tester.tap(find.text('重新登录'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('keepPassword')), findsOneWidget);
      expect(logins, 0);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('keepPassword')))
            .controller!
            .text,
        isEmpty,
      );
    },
  );

  testWidgets(
    'logout confirmation failure preserves state, and stale list cannot restore it',
    (tester) async {
      configured = true;
      final source = FakeKeepSource();
      await mount(tester, source);
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(
        calls.where((call) => call.method == 'clearKeepAuthorization'),
        isEmpty,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      failClear = true;
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '退出登录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('退出失败'), findsOneWidget);
      expect(find.byKey(const Key('keepAccount')), findsNothing);
      failClear = false;
      final pending = Completer<List<WorkoutActivity>>();
      source.load = () => pending.future;
      await tester.tap(find.text('刷新'));
      await tester.pump();
      await tester.tap(find.text('退出登录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, '退出登录'));
      await tester.pump();
      pending.complete([activity('stale')]);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('keepAccount')), findsOneWidget);
      expect(find.text('晨跑 stale'), findsNothing);
      expect(source.cancellations, greaterThan(0));
    },
  );
}
