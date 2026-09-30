import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/fit_merge_page.dart';

void main() {
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
