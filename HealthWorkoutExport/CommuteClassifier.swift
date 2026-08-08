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
}
