import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/native_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('health_workout_export/preferences');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('legacy preview and health-write preferences keep exact keys', () async {
    final saved = <String, Object?>{};
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String;
      if (call.method == 'write') {
        saved[key] = args['value'];
        return null;
      }
      return saved[key];
    });
    const preferences = PreferencesChannel();
    await preferences.write('sync_preview_policy', 'everyActivity');
    await preferences.write('write_to_apple_health', true);
    expect(await preferences.read('sync_preview_policy'), 'everyActivity');
    expect(await preferences.read('write_to_apple_health'), isTrue);
  });
}
