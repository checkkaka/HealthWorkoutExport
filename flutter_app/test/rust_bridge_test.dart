import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/src/rust/api/simple.dart';
import 'package:health_workout_export/src/rust/frb_generated.dart';
import 'package:health_workout_export/strava_upload_api.dart' as upload;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

    const uploadApi = upload.StravaUploadApi();
    final cancelledHandle = uploadApi.reserve('ffi-cancel-before-start');
    expect(uploadApi.cancel(cancelledHandle), isTrue);
    final cancelledUpload = await uploadApi.upload(
      handle: cancelledHandle,
      accessToken: 'token',
      fit: Uint8List.fromList(const [1]),
      externalId: 'external',
      filename: 'ride.fit',
      commute: false,
    );
    expect(cancelledUpload.status, upload.StravaUploadFfiStatus.cancelled);
    expect(
      cancelledUpload.error?.code,
      upload.StravaUploadFfiErrorCode.cancelled,
    );
    expect(cancelledUpload.remoteId, isNull);
    expect(cancelledUpload.retry, isNull);
    expect(uploadApi.cancel(cancelledHandle), isFalse);

    final firstGeneration = uploadApi.reserve('ffi-generation');
    expect(uploadApi.release(firstGeneration), isTrue);
    final secondGeneration = uploadApi.reserve('ffi-generation');
    expect(uploadApi.cancel(firstGeneration), isFalse);
    expect(uploadApi.cancel(secondGeneration), isTrue);
    expect(uploadApi.release(secondGeneration), isTrue);

    final validationHandle = uploadApi.reserve('ffi-preflight');
    expect(
      () => uploadApi.upload(
        handle: validationHandle,
        accessToken: 'token',
        fit: Uint8List(64 * 1024 * 1024 + 1),
        externalId: 'external',
        filename: 'ride.fit',
        commute: false,
      ),
      throwsArgumentError,
    );
    expect(
      () => uploadApi.upload(
        handle: validationHandle,
        accessToken: ''.padRight(8 * 1024 + 1, 'x'),
        fit: Uint8List.fromList(const [1]),
        externalId: 'external',
        filename: 'ride.fit',
        commute: false,
      ),
      throwsArgumentError,
    );
    expect(
      () => uploadApi.upload(
        handle: validationHandle,
        accessToken: 'token',
        fit: Uint8List.fromList(const [1]),
        externalId: 'external',
        filename: 'ride\n.fit',
        commute: false,
      ),
      throwsArgumentError,
    );
    expect(
      () => uploadApi.resumePollAfterRefresh(
        handle: validationHandle,
        accessToken: 'token',
        uploadId: ''.padRight(1025, 'x'),
        pollAttempt: 0,
      ),
      throwsArgumentError,
    );
    for (final secretCase in <({String token, String? description})>[
      (token: 'do-not-leak-token\n', description: null),
      (token: 'token', description: 'do-not-leak-description\n'),
    ]) {
      try {
        uploadApi.upload(
          handle: validationHandle,
          accessToken: secretCase.token,
          fit: Uint8List.fromList(const [1]),
          externalId: 'external',
          filename: 'ride.fit',
          commute: false,
          description: secretCase.description,
        );
        fail('应在进入 FFI 前拒绝秘密中的控制字符');
      } on ArgumentError catch (error) {
        expect(error.toString(), isNot(contains('do-not-leak')));
      }
    }
    expect(uploadApi.release(validationHandle), isFalse);
    final replacement = uploadApi.reserve('ffi-preflight');
    expect(uploadApi.release(replacement), isTrue);

    const keychain = MethodChannel('health_workout_export/keychain');
    var refreshCount = 0;
    Map<Object?, Object?>? committed;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keychain, (call) async {
          switch (call.method) {
            case 'stravaLease':
              final purpose =
                  (call.arguments as Map<Object?, Object?>)['purpose'];
              if (purpose == 'upload') {
                return <String, Object>{
                  'accessToken': 'expired-access',
                  'expiresAtSeconds': 1.0,
                };
              }
              return <String, Object>{
                'clientId': 'client',
                'clientSecret': 'secret',
                'refreshToken': 'refresh',
                'expiresAtSeconds': 1.0,
              };
            case 'writeStravaAuthorization':
              committed = Map<Object?, Object?>.from(
                call.arguments as Map<Object?, Object?>,
              );
              return null;
          }
          throw MissingPluginException(call.method);
        });
    try {
      final session = upload.StravaUploadSession(
        refreshToken:
            ({
              required clientId,
              required clientSecret,
              required refreshToken,
            }) async {
              refreshCount += 1;
              return const StravaTokenResult(
                accessToken: 'rotated-access',
                refreshToken: 'rotated-refresh',
                expiresAt: 2000000000,
              );
            },
      );
      final task = session.start(
        logicalOperationId: 'ffi-session-refresh-cancel',
        fit: Uint8List.fromList(const [1]),
        externalId: 'external',
        filename: 'ride.fit',
        commute: false,
      );
      expect(task.cancel(), isTrue);
      final result = await task.result;
      expect(result.status, upload.StravaUploadFfiStatus.cancelled);
      expect(refreshCount, 1);
      expect(committed?['accessToken'], 'rotated-access');
      expect(committed?['refreshToken'], 'rotated-refresh');
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(keychain, null);
    }
  });
}
