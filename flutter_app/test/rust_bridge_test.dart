import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/src/rust/api/simple.dart';
import 'package:health_workout_export/src/rust/frb_generated.dart';

void main() {
  test('Flutter 通过真实 Rust 核心判定通勤', () async {
    final rustRoot = Directory('../rust/workout_core').absolute;
    final build = await Process.run(
      'cargo',
      ['build'],
      workingDirectory: rustRoot.path,
    );
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

    expect(
      isCommute(distanceMeters: 4000, durationSeconds: 1200),
      isTrue,
    );
    expect(
      isCommute(distanceMeters: 20000, durationSeconds: 2400),
      isFalse,
    );
  });
}
