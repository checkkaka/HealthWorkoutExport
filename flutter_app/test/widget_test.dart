import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/main.dart';
import 'package:health_workout_export/native_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const healthKitChannel = MethodChannel('health_workout_export/healthkit');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(healthKitChannel, null);
  });

  testWidgets('启动 UI 前先初始化 Rust', (tester) async {
    var initialized = false;
    await startApp(
      initializeRust: () async {
        initialized = true;
      },
    );
    await tester.pump();

    expect(initialized, isTrue);
    expect(find.byType(HealthWorkoutExportApp), findsOneWidget);
  });

  testWidgets('显示健康、行者和顽鹿三个页签', (tester) async {
    await tester.pumpWidget(const HealthWorkoutExportApp());

    expect(find.text('健康'), findsOneWidget);
    expect(find.text('行者'), findsOneWidget);
    expect(find.text('顽鹿'), findsOneWidget);
    expect(find.text('健康训练'), findsOneWidget);
  });

  testWidgets('切换第三方入口后保留健康页的日期预设', (tester) async {
    await tester.pumpWidget(const HealthWorkoutExportApp());

    await tester.tap(find.text('近7天'));
    await tester.pump();
    expect(_chip(tester, '近7天').selected, isTrue);

    await tester.tap(find.text('行者'));
    await tester.pump();
    expect(find.text('行者活动'), findsAtLeastNWidgets(1));

    await tester.tap(find.text('健康'));
    await tester.pump();
    expect(_chip(tester, '近7天').selected, isTrue);

    await tester.tap(find.text('行者'));
    await tester.pump();
    expect(find.text('行者活动'), findsAtLeastNWidgets(1));
  });

  testWidgets('非 iOS 平台明确提示 HealthKit 不可用且不调用原生通道', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(healthKitChannel, (call) async {
      calls.add(call);
      throw MissingPluginException();
    });

    try {
      await tester.pumpWidget(const HealthWorkoutExportApp());
      await tester.pumpAndSettle();

      expect(find.text('此平台不支持 HealthKit'), findsOneWidget);
      expect(calls, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('健康页检查可用性和授权后按当前区间加载空态', (tester) async {
    final calls = <MethodCall>[];
    final pending = Completer<Object?>();
    messenger.setMockMethodCallHandler(healthKitChannel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'isAvailable' => true,
        'requestAuthorization' => null,
        'listWorkouts' => pending.future,
        _ => throw MissingPluginException(),
      };
    });

    await tester.pumpWidget(
      const HealthWorkoutExportApp(healthKit: HealthKitChannel()),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    pending.complete(<Object?>[]);
    await tester.pumpAndSettle();

    expect(calls.map((call) => call.method), [
      'isAvailable',
      'requestAuthorization',
      'listWorkouts',
    ]);
    final range = calls.last.arguments as Map<Object?, Object?>;
    expect(range['startMs'], isA<int>());
    expect(range['endMs'], isA<int>());
    expect(range['startMs'] as int, lessThan(range['endMs'] as int));
    expect(find.text('当前时间范围内没有训练'), findsOneWidget);
  });

  testWidgets('健康训练支持单选、全选和取消全选', (tester) async {
    messenger.setMockMethodCallHandler(healthKitChannel, (call) async {
      return switch (call.method) {
        'isAvailable' => true,
        'requestAuthorization' => null,
        'listWorkouts' => <Object?>[
          _workout('workout-1', '骑车'),
          _workout('workout-2', '跑步'),
        ],
        _ => throw MissingPluginException(),
      };
    });

    await tester.pumpWidget(
      const HealthWorkoutExportApp(healthKit: HealthKitChannel()),
    );
    await tester.pumpAndSettle();

    expect(find.text('骑车'), findsOneWidget);
    expect(find.text('跑步'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workout-1')));
    await tester.pump();
    expect(_workoutTile(tester, 'workout-1').value, isTrue);
    expect(_workoutTile(tester, 'workout-2').value, isFalse);

    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(_workoutTile(tester, 'workout-1').value, isTrue);
    expect(_workoutTile(tester, 'workout-2').value, isTrue);

    await tester.tap(find.text('取消全选'));
    await tester.pump();
    expect(_workoutTile(tester, 'workout-1').value, isFalse);
    expect(_workoutTile(tester, 'workout-2').value, isFalse);
  });

  testWidgets('首次同步明确展示范围并在启动前提示不可取消', (tester) async {
    messenger.setMockMethodCallHandler(healthKitChannel, (call) async {
      return switch (call.method) {
        'isAvailable' => true,
        'requestAuthorization' => null,
        'listWorkouts' => <Object?>[_workout('workout-1', '骑车')],
        _ => throw MissingPluginException(),
      };
    });

    await tester.pumpWidget(
      const HealthWorkoutExportApp(healthKit: HealthKitChannel()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workout-1')));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();

    expect(
      find.text('HealthKit → Strava API 首传（同指纹/近似预检，无补源/覆盖）'),
      findsOneWidget,
    );
    await tester.tap(find.text('开始首次同步'));
    await tester.pumpAndSettle();
    expect(find.text('开始首次同步到 Strava？'), findsOneWidget);
    expect(find.textContaining('不能取消预检或上传'), findsOneWidget);
  });

  testWidgets('健康训练加载失败后可以重试', (tester) async {
    var attempts = 0;
    messenger.setMockMethodCallHandler(healthKitChannel, (call) async {
      return switch (call.method) {
        'isAvailable' => true,
        'requestAuthorization' => null,
        'listWorkouts' =>
          ++attempts == 1
              ? throw PlatformException(code: 'healthkit_failed')
              : <Object?>[_workout('retry-workout', '游泳')],
        _ => throw MissingPluginException(),
      };
    });

    await tester.pumpWidget(
      const HealthWorkoutExportApp(healthKit: HealthKitChannel()),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('加载失败'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('游泳'), findsOneWidget);
  });

  testWidgets('首次授权完成前切换日期不会提前查询或丢失授权后结果', (tester) async {
    final authorization = Completer<Object?>();
    final calls = <String>[];
    var listCalls = 0;
    messenger.setMockMethodCallHandler(healthKitChannel, (call) {
      calls.add(call.method);
      return switch (call.method) {
        'isAvailable' => Future<Object?>.value(true),
        'requestAuthorization' => authorization.future,
        'listWorkouts' => Future<Object?>.value(
          (++listCalls, <Object?>[_workout('authorized', '骑车')]).$2,
        ),
        _ => Future<Object?>.error(MissingPluginException()),
      };
    });

    await tester.pumpWidget(
      const HealthWorkoutExportApp(healthKit: HealthKitChannel()),
    );
    await tester.pump();
    await tester.tap(find.text('近7天'));
    await tester.pump();

    expect(_chip(tester, '近7天').selected, isTrue);
    expect(listCalls, 0);
    authorization.complete(null);
    await tester.pumpAndSettle();
    expect(listCalls, 1, reason: calls.toString());
    expect(find.text('骑车'), findsOneWidget);
  });

  testWidgets('健康训练空态可以打开系统设置恢复权限', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(healthKitChannel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'isAvailable' => true,
        'requestAuthorization' || 'openSettings' => null,
        'listWorkouts' => <Object?>[],
        _ => throw MissingPluginException(),
      };
    });

    await tester.pumpWidget(
      const HealthWorkoutExportApp(healthKit: HealthKitChannel()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开设置'));
    await tester.pump();

    expect(calls.map((call) => call.method), contains('openSettings'));
  });
}

ChoiceChip _chip(WidgetTester tester, String label) {
  return tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));
}

CheckboxListTile _workoutTile(WidgetTester tester, String id) {
  return tester.widget<CheckboxListTile>(find.byKey(ValueKey(id)));
}

Map<String, Object?> _workout(String uuid, String activityName) => {
  'uuid': uuid,
  'startMs': DateTime(2026, 8, 11, 8).millisecondsSinceEpoch,
  'endMs': DateTime(2026, 8, 11, 9).millisecondsSinceEpoch,
  'durationSeconds': 3600.0,
  'activityType': 13,
  'activityName': activityName,
  'sourceName': 'Apple Watch',
  'sourceBundleId': 'com.apple.health',
  'totalEnergyKcal': 420.0,
  'totalDistanceMeters': 12345.0,
};
