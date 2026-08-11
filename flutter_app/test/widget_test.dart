import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/main.dart';

void main() {
  testWidgets('显示迁移骨架页面', (tester) async {
    await tester.pumpWidget(const HealthWorkoutExportApp());

    expect(find.text('健康运动导出'), findsOneWidget);
    expect(find.text('Flutter 迁移骨架已就绪'), findsOneWidget);
  });
}
