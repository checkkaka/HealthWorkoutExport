import 'dart:async';

/// Tracks actual callback work separately from Flutter frame settlement.
/// Kept in the runtime harness; production UI error handling stays unchanged.
class RuntimeCallbackCompletion {
  Future<void>? _completion;

  Future<void> run(Future<void> Function() callback) =>
      _completion = Future<void>.sync(callback);

  Future<void> wait({required Duration timeout}) {
    final completion = _completion;
    if (completion == null) {
      return Future<void>.error(StateError('Runtime callback was not invoked'));
    }
    return completion.timeout(timeout);
  }
}
