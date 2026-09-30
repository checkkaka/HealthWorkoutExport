import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/fit_merge_picker.dart';

void main() {
  testWidgets('select all and confirm preserve source order', (tester) async {
    List<String>? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                chosen = await showModalBottomSheet<List<String>>(
                  context: context,
                  builder: (_) => FitMergePicker(
                    activities: [
                      FitMergePickItem(
                        id: 'b',
                        title: 'Ride',
                        start: DateTime(2026),
                      ),
                      FitMergePickItem(
                        id: 'a',
                        title: 'Run',
                        start: DateTime(2026),
                      ),
                    ],
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '添加'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('选择健康训练（2）'), findsOneWidget);
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(chosen, ['b', 'a']);
  });
  testWidgets(
    'deselect all disables confirmation; individual selection supported',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FitMergePicker(
              activities: [
                FitMergePickItem(id: '1', title: 'Ride', start: DateTime(2026)),
                FitMergePickItem(id: '2', title: 'Run', start: DateTime(2026)),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消全选'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '添加'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Ride'));
      await tester.pumpAndSettle();
      expect(find.text('选择健康训练（1）'), findsOneWidget);
    },
  );
}
