import XCTest
@testable import HealthWorkoutExport

final class OpenMeteoWeatherCacheTests: XCTestCase {
    /// 同格同日第二次请求应命中缓存，fetcher 只调用一次。
    func testSameGridSameDayHitsCache() async throws {
        let counter = FetchCounter()
        let cache = OpenMeteoWeatherCache { _, _, _, _ in
            await counter.increment()
            return [
                WeatherSample(
                    date: Date(timeIntervalSince1970: 1_720_000_000),
                    temperatureC: 20,
                    relativeHumidityPercent: 50,
                    pressureMslHpa: 1013,
                    windSpeedMps: 3,
                    windFromDegrees: 90
                )
            ]
        }
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let end = start.addingTimeInterval(3600)
        // 调用 cache.hourly：第一次打 fetcher。
        let first = try await cache.hourly(latitude: 31.20, longitude: 121.50, start: start, end: end)
        // 邻近坐标落入同一 0.1° 格，应复用。
        let second = try await cache.hourly(latitude: 31.21, longitude: 121.51, start: start, end: end)
        XCTAssertEqual(first, second)
        XCTAssertEqual(await counter.value, 1)
        XCTAssertEqual(await cache.entryCount, 1)
    }

    /// 不同 UTC 日不应复用缓存。
    func testDifferentDayMissesCache() async throws {
        let counter = FetchCounter()
        let cache = OpenMeteoWeatherCache { _, _, _, _ in
            await counter.increment()
            return []
        }
        let day1 = Date(timeIntervalSince1970: 1_720_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        _ = try await cache.hourly(latitude: 31.2, longitude: 121.5, start: day1, end: day1)
        _ = try await cache.hourly(latitude: 31.2, longitude: 121.5, start: day2, end: day2)
        XCTAssertEqual(await counter.value, 2)
    }

    /// 粗网格键对邻近坐标应一致。
    func testCacheKeyRoundsToSameGrid() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let start = now.addingTimeInterval(-3 * 86_400)
        let a = OpenMeteoWeatherCache.cacheKey(
            latitude: 31.20, longitude: 121.50, start: start, end: start, now: now
        )
        let b = OpenMeteoWeatherCache.cacheKey(
            latitude: 31.24, longitude: 121.54, start: start, end: start, now: now
        )
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("forecast|"), "近 7 天主源应为 forecast，实际 \(a)")
    }

    /// 不同主数据源的缓存键应区分开。
    func testCacheKeyIncludesPreferredSource() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let recent = now.addingTimeInterval(-2 * 86_400)
        let older = now.addingTimeInterval(-30 * 86_400)
        let recentKey = OpenMeteoWeatherCache.cacheKey(
            latitude: 31.2, longitude: 121.5, start: recent, end: recent, now: now
        )
        let olderKey = OpenMeteoWeatherCache.cacheKey(
            latitude: 31.2, longitude: 121.5, start: older, end: older, now: now
        )
        XCTAssertTrue(recentKey.hasPrefix("forecast|"))
        XCTAssertTrue(olderKey.hasPrefix("historicalForecast|"))
        XCTAssertNotEqual(recentKey, olderKey)
    }
}

/// 统计 fetcher 调用次数（actor 保证并发安全）。
private actor FetchCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
