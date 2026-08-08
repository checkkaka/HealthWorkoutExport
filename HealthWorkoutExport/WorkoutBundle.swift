import Foundation
import HealthKit

/// 时间序列样本点：统一承载各类 HealthKit quantity 读数。
struct TimedSample: Codable, Sendable, Hashable {
    let date: Date
    let value: Double
    let unit: String
}

/// GPS 轨迹点。
struct RoutePoint: Codable, Sendable, Hashable {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let timestamp: Date?
    let speed: Double?
}

/// 训练事件（暂停/继续/分段等）。
struct WorkoutEventDTO: Codable, Sendable, Hashable {
    let type: String
    let date: Date
}

/// 列表用轻量摘要（不含大样本，保证列表秒开）。
struct WorkoutSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let uuid: UUID
    let activityType: HKWorkoutActivityType
    let activityName: String
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let totalDistanceMeters: Double?
    let totalEnergyKilocalories: Double?
    let sourceName: String?
}

/// 单次训练完整导出包。
struct WorkoutBundle: Sendable {
    let summary: WorkoutSummary
    let metadata: [String: String]
    let events: [WorkoutEventDTO]
    /// 键为 identifier（如 HKQuantityTypeIdentifierHeartRate），值为时间序列。
    let series: [String: [TimedSample]]
    let route: [RoutePoint]
}

extension WorkoutBundle {
    /// 转为可 JSON 编码的字典结构；日期按指定时区输出 ISO8601（含偏移）。
    func jsonObject(timeZone: TimeZone = .current) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = timeZone

        func sampleArr(_ samples: [TimedSample]) -> [[String: Any]] {
            samples.map {
                [
                    "date": iso.string(from: $0.date),
                    "value": $0.value,
                    "unit": $0.unit
                ]
            }
        }

        var seriesObj: [String: Any] = [:]
        for (key, samples) in series {
            seriesObj[key] = sampleArr(samples)
        }

        // 可选值仅在非 nil 时写入，避免 Optional 进入 JSONSerialization 触发崩溃。
        var root: [String: Any] = [
            "id": summary.uuid.uuidString,
            "activityType": summary.activityType.rawValue,
            "activityName": summary.activityName,
            "startDate": iso.string(from: summary.startDate),
            "endDate": iso.string(from: summary.endDate),
            "durationSeconds": summary.duration,
            "timeZone": timeZone.identifier,
            "metadata": metadata,
            "events": events.map { ["type": $0.type, "date": iso.string(from: $0.date)] },
            "series": seriesObj,
            "route": route.map { point -> [String: Any] in
                var dict: [String: Any] = [
                    "latitude": point.latitude,
                    "longitude": point.longitude
                ]
                if let altitude = point.altitude { dict["altitude"] = altitude }
                if let timestamp = point.timestamp { dict["timestamp"] = iso.string(from: timestamp) }
                if let speed = point.speed { dict["speed"] = speed }
                return dict
            }
        ]
        if let distance = summary.totalDistanceMeters { root["totalDistanceMeters"] = distance }
        if let energy = summary.totalEnergyKilocalories { root["totalEnergyKilocalories"] = energy }
        if let source = summary.sourceName { root["sourceName"] = source }
        return root
    }
}

/// 导出可选时区：固定候选 + 当前时区，上海必在列表中。
enum ExportTimeZone {
    /// 下拉候选（identifier）；当前时区若不在其中会补到最前。
    static let candidateIdentifiers = [
        "Asia/Shanghai",
        "UTC",
        "Asia/Tokyo",
        "Europe/London",
        "America/New_York",
        "America/Los_Angeles"
    ]

    /// 生成下拉选项，去重并保证当前时区与上海都在。
    static func options() -> [TimeZone] {
        var seen = Set<String>()
        var result: [TimeZone] = []
        for id in [TimeZone.current.identifier] + candidateIdentifiers {
            guard !seen.contains(id), let zone = TimeZone(identifier: id) else { continue }
            seen.insert(id)
            result.append(zone)
        }
        return result
    }

    /// 展示名：城市名 + GMT 偏移。
    static func displayName(for zone: TimeZone) -> String {
        let seconds = zone.secondsFromGMT()
        let sign = seconds >= 0 ? "+" : "-"
        let hours = abs(seconds) / 3600
        let minutes = (abs(seconds) % 3600) / 60
        let offset = minutes == 0 ? "GMT\(sign)\(hours)" : String(format: "GMT%@%d:%02d", sign, hours, minutes)
        let city = zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier
        return "\(city.replacingOccurrences(of: "_", with: " ")) (\(offset))"
    }
}

enum DateRangePreset: String, CaseIterable, Identifiable {
    case days7
    case days30
    case thisYear
    /// 业务语义：不截断起始日，尽量拉全量（各源自行分页截断）。
    case all
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .days7: return "近7天"
        case .days30: return "近30天"
        case .thisYear: return "今年"
        case .all: return "全部"
        case .custom: return "自定义"
        }
    }

    /// 计算预设对应的起止时间（自定义由外部传入）。
    func resolve(customStart: Date, customEnd: Date, now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let end = now
        switch self {
        case .days7:
            let start = calendar.date(byAdding: .day, value: -7, to: end) ?? end
            return (start, end)
        case .days30:
            let start = calendar.date(byAdding: .day, value: -30, to: end) ?? end
            return (start, end)
        case .thisYear:
            let start = calendar.date(from: calendar.dateComponents([.year], from: end)) ?? end
            return (start, end)
        case .all:
            var comps = DateComponents()
            comps.year = 2000
            comps.month = 1
            comps.day = 1
            return (calendar.date(from: comps) ?? end, end)
        case .custom:
            let start = min(customStart, customEnd)
            let endDay = max(customStart, customEnd)
            let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDay)) ?? endDay
            return (calendar.startOfDay(for: start), endExclusive)
        }
    }
}
