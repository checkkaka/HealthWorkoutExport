import Foundation
import HealthKit
import FITSwiftSDK

/// 健康里已有训练的轻量摘要，供接近匹配（不依赖 HKWorkout，方便单测）。
struct HealthNearbyWorkout: Sendable, Equatable {
    var uuid: UUID
    var startDate: Date
    var endDate: Date
    var duration: TimeInterval
    var distanceMeters: Double?
    var sourceName: String?
    var syncIdentifier: String?
}

enum HealthProximity {
    /// 用与补源相同的 ActivityMatcher 窗口判断是否「接近」。
    static func overlapping(_ activity: SourceActivity, in nearby: [HealthNearbyWorkout]) -> [HealthNearbyWorkout] {
        nearby.filter { candidate in
            let asActivity = SourceActivity(
                id: candidate.uuid.uuidString,
                sourceId: HealthKitDataSource.sourceId,
                title: candidate.sourceName ?? "健康",
                startDate: candidate.startDate,
                endDate: candidate.endDate,
                duration: candidate.duration,
                distanceMeters: candidate.distanceMeters
            )
            return ActivityMatcher.score(primary: activity, candidate: asActivity) != nil
        }
    }

    static func alreadyImported(fingerprint: String, in nearby: [HealthNearbyWorkout]) -> HealthNearbyWorkout? {
        nearby.first { $0.syncIdentifier == fingerprint }
    }
}

/// FIT → 写入健康所需的明细草稿。
struct HealthWorkoutDraft: Sendable {
    var fingerprint: String
    var activityType: HKWorkoutActivityType
    var start: Date
    var end: Date
    var duration: TimeInterval
    var distanceMeters: Double?
    var energyKilocalories: Double?
    var locations: [RoutePoint]
    var heartRate: [TimedSample]
    var cadence: [TimedSample]
    var power: [TimedSample]
    var speed: [TimedSample]
    var events: [WorkoutEventDTO]

    static func fromFIT(_ data: Data, fingerprint: String) throws -> HealthWorkoutDraft {
        let messages = try FitMerger.decode(data, name: "health-import")
        let inspection = FITInspector.inspect(messages)
        let session = messages.sessionMesgs.first
        let recordDates = messages.recordMesgs.compactMap { $0.getTimestamp()?.date }.sorted()
        guard let start = session?.getStartTime()?.date ?? recordDates.first,
              let end = session?.getTimestamp()?.date ?? recordDates.last else {
            throw HealthKitServiceError.queryFailed("FIT 没有可用的开始/结束时间")
        }
        let duration: TimeInterval
        if let timer = session?.getTotalTimerTime() {
            duration = TimeInterval(timer)
        } else {
            duration = max(end.timeIntervalSince(start), 0)
        }
        let altByDate = Dictionary(
            (inspection.series[.altitude] ?? []).map { ($0.date, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let locations = inspection.track.map { point in
            RoutePoint(
                latitude: point.latitude,
                longitude: point.longitude,
                altitude: point.date.flatMap { altByDate[$0] },
                timestamp: point.date,
                speed: nil
            )
        }
        func samples(_ kind: FITSeriesKind, unit: String, scale: Double = 1) -> [TimedSample] {
            (inspection.series[kind] ?? []).map {
                TimedSample(date: $0.date, value: $0.value * scale, unit: unit)
            }
        }
        var events: [WorkoutEventDTO] = []
        for mesg in messages.eventMesgs {
            guard mesg.getEvent() == .timer, let date = mesg.getTimestamp()?.date else { continue }
            let type = mesg.getEventType()
            if date.timeIntervalSince(start) < 0.5, type == .start { continue }
            if abs(date.timeIntervalSince(end)) < 0.5,
               type == .stopAll || type == .stop || type == .stopDisable || type == .stopDisableAll { continue }
            switch type {
            case .stopAll, .stop, .stopDisable, .stopDisableAll:
                events.append(WorkoutEventDTO(type: "pause", date: date))
            case .start:
                events.append(WorkoutEventDTO(type: "resume", date: date))
            default:
                break
            }
        }
        let distance: Double?
        if let meters = session?.getTotalDistance() {
            distance = Double(meters)
        } else if inspection.summary.hasDistance {
            distance = inspection.summary.distanceMeters
        } else {
            distance = nil
        }
        let kcal: Double?
        if let calories = session?.getTotalCalories() {
            kcal = Double(calories)
        } else {
            kcal = nil
        }
        return HealthWorkoutDraft(
            fingerprint: fingerprint,
            activityType: mapActivityType(session?.getSport()),
            start: start,
            end: max(end, start),
            duration: duration,
            distanceMeters: distance,
            energyKilocalories: kcal,
            locations: locations,
            heartRate: samples(.heartRate, unit: "count/min"),
            cadence: samples(.cadence, unit: "rpm"),
            power: samples(.power, unit: "W"),
            speed: samples(.speed, unit: "m/s", scale: 1 / 3.6),
            events: events
        )
    }

    private static func mapActivityType(_ sport: Sport?) -> HKWorkoutActivityType {
        switch sport {
        case .running: return .running
        case .cycling: return .cycling
        case .walking: return .walking
        case .hiking: return .hiking
        case .swimming: return .swimming
        case .training: return .traditionalStrengthTraining
        case .rowing: return .rowing
        case .fitnessEquipment: return .elliptical
        case .soccer: return .soccer
        case .basketball: return .basketball
        case .tennis: return .tennis
        case .golf: return .golf
        case .alpineSkiing: return .downhillSkiing
        case .snowboarding: return .snowboarding
        case .rockClimbing: return .climbing
        default: return .other
        }
    }
}
