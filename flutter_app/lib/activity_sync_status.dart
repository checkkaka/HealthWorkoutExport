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
  });
  final String status;
  final bool hasSyncedFit;
  final bool hasVirtualPower;
  final String? remoteId;
  final String? message;
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
  required double durationSeconds,
  double? distanceMeters,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            Text('来源：$sourceTitle'),
            Text('开始：$start'),
            Text('时长：${(durationSeconds / 60).toStringAsFixed(1)} 分钟'),
            if (distanceMeters != null)
              Text('距离：${(distanceMeters / 1000).toStringAsFixed(2)} 公里'),
            const SizedBox(height: 12),
            ActivitySyncBadges(
              sourceId: sourceId,
              activityId: activityId,
              details: true,
            ),
          ],
        ),
      ),
    ),
  ),
);
