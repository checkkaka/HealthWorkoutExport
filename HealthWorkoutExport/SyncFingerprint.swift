import Foundation
import CryptoKit

/// 同步幂等指纹：主源活动 + 起止 + 补源集合 + 目标平台。
enum SyncFingerprint {
    static func make(
        primarySourceId: String,
        primaryActivityId: String,
        startDate: Date,
        supplementSourceIds: [String],
        destination: String = "strava"
    ) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let start = iso.string(from: startDate)
        let supplements = supplementSourceIds.sorted().joined(separator: ",")
        let raw = "\(primarySourceId)|\(primaryActivityId)|\(start)|\(supplements)|\(destination)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 跨主源稳定去重：开始时间 + 距离近似即视为同一场（换主源重跑不再上传）。
enum SyncStableDedupe {
    /// 开始时间紧窗（秒）：仅看距离即可。
    static let tightStartDelta: TimeInterval = 5 * 60
    /// 开始时间宽窗（秒）：覆盖多设备时钟/起停差；宽窗须时长也接近。
    static let maxStartDelta: TimeInterval = 45 * 60
    /// 宽窗下的时长相对差上限。
    static let maxDurationRatio = 0.20
    /// 距离相对差上限。
    static let maxDistanceRatio = 0.05
    /// 距离绝对差下限门槛（米）：短途用绝对值，长途用比例。
    static let maxDistanceAbsMeters = 100.0

    /// 两边距离都有效且开始接近、距离接近则判为同场。
    /// 宽窗（>tight）时须同时提供时长且相对差 ≤ maxDurationRatio，避免误伤相邻短途。
    static func matches(
        startA: Date,
        distanceA: Double,
        startB: Date,
        distanceB: Double,
        durationA: TimeInterval? = nil,
        durationB: TimeInterval? = nil
    ) -> Bool {
        guard distanceA > 0, distanceB > 0 else { return false }
        let startDelta = abs(startA.timeIntervalSince(startB))
        guard startDelta <= maxStartDelta else { return false }
        let diff = abs(distanceA - distanceB)
        let limit = max(maxDistanceAbsMeters, max(distanceA, distanceB) * maxDistanceRatio)
        guard diff <= limit else { return false }
        if startDelta <= tightStartDelta { return true }
        guard let durationA, let durationB, durationA > 0, durationB > 0 else { return false }
        let durRatio = abs(durationA - durationB) / max(durationA, durationB)
        return durRatio <= maxDurationRatio
    }
}
