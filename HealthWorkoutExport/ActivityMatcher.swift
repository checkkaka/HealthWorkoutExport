import Foundation

enum ActivityMatchConfidence: String, Sendable {
    case high
    case medium
    case low

    var title: String {
        switch self {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }
}

struct ActivityMatchCandidate: Identifiable, Sendable {
    var activity: SourceActivity
    var score: Double
    var confidence: ActivityMatchConfidence
    var reason: String
    var isEligible: Bool

    var id: String { activity.id }
}

/// 主活动与补源活动的时间窗匹配（区间 IoU 优先）。
enum ActivityMatcher {
    /// 区间重叠匹配的最小 IoU，避免仅擦边一小段也合并补源。
    static let minOverlapRatio = 0.5
    /// 开始时间差上限（秒）。
    static let maxStartDelta: TimeInterval = 15 * 60
    /// 时长相对差上限。
    static let maxDurationRatio = 0.20
    /// 低于该分数即使只有一个候选也需人工确认。
    static let lowConfidenceThreshold = 0.60
    /// 前两名分差小于该值视为歧义。
    static let ambiguousScoreDelta = 0.15
    /// 手工选择列表放宽到开始时间差 30 分钟。
    static let manualCandidateStartDelta: TimeInterval = 30 * 60
    /// 手工选择列表放宽到时长差 50%。
    static let manualCandidateDurationRatio = 0.50

    /// 在 candidates 中为 primary 选最佳一条；无合适匹配返回 nil。
    static func bestMatch(primary: SourceActivity, candidates: [SourceActivity]) -> SourceActivity? {
        rankedCandidates(primary: primary, candidates: candidates)
            .first(where: \.isEligible)?
            .activity
    }

    /// 自动匹配候选排在前面，同时保留附近但未达自动阈值的活动供人工选择。
    static func rankedCandidates(
        primary: SourceActivity,
        candidates: [SourceActivity]
    ) -> [ActivityMatchCandidate] {
        candidates.compactMap { candidate in
            let eligibleScore = score(primary: primary, candidate: candidate)
            guard eligibleScore != nil || isManualCandidate(primary: primary, candidate: candidate) else {
                return nil
            }
            let value = eligibleScore ?? 0
            let confidence: ActivityMatchConfidence
            if value >= 0.80 {
                confidence = .high
            } else if value >= lowConfidenceThreshold {
                confidence = .medium
            } else {
                confidence = .low
            }
            return ActivityMatchCandidate(
                activity: candidate,
                score: value,
                confidence: confidence,
                reason: matchReason(primary: primary, candidate: candidate, eligible: eligibleScore != nil),
                isEligible: eligibleScore != nil
            )
        }
        .sorted {
            if $0.isEligible != $1.isEligible { return $0.isEligible && !$1.isEligible }
            if $0.score != $1.score { return $0.score > $1.score }
            let left = abs($0.activity.startDate.timeIntervalSince(primary.startDate))
            let right = abs($1.activity.startDate.timeIntervalSince(primary.startDate))
            return left < right
        }
    }

    static func requiresConfirmation(_ candidates: [ActivityMatchCandidate]) -> Bool {
        let eligible = candidates.filter(\.isEligible)
        guard let first = eligible.first else { return !candidates.isEmpty }
        if first.score < lowConfidenceThreshold { return true }
        guard eligible.count > 1 else { return false }
        return first.score - eligible[1].score < ambiguousScoreDelta
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
            let ratio = overlap / union
            if ratio >= minOverlapRatio { return ratio }
        }

        let startDelta = abs(pStart.timeIntervalSince(cStart))
        guard startDelta <= maxStartDelta else { return nil }
        let ratio = abs(pDur - cDur) / max(pDur, cDur)
        guard ratio <= maxDurationRatio else { return nil }
        // 无重叠或低重叠时，用开始与时长容差兜底；越近分数越高。
        return max(0, 1 - startDelta / maxStartDelta) * (1 - ratio)
    }

    private static func isManualCandidate(primary: SourceActivity, candidate: SourceActivity) -> Bool {
        let startDelta = abs(primary.startDate.timeIntervalSince(candidate.startDate))
        guard startDelta <= manualCandidateStartDelta else { return false }
        let primaryDuration = max(primary.duration, 1)
        let candidateDuration = max(candidate.duration, 1)
        let ratio = abs(primaryDuration - candidateDuration) / max(primaryDuration, candidateDuration)
        return ratio <= manualCandidateDurationRatio
    }

    private static func matchReason(
        primary: SourceActivity,
        candidate: SourceActivity,
        eligible: Bool
    ) -> String {
        let startDeltaMinutes = abs(primary.startDate.timeIntervalSince(candidate.startDate)) / 60
        let primaryDuration = max(primary.duration, 1)
        let candidateDuration = max(candidate.duration, 1)
        let durationRatio = abs(primaryDuration - candidateDuration) / max(primaryDuration, candidateDuration)
        let overlap = min(primary.endDate, candidate.endDate).timeIntervalSince(max(primary.startDate, candidate.startDate))
        if overlap > 0 {
            let union = max(primary.endDate, candidate.endDate).timeIntervalSince(min(primary.startDate, candidate.startDate))
            if union > 0, overlap / union >= minOverlapRatio {
                return String(format: "时间重叠 %.0f%%", overlap / union * 100)
            }
        }
        return String(
            format: eligible ? "开始差 %.1f 分钟 · 时长差 %.0f%%" : "仅供手工选择：开始差 %.1f 分钟 · 时长差 %.0f%%",
            startDeltaMinutes,
            durationRatio * 100
        )
    }
}
