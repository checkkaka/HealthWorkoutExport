import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/main.dart';

void main() {
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

  testWidgets('切换页签后保留各自的日期预设', (tester) async {
    await tester.pumpWidget(const HealthWorkoutExportApp());

    await tester.tap(find.text('近7天'));
    await tester.pump();
    expect(_chip(tester, '近7天').selected, isTrue);

    await tester.tap(find.text('行者'));
    await tester.pump();
    await tester.tap(find.text('今年'));
    await tester.pump();
    expect(_chip(tester, '今年').selected, isTrue);

    await tester.tap(find.text('健康'));
    await tester.pump();
    expect(_chip(tester, '近7天').selected, isTrue);

    await tester.tap(find.text('行者'));
    await tester.pump();
    expect(_chip(tester, '今年').selected, isTrue);
  });
}

ChoiceChip _chip(WidgetTester tester, String label) {
  return tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));
}
