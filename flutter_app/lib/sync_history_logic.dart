import 'native_channels.dart';
import 'src/rust/api/simple.dart' as rust;

/// Swift parity: oldest local first, closest start strictly within two minutes,
/// never reassign an existing ID and never assign one remote to multiple locals.
Map<String, String> remoteIdAssignments(
  Map<String, Map<String, Object?>> records,
  List<rust.StravaRemoteActivityResult> remotes,
) {
  final used = {
    for (final value in records.values)
      if (value['remoteId'] case final String id)
        if (isValidStravaActivityId(id)) id,
  };
  final locals =
      records.entries
          .where(
            (entry) =>
                entry.value['startDate'] is num &&
                !isValidStravaActivityId(
                  entry.value['remoteId'] as String? ?? '',
                ),
          )
          .toList()
        ..sort((a, b) {
          final order = (a.value['startDate'] as num).compareTo(
            b.value['startDate'] as num,
          );
          return order == 0 ? a.key.compareTo(b.key) : order;
        });
  final result = <String, String>{};
  for (final local in locals) {
    final start = (local.value['startDate'] as num).toDouble() + 978307200;
    if (!start.isFinite) continue;
    rust.StravaRemoteActivityResult? best;
    var delta = 120.0;
    for (final remote in remotes) {
      if (!isValidStravaActivityId(remote.id) || used.contains(remote.id)) {
        continue;
      }
      final candidateDelta = (remote.startTimeSeconds - start).abs();
      if (candidateDelta < delta) {
        best = remote;
        delta = candidateDelta;
      }
    }
    if (best != null) {
      result[local.key] = best.id;
      used.add(best.id);
    }
  }
  return result;
}

bool isAnomalousStravaSpeed(rust.StravaActivitySpeedResult speed) {
  final sport = speed.sportType.trim().toLowerCase();
  const cycling = [
    'ride',
    'cycling',
    'cycle',
    'bike',
    'biking',
    'gravel',
    'ebike',
    'e-bike',
    'virtualride',
    'handcycle',
    'velomobile',
    '骑行',
    '骑车',
    '公路',
    '山地',
    '砾石',
  ];
  if (!cycling.any(sport.contains)) return false;
  return speed.listedMaxSpeedMps >= 80 / 3.6 ||
      speed.bestEffortPeakMps >= 80 / 3.6 ||
      (speed.maxSpeedMps >= 80 / 3.6 && speed.averageSpeedMps >= 40 / 3.6);
}
