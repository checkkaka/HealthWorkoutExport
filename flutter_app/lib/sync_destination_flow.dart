final class DestinationBatchResult {
  const DestinationBatchResult({
    required this.strava,
    required this.health,
    required this.completedIds,
  });
  final Map<String, bool> strava, health;
  final Set<String> completedIds;
}

Future<DestinationBatchResult> runSyncDestinations({
  required List<String> ids,
  required bool uploadToStrava,
  required bool writeToHealth,
  required Future<Map<String, bool>> Function() runStrava,
  required Future<Map<String, bool>> Function() runHealth,
  bool Function()? cancelled,
}) async {
  if (!uploadToStrava && !writeToHealth) throw ArgumentError('没有同步目标');
  Map<String, bool> strava = const {}, health = const {};
  if (uploadToStrava && cancelled?.call() != true) strava = await runStrava();
  if (writeToHealth && cancelled?.call() != true) health = await runHealth();
  return DestinationBatchResult(
    strava: Map.unmodifiable(strava),
    health: Map.unmodifiable(health),
    completedIds: Set.unmodifiable(
      ids.where(
        (id) =>
            (!uploadToStrava || strava[id] == true) &&
            (!writeToHealth || health[id] == true),
      ),
    ),
  );
}
