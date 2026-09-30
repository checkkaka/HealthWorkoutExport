import 'dart:io';
import 'package:share_plus/share_plus.dart';
import 'activity_detail_page.dart';
import 'route_map.dart';
import 'auto_sync_page.dart';
import 'sync_preview_models.dart';
import 'workout_source.dart';
import 'src/rust/api/simple.dart' as rust;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'native_channels.dart';
import 'sync_state_store.dart';

final class ActivitySyncStatus {
  const ActivitySyncStatus({
    required this.status,
    required this.hasSyncedFit,
    required this.hasVirtualPower,
    this.remoteId,
    this.message,
    this.fingerprint,
    this.appleHealthUuid,
    this.appleHealthSkipped = false,
    this.appleHealthError,
    this.coordinatesWgs84,
  });
  final String status;
  final bool hasSyncedFit;
  final bool hasVirtualPower;
  final String? remoteId;
  final String? message;
  final String? fingerprint, appleHealthUuid, appleHealthError;
  final bool appleHealthSkipped;
  final bool? coordinatesWgs84;
}

/// 每次状态版本只读取一次清单；所有源页面复用同一未来结果。
final class ActivitySyncIndex {
  static Future<Map<String, ActivitySyncStatus>>? _cached;
  static var _version = -1;
  static String key(String source, String activity) => '$source\u0000$activity';

  static Future<Map<String, ActivitySyncStatus>> load() {
    final version = SyncStateStore.changes.value;
    if (_cached == null || _version != version) {
      _version = version;
      _cached = _read();
    }
    return _cached!;
  }

  static Future<Map<String, ActivitySyncStatus>> _read() async {
    final store = SyncStateStore();
    try {
      final records = (await store.allRecords()).entries
          .where((entry) => entry.value is Map)
          .toList();
      records.sort(
        (a, b) => (((b.value as Map)['updatedAt'] as num?) ?? 0).compareTo(
          ((a.value as Map)['updatedAt'] as num?) ?? 0,
        ),
      );
      final result = <String, ActivitySyncStatus>{};
      for (final entry in records) {
        final record = entry.value as Map;
        final source = record['primarySourceId'];
        final activity = record['primaryActivityId'];
        if (source is! String || activity is! String) continue;
        // 早期 HealthKit 首传错误地使用采样应用 bundle id，兼容已保存记录。
        final normalizedSource = source == 'xingzhe' || source == 'onelap'
            ? source
            : 'healthkit';
        final id = key(normalizedSource, activity);
        if (result[id]?.hasSyncedFit == true) continue;
        var hasFit = false;
        if (record['status'] == 'uploaded') {
          try {
            hasFit = (await store.readSyncedFit(entry.key)).isNotEmpty;
          } on PlatformException catch (error) {
            if (error.code != 'sync_file_missing') rethrow;
          }
        }
        final remote = record['remoteId'];
        final previous = result[id];
        result[id] = ActivitySyncStatus(
          status: previous?.status ?? '${record['status']}',
          hasSyncedFit: hasFit,
          hasVirtualPower:
              (previous?.hasVirtualPower ?? false) ||
              record['hasVirtualPower'] == true,
          remoteId:
              previous?.remoteId ??
              (remote is String && isValidStravaActivityId(remote)
                  ? remote
                  : null),
          message: previous?.message ?? record['message'] as String?,
          fingerprint: hasFit ? entry.key : previous?.fingerprint,
          appleHealthUuid:
              previous?.appleHealthUuid ?? record['appleHealthUUID'] as String?,
          appleHealthSkipped:
              (previous?.appleHealthSkipped ?? false) ||
              record['appleHealthSkipped'] == true,
          appleHealthError:
              previous?.appleHealthError ??
              record['appleHealthError'] as String?,
          coordinatesWgs84: record['coordinatesWgs84'] is bool
              ? record['coordinatesWgs84'] as bool
              : null,
        );
      }
      return result;
    } catch (_) {
      return const {};
    }
  }
}

class ActivitySyncBadges extends StatelessWidget {
  const ActivitySyncBadges({
    super.key,
    required this.sourceId,
    required this.activityId,
    this.details = false,
  });
  final String sourceId;
  final String activityId;
  final bool details;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: SyncStateStore.changes,
    builder: (context, _, _) => FutureBuilder<Map<String, ActivitySyncStatus>>(
      future: ActivitySyncIndex.load(),
      builder: (context, snapshot) {
        final status =
            snapshot.data?[ActivitySyncIndex.key(sourceId, activityId)];
        if (status == null) {
          return details ? const Text('暂无本地同步记录') : const SizedBox.shrink();
        }
        final labels = [
          switch (status.status) {
            'uploaded' => '已同步',
            'pending' => '待处理',
            'failed' => '同步失败',
            _ => '同步记录',
          },
          if (status.hasSyncedFit) '同步 FIT',
          if (status.hasVirtualPower) '虚拟功率',
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final label in labels)
                  Chip(
                    label: Text(label),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            ActivityHealthStatusView(
              uuid: status.appleHealthUuid,
              skipped: status.appleHealthSkipped,
              error: details ? status.appleHealthError : null,
            ),
            if (details && status.message != null) Text(status.message!),
            if (details && status.remoteId != null)
              TextButton(
                onPressed: () async {
                  try {
                    await const StravaWebChannel().openActivity(
                      status.remoteId!,
                    );
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('无法打开 Strava 活动')),
                      );
                    }
                  }
                },
                child: Text('Strava 活动 ${status.remoteId}'),
              ),
          ],
        );
      },
    ),
  );
}

Future<void> showWorkoutActivityDetails(
  BuildContext context, {
  required String sourceId,
  required String sourceTitle,
  required String activityId,
  required String title,
  required DateTime start,
  DateTime? end,
  required double durationSeconds,
  double? distanceMeters,
}) async {
  final sourceType = switch (sourceId) {
    'xingzhe' => WorkoutSourceId.xingzhe,
    'onelap' => WorkoutSourceId.onelap,
    _ => WorkoutSourceId.healthkit,
  };
  final WorkoutSource source = switch (sourceType) {
    WorkoutSourceId.healthkit => HealthKitWorkoutSource(),
    WorkoutSourceId.xingzhe => XingzheWorkoutSource(),
    WorkoutSourceId.onelap => OnelapWorkoutSource(),
  };
  final activity = WorkoutActivity(
    id: activityId,
    sourceId: sourceType,
    title: title,
    start: start,
    end:
        end ??
        start.add(Duration(milliseconds: (durationSeconds * 1000).round())),
    durationSeconds: durationSeconds,
    distanceMeters: distanceMeters,
  );
  var index = ActivitySyncIndex.load();
  final temporary = <Directory>[];
  try {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => StatefulBuilder(
          builder: (context, setRouteState) =>
              FutureBuilder<Map<String, ActivitySyncStatus>>(
                future: index,
                builder: (context, snapshot) {
                  if (!snapshot.hasData &&
                      snapshot.connectionState != ConnectionState.done) {
                    return Scaffold(
                      appBar: AppBar(title: Text(title)),
                      body: const Center(child: CircularProgressIndicator()),
                    );
                  }
                  final status = snapshot
                      .data?[ActivitySyncIndex.key(sourceId, activityId)];
                  Future<void> configure(bool replace) async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AutoSyncPage(
                          entrySource: sourceType,
                          selected: [activity],
                          initialPreviewPolicy: SyncPreviewPolicy.everyActivity,
                          initialSkipLocalHistory: !replace,
                        ),
                      ),
                    );
                    if (context.mounted) {
                      setRouteState(() => index = ActivitySyncIndex.load());
                    }
                  }

                  return WorkoutActivityDetailPage(
                    key: ValueKey(index),
                    title: title,
                    sourceTitle: sourceTitle,
                    loadOriginal: () => source.fetchFit(activity),
                    loadSynced:
                        status?.hasSyncedFit == true &&
                            status?.fingerprint != null
                        ? () => SyncStateStore().readSyncedFit(
                            status!.fingerprint!,
                          )
                        : null,
                    inspect: (data) async => FitPreviewInspection.decode(
                      await rust.inspectFitPreview(data: data),
                    ),
                    onExport: (shareContext, bytes, synced) async {
                      final directory = await Directory.systemTemp.createTemp(
                        'health-workout-export-detail-',
                      );
                      temporary.add(directory);
                      final file = File(
                        '${directory.path}${Platform.pathSeparator}${synced ? 'strava' : 'original'}.fit',
                      );
                      await file.writeAsBytes(bytes, flush: true);
                      if (!shareContext.mounted) return;
                      final render = shareContext.findRenderObject();
                      final origin = render is RenderBox && render.hasSize
                          ? render.localToGlobal(Offset.zero) & render.size
                          : const Rect.fromLTWH(0, 0, 1, 1);
                      await SharePlus.instance.share(
                        ShareParams(
                          files: [XFile(file.path)],
                          sharePositionOrigin: origin,
                        ),
                      );
                    },
                    onPreview: () => configure(false),
                    onOverwrite: status?.remoteId != null
                        ? () => configure(true)
                        : null,
                    onOpenRemote: status?.remoteId != null
                        ? () => const StravaWebChannel().openActivity(
                            status!.remoteId!,
                          )
                        : null,
                    mapBuilder: (context, inspection, synced) => WorkoutRouteMap(
                      contentId:
                          '$sourceId:$activityId:$synced:${inspection.coordinateValueHash}',
                      lines: [
                        RouteMapLine(
                          id: synced ? 'synced' : 'original',
                          points: [
                            for (final point in inspection.track)
                              RouteMapPoint(
                                latitude: point.y,
                                longitude: point.x,
                              ),
                          ],
                          color: Theme.of(context).colorScheme.primary,
                          coordinateSystem:
                              (!synced &&
                                      sourceType ==
                                          WorkoutSourceId.healthkit) ||
                                  (synced && status?.coordinatesWgs84 == true)
                              ? RouteCoordinateSystem.wgs84
                              : RouteCoordinateSystem.unknown,
                        ),
                      ],
                    ),
                    statusDetails: ActivitySyncBadges(
                      sourceId: sourceId,
                      activityId: activityId,
                      details: true,
                    ),
                  );
                },
              ),
        ),
      ),
    );
  } finally {
    if (source is CancellableWorkoutSource) source.cancelPending();
    for (final directory in temporary) {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
      } catch (_) {
        /* Only this view's temporary copies are eligible. */
      }
    }
  }
}
