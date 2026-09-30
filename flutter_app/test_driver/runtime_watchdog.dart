import 'dart:async';
import 'dart:io';

/// FlutterDriver's request timeout only emits a warning in the pinned SDK.
/// A separate process watchdog bounds connection, response and artifact writes.
/// Termination prevents a late SDK continuation from reporting success.
Timer startRuntimeWatchdog({
  Duration timeout = const Duration(minutes: 15),
  void Function()? onTimeout,
}) => Timer(timeout, onTimeout ?? _terminateStalledDriver);

Never _terminateStalledDriver() {
  stderr.writeln(
    'Runtime driver exceeded its hard deadline; evidence is incomplete',
  );
  exit(1);
}
