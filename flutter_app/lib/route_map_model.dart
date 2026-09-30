import 'dart:math' as math;
import 'package:flutter/material.dart';

enum RouteCoordinateSystem { wgs84, gcj02, unknown }

class RouteMapPoint {
  const RouteMapPoint({required this.latitude, required this.longitude});
  final double latitude, longitude;
}

class RouteMapLine {
  const RouteMapLine({
    required this.id,
    required this.points,
    required this.color,
    required this.coordinateSystem,
  });
  final String id;
  final List<RouteMapPoint> points;
  final Color color;
  final RouteCoordinateSystem coordinateSystem;
}

/// Coordinate provenance is supplied by the FIT/core pipeline, never inferred
/// from geography. This widget does not convert GCJ-02 or relabel raw data.
bool routeCanUseOsm(List<RouteMapLine> lines) =>
    lines.any((line) => line.points.isNotEmpty) &&
    lines.every((line) => line.coordinateSystem == RouteCoordinateSystem.wgs84);

class OsmTileKey {
  const OsmTileKey(this.z, this.x, this.y);
  final int z, x, y;
  Uri get uri => Uri.parse('https://tile.openstreetmap.org/$z/$x/$y.png');
  @override
  bool operator ==(Object other) =>
      other is OsmTileKey && z == other.z && x == other.x && y == other.y;
  @override
  int get hashCode => Object.hash(z, x, y);
}

class RouteMapTile {
  const RouteMapTile(this.key, this.position, this.size);
  final OsmTileKey key;
  final Offset position;
  final double size;
}

class RouteMapProjection {
  RouteMapProjection._(this.size, this.center, this.pixelsPerWorld);
  final Size size;
  final Offset center;
  final double pixelsPerWorld;

  factory RouteMapProjection.fit(List<RouteMapPoint> points, Size size) {
    if (!size.width.isFinite || !size.height.isFinite || size.isEmpty) {
      throw ArgumentError('Map viewport must be finite and positive');
    }
    final projected = points.map(_mercator).toList();
    if (projected.isEmpty) {
      return RouteMapProjection._(size, const Offset(.5, .5), 256);
    }
    final anchor = projected.first.dx;
    final unwrapped = projected.map((p) => Offset(_near(p.dx, anchor), p.dy));
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in unwrapped) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final scale = math
        .min(
          math.max(1, size.width - 64) / math.max(maxX - minX, 1e-6),
          math.max(1, size.height - 64) / math.max(maxY - minY, 1e-6),
        )
        .clamp(1.0, 256.0 * (1 << 19));
    return RouteMapProjection._(
      size,
      Offset((minX + maxX) / 2, (minY + maxY) / 2),
      scale,
    );
  }

  static double _near(double x, double anchor) => x + (anchor - x).round();
  static Offset _mercator(RouteMapPoint point) {
    if (!point.latitude.isFinite ||
        !point.longitude.isFinite ||
        point.latitude.abs() > 90 ||
        point.longitude.abs() > 180) {
      throw ArgumentError('Invalid geographic coordinate');
    }
    final latitude =
        point.latitude.clamp(-85.05112878, 85.05112878) * math.pi / 180;
    return Offset(
      (point.longitude + 180) / 360,
      (1 - math.log(math.tan(latitude) + 1 / math.cos(latitude)) / math.pi) / 2,
    );
  }

  Offset project(RouteMapPoint point) {
    final p = _mercator(point);
    return Offset(
      size.width / 2 + (_near(p.dx, center.dx) - center.dx) * pixelsPerWorld,
      size.height / 2 + (p.dy - center.dy) * pixelsPerWorld,
    );
  }

  /// Only the visible viewport at a single zoom level; no prefetch or bulk use.
  List<RouteMapTile> visibleTiles({
    required double scale,
    required Offset translation,
  }) {
    if (!scale.isFinite ||
        scale <= 0 ||
        !translation.dx.isFinite ||
        !translation.dy.isFinite) {
      return [];
    }
    final z = (math.log(pixelsPerWorld * scale / 256) / math.ln2).floor().clamp(
      0,
      19,
    );
    final n = 1 << z;
    final tileSize = pixelsPerWorld / n;
    final origin = Offset(
      size.width / 2 - center.dx * pixelsPerWorld,
      size.height / 2 - center.dy * pixelsPerWorld,
    );
    final left = (-translation.dx / scale - origin.dx) / tileSize;
    final top = (-translation.dy / scale - origin.dy) / tileSize;
    final right =
        ((size.width - translation.dx) / scale - origin.dx) / tileSize;
    final bottom =
        ((size.height - translation.dy) / scale - origin.dy) / tileSize;
    final result = <RouteMapTile>[];
    for (
      var y = math.max(0, top.floor());
      y <= math.min(n - 1, bottom.floor());
      y++
    ) {
      for (var x = left.floor(); x <= right.floor(); x++) {
        if (result.length >= 64) return result;
        result.add(
          RouteMapTile(
            OsmTileKey(z, x % n, y),
            origin + Offset(x * tileSize, y * tileSize),
            tileSize,
          ),
        );
      }
    }
    return result;
  }
}
