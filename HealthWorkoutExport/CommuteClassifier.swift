import Foundation

/// 根据距离/均速判断是否标记为 Strava 通勤（API `commute` 字段）。
/// 规则：距离 < 5km，或（均速 < 28 km/h 且距离 < 16km）。
enum CommuteClassifier {
    /// 距离上限（公里）：短于该值一律视为通勤。
    static let shortDistanceKm = 5.0
    /// 均速上限（公里/时）：慢于该值且距离未超长途上限时视为通勤。
    static let slowSpeedKmh = 28.0
    /// 慢速通勤的距离上限（公里）。
    static let slowCommuteMaxDistanceKm = 16.0

    static func isCommute(distanceMeters: Double?, durationSeconds: TimeInterval) -> Bool {
        guard let meters = distanceMeters, meters > 0, durationSeconds > 0 else {
            return false
        }
        let distanceKm = meters / 1000
        if distanceKm < shortDistanceKm { return true }
        let speedKmh = distanceKm / (durationSeconds / 3600)
        return speedKmh < slowSpeedKmh && distanceKm < slowCommuteMaxDistanceKm
    }

    /// 未填自定义标题时，通勤活动上传到 Strava 的名称。
    static let commuteActivityTitle = "通勤🚲"

    /// 自定义标题优先；否则通勤用「通勤🚲」，其它沿用源标题。
    static func stravaActivityName(
        customTitle: String?,
        isCommute: Bool,
        originalTitle: String
    ) -> String {
        let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        if isCommute { return commuteActivityTitle }
        return originalTitle
    }

    /// 通勤按路肩/楼群遮蔽，开阔公路不额外打折。叠在 10 m→骑手高度折减之上。
    static let commuteWindShelterFactor = 0.7
    static let openWindShelterFactor = 1.0

    static func windShelterFactor(distanceMeters: Double?, durationSeconds: TimeInterval) -> Double {
        isCommute(distanceMeters: distanceMeters, durationSeconds: durationSeconds)
            ? commuteWindShelterFactor
            : openWindShelterFactor
    }
}
