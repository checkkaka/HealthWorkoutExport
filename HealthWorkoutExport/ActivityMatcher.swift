import Foundation

/// 主活动与补源活动的时间窗匹配（区间 IoU 优先）。
enum ActivityMatcher {
    /// 开始时间差上限（秒）。
    static let maxStartDelta: TimeInterval = 15 * 60
    /// 时长相对差上限。
    static let maxDurationRatio = 0.20

    /// 在 candidates 中为 primary 选最佳一条；无合适匹配返回 nil。
    static func bestMatch(primary: SourceActivity, candidates: [SourceActivity]) -> SourceActivity? {
        var best: (SourceActivity, Double)?
        for candidate in candidates {
            if let score = score(primary: primary, candidate: candidate) {
                if best == nil || score > best!.1 {
                    best = (candidate, score)
                }
            }
        }
        return best?.0
    }

    /// 分数越高越好；不匹配返回 nil。
    static func score(primary: SourceActivity, candidate: SourceActivity) -> Double? {
        let pStart = primary.startDate
        let pEnd = primary.endDate
        let cStart = candidate.startDate
        let cEnd = candidate.endDate
        let pDur = max(pEnd.timeIntervalSince(pStart), primary.duration, 1)
        let cDur = max(cEnd.timeIntervalSince(cStart), candidate.duration, 1)

        let overlapStart = max(pStart, cStart)
        let overlapEnd = min(pEnd, cEnd)
        let overlap = overlapEnd.timeIntervalSince(overlapStart)
        if overlap > 0 {
            let union = max(pEnd, cEnd).timeIntervalSince(min(pStart, cStart))
            guard union > 0 else { return nil }
            return overlap / union
        }

        let startDelta = abs(pStart.timeIntervalSince(cStart))
        guard startDelta <= maxStartDelta else { return nil }
        let ratio = abs(pDur - cDur) / max(pDur, cDur)
        guard ratio <= maxDurationRatio else { return nil }
        // 无重叠时用「越近越高」的伪 IoU。
        return max(0, 1 - startDelta / maxStartDelta) * (1 - ratio)
    }
}
