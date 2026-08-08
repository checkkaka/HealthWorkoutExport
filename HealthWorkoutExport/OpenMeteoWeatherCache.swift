import Foundation

/// 同批次 Open-Meteo 天气缓存：按数据源 + UTC 日期范围 + 粗网格坐标去重 HTTP。
/// 粗网格只影响「少打几次 API」，不替代沿途多锚点；空气密度仍按每秒海拔订正。
actor OpenMeteoWeatherCache {
    /// 粗网格边长（度），约 11 km，同城多条活动可命中同一格。
    private static let gridDegrees = 0.1

    private var store: [String: [WeatherSample]] = [:]
    private var inFlight: [String: Task<[WeatherSample], Error>] = [:]
    private let fetcher: @Sendable (Double, Double, Date, Date) async throws -> [WeatherSample]

    init(
        fetcher: @escaping @Sendable (Double, Double, Date, Date) async throws -> [WeatherSample] = {
            lat, lon, start, end in
            // 调用 OpenMeteoWeatherClient：未命中缓存时按 7 天分流打天气 API。
            try await OpenMeteoWeatherClient.fetchHourly(
                latitude: lat,
                longitude: lon,
                start: start,
                end: end
            )
        }
    ) {
        self.fetcher = fetcher
    }

    /// 拉取或复用 [start, end] 覆盖的逐小时样本。
    func hourly(
        latitude: Double,
        longitude: Double,
        start: Date,
        end: Date
    ) async throws -> [WeatherSample] {
        let key = Self.cacheKey(latitude: latitude, longitude: longitude, start: start, end: end)
        if let hit = store[key] {
            return hit
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task {
            try await fetcher(latitude, longitude, start, end)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let samples = try await task.value
        store[key] = samples
        return samples
    }

    /// 当前缓存条目数（测试/诊断用）。
    var entryCount: Int { store.count }

    /// 清空本批缓存。
    func clear() {
        store.removeAll()
        inFlight.removeAll()
    }

    /// 生成缓存键：主数据源 + 粗网格 lat/lon + UTC 起止日。
    static func cacheKey(
        latitude: Double,
        longitude: Double,
        start: Date,
        end: Date,
        now: Date = Date()
    ) -> String {
        // 调用 preferredSource：键含主源，避免 Forecast/Archive 串缓存。
        let source = OpenMeteoWeatherClient.preferredSource(activityEnd: end, now: now)
        let gridLat = (latitude / gridDegrees).rounded() * gridDegrees
        let gridLon = (longitude / gridDegrees).rounded() * gridDegrees
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let startDay = utc.startOfDay(for: start)
        let endDay = utc.startOfDay(for: end)
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        let latKey = String(format: "%.1f", gridLat)
        let lonKey = String(format: "%.1f", gridLon)
        return "\(source.rawValue)|\(latKey),\(lonKey)@\(df.string(from: startDay))_\(df.string(from: endDay))"
    }
}
