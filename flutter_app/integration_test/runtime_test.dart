import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:health_workout_export/activity_detail_page.dart';
import 'package:health_workout_export/auto_sync_session.dart';
import 'package:health_workout_export/fit_merge_page.dart';
import 'package:health_workout_export/main.dart';
import 'package:health_workout_export/native_channels.dart';
import 'package:health_workout_export/recovery_batch_checkpoint.dart';
import 'package:health_workout_export/src/rust/api/simple.dart' as rust;
import 'package:health_workout_export/src/rust/frb_generated.dart';
import 'package:health_workout_export/sync_preview_models.dart';
import 'package:health_workout_export/sync_state_store.dart';
import 'package:health_workout_export/workout_export.dart';

import 'runtime_fixture.dart';

const phase = String.fromEnvironment('HWE_RUNTIME_PHASE');
final fingerprint = 'b' * 64;
const nativeFiles = SyncFilesChannel();
const healthChannel = MethodChannel('health_workout_export/healthkit');
final captureKey = GlobalKey();
final checks = <String>[];
final screenshots = <Map<String, String>>[];

// This is an on-device integration test, not a host widget test. The production
// app, engine, Rust library, preferences and sync file plugins are real. Only
// external health data/authorization, file-picker selection and OS sharing are
// synthetic boundaries. No native permission grants or remote account actions.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('runtime $phase: real Flutter, Rust and platform storage', (
    tester,
  ) async {
    expect(['startup', 'seed', 'verify'], contains(phase));
    binding.reportData = {
      'phase': phase,
      'pid': pid,
      'checks': checks,
      'screenshots': screenshots,
    };
    await WorkoutCoreRustLib.init();
    final fit = await fixtureFit();
    expect(rust.isValidFit(data: fit), isTrue);
    final inspected =
        jsonDecode(await rust.inspectFitPreview(data: fit)) as Map;
    expect(inspected['summary']['recordCount'], 2);
    checks.add('bundled-rust-ffi-encode-and-preview');

    // Availability does not request authorization or read personal health data.
    if (!Platform.isWindows) {
      expect(await const HealthKitChannel().isAvailable(), isA<bool>());
    }
    final writable = await const HealthKitChannel().canWriteWorkouts();
    if (Platform.isAndroid || Platform.isWindows) expect(writable, isFalse);
    checks.add('native-health-capability-probe-no-authorization');

    const preferences = PreferencesChannel();
    if (phase == 'verify') {
      expect(await preferences.read('sync_preview_policy'), 'everyActivity');
      expect(await nativeFiles.readSyncedFit(fingerprint), fit);
      final checkpoint = RecoveryBatchCheckpoint.decode(
        await nativeFiles.readBatchSession(),
      );
      expect(checkpoint.generationId, 'c' * 64);
      expect(checkpoint.fingerprints, [fingerprint]);
      expect(checkpoint.needsStrava(fingerprint), isTrue);
      final record = await SyncStateStore().recordFor(fingerprint);
      expect(record?['primaryActivityId'], 'runtime-synthetic-activity');
      expect(record?['status'], 'pending');
      final restored = AutoSyncSession();
      await restored.restore();
      expect(restored.restoreError, isNull);
      expect(restored.progress.total, 1);
      expect(restored.progress.processed, 0);
      expect(restored.progress.message, contains('恢复'));
      expect(restored.isRunning, isFalse);
      restored.cancel();
      expect(restored.cancelled, isTrue);
      restored.dispose();
      checks.add(
        'new-process-native-files-preferences-and-production-session-restoration',
      );
    } else {
      await preferences.write('sync_preview_policy', 'everyActivity');
      expect(await preferences.read('sync_preview_policy'), 'everyActivity');
      checks.add('native-preferences-roundtrip');
    }

    // Explicit synthetic health boundary prevents automatic system permission
    // UI. Native availability above was called before installing this adapter.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      healthChannel,
      (call) async => switch (call.method) {
        'isAvailable' => false,
        'canWriteWorkouts' => false,
        _ => throw StateError(
          'Unexpected synthetic health call: ${call.method}',
        ),
      },
    );
    addTearDown(() => messenger.setMockMethodCallHandler(healthChannel, null));
    await tester.pumpWidget(
      RepaintBoundary(key: captureKey, child: const HealthWorkoutExportApp()),
    );
    await tester.pumpAndSettle();
    expect(find.text('健康训练'), findsOneWidget);
    for (final label in ['行者', '顽鹿', '健康']) {
      await tester.tap(find.widgetWithText(NavigationDestination, label));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('合并 FIT'));
    await tester.pumpAndSettle();
    expect(find.byType(FitMergePage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('健康训练'), findsOneWidget);
    checks.add('production-root-tabs-navigation-and-back');
    await screenshot(tester, 'root-$phase');

    if (phase == 'seed') {
      await functionalFlow(tester, fit);
      // Fail closed if these tests were accidentally pointed at a used account.
      expect(await SyncStateStore().allRecords(), isEmpty);
      await SyncStateStore().savePendingFit(
        record: SyncPendingRecord(
          fingerprint: fingerprint,
          primarySourceId: 'onelap',
          primaryActivityId: 'runtime-synthetic-activity',
          updatedAt: DateTime.utc(2024),
          title: 'Synthetic runtime fixture',
        ),
        fit: fit,
      );
      await nativeFiles.writeBatchSession(
        RecoveryBatchCheckpoint(
          fingerprints: [fingerprint],
          replaceExisting: false,
          generationId: 'c' * 64,
          uploadToStrava: true,
          writeToHealth: false,
        ).encode(),
      );
      expect(await nativeFiles.readSyncedFit(fingerprint), fit);
      checks.add('durable-recovery-seed-before-host-process-termination');
      await screenshot(tester, 'durable-seed');
    }
    if (phase == 'verify') {
      // Only our reserved synthetic records are removed, after proving recovery.
      await SyncStateStore().remove(fingerprint);
      await nativeFiles.deleteBatchSession();
      checks.add('synthetic-runtime-data-cleanup');
    }
    expect(tester.takeException(), isNull);
    binding.reportData = {
      'phase': phase,
      'pid': pid,
      'checks': checks,
      'screenshots': screenshots,
      'boundaries': [
        'synthetic health availability for UI only',
        'synthetic file selection',
        'share callback validates file, no OS share sheet',
        'no OAuth, remote uploads or health writes',
      ],
    };
  }, timeout: const Timeout(Duration(minutes: 4)));
}

Future<void> screenshot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  final boundary =
      captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(bytes, isNotNull);
    screenshots.add({
      'name': name,
      'pngBase64': base64Encode(bytes!.buffer.asUint8List()),
    });
  } finally {
    image.dispose();
  }
}

Future<void> showPage(WidgetTester tester, Widget page) async {
  final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
  nav.push(MaterialPageRoute<void>(builder: (_) => page));
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).last,
    );
  } else {
    await tester.ensureVisible(finder);
  }
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> functionalFlow(WidgetTester tester, Uint8List fit) async {
  final directory = await Directory.systemTemp.createTemp(
    'hwe-runtime-fixtures-',
  );
  final first = File('${directory.path}/synthetic-primary.fit');
  final second = File('${directory.path}/synthetic-sensors.fit');
  await first.writeAsBytes(await fixtureFit(sensors: false), flush: true);
  await second.writeAsBytes(fit, flush: true);
  WorkoutExportResult? exported;
  var selections = 0;
  final selectionGate = Completer<List<String>>();
  try {
    await showPage(
      tester,
      FitMergePage(
        // First selection is cancelled; subsequent selection imports two real
        // local files. Rust validation and merge use production implementations.
        pickFits: () async => ++selections == 1 ? [] : selectionGate.future,
        shareResult: (result) async {
          expect(await result.file.exists(), isTrue);
          expect(
            rust.isValidFit(data: await result.file.readAsBytes()),
            isTrue,
          );
          exported = result;
        },
      ),
    );
    await tapVisible(tester, find.text('从文件加入'));
    expect(find.byKey(const ValueKey('mergeFile-0')), findsNothing);
    await tapVisible(tester, find.text('从文件加入'));
    // A second click while selection is pending must not create another request.
    await tapVisible(tester, find.text('从文件加入'));
    expect(selections, 2);
    selectionGate.complete([first.path, second.path]);
    for (
      var i = 0;
      i < 100 && find.byKey(const ValueKey('mergeFile-0')).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mergeFile-0')), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('mergeFile-0')));
    await tapVisible(tester, find.widgetWithText(FilledButton, '合并 FIT'));
    // Native async Rust/I/O can need additional frames after the spinner settles.
    for (var i = 0; i < 100 && find.text('结果已生成').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('结果已生成'), findsOneWidget);
    await tapVisible(tester, find.text('分享结果'));
    expect(exported, isNotNull);
    final merged = await exported!.file.readAsBytes();
    final inspection = FitPreviewInspection.decode(
      await rust.inspectFitPreview(data: merged),
    );
    expect(inspection.summary['heartRateCount'], 2);
    checks.add(
      'synthetic-file-selection-cancel-real-fit-import-rust-merge-export',
    );
    await screenshot(tester, 'merged-export');
    // Cancel the destructive dialog, proving the real generated file survives.
    await tapVisible(tester, find.text('删除结果'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await exported!.file.exists(), isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    var exportedFromDetail = false;
    await showPage(
      tester,
      WorkoutActivityDetailPage(
        title: 'Synthetic runtime ride',
        sourceTitle: 'Synthetic FIT',
        loadOriginal: () async => merged,
        inspect: (bytes) async => FitPreviewInspection.decode(
          await rust.inspectFitPreview(data: bytes),
        ),
        onExport: (_, bytes, synced) async {
          expect(bytes, merged);
          expect(synced, isFalse);
          final output = File('${directory.path}/detail-export.fit');
          await output.writeAsBytes(bytes, flush: true);
          expect(await output.readAsBytes(), merged);
          exportedFromDetail = true;
        },
      ),
    );
    expect(find.text('概览'), findsOneWidget);
    await screenshot(tester, 'fit-preview');
    await tapVisible(tester, find.text('导出原始 FIT'));
    expect(exportedFromDetail, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    checks.add('real-detail-preview-export-cancel-and-return');
  } finally {
    if (exported != null) await exported!.directory.delete(recursive: true);
    await directory.delete(recursive: true);
  }
}
