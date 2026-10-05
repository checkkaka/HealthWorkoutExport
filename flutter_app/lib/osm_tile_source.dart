import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'route_map_model.dart';

abstract interface class OsmTileSource {
  void setVisibleTiles(Set<OsmTileKey> keys);
  Future<Uint8List> load(OsmTileKey key);
  void close();
}

class OsmTileResponse {
  const OsmTileResponse(this.status, this.headers, this.bytes);
  final int status;
  final Map<String, String> headers;
  final Uint8List bytes;
}

typedef OsmTileFetcher =
    Future<OsmTileResponse> Function(Uri, Map<String, String>);

/// Chooses a user-specific desktop cache and the app-sandbox cache on mobile.
String osmTileCachePath({
  required String operatingSystem,
  required Map<String, String> environment,
  required String temporaryDirectory,
}) {
  final home = environment['HOME'];
  final base = switch (operatingSystem) {
    'windows' => environment['LOCALAPPDATA'] ?? temporaryDirectory,
    'macos' => home == null ? temporaryDirectory : '$home/Library/Caches',
    'linux' =>
      environment['XDG_CACHE_HOME'] ??
          (home == null ? temporaryDirectory : '$home/.cache'),
    _ => temporaryDirectory, // Flutter mobile supplies its app-private cache.
  };
  return '$base/HealthWorkoutExport/osm_tiles_v1';
}

/// Native (Android/iOS/macOS/Windows) standard OSM raster tiles.
/// Policy: https://operations.osmfoundation.org/policies/tiles/
/// One foreground request at a time, viewport-only, no prefetch. Persistent
/// bounded cache honors server freshness and validators, with a seven-day
/// fallback. Fresh entries are never evicted to fetch additional areas.
class CachedOsmTileSource implements OsmTileSource {
  CachedOsmTileSource({
    Directory? directory,
    DateTime Function()? now,
    this.fetcher,
    this.maximumTiles = 512,
  }) : _directory =
           directory ??
           Directory(
             osmTileCachePath(
               operatingSystem: Platform.operatingSystem,
               environment: Platform.environment,
               temporaryDirectory: Directory.systemTemp.path,
             ),
           ),
       _now = now ?? DateTime.now;

  final Directory _directory;
  final DateTime Function() _now;
  final OsmTileFetcher? fetcher;
  final int maximumTiles;
  final _client = HttpClient()
    ..userAgent = 'HealthWorkoutExport/1.0 (route-map)'
    ..connectionTimeout = const Duration(seconds: 10)
    ..maxConnectionsPerHost = 1;
  final _pending = <OsmTileKey, Future<Uint8List>>{};
  Set<OsmTileKey> _visible = {};
  // All map views share one on-disk cache: serialize writes across instances.
  static Future<void> _tail = Future.value();
  bool _closed = false;
  DateTime? _blockedUntil;
  static const _maximumTileBytes = 256 * 1024;

  @override
  void setVisibleTiles(Set<OsmTileKey> keys) {
    _visible = keys.take(64).toSet();
  }

  @override
  Future<Uint8List> load(OsmTileKey key) {
    if (_closed || !_visible.contains(key)) {
      return Future.error(StateError('Tile not visible'));
    }
    return _pending.putIfAbsent(key, () {
      final result = _tail.then((_) => _load(key));
      _tail = result.then<void>((_) {}, onError: (Object _) {});
      // Remove in both paths without creating an unhandled error future.
      result.then<void>(
        (_) => _pending.remove(key),
        onError: (Object _) {
          _pending.remove(key);
        },
      );
      return result;
    });
  }

  Future<Uint8List> _load(OsmTileKey key) async {
    if (_closed || !_visible.contains(key)) {
      throw StateError('Tile not visible');
    }
    if (key.z < 0 ||
        key.z > 19 ||
        key.x < 0 ||
        key.y < 0 ||
        key.x >= (1 << key.z) ||
        key.y >= (1 << key.z)) {
      throw StateError('Invalid tile');
    }
    await _directory.create(recursive: true);
    final file = File('${_directory.path}/${key.z}_${key.x}_${key.y}.json');
    final cached = await _read(file);
    final now = _now();
    if (cached != null && cached.expiry.isAfter(now)) return cached.bytes;
    if (_blockedUntil?.isAfter(now) ?? false) {
      throw StateError('Tile service temporarily unavailable');
    }
    await _makeRoom(file, now);
    if (_closed || !_visible.contains(key)) {
      throw StateError('Tile not visible');
    }
    final headers = <String, String>{
      'User-Agent': 'HealthWorkoutExport/1.0 (route-map)',
      if (cached?.etag != null) 'If-None-Match': cached!.etag!,
      if (cached?.modified != null) 'If-Modified-Since': cached!.modified!,
    };
    final response = await (fetcher ?? _fetch)(key.uri, headers);
    if (_closed) throw StateError('Online map closed');
    if (response.status == 403 || response.status == 429) {
      _blockedUntil = now.add(const Duration(hours: 1));
    }
    if (response.status != 200 && !(response.status == 304 && cached != null)) {
      throw StateError('Tile service temporarily unavailable');
    }
    final bytes = response.status == 304 ? cached!.bytes : response.bytes;
    _validatePng(bytes);
    final cacheHeaders = <String, String>{
      if (response.status == 304) ...?cached?.headers,
      ...response.headers,
    };
    final directives = (cacheHeaders['cache-control'] ?? '').toLowerCase();
    if (!directives.contains('no-store')) {
      var expiry = now.add(const Duration(days: 7));
      final maxAge = RegExp(
        r'(?:^|,)\s*max-age\s*=\s*"?(\d+)',
      ).firstMatch(directives);
      if (maxAge != null) {
        final age = int.tryParse(response.headers['age'] ?? '') ?? 0;
        expiry = now.add(
          Duration(seconds: (int.parse(maxAge[1]!) - age).clamp(0, 31536000)),
        );
      } else if (cacheHeaders['expires'] != null) {
        try {
          expiry = HttpDate.parse(cacheHeaders['expires']!);
        } on FormatException {
          /* fallback */
        }
      }
      if (directives.contains('no-cache')) expiry = now;
      final entry = _CachedTile(
        bytes,
        expiry,
        cacheHeaders['etag'],
        cacheHeaders['last-modified'],
        cacheHeaders,
      );
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(entry.toJson()), flush: true);
      await temporary.rename(file.path);
    } else if (await file.exists()) {
      await file.delete();
    }
    return bytes;
  }

  Future<void> _makeRoom(File wanted, DateTime now) async {
    if (await wanted.exists()) return;
    final files = await _directory
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.json'))
        .cast<File>()
        .toList();
    if (files.length < maximumTiles) return;
    // Keep validators until capacity requires eviction; a normal revisit can
    // then make a conditional request instead of downloading the whole tile.
    for (final entry in files) {
      final cached = await _read(entry);
      if (cached == null || !cached.expiry.isAfter(now)) {
        await entry.delete();
        return;
      }
    }
    throw StateError('Tile cache full');
  }

  Future<_CachedTile?> _read(File file) async {
    try {
      if (!await file.exists() || await file.length() > _maximumTileBytes * 2) {
        return null;
      }
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final bytes = base64Decode(json['bytes'] as String);
      _validatePng(bytes);
      return _CachedTile(
        bytes,
        DateTime.parse(json['expires'] as String),
        json['etag'] as String?,
        json['modified'] as String?,
        Map<String, String>.from(json['headers'] as Map? ?? const {}),
      );
    } on Object {
      return null;
    }
  }

  static void _validatePng(Uint8List bytes) {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 24 ||
        bytes.length > _maximumTileBytes ||
        List.generate(8, (i) => bytes[i] == signature[i]).contains(false)) {
      throw StateError('Invalid map tile');
    }
    final dimensions = ByteData.sublistView(bytes);
    for (final offset in [16, 20]) {
      final size = dimensions.getUint32(offset);
      if (size == 0 || size > 256) {
        throw StateError('Invalid map tile dimensions');
      }
    }
  }

  Future<OsmTileResponse> _fetch(Uri uri, Map<String, String> headers) async {
    final request = await _client
        .getUrl(uri)
        .timeout(const Duration(seconds: 10));
    request.followRedirects =
        false; // never forward viewed-area requests to another provider
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 15));
    final bytes = BytesBuilder();
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      if (bytes.length + chunk.length > _maximumTileBytes) {
        throw StateError('Map tile too large');
      }
      bytes.add(chunk);
    }
    return OsmTileResponse(response.statusCode, {
      for (final name in [
        'cache-control',
        'expires',
        'etag',
        'last-modified',
        'age',
      ])
        if (response.headers.value(name) != null)
          name: response.headers.value(name)!,
    }, bytes.takeBytes());
  }

  @override
  void close() {
    _closed = true;
    _visible.clear();
    _client.close(force: true);
  }
}

class _CachedTile {
  const _CachedTile(
    this.bytes,
    this.expiry,
    this.etag,
    this.modified,
    this.headers,
  );
  final Uint8List bytes;
  final DateTime expiry;
  final String? etag, modified;
  final Map<String, String> headers;
  Map<String, Object?> toJson() => {
    'bytes': base64Encode(bytes),
    'expires': expiry.toUtc().toIso8601String(),
    'etag': etag,
    'modified': modified,
    'headers': headers,
  };
}
