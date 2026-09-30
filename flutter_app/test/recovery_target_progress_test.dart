import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/recovery_batch_checkpoint.dart';

const id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
RecoveryBatchCheckpoint queue() => RecoveryBatchCheckpoint(
  fingerprints: [id],
  replaceExisting: true,
  writeToHealth: true,
);
void main() {
  test(
    'Health success before queue checkpoint needs no deleted temporary FIT on restart',
    () {
      final pending = RecoveryBatchCheckpoint(
        fingerprints: [id],
        replaceExisting: false,
        uploadToStrava: false,
        writeToHealth: true,
      );
      final done = pending.reconcileHealth(id, {
        'appleHealthUUID': '11111111-1111-4111-8111-111111111111',
      });
      expect(done.needsHealth(id), isFalse);
      expect(done.completed, {id});
    },
  );
  test(
    'explicit Health skip proves completion but malformed UUID does not',
    () {
      final pending = queue();
      expect(
        pending
            .reconcileHealth(id, {'appleHealthSkipped': true})
            .needsHealth(id),
        isFalse,
      );
      expect(
        pending
            .reconcileHealth(id, {'appleHealthUUID': 'not-uuid'})
            .needsHealth(id),
        isTrue,
      );
    },
  );

  test('Strava success followed by Health failure resumes only Health', () {
    final saved = queue().markStrava(id, '222');
    expect(saved.needsStrava(id), isFalse);
    expect(saved.needsHealth(id), isTrue);
    expect(saved.completed, isEmpty);
    final restored = RecoveryBatchCheckpoint.decode(saved.encode());
    expect(restored.needsStrava(id), isFalse);
    expect(restored.needsHealth(id), isTrue);
  });
  test(
    'crash after atomic upload success before queue write recovers same generation proof',
    () {
      final original = queue();
      final recovered = original.reconcileUploaded(id, {
        'status': 'uploaded',
        'remoteId': '222',
        'recoveryBatchId': original.generationId,
        'uploadExternalId': 'stable-upload-id',
      });
      expect(recovered.needsStrava(id), isFalse);
      expect(recovered.needsHealth(id), isTrue);
    },
  );
  test('old uploaded record does not prove this generation success', () {
    final recovered = queue().reconcileUploaded(id, {
      'status': 'uploaded',
      'remoteId': '111',
      'recoveryBatchId': 'b' * 64,
      'uploadExternalId': 'older-upload',
    });
    expect(recovered.needsStrava(id), isTrue);
  });
  test(
    'whole retry gets a new generation and does not inherit target completion',
    () {
      final completed = queue().markStrava(id, '222').markHealth(id);
      expect(completed.completed, {id});
      final retry = completed.retryAll();
      expect(retry.generationId, isNot(completed.generationId));
      expect(retry.needsStrava(id), isTrue);
      expect(retry.needsHealth(id), isTrue);
    },
  );
  test('legacy queue without generation proof fails closed', () {
    final raw =
        jsonDecode(queue().encode().letDecode()) as Map<String, dynamic>;
    raw.remove('generationId');
    expect(
      () => RecoveryBatchCheckpoint.decode(
        Uint8List.fromList(utf8.encode(jsonEncode(raw))),
      ),
      throwsFormatException,
    );
  });
}

extension on Uint8List {
  String letDecode() => utf8.decode(this);
}
