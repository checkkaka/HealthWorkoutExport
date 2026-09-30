import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/apple_health_import.dart';
import 'package:health_workout_export/apple_health_import_dialog.dart';

const fingerprint = 'saved-fit-fingerprint';
const workoutId = '12345678-1234-4234-8234-123456789abc';
const otherWorkoutId = '22345678-1234-4234-8234-123456789abc';
final start = DateTime.utc(2026, 9, 30, 8);
final end = start.add(const Duration(hours: 1));

void main() {
  late Harness h;
  setUp(() => h = Harness());

  test(
    'writes final FIT draft and persists independent Health flags',
    () async {
      final result = await h.run();
      expect(result.outcome, AppleHealthImportOutcome.written);
      expect(result.uuid, workoutId);
      expect(h.events, [
        'record',
        'available',
        'authorize',
        'decode',
        'nearby',
        'write',
        'written',
      ]);
      expect(h.writtenDraft, h.draft);
      expect(h.saved['status'], 'uploaded');
      expect(h.saved['remoteId'], 'strava-id');
      expect(h.saved['appleHealthUUID'], workoutId);
      expect(
        h.queryStart,
        start.subtract(const Duration(minutes: 15)).millisecondsSinceEpoch,
      );
      expect(
        h.queryEnd,
        end.add(const Duration(minutes: 15)).millisecondsSinceEpoch,
      );
    },
  );
  for (final record in [
    {'appleHealthUUID': workoutId},
    {'appleHealthSkipped': true},
  ]) {
    test('recorded Health outcome is idempotent: $record', () async {
      h.saved.addAll(record);
      expect((await h.run()).outcome, AppleHealthImportOutcome.skipped);
      expect(h.events, ['record']);
    });
  }
  test(
    'requires a saved record and final FIT without fetching a source',
    () async {
      h.missingRecord = true;
      expect((await h.run()).outcome, AppleHealthImportOutcome.failed);
      expect(h.events, ['record']);
      h.missingRecord = false;
      h.events.clear();
      expect(
        (await h.run(fit: Uint8List(0))).outcome,
        AppleHealthImportOutcome.failed,
      );
      expect(h.events, ['record', 'failed']);
    },
  );
  test(
    'recorded outcome does not require FIT or authorization again',
    () async {
      h.saved['appleHealthUUID'] = workoutId;
      expect(
        (await h.run(fit: Uint8List(0))).outcome,
        AppleHealthImportOutcome.skipped,
      );
      expect(h.events, ['record']);
    },
  );
  test('exact native fingerprint recovers state before prompting', () async {
    h.nearby = [nearby(), nearby(uuid: workoutId, syncIdentifier: fingerprint)];
    final result = await h.run();
    expect(result.outcome, AppleHealthImportOutcome.skipped);
    expect(result.uuid, workoutId);
    expect(h.saved['appleHealthUUID'], workoutId);
    expect(h.events, [
      'record',
      'available',
      'authorize',
      'decode',
      'nearby',
      'written',
    ]);
  });
  test(
    'draft timing drives duplicate detection rather than stale metadata',
    () async {
      final actualStart = start.add(const Duration(days: 1));
      h.draft = draftBytes(startDate: actualStart);
      h.nearby = [nearby(startDate: actualStart)];
      h.decision = AppleHealthNearbyDecision.skipOnce;
      expect((await h.run()).outcome, AppleHealthImportOutcome.skipped);
      expect(
        h.queryStart,
        actualStart
            .subtract(const Duration(minutes: 15))
            .millisecondsSinceEpoch,
      );
      expect(h.prompts.single.nearbySummary, contains('0.0'));
    },
  );
  for (final choice in AppleHealthNearbyDecision.values) {
    test(
      'nearby decision $choice follows Swift persistence semantics',
      () async {
        h.nearby = [nearby()];
        h.decision = choice;
        if (choice == AppleHealthNearbyDecision.cancelBatch) {
          await expectLater(
            h.run(),
            throwsA(isA<AppleHealthImportCancelled>()),
          );
          expect(h.events, isNot(contains('write')));
          expect(h.events, isNot(contains('skipped')));
          expect(h.events, isNot(contains('failed')));
          await expectLater(
            h.run(),
            throwsA(isA<AppleHealthImportCancelled>()),
          );
        } else {
          final result = await h.run();
          final writes =
              choice == AppleHealthNearbyDecision.write ||
              choice == AppleHealthNearbyDecision.writeRestOfBatch;
          expect(
            result.outcome,
            writes
                ? AppleHealthImportOutcome.written
                : AppleHealthImportOutcome.skipped,
          );
          expect(h.events.contains('write'), writes);
          expect(
            h.saved['appleHealthSkipped'] == true,
            choice == AppleHealthNearbyDecision.skip ||
                choice == AppleHealthNearbyDecision.skipRestOfBatch,
          );
        }
        expect(h.prompts.single.nearbySummary, contains('不能覆盖或删除'));
      },
    );
  }
  for (final choice in [
    AppleHealthNearbyDecision.writeRestOfBatch,
    AppleHealthNearbyDecision.skipRestOfBatch,
  ]) {
    test(
      '$choice only applies to later overlaps and resets per batch',
      () async {
        h.nearby = [nearby()];
        h.decision = choice;
        await h.run();
        h.resetRecord();
        await h.run();
        expect(h.prompts, hasLength(1));
        h.resetRecord();
        h.nearby = [];
        expect((await h.run()).outcome, AppleHealthImportOutcome.written);
        h.resetRecord();
        h.nearby = [nearby()];
        h.pass.beginBatch();
        await h.run();
        expect(h.prompts, hasLength(2));
        expect(h.events.where((event) => event == 'authorize'), hasLength(2));
      },
    );
  }
  test('skip-once is retried without persisting', () async {
    h.nearby = [nearby()];
    h.decision = AppleHealthNearbyDecision.skipOnce;
    await h.run();
    await h.run();
    expect(h.prompts, hasLength(2));
    expect(h.events, isNot(contains('skipped')));
  });
  for (final event in [
    'record',
    'available',
    'authorize',
    'decode',
    'nearby',
    'prompt',
  ]) {
    test(
      'cancellation after $event blocks writes and state mutations',
      () async {
        h.nearby = [nearby()];
        h.cancelAfter = event;
        await expectLater(h.run(), throwsA(isA<AppleHealthImportCancelled>()));
        expect(h.events, isNot(contains('write')));
        expect(h.events, isNot(contains('skipped')));
        expect(h.events, isNot(contains('failed')));
      },
    );
  }
  test('successful in-flight write persists despite cancellation', () async {
    h.cancelAfter = 'write';
    expect((await h.run()).outcome, AppleHealthImportOutcome.written);
    expect(h.saved['appleHealthUUID'], workoutId);
    await expectLater(h.run(), throwsA(isA<AppleHealthImportCancelled>()));
    h.cancelled = false;
    h.pass.beginBatch();
    expect((await h.run()).outcome, AppleHealthImportOutcome.skipped);
    expect(h.events.where((event) => event == 'write'), hasLength(1));
  });
  test('cancel method prevents processing until next batch', () async {
    h.pass.cancel();
    await expectLater(h.run(), throwsA(isA<AppleHealthImportCancelled>()));
    expect(h.events, isEmpty);
    h.pass.beginBatch();
    expect((await h.run()).outcome, AppleHealthImportOutcome.written);
  });
  test('unsupported platform fails without authorization', () async {
    h.available = false;
    expect((await h.run()).outcome, AppleHealthImportOutcome.failed);
    expect(h.events, ['record', 'available', 'failed']);
    expect(h.saved['status'], 'uploaded');
  });
  for (final event in ['authorize', 'decode', 'nearby', 'write']) {
    test('$event error only changes Health flags and permits retry', () async {
      h.errorAt = event;
      expect((await h.run()).outcome, AppleHealthImportOutcome.failed);
      expect(h.saved['status'], 'uploaded');
      expect(h.saved['appleHealthError'], contains(event));
      h.errorAt = null;
      expect((await h.run()).outcome, AppleHealthImportOutcome.written);
      expect(h.saved['appleHealthError'], isNull);
    });
  }
  test('partial native write persists UUID and warns without retry', () async {
    h.writeError = PlatformException(
      code: 'healthkit_write_partial',
      message: 'route failed',
      details: {'uuid': workoutId, 'fingerprint': fingerprint},
    );
    final result = await h.run();
    expect(result.outcome, AppleHealthImportOutcome.writtenWithWarning);
    expect(result.uuid, workoutId);
    expect(result.message, contains('路线'));
    expect(h.saved['appleHealthUUID'], workoutId);
    expect(h.saved['appleHealthError'], contains('路线'));
    expect(h.events.indexOf('written'), lessThan(h.events.indexOf('failed')));
    expect((await h.run()).outcome, AppleHealthImportOutcome.skipped);
    expect(h.events.where((event) => event == 'write'), hasLength(1));
  });
  test('partial write persists even after in-flight cancellation', () async {
    h.cancelAfter = 'write';
    h.writeError = PlatformException(
      code: 'healthkit_write_partial',
      details: {'uuid': workoutId, 'fingerprint': fingerprint},
    );
    expect(
      (await h.run()).outcome,
      AppleHealthImportOutcome.writtenWithWarning,
    );
    expect(h.saved['appleHealthUUID'], workoutId);
  });
  for (final details in [
    {'uuid': workoutId, 'fingerprint': 'other-fit'},
    {'uuid': 'invalid', 'fingerprint': fingerprint},
    {'uuid': workoutId},
    null,
  ]) {
    test(
      'invalid partial-write details never mark completion: $details',
      () async {
        h.writeError = PlatformException(
          code: 'healthkit_write_partial',
          details: details,
        );
        expect((await h.run()).outcome, AppleHealthImportOutcome.failed);
        expect(h.saved['appleHealthUUID'], isNull);
        expect(h.events, isNot(contains('written')));
      },
    );
  }
  test('invalid write UUID cannot mark completion', () async {
    h.writeUuid = '';
    expect((await h.run()).outcome, AppleHealthImportOutcome.failed);
    expect(h.saved['appleHealthUUID'], isNull);
  });
  test(
    'draft fingerprint mismatch fails before Health query or write',
    () async {
      h.draft = draftBytes(fingerprintValue: 'wrong');
      expect((await h.run()).outcome, AppleHealthImportOutcome.failed);
      expect(h.events, isNot(contains('nearby')));
      expect(h.events, isNot(contains('write')));
    },
  );
  test('malformed draft timing fails closed', () async {
    h.draft = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'fingerprint': fingerprint,
          'startMs': 'yesterday',
          'endMs': end.millisecondsSinceEpoch,
          'durationSeconds': 3600,
        }),
      ),
    );
    expect((await h.run()).outcome, AppleHealthImportOutcome.failed);
    expect(h.events, isNot(contains('write')));
  });
  for (final partial in [false, true]) {
    test(
      'local success-save failure retains native UUID and retries only persistence (partial=$partial)',
      () async {
        h.errorAt = 'written';
        if (partial) {
          h.writeError = PlatformException(
            code: 'healthkit_write_partial',
            details: {'uuid': workoutId, 'fingerprint': fingerprint},
          );
        }
        final first = await h.run();
        expect(first.outcome, AppleHealthImportOutcome.failed);
        expect(first.uuid, workoutId);
        expect(first.message, contains('请勿重复写入'));
        expect(h.saved['appleHealthUUID'], isNull);
        expect(h.events, isNot(contains('failed')));
        h.errorAt = null;
        h.pass.beginBatch();
        final retry = await h.run();
        expect(
          retry.outcome,
          partial
              ? AppleHealthImportOutcome.writtenWithWarning
              : AppleHealthImportOutcome.written,
        );
        expect(h.saved['appleHealthUUID'], workoutId);
        expect(h.events.where((event) => event == 'write'), hasLength(1));
      },
    );
  }
  test(
    'failed persistence after in-flight cancellation still reports native UUID',
    () async {
      h.cancelAfter = 'write';
      h.errorAt = 'written';
      final result = await h.run();
      expect(result.outcome, AppleHealthImportOutcome.failed);
      expect(result.uuid, workoutId);
      expect(h.events, isNot(contains('failed')));
    },
  );
  test(
    'concurrent clicks cannot authorize or write twice or reset batch in flight',
    () async {
      final barrier = Completer<void>();
      h.recordBarrier = barrier.future;
      final first = h.run();
      await expectLater(h.run(), throwsStateError);
      expect(h.pass.beginBatch, throwsStateError);
      expect(h.events, ['record']);
      barrier.complete();
      expect((await first).outcome, AppleHealthImportOutcome.written);
      expect(h.events.where((event) => event == 'write'), hasLength(1));
    },
  );
  test(
    'cancel method after an asynchronous read prevents all downstream effects',
    () async {
      final barrier = Completer<void>();
      h.recordBarrier = barrier.future;
      final processing = h.run();
      h.pass.cancel();
      barrier.complete();
      await expectLater(processing, throwsA(isA<AppleHealthImportCancelled>()));
      expect(h.events, ['record']);
    },
  );
  test(
    'error while saving failed status remains visible to the caller',
    () async {
      h.writeError = StateError('native write failure');
      h.errorAt = 'failed';
      final result = await h.run();
      expect(result.outcome, AppleHealthImportOutcome.failed);
      expect(result.message, contains('错误状态保存失败'));
      expect(result.message, contains('native write failure'));
    },
  );
  group('Health proximity', () {
    test('large start offset matches via interval IoU', () {
      expect(
        HealthProximity.overlapping(
          start: start,
          end: end,
          duration: 3600,
          nearby: [nearby(startDate: start.add(const Duration(minutes: 20)))],
        ),
        hasLength(1),
      );
    });
    test('start and duration fallback includes exact limits', () {
      expect(
        HealthProximity.overlapping(
          start: start,
          end: start,
          duration: 100,
          nearby: [
            nearby(
              startDate: start.add(const Duration(minutes: 15)),
              endDate: start.add(const Duration(minutes: 15)),
              duration: 80,
            ),
          ],
        ),
        hasLength(1),
      );
    });
    test('outside start or duration tolerance without overlap is excluded', () {
      expect(
        HealthProximity.overlapping(
          start: start,
          end: start,
          duration: 100,
          nearby: [
            nearby(
              startDate: start.add(const Duration(minutes: 16)),
              duration: 100,
            ),
            nearby(startDate: start, endDate: start, duration: 79),
          ],
        ),
        isEmpty,
      );
    });
    test('distance difference is ignored as in Swift', () {
      expect(
        HealthProximity.overlapping(
          start: start,
          end: end,
          duration: 3600,
          nearby: [nearby(distance: 999999)],
        ),
        hasLength(1),
      );
    });
    test('native DTO validates dates and optional fields', () {
      expect(
        () => HealthNearbyWorkout.fromObject({
          'uuid': workoutId,
          'startMs': 1,
          'endMs': 0,
          'durationSeconds': 10,
        }),
        throwsFormatException,
      );
      expect(
        () => HealthNearbyWorkout.fromObject({
          'uuid': workoutId,
          'startMs': 0,
          'endMs': 1,
          'durationSeconds': -1,
        }),
        throwsFormatException,
      );
      final dto = HealthNearbyWorkout.fromObject({
        'uuid': workoutId,
        'startMs': 0,
        'endMs': 1,
        'durationSeconds': 1,
        'sourceName': 'Watch',
        'syncIdentifier': fingerprint,
      });
      expect(dto.syncIdentifier, fingerprint);
      expect(dto.distanceMeters, isNull);
    });
  });
  for (final choice in AppleHealthNearbyDecision.values) {
    testWidgets('dialog returns $choice', (tester) async {
      AppleHealthNearbyDecision? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showAppleHealthNearbyDialog(
                    context,
                    AppleHealthNearbyPrompt(
                      activityTitle: 'Morning ride',
                      nearbySummary: 'Apple Watch overlap',
                      nearby: [nearby()],
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Morning ride'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('health-decision-${choice.name}')));
      await tester.pumpAndSettle();
      expect(result, choice);
    });
  }
  testWidgets(
    'small-screen large-text dialog keeps every choice reachable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  showAppleHealthNearbyDialog(
                    context,
                    AppleHealthNearbyPrompt(
                      activityTitle: '非常长的训练标题测试在小屏幕上的换行',
                      nearbySummary:
                          '已有接近训练，写入会新增一条记录，不能覆盖或删除 Apple Watch 的数据。' * 6,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('health-decision-cancelBatch')),
      );
      await tester.tap(
        find.byKey(const ValueKey('health-decision-cancelBatch')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('health-decision-cancelBatch')),
        findsNothing,
      );
    },
  );
  testWidgets('unmounted host skips once without opening a dialog', (
    tester,
  ) async {
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            host = context;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    final choice = await showAppleHealthNearbyDialog(
      host,
      const AppleHealthNearbyPrompt(
        activityTitle: 'Ride',
        nearbySummary: 'Watch',
      ),
    );
    expect(choice, AppleHealthNearbyDecision.skipOnce);
    expect(tester.takeException(), isNull);
  });
  testWidgets('dialog dismissal skips once', (tester) async {
    AppleHealthNearbyDecision? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showAppleHealthNearbyDialog(
                  context,
                  AppleHealthNearbyPrompt(
                    activityTitle: 'Ride',
                    nearbySummary: 'Watch overlap',
                    nearby: [nearby()],
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(result, AppleHealthNearbyDecision.skipOnce);
  });
}

Uint8List draftBytes({
  DateTime? startDate,
  String fingerprintValue = fingerprint,
}) {
  final from = startDate ?? start;
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'fingerprint': fingerprintValue,
        'startMs': from.millisecondsSinceEpoch,
        'endMs': from.add(const Duration(hours: 1)).millisecondsSinceEpoch,
        'durationSeconds': 3600,
        'distanceMeters': 12000,
        'locations': [],
      }),
    ),
  );
}

HealthNearbyWorkout nearby({
  String uuid = otherWorkoutId,
  DateTime? startDate,
  DateTime? endDate,
  double duration = 3600,
  double? distance = 12000,
  String? syncIdentifier,
}) {
  final from = startDate ?? start;
  return HealthNearbyWorkout(
    uuid: uuid,
    startMs: from.millisecondsSinceEpoch,
    endMs:
        (endDate ?? from.add(const Duration(hours: 1))).millisecondsSinceEpoch,
    durationSeconds: duration,
    distanceMeters: distance,
    sourceName: 'Apple Watch',
    syncIdentifier: syncIdentifier,
  );
}

final class Harness {
  Harness() {
    pass = AppleHealthImportPass(
      canWriteWorkouts: () async {
        event('available');
        return available;
      },
      requestWriteAuthorization: () async {
        event('authorize');
      },
      findNearbyWorkouts: ({required startMs, required endMs}) async {
        queryStart = startMs;
        queryEnd = endMs;
        event('nearby');
        return nearby;
      },
      writeWorkout: ({required draftJson}) async {
        writtenDraft = draftJson;
        event('write');
        if (writeError != null) throw writeError!;
        return writeUuid;
      },
      decodeFitHealthDraft: ({required data, required fingerprint}) async {
        event('decode');
        return draft;
      },
      recordFor: (_) async {
        event('record');
        await recordBarrier;
        return missingRecord ? null : Map.of(saved);
      },
      markWritten:
          ({required fingerprint, required uuid, required updatedAt}) async {
            event('written');
            saved['appleHealthUUID'] = uuid;
            saved.remove('appleHealthError');
            saved.remove('appleHealthSkipped');
          },
      markSkipped: ({required fingerprint, required updatedAt}) async {
        event('skipped');
        saved['appleHealthSkipped'] = true;
        saved.remove('appleHealthError');
      },
      markFailed:
          ({required fingerprint, required message, required updatedAt}) async {
            event('failed');
            saved['appleHealthError'] = message;
          },
      onNearby: (prompt) async {
        prompts.add(prompt);
        event('prompt');
        return decision;
      },
      cancelled: () => cancelled,
      now: () => start,
    );
  }
  late final AppleHealthImportPass pass;
  Map<String, Object?> saved = {'status': 'uploaded', 'remoteId': 'strava-id'};
  final events = <String>[];
  final prompts = <AppleHealthNearbyPrompt>[];
  List<HealthNearbyWorkout> nearby = [];
  AppleHealthNearbyDecision decision = AppleHealthNearbyDecision.write;
  Future<void>? recordBarrier;
  bool missingRecord = false;
  bool available = true;
  bool cancelled = false;
  String? cancelAfter;
  String? errorAt;
  Object? writeError;
  String writeUuid = workoutId;
  int? queryStart;
  int? queryEnd;
  Uint8List draft = draftBytes();
  Uint8List? writtenDraft;
  void event(String value) {
    events.add(value);
    if (cancelAfter == value) cancelled = true;
    if (errorAt == value) throw StateError('$value failed');
  }

  void resetRecord() {
    saved = {'status': 'uploaded', 'remoteId': 'strava-id'};
  }

  Future<AppleHealthImportResult> run({Uint8List? fit}) => pass.process(
    fingerprint: fingerprint,
    fit: fit ?? Uint8List.fromList([1, 2, 3]),
    title: 'Morning ride',
    start: start,
    end: end,
    duration: 3600,
    distance: 12000,
  );
}
