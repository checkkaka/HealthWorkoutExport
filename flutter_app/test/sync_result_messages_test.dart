import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/sync_result_messages.dart';

void main() {
  testWidgets(
    'partial Health and remote metadata warnings remain visible after counters finish',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SyncResultMessages(
              messages: ['已写训练，路线未完成/需检查', '上传已完成，标题/描述更新失败'],
            ),
          ),
        ),
      );
      expect(find.text('已写训练，路线未完成/需检查'), findsOneWidget);
      expect(find.text('上传已完成，标题/描述更新失败'), findsOneWidget);
    },
  );
}
