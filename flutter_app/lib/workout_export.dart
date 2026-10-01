import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

import 'native_channels.dart';
import 'src/rust/api/simple.dart' as rust;
import 'sync_state_store.dart';

enum WorkoutExportFormat {
  json('JSON', 'json'),
  fit('FIT', 'fit');

  const WorkoutExportFormat(this.title, this.extension);

  final String title;
  final String extension;
}

enum WorkoutFitExportSource {
  original('原始文件'),
  synced('Strava 同步版');

  const WorkoutFitExportSource(this.title);
  final String title;
}

/// 导出摘要不携带会话或密码，第三方源不伪造健康明细。
final class WorkoutExportActivity {
  const WorkoutExportActivity({
    required this.id,
    required this.sourceId,
    required this.title,
    required this.start,
    required this.end,
    required this.durationSeconds,
    this.distanceMeters,
    this.metadata = const {},
  });

  factory WorkoutExportActivity.health(HealthWorkoutSummary summary) =>
      WorkoutExportActivity(
        id: summary.uuid,
        sourceId: 'healthkit',
        title: summary.activityName,
        start: DateTime.fromMillisecondsSinceEpoch(summary.startMs),
        end: DateTime.fromMillisecondsSinceEpoch(summary.endMs),
        durationSeconds: summary.durationSeconds,
        distanceMeters: summary.totalDistanceMeters,
      );

  final String id;
  final String sourceId;
  final String title;
  final DateTime start;
  final DateTime end;
  final double durationSeconds;
  final double? distanceMeters;
  final Map<String, Object?> metadata;
  String get key => jsonEncode([sourceId, id]);
}

/// 只使用已上传、且文件仍存在的最近记录；缺文件时绝不回退到原始 FIT。
final class SyncedFitExportStore {
  SyncedFitExportStore({
    Future<Map<String, Object?>> Function()? loadRecords,
    Future<Uint8List> Function(String fingerprint)? readFit,
  }) : _loadRecords = loadRecords ?? SyncStateStore().allRecords,
       _readFit = readFit ?? const SyncFilesChannel().readSyncedFit;

  final Future<Map<String, Object?>> Function() _loadRecords;
  final Future<Uint8List> Function(String fingerprint) _readFit;

  Future<Map<String, String>> available(
    List<WorkoutExportActivity> activities,
  ) async {
    if (activities.isEmpty) return const {};
    final requested = activities.map((activity) => activity.key).toSet();
    final records =
        (await _loadRecords()).entries.where((entry) {
          final value = entry.value;
          return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(entry.key) &&
              value is Map &&
              value['status'] == 'uploaded';
        }).toList()..sort((a, b) {
          double timestamp(Object? value) =>
              value is Map && value['updatedAt'] is num
              ? (value['updatedAt'] as num).toDouble()
              : 0;
          return timestamp(b.value).compareTo(timestamp(a.value));
        });
    final result = <String, String>{};
    for (final entry in records) {
      final record = entry.value as Map;
      final key = jsonEncode([
        record['primarySourceId'],
        record['primaryActivityId'],
      ]);
      if (!requested.contains(key) || result.containsKey(key)) continue;
      try {
        final bytes = await _readFit(entry.key);
        if (bytes.isNotEmpty) result[key] = entry.key;
      } on PlatformException catch (error) {
        if (error.code != 'sync_file_missing') rethrow;
      }
    }
    return result;
  }

  Future<Uint8List> read(
    WorkoutExportActivity activity,
    Map<String, String> fingerprints,
  ) async {
    final fingerprint = fingerprints[activity.key];
    if (fingerprint == null) {
      throw StateError('“${activity.title}”没有保存 Strava 同步版 FIT，请重新同步后导出');
    }
    try {
      final bytes = await _readFit(fingerprint);
      if (bytes.isNotEmpty) return bytes;
    } on PlatformException catch (error) {
      if (error.code != 'sync_file_missing') rethrow;
    }
    throw StateError('“${activity.title}”的 Strava 同步版 FIT 已被删除，请刷新后重试');
  }
}

/// 与原应用一致的导出时区候选；偏移按每条训练结束时刻计算，能正确覆盖夏令时。
final class WorkoutExportTimeZone {
  const WorkoutExportTimeZone._(this.id, this.title);

  static const candidates = [
    WorkoutExportTimeZone._(null, '当前时区'),
    WorkoutExportTimeZone._('Asia/Shanghai', '上海'),
    WorkoutExportTimeZone._('UTC', 'UTC'),
    WorkoutExportTimeZone._('Asia/Tokyo', '东京'),
    WorkoutExportTimeZone._('Europe/London', '伦敦'),
    WorkoutExportTimeZone._('America/New_York', '纽约'),
    WorkoutExportTimeZone._('America/Los_Angeles', '洛杉矶'),
  ];

  /// `null` 表示系统当前时区；其他值是稳定的 IANA 时区标识。
  final String? id;
  final String title;

  factory WorkoutExportTimeZone.resolvedCurrent(String identifier) {
    if (identifier.trim().isEmpty) {
      throw ArgumentError.value(identifier, 'identifier');
    }
    return WorkoutExportTimeZone._(identifier, '当前时区');
  }
}

final class WorkoutExportProgress {
  const WorkoutExportProgress({required this.completed, required this.total});

  final int completed;
  final int total;
  double get fraction => total == 0 ? 0 : completed / total;
}

/// 本次临时导出结果；用户删除、下次导出或七天清理时调用 [dispose]，绝不影响同步 FIT。
final class WorkoutExportResult {
  const WorkoutExportResult({required this.file, required this.directory});

  final File file;
  final Directory directory;

  Future<void> dispose() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

typedef HealthFitEncoder =
    Future<Uint8List> Function({
      required List<int> bundleJson,
      required int timezoneOffsetSeconds,
    });

/// 只负责临时文件与分享：HealthKit 读取和 FIT 语义仍分别留在原生通道与 Rust。
final class WorkoutExportService {
  WorkoutExportService({HealthFitEncoder? fitEncoder})
    : _fitEncoder = fitEncoder ?? rust.encodeHealthWorkoutFit;

  static const _temporaryPrefix = 'health-workout-export-';
  final HealthFitEncoder _fitEncoder;

  Future<WorkoutExportResult> export({
    required List<HealthWorkoutBundle> bundles,
    required WorkoutExportFormat format,
    required WorkoutExportTimeZone timeZone,
    void Function(WorkoutExportProgress progress)? onProgress,
  }) async {
    return _export(
      total: bundles.length,
      loadBundle: (index) async => bundles[index],
      format: format,
      timeZone: timeZone,
      onProgress: onProgress,
    );
  }

  /// 逐条读取并落盘，避免长 GPS 训练全量跨通道驻留在 Dart 内存中。
  Future<WorkoutExportResult> exportFromLoader({
    required List<String> workoutIds,
    required Future<HealthWorkoutBundle> Function(String uuid) loadBundle,
    required WorkoutExportFormat format,
    required WorkoutExportTimeZone timeZone,
    void Function(WorkoutExportProgress progress)? onProgress,
  }) => _export(
    total: workoutIds.length,
    loadBundle: (index) => loadBundle(workoutIds[index]),
    format: format,
    timeZone: timeZone,
    onProgress: onProgress,
  );

  /// 原始 FIT 字节直接来自源；同步版字节直接来自受保护的同步存储。
  Future<WorkoutExportResult> exportActivities({
    required List<WorkoutExportActivity> activities,
    required WorkoutExportFormat format,
    required WorkoutExportTimeZone timeZone,
    Future<Uint8List> Function(WorkoutExportActivity activity)? loadFit,
    Future<HealthWorkoutBundle> Function(String id)? loadHealthBundle,
    void Function(WorkoutExportProgress progress)? onProgress,
  }) => _writeBatch(
    total: activities.length,
    onProgress: onProgress,
    load: (index) async {
      final activity = activities[index];
      final start = _dateInZone(
        activity.start.millisecondsSinceEpoch,
        timeZone,
      );
      final name =
          '${_safeFileBaseName(activity.id, activity.title, start)}.${format.extension}';
      final bytes = switch (format) {
        WorkoutExportFormat.fit =>
          loadFit == null
              ? throw StateError('没有可用的 FIT 来源')
              : await loadFit(activity),
        WorkoutExportFormat.json => utf8.encode(
          const JsonEncoder.withIndent('  ').convert(
            loadHealthBundle == null
                ? _sourceJsonExport(activity, timeZone)
                : _jsonExport(await loadHealthBundle(activity.id), timeZone),
          ),
        ),
      };
      return (name, bytes);
    },
  );

  Future<WorkoutExportResult> _export({
    required int total,
    required Future<HealthWorkoutBundle> Function(int index) loadBundle,
    required WorkoutExportFormat format,
    required WorkoutExportTimeZone timeZone,
    required void Function(WorkoutExportProgress progress)? onProgress,
  }) => _writeBatch(
    total: total,
    onProgress: onProgress,
    load: (index) async {
      final bundle = await loadBundle(index);
      final end = _dateInZone(bundle.summary.endMs, timeZone);
      final start = _dateInZone(bundle.summary.startMs, timeZone);
      final name = '${_fileBaseName(bundle, start)}.${format.extension}';
      final bytes = switch (format) {
        WorkoutExportFormat.json => utf8.encode(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(_jsonExport(bundle, timeZone)),
        ),
        WorkoutExportFormat.fit => await _fitEncoder(
          bundleJson: utf8.encode(jsonEncode(healthWorkoutFitInput(bundle))),
          timezoneOffsetSeconds: end.timeZoneOffset.inSeconds,
        ),
      };
      return (name, bytes);
    },
  );

  Future<WorkoutExportResult> _writeBatch({
    required int total,
    required Future<(String, List<int>)> Function(int index) load,
    required void Function(WorkoutExportProgress progress)? onProgress,
  }) async {
    if (total == 0) throw ArgumentError('至少选择一条训练');
    _initializeTimeZones();
    await _cleanupOldExports();
    final directory = await Directory.systemTemp.createTemp(_temporaryPrefix);
    try {
      final files = <File>[];
      final usedNames = <String>{};
      onProgress?.call(WorkoutExportProgress(completed: 0, total: total));
      // 一条一条读取，限制驻留内存，并避免源服务限流；失败不会分享残缺结果。
      for (var index = 0; index < total; index++) {
        final (baseName, bytes) = await load(index);
        final name = _uniqueFileName(baseName, usedNames);
        final output = File('${directory.path}${Platform.pathSeparator}$name');
        await output.writeAsBytes(bytes, flush: true);
        files.add(output);
        onProgress?.call(
          WorkoutExportProgress(completed: index + 1, total: total),
        );
      }
      if (files.length == 1) {
        return WorkoutExportResult(file: files.single, directory: directory);
      }
      final archive = File(
        '${directory.path}${Platform.pathSeparator}workouts_export.zip',
      );
      final encoder = ZipFileEncoder()..create(archive.path);
      try {
        for (final file in files) {
          await encoder.addFile(file, file.uri.pathSegments.last);
        }
      } finally {
        await encoder.close();
      }
      return WorkoutExportResult(file: archive, directory: directory);
    } catch (_) {
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<ShareResult> share(
    WorkoutExportResult result, {
    Rect? sharePositionOrigin,
  }) => SharePlus.instance.share(
    ShareParams(
      files: [XFile(result.file.path)],
      subject: '健康训练导出',
      sharePositionOrigin: sharePositionOrigin,
    ),
  );

  static void _initializeTimeZones() {
    if (_timeZonesInitialized) return;
    timezone_data.initializeTimeZones();
    _timeZonesInitialized = true;
  }

  static bool _timeZonesInitialized = false;

  static Future<void> _cleanupOldExports() async {
    await for (final entity in Directory.systemTemp.list()) {
      if (entity is! Directory ||
          !entity.uri.pathSegments
              .where((part) => part.isNotEmpty)
              .last
              .startsWith(_temporaryPrefix)) {
        continue;
      }
      try {
        final modified = await entity.stat().then((value) => value.modified);
        if (DateTime.now().difference(modified) > const Duration(days: 7)) {
          await entity.delete(recursive: true);
        }
      } on FileSystemException {
        // 旧临时目录不可访问不应阻断新的用户导出；本次目录仍单独受控。
      }
    }
  }
}

DateTime _dateInZone(int milliseconds, WorkoutExportTimeZone zone) {
  final instant = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  return switch (zone.id) {
    null => instant.toLocal(),
    final id => timezone.TZDateTime.from(instant, timezone.getLocation(id)),
  };
}

String _fileBaseName(HealthWorkoutBundle bundle, DateTime start) =>
    _safeFileBaseName(bundle.summary.uuid, bundle.summary.activityName, start);

String _safeFileBaseName(String id, String title, DateTime start) {
  final stamp =
      '${start.year.toString().padLeft(4, '0')}'
      '${start.month.toString().padLeft(2, '0')}'
      '${start.day.toString().padLeft(2, '0')}_'
      '${start.hour.toString().padLeft(2, '0')}'
      '${start.minute.toString().padLeft(2, '0')}';
  String safe(String value, int limit, String fallback) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp('_+'), '_')
        .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
    if (cleaned.isEmpty) return fallback;
    // 按 UTF-8 字节限制长度，避免中文标题超过平台单文件名上限。
    final runes = <int>[];
    var bytes = 0;
    for (final rune in cleaned.runes) {
      bytes += utf8.encode(String.fromCharCode(rune)).length;
      if (bytes > limit) break;
      runes.add(rune);
    }
    return String.fromCharCodes(runes);
  }

  final prefix = String.fromCharCodes(id.runes.take(8));
  return '${stamp}_${safe(title, 120, 'workout')}_${safe(prefix, 32, 'activity')}';
}

String _uniqueFileName(String name, Set<String> used) {
  var result = name;
  var suffix = 2;
  final dot = name.lastIndexOf('.');
  while (!used.add(result.toLowerCase())) {
    result = '${name.substring(0, dot)}_${suffix++}${name.substring(dot)}';
  }
  return result;
}

Map<String, Object?> _sourceJsonExport(
  WorkoutExportActivity activity,
  WorkoutExportTimeZone zone,
) => {
  'id': activity.id,
  'sourceId': activity.sourceId,
  'title': activity.title,
  'startDate': _iso8601WithOffset(
    _dateInZone(activity.start.millisecondsSinceEpoch, zone),
  ),
  'endDate': _iso8601WithOffset(
    _dateInZone(activity.end.millisecondsSinceEpoch, zone),
  ),
  'durationSeconds': activity.durationSeconds,
  if (activity.distanceMeters != null)
    'totalDistanceMeters': activity.distanceMeters,
  'metadata': activity.metadata,
  'timeZone': zone.id ?? DateTime.now().timeZoneName,
  'note': '第三方源 JSON 仅为活动摘要；完整轨迹请导出 FIT。',
};

/// HealthKit 到 Rust FIT 编码器的唯一输入映射，导出与自动同步共用。
Map<String, Object?> healthWorkoutFitInput(HealthWorkoutBundle bundle) => {
  'uuid': bundle.summary.uuid,
  'startMs': bundle.summary.startMs,
  'endMs': bundle.summary.endMs,
  'durationSeconds': bundle.summary.durationSeconds,
  'activityType': bundle.summary.activityType,
  'totalEnergyKcal': bundle.summary.totalEnergyKcal,
  'totalDistanceMeters': bundle.summary.totalDistanceMeters,
  'events': [
    for (final event in bundle.events)
      {'type': event.type, 'dateMs': event.dateMs},
  ],
  'series': {
    for (final entry in bundle.series.entries)
      entry.key: [
        for (final sample in entry.value)
          {'dateMs': sample.dateMs, 'value': sample.value, 'unit': sample.unit},
      ],
  },
  'route': [
    for (final point in bundle.route)
      {
        'latitude': point.latitude,
        'longitude': point.longitude,
        'altitudeMeters': point.altitudeMeters,
        'timestampMs': point.timestampMs,
        'speedMetersPerSecond': point.speedMetersPerSecond,
      },
  ],
};

Map<String, Object?> _jsonExport(
  HealthWorkoutBundle bundle,
  WorkoutExportTimeZone zone,
) {
  DateTime convert(int milliseconds) => _dateInZone(milliseconds, zone);
  return {
    'id': bundle.summary.uuid,
    'activityType': bundle.summary.activityType,
    'activityName': bundle.summary.activityName,
    'startDate': _iso8601WithOffset(convert(bundle.summary.startMs)),
    'endDate': _iso8601WithOffset(convert(bundle.summary.endMs)),
    'durationSeconds': bundle.summary.durationSeconds,
    'timeZone': zone.id ?? DateTime.now().timeZoneName,
    'metadata': bundle.metadata,
    'events': [
      for (final event in bundle.events)
        {'type': event.type, 'date': _iso8601WithOffset(convert(event.dateMs))},
    ],
    'series': {
      for (final entry in bundle.series.entries)
        entry.key: [
          for (final sample in entry.value)
            {
              'date': _iso8601WithOffset(convert(sample.dateMs)),
              'value': sample.value,
              'unit': sample.unit,
            },
        ],
    },
    'route': [
      for (final point in bundle.route)
        {
          'latitude': point.latitude,
          'longitude': point.longitude,
          if (point.altitudeMeters != null) 'altitude': point.altitudeMeters,
          if (point.timestampMs != null)
            'timestamp': _iso8601WithOffset(convert(point.timestampMs!)),
          if (point.speedMetersPerSecond != null)
            'speed': point.speedMetersPerSecond,
        },
    ],
    if (bundle.summary.totalDistanceMeters != null)
      'totalDistanceMeters': bundle.summary.totalDistanceMeters,
    if (bundle.summary.totalEnergyKcal != null)
      'totalEnergyKilocalories': bundle.summary.totalEnergyKcal,
    if (bundle.summary.sourceName != null)
      'sourceName': bundle.summary.sourceName,
  };
}

String _iso8601WithOffset(DateTime value) {
  final offset = value.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final minutes = offset.inMinutes.abs();
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}T'
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}:'
      '${value.second.toString().padLeft(2, '0')}.'
      '${value.millisecond.toString().padLeft(3, '0')}'
      '$sign${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';
}
