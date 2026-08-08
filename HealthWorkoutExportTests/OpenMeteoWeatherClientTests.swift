import XCTest
@testable import HealthWorkoutExport

final class OpenMeteoWeatherClientTests: XCTestCase {
    /// 结束日距今 ≤7 天 → Forecast。
    func testPreferredSourceRecentUsesForecast() {
        let now = date(2026, 8, 8)
        XCTAssertEqual(
            OpenMeteoWeatherClient.preferredSource(activityEnd: date(2026, 8, 8), now: now),
            .forecast
        )
        XCTAssertEqual(
            OpenMeteoWeatherClient.preferredSource(activityEnd: date(2026, 8, 1), now: now),
            .forecast
        )
    }

    /// 结束日距今 >7 天且 ≥2022 → Historical Forecast。
    func testPreferredSourceOlderUsesHistoricalForecast() {
        let now = date(2026, 8, 8)
        XCTAssertEqual(
            OpenMeteoWeatherClient.preferredSource(activityEnd: date(2026, 7, 31), now: now),
            .historicalForecast
        )
        XCTAssertEqual(
            OpenMeteoWeatherClient.preferredSource(activityEnd: date(2022, 1, 1), now: now),
            .historicalForecast
        )
    }

    /// 结束日早于 2022 → Archive。
    func testPreferredSourcePre2022UsesArchive() {
        let now = date(2026, 8, 8)
        XCTAssertEqual(
            OpenMeteoWeatherClient.preferredSource(activityEnd: date(2021, 12, 31), now: now),
            .archive
        )
    }

    /// Forecast URL 应带 past_days / forecast_days。
    func testForecastURLUsesPastDays() throws {
        let now = date(2026, 8, 8)
        let start = date(2026, 8, 6)
        let end = date(2026, 8, 6)
        let url = try XCTUnwrap(
            OpenMeteoWeatherClient.makeURL(
                source: .forecast,
                latitude: 31.3,
                longitude: 120.6,
                start: start,
                end: end,
                now: now
            )
        )
        XCTAssertTrue(url.host?.contains("api.open-meteo.com") == true)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "past_days" }?.value, "2")
        XCTAssertEqual(items.first { $0.name == "forecast_days" }?.value, "1")
        XCTAssertNil(items.first { $0.name == "start_date" })
    }

    /// Historical Forecast / Archive URL 应带 start_date/end_date。
    func testDatedSourcesUseStartEnd() throws {
        let start = date(2024, 5, 1)
        let end = date(2024, 5, 2)
        let hist = try XCTUnwrap(
            OpenMeteoWeatherClient.makeURL(
                source: .historicalForecast,
                latitude: 31.3,
                longitude: 120.6,
                start: start,
                end: end
            )
        )
        XCTAssertTrue(hist.host?.contains("historical-forecast-api") == true)
        let histItems = URLComponents(url: hist, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(histItems.first { $0.name == "start_date" }?.value, "2024-05-01")
        XCTAssertEqual(histItems.first { $0.name == "end_date" }?.value, "2024-05-02")

        let archive = try XCTUnwrap(
            OpenMeteoWeatherClient.makeURL(
                source: .archive,
                latitude: 31.3,
                longitude: 120.6,
                start: start,
                end: end
            )
        )
        XCTAssertTrue(archive.host?.contains("archive-api") == true)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.date(from: DateComponents(year: y, month: m, day: d))!
    }
}
