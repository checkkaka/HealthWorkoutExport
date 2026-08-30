import Foundation
import FITSwiftSDK

enum FITQualitySeverity: Int, Comparable, Sendable {
    case info
    case warning
    case error

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }
}

struct FITQualityIssue: Identifiable, Sendable {
    var id: String
    var severity: FITQualitySeverity
    var title: String
    var detail: String
}

enum FITSeriesKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case speed
    case altitude
    case heartRate
    case cadence
    case power

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: return "速度"
        case .altitude: return "海拔"
        case .heartRate: return "心率"
        case .cadence: return "踏频"
        case .power: return "功率"
        }
    }

    var unit: String {
        switch self {
        case .speed: return "km/h"
        case .altitude: return "m"
        case .heartRate: return "bpm"
        case .cadence: return "rpm"
        case .power: return "W"
        }
    }
}

struct FITChartPoint: Identifiable, Sendable {
    var index: Int
    var date: Date
    var value: Double
    var id: Int { index }
}

struct FITTrackPoint: Identifiable, Sendable {
    var index: Int
    var date: Date?
    var latitude: Double
    var longitude: Double
    var id: Int { index }
}

struct FITCoordinateValue: Equatable, Sendable {
    var field: String
    var index: Int
    var timestamp: UInt32?
    var latitude: Int32?
    var longitude: Int32?
}

struct FITCoordinateSnapshot: Equatable, Sendable {
    var values: [FITCoordinateValue]

    func hasSameShape(as other: FITCoordinateSnapshot) -> Bool {
        guard values.count == other.values.count else { return false }
        return zip(values, other.values).allSatisfy { lhs, rhs in
            lhs.field == rhs.field
                && lhs.index == rhs.index
                && lhs.timestamp == rhs.timestamp
                && (lhs.latitude == nil) == (rhs.latitude == nil)
                && (lhs.longitude == nil) == (rhs.longitude == nil)
        }
    }
}

struct FITInspectionSummary: Sendable {
    var recordCount: Int = 0
    var gpsCount: Int = 0
    var heartRateCount: Int = 0
    var cadenceCount: Int = 0
    var powerCount: Int = 0
    var durationSeconds: TimeInterval = 0
    var distanceMeters: Double = 0
    var maximumSpeedKPH: Double = 0
    var maximumGPSSpeedKPH: Double = 0
}

struct FITInspection: Sendable {
    var summary: FITInspectionSummary
    var track: [FITTrackPoint]
    var series: [FITSeriesKind: [FITChartPoint]]
    var coordinates: FITCoordinateSnapshot
    var issues: [FITQualityIssue]

    var hasErrors: Bool { issues.contains { $0.severity == .error } }
    var hasWarnings: Bool { issues.contains { $0.severity == .warning } }

    func displayTrack(limit: Int = 2_000) -> [FITTrackPoint] {
        Self.sample(track, limit: limit)
    }

    func displaySeries(_ kind: FITSeriesKind, limit: Int = 600) -> [FITChartPoint] {
        Self.sample(series[kind] ?? [], limit: limit)
    }

    private static func sample<T>(_ values: [T], limit: Int) -> [T] {
        guard limit > 1, values.count > limit else { return values }
        let step = Double(values.count - 1) / Double(limit - 1)
        return (0..<limit).map { values[Int((Double($0) * step).rounded())] }
    }
}

enum FITInspector {
    private static let semicirclesPerDegree = 2_147_483_648.0 / 180.0

    static func inspect(_ data: Data, name: String = "FIT") -> FITInspection {
        do {
            return inspect(try FitMerger.decode(data, name: name))
        } catch {
            return FITInspection(
                summary: FITInspectionSummary(),
                track: [],
                series: [:],
                coordinates: FITCoordinateSnapshot(values: []),
                issues: [.init(
                    id: "invalid-fit",
                    severity: .error,
                    title: "FIT 无法解析",
                    detail: error.localizedDescription
                )]
            )
        }
    }

    static func inspect(_ messages: FitMessages) -> FITInspection {
        let records = messages.recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        let coordinates = coordinateSnapshot(messages)
        var summary = FITInspectionSummary(recordCount: records.count)
        var track: [FITTrackPoint] = []
        var series: [FITSeriesKind: [FITChartPoint]] = [:]
        var issues: [FITQualityIssue] = []
        let invalidCoordinateCount = coordinates.values.filter { value in
            guard value.latitude != nil || value.longitude != nil else { return false }
            guard let latitude = value.latitude, let longitude = value.longitude else { return true }
            let latDegrees = Double(latitude) / semicirclesPerDegree
            let lonDegrees = Double(longitude) / semicirclesPerDegree
            return !(-90...90).contains(latDegrees) || !(-180...180).contains(lonDegrees)
        }.count
        var previousGPS: (date: Date, latitude: Double, longitude: Double)?

        for (index, record) in records.enumerated() {
            guard let date = record.getTimestamp()?.date else { continue }
            if let speed = record.getSpeed() ?? record.getEnhancedSpeed() {
                let value = Double(speed) * 3.6
                series[.speed, default: []].append(.init(index: index, date: date, value: value))
                summary.maximumSpeedKPH = max(summary.maximumSpeedKPH, value)
            }
            if let altitude = record.getAltitude() ?? record.getEnhancedAltitude() {
                series[.altitude, default: []].append(.init(index: index, date: date, value: Double(altitude)))
            }
            if let value = record.getHeartRate() {
                summary.heartRateCount += 1
                series[.heartRate, default: []].append(.init(index: index, date: date, value: Double(value)))
            }
            if let value = record.getCadence() {
                summary.cadenceCount += 1
                series[.cadence, default: []].append(.init(index: index, date: date, value: Double(value)))
            }
            if let value = record.getPower() {
                summary.powerCount += 1
                series[.power, default: []].append(.init(index: index, date: date, value: Double(value)))
            }

            let rawLat = record.getPositionLat()
            let rawLon = record.getPositionLong()
            guard rawLat != nil || rawLon != nil else { continue }
            guard let rawLat, let rawLon else { continue }
            let latitude = Double(rawLat) / semicirclesPerDegree
            let longitude = Double(rawLon) / semicirclesPerDegree
            guard latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { continue }
            summary.gpsCount += 1
            track.append(.init(
                index: index,
                date: date,
                latitude: latitude,
                longitude: longitude
            ))
            if let previousGPS {
                let elapsed = date.timeIntervalSince(previousGPS.date)
                if elapsed > 0, elapsed <= 8 {
                    let speedKPH = haversineMeters(
                        latitude1: previousGPS.latitude,
                        longitude1: previousGPS.longitude,
                        latitude2: latitude,
                        longitude2: longitude
                    ) / elapsed * 3.6
                    summary.maximumGPSSpeedKPH = max(summary.maximumGPSSpeedKPH, speedKPH)
                }
            }
            previousGPS = (date, latitude, longitude)
        }

        let timestampedDates = records.compactMap { $0.getTimestamp()?.date }
        if let first = timestampedDates.first, let last = timestampedDates.last {
            summary.durationSeconds = messages.sessionMesgs.compactMap { $0.getTotalTimerTime() }
                .first.map { TimeInterval($0) } ?? max(0, last.timeIntervalSince(first))
        } else {
            issues.append(.init(
                id: "no-timestamp",
                severity: .error,
                title: "没有有效时间记录",
                detail: "FIT 中没有带时间戳的 Record，无法同步。"
            ))
        }
        let lastRecordDistance = records.last(where: { $0.getDistance() != nil })?.getDistance()
        summary.distanceMeters = messages.sessionMesgs.compactMap { $0.getTotalDistance() }
            .first.map { Double($0) }
            ?? lastRecordDistance.map { Double($0) }
            ?? 0

        if invalidCoordinateCount > 0 {
            issues.append(.init(
                id: "invalid-coordinate",
                severity: .error,
                title: "存在非法坐标",
                detail: "发现 \(invalidCoordinateCount) 条缺少经纬度配对或超出有效范围的坐标。"
            ))
        }
        if summary.gpsCount < 5 {
            issues.append(.init(
                id: "few-gps-points",
                severity: .warning,
                title: "GPS 点过少",
                detail: "仅有 \(summary.gpsCount) 个有效 GPS 点。"
            ))
        }
        if summary.maximumSpeedKPH > 80 {
            issues.append(.init(
                id: "speed-over-80",
                severity: .warning,
                title: "速度字段异常",
                detail: String(format: "最高速度字段 %.1f km/h，超过 80 km/h。", summary.maximumSpeedKPH)
            ))
        }
        if summary.maximumGPSSpeedKPH > 120 {
            issues.append(.init(
                id: "gps-speed-over-120",
                severity: .warning,
                title: "GPS 推算速度异常",
                detail: String(format: "相邻轨迹点推算最高 %.1f km/h，超过 120 km/h。", summary.maximumGPSSpeedKPH)
            ))
        }
        if summary.heartRateCount == 0 {
            issues.append(.init(id: "missing-heart-rate", severity: .info, title: "缺少心率", detail: "该 FIT 没有心率记录。"))
        }
        if summary.powerCount == 0 {
            issues.append(.init(id: "missing-power", severity: .info, title: "缺少功率", detail: "该 FIT 没有功率记录。"))
        }

        return FITInspection(
            summary: summary,
            track: track,
            series: series,
            coordinates: coordinates,
            issues: issues
        )
    }

    static func processingIssues(
        original: FITInspection,
        final: FITInspection,
        gcjEnabled: Bool,
        mergeReports: [FitSupplementReport],
        repairedSpeedCount: Int,
        convertedCoordinateCount: Int,
        averageCoordinateDisplacementMeters: Double,
        virtualPowerCount: Int
    ) -> [FITQualityIssue] {
        var issues: [FITQualityIssue] = []
        if !original.coordinates.hasSameShape(as: final.coordinates) {
            issues.append(.init(
                id: "coordinate-shape-changed",
                severity: .error,
                title: "坐标结构发生变化",
                detail: "处理前后坐标字段数量、时间戳或空值位置不一致。"
            ))
        } else if !gcjEnabled, original.coordinates != final.coordinates {
            issues.append(.init(
                id: "coordinate-changed-while-disabled",
                severity: .error,
                title: "坐标被意外修改",
                detail: "GCJ→WGS 已关闭，但 Record/Lap/Session 坐标并非逐值一致，已禁止上传。"
            ))
        }
        if final.summary.gpsCount < original.summary.gpsCount {
            issues.append(.init(
                id: "gps-points-lost",
                severity: .error,
                title: "处理后丢失 GPS 点",
                detail: "有效 GPS 点从 \(original.summary.gpsCount) 减少为 \(final.summary.gpsCount)。"
            ))
        }
        for (id, title, oldCount, newCount) in [
            ("heart-rate-lost", "心率", original.summary.heartRateCount, final.summary.heartRateCount),
            ("cadence-lost", "踏频", original.summary.cadenceCount, final.summary.cadenceCount),
            ("power-lost", "功率", original.summary.powerCount, final.summary.powerCount)
        ] where newCount < oldCount {
            issues.append(.init(
                id: id,
                severity: .error,
                title: "处理后丢失\(title)点",
                detail: "\(title)点从 \(oldCount) 减少为 \(newCount)。"
            ))
        }
        let distanceDelta = abs(final.summary.distanceMeters - original.summary.distanceMeters)
        let allowedDistanceDelta = max(200, original.summary.distanceMeters * 0.02)
        if distanceDelta > allowedDistanceDelta {
            issues.append(.init(
                id: "distance-changed",
                severity: .warning,
                title: "距离变化较大",
                detail: String(format: "处理前后距离相差 %.0f 米，阈值为 %.0f 米。", distanceDelta, allowedDistanceDelta)
            ))
        }
        if repairedSpeedCount > 0 {
            issues.append(.init(
                id: "speed-repaired",
                severity: .warning,
                title: "速度字段已修复",
                detail: "修复了 \(repairedSpeedCount) 个异常速度/距离点；坐标未参与改写。"
            ))
        }
        for report in mergeReports where report.totalFilledCount == 0 {
            issues.append(.init(
                id: "supplement-empty-\(report.name)",
                severity: .warning,
                title: "补源未补入字段",
                detail: "\(report.name) 未补入心率、踏频、功率、温度或坡度。"
            ))
        }
        if gcjEnabled {
            issues.append(.init(
                id: "gcj-conversion",
                severity: .info,
                title: "GCJ→WGS 转换",
                detail: String(format: "转换 %d 组坐标，平均位移 %.1f 米。", convertedCoordinateCount, averageCoordinateDisplacementMeters)
            ))
        }
        if virtualPowerCount > 0 {
            issues.append(.init(
                id: "virtual-power",
                severity: .info,
                title: "虚拟功率已写入",
                detail: "写入或覆盖了 \(virtualPowerCount) 个功率点。"
            ))
        }
        return issues
    }

    private static func coordinateSnapshot(_ messages: FitMessages) -> FITCoordinateSnapshot {
        var values: [FITCoordinateValue] = []
        let records = messages.recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        for (index, record) in records.enumerated() {
            values.append(.init(
                field: "record.position",
                index: index,
                timestamp: record.getTimestamp()?.timestamp,
                latitude: record.getPositionLat(),
                longitude: record.getPositionLong()
            ))
        }
        let laps = messages.lapMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        for (index, lap) in laps.enumerated() {
            let timestamp = lap.getTimestamp()?.timestamp
            values.append(.init(field: "lap.start", index: index, timestamp: timestamp, latitude: lap.getStartPositionLat(), longitude: lap.getStartPositionLong()))
            values.append(.init(field: "lap.end", index: index, timestamp: timestamp, latitude: lap.getEndPositionLat(), longitude: lap.getEndPositionLong()))
        }
        let sessions = messages.sessionMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        for (index, session) in sessions.enumerated() {
            let timestamp = session.getTimestamp()?.timestamp
            values.append(.init(field: "session.start", index: index, timestamp: timestamp, latitude: session.getStartPositionLat(), longitude: session.getStartPositionLong()))
            values.append(.init(field: "session.nec", index: index, timestamp: timestamp, latitude: session.getNecLat(), longitude: session.getNecLong()))
            values.append(.init(field: "session.swc", index: index, timestamp: timestamp, latitude: session.getSwcLat(), longitude: session.getSwcLong()))
            values.append(.init(field: "session.end", index: index, timestamp: timestamp, latitude: session.getEndPositionLat(), longitude: session.getEndPositionLong()))
        }
        return FITCoordinateSnapshot(values: values)
    }

    private static func haversineMeters(
        latitude1: Double,
        longitude1: Double,
        latitude2: Double,
        longitude2: Double
    ) -> Double {
        let radius = 6_371_000.0
        let lat1 = latitude1 * .pi / 180
        let lat2 = latitude2 * .pi / 180
        let dLat = (latitude2 - latitude1) * .pi / 180
        let dLon = (longitude2 - longitude1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
