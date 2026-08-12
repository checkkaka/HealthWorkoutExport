import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/native_channels.dart';
import 'package:health_workout_export/workout_export.dart';

void main() {
  final bundle = HealthWorkoutBundle(
    summary: const HealthWorkoutSummary(
      uuid: '123e4567-e89b-12d3-a456-426614174000',
      startMs: 1704067200123,
      endMs: 1704070800456,
      durationSeconds: 3600,
      activityType: 37,
      activityName: '晨跑 / Test',
      sourceName: '健康',
      sourceBundleId: 'com.apple.Health',
      totalEnergyKcal: 321,
      totalDistanceMeters: 9876.5,
    ),
    metadata: const {'weather': 'sunny'},
    events: const [HealthWorkoutEvent(type: 'pause', dateMs: 1704069000000)],
    series: const {
      'HKQuantityTypeIdentifierHeartRate': [
        HealthQuantitySample(
          dateMs: 1704067200123,
          value: 140,
          unit: 'count/min',
        ),
      ],
    },
    route: const [
      HealthRoutePoint(
        latitude: 31.2,
        longitude: 121.5,
        altitudeMeters: 8,
        timestampMs: 1704067200123,
        speedMetersPerSecond: 3.2,
      ),
    ],
  );

  test('JSON 导出保留旧字段、所选时区与临时目录清理', () async {
    final service = WorkoutExportService(
      fitEncoder: ({required bundleJson, required timezoneOffsetSeconds}) {
        fail('JSON 导出不应调用 FIT 编码器');
      },
    );
    final result = await service.export(
      bundles: [bundle],
      format: WorkoutExportFormat.json,
      timeZone: WorkoutExportTimeZone.candidates[1],
    );
    final value = jsonDecode(await result.file.readAsString()) as Map;
    expect(result.file.path.endsWith('.json'), isTrue);
    expect(result.file.uri.pathSegments.last, contains('晨跑_Test'));
    expect(value['id'], bundle.summary.uuid);
    expect(value['timeZone'], 'Asia/Shanghai');
    expect(value['startDate'], contains('+08:00'));
    expect((value['route'] as List).single['altitude'], 8);
    await result.dispose();
    expect(await result.directory.exists(), isFalse);
  });

  test('多条 FIT 导出流式打包为 ZIP，编码器获得每条结束时区偏移', () async {
    final offsets = <int>[];
    final encodedIds = <String>[];
    final second = HealthWorkoutBundle(
      summary: const HealthWorkoutSummary(
        uuid: '123e4567-e89b-12d3-a456-426614174001',
        startMs: 1704067200123,
        endMs: 1704070800456,
        durationSeconds: 3600,
        activityType: 37,
        activityName: '晚跑',
        sourceName: '健康',
        sourceBundleId: 'com.apple.Health',
        totalEnergyKcal: 321,
        totalDistanceMeters: 9876.5,
      ),
      metadata: bundle.metadata,
      events: bundle.events,
      series: bundle.series,
      route: bundle.route,
    );
    final service = WorkoutExportService(
      fitEncoder:
          ({required bundleJson, required timezoneOffsetSeconds}) async {
            offsets.add(timezoneOffsetSeconds);
            final input = jsonDecode(utf8.decode(bundleJson)) as Map;
            encodedIds.add(input['uuid']! as String);
            return Uint8List.fromList(const [0x46, 0x49, 0x54]);
          },
    );
    final result = await service.export(
      bundles: [bundle, second],
      format: WorkoutExportFormat.fit,
      timeZone: WorkoutExportTimeZone.candidates[1],
    );
    final archive = ZipDecoder().decodeBytes(await result.file.readAsBytes());
    expect(result.file.path.endsWith('.zip'), isTrue);
    expect(archive.files.where((file) => file.isFile), hasLength(2));
    expect(encodedIds, [bundle.summary.uuid, second.summary.uuid]);
    expect(offsets, [8 * 3600, 8 * 3600]);
    await result.dispose();
  });
}
