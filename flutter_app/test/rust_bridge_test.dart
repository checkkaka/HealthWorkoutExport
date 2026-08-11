import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/src/rust/api/simple.dart';
import 'package:health_workout_export/src/rust/frb_generated.dart';

void main() {
  test('Flutter 通过真实 Rust 核心判定通勤', () async {
    final rustRoot = Directory('../rust/workout_core').absolute;
    final build = await Process.run('cargo', [
      'build',
    ], workingDirectory: rustRoot.path);
    expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');

    final fileName = Platform.isWindows
        ? 'rust_lib_health_workout_export.dll'
        : Platform.isMacOS
        ? 'librust_lib_health_workout_export.dylib'
        : 'librust_lib_health_workout_export.so';
    final library = File(
      '${rustRoot.path}${Platform.pathSeparator}target'
      '${Platform.pathSeparator}debug${Platform.pathSeparator}$fileName',
    );
    expect(library.existsSync(), isTrue);
    await WorkoutCoreRustLib.init(
      externalLibrary: ExternalLibrary.open(library.path),
    );

    expect(isCommute(distanceMeters: 4000, durationSeconds: 1200), isTrue);
    expect(isCommute(distanceMeters: 20000, durationSeconds: 2400), isFalse);

    final fit = Uint8List.fromList(const [
      0x0E,
      0x20,
      0xD5,
      0x52,
      0x20,
      0,
      0,
      0,
      0x2E,
      0x46,
      0x49,
      0x54,
      0x6F,
      0x47,
      0x40,
      0,
      0,
      0x14,
      0,
      4,
      0xFD,
      4,
      0x86,
      0,
      4,
      0x85,
      1,
      4,
      0x85,
      3,
      1,
      2,
      0,
      0x11,
      0x22,
      0x33,
      0x44,
      4,
      3,
      2,
      1,
      8,
      7,
      6,
      5,
      0x8C,
      0xD9,
      0xFB,
    ]);
    final summary = fitContentSummary(data: fit);
    expect(summary.gpsPointCount, 1);
    expect(summary.heartRatePointCount, 1);
    expect(summary.qualityScore, 11);
    expect(reencodeFit(data: fit), fit);
    expect(
      isValidFit(data: Uint8List.fromList('{"error":true}'.codeUnits)),
      isFalse,
    );

    await expectLater(
      stravaExchangeCode(clientId: '', clientSecret: 'secret', code: 'code'),
      throwsA(anything),
    );
  });
}
