import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/fit_merge_page.dart';
import 'package:health_workout_export/date_range.dart';
import 'package:health_workout_export/workout_source.dart';
import 'package:health_workout_export/workout_export.dart';

void main() {
  testWidgets('单个有效 FIT 直接导出，不重编码原始内容', (tester) async {
    WorkoutExportResult? shared;
    await tester.pumpWidget(
      MaterialApp(
        home: FitMergePage(
          pickFits: () async => ['/selected/one.fit'],
          readFit: (_) async => Uint8List.fromList([1, 2, 3]),
          validateFit: (_) {},
          mergeFits:
              ({
                required primary,
                required supplements,
                required sensorsOnly,
                required alignment,
                required manualOffsetSeconds,
              }) => throw StateError('single must not merge'),
          shareResult: (result) async {
            shared = result;
          },
        ),
      ),
    );
    await tester.tap(find.text('从文件加入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出 FIT'));
    await _settleFileWork(
      tester,
      () => find.text('结果已生成').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.text('结果已生成'), findsOneWidget);
    await tester.tap(find.text('分享结果'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => shared!.file.readAsBytes()), [1, 2, 3]);
    await tester.tap(find.text('删除结果'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => shared!.file.exists()), isTrue);
    await tester.tap(find.text('删除'));
    await _settleFileWork(tester, () => find.text('结果已生成').evaluate().isEmpty);
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => shared!.directory.exists()), isFalse);
  });

  testWidgets('多文件要求显式主源并传递真实偏移与补充模式', (tester) async {
    int? offset;
    bool? sensors;
    List<int>? primaryBytes;
    WorkoutExportResult? shared;
    await tester.pumpWidget(
      MaterialApp(
        home: FitMergePage(
          pickFits: () async => ['/selected/one.fit', '/selected/two.fit'],
          readFit: (path) async =>
              Uint8List.fromList([path.contains('one') ? 1 : 2]),
          validateFit: (_) {},
          mergeFits:
              ({
                required primary,
                required supplements,
                required sensorsOnly,
                required alignment,
                required manualOffsetSeconds,
              }) {
                offset = manualOffsetSeconds;
                sensors = sensorsOnly;
                primaryBytes = primary;
                expect(alignment, 'manual');
                expect(supplements.single, [1]);
                return Uint8List.fromList([9]);
              },
          shareResult: (result) async {
            shared = result;
          },
        ),
      ),
    );
    await tester.tap(find.text('从文件加入'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, '合并 FIT'));
    await tester.tap(find.widgetWithText(FilledButton, '合并 FIT'));
    await tester.pumpAndSettle();
    expect(find.text('多文件必须选择主源'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mergeFile-1')));
    await tester.pump();
    await tester.ensureVisible(find.text('手动偏移'));
    await tester.tap(find.text('手动偏移'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('mergeManualOffset')), '-871');
    // The added manual field can move the lazily built action below the viewport.
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '合并 FIT'),
      200,
      scrollable: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '合并 FIT'));
    await tester.pumpAndSettle();
    await _settleFileWork(
      tester,
      () => find.text('结果已生成').evaluate().isNotEmpty,
    );
    expect(primaryBytes, [2]);
    expect(offset, -871);
    expect(sensors, isFalse);
    await tester.scrollUntilVisible(
      find.text('分享结果'),
      200,
      scrollable: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('分享结果'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => shared!.dispose());
  });

  testWidgets('重复导入同一文件只保留一次，无效 FIT 明确报错', (tester) async {
    var call = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FitMergePage(
          pickFits: () async =>
              call++ == 0 ? ['/one.fit', '/copy.fit'] : ['/bad.fit'],
          readFit: (path) async =>
              Uint8List.fromList([path.contains('bad') ? 0 : 1]),
          validateFit: (bytes) {
            if (bytes.first == 0) throw const FormatException('无效 FIT');
          },
        ),
      ),
    );
    await tester.tap(find.text('从文件加入'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    await tester.tap(find.text('从文件加入'));
    await tester.pumpAndSettle();
    expect(find.text('无效 FIT'), findsOneWidget);
    expect(find.byType(ListTile), findsOneWidget);
  });
  testWidgets('健康训练支持全选批量加入且读取所选范围', (tester) async {
    final source = _HealthSource();
    var authorized = false;
    await tester.pumpWidget(
      MaterialApp(
        home: FitMergePage(
          healthSource: source,
          requestHealthAuthorization: () async {
            authorized = true;
          },
          validateFit: (_) {},
        ),
      ),
    );
    await tester.tap(find.text('从健康训练加入'));
    await tester.pumpAndSettle();
    expect(authorized, isTrue);
    expect(source.interval, isNotNull);
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(source.fetched, ['1', '2']);
    expect(find.text('训练1.fit'), findsOneWidget);
    expect(find.text('训练2.fit'), findsOneWidget);
  });

  testWidgets('健康批量读取失败不残留半批文件', (tester) async {
    final source = _HealthSource()..failSecond = true;
    await tester.pumpWidget(
      MaterialApp(
        home: FitMergePage(
          healthSource: source,
          requestHealthAuthorization: () async {},
          validateFit: (_) {},
        ),
      ),
    );
    await tester.tap(find.text('从健康训练加入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.text('训练1.fit'), findsNothing);
    expect(find.text('无法读取健康训练，请检查授权后重试'), findsOneWidget);
  });
}

Future<void> _settleFileWork(
  WidgetTester tester,
  bool Function() complete,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (complete()) return;
  }
  fail('异步文件操作未完成');
}

class _HealthSource implements WorkoutSource {
  DateInterval? interval;
  final fetched = <String>[];
  bool failSecond = false;
  @override
  WorkoutSourceId get id => WorkoutSourceId.healthkit;
  @override
  Future<bool> isAuthenticated() async => true;
  @override
  Future<void> logout() async {}
  @override
  Future<List<WorkoutActivity>> listActivities(DateInterval value) async {
    interval = value;
    return [
      for (var i = 1; i <= 2; i++)
        WorkoutActivity(
          id: '$i',
          sourceId: id,
          title: '训练$i',
          start: DateTime(2026, 9, 20),
          end: DateTime(2026, 9, 20, 1),
          durationSeconds: 3600,
        ),
    ];
  }

  @override
  Future<Uint8List> fetchFit(WorkoutActivity activity) async {
    fetched.add(activity.id);
    if (failSecond && activity.id == '2') throw StateError('synthetic failure');
    return Uint8List.fromList([int.parse(activity.id)]);
  }
}
