import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/recovery_batch_checkpoint.dart';

void main() {
  test('recovery custom title persists with exact queue', () {
    final value = RecoveryBatchCheckpoint(
      fingerprints: ['a' * 64],
      replaceExisting: true,
      customTitle: 'Morning ride',
    );
    expect(
      RecoveryBatchCheckpoint.decode(value.encode()).customTitle,
      'Morning ride',
    );
  });
  test('normal batch retry invalidates previous successes', () {
    expect(completedBeforeRetry({'a', 'b'}, ['a']), {'b'});
    expect(completedBeforeRetry({'a'}, ['a']), isEmpty);
  });
  test('recovery roundtrip retains intent and target progress', () {
    final value = RecoveryBatchCheckpoint(
      fingerprints: ['a' * 64, 'b' * 64],
      replaceExisting: true,
    ).markStrava('a' * 64, '1');
    final saved = RecoveryBatchCheckpoint.decode(value.encode());
    expect(saved.completed, {'a' * 64});
    expect(saved.replaceExisting, isTrue);
    expect(saved.generationId, value.generationId);
  });
  test('invalid duplicate or foreign target IDs reject', () {
    for (final value in [
      RecoveryBatchCheckpoint(fingerprints: ['../x'], replaceExisting: false),
      RecoveryBatchCheckpoint(
        fingerprints: ['a' * 64, 'a' * 64],
        replaceExisting: false,
      ),
      RecoveryBatchCheckpoint(
        fingerprints: ['a' * 64],
        replaceExisting: false,
        healthCompleted: {'b' * 64},
      ),
    ]) {
      expect(value.encode, throwsFormatException);
    }
  });
  test('health-only never silently becomes a Strava upload', () {
    final value = RecoveryBatchCheckpoint(
      fingerprints: ['a' * 64],
      replaceExisting: false,
      uploadToStrava: false,
      writeToHealth: true,
    );
    final saved = RecoveryBatchCheckpoint.decode(value.encode());
    expect(saved.uploadToStrava, isFalse);
    expect(saved.writeToHealth, isTrue);
  });
  test('unknown fields and future versions reject', () {
    final base =
        jsonDecode(
              utf8.decode(
                RecoveryBatchCheckpoint(
                  fingerprints: ['a' * 64],
                  replaceExisting: false,
                ).encode(),
              ),
            )
            as Map<String, dynamic>;
    for (final value in [
      {...base, 'token': 'placeholder'},
      {...base, 'version': 99},
    ]) {
      expect(
        () => RecoveryBatchCheckpoint.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(value))),
        ),
        throwsFormatException,
      );
    }
  });
}
