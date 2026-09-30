import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/src/rust/api/simple.dart' as rust;
import 'package:health_workout_export/strava_metadata_finalizer.dart';

const completed = rust.StravaUploadFfiResponse(
  status: rust.StravaUploadFfiStatus.completed,
  remoteId: '42',
  isDuplicate: false,
);
void main() {
  test('metadata401 gets exactly one metadata-only refresh retry', () async {
    final refreshes = <bool>[];
    final result = await finalizeUploadedMetadata(
      completed,
      update: (force) async {
        refreshes.add(force);
        if (!force) throw StateError('Strava 授权已失效');
      },
    );
    expect(refreshes, [false, true]);
    expect(result.status, rust.StravaUploadFfiStatus.completed);
    expect(result.error, isNull);
  });
  test(
    'metadata failure preserves completed remote upload with safe warning',
    () async {
      final result = await finalizeUploadedMetadata(
        completed,
        update: (_) async => throw StateError('secret-token'),
      );
      expect(result.status, rust.StravaUploadFfiStatus.completed);
      expect(result.remoteId, '42');
      expect(result.error?.message, contains('标题/描述'));
      expect(result.error?.message, isNot(contains('secret-token')));
    },
  );
  test(
    'duplicate and missing remote IDs never modify someone else activity',
    () async {
      var calls = 0;
      for (final response in [
        const rust.StravaUploadFfiResponse(
          status: rust.StravaUploadFfiStatus.completed,
          remoteId: '42',
          isDuplicate: true,
        ),
        const rust.StravaUploadFfiResponse(
          status: rust.StravaUploadFfiStatus.completed,
          remoteId: null,
          isDuplicate: false,
        ),
      ]) {
        await finalizeUploadedMetadata(
          response,
          update: (_) async {
            calls++;
          },
        );
      }
      expect(calls, 0);
    },
  );
  test(
    'cancel after upload starts no metadata work and still records success',
    () async {
      var calls = 0;
      final response = await finalizeUploadedMetadata(
        completed,
        cancelled: () => true,
        update: (_) async {
          calls++;
        },
      );
      expect(calls, 0);
      expect(response.status, rust.StravaUploadFfiStatus.completed);
      expect(response.error?.message, contains('停止'));
    },
  );
}
