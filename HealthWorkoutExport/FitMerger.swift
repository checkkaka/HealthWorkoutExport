import Foundation
import FITSwiftSDK

enum FitMergeError: LocalizedError {
    case needAtLeastTwoFiles
    case invalidFitFile(String)
    case alignFailed(String)

    var errorDescription: String? {
        switch self {
        case .needAtLeastTwoFiles: return "请至少选择 2 个 FIT 文件"
        case .invalidFitFile(let name): return "无法解析 FIT 文件：\(name)"
        case .alignFailed(let message): return message
        }
    }
}

/// 副文件时间轴相对主文件的对齐方式。
/// offset 语义：加到副文件时间戳上再与主对齐（迈金时钟快 871 秒时填 -871）。
enum FitMergeTimeAlign: Equatable {
    /// 直接用绝对时间戳，不做偏移。
    case absolute
    /// 手动：所有副文件统一加 seconds。
    case manual(seconds: Int)
    /// 自动：按速度互相关为每个副文件估偏移。
    case automatic
    /// 每个副文件用调用方预先算好的偏移（与 others 顺序一一对应），避免 merge 内重复估算。
    case perFile(offsets: [Int])
}

/// 副文件相对主文件的补缺策略。
enum FitSupplementMode: Equatable {
    /// 旧行为：同秒补全缺字段；主缺的秒整条插入（含 GPS）。手动合并页用。
    case fillRecords
    /// 自动同步：只往主已有秒上补传感器；绝不插入副源 GPS/distance，起止严格跟主源。
    case sensorsOnly
}

/// 合并多个 FIT Activity 文件：主文件为基准，其余文件仅补充主文件空缺的数据。
///
/// 合并规则（`fillRecords`）：
/// - Record 按「秒」对齐：主文件已有该秒的记录时，只把副文件该秒记录里主缺失的字段补进去（冲突以主为准）；
///   主文件没有该秒的记录时，整条补入（时间戳改写到对齐后的主时间轴）。
/// - Session 汇总按字段补缺；与主完全不重叠的副文件段，距离/卡路里/计时时长做求和。
/// - Event / Lap：主时间范围内沿用主文件；范围外保留副文件各自的（防重叠双计）。
/// - Activity / FileId 沿用主文件。
///
/// `sensorsOnly`（自动同步）：同秒只补心率/功率/踏频等；主缺秒不插整条；起止/距离以主为准。
enum FitMerger {
    /// 解码 FIT 二进制为消息集合。
    static func decode(_ data: Data, name: String = "fit") throws -> FitMessages {
        let stream = FITSwiftSDK.InputStream(data: data)
        let decoder = FITSwiftSDK.Decoder(stream: stream)
        let listener = FitListener()
        decoder.addMesgListener(listener)
        do {
            // 调用 decoder.read：解析整个 FIT 文件并派发到 listener。
            try decoder.read()
        } catch {
            throw FitMergeError.invalidFitFile(name)
        }
        return listener.fitMessages
    }

    /// 估算副文件相对主文件的起点偏移（秒）：用 Session.startTime，否则首条 Record。
    /// 自动速度对齐失败时的兜底，便于同秒补传感器（不插 GPS）。
    static func estimateStartOffset(primaryMessages: FitMessages, secondaryMessages: FitMessages) -> Int? {
        func firstTimestamp(_ messages: FitMessages) -> UInt32? {
            if let start = messages.sessionMesgs.first?.getStartTime()?.timestamp {
                return start
            }
            return messages.recordMesgs.compactMap { $0.getTimestamp()?.timestamp }.min()
        }
        guard let primary = firstTimestamp(primaryMessages),
              let secondary = firstTimestamp(secondaryMessages) else { return nil }
        return Int(Int64(primary) - Int64(secondary))
    }

    /// 自动对齐的质量门槛：最优偏移下平均速度差超过该值（m/s）视为「不像同一场运动」。
    private static let alignMaxMeanSpeedDiff = 1.0

    /// 估算副文件相对主文件的时间偏移（秒，加到副时间戳后与主对齐）。
    static func estimateOffset(primary: Data, secondary: Data) throws -> Int {
        // 调用 decode + estimateOffset：解析后走已解码版本，供外部一次性调用。
        try estimateOffset(primaryMessages: decode(primary, name: "primary"),
                           secondaryMessages: decode(secondary, name: "secondary"))
    }

    /// 已解码版本：merge 内部复用已解析的消息，避免重复解码。
    /// 优先用速度互相关；主/副都缺少速度时退回累计距离匹配。
    /// 最优偏移下两边速度仍差很大时判定不是同一场运动，直接报错而不硬合。
    static func estimateOffset(primaryMessages: FitMessages, secondaryMessages: FitMessages) throws -> Int {
        let primarySpeeds = speedSeries(from: primaryMessages.recordMesgs)
        let secondarySpeeds = speedSeries(from: secondaryMessages.recordMesgs)
        if primarySpeeds.count >= 30, secondarySpeeds.count >= 30 {
            // 调用 bestSpeedOffset：用速度吻合度搜最佳偏移。
            if let (offset, meanDiff) = bestSpeedOffset(primary: primarySpeeds, secondary: secondarySpeeds) {
                guard meanDiff <= alignMaxMeanSpeedDiff else {
                    throw FitMergeError.alignFailed(String(
                        format: "自动对齐失败：最优偏移(%d 秒)下平均速度差仍达 %.2f m/s，两段可能不是同一场运动。请改用手动偏移或绝对时间。",
                        offset, meanDiff))
                }
                return offset
            }
            // 速度序列充足但连 80 对都配不上：可能重叠太短，也可能压根不是同一场。
            throw FitMergeError.alignFailed("自动对齐失败：两段在 ±2 小时内配对样本不足（重叠时间过短，或不是同一场运动）。请改用手动偏移或绝对时间。")
        }

        let primaryDist = distanceSeries(from: primaryMessages.recordMesgs)
        let secondaryDist = distanceSeries(from: secondaryMessages.recordMesgs)
        if primaryDist.count >= 30, secondaryDist.count >= 30 {
            // 调用 medianDistanceOffset：用累计距离最近点估时钟偏差。
            if let offset = medianDistanceOffset(primary: primaryDist, secondary: secondaryDist) {
                return offset
            }
        }

        throw FitMergeError.alignFailed("无法自动对齐：缺少足够的速度样本，且距离匹配不可靠（可能不是同一场运动）。请改用手动偏移或绝对时间。")
    }

    /// 合并入口：primary 为主数据源，others 依次补缺（排前的优先）。
    /// timeAlign 控制副文件时间戳如何映射到主时间轴。
    /// supplementMode：`.fillRecords` 可插整条；`.sensorsOnly` 只补传感器且起止跟主。
    static func merge(
        primary: Data,
        primaryName: String,
        others: [(data: Data, name: String)],
        timeAlign: FitMergeTimeAlign = .absolute,
        supplementMode: FitSupplementMode = .fillRecords
    ) throws -> Data {
        guard !others.isEmpty else { throw FitMergeError.needAtLeastTwoFiles }
        let sensorsOnly = supplementMode == .sensorsOnly

        // 调用 decode：解析主文件。
        let primaryMessages = try decode(primary, name: primaryName)
        // 调用 decode：逐个解析副文件。
        let otherMessages = try others.map { try decode($0.data, name: $0.name) }

        // 每个副文件的偏移（加到副时间戳）。
        var offsets: [Int] = []
        switch timeAlign {
        case .absolute:
            offsets = Array(repeating: 0, count: others.count)
        case .manual(let seconds):
            offsets = Array(repeating: seconds, count: others.count)
        case .automatic:
            for messages in otherMessages {
                // 调用 estimateOffset：为每个副文件估时钟偏差（复用已解码消息）。
                offsets.append(try estimateOffset(primaryMessages: primaryMessages, secondaryMessages: messages))
            }
        case .perFile(let list):
            guard list.count == others.count else {
                throw FitMergeError.alignFailed("内部错误：预计算偏移数量(\(list.count))与副文件数量(\(others.count))不一致")
            }
            offsets = list
        }

        // Record 按秒索引，主文件先占位。
        var recordsBySecond: [UInt32: RecordMesg] = [:]
        for record in primaryMessages.recordMesgs {
            guard let ts = record.getTimestamp() else { continue }
            recordsBySecond[ts.timestamp] = record
        }
        // 主文件记录的时间范围：范围内冲突以主为准，范围外「以各自为主」（仅 fillRecords）。
        let primaryTimestamps = recordsBySecond.keys
        let primaryRange: ClosedRange<UInt32>? = {
            guard let lo = primaryTimestamps.min(), let hi = primaryTimestamps.max() else { return nil }
            return lo...hi
        }()

        // 每个副文件对齐后的记录时间范围，用于判断该文件是否与主完全不重叠。
        var alignedRanges: [ClosedRange<UInt32>?] = []
        for (messages, offset) in zip(otherMessages, offsets) {
            var alignedMin: UInt32?
            var alignedMax: UInt32?
            for otherRecord in messages.recordMesgs {
                guard let ts = otherRecord.getTimestamp() else { continue }
                let aligned = Int64(ts.timestamp) + Int64(offset)
                guard aligned >= 0, aligned <= Int64(UInt32.max) else { continue }
                let key = UInt32(aligned)
                alignedMin = min(alignedMin ?? key, key)
                alignedMax = max(alignedMax ?? key, key)
                if let primaryRecord = recordsBySecond[key] {
                    if sensorsOnly {
                        // 调用 fillSensorFields：同秒只补心率/功率/踏频等，不碰 GPS/距离。
                        try fillSensorFields(into: primaryRecord, from: otherRecord)
                    } else {
                        // 调用 fillMissingFields：同一秒冲突，以主为准，仅补主缺的字段。
                        fillMissingFields(into: primaryRecord, from: otherRecord)
                    }
                } else if !sensorsOnly {
                    // 主没有该秒：整条补入（sensorsOnly 禁止，避免错位 GPS 拉飞距离）。
                    let copy = RecordMesg(mesg: otherRecord)
                    try copy.setTimestamp(DateTime(timestamp: key))
                    recordsBySecond[key] = copy
                }
            }
            if let alignedMin, let alignedMax {
                alignedRanges.append(alignedMin...alignedMax)
            } else {
                alignedRanges.append(nil)
            }
        }

        // 主时间范围之外的段落「以各自为主」：fillRecords 才带入；sensorsOnly 起止严格跟主。
        var extraEvents: [EventMesg] = []
        var extraLaps: [LapMesg] = []
        if !sensorsOnly {
            var seenEventKeys = Set<String>()
            var acceptedLapRanges: [ClosedRange<Int64>] = []
            for (messages, offset) in zip(otherMessages, offsets) {
                for event in messages.eventMesgs {
                    guard let ts = event.getTimestamp() else { continue }
                    let aligned = Int64(ts.timestamp) + Int64(offset)
                    guard aligned >= 0, aligned <= Int64(UInt32.max) else { continue }
                    let key = UInt32(aligned)
                    guard primaryRange == nil || !primaryRange!.contains(key) else { continue }
                    let dedupeKey = "\(key)-\(event.getEvent()?.rawValue ?? 255)-\(event.getEventType()?.rawValue ?? 255)"
                    guard seenEventKeys.insert(dedupeKey).inserted else { continue }
                    let copy = EventMesg(mesg: event)
                    try copy.setTimestamp(DateTime(timestamp: key))
                    extraEvents.append(copy)
                }
                for lap in messages.lapMesgs {
                    guard let end = lap.getTimestamp() else { continue }
                    let alignedEnd = Int64(end.timestamp) + Int64(offset)
                    guard alignedEnd >= 0, alignedEnd <= Int64(UInt32.max) else { continue }
                    let start = lap.getStartTime().map { Int64($0.timestamp) + Int64(offset) } ?? alignedEnd
                    let outside = primaryRange == nil
                        || alignedEnd < Int64(primaryRange!.lowerBound)
                        || start > Int64(primaryRange!.upperBound)
                    guard outside else { continue }
                    let lapRange = min(start, alignedEnd)...max(start, alignedEnd)
                    guard !acceptedLapRanges.contains(where: { $0.overlaps(lapRange) }) else { continue }
                    acceptedLapRanges.append(lapRange)
                    let copy = LapMesg(mesg: lap)
                    try copy.setTimestamp(DateTime(timestamp: UInt32(alignedEnd)))
                    if lap.getStartTime() != nil, start >= 0, start <= Int64(UInt32.max) {
                        try copy.setStartTime(DateTime(timestamp: UInt32(start)))
                    }
                    extraLaps.append(copy)
                }
            }
        }

        // Session：主文件的会话按字段补缺（用每个副文件的第一条会话）。
        let primarySession = primaryMessages.sessionMesgs.first
        let origDistance = primarySession?.getTotalDistance()
        let origCalories = primarySession?.getTotalCalories()
        let origTimerTime = primarySession?.getTotalTimerTime()
        let session: SessionMesg?
        if let primarySession {
            for messages in otherMessages {
                if let otherSession = messages.sessionMesgs.first {
                    if sensorsOnly {
                        // 调用 fillSessionSensorFields：只补平均/最大心率等，不动距离时长。
                        try fillSessionSensorFields(into: primarySession, from: otherSession)
                    } else {
                        fillMissingFields(into: primarySession, from: otherSession)
                    }
                }
            }
            session = primarySession
        } else {
            session = otherMessages.compactMap { $0.sessionMesgs.first }.first
        }

        // fillRecords：与主完全不重叠的副段可加距离/卡路里/计时；sensorsOnly 不加。
        if !sensorsOnly, let session, primarySession != nil, let primaryRange {
            var extraDistance = 0.0
            var extraCalories = 0
            var extraTimerTime = 0.0
            for (messages, alignedRange) in zip(otherMessages, alignedRanges) {
                guard let alignedRange, !alignedRange.overlaps(primaryRange),
                      let otherSession = messages.sessionMesgs.first else { continue }
                extraDistance += otherSession.getTotalDistance() ?? 0
                extraCalories += Int(otherSession.getTotalCalories() ?? 0)
                extraTimerTime += otherSession.getTotalTimerTime() ?? 0
            }
            if extraDistance > 0 {
                try session.setTotalDistance((origDistance ?? 0) + extraDistance)
            }
            if extraCalories > 0 {
                try session.setTotalCalories(UInt16(clamping: Int(origCalories ?? 0) + extraCalories))
            }
            if extraTimerTime > 0 {
                try session.setTotalTimerTime((origTimerTime ?? 0) + extraTimerTime)
            }
        }

        // fillRecords 才可能因插入副记录而需外扩 Session；sensorsOnly 起止严格跟主，不扩。
        if !sensorsOnly {
            let mergedTimestamps = recordsBySecond.keys
            if let minTs = mergedTimestamps.min(), let maxTs = mergedTimestamps.max() {
                if let session {
                    try extendTimeRange(startTime: session.getStartTime(), endTime: session.getTimestamp(),
                                        elapsed: session.getTotalElapsedTime(), minTs: minTs, maxTs: maxTs,
                                        setStart: session.setStartTime, setEnd: session.setTimestamp,
                                        setElapsed: session.setTotalElapsedTime)
                }
                if extraLaps.isEmpty, let lap = primaryMessages.lapMesgs.first {
                    try extendTimeRange(startTime: lap.getStartTime(), endTime: lap.getTimestamp(),
                                        elapsed: lap.getTotalElapsedTime(), minTs: minTs, maxTs: maxTs,
                                        setStart: lap.setStartTime, setEnd: lap.setTimestamp,
                                        setElapsed: lap.setTotalElapsedTime)
                }
            }
        }

        // 组装输出：FileId 必须有，缺失时现造一个。
        let fileId: FileIdMesg
        if let primaryFileId = primaryMessages.fileIdMesgs.first {
            fileId = primaryFileId
        } else {
            fileId = FileIdMesg()
            try fileId.setType(File.activity)
            try fileId.setManufacturer(Manufacturer.development)
            try fileId.setProduct(1)
            try fileId.setSerialNumber(UInt32.random(in: 1..<UInt32.max))
            try fileId.setTimeCreated(DateTime())
        }

        let encoder = FITSwiftSDK.Encoder()
        encoder.write(mesg: fileId)
        for deviceInfo in primaryMessages.deviceInfoMesgs {
            encoder.write(mesg: deviceInfo)
        }
        // 主事件与副文件补入的事件统一按时间序写出，避免副段在主段之前时时间戳乱序。
        for event in (primaryMessages.eventMesgs + extraEvents)
            .sorted(by: { ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0) }) {
            encoder.write(mesg: event)
        }
        let sortedRecords = recordsBySecond.sorted { $0.key < $1.key }.map(\.value)
        // 各文件的累计距离基线不同（各自从自己的起点累计），拼接后可能倒退。
        // 倒退时把后续记录整体平移衔接，保持累计距离单调（段间空档按位移 0 计）。
        // ponytail: 只修倒退跳变；副段基线偏大造成的“前跳”与真实录制空档无法区分，不处理。
        if !sensorsOnly {
            var distanceFloor: Double?
            var distanceShift = 0.0
            for record in sortedRecords {
                guard let raw = record.getDistance() else { continue }
                var adjusted = raw + distanceShift
                if let floor = distanceFloor, adjusted < floor {
                    distanceShift += floor - adjusted
                    adjusted = floor
                }
                if distanceShift != 0 {
                    try record.setDistance(adjusted)
                }
                distanceFloor = adjusted
            }
        }
        for record in sortedRecords {
            encoder.write(mesg: record)
        }
        // 透传主文件的 Length（游泳趟）与 HRV，避免合并后丢失；
        // 副文件独有的 Length/HRV 不合并：跨文件按趟/按心跳对齐语义不明确，宁缺勿错。
        for length in primaryMessages.lengthMesgs {
            encoder.write(mesg: length)
        }
        for hrv in primaryMessages.hrvMesgs {
            encoder.write(mesg: hrv)
        }
        // 主 Lap 与副文件补入的 Lap 统一按结束时间序写出，避免副段在主段之前时乱序。
        for lap in (primaryMessages.lapMesgs + extraLaps)
            .sorted(by: { ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0) }) {
            encoder.write(mesg: lap)
        }
        if let session {
            encoder.write(mesg: session)
        }
        if let activity = primaryMessages.activityMesgs.first {
            encoder.write(mesg: activity)
        }
        return encoder.close()
    }

    // MARK: - Align helpers

    private static func speedSeries(from records: [RecordMesg]) -> [UInt32: Double] {
        var map: [UInt32: Double] = [:]
        for record in records {
            guard let ts = record.getTimestamp()?.timestamp else { continue }
            guard let speed = record.getSpeed() ?? record.getEnhancedSpeed() else { continue }
            map[ts] = speed
        }
        return map
    }

    private static func distanceSeries(from records: [RecordMesg]) -> [(UInt32, Double)] {
        records.compactMap { record in
            guard let ts = record.getTimestamp()?.timestamp,
                  let dist = record.getDistance() else { return nil }
            return (ts, dist)
        }.sorted { $0.0 < $1.0 }
    }

    /// 在 ±2 小时内按 1 秒步进搜速度差最小的偏移；要求至少 80 对样本。
    /// 返回 (偏移, 该偏移下的平均速度差)，供上层做同场校验。
    private static func bestSpeedOffset(primary: [UInt32: Double], secondary: [UInt32: Double]) -> (offset: Int, meanDiff: Double)? {
        let range = -7200...7200
        var bestOffset: Int?
        var bestScore = Double.greatestFiniteMagnitude
        var bestPairs = 0
        for offset in range {
            var sum = 0.0
            var n = 0
            for (ts, spdA) in primary {
                // 偏移加在副时间戳上：副t + offset = 主t → 查副表用 主t - offset。
                let key = Int64(ts) - Int64(offset)
                guard key >= 0, let spdB = secondary[UInt32(key)] else { continue }
                sum += abs(spdA - spdB)
                n += 1
            }
            guard n >= 80 else { continue }
            let mean = sum / Double(n)
            // 优先更低平均速度差；接近时偏好更多配对。
            if mean < bestScore - 0.01 || (abs(mean - bestScore) <= 0.01 && n > bestPairs) {
                bestScore = mean
                bestOffset = offset
                bestPairs = n
            }
        }
        guard let bestOffset else { return nil }
        return (bestOffset, bestScore)
    }

    /// 对副文件每个距离点找主文件最近距离，取 (副t - 主t) 的中位数，再取负号？
    /// 偏移定义：加到副时间戳。若副时钟快 Δ，副t = 主t + Δ，应对齐则 offset = -Δ = 主t - 副t。
    private static func medianDistanceOffset(primary: [(UInt32, Double)], secondary: [(UInt32, Double)]) -> Int? {
        var deltas: [Int] = []
        var primaryIndex = 0
        for (secTs, secDist) in secondary {
            guard secDist > 50 else { continue }
            while primaryIndex + 1 < primary.count, primary[primaryIndex + 1].1 <= secDist {
                primaryIndex += 1
            }
            let candidates = [primaryIndex, min(primary.count - 1, primaryIndex + 1)]
            var bestDD = Double.greatestFiniteMagnitude
            var bestDelta = 0
            for idx in Set(candidates) {
                let dd = abs(primary[idx].1 - secDist)
                if dd < bestDD {
                    bestDD = dd
                    // offset 加到副：副对齐后 = 副 + offset = 主 → offset = 主 - 副
                    bestDelta = Int(Int64(primary[idx].0) - Int64(secTs))
                }
            }
            if bestDD < 12 {
                deltas.append(bestDelta)
            }
        }
        guard deltas.count >= 30 else { return nil }
        let sorted = deltas.sorted()
        let median = sorted[sorted.count / 2]
        // 质量门槛：同一场运动的偏移候选应向中位数集中（±30 秒内占六成以上）；
        // 两段不同轨迹的距离-时间曲线斜率不同，候选会大范围散开，此时拒绝而非硬给。
        let concentrated = deltas.filter { abs($0 - median) <= 30 }.count
        guard concentrated * 10 >= deltas.count * 6 else { return nil }
        return median
    }

    /// 把 source 中 target 缺失的字段补进 target（同字段冲突时保留 target）。
    /// SDK 未公开字段枚举接口，这里按 FIT 字段号全域扫描（0...254，255 为 invalid）。
    /// 用整字段对象拷贝而非按值拷贝，保留数组字段的全部分量；
    /// source 解码后随即丢弃，字段对象引用共享无副作用。
    /// ponytail: 开发者自定义字段（developer fields）不补缺——需级联透传
    /// DeveloperDataId + FieldDescription 消息才能被解码方识别，收益低；需要时再扩展。
    private static func fillMissingFields(into target: Mesg, from source: Mesg) {
        for fieldNum: UInt8 in 0...254 {
            guard !target.hasField(fieldNum: fieldNum),
                  let field = source.getField(fieldNum: fieldNum) else { continue }
            // 调用 setField：整字段挂到主记录上，补齐主缺失的数据列。
            target.setField(field: field)
        }
    }

    /// 同秒只补传感器：心率/功率/踏频/体温；不碰 GPS、距离、速度、海拔。
    private static func fillSensorFields(into target: RecordMesg, from source: RecordMesg) throws {
        if target.getHeartRate() == nil, let v = source.getHeartRate() {
            try target.setHeartRate(v)
        }
        if target.getCadence() == nil, let v = source.getCadence() {
            try target.setCadence(v)
        }
        if target.getPower() == nil, let v = source.getPower() {
            try target.setPower(v)
        }
        if target.getTemperature() == nil, let v = source.getTemperature() {
            try target.setTemperature(v)
        }
    }

    /// Session 只补平均/最大心率等传感器汇总，不动距离与时长（起止以主为准）。
    private static func fillSessionSensorFields(into target: SessionMesg, from source: SessionMesg) throws {
        if target.getAvgHeartRate() == nil, let v = source.getAvgHeartRate() {
            try target.setAvgHeartRate(v)
        }
        if target.getMaxHeartRate() == nil, let v = source.getMaxHeartRate() {
            try target.setMaxHeartRate(v)
        }
        if target.getAvgCadence() == nil, let v = source.getAvgCadence() {
            try target.setAvgCadence(v)
        }
        if target.getMaxCadence() == nil, let v = source.getMaxCadence() {
            try target.setMaxCadence(v)
        }
        if target.getAvgPower() == nil, let v = source.getAvgPower() {
            try target.setAvgPower(v)
        }
        if target.getMaxPower() == nil, let v = source.getMaxPower() {
            try target.setMaxPower(v)
        }
    }

    /// 若合并后的记录时间范围超出原起止，则外扩 startTime/timestamp，并把
    /// totalElapsedTime 至少扩到新跨度（原值更大时保留原值）。
    private static func extendTimeRange(
        startTime: DateTime?, endTime: DateTime?, elapsed: Float64?,
        minTs: UInt32, maxTs: UInt32,
        setStart: (DateTime) throws -> Void,
        setEnd: (DateTime) throws -> Void,
        setElapsed: (Float64) throws -> Void
    ) throws {
        let newStart = min(startTime?.timestamp ?? minTs, minTs)
        let newEnd = max(endTime?.timestamp ?? maxTs, maxTs)
        if startTime == nil || newStart < startTime!.timestamp {
            try setStart(DateTime(timestamp: newStart))
        }
        if endTime == nil || newEnd > endTime!.timestamp {
            try setEnd(DateTime(timestamp: newEnd))
        }
        let span = Float64(newEnd - newStart)
        if elapsed == nil || elapsed! < span {
            try setElapsed(span)
        }
    }
}

/// 自动同步上传前：检测并修复几秒内的离谱速度尖峰（几百/几千 km/h）。
/// 用邻点（或全场）均速改写速度，距离按均速推进；GPS 瞬移则坐标退回上一有效点。
enum FitSpeedSpikeFixer {
    /// 瞬时合理上限（与异常扫描共用 80 km/h）。
    static var maxReasonableSpeedMps: Double { StravaSpeedAnomaly.peakThresholdMps }
    /// 只处理短间隔跳变（秒）。
    private static let maxGapSeconds: Double = 8
    private static let semicirclesPerDegree = 2_147_483_648.0 / 180.0

    struct FixResult: Sendable {
        var data: Data
        var fixedCount: Int
    }

    /// 修复尖峰；无尖峰时原样返回 data（fixedCount=0）。
    static func fix(_ data: Data) throws -> FixResult {
        // 调用 FitMerger.decode：解析后就地改 Record。
        let messages = try FitMerger.decode(data)
        let fixed = try fixRecords(messages.recordMesgs)
        guard fixed > 0 else {
            return FixResult(data: data, fixedCount: 0)
        }
        return FixResult(data: try encode(messages), fixedCount: fixed)
    }

    /// 多趟扫描：后点尖峰修好后，前面依赖关系可能变化。
    private static func fixRecords(_ records: [RecordMesg]) throws -> Int {
        let sorted = records.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        guard sorted.count >= 2 else { return 0 }

        var total = 0
        for _ in 0..<5 {
            let activityAvg = activityAverageSpeedMps(sorted) ?? 5.0
            var pass = 0
            for i in 1..<sorted.count {
                let cur = sorted[i]
                let prev = sorted[i - 1]
                guard let t0 = prev.getTimestamp()?.timestamp,
                      let t1 = cur.getTimestamp()?.timestamp else { continue }
                let dt = Double(Int64(t1) - Int64(t0))
                guard dt > 0, dt <= maxGapSeconds else { continue }

                let implied = impliedSpeedMps(from: prev, to: cur, dt: dt)
                let fieldSpeed = cur.getSpeed() ?? cur.getEnhancedSpeed()
                let peak = max(implied ?? 0, fieldSpeed ?? 0)
                guard peak > maxReasonableSpeedMps else { continue }

                let avg = neighborAverageSpeedMps(sorted, around: i) ?? activityAvg
                // 调用 applyAverageFix：用均速抹掉瞬移/距离暴跳。
                try applyAverageFix(current: cur, previous: prev, dt: dt, averageSpeedMps: avg, implied: implied)
                pass += 1
            }
            total += pass
            if pass == 0 { break }
        }
        return total
    }

    private static func applyAverageFix(
        current: RecordMesg,
        previous: RecordMesg,
        dt: Double,
        averageSpeedMps: Double,
        implied: Double?
    ) throws {
        let avg = max(0, min(averageSpeedMps, maxReasonableSpeedMps))
        try current.setSpeed(avg)
        if current.getEnhancedSpeed() != nil {
            try current.setEnhancedSpeed(avg)
        }

        // GPS 瞬移：坐标退回上一点，避免平台按轨迹重算几千 km/h。
        if let implied, implied > maxReasonableSpeedMps,
           let plat = previous.getPositionLat(), let plon = previous.getPositionLong() {
            try current.setPositionLat(plat)
            try current.setPositionLong(plon)
        }

        if let prevDist = previous.getDistance() {
            try current.setDistance(prevDist + avg * dt)
        }
    }

    private static func impliedSpeedMps(from prev: RecordMesg, to cur: RecordMesg, dt: Double) -> Double? {
        if let la0 = prev.getPositionLat(), let lo0 = prev.getPositionLong(),
           let la1 = cur.getPositionLat(), let lo1 = cur.getPositionLong() {
            let meters = haversineMeters(
                lat1: degree(fromSemicircle: la0), lon1: degree(fromSemicircle: lo0),
                lat2: degree(fromSemicircle: la1), lon2: degree(fromSemicircle: lo1)
            )
            return meters / dt
        }
        if let d0 = prev.getDistance(), let d1 = cur.getDistance(), d1 >= d0 {
            return (d1 - d0) / dt
        }
        return nil
    }

    private static func neighborAverageSpeedMps(_ records: [RecordMesg], around index: Int) -> Double? {
        var sum = 0.0
        var n = 0
        let lo = max(0, index - 8)
        let hi = min(records.count - 1, index + 8)
        for j in lo...hi where j != index {
            guard let spd = records[j].getSpeed() ?? records[j].getEnhancedSpeed(),
                  spd <= maxReasonableSpeedMps else { continue }
            sum += spd
            n += 1
        }
        guard n > 0 else { return nil }
        return sum / Double(n)
    }

    private static func activityAverageSpeedMps(_ records: [RecordMesg]) -> Double? {
        var sum = 0.0
        var n = 0
        for record in records {
            guard let spd = record.getSpeed() ?? record.getEnhancedSpeed(),
                  spd > 0, spd <= maxReasonableSpeedMps else { continue }
            sum += spd
            n += 1
        }
        if n >= 5 { return sum / Double(n) }
        // 用首尾累计距离估均速。
        let withDist = records.compactMap { r -> (UInt32, Double)? in
            guard let t = r.getTimestamp()?.timestamp, let d = r.getDistance() else { return nil }
            return (t, d)
        }
        guard let first = withDist.first, let last = withDist.last, last.0 > first.0, last.1 >= first.1 else {
            return n > 0 ? sum / Double(n) : nil
        }
        return (last.1 - first.1) / Double(last.0 - first.0)
    }

    private static func degree(fromSemicircle value: Int32) -> Double {
        // semicirclesPerDegree = 2^31/180；度 = 半圆 / 该常数（勿再乘 180）。
        Double(value) / semicirclesPerDegree
    }

    private static func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    /// 把改过的 FitMessages 重新编码成 Activity FIT。
    fileprivate static func encode(_ messages: FitMessages) throws -> Data {
        try FitMessagesReencoder.encode(messages)
    }
}

/// FIT 消息重编码（尖峰修复 / GCJ 改写共用）。
enum FitMessagesReencoder {
    static func encode(_ messages: FitMessages) throws -> Data {
        let encoder = FITSwiftSDK.Encoder()
        let fileId: FileIdMesg
        if let primary = messages.fileIdMesgs.first {
            fileId = primary
        } else {
            fileId = FileIdMesg()
            try fileId.setType(File.activity)
            try fileId.setManufacturer(Manufacturer.development)
            try fileId.setProduct(1)
            try fileId.setSerialNumber(UInt32.random(in: 1..<UInt32.max))
            try fileId.setTimeCreated(DateTime())
        }
        encoder.write(mesg: fileId)
        for deviceInfo in messages.deviceInfoMesgs {
            encoder.write(mesg: deviceInfo)
        }
        for event in messages.eventMesgs.sorted(by: {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }) {
            encoder.write(mesg: event)
        }
        for record in messages.recordMesgs.sorted(by: {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }) {
            encoder.write(mesg: record)
        }
        for length in messages.lengthMesgs {
            encoder.write(mesg: length)
        }
        for hrv in messages.hrvMesgs {
            encoder.write(mesg: hrv)
        }
        for lap in messages.lapMesgs.sorted(by: {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }) {
            encoder.write(mesg: lap)
        }
        if let session = messages.sessionMesgs.first {
            encoder.write(mesg: session)
        }
        if let activity = messages.activityMesgs.first {
            encoder.write(mesg: activity)
        }
        return encoder.close()
    }
}

/// 粗检 FIT 内容质量（顽鹿多候选下载时择优）。
enum FitContentProbe {
    static func isValidFit(_ data: Data) -> Bool {
        guard data.count >= 14 else { return false }
        // 头 4 字节若是 `{`/`[`/`<` 多半是 JSON/HTML 错误页。
        if let first = data.first, [UInt8(ascii: "{"), UInt8(ascii: "["), UInt8(ascii: "<")].contains(first) {
            return false
        }
        let magic = data.subdata(in: 8..<12)
        return magic == Data([0x2E, 0x46, 0x49, 0x54]) // .FIT
    }

    static func gpsPointCount(_ data: Data) -> Int {
        guard let messages = try? FitMerger.decode(data) else { return 0 }
        return messages.recordMesgs.reduce(0) { count, record in
            (record.getPositionLat() != nil && record.getPositionLong() != nil) ? count + 1 : count
        }
    }

    static func heartRatePointCount(_ data: Data) -> Int {
        guard let messages = try? FitMerger.decode(data) else { return 0 }
        return messages.recordMesgs.reduce(0) { count, record in
            record.getHeartRate() != nil ? count + 1 : count
        }
    }

    /// GPS 权重大于心率：优先保住轨迹。
    static func qualityScore(_ data: Data) -> Int {
        gpsPointCount(data) * 10 + heartRatePointCount(data)
    }
}

/// 国内 GCJ-02 → WGS-84（二分反解，对齐 WanSync）。中国境外原样返回。
enum Gcj02ToWgs84 {
    private static let pi = 3.1415926535897932384626
    private static let a = 6_378_245.0
    private static let ee = 0.00669342162296594323
    private static let threshold = 1e-6

    static func convert(latitude: Double, longitude: Double) -> (Double, Double) {
        if isOutOfChina(latitude: latitude, longitude: longitude) {
            return (latitude, longitude)
        }
        var minLat = latitude - 0.5
        var maxLat = latitude + 0.5
        var minLon = longitude - 0.5
        var maxLon = longitude + 0.5
        var resultLat = latitude
        var resultLon = longitude
        for _ in 0..<30 {
            resultLat = (minLat + maxLat) / 2
            resultLon = (minLon + maxLon) / 2
            let (tLat, tLon) = wgs84ToGcj02(latitude: resultLat, longitude: resultLon)
            let dLat = tLat - latitude
            let dLon = tLon - longitude
            if abs(dLat) < threshold, abs(dLon) < threshold {
                return (resultLat, resultLon)
            }
            if dLat > 0 { maxLat = resultLat } else { minLat = resultLat }
            if dLon > 0 { maxLon = resultLon } else { minLon = resultLon }
        }
        return (resultLat, resultLon)
    }

    private static func isOutOfChina(latitude: Double, longitude: Double) -> Bool {
        longitude < 72.004 || longitude > 137.8347 || latitude < 0.8293 || latitude > 55.8271
    }

    private static func wgs84ToGcj02(latitude: Double, longitude: Double) -> (Double, Double) {
        if isOutOfChina(latitude: latitude, longitude: longitude) {
            return (latitude, longitude)
        }
        let (dLat, dLon) = delta(latitude: latitude, longitude: longitude)
        return (latitude + dLat, longitude + dLon)
    }

    private static func delta(latitude: Double, longitude: Double) -> (Double, Double) {
        var latTransform = transformLat(x: longitude - 105.0, y: latitude - 35.0)
        var lonTransform = transformLon(x: longitude - 105.0, y: latitude - 35.0)
        let radians = latitude / 180.0 * pi
        var magic = sin(radians)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        latTransform = (latTransform * 180.0) / (((a * (1 - ee)) / (magic * sqrtMagic)) * pi)
        lonTransform = (lonTransform * 180.0) / ((a / sqrtMagic) * cos(radians) * pi)
        return (latTransform, lonTransform)
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var result = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        result += (20.0 * sin(y * pi) + 40.0 * sin(y / 3.0 * pi)) * 2.0 / 3.0
        result += (160.0 * sin(y / 12.0 * pi) + 320.0 * sin(y * pi / 30.0)) * 2.0 / 3.0
        return result
    }

    private static func transformLon(x: Double, y: Double) -> Double {
        var result = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        result += (20.0 * sin(x * pi) + 40.0 * sin(x / 3.0 * pi)) * 2.0 / 3.0
        result += (150.0 * sin(x / 12.0 * pi) + 300.0 * sin(x / 30.0 * pi)) * 2.0 / 3.0
        return result
    }
}

/// 上传前把 FIT 经纬度从 GCJ-02 改写为 WGS-84（对齐 WanSync：Record + Lap + Session）。
enum FitGcjCoordinateRewriter {
    /// 每度对应的 FIT semicircle 数（2^31 / 180）。
    private static let semicirclesPerDegree = 2_147_483_648.0 / 180.0

    /// 改写成功坐标对数；无坐标或无需转换时原样返回。
    static func rewrite(_ data: Data) throws -> (data: Data, rewrittenCount: Int) {
        let messages = try FitMerger.decode(data)
        var count = 0
        for record in messages.recordMesgs {
            count += try rewritePair(
                getLat: record.getPositionLat, getLon: record.getPositionLong,
                setLat: record.setPositionLat, setLon: record.setPositionLong
            )
        }
        for lap in messages.lapMesgs {
            count += try rewritePair(
                getLat: lap.getStartPositionLat, getLon: lap.getStartPositionLong,
                setLat: lap.setStartPositionLat, setLon: lap.setStartPositionLong
            )
            count += try rewritePair(
                getLat: lap.getEndPositionLat, getLon: lap.getEndPositionLong,
                setLat: lap.setEndPositionLat, setLon: lap.setEndPositionLong
            )
        }
        for session in messages.sessionMesgs {
            count += try rewritePair(
                getLat: session.getStartPositionLat, getLon: session.getStartPositionLong,
                setLat: session.setStartPositionLat, setLon: session.setStartPositionLong
            )
            count += try rewritePair(
                getLat: session.getNecLat, getLon: session.getNecLong,
                setLat: session.setNecLat, setLon: session.setNecLong
            )
            count += try rewritePair(
                getLat: session.getSwcLat, getLon: session.getSwcLong,
                setLat: session.setSwcLat, setLon: session.setSwcLong
            )
            count += try rewritePair(
                getLat: session.getEndPositionLat, getLon: session.getEndPositionLong,
                setLat: session.setEndPositionLat, setLon: session.setEndPositionLong
            )
        }
        guard count > 0 else { return (data, 0) }
        return (try FitMessagesReencoder.encode(messages), count)
    }

    private static func rewritePair(
        getLat: () -> Int32?,
        getLon: () -> Int32?,
        setLat: (Int32) throws -> Void,
        setLon: (Int32) throws -> Void
    ) throws -> Int {
        guard let latSC = getLat(), let lonSC = getLon() else { return 0 }
        // 度 = semicircle / (2^31/180)；写成 *180/semicirclesPerDegree 会多乘 180，国内点被当成境外跳过。
        let lat = Double(latSC) / semicirclesPerDegree
        let lon = Double(lonSC) / semicirclesPerDegree
        guard lat >= -90, lat <= 90, lon >= -180, lon <= 180 else { return 0 }
        let (wgsLat, wgsLon) = Gcj02ToWgs84.convert(latitude: lat, longitude: lon)
        if abs(wgsLat - lat) < 1e-9, abs(wgsLon - lon) < 1e-9 { return 0 }
        guard wgsLat >= -90, wgsLat <= 90, wgsLon >= -180, wgsLon <= 180 else { return 0 }
        try setLat(Int32((wgsLat * semicirclesPerDegree).rounded()))
        try setLon(Int32((wgsLon * semicirclesPerDegree).rounded()))
        return 1
    }
}
