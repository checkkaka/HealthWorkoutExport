import Foundation

/// Strava 远端活动预检与 duplicate 文案解析（纯函数 + 列表匹配）。
enum StravaActivityLookup {
    struct RemoteActivity: Equatable {
        var id: String
        var startDate: Date
        var endDate: Date
        /// 列表距离（米）；缺则只走时间判据。
        var distanceMeters: Double? = nil
    }

    /// 判为同一条所需的最小时间区间重叠比例（交集/并集）。
    /// 仅开始时间接近不算重复：热身、拆段等相邻活动区间几乎不重叠。
    static let minOverlapRatio = 0.5
    /// 无足够 IoU 时：开始时间差上限（秒），对齐多设备时钟差 / 起停差。
    static let maxStartDelta: TimeInterval = 45 * 60
    /// 无足够 IoU 时：时长相对差上限（与 ActivityMatcher 一致）。
    static let maxDurationRatio = 0.20

    /// 拉取远端列表时向两侧多取的时间，覆盖跨边界的活动。
    static let fetchPadding: TimeInterval = 24 * 60 * 60

    /// 在已拉取的远端列表中匹配同一场：优先区间 IoU，其次开始+时长，再其次开始+距离。
    static func match(
        startDate: Date,
        endDate: Date,
        distanceMeters: Double? = nil,
        in activities: [RemoteActivity]
    ) -> RemoteActivity? {
        var best: RemoteActivity?
        var bestScore = 0.0
        let localDur = max(endDate.timeIntervalSince(startDate), 1)
        for activity in activities {
            let remoteDur = max(activity.endDate.timeIntervalSince(activity.startDate), 1)
            var score = 0.0
            let overlapStart = max(startDate, activity.startDate)
            let overlapEnd = min(endDate, activity.endDate)
            let overlap = overlapEnd.timeIntervalSince(overlapStart)
            if overlap > 0 {
                let union = max(endDate, activity.endDate).timeIntervalSince(min(startDate, activity.startDate))
                if union > 0 {
                    let ratio = overlap / union
                    if ratio >= minOverlapRatio {
                        // IoU 命中：分数落在 1...2，优先于时长/距离近似。
                        score = 1 + ratio
                    }
                }
            }
            if score == 0 {
                let startDelta = abs(startDate.timeIntervalSince(activity.startDate))
                if startDelta <= maxStartDelta {
                    let durRatio = abs(localDur - remoteDur) / max(localDur, remoteDur)
                    if durRatio <= maxDurationRatio {
                        // 时长近似：分数 < 1，避免压过真正的高 IoU。
                        score = max(0.01, (1 - startDelta / maxStartDelta) * (1 - durRatio) * 0.99)
                    }
                }
            }
            if score == 0,
               let localDist = distanceMeters, localDist > 0,
               let remoteDist = activity.distanceMeters, remoteDist > 0,
               SyncStableDedupe.matches(
                startA: startDate,
                distanceA: localDist,
                startB: activity.startDate,
                distanceB: remoteDist,
                durationA: localDur,
                durationB: remoteDur
               ) {
                // 开始+距离（宽窗还看时长）：分数略低于纯时长近似。
                let startDelta = abs(startDate.timeIntervalSince(activity.startDate))
                score = max(0.01, (1 - startDelta / SyncStableDedupe.maxStartDelta) * 0.5)
            }
            guard score > bestScore else { continue }
            bestScore = score
            best = activity
        }
        return best
    }

    /// 解析 Uploads 错误里的 duplicate 活动 ID。
    /// 支持：`duplicate of activity 21234316`，以及网页 HTML：`duplicate of <a href='/activities/123'>`。
    static func parseDuplicateActivityId(_ text: String) -> String? {
        let patterns = [
            #"duplicate of activity (\d+)"#,
            #"duplicate of\s*<a[^>]*href=['\"]/activities/(\d+)"#
        ]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let idRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let id = String(text[idRange])
            if !id.isEmpty { return id }
        }
        // 兜底：文案含 duplicate 且能抠出 /activities/数字
        guard text.range(of: "duplicate", options: .caseInsensitive) != nil else { return nil }
        if let regex = try? NSRegularExpression(pattern: #"/activities/(\d+)"#, options: []),
           let match = regex.firstMatch(in: text, options: [], range: range),
           match.numberOfRanges >= 2,
           let idRange = Range(match.range(at: 1), in: text) {
            return String(text[idRange])
        }
        return nil
    }

    /// 响应是否为 Strava duplicate（含 HTML 链接形态）。
    static func isDuplicateUploadResponse(_ text: String) -> Bool {
        parseDuplicateActivityId(text) != nil
            || text.range(of: #"duplicate of activity"#, options: [.regularExpression, .caseInsensitive]) != nil
            || text.range(of: #"duplicate of\s*<a"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 从 Uploads JSON 取数字 `activity_id`；忽略缺失 / NSNull / `"<null>"`（否则会写成假远端 ID）。
    static func jsonActivityId(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            let s = number.stringValue
            return StravaSpeedAnomaly.isOpenableRemoteId(s) ? s : nil
        }
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "<null>" || trimmed.lowercased() == "null" { return nil }
            return StravaSpeedAnomaly.isOpenableRemoteId(trimmed) ? trimmed : nil
        }
        let s = "\(value)"
        if s.isEmpty || s == "<null>" { return nil }
        return StravaSpeedAnomaly.isOpenableRemoteId(s) ? s : nil
    }
}

/// 用峰值+均速 / 摘要最高速 / 最佳成绩判断合并轨迹异常（扫描与跳过历史共用）。
enum StravaSpeedAnomaly {
    /// 异常峰值 / 摘要最高速 / 最佳成绩阈值（km/h）。
    static let maxSpeedKmh = 80.0
    /// 异常均速阈值（km/h）：与综合峰值同时满足时也算异常。
    static let averageSpeedKmh = 40.0

    static var peakThresholdMps: Double { maxSpeedKmh / 3.6 }
    static var averageThresholdMps: Double { averageSpeedKmh / 3.6 }

    /// 判定异常（满足任一即可）：
    /// 1) 摘要 `max_speed` ≥ 80
    /// 2) 最佳成绩任一分段推算速度 ≥ 80
    /// 3) 综合峰值 ≥ 80 且均速 ≥ 40
    static func isAnomalous(
        listedMaxSpeedMps: Double,
        bestEffortPeakMps: Double,
        peakSpeedMps: Double,
        averageSpeedMps: Double
    ) -> Bool {
        if listedMaxSpeedMps >= peakThresholdMps { return true }
        if bestEffortPeakMps >= peakThresholdMps { return true }
        if peakSpeedMps >= peakThresholdMps && averageSpeedMps >= averageThresholdMps { return true }
        return false
    }

    static func isOpenableRemoteId(_ remoteId: String) -> Bool {
        !remoteId.isEmpty
            && remoteId != "unknown"
            && remoteId != "<null>"
            && remoteId.allSatisfy(\.isNumber)
    }

    /// 是否骑车类（异常扫描只看这类，健走/跑步等忽略）。
    static func isCyclingSport(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return false }
        // 中英文常见骑车类型。
        let keywords = [
            "ride", "cycling", "cycle", "bike", "biking", "gravel", "ebike", "e-bike",
            "virtualride", "handcycle", "velomobile",
            "骑行", "骑车", "公路", "山地", "砾石"
        ]
        if keywords.contains(where: { s == $0 || s.contains($0) }) { return true }
        // 明确排除步行/跑步等。
        let exclude = ["walk", "run", "hike", "swim", "ski", "yoga", "workout", "健走", "跑步", "步行", "游泳"]
        if exclude.contains(where: { s == $0 || s.contains($0) }) { return false }
        return false
    }

    /// 从列表 JSON 取 sport / type 字段。
    static func sportType(from item: [String: Any]) -> String {
        if let s = item["sport_type"] as? String, !s.isEmpty { return s }
        if let s = item["type"] as? String, !s.isEmpty { return s }
        if let s = item["activity_type"] as? String, !s.isEmpty { return s }
        if let s = item["activityType"] as? String, !s.isEmpty { return s }
        return ""
    }

    /// 仅由 best_efforts 推算的峰值 m/s（不含摘要 max_speed）。
    static func bestEffortPeakMps(bestEfforts: [[String: Any]]) -> Double {
        peakSpeedMps(maxSpeedMps: 0, bestEfforts: bestEfforts)
    }

    /// 取活动摘要最高速与 best_efforts（距离/耗时）中的峰值 m/s。
    /// 只计距离 ≥200m 的成绩（对齐 400m/1mi/5k/20k 等，忽略噪声短段）。
    static func peakSpeedMps(maxSpeedMps: Double, bestEfforts: [[String: Any]]) -> Double {
        var peak = max(0, maxSpeedMps)
        for effort in bestEfforts {
            let distance = doubleValue(effort["distance"]) ?? 0
            let elapsed = doubleValue(effort["elapsed_time"])
                ?? doubleValue(effort["moving_time"])
                ?? 0
            guard distance >= 200, elapsed > 0 else { continue }
            peak = max(peak, distance / elapsed)
        }
        return peak
    }

    static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}

/// API / 网页扫描共用的活动速度摘要。
struct StravaActivitySpeedInfo: Sendable {
    var id: String
    var name: String
    var startDate: Date?
    /// Strava sport_type / type（如 Ride、Walk）。
    var sportType: String
    /// Strava 摘要字段 max_speed（m/s）。
    var listedMaxSpeedMps: Double
    /// 最佳成绩推算的峰值（m/s）；不含速度流毛刺。
    var bestEffortPeakMps: Double
    /// 有效峰值（m/s）：max(listedMax, bestEffortPeak)。
    var maxSpeedMps: Double
    /// 均速（m/s）。
    var averageSpeedMps: Double
    /// 峰值主要来自最佳成绩分段。
    var fromBestEffort: Bool

    var isCycling: Bool {
        StravaSpeedAnomaly.isCyclingSport(sportType)
    }

    var isAnomalous: Bool {
        guard isCycling else { return false }
        return StravaSpeedAnomaly.isAnomalous(
            listedMaxSpeedMps: listedMaxSpeedMps,
            bestEffortPeakMps: bestEffortPeakMps,
            peakSpeedMps: maxSpeedMps,
            averageSpeedMps: averageSpeedMps
        )
    }
}

/// 用户对「远端已存在 / duplicate」的选择。
enum StravaDuplicateDecision: Sendable {
    /// 记为已上传，跳过。
    case skip
    /// 本批剩余重复一律跳过（仅当前这次同步任务）。
    case skipRestOfBatch
    /// 打开 Strava 活动页，本条不记 uploaded（便于删后重试）。
    case openRemote
    /// 用网页 Cookie 删远端后再按当前模式重传。
    case overwrite
    /// 本批剩余重复一律覆盖（仅当前这次同步任务，不跨批记住）。
    case overwriteRestOfBatch
}
