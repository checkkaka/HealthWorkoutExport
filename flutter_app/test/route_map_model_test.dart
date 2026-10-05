import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/route_map_model.dart';

void main() {
  const wgs = RouteMapLine(
    id: 'wgs',
    points: [
      RouteMapPoint(latitude: 0, longitude: 0),
      RouteMapPoint(latitude: 1, longitude: 1),
    ],
    color: Colors.blue,
    coordinateSystem: RouteCoordinateSystem.wgs84,
  );

  test('online tiles require explicitly known WGS84 for every line', () {
    expect(routeCanUseOsm([wgs]), isTrue);
    expect(routeCanUseOsm([]), isFalse);
    for (final system in [
      RouteCoordinateSystem.gcj02,
      RouteCoordinateSystem.unknown,
    ]) {
      expect(
        routeCanUseOsm([
          wgs,
          RouteMapLine(
            id: 'raw',
            points: wgs.points,
            color: Colors.grey,
            coordinateSystem: system,
          ),
        ]),
        isFalse,
      );
    }
  });

  test(
    'Mercator projection uses one scale and fits antimeridian route locally',
    () {
      final projection = RouteMapProjection.fit(const [
        RouteMapPoint(latitude: 0, longitude: 179.9),
        RouteMapPoint(latitude: 0.1, longitude: -179.9),
      ], const Size(400, 240));
      final a = projection.project(
        const RouteMapPoint(latitude: 0, longitude: 179.9),
      );
      final b = projection.project(
        const RouteMapPoint(latitude: .1, longitude: -179.9),
      );
      expect((b.dx - a.dx).abs(), closeTo(336, .01));
      expect((b.dy - a.dy).abs(), closeTo(168, .1));
      expect(a.dx, inInclusiveRange(30, 370));
      expect(b.dx, inInclusiveRange(30, 370));
    },
  );

  test(
    'polar coordinates and one point produce finite bounded viewport tiles',
    () {
      final projection = RouteMapProjection.fit(const [
        RouteMapPoint(latitude: 90, longitude: 180),
      ], const Size(400, 240));
      final point = projection.project(
        const RouteMapPoint(latitude: 90, longitude: 180),
      );
      expect(point.dx.isFinite && point.dy.isFinite, isTrue);
      final tiles = projection.visibleTiles(scale: 1, translation: Offset.zero);
      expect(tiles.length, inInclusiveRange(1, 64));
      for (final tile in tiles) {
        expect(tile.key.x, inInclusiveRange(0, (1 << tile.key.z) - 1));
        expect(tile.key.y, inInclusiveRange(0, (1 << tile.key.z) - 1));
        expect(tile.key.uri.host, 'tile.openstreetmap.org');
        expect(tile.key.uri.scheme, 'https');
      }
    },
  );

  test(
    'invalid geographic values are rejected before projection or tile access',
    () {
      expect(
        () => RouteMapProjection.fit(const [
          RouteMapPoint(latitude: 91, longitude: 0),
        ], const Size(400, 240)),
        throwsArgumentError,
      );
    },
  );
  test('world spanning track still fits within the visible map', () {
    final points = [
      const RouteMapPoint(latitude: -80, longitude: -70),
      const RouteMapPoint(latitude: 80, longitude: 70),
    ];
    final projection = RouteMapProjection.fit(points, const Size(400, 240));
    for (final point in points) {
      final projected = projection.project(point);
      expect(projected.dx, inInclusiveRange(31.9, 368.1));
      expect(projected.dy, inInclusiveRange(31.9, 208.1));
    }
  });
}
