import 'dart:convert';
import 'dart:typed_data';

import 'date_range.dart';
import 'native_channels.dart';
import 'keep_vault.dart';
import 'src/rust/api/keep.dart' as keep;
import 'workout_sport.dart';
export 'workout_sport.dart';
import 'src/rust/api/simple.dart' as rust;
import 'workout_export.dart';

enum WorkoutSourceId { healthkit, xingzhe, onelap, keep }

extension WorkoutSourceIdText on WorkoutSourceId {
  String get value => name;
  String get title => switch (this) {
    WorkoutSourceId.healthkit => '健康',
    WorkoutSourceId.xingzhe => '行者',
    WorkoutSourceId.onelap => '顽鹿',
    WorkoutSourceId.keep => 'Keep',
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
    this.sportType,
    this.coordinatesWgs84,
    this.indoor = false,
  });

  final String id;
  final WorkoutSourceId sourceId;
  final String title;
  final DateTime start;
  final DateTime end;
  final double durationSeconds;
  final double? distanceMeters;
  final String? sportType;
  final bool? coordinatesWgs84;
  final bool indoor;

  String? get effectiveSportType =>
      sourceSportType(sourceId.value, sportType: sportType);
  bool get isCycling => normalizedWorkoutSport(effectiveSportType) == 'Ride';
  bool get hasWgs84Coordinates =>
      coordinatesWgs84 ??
      (sourceId == WorkoutSourceId.healthkit ||
          sourceId == WorkoutSourceId.keep);

  rust.ActivityIntervalInput get interval => rust.ActivityIntervalInput(
    startSeconds: start.millisecondsSinceEpoch / 1000,
    endSeconds: end.millisecondsSinceEpoch / 1000,
    durationSeconds: durationSeconds,
  );
}

abstract interface class CancellableWorkoutSource implements WorkoutSource {
  void cancelPending();
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
          sportType: healthKitSportType(workout.activityType),
          coordinatesWgs84: true,
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

final class XingzheWorkoutSource
    implements WorkoutSource, CancellableWorkoutSource {
  XingzheWorkoutSource({
    XingzheVaultChannel vault = const XingzheVaultChannel(),
    // ignore: prefer_initializing_formals
  }) : _vault = vault;
  final _activeHandles = <String>{};

  @override
  void cancelPending() {
    for (final handle in _activeHandles) {
      rust.xingzheCancelList(operationHandle: handle);
    }
  }

  Future<T> _withOperation<T>(
    String name,
    Future<T> Function(String handle) action,
  ) async {
    final reservation = rust.xingzheReserveList(
      operationId: '$name-${DateTime.now().microsecondsSinceEpoch}',
    );
    _activeHandles.add(reservation.handle);
    try {
      return await action(reservation.handle);
    } finally {
      _activeHandles.remove(reservation.handle);
      rust.xingzheReleaseList(operationHandle: reservation.handle);
    }
  }

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
    final workouts = await _withOperation(
      'xingzhe-list',
      (handle) => rust.xingzheListWorkouts(
        operationHandle: handle,
        sessionId: sessionId,
        fromSeconds: interval.start.millisecondsSinceEpoch ~/ 1000,
        toSeconds: interval.endExclusive.millisecondsSinceEpoch ~/ 1000,
      ),
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
    return _withOperation(
      'xingzhe-fit',
      (handle) => rust.xingzheDownloadFit(
        operationHandle: handle,
        sessionId: sessionId,
        workoutId: activity.id,
        title: activity.title,
        startTimeSeconds: activity.start.millisecondsSinceEpoch / 1000,
        durationSeconds: activity.durationSeconds,
        distanceMeters: activity.distanceMeters,
        timezoneOffsetSeconds: activity.end.toLocal().timeZoneOffset.inSeconds,
      ),
    );
  }
}

typedef OnelapAuthenticate =
    Future<rust.OnelapLoginResult> Function({
      required String account,
      required String password,
    });
typedef OnelapRefresh =
    Future<rust.OnelapLoginResult> Function({
      required String refreshToken,
      required String uid,
    });

/// 失效会话只恢复一次；同源并发请求共享恢复，网络失败不会触发无意义重登。
final class OnelapSessionManager {
  OnelapSessionManager({
    OnelapVaultChannel vault = const OnelapVaultChannel(),
    OnelapAuthenticate login = rust.onelapLogin,
    OnelapRefresh refresh = rust.onelapRefreshSession,
    // ignore: prefer_initializing_formals
  }) : _vault = vault,
       // ignore: prefer_initializing_formals
       _login = login,
       // ignore: prefer_initializing_formals
       _refresh = refresh;
  final OnelapVaultChannel _vault;
  final OnelapAuthenticate _login;
  final OnelapRefresh _refresh;
  Future<OnelapVaultLease>? _refreshInFlight;

  Future<T> run<T>(
    Future<T> Function(OnelapVaultLease lease) action, {
    bool Function()? cancelled,
  }) async {
    final lease = await _vault.lease();
    void check() {
      if (cancelled?.call() == true) throw StateError('已停止');
    }

    check();
    try {
      return await action(lease);
    } catch (error) {
      check();
      if (!error.toString().contains('顽鹿登录已失效')) rethrow;
      final recovered = await (_refreshInFlight ??= _recover(lease));
      check();
      return action(recovered);
    }
  }

  Future<OnelapVaultLease> _recover(OnelapVaultLease lease) async {
    try {
      rust.OnelapLoginResult? session;
      if (lease.refreshToken != null && lease.uid != null) {
        try {
          session = await _refresh(
            refreshToken: lease.refreshToken!,
            uid: lease.uid!,
          );
        } catch (error) {
          if (!error.toString().contains('顽鹿登录已失效')) rethrow;
        }
      }
      session ??= await _login(
        account: lease.account,
        password: lease.password,
      );
      await _vault.commitAuthorization(
        account: lease.account,
        password: lease.password,
        token: session.token,
        uid: session.uid,
        refreshToken: session.refreshToken,
      );
      return OnelapVaultLease(
        account: lease.account,
        password: lease.password,
        token: session.token,
        uid: session.uid,
        refreshToken: session.refreshToken,
      );
    } finally {
      _refreshInFlight = null;
    }
  }
}

final class OnelapWorkoutSource
    implements WorkoutSource, CancellableWorkoutSource {
  OnelapWorkoutSource({OnelapVaultChannel vault = const OnelapVaultChannel()})
    : _vault = vault,
      _sessions = OnelapSessionManager(vault: vault);
  final OnelapVaultChannel _vault;
  final OnelapSessionManager _sessions;
  final _activeHandles = <String>{};
  var _cancellationGeneration = 0;

  @override
  WorkoutSourceId get id => WorkoutSourceId.onelap;
  @override
  Future<bool> isAuthenticated() async => (await _vault.status()).isConfigured;
  @override
  Future<void> logout() => _vault.clearAuthorization();
  @override
  void cancelPending() {
    _cancellationGeneration++;
    for (final handle in _activeHandles) {
      rust.onelapCancelOperation(operationHandle: handle);
    }
  }

  Future<T> _run<T>(
    String name,
    Future<T> Function(String handle, OnelapVaultLease lease) action,
  ) async {
    final generation = _cancellationGeneration;
    return _sessions.run((lease) async {
      final reservation = rust.onelapReserveOperation(
        operationId: '$name-${DateTime.now().microsecondsSinceEpoch}',
      );
      _activeHandles.add(reservation.handle);
      try {
        return await action(reservation.handle, lease);
      } finally {
        _activeHandles.remove(reservation.handle);
        rust.onelapReleaseOperation(operationHandle: reservation.handle);
      }
    }, cancelled: () => generation != _cancellationGeneration);
  }

  @override
  Future<List<WorkoutActivity>> listActivities(DateInterval interval) async {
    final workouts = await _run(
      'onelap-list',
      (handle, lease) => rust.onelapListWorkoutsCancellable(
        operationHandle: handle,
        token: lease.token ?? (throw StateError('缺少顽鹿会话')),
        uid: lease.uid ?? (throw StateError('缺少顽鹿会话')),
        fromSeconds: interval.start.millisecondsSinceEpoch ~/ 1000,
        toSeconds: interval.endExclusive.millisecondsSinceEpoch ~/ 1000,
        timezoneOffsetSeconds: DateTime.now().timeZoneOffset.inSeconds,
      ),
    );
    return [
      for (final workout in workouts)
        ?normalizeOnelapActivity(workout, interval),
    ];
  }

  @override
  Future<Uint8List> fetchFit(WorkoutActivity activity) => _run(
    'onelap-fit',
    (handle, lease) => rust.onelapDownloadFitCancellable(
      operationHandle: handle,
      token: lease.token ?? (throw StateError('缺少顽鹿会话')),
      uid: lease.uid ?? (throw StateError('缺少顽鹿会话')),
      activityId: activity.id,
    ),
  );
}

/// Experimental Keep account source. The vault stores token/account, never password.
final class KeepWorkoutSource
    implements WorkoutSource, CancellableWorkoutSource {
  KeepWorkoutSource({KeepVaultChannel vault = const KeepVaultChannel()})
    // ignore: prefer_initializing_formals
    : _vault = vault;
  final KeepVaultChannel _vault;
  final _handles = <String>{};
  var _generation = 0;
  @override
  WorkoutSourceId get id => WorkoutSourceId.keep;
  @override
  Future<bool> isAuthenticated() async => (await _vault.status()).isConfigured;
  @override
  Future<void> logout() async {
    cancelPending();
    await _vault.clearAuthorization();
  }

  @override
  void cancelPending() {
    _generation++;
    for (final handle in _handles) {
      keep.keepCancelOperation(operationHandle: handle);
    }
  }

  Future<T> _run<T>(
    String name,
    Future<T> Function(String handle, String token) action,
  ) async {
    final generation = _generation;
    final lease = await _vault.lease();
    if (generation != _generation) throw StateError('KeepCancelled');
    final reservation = keep.keepReserveOperation(
      operationId: '$name-${DateTime.now().microsecondsSinceEpoch}',
    );
    _handles.add(reservation.handle);
    try {
      final result = await action(reservation.handle, lease.token);
      if (generation != _generation) throw StateError('KeepCancelled');
      return result;
    } finally {
      _handles.remove(reservation.handle);
      keep.keepReleaseOperation(operationHandle: reservation.handle);
    }
  }

  @override
  Future<List<WorkoutActivity>> listActivities(DateInterval interval) async {
    final records = await _run(
      'keep-list',
      (handle, token) => keep.keepListWorkouts(
        operationHandle: handle,
        token: token,
        fromSeconds: interval.start.millisecondsSinceEpoch ~/ 1000,
        toSeconds: interval.endExclusive.millisecondsSinceEpoch ~/ 1000,
      ),
    );
    return [
      for (final record in records)
        WorkoutActivity(
          id: record.id,
          sourceId: id,
          title: record.title,
          start: DateTime.fromMillisecondsSinceEpoch(
            (record.startTimeSeconds * 1000).round(),
            isUtc: true,
          ),
          end: DateTime.fromMillisecondsSinceEpoch(
            (record.endTimeSeconds * 1000).round(),
            isUtc: true,
          ),
          durationSeconds: record.durationSeconds,
          distanceMeters: record.distanceMeters,
          sportType: 'Run',
          coordinatesWgs84: true,
          indoor: record.indoor,
        ),
    ];
  }

  @override
  Future<Uint8List> fetchFit(WorkoutActivity activity) {
    if (activity.sourceId != id) throw ArgumentError('Keep 活动来源不一致');
    return _run(
      'keep-fit',
      (handle, token) => keep.keepDownloadFit(
        operationHandle: handle,
        token: token,
        workoutId: activity.id,
      ),
    );
  }
}

WorkoutSource workoutSourceFor(WorkoutSourceId id) => switch (id) {
  WorkoutSourceId.healthkit => HealthKitWorkoutSource(),
  WorkoutSourceId.xingzhe => XingzheWorkoutSource(),
  WorkoutSourceId.onelap => OnelapWorkoutSource(),
  WorkoutSourceId.keep => KeepWorkoutSource(),
};

/// 顽鹿时间没有 UTC offset，必须用活动日期的本地时区规则，而非今天的偏移。
WorkoutActivity? normalizeOnelapActivity(
  rust.OnelapWorkoutResult workout,
  DateInterval interval, {
  DateTime Function(String value)? parseLocal,
}) {
  final start = (parseLocal ?? DateTime.parse)(workout.startTimeLocal);
  if (start.isBefore(interval.start) ||
      !start.isBefore(interval.endExclusive)) {
    return null;
  }
  final duration = workout.durationSeconds > 0 ? workout.durationSeconds : 1.0;
  return WorkoutActivity(
    id: workout.id,
    sourceId: WorkoutSourceId.onelap,
    title: workout.title,
    start: start,
    end: start.add(Duration(milliseconds: (duration * 1000).round())),
    durationSeconds: workout.durationSeconds,
    distanceMeters: workout.distanceMeters,
  );
}
