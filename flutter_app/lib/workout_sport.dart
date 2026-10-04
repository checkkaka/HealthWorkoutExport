/// Normalize only documented sport families. Unknown is never a cross-source match.
String? normalizedWorkoutSport(String? value) {
  final sport = value?.trim().toLowerCase();
  if (sport == null || sport.isEmpty) return null;
  if (const {'run', 'trailrun', 'virtualrun'}.contains(sport)) return 'Run';
  if (const {
    'ride',
    'virtualride',
    'mountainbikeride',
    'gravelride',
    'ebikeride',
    'emountainbikeride',
    'handcycle',
    'velomobile',
  }.contains(sport)) {
    return 'Ride';
  }
  return switch (sport) {
    'walk' => 'Walk',
    'hike' => 'Hike',
    'swim' => 'Swim',
    'rowing' => 'Rowing',
    'elliptical' => 'Elliptical',
    'yoga' => 'Yoga',
    'weighttraining' => 'WeightTraining',
    _ => null,
  };
}

bool compatibleWorkoutSports(String? left, String? right) {
  final normalized = normalizedWorkoutSport(left);
  return normalized != null && normalized == normalizedWorkoutSport(right);
}

/// Fixed-sport providers provide safe provenance for older saved records.
String? sourceSportType(String? sourceId, {String? sportType}) =>
    sportType ??
    switch (sourceId) {
      'keep' => 'Run',
      'xingzhe' || 'onelap' => 'Ride',
      _ => null,
    };

String? healthKitSportType(int activityType) => switch (activityType) {
  13 => 'Ride',
  37 => 'Run',
  52 => 'Walk',
  24 => 'Hike',
  46 => 'Swim',
  35 => 'Rowing',
  16 => 'Elliptical',
  57 => 'Yoga',
  50 || 20 => 'WeightTraining',
  _ => null,
};
