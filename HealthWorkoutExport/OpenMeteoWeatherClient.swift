import Foundation

/// Open-Meteo 历史天气样本（单点单时刻）。
struct WeatherSample: Sendable, Equatable {
    /// 样本时间（UTC）。
    var date: Date
    /// 气温（°C）。
    var temperatureC: Double
    /// 相对湿度（%）。
    var relativeHumidityPercent: Double
    /// 海平面气压（hPa）。
    var pressureMslHpa: Double
    /// 10 m 风速（m/s）。
    var windSpeedMps: Double
    /// 风向：风从哪来（度，0=北）。
    var windFromDegrees: Double
}

/// Open-Meteo 数据源：近 7 天 Forecast，更早 Historical Forecast（≥2022），再早或失败用 Archive。
enum OpenMeteoWeatherSource: String, Sendable {
    /// 实时/近况预报接口（含 past_days）。
    case forecast
    /// 历史预报拼接（约 2022 起）。
    case historicalForecast
    /// 再分析 Archive（长历史兜底）。
    case archive
}

/// Open-Meteo 天气客户端：按活动新旧分流拉取逐小时风与温湿压。
enum OpenMeteoWeatherClient {
    /// Forecast 根地址。
    private static let forecastBase = URL(string: "https://api.open-meteo.com/v1/forecast")!
    /// Historical Forecast 根地址。
    private static let historicalForecastBase = URL(string: "https://historical-forecast-api.open-meteo.com/v1/forecast")!
    /// Archive 根地址。
    private static let archiveBase = URL(string: "https://archive-api.open-meteo.com/v1/archive")!
    /// 近况窗口：结束日距今 ≤ 该天数走 Forecast。
    static let recentForecastMaxAgeDays = 7
    /// Historical Forecast 可用起点（UTC 日）。
    static let historicalForecastAvailableFrom: Date = {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.date(from: DateComponents(year: 2022, month: 1, day: 1))!
    }()
    /// 国内访问失败时尽快退化，避免拖垮整批同步（秒）。
    private static let requestTimeoutSeconds: TimeInterval = 12

    private static let shortTimeoutSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeoutSeconds
        config.timeoutIntervalForResource = requestTimeoutSeconds
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    enum WeatherError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Open-Meteo 响应无效"
            case .httpStatus(let code): return "Open-Meteo HTTP \(code)"
            case .decodeFailed: return "Open-Meteo 解析失败"
            }
        }
    }

    /// 按活动结束日选择主数据源。
    static func preferredSource(activityEnd: Date, now: Date = Date()) -> OpenMeteoWeatherSource {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = utc.startOfDay(for: now)
        let endDay = utc.startOfDay(for: activityEnd)
        let ageDays = utc.dateComponents([.day], from: endDay, to: today).day ?? Int.max
        if ageDays <= recentForecastMaxAgeDays {
            return .forecast
        }
        if endDay >= utc.startOfDay(for: historicalForecastAvailableFrom) {
            return .historicalForecast
        }
        return .archive
    }

    /// 拉取 [start, end] 覆盖的逐小时样本；主源失败或空结果时回退 Archive（主源已是 Archive 则不再回退）。
    static func fetchHourly(
        latitude: Double,
        longitude: Double,
        start: Date,
        end: Date,
        session: URLSession? = nil,
        now: Date = Date()
    ) async throws -> [WeatherSample] {
        let session = session ?? shortTimeoutSession
        let primary = preferredSource(activityEnd: end, now: now)
        do {
            let samples = try await fetchHourly(
                source: primary,
                latitude: latitude,
                longitude: longitude,
                start: start,
                end: end,
                session: session,
                now: now
            )
            if !samples.isEmpty {
                return samples
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            if primary == .archive { throw error }
        }
        guard primary != .archive else { return [] }
        // 调用 fetchHourly(archive)：主源空/失败时用 Archive 兜底。
        return try await fetchHourly(
            source: .archive,
            latitude: latitude,
            longitude: longitude,
            start: start,
            end: end,
            session: session,
            now: now
        )
    }

    /// 指定数据源拉取；Forecast 用 past_days，其余用 start_date/end_date。
    static func fetchHourly(
        source: OpenMeteoWeatherSource,
        latitude: Double,
        longitude: Double,
        start: Date,
        end: Date,
        session: URLSession? = nil,
        now: Date = Date()
    ) async throws -> [WeatherSample] {
        let session = session ?? shortTimeoutSession
        guard let url = makeURL(
            source: source,
            latitude: latitude,
            longitude: longitude,
            start: start,
            end: end,
            now: now
        ) else {
            throw WeatherError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw WeatherError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw WeatherError.httpStatus(http.statusCode) }

        return try decodeHourlySamples(from: data)
    }

    /// 组装请求 URL（供测试断言分流参数）。
    static func makeURL(
        source: OpenMeteoWeatherSource,
        latitude: Double,
        longitude: Double,
        start: Date,
        end: Date,
        now: Date = Date()
    ) -> URL? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let startDay = utc.startOfDay(for: start)
        let endDay = utc.startOfDay(for: end)
        let today = utc.startOfDay(for: now)
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"

        let hourly =
            "temperature_2m,relative_humidity_2m,pressure_msl,wind_speed_10m,wind_direction_10m"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "hourly", value: hourly),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "timezone", value: "UTC")
        ]

        let base: URL
        switch source {
        case .forecast:
            base = forecastBase
            let past = utc.dateComponents([.day], from: startDay, to: today).day ?? 0
            let pastDays = min(92, max(0, past))
            let future = utc.dateComponents([.day], from: today, to: endDay).day ?? 0
            let forecastDays = min(16, max(1, future + 1))
            items.append(URLQueryItem(name: "past_days", value: String(pastDays)))
            items.append(URLQueryItem(name: "forecast_days", value: String(forecastDays)))
        case .historicalForecast:
            base = historicalForecastBase
            items.append(URLQueryItem(name: "start_date", value: df.string(from: startDay)))
            items.append(URLQueryItem(name: "end_date", value: df.string(from: endDay)))
        case .archive:
            base = archiveBase
            items.append(URLQueryItem(name: "start_date", value: df.string(from: startDay)))
            items.append(URLQueryItem(name: "end_date", value: df.string(from: endDay)))
        }

        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.queryItems = items
        return comps.url
    }

    private static func decodeHourlySamples(from data: Data) throws -> [WeatherSample] {
        let decoded: HourlyResponse
        do {
            decoded = try JSONDecoder().decode(HourlyResponse.self, from: data)
        } catch {
            throw WeatherError.decodeFailed
        }
        guard let hourly = decoded.hourly,
              let times = hourly.time,
              let temps = hourly.temperature_2m,
              times.count == temps.count else {
            throw WeatherError.decodeFailed
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        // Open-Meteo 常返回无时区的 "yyyy-MM-dd'T'HH:mm"。
        let localIso = DateFormatter()
        localIso.locale = Locale(identifier: "en_US_POSIX")
        localIso.timeZone = TimeZone(secondsFromGMT: 0)
        localIso.dateFormat = "yyyy-MM-dd'T'HH:mm"

        var samples: [WeatherSample] = []
        samples.reserveCapacity(times.count)
        for i in 0..<times.count {
            let raw = times[i]
            let date = iso.date(from: raw + "Z") ?? localIso.date(from: raw)
            guard let date else { continue }
            guard let temp = temps[i] else { continue }
            let rh = hourly.relative_humidity_2m?[safe: i] ?? 50
            let pressure = hourly.pressure_msl?[safe: i] ?? 1013.25
            let wind = hourly.wind_speed_10m?[safe: i] ?? 0
            let dir = hourly.wind_direction_10m?[safe: i] ?? 0
            samples.append(
                WeatherSample(
                    date: date,
                    temperatureC: temp,
                    relativeHumidityPercent: rh ?? 50,
                    pressureMslHpa: pressure ?? 1013.25,
                    windSpeedMps: wind ?? 0,
                    windFromDegrees: dir ?? 0
                )
            )
        }
        return samples
    }

    private struct HourlyResponse: Decodable {
        var hourly: Hourly?
    }

    private struct Hourly: Decodable {
        var time: [String]?
        var temperature_2m: [Double?]?
        var relative_humidity_2m: [Double?]?
        var pressure_msl: [Double?]?
        var wind_speed_10m: [Double?]?
        var wind_direction_10m: [Double?]?
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
