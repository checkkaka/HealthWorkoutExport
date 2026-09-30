import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/osm_tile_source.dart';
import 'package:health_workout_export/route_map_model.dart';

void main() {
  late Directory cache;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  const tile = OsmTileKey(4, 8, 8);
  setUp(() async {
    cache = await Directory.systemTemp.createTemp('osm-synthetic-');
  });
  tearDown(() async {
    await cache.delete(recursive: true);
  });

  test(
    'desktop tile cache uses the user profile rather than a shared temp directory',
    () {
      expect(
        osmTileCachePath(
          operatingSystem: 'windows',
          environment: const {'LOCALAPPDATA': 'C:/Users/test/AppData/Local'},
          temporaryDirectory: '/shared-temp',
        ),
        'C:/Users/test/AppData/Local/HealthWorkoutExport/osm_tiles_v1',
      );
      expect(
        osmTileCachePath(
          operatingSystem: 'macos',
          environment: const {'HOME': '/Users/test'},
          temporaryDirectory: '/shared-temp',
        ),
        '/Users/test/Library/Caches/HealthWorkoutExport/osm_tiles_v1',
      );
      expect(
        osmTileCachePath(
          operatingSystem: 'linux',
          environment: const {'XDG_CACHE_HOME': '/home/test/.cache'},
          temporaryDirectory: '/shared-temp',
        ),
        '/home/test/.cache/HealthWorkoutExport/osm_tiles_v1',
      );
    },
  );

  test('mobile tile cache remains in the application sandbox', () {
    for (final platform in ['ios', 'android']) {
      expect(
        osmTileCachePath(
          operatingSystem: platform,
          environment: const {},
          temporaryDirectory: '/sandbox/cache',
        ),
        '/sandbox/cache/HealthWorkoutExport/osm_tiles_v1',
      );
    }
  });

  test(
    'only visible tiles load and requests identify app without cache bypass',
    () async {
      final requested = <Uri>[];
      final source = CachedOsmTileSource(
        directory: cache,
        fetcher: (uri, headers) async {
          requested.add(uri);
          expect(headers['User-Agent'], startsWith('HealthWorkoutExport/'));
          expect(headers.containsKey('Cache-Control'), isFalse);
          return OsmTileResponse(200, const {}, png);
        },
      );
      await expectLater(source.load(tile), throwsStateError);
      expect(requested, isEmpty);
      source.setVisibleTiles({tile});
      expect(await source.load(tile), png);
      expect(requested, [tile.uri]);
      source.close();
    },
  );

  test(
    'unexpired tiles survive a new source instance for at least seven days',
    () async {
      var now = DateTime.utc(2026);
      var requests = 0;
      CachedOsmTileSource create() => CachedOsmTileSource(
        directory: cache,
        now: () => now,
        fetcher: (_, _) async {
          requests++;
          return OsmTileResponse(200, const {}, png);
        },
      );
      final first = create()..setVisibleTiles({tile});
      await first.load(tile);
      first.close();
      now = now.add(const Duration(days: 6));
      final second = create()..setVisibleTiles({tile});
      expect(await second.load(tile), png);
      expect(requests, 1);
      second.close();
    },
  );

  test(
    'server cache headers and conditional ETag revalidation are respected',
    () async {
      var now = DateTime.utc(2026);
      var requests = 0;
      final source = CachedOsmTileSource(
        directory: cache,
        now: () => now,
        fetcher: (_, headers) async {
          requests++;
          if (requests == 1) {
            return OsmTileResponse(200, const {
              'cache-control': 'max-age=60',
              'etag': 'synthetic-v1',
            }, png);
          }
          expect(headers['If-None-Match'], 'synthetic-v1');
          return OsmTileResponse(304, const {
            'cache-control': 'max-age=120',
          }, png.sublist(0, 0));
        },
      )..setVisibleTiles({tile});
      await source.load(tile);
      now = now.add(const Duration(seconds: 59));
      await source.load(tile);
      expect(requests, 1);
      now = now.add(const Duration(seconds: 2));
      expect(await source.load(tile), png);
      expect(requests, 2);
      source.close();
    },
  );

  test('capacity never evicts fresh tiles to bulk fetch more areas', () async {
    var requests = 0;
    final source = CachedOsmTileSource(
      directory: cache,
      maximumTiles: 1,
      fetcher: (_, _) async {
        requests++;
        return OsmTileResponse(200, const {}, png);
      },
    )..setVisibleTiles({tile, const OsmTileKey(4, 8, 9)});
    await source.load(tile);
    await expectLater(source.load(const OsmTileKey(4, 8, 9)), throwsStateError);
    expect(requests, 1);
    source.close();
  });

  test('offscreen queued loads are canceled before network access', () async {
    final pending = Completer<OsmTileResponse>();
    final started = Completer<void>();
    var requests = 0;
    const other = OsmTileKey(4, 8, 9);
    final source = CachedOsmTileSource(
      directory: cache,
      fetcher: (_, _) {
        requests++;
        started.complete();
        return pending.future;
      },
    )..setVisibleTiles({tile, other});
    final a = source.load(tile);
    final b = source.load(other);
    final canceled = expectLater(b, throwsStateError);
    await started.future;
    source.setVisibleTiles({tile});
    pending.complete(OsmTileResponse(200, const {}, png));
    await a;
    await canceled;
    expect(requests, 1);
    source.close();
  });

  test('blocked tile service is not retried automatically', () async {
    var requests = 0;
    final source = CachedOsmTileSource(
      directory: cache,
      fetcher: (_, _) async {
        requests++;
        return OsmTileResponse(429, const {}, png);
      },
    )..setVisibleTiles({tile});
    await expectLater(source.load(tile), throwsStateError);
    await expectLater(source.load(tile), throwsStateError);
    expect(requests, 1);
    source.close();
  });
  test('304 without freshness headers retains original max-age', () async {
    var now = DateTime.utc(2026);
    var requests = 0;
    final source = CachedOsmTileSource(
      directory: cache,
      now: () => now,
      fetcher: (_, _) async {
        requests++;
        return requests == 1
            ? OsmTileResponse(200, const {
                'cache-control': 'max-age=60',
                'etag': 'v1',
              }, png)
            : OsmTileResponse(304, const {}, png.sublist(0, 0));
      },
    )..setVisibleTiles({tile});
    await source.load(tile);
    now = now.add(const Duration(seconds: 61));
    await source.load(tile);
    now = now.add(const Duration(seconds: 61));
    await source.load(tile);
    expect(requests, 3);
    source.close();
  });

  test('no-store revalidation removes the formerly cached tile', () async {
    var now = DateTime.utc(2026);
    var requests = 0;
    final source = CachedOsmTileSource(
      directory: cache,
      now: () => now,
      fetcher: (_, headers) async {
        requests++;
        if (requests == 3) {
          expect(headers.containsKey('If-None-Match'), isFalse);
        }
        return OsmTileResponse(
          200,
          requests == 1
              ? const {'cache-control': 'max-age=1', 'etag': 'v1'}
              : const {'cache-control': 'no-store'},
          png,
        );
      },
    )..setVisibleTiles({tile});
    await source.load(tile);
    now = now.add(const Duration(seconds: 2));
    await source.load(tile);
    await source.load(tile);
    source.close();
  });

  test(
    'two map views serialize shared cache writes and reuse the same tile',
    () async {
      var requests = 0;
      Future<OsmTileResponse> fetch(
        Uri uri,
        Map<String, String> headers,
      ) async {
        requests++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return OsmTileResponse(200, const {}, png);
      }

      final first = CachedOsmTileSource(directory: cache, fetcher: fetch)
        ..setVisibleTiles({tile});
      final second = CachedOsmTileSource(directory: cache, fetcher: fetch)
        ..setVisibleTiles({tile});
      await Future.wait([first.load(tile), second.load(tile)]);
      expect(requests, 1);
      first.close();
      second.close();
    },
  );
  test(
    'viewing another tile preserves expired validators while cache has room',
    () async {
      var now = DateTime.utc(2026);
      final source = CachedOsmTileSource(
        directory: cache,
        now: () => now,
        fetcher: (uri, headers) async {
          if (now.year == 2027 && uri == tile.uri) {
            expect(headers['If-None-Match'], 'v1');
          }
          return OsmTileResponse(200, const {
            'cache-control': 'max-age=60',
            'etag': 'v1',
          }, png);
        },
      )..setVisibleTiles({tile, const OsmTileKey(4, 8, 9)});
      await source.load(tile);
      now = DateTime.utc(2027);
      await source.load(const OsmTileKey(4, 8, 9));
      await source.load(tile);
      source.close();
    },
  );
}
