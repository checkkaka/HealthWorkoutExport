import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/route_map.dart';
import 'package:health_workout_export/osm_tile_source.dart';

class SyntheticTileSource implements OsmTileSource {
  bool delay = false;
  final pending = <OsmTileKey, Completer<Uint8List>>{};
  final requests = <OsmTileKey>[];
  var closed = false;
  @override
  void setVisibleTiles(Set<OsmTileKey> keys) {
    for (final key in pending.keys.toList()) {
      if (!keys.contains(key)) {
        pending.remove(key)!.completeError(StateError('offscreen'));
      }
    }
  }

  @override
  Future<Uint8List> load(OsmTileKey key) async {
    requests.add(key);
    if (delay) return (pending[key] = Completer<Uint8List>()).future;
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  const line = RouteMapLine(
    id: 'final',
    points: [
      RouteMapPoint(latitude: 0, longitude: 0),
      RouteMapPoint(latitude: .01, longitude: .01),
    ],
    color: Colors.blue,
    coordinateSystem: RouteCoordinateSystem.wgs84,
  );
  Widget app(
    SyntheticTileSource tiles, {
    RouteMapLine route = line,
    String id = 'a',
  }) => MaterialApp(
    home: Scaffold(
      body: WorkoutRouteMap(
        lines: [route],
        contentId: id,
        tileSourceFactory: () => tiles,
      ),
    ),
  );

  testWidgets(
    'offline by default supports pan zoom reset without any tile requests',
    (tester) async {
      final tiles = SyntheticTileSource();
      await tester.pumpWidget(app(tiles));
      expect(find.textContaining('离线轨迹示意'), findsOneWidget);
      expect(tiles.requests, isEmpty);
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      viewer.transformationController!.value = Matrix4.identity()
        ..translateByDouble(100, 0, 0, 1);
      await tester.pump();
      await tester.tap(find.text('回到轨迹'));
      await tester.pump();
      expect(viewer.transformationController!.value.entry(0, 3), 0);
      expect(tiles.requests, isEmpty);
    },
  );

  testWidgets(
    'explicit privacy confirmation is required before visible OSM tiles load',
    (tester) async {
      final tiles = SyntheticTileSource();
      await tester.pumpWidget(app(tiles));
      await tester.tap(find.text('启用在线底图'));
      await tester.pumpAndSettle();
      expect(find.textContaining('查看的位置区域'), findsOneWidget);
      expect(tiles.requests, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tiles.requests, isEmpty);
      await tester.tap(find.text('启用在线底图'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同意并启用'));
      await tester.pumpAndSettle();
      expect(tiles.requests, isNotEmpty);
      expect(tiles.requests.length, lessThanOrEqualTo(64));
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
      await tester.tap(find.text('关闭在线底图'));
      await tester.pumpAndSettle();
      expect(tiles.closed, isTrue);
      expect(find.textContaining('离线轨迹示意'), findsOneWidget);
    },
  );

  testWidgets(
    'raw GCJ and unknown coordinates cannot be passed off as WGS84 tiles',
    (tester) async {
      final tiles = SyntheticTileSource();
      await tester.pumpWidget(
        app(
          tiles,
          route: RouteMapLine(
            id: 'raw',
            points: line.points,
            color: Colors.grey,
            coordinateSystem: RouteCoordinateSystem.gcj02,
          ),
        ),
      );
      expect(find.text('启用在线底图'), findsNothing);
      expect(find.textContaining('GCJ-02'), findsOneWidget);
      expect(tiles.requests, isEmpty);
    },
  );

  testWidgets('online consent does not carry to a different activity', (
    tester,
  ) async {
    final tiles = SyntheticTileSource();
    await tester.pumpWidget(app(tiles));
    await tester.tap(find.text('启用在线底图'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意并启用'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(tiles, id: 'next'));
    await tester.pumpAndSettle();
    expect(tiles.closed, isTrue);
    expect(find.text('启用在线底图'), findsOneWidget);
  });
  testWidgets('backgrounding closes online tile access until a fresh opt-in', (
    tester,
  ) async {
    final tiles = SyntheticTileSource();
    await tester.pumpWidget(app(tiles));
    await tester.tap(find.text('启用在线底图'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意并启用'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(tiles.closed, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('启用在线底图'), findsOneWidget);
  });

  testWidgets('covering the map route closes pending tile access', (
    tester,
  ) async {
    final tiles = SyntheticTileSource()..delay = true;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: WorkoutRouteMap(
            lines: const [line],
            contentId: 'route',
            tileSourceFactory: () => tiles,
          ),
        ),
      ),
    );
    await tester.tap(find.text('启用在线底图'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意并启用'));
    await tester.pumpAndSettle();
    expect(tiles.requests, isNotEmpty);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('other page')),
      ),
    );
    await tester.pumpAndSettle();
    expect(tiles.closed, isTrue);
  });
  testWidgets('scrolling the map outside the viewport revokes online consent', (
    tester,
  ) async {
    final tiles = SyntheticTileSource()..delay = true;
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            child: Column(
              children: [
                WorkoutRouteMap(
                  lines: const [line],
                  contentId: 'scroll',
                  tileSourceFactory: () => tiles,
                ),
                const SizedBox(height: 2000),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('启用在线底图'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意并启用'));
    await tester.pumpAndSettle();
    scroll.jumpTo(1000);
    await tester.pumpAndSettle();
    expect(tiles.closed, isTrue);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('启用在线底图'), findsOneWidget);
  });

  testWidgets(
    'panning retries canceled viewport tiles instead of keeping failed futures',
    (tester) async {
      final tiles = SyntheticTileSource()..delay = true;
      await tester.pumpWidget(app(tiles));
      await tester.tap(find.text('启用在线底图'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同意并启用'));
      await tester.pumpAndSettle();
      final before = tiles.requests.length;
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      viewer.transformationController!.value = Matrix4.identity()
        ..translateByDouble(1, 0, 0, 1);
      await tester.pump();
      tiles.delay = false;
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(tiles.requests.length, greaterThan(before));
      expect(find.byType(Image), findsWidgets);
    },
  );
}
