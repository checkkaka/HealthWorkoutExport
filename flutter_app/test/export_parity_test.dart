import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/native_channels.dart';
import 'package:health_workout_export/workout_export.dart';

WorkoutExportActivity activity({
  String id = '7',
  String title = '晨骑',
  String source = 'xingzhe',
  double? distance,
}) => WorkoutExportActivity(
  id: id,
  sourceId: source,
  title: title,
  start: DateTime.utc(2024, 3, 31, 0, 30),
  end: DateTime.utc(2024, 3, 31, 1, 30),
  durationSeconds: 3600,
  distanceMeters: distance,
);

void main() {
  test('第三方摘要 JSON 契约包含真实摘要、时区，且无伪造明细', () async {
    final source = activity(distance: 12000);
    final result = await WorkoutExportService().exportActivities(
      activities: [source],
      format: WorkoutExportFormat.json,
      timeZone: WorkoutExportTimeZone.resolvedCurrent('Europe/London'),
      loadFit: (_) async => fail('JSON 不下载 FIT'),
    );
    addTearDown(result.dispose);
    final value = jsonDecode(await result.file.readAsString()) as Map;
    expect(value, {
      'id': '7',
      'sourceId': 'xingzhe',
      'title': '晨骑',
      'startDate': '2024-03-31T00:30:00.000+00:00',
      'endDate': '2024-03-31T02:30:00.000+01:00',
      'durationSeconds': 3600,
      'totalDistanceMeters': 12000,
      'metadata': {},
      'timeZone': 'Europe/London',
      'note': '第三方源 JSON 仅为活动摘要；完整轨迹请导出 FIT。',
    });
    expect(value.containsKey('route'), isFalse);
    expect(value.containsKey('series'), isFalse);
  });

  test('第三方缺失距离省略而非伪造零值', () async {
    final result = await WorkoutExportService().exportActivities(
      activities: [activity(source: 'onelap')],
      format: WorkoutExportFormat.json,
      timeZone: WorkoutExportTimeZone.candidates[1],
    );
    addTearDown(result.dispose);
    final value = jsonDecode(await result.file.readAsString()) as Map;
    expect(value.containsKey('totalDistanceMeters'), isFalse);
    expect(value['sourceId'], 'onelap');
    expect(value['timeZone'], 'Asia/Shanghai');
  });

  test('原始 FIT 字节不改写，单文件直接输出', () async {
    final bytes = Uint8List.fromList([0, 1, 2, 255, 14, 46, 70, 73, 84]);
    final result = await WorkoutExportService().exportActivities(
      activities: [activity()],
      format: WorkoutExportFormat.fit,
      timeZone: WorkoutExportTimeZone.candidates[1],
      loadFit: (_) async => bytes,
    );
    addTearDown(result.dispose);
    expect(result.file.path, endsWith('.fit'));
    expect(await result.file.readAsBytes(), bytes);
  });

  test('同分钟同名和相同 ID 前缀仍保留所有 ZIP 文件', () async {
    final first = activity(id: '12345678-a');
    final second = activity(id: '12345678-b');
    final progress = <int>[];
    final result = await WorkoutExportService().exportActivities(
      activities: [first, second],
      format: WorkoutExportFormat.fit,
      timeZone: WorkoutExportTimeZone.candidates[1],
      loadFit: (item) async => Uint8List.fromList(utf8.encode(item.id)),
      onProgress: (value) => progress.add(value.completed),
    );
    addTearDown(result.dispose);
    final files = ZipDecoder()
        .decodeBytes(await result.file.readAsBytes())
        .files;
    expect(files, hasLength(2));
    expect(files.map((file) => file.name).toSet(), hasLength(2));
    expect(
      files.map((file) => utf8.decode(file.content as List<int>)).toSet(),
      {'12345678-a', '12345678-b'},
    );
    expect(progress, [0, 1, 2]);
  });

  test('短 ID、不可信路径和长中文标题产生安全且受限的文件名', () async {
    for (final id in ['', '7', '../../x', 'a\\b:\u0000']) {
      final result = await WorkoutExportService().exportActivities(
        activities: [activity(id: id, title: '${'骑行' * 180}/../:*?"<>|')],
        format: WorkoutExportFormat.json,
        timeZone: WorkoutExportTimeZone.candidates[1],
      );
      addTearDown(result.dispose);
      final name = result.file.uri.pathSegments.last;
      expect(utf8.encode(name).length, lessThan(255));
      expect(name.contains(RegExp(r'[\\/:*?"<>|\x00-\x1F]')), isFalse);
      expect(result.file.parent.path, result.directory.path);
    }
  });

  test('健康短 UUID 不发生 substring 越界', () async {
    final bundle = HealthWorkoutBundle(
      summary: const HealthWorkoutSummary(
        uuid: '7',
        startMs: 1704067200000,
        endMs: 1704070800000,
        durationSeconds: 3600,
        activityType: 13,
        activityName: '骑车',
        sourceName: null,
        sourceBundleId: null,
        totalEnergyKcal: null,
        totalDistanceMeters: null,
      ),
      metadata: const {},
      events: const [],
      series: const {},
      route: const [],
    );
    final result = await WorkoutExportService().export(
      bundles: [bundle],
      format: WorkoutExportFormat.json,
      timeZone: WorkoutExportTimeZone.candidates[1],
    );
    addTearDown(result.dispose);
    expect(result.file.path, endsWith('_7.json'));
  });

  test('批次中途失败清理本次临时目录且不返回残缺结果', () async {
    Future<Set<String>> directories() async =>
        (await Directory.systemTemp.list().toList())
            .whereType<Directory>()
            .map((directory) => directory.path)
            .where((path) => path.contains('health-workout-export-'))
            .toSet();
    final before = await directories();
    final progress = <int>[];
    await expectLater(
      WorkoutExportService().exportActivities(
        activities: [
          activity(id: '1'),
          activity(id: '2'),
        ],
        format: WorkoutExportFormat.fit,
        timeZone: WorkoutExportTimeZone.candidates[1],
        loadFit: (item) async {
          if (item.id == '2') throw StateError('下载失败');
          return Uint8List.fromList([1]);
        },
        onProgress: (value) => progress.add(value.completed),
      ),
      throwsStateError,
    );
    expect((await directories()).difference(before), isEmpty);
    expect(progress, [0, 1]);
  });

  test('同步 FIT 仅匹配相同源和 ID 的已上传记录，并回退最近存在文件', () async {
    final item = activity();
    final missing = 'a' * 64;
    final existing = 'b' * 64;
    final pending = 'c' * 64;
    final otherSource = 'd' * 64;
    final calls = <String>[];
    final store = SyncedFitExportStore(
      loadRecords: () async => {
        missing: _record(updated: 5),
        existing: _record(updated: 4),
        pending: _record(updated: 6, status: 'pending'),
        otherSource: _record(updated: 7, source: 'onelap'),
        '../invalid': _record(updated: 8),
      },
      readFit: (fingerprint) async {
        calls.add(fingerprint);
        if (fingerprint == missing) {
          throw PlatformException(code: 'sync_file_missing');
        }
        return Uint8List.fromList([1, 2, 3]);
      },
    );
    final available = await store.available([item]);
    expect(available, {item.key: existing});
    expect(calls, [missing, existing]);
    expect(await store.read(item, available), [1, 2, 3]);
  });

  test('同步文件检查后消失时导出失败，绝不悄悄改用源文件', () async {
    final item = activity();
    var exists = true;
    final fingerprint = 'a' * 64;
    final store = SyncedFitExportStore(
      loadRecords: () async => {fingerprint: _record()},
      readFit: (_) async {
        if (!exists) throw PlatformException(code: 'sync_file_missing');
        return Uint8List.fromList([1]);
      },
    );
    final available = await store.available([item]);
    exists = false;
    await expectLater(store.read(item, available), throwsStateError);
    await expectLater(store.read(item, const {}), throwsStateError);
  });

  test('非缺失的同步文件读取失败不能误报成无文件', () async {
    final store = SyncedFitExportStore(
      loadRecords: () async => {'a' * 64: _record()},
      readFit: (_) async =>
          throw PlatformException(code: 'protected_data_unavailable'),
    );
    await expectLater(
      store.available([activity()]),
      throwsA(isA<PlatformException>()),
    );
  });
}

Map<String, Object?> _record({
  int updated = 1,
  String status = 'uploaded',
  String source = 'xingzhe',
}) => {
  'status': status,
  'primarySourceId': source,
  'primaryActivityId': '7',
  'updatedAt': updated,
};
