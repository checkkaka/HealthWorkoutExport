import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/activity_detail_page.dart';
import 'package:health_workout_export/fit_merge_page.dart';
import 'package:health_workout_export/sync_preview_models.dart';

import '../integration_test/runtime_callback_completion.dart';

void main() {
  testWidgets('runtime detail export waits beyond frame settlement', (
    tester,
  ) async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final writeFinished = Completer<void>();
    var exported = false;
    final exportCompletion = RuntimeCallbackCompletion();
    await tester.pumpWidget(
      MaterialApp(
        home: WorkoutActivityDetailPage(
          title: 'Synthetic runtime ride',
          sourceTitle: 'Synthetic FIT',
          loadOriginal: () async => bytes,
          inspect: (_) async => const FitPreviewInspection(),
          onExport: (_, actual, synced) => exportCompletion.run(() async {
            await writeFinished.future;
            expect(actual, bytes);
            expect(synced, isFalse);
            exported = true;
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('导出原始 FIT'), 300);
    await tester.tap(find.text('导出原始 FIT'));
    await tester.pumpAndSettle();
    expect(exported, isFalse);
    var waitFinished = false;
    final waiting = exportCompletion
        .wait(timeout: const Duration(seconds: 1))
        .then((_) => waitFinished = true);
    await tester.pump();
    try {
      // Frame settlement must not let the harness advance before file I/O.
      expect(waitFinished, isFalse);
    } finally {
      writeFinished.complete();
      await waiting;
      await tester.pumpAndSettle();
    }
    expect(exported, isTrue);
    expect(waitFinished, isTrue);
  });

  test(
    'runtime callback wait fails if the callback was never invoked',
    () async {
      await expectLater(
        RuntimeCallbackCompletion().wait(timeout: const Duration(seconds: 1)),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('runtime callback wait has a bounded failure', () async {
    final completion = RuntimeCallbackCompletion();
    final gate = Completer<void>();
    final callback = completion.run(() => gate.future);
    try {
      await expectLater(
        completion.wait(timeout: Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
    } finally {
      gate.complete();
      await callback;
    }
  });

  test(
    'runtime callback wait preserves a failure caught by the page',
    () async {
      final completion = RuntimeCallbackCompletion();
      final failure = StateError('byte-exact verification failed');
      try {
        await completion.run(() async => throw failure);
      } catch (_) {
        // The production detail page catches callback errors for its UI.
      }
      await expectLater(
        completion.wait(timeout: const Duration(seconds: 1)),
        throwsA(same(failure)),
      );
    },
  );

  testWidgets('runtime selection waits for the whole imported batch', (
    tester,
  ) async {
    final second = Completer<Uint8List>();
    await tester.pumpWidget(
      MaterialApp(
        home: FitMergePage(
          pickFits: () async => ['/synthetic/one.fit', '/synthetic/two.fit'],
          readFit: (path) async => path.endsWith('one.fit')
              ? Uint8List.fromList([1])
              : second.future,
          validateFit: (_) {},
        ),
      ),
    );
    await tester.tap(find.text('从文件加入'));
    await tester.pumpAndSettle();
    final primary = find.byKey(const ValueKey('mergeFile-0'));
    expect(primary, findsOneWidget);
    expect(tester.widget<ListTile>(primary).onTap, isNull);
    await tester.tap(primary);
    expect(tester.widget<ListTile>(primary).selected, isFalse);
    second.complete(Uint8List.fromList([2]));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mergeFile-1')), findsOneWidget);
    expect(tester.widget<ListTile>(primary).onTap, isNotNull);
    await tester.tap(primary);
    await tester.pump();
    expect(tester.widget<ListTile>(primary).selected, isTrue);
  });
}
