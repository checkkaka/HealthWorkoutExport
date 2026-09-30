import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/virtual_power_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('health_workout_export/preferences');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final values = <String, Object>{};
  setUp(() {
    values.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String;
      if (call.method == 'read') return values[key];
      if (call.method == 'write') values[key] = args['value'] as Object;
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  testWidgets('默认关闭并在启用前披露位置日期天气传输', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ListView(children: [VirtualPowerSettingsCard()])),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('virtualPowerEnabled')))
          .value,
      isFalse,
    );
    expect(find.textContaining('Open-Meteo'), findsOneWidget);
    await tester.tap(find.byKey(const Key('virtualPowerEnabled')));
    await tester.pumpAndSettle();
    expect(values['virtualPower.enabled'], isTrue);
    await tester.ensureVisible(find.text('保存功率参数'));
    await tester.tap(find.text('保存功率参数'));
    await tester.pumpAndSettle();
    expect(values['virtualPower.riderMassKg'], 70);
    expect(values['virtualPower.bikeMassKg'], 8.5);
    expect(values['virtualPower.cda'], 0.3);
    expect(values['virtualPower.includeInertia'], isTrue);
  });

  testWidgets('非法质量阻止写入功率参数', (tester) async {
    values['virtualPower.enabled'] = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ListView(children: [VirtualPowerSettingsCard()])),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('virtualPowerRider')), '-1');
    await tester.ensureVisible(find.text('保存功率参数'));
    await tester.tap(find.text('保存功率参数'));
    await tester.pumpAndSettle();
    expect(values.containsKey('virtualPower.riderMassKg'), isFalse);
    expect(find.textContaining('有限数值'), findsOneWidget);
  });
}
