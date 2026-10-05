import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/auto_sync_checkpoint.dart';
import 'package:health_workout_export/sync_recovery_runner.dart';

void main() {
  test('Keep checkpoint preserves Run, WGS84 and indoor fields', () {
    final configuration = <String, Object?>{
      'primary': 'keep',
      'supplements': <String>[],
      'gcjEnabled': true,
      'skipLocalHistory': true,
      'mode': 'api',
      'activities': [
        {
          'id': 'run-90071992547409931',
          'title': 'Keep 跑步',
          'startMs': 1704067200000,
          'endMs': 1704069000000,
          'durationSeconds': 1800,
          'distanceMeters': 3000,
          'sportType': 'Run',
          'coordinatesWgs84': true,
          'indoor': true,
        },
      ],
    };
    final checkpoint = AutoSyncCheckpoint(
      configuration: configuration,
      completedIds: {},
    );
    expect(
      AutoSyncCheckpoint.decode(checkpoint.encode()).configuration,
      configuration,
    );
  });

  test(
    'Run recovery round trip retains sport without changing bytes or commute',
    () {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'primarySourceId': 'keep',
            'primaryActivityId': 'run-1',
            'title': 'Keep 跑步',
            'startDate': 725760000,
            'endDate': 725761800,
            'supplementSourceIds': <String>[],
            'durationSeconds': 1800,
            'distanceMeters': 3000,
            'uploadData': base64Encode([1, 2, 3]),
            'filename': 'run.fit',
            'commute': false,
            'uploadChannel': 'api',
            'sportType': 'Run',
            'coordinatesWgs84': true,
          }),
        ),
      );
      final recovery = RecoveryUploadData.fromJson(bytes);
      expect(jsonDecode(utf8.decode(recovery.encode()))['sportType'], 'Run');
      expect(recovery.pending('a' * 64).toJson()['sportType'], 'Run');
      expect(recovery.fit, [1, 2, 3]);
      expect(recovery.commute, false);
    },
  );
}
