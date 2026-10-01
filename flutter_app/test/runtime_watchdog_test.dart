import 'package:flutter_test/flutter_test.dart';

import '../test_driver/runtime_watchdog.dart';

void main() {
  testWidgets('runtime watchdog terminates exactly at its hard deadline', (
    tester,
  ) async {
    var terminations = 0;
    final watchdog = startRuntimeWatchdog(
      timeout: const Duration(seconds: 15),
      onTimeout: () => terminations++,
    );
    await tester.pump(const Duration(milliseconds: 14999));
    expect(terminations, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(terminations, 1);
    await tester.pump(const Duration(minutes: 1));
    expect(terminations, 1);
    expect(watchdog.isActive, isFalse);
  });

  testWidgets('completed driver cancels its watchdog', (tester) async {
    var terminated = false;
    final watchdog = startRuntimeWatchdog(
      timeout: const Duration(seconds: 15),
      onTimeout: () => terminated = true,
    );
    watchdog.cancel();
    await tester.pump(const Duration(minutes: 1));
    expect(terminated, isFalse);
  });
}
