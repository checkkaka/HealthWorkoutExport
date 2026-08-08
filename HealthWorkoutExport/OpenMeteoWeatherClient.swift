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

/// Open-Meteo Archive API：按经纬度+日期拉取逐小时风与温湿压。
enum OpenMeteoWeatherClient {
    /// 历史天气根地址。
    private static let archiveBase = URL(string: "https://archive-api.open-meteo.com/v1/archive")!

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

    /// 拉取 [start, end] 覆盖的逐小时样本；风速请求为 m/s。
    static func fetchHourly(
        latitude: Double,
        longitude: Double,
        start: Date,
        end: Date,
        session: URLSession = .shared
    ) async throws -> [WeatherSample] {
        let cal = Calendar(identifier: .gregorian)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let startDay = utc.startOfDay(for: start)
        let endDay = utc.startOfDay(for: end)
        let df = DateFormatter()
        df.calendar = cal
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"

        var comps = URLComponents(url: archiveBase, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "start_date", value: df.string(from: startDay)),
            URLQueryItem(name: "end_date", value: df.string(from: endDay)),
            URLQueryItem(
                name: "hourly",
                value: "temperature_2m,relative_humidity_2m,pressure_msl,wind_speed_10m,wind_direction_10m"
            ),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "timezone", value: "UTC")
        ]
        guard let url = comps.url else { throw WeatherError.invalidResponse }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw WeatherError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw WeatherError.httpStatus(http.statusCode) }

        let decoded: ArchiveResponse
        do {
            decoded = try JSONDecoder().decode(ArchiveResponse.self, from: data)
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
            let temp = temps[i]
            let rh = hourly.relative_humidity_2m?[safe: i] ?? 50
            let pressure = hourly.pressure_msl?[safe: i] ?? 1013.25
            let wind = hourly.wind_speed_10m?[safe: i] ?? 0
            let dir = hourly.wind_direction_10m?[safe: i] ?? 0
            samples.append(
                WeatherSample(
                    date: date,
                    temperatureC: temp,
                    relativeHumidityPercent: rh,
                    pressureMslHpa: pressure,
                    windSpeedMps: wind,
                    windFromDegrees: dir
                )
            )
        }
        return samples
    }

    private struct ArchiveResponse: Decodable {
        var hourly: Hourly?
    }

    private struct Hourly: Decodable {
        var time: [String]?
        var temperature_2m: [Double]?
        var relative_humidity_2m: [Double]?
        var pressure_msl: [Double]?
        var wind_speed_10m: [Double]?
        var wind_direction_10m: [Double]?
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
