import 'dart:convert';
import 'dart:typed_data';

import 'date_range.dart';
import 'native_channels.dart';
import 'src/rust/api/simple.dart' as rust;
import 'workout_export.dart';

enum WorkoutSourceId { healthkit, xingzhe, onelap }

extension WorkoutSourceIdText on WorkoutSourceId {
  String get value => name;
  String get title => switch (this) {
    WorkoutSourceId.healthkit => '健康',
    WorkoutSourceId.xingzhe => '行者',
    WorkoutSourceId.onelap => '顽鹿',
  };
}

final class WorkoutActivity {
  const WorkoutActivity({
    required this.id,
    required this.sourceId,
    required this.title,
    required this.start,
    required this.end,
    required this.durationSeconds,
    this.distanceMeters,
  });

  final String id;
  final WorkoutSourceId sourceId;
  final String title;
  final DateTime start;
  final DateTime end;
  final double durationSeconds;
  final double? distanceMeters;

  rust.ActivityIntervalInput get interval => rust.ActivityIntervalInput(
    startSeconds: start.millisecondsSinceEpoch / 1000,
    endSeconds: end.millisecondsSinceEpoch / 1000,
    durationSeconds: durationSeconds,
  );
}

abstract interface class WorkoutSource {
  WorkoutSourceId get id;
  Future<bool> isAuthenticated();
  Future<void> logout();
  Future<List<WorkoutActivity>> listActivities(DateInterval interval);
  Future<Uint8List> fetchFit(WorkoutActivity activity);
}

final class HealthKitWorkoutSource implements WorkoutSource {
  HealthKitWorkoutSource({
    HealthKitChannel? healthKit,
    HealthFitEncoder? fitEncoder,
  }) : _healthKit = healthKit ?? const HealthKitChannel(),
       _fitEncoder = fitEncoder ?? rust.encodeHealthWorkoutFit;

  final HealthKitChannel _healthKit;
  final HealthFitEncoder _fitEncoder;

  @override
  WorkoutSourceId get id => WorkoutSourceId.healthkit;

  @override
  Future<bool> isAuthenticated() => _healthKit.isAvailable();

  @override
  Future<void> logout() async {}

  @override
  Future<List<WorkoutActivity>> listActivities(DateInterval interval) async {
    final workouts = await _healthKit.listWorkouts(
      start: interval.start,
      endExclusive: interval.endExclusive,
    );
    return [
      for (final workout in workouts)
        WorkoutActivity(
          id: workout.uuid,
          sourceId: id,
          title: workout.activityName,
          start: DateTime.fromMillisecondsSinceEpoch(workout.startMs),
          end: DateTime.fromMillisecondsSinceEpoch(workout.endMs),
          durationSeconds: workout.durationSeconds,
          distanceMeters: workout.totalDistanceMeters,
        ),
    ];
  }

  @override
  Future<Uint8List> fetchFit(WorkoutActivity activity) async {
    final bundle = (await _healthKit.fetchWorkoutBundles([activity.id])).single;
    return _fitEncoder(
      bundleJson: utf8.encode(jsonEncode(healthWorkoutFitInput(bundle))),
      timezoneOffsetSeconds: DateTime.fromMillisecondsSinceEpoch(
        bundle.summary.endMs,
      ).toLocal().timeZoneOffset.inSeconds,
    );
  }
}

final class XingzheWorkoutSource implements WorkoutSource {
  XingzheWorkoutSource({this._vault = const XingzheVaultChannel()});

  final XingzheVaultChannel _vault;

  @override
  WorkoutSourceId get id => WorkoutSourceId.xingzhe;

  @override
  Future<bool> isAuthenticated() async => (await _vault.status()).isConfigured;

  @override
  Future<void> logout() => _vault.clearAuthorization();

  @override
  Future<List<WorkoutActivity>> listActivities(DateInterval interval) async {
    final lease = await _vault.lease();
    final sessionId = lease.sessionId;
    if (sessionId == null) throw StateError('缺少行者会话');
    final reservation = rust.xingzheReserveList(
      operationId: 'xingzhe-list-${DateTime.now().microsecondsSinceEpoch}',
    );
    final workouts = await rust.xingzheListWorkouts(
      operationHandle: reservation.handle,
      sessionId: sessionId,
      fromSeconds: interval.start.millisecondsSinceEpoch ~/ 1000,
      toSeconds: interval.endExclusive.millisecondsSinceEpoch ~/ 1000,
    );
    return [
      for (final workout in workouts)
        WorkoutActivity(
          id: workout.id,
          sourceId: id,
          title: workout.title,
          start: DateTime.fromMillisecondsSinceEpoch(
            (workout.startTimeSeconds * 1000).round(),
          ),
          end: DateTime.fromMillisecondsSinceEpoch(
            (workout.endTimeSeconds * 1000).round(),
          ),
          durationSeconds: workout.durationSeconds,
          distanceMeters: workout.distanceMeters,
        ),
    ];
  }

  @override
  Future<Uint8List> fetchFit(WorkoutActivity activity) async {
    final lease = await _vault.lease();
    final sessionId = lease.sessionId;
    if (sessionId == null) throw StateError('缺少行者会话');
    final reservation = rust.xingzheReserveList(
      operationId: 'xingzhe-fit-${activity.id}',
    );
    return rust.xingzheDownloadFit(
      operationHandle: reservation.handle,
      sessionId: sessionId,
      workoutId: activity.id,
      title: activity.title,
      startTimeSeconds: activity.start.millisecondsSinceEpoch / 1000,
      durationSeconds: activity.durationSeconds,
      distanceMeters: activity.distanceMeters,
      timezoneOffsetSeconds: activity.end.toLocal().timeZoneOffset.inSeconds,
    );
  }
}

final class OnelapWorkoutSource implements WorkoutSource {
  OnelapWorkoutSource({this._vault = const OnelapVaultChannel()});

  final OnelapVaultChannel _vault;

  @override
  WorkoutSourceId get id => WorkoutSourceId.onelap;

  @override
  Future<bool> isAuthenticated() async => (await _vault.status()).isConfigured;

  @override
  Future<void> logout() => _vault.clearAuthorization();

  @override
  Future<List<WorkoutActivity>> listActivities(DateInterval interval) async {
    final lease = await _vault.lease();
    final token = lease.token;
    final uid = lease.uid;
    if (token == null || uid == null) throw StateError('缺少顽鹿会话');
    final workouts = await rust.onelapListWorkouts(
      token: token,
      uid: uid,
      fromSeconds: interval.start.millisecondsSinceEpoch ~/ 1000,
      toSeconds: interval.endExclusive.millisecondsSinceEpoch ~/ 1000,
      timezoneOffsetSeconds: DateTime.now().timeZoneOffset.inSeconds,
    );
    return [
      for (final workout in workouts)
        WorkoutActivity(
          id: workout.id,
          sourceId: id,
          title: workout.title,
          start: DateTime.fromMillisecondsSinceEpoch(
            (workout.startTimeSeconds * 1000).round(),
          ),
          end: DateTime.fromMillisecondsSinceEpoch(
            (workout.endTimeSeconds * 1000).round(),
          ),
          durationSeconds: workout.durationSeconds,
          distanceMeters: workout.distanceMeters,
        ),
    ];
  }

  @override
  Future<Uint8List> fetchFit(WorkoutActivity activity) async {
    final lease = await _vault.lease();
    final token = lease.token;
    final uid = lease.uid;
    if (token == null || uid == null) throw StateError('缺少顽鹿会话');
    return rust.onelapDownloadFit(
      token: token,
      uid: uid,
      activityId: activity.id,
    );
  }
}

WorkoutSource workoutSourceFor(WorkoutSourceId id) => switch (id) {
  WorkoutSourceId.healthkit => HealthKitWorkoutSource(),
  WorkoutSourceId.xingzhe => XingzheWorkoutSource(),
  WorkoutSourceId.onelap => OnelapWorkoutSource(),
};
