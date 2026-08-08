import Foundation
import UIKit

struct AutoSyncProgress: Sendable {
    var total: Int
    var processed: Int
    var uploaded: Int
    var deduped: Int
    var failed: Int
    var skippedSupplementNotes: [String]
    var message: String

    static let zero = AutoSyncProgress(
        total: 0, processed: 0, uploaded: 0, deduped: 0, failed: 0,
        skippedSupplementNotes: [], message: ""
    )
}

struct AutoSyncResult: Sendable {
    var uploaded: Int
    var deduped: Int
    var failed: Int
    var notes: [String]
}

enum AutoSyncMode: String, CaseIterable, Identifiable {
    case today
    case history

    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "同步当天"
        case .history: return "同步历史"
        }
    }
}

struct StravaDuplicatePrompt: Sendable {
    var activityTitle: String
    var remoteId: String
    var reason: String
}

/// 自动同步引擎：主源列表 → 可选补源匹配合并 → 幂等上传 Strava。
@MainActor
final class AutoSyncEngine {
    private let registry: DataSourceRegistry
    private let stateStore: SyncStateStore
    private let apiUploader: StravaAPIUploader
    private let webUploader: StravaWebUploader
    private let recoveryStore: ResyncRecoveryStore
    /// 本批同步共用的天气缓存（按日+粗网格），避免同城多活动重复打 Open-Meteo。
    private var weatherCache: OpenMeteoWeatherCache?

    init(
        registry: DataSourceRegistry? = nil,
        stateStore: SyncStateStore = .shared,
        apiUploader: StravaAPIUploader? = nil,
        webUploader: StravaWebUploader? = nil,
        recoveryStore: ResyncRecoveryStore = ResyncRecoveryStore()
    ) {
        self.registry = registry ?? .shared
        self.stateStore = stateStore
        self.apiUploader = apiUploader ?? StravaAPIUploader()
        self.webUploader = webUploader ?? StravaWebUploader()
        self.recoveryStore = recoveryStore
    }

    private func uploader() -> any StravaUploading {
        StravaSettings.mode == .web ? webUploader : apiUploader
    }

    func run(
        primarySourceId: String,
        supplementSourceIds: [String],
        mode: AutoSyncMode,
        historyRange: SyncHistoryRange,
        customStart: Date,
        customEnd: Date,
        skipIfHistoryExists: Bool = false,
        onProgress: @MainActor @escaping (AutoSyncProgress) -> Void,
        onDuplicate: @MainActor @escaping (StravaDuplicatePrompt) async -> StravaDuplicateDecision
    ) async throws -> AutoSyncResult {
        guard let primary = registry.source(id: primarySourceId) else {
            throw WorkoutDataSourceError.fetchFailed("未知主数据源")
        }
        let supplements = supplementSourceIds
            .filter { $0 != primarySourceId }
            .compactMap { registry.source(id: $0) }

        let range: (start: Date, end: Date)
        switch mode {
        case .today:
            range = SyncDayRange.today()
        case .history:
            range = historyRange.resolve(customStart: customStart, customEnd: customEnd)
        }

        let uploader = uploader()
        guard await uploader.isReady() else { throw StravaUploadError.notConfigured }

        // 本批新建天气缓存；结束时清空引用，避免跨批次串数据。
        let batchWeatherCache = OpenMeteoWeatherCache()
        weatherCache = batchWeatherCache
        defer { weatherCache = nil }

        // 调用 listActivities：拉取主源时间窗内活动。
        let primaries = try await primary.listActivities(from: range.start, to: range.end)
        var progress = AutoSyncProgress.zero
        progress.total = primaries.count
        progress.message = "已拉取主源 \(primaries.count) 条"
        onProgress(progress)

        if primaries.isEmpty {
            let rangeLabel: String
            switch mode {
            case .today:
                rangeLabel = "当天"
            case .history:
                rangeLabel = "所选历史范围"
            }
            return AutoSyncResult(
                uploaded: 0,
                deduped: 0,
                failed: 0,
                notes: ["主源「\(primary.displayName)」在\(rangeLabel)内无活动，未上传任何内容"]
            )
        }

        // 批次预取 Strava 列表做区间预检：优先 API；网页模式用 Cookie 训练列表。
        var remoteActivities: [StravaActivityLookup.RemoteActivity] = []
        let pad = StravaActivityLookup.fetchPadding
        let remoteAfter = range.start.addingTimeInterval(-pad)
        let remoteBefore = range.end.addingTimeInterval(pad)
        if await apiUploader.isReady() {
            do {
                // 调用 apiUploader.fetchActivities：API 列表预检（网页上传模式也可复用）。
                remoteActivities = try await apiUploader.fetchActivities(after: remoteAfter, before: remoteBefore)
            } catch StravaUploadError.unauthorized {
                progress.skippedSupplementNotes.append("Strava API 预检未授权，将尝试网页列表")
            } catch {
                progress.skippedSupplementNotes.append("Strava API 预检失败：\(error.localizedDescription)")
            }
        }
        if remoteActivities.isEmpty, await webUploader.isReady() {
            do {
                // 调用 webUploader.fetchActivities：网页 Cookie 拉训练列表做预检。
                remoteActivities = try await webUploader.fetchActivities(after: remoteAfter, before: remoteBefore)
            } catch {
                progress.skippedSupplementNotes.append("Strava 网页预检失败：\(error.localizedDescription)")
            }
        }

        // 预取各补源列表，避免循环内重复请求。
        var supplementLists: [String: [SourceActivity]] = [:]
        for source in supplements {
            do {
                supplementLists[source.id] = try await source.listActivities(from: range.start, to: range.end)
            } catch {
                progress.skippedSupplementNotes.append("\(source.displayName) 列表失败：\(error.localizedDescription)")
                supplementLists[source.id] = []
            }
        }

        var notes: [String] = progress.skippedSupplementNotes
        var skipRestDuplicates = false
        var overwriteRestDuplicates = false
        let supplementIds = supplements.map(\.id)
        // 本批同步开始时间：写入每条记录，供同步记录页按批次归纳。
        let batchAt = Date()

        for activity in primaries {
            try Task.checkCancellation()
            // 预检覆盖删远端后继续上传时，须换 external_id，否则易撞已删幽灵。
            var useOverwriteExternalId = false
            let fingerprint = SyncFingerprint.make(
                primarySourceId: primary.id,
                primaryActivityId: activity.id,
                startDate: activity.startDate,
                supplementSourceIds: supplementIds
            )
            // 本地跳过一律受「自动跳过已有同步记录」开关控制；关掉则强制再走上传/远端预检。
            if skipIfHistoryExists, await stateStore.isUploaded(fingerprint) {
                // 调用 shouldSkipLocalHistory：异常最高速活动不因本地已同步而跳过。
                if await shouldSkipLocalHistory(
                    primarySourceId: primary.id,
                    primaryActivityId: activity.id,
                    fingerprint: fingerprint,
                    title: activity.title,
                    notes: &notes
                ) {
                    // 调用 markDeduped：同步记录打「去重」标。
                    await stateStore.markDeduped(fingerprint: fingerprint, reason: "本地已同步跳过")
                    progress.deduped += 1
                    progress.processed += 1
                    progress.message = "跳过已同步：\(activity.title)"
                    onProgress(progress)
                    continue
                }
            } else if skipIfHistoryExists,
                      await stateStore.hasUploadedHistory(primarySourceId: primary.id, primaryActivityId: activity.id) {
                // 跳过历史：同主活动任一 uploaded 即候选跳过；异常速度复查后才真正跳过。
                if await shouldSkipLocalHistory(
                    primarySourceId: primary.id,
                    primaryActivityId: activity.id,
                    fingerprint: fingerprint,
                    title: activity.title,
                    notes: &notes
                ) {
                    await stateStore.markPending(
                        fingerprint: fingerprint,
                        primarySourceId: primary.id,
                        primaryActivityId: activity.id,
                        title: activity.title,
                        startDate: activity.startDate,
                        supplementSourceIds: supplementIds,
                        distanceMeters: activity.distanceMeters,
                        durationSeconds: activity.duration,
                        batchAt: batchAt
                    )
                    await stateStore.markUploaded(
                        fingerprint: fingerprint,
                        remoteId: nil,
                        isDuplicate: true,
                        distanceMeters: activity.distanceMeters,
                        durationSeconds: activity.duration,
                        message: "同主活动历史已同步跳过",
                        uploadChannel: uploader.mode
                    )
                    progress.deduped += 1
                    progress.processed += 1
                    progress.message = "跳过历史记录：\(activity.title)"
                    onProgress(progress)
                    continue
                }
            } else if skipIfHistoryExists,
                      let meters = activity.distanceMeters, meters > 0,
                      let stable = await stateStore.uploadedStableMatch(
                        startDate: activity.startDate,
                        distanceMeters: meters,
                        durationSeconds: activity.duration
                      ) {
                // 跨主源稳定去重：开始+距离近似的已上传活动（换主源重跑）。
                notes.append("跳过稳定去重（同场已传）：\(activity.title)")
                progress.deduped += 1
                progress.processed += 1
                progress.message = "跳过稳定去重：\(activity.title)"
                // 调用 markUploaded：把当前指纹也记成已传并打去重标。
                await stateStore.markPending(
                    fingerprint: fingerprint,
                    primarySourceId: primary.id,
                    primaryActivityId: activity.id,
                    title: activity.title,
                    startDate: activity.startDate,
                    supplementSourceIds: supplementIds,
                    distanceMeters: meters,
                    durationSeconds: activity.duration,
                    batchAt: batchAt
                )
                await stateStore.markUploaded(
                    fingerprint: fingerprint,
                    remoteId: stable.remoteId,
                    isDuplicate: true,
                    distanceMeters: meters,
                    durationSeconds: activity.duration,
                    message: "稳定去重（同场已传）",
                    uploadChannel: uploader.mode
                )
                onProgress(progress)
                continue
            }

            do {
                await stateStore.markPending(
                    fingerprint: fingerprint,
                    primarySourceId: primary.id,
                    primaryActivityId: activity.id,
                    title: activity.title,
                    startDate: activity.startDate,
                    supplementSourceIds: supplementIds,
                    distanceMeters: activity.distanceMeters,
                    durationSeconds: activity.duration,
                    batchAt: batchAt
                )

                // 调用 match：上传前按时间区间/距离做 Strava 预检。
                if let existing = StravaActivityLookup.match(
                    startDate: activity.startDate,
                    endDate: activity.endDate,
                    distanceMeters: activity.distanceMeters,
                    in: remoteActivities
                ) {
                    // 本批刚上传、尚无远端 ID：开着本地跳过则静默去重；关掉则弹窗（无法覆盖）。
                    if existing.id.hasPrefix("local-") {
                        if skipIfHistoryExists {
                            await stateStore.markUploaded(
                                fingerprint: fingerprint,
                                remoteId: nil,
                                isDuplicate: true,
                                distanceMeters: activity.distanceMeters,
                                durationSeconds: activity.duration,
                                message: "本批近似活动去重",
                                uploadChannel: uploader.mode
                            )
                            notes.append("跳过本批已传近似活动：\(activity.title)")
                            progress.deduped += 1
                            progress.processed += 1
                            progress.message = "跳过本批近似：\(activity.title)"
                            onProgress(progress)
                            continue
                        }
                        let handled = try await handleDuplicate(
                            fingerprint: fingerprint,
                            title: activity.title,
                            remoteId: existing.id,
                            reason: "本批已传近似活动（尚无远端 ID，无法覆盖）",
                            skipRest: &skipRestDuplicates,
                            overwriteRest: &overwriteRestDuplicates,
                            fitData: nil,
                            filename: nil,
                            commute: false,
                            activityDescription: nil,
                            distanceMeters: activity.distanceMeters,
                            durationSeconds: activity.duration,
                            activityStart: activity.startDate,
                            activityEnd: activity.endDate,
                            uploader: uploader,
                            onDuplicate: onDuplicate,
                            progress: &progress,
                            notes: &notes,
                            remoteActivities: &remoteActivities
                        )
                        if handled {
                            progress.processed += 1
                            progress.message = "进度 \(progress.processed)/\(progress.total)"
                            onProgress(progress)
                            continue
                        }
                    }
                    let handled = try await handleDuplicate(
                        fingerprint: fingerprint,
                        title: activity.title,
                        remoteId: existing.id,
                        reason: "Strava 已有时间高度重合的活动",
                        skipRest: &skipRestDuplicates,
                        overwriteRest: &overwriteRestDuplicates,
                        fitData: nil,
                        filename: nil,
                        commute: false,
                        activityDescription: nil,
                        distanceMeters: activity.distanceMeters,
                        durationSeconds: activity.duration,
                        activityStart: activity.startDate,
                        activityEnd: activity.endDate,
                        uploader: uploader,
                        onDuplicate: onDuplicate,
                        progress: &progress,
                        notes: &notes,
                        remoteActivities: &remoteActivities
                    )
                    if handled {
                        progress.processed += 1
                        progress.message = "进度 \(progress.processed)/\(progress.total)"
                        onProgress(progress)
                        continue
                    }
                    useOverwriteExternalId = true
                }

                // 调用 fetchFitData：拉主源 FIT。
                let primaryFit = try await primary.fetchFitData(for: activity)
                var others: [(data: Data, name: String)] = []
                for source in supplements {
                    let candidates = supplementLists[source.id] ?? []
                    // 调用 ActivityMatcher：为该主活动匹配补源。
                    guard let match = ActivityMatcher.bestMatch(primary: activity, candidates: candidates) else {
                        continue
                    }
                    do {
                        let data = try await source.fetchFitData(for: match)
                        others.append((data, "\(source.id)-\(match.id).fit"))
                    } catch {
                        notes.append("补源 \(source.displayName) 拉取失败，已跳过：\(error.localizedDescription)")
                    }
                }

                let fitData: Data
                if others.isEmpty {
                    fitData = primaryFit
                } else {
                    do {
                        // 调用 FitMerger：主源基准、补源补缺。
                        fitData = try FitMerger.merge(
                            primary: primaryFit,
                            primaryName: "\(primary.id).fit",
                            others: others,
                            timeAlign: .automatic,
                            supplementMode: .sensorsOnly
                        )
                    } catch {
                        // 速度对齐失败：改按起点偏移，仍只补传感器、起止跟主源。
                        if let startAligned = try? mergeByStartOffset(
                            primaryFit: primaryFit,
                            primaryName: "\(primary.id).fit",
                            others: others
                        ) {
                            fitData = startAligned
                            notes.append("自动对齐失败，已按起点偏移补传感器：\(activity.title)")
                        } else {
                            fitData = primaryFit
                            notes.append("自动对齐失败，已跳过补源合并：\(activity.title)")
                        }
                    }
                }

                // 调用 FitSpeedSpikeFixer：抹掉几秒内几百/几千 km/h 尖峰后再上传。
                let spikeFixed = try FitSpeedSpikeFixer.fix(fitData)
                var uploadData = spikeFixed.data
                if spikeFixed.fixedCount > 0 {
                    notes.append("已修复 \(spikeFixed.fixedCount) 处速度尖峰：\(activity.title)")
                }
                // 上传成功可写入 sync_state.message，便于核对 GCJ 是否跑过。
                // 虚拟功率放在 GCJ 之后：用最终坐标估风向/方位，避免转换前方位偏差。
                var uploadMessage: String?
                if StravaSettings.gcjCorrectionEnabled {
                    // 调用 FitGcjCoordinateRewriter：可选 GCJ→WGS，修国内轨迹偏移。
                    let gcj = try FitGcjCoordinateRewriter.rewrite(uploadData)
                    uploadData = gcj.data
                    let gcjMsg = gcj.rewrittenCount > 0
                        ? "已转换 \(gcj.rewrittenCount) 个 GCJ 坐标点"
                        : "GCJ 开关已开但未转换任何坐标点"
                    notes.append("\(gcjMsg)：\(activity.title)")
                    uploadMessage = gcjMsg
                }
                // 调用 applyVirtualPowerIfNeeded：开启后估算并覆盖已有原生 power。
                let virtualPower = try await applyVirtualPowerIfNeeded(
                    uploadData,
                    activityTitle: activity.title,
                    notes: &notes
                )
                uploadData = virtualPower.data
                let activityDescription = virtualPower.activityDescription
                let gpsPoints = FitContentProbe.gpsPointCount(uploadData)
                let hrPoints = FitContentProbe.heartRatePointCount(uploadData)
                if gpsPoints < 5 {
                    notes.append("警告：轨迹点仅 \(gpsPoints) 个，Strava 易显示为直线：\(activity.title)")
                }
                if hrPoints == 0 {
                    notes.append("警告：无心率点：\(activity.title)")
                }

                let filename = "\(primary.id)-\(activity.id).fit"
                // 调用 CommuteClassifier：短距/低速短途标记为通勤（Strava API commute=1）。
                let commute = CommuteClassifier.isCommute(
                    distanceMeters: activity.distanceMeters,
                    durationSeconds: activity.duration
                )
                // 调用 uploader.uploadFit：上传到 Strava。
                let result = try await uploader.uploadFit(
                    uploadData,
                    externalId: useOverwriteExternalId ? overwriteExternalId(fingerprint) : fingerprint,
                    filename: filename,
                    commute: commute,
                    description: activityDescription
                )

                if result.isDuplicate {
                    _ = try await handleDuplicate(
                        fingerprint: fingerprint,
                        title: activity.title,
                        remoteId: result.remoteId ?? "unknown",
                        reason: "Strava 判定 duplicate",
                        skipRest: &skipRestDuplicates,
                        overwriteRest: &overwriteRestDuplicates,
                        fitData: uploadData,
                        filename: filename,
                        commute: commute,
                        activityDescription: activityDescription,
                        distanceMeters: activity.distanceMeters,
                        durationSeconds: activity.duration,
                        activityStart: activity.startDate,
                        activityEnd: activity.endDate,
                        uploader: uploader,
                        onDuplicate: onDuplicate,
                        progress: &progress,
                        notes: &notes,
                        remoteActivities: &remoteActivities
                    )
                } else {
                    await stateStore.markUploaded(
                        fingerprint: fingerprint,
                        remoteId: result.remoteId,
                        isDuplicate: false,
                        distanceMeters: activity.distanceMeters,
                        durationSeconds: activity.duration,
                        message: uploadMessage,
                        uploadChannel: uploader.mode
                    )
                    // 调用 rememberRemote：本批后续预检能立刻看到刚上传的活动。
                    rememberRemote(
                        &remoteActivities,
                        remoteId: result.remoteId,
                        fingerprint: fingerprint,
                        startDate: activity.startDate,
                        endDate: activity.endDate,
                        distanceMeters: activity.distanceMeters
                    )
                    progress.uploaded += 1
                }
            } catch {
                progress.failed += 1
                await stateStore.markFailed(fingerprint: fingerprint, message: error.localizedDescription)
                notes.append("失败 \(activity.title)：\(error.localizedDescription)")
            }

            progress.processed += 1
            progress.message = "进度 \(progress.processed)/\(progress.total)"
            onProgress(progress)
        }

        return AutoSyncResult(
            uploaded: progress.uploaded,
            deduped: progress.deduped,
            failed: progress.failed,
            notes: notes
        )
    }

    /// 本地已同步时是否仍应跳过：先查远端最高速，≥80 km/h 的异常活动不跳过（便于覆盖重传）。
    /// 无可用远端 ID / API 不可用 / 查不到详情时保持跳过。
    private func shouldSkipLocalHistory(
        primarySourceId: String,
        primaryActivityId: String,
        fingerprint: String,
        title: String,
        notes: inout [String]
    ) async -> Bool {
        var remoteIds = await stateStore.uploadedRemoteIds(
            primarySourceId: primarySourceId,
            primaryActivityId: primaryActivityId
        )
        if let one = await stateStore.uploadedRemoteId(for: fingerprint),
           !remoteIds.contains(one) {
            remoteIds.append(one)
        }
        guard !remoteIds.isEmpty else { return true }
        guard await apiUploader.isReady() else {
            notes.append("无法复查异常速度（需 API 授权），仍跳过：\(title)")
            return true
        }
        for remoteId in remoteIds {
            do {
                // 调用 fetchActivitySpeed：复查本地已同步活动是否最高速异常。
                guard let info = try await apiUploader.fetchActivitySpeed(id: remoteId) else {
                    continue
                }
                if info.isAnomalous {
                    let peakKmh = info.maxSpeedMps * 3.6
                    let avgKmh = info.averageSpeedMps * 3.6
                    let listedKmh = info.listedMaxSpeedMps * 3.6
                    notes.append(String(
                        format: "远端异常（峰值 %.0f / 均速 %.0f / 摘要最高速 %.0f km/h），不跳过以便覆盖：%@",
                        peakKmh, avgKmh, listedKmh, title
                    ))
                    return false
                }
            } catch {
                notes.append("复查速度失败，仍跳过 \(title)：\(error.localizedDescription)")
                return true
            }
        }
        return true
    }

    /// 速度互相关对齐失败时：用各文件 Session/首点起点差做 perFile 偏移合并。
    private func mergeByStartOffset(
        primaryFit: Data,
        primaryName: String,
        others: [(data: Data, name: String)]
    ) throws -> Data {
        let primaryMessages = try FitMerger.decode(primaryFit, name: primaryName)
        var offsets: [Int] = []
        for (data, name) in others {
            let secondary = try FitMerger.decode(data, name: name)
            guard let offset = FitMerger.estimateStartOffset(
                primaryMessages: primaryMessages,
                secondaryMessages: secondary
            ) else {
                throw FitMergeError.alignFailed("无法读取补源起点时间：\(name)")
            }
            offsets.append(offset)
        }
        // 调用 FitMerger.merge：按起点偏移只补传感器，起止跟主源。
        return try FitMerger.merge(
            primary: primaryFit,
            primaryName: primaryName,
            others: others,
            timeAlign: .perFile(offsets: offsets),
            supplementMode: .sensorsOnly
        )
    }

    /// 开关开启且参数合法时，对骑行 FIT 估算虚拟功率并覆盖已有原生 power。
    /// 返回值：写入后的数据，以及是否应附带虚拟功率社交描述。
    private func applyVirtualPowerIfNeeded(
        _ data: Data,
        activityTitle: String,
        notes: inout [String]
    ) async throws -> (data: Data, activityDescription: String?) {
        guard VirtualPowerSettings.enabled else { return (data, nil) }
        guard VirtualPowerSettings.isConfigured else {
            notes.append("虚拟功率已开但参数无效，已跳过：\(activityTitle)")
            return (data, nil)
        }
        // 调用 FitVirtualPowerFiller：Gribble + Open-Meteo，覆盖已有 power；失败秒标 failed。
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            data,
            settings: VirtualPowerSettings.physicsParams(),
            weatherCache: weatherCache
        )
        if result.filledCount > 0
            || result.failedCount > 0
            || result.activityRejected
            || result.note.contains("退化")
            || result.note.contains("未写入")
            || result.note.contains("跳过")
            || result.note.contains("放弃") {
            notes.append("\(result.note)：\(activityTitle)")
        }
        // 仅当编码结果里确有 powerSource=virtual 时才附社交描述（仅 filled/failed 不够）。
        guard !result.activityRejected, result.virtualMarkedCount > 0 else {
            return (result.data, nil)
        }
        guard let messages = try? FitMerger.decode(result.data),
              // 调用 containsVirtualMarkedRecord：按 developer 字段确认是虚拟功率。
              VirtualPowerSourceMark.containsVirtualMarkedRecord(in: messages) else {
            return (result.data, nil)
        }
        return (result.data, VirtualPowerSocialCopy.activityDescription)
    }

    /// 本批预检列表追加刚上传的活动，避免同批后条再传一遍。
    /// 网页上传 / API 后台补 ID 前常无 activity_id：用 fingerprint 占位，避免同秒开骑互相覆盖。
    private func rememberRemote(
        _ remoteActivities: inout [StravaActivityLookup.RemoteActivity],
        remoteId: String?,
        fingerprint: String,
        startDate: Date,
        endDate: Date,
        distanceMeters: Double? = nil
    ) {
        let id: String
        if let remoteId, StravaSpeedAnomaly.isOpenableRemoteId(remoteId) {
            id = remoteId
        } else {
            id = "local-\(fingerprint)"
        }
        remoteActivities.removeAll { $0.id == id }
        remoteActivities.append(.init(
            id: id,
            startDate: startDate,
            endDate: endDate,
            distanceMeters: distanceMeters
        ))
    }

    /// 覆盖/重传用唯一 external_id：删远端后 Strava 仍可能用原 external_id 判 duplicate（撞已删幽灵 ID）。
    private func overwriteExternalId(_ fingerprint: String) -> String {
        "\(fingerprint)-ow-\(Int(Date().timeIntervalSince1970))"
    }

    /// 处理预检命中或 duplicate：返回 true 表示本条已结束（跳过/打开），false 表示覆盖后已重传或调用方还需继续。
    private func handleDuplicate(
        fingerprint: String,
        title: String,
        remoteId: String,
        reason: String,
        skipRest: inout Bool,
        overwriteRest: inout Bool,
        fitData: Data?,
        filename: String?,
        commute: Bool,
        activityDescription: String?,
        distanceMeters: Double?,
        durationSeconds: TimeInterval?,
        activityStart: Date,
        activityEnd: Date,
        uploader: any StravaUploading,
        onDuplicate: @MainActor (StravaDuplicatePrompt) async -> StravaDuplicateDecision,
        progress: inout AutoSyncProgress,
        notes: inout [String],
        remoteActivities: inout [StravaActivityLookup.RemoteActivity]
    ) async throws -> Bool {
        // 幽灵 duplicate：文案指向已删活动（404）。有 FIT 则换 external_id 重传，避免弹「打开远端却没有」。
        if let fitData, let filename,
           StravaSpeedAnomaly.isOpenableRemoteId(remoteId),
           await apiUploader.isReady(),
           (try? await apiUploader.fetchActivitySpeed(id: remoteId)) == nil {
            let result = try await uploader.uploadFit(
                fitData,
                externalId: overwriteExternalId(fingerprint),
                filename: filename,
                commute: commute,
                description: activityDescription
            )
            if !result.isDuplicate {
                await stateStore.markUploaded(
                    fingerprint: fingerprint,
                    remoteId: result.remoteId,
                    isDuplicate: false,
                    distanceMeters: distanceMeters,
                    durationSeconds: durationSeconds,
                    uploadChannel: uploader.mode
                )
                rememberRemote(
                    &remoteActivities,
                    remoteId: result.remoteId,
                    fingerprint: fingerprint,
                    startDate: activityStart,
                    endDate: activityEnd,
                    distanceMeters: distanceMeters
                )
                progress.uploaded += 1
                notes.append("幽灵 duplicate（远端 \(remoteId) 已不存在），已换 ID 重传：\(title)")
                return true
            }
            remoteActivities.removeAll { $0.id == remoteId }
        }

        let decision: StravaDuplicateDecision
        if overwriteRest {
            decision = .overwrite
        } else if skipRest {
            decision = .skip
        } else {
            // 调用 onDuplicate：询问用户跳过 / 打开 / 覆盖（可记本批默认）。
            decision = await onDuplicate(
                StravaDuplicatePrompt(activityTitle: title, remoteId: remoteId, reason: reason)
            )
        }

        switch decision {
        case .skip, .skipRestOfBatch:
            if decision == .skipRestOfBatch { skipRest = true }
            await stateStore.markUploaded(
                fingerprint: fingerprint,
                remoteId: remoteId == "unknown" || remoteId.hasPrefix("local-") ? nil : remoteId,
                isDuplicate: true,
                distanceMeters: distanceMeters,
                durationSeconds: durationSeconds,
                message: reason,
                uploadChannel: uploader.mode
            )
            progress.deduped += 1
            progress.message = "去重跳过：\(title)"
            return true

        case .openRemote:
            if remoteId != "unknown",
               !remoteId.hasPrefix("local-"),
               let url = URL(string: "https://www.strava.com/activities/\(remoteId)") {
                await UIApplication.shared.open(url)
            }
            await stateStore.markFailed(fingerprint: fingerprint, message: "已打开远端活动，请手动处理后重试")
            progress.failed += 1
            notes.append("已打开远端 \(remoteId)：\(title)")
            return true

        case .overwrite, .overwriteRestOfBatch:
            if decision == .overwriteRestOfBatch { overwriteRest = true }
            guard remoteId != "unknown", !remoteId.hasPrefix("local-") else {
                throw StravaUploadError.uploadFailed("无法覆盖：缺少远端活动 ID")
            }
            guard await webUploader.isReady() else {
                throw StravaUploadError.uploadFailed("覆盖需要网页 Cookie：请先在 Strava 设置里完成网页登录（上传模式可仍用 API）")
            }
            // 调用 deleteActivity：仅覆盖路径用网页 Cookie 删远端。
            try await webUploader.deleteActivity(id: remoteId)
            // 已删除的条目要从预检列表移除，避免后续活动再次匹配到它。
            remoteActivities.removeAll { $0.id == remoteId }
            guard let fitData, let filename else {
                // 预检命中时尚无 FIT：返回 false 让上层继续拉 FIT 并上传。
                notes.append("已删除远端 \(remoteId)，继续上传：\(title)")
                return false
            }
            // 调用 uploadFit：按当前模式重传（换 external_id，避免撞已删幽灵）。
            let result = try await uploader.uploadFit(
                fitData,
                externalId: overwriteExternalId(fingerprint),
                filename: filename,
                commute: commute,
                description: activityDescription
            )
            if result.isDuplicate {
                let hit = result.remoteId.map { "（撞上远端 \($0)）" } ?? ""
                await stateStore.markUploaded(
                    fingerprint: fingerprint,
                    remoteId: result.remoteId,
                    isDuplicate: true,
                    distanceMeters: distanceMeters,
                    durationSeconds: durationSeconds,
                    message: "覆盖后仍 duplicate\(hit)",
                    uploadChannel: uploader.mode
                )
                progress.deduped += 1
                notes.append("覆盖后仍 duplicate\(hit)：\(title)")
            } else {
                await stateStore.markUploaded(
                    fingerprint: fingerprint,
                    remoteId: result.remoteId,
                    isDuplicate: false,
                    distanceMeters: distanceMeters,
                    durationSeconds: durationSeconds,
                    uploadChannel: uploader.mode
                )
                // 调用 rememberRemote：覆盖重传后写入本批预检列表。
                rememberRemote(
                    &remoteActivities,
                    remoteId: result.remoteId,
                    fingerprint: fingerprint,
                    startDate: activityStart,
                    endDate: activityEnd,
                    distanceMeters: distanceMeters
                )
                progress.uploaded += 1
            }
            return true
        }
    }

    /// 勾选重传：删除前保存最终 FIT；失败时下次优先恢复；默认覆盖不弹窗，通道跟当前设置。
    func resyncFingerprints(
        _ fingerprints: [String],
        onProgress: @MainActor @escaping (AutoSyncProgress) -> Void
    ) async throws -> AutoSyncResult {
        let uploader = uploader()
        guard await uploader.isReady() else { throw StravaUploadError.notConfigured }

        // 重传批次同样共用天气缓存。
        let batchWeatherCache = OpenMeteoWeatherCache()
        weatherCache = batchWeatherCache
        defer { weatherCache = nil }

        var progress = AutoSyncProgress.zero
        progress.total = fingerprints.count
        progress.message = "准备重传 \(fingerprints.count) 条"
        onProgress(progress)

        var notes: [String] = []
        let batchAt = Date()
        var remoteActivities: [StravaActivityLookup.RemoteActivity] = []
        var skipRestDuplicates = false
        var overwriteRestDuplicates = true

        for fingerprint in fingerprints {
            try Task.checkCancellation()
            guard let record = await stateStore.record(for: fingerprint) else {
                progress.failed += 1
                progress.processed += 1
                notes.append("找不到本地记录：\(fingerprint.prefix(8))")
                onProgress(progress)
                continue
            }
            guard let primary = registry.source(id: record.primarySourceId) else {
                progress.failed += 1
                progress.processed += 1
                await stateStore.markFailed(fingerprint: fingerprint, message: "未知主数据源")
                notes.append("未知主源：\(record.title ?? record.primaryActivityId)")
                onProgress(progress)
                continue
            }

            let title = record.title ?? record.primaryActivityId
            progress.message = "重传：\(title)"
            onProgress(progress)

            do {
                let remoteIdToReplace = record.remoteId.flatMap {
                    StravaSpeedAnomaly.isOpenableRemoteId($0) ? $0 : nil
                }
                if remoteIdToReplace != nil, !(await webUploader.isReady()) {
                    throw StravaUploadError.uploadFailed("覆盖需要网页 Cookie：请先完成网页登录")
                }

                let recoveredUpload: PendingResyncUpload?
                do {
                    recoveredUpload = try recoveryStore.load(fingerprint: fingerprint)
                } catch {
                    recoveryStore.remove(fingerprint: fingerprint)
                    recoveredUpload = nil
                    notes.append("恢复文件损坏，已重新生成：\(title)")
                }

                let prepared: PendingResyncUpload
                if let recoveredUpload {
                    prepared = recoveredUpload
                    notes.append("使用上次保留的重传文件：\(title)")
                } else {
                    let anchor = record.startDate ?? Date()
                    let windowStart = anchor.addingTimeInterval(-36 * 3600)
                    let windowEnd = anchor.addingTimeInterval(36 * 3600)
                    // 调用 listActivities：在时间窗内找回源活动。
                    let listed = try await primary.listActivities(from: windowStart, to: windowEnd)
                    guard let activity = listed.first(where: { $0.id == record.primaryActivityId }) else {
                        throw WorkoutDataSourceError.fetchFailed("源站找不到活动 \(record.primaryActivityId)")
                    }

                    let supplementIds = record.supplementSourceIds ?? []
                    let supplements = supplementIds
                        .filter { $0 != primary.id }
                        .compactMap { registry.source(id: $0) }
                    var supplementLists: [String: [SourceActivity]] = [:]
                    for source in supplements {
                        // 调用 listActivities：预取补源同窗活动。
                        supplementLists[source.id] = (try? await source.listActivities(from: windowStart, to: windowEnd)) ?? []
                    }

                    // 调用 fetchFitData：拉主源 FIT。
                    let primaryFit = try await primary.fetchFitData(for: activity)
                    var others: [(data: Data, name: String)] = []
                    for source in supplements {
                        let candidates = supplementLists[source.id] ?? []
                        guard let match = ActivityMatcher.bestMatch(primary: activity, candidates: candidates) else {
                            continue
                        }
                        do {
                            let data = try await source.fetchFitData(for: match)
                            others.append((data, "\(source.id)-\(match.id).fit"))
                        } catch {
                            notes.append("补源 \(source.displayName) 拉取失败，已跳过：\(error.localizedDescription)")
                        }
                    }

                    let fitData: Data
                    if others.isEmpty {
                        fitData = primaryFit
                    } else if let merged = try? FitMerger.merge(
                        primary: primaryFit,
                        primaryName: "\(primary.id).fit",
                        others: others,
                        timeAlign: .automatic,
                        supplementMode: .sensorsOnly
                    ) {
                        fitData = merged
                    } else if let startAligned = try? mergeByStartOffset(
                        primaryFit: primaryFit,
                        primaryName: "\(primary.id).fit",
                        others: others
                    ) {
                        fitData = startAligned
                    } else {
                        fitData = primaryFit
                    }

                    let spikeFixed = try FitSpeedSpikeFixer.fix(fitData)
                    var uploadData = spikeFixed.data
                    // 重传路径同样：尖峰 → GCJ → 虚拟功率（最终坐标再估风）。
                    var uploadMessage: String?
                    if StravaSettings.gcjCorrectionEnabled {
                        // 调用 FitGcjCoordinateRewriter：可选 GCJ→WGS，修国内轨迹偏移。
                        let gcj = try FitGcjCoordinateRewriter.rewrite(uploadData)
                        uploadData = gcj.data
                        uploadMessage = gcj.rewrittenCount > 0
                            ? "已转换 \(gcj.rewrittenCount) 个 GCJ 坐标点"
                            : "GCJ 开关已开但未转换任何坐标点"
                    }
                    // 调用 applyVirtualPowerIfNeeded：重传路径同样估算并覆盖已有功率。
                    let virtualPower = try await applyVirtualPowerIfNeeded(
                        uploadData,
                        activityTitle: activity.title,
                        notes: &notes
                    )
                    uploadData = virtualPower.data

                    prepared = PendingResyncUpload(
                        primarySourceId: primary.id,
                        primaryActivityId: activity.id,
                        title: activity.title,
                        startDate: activity.startDate,
                        endDate: activity.endDate,
                        supplementSourceIds: supplementIds,
                        distanceMeters: activity.distanceMeters,
                        durationSeconds: activity.duration,
                        uploadData: uploadData,
                        uploadMessage: uploadMessage,
                        filename: "\(primary.id)-\(activity.id).fit",
                        commute: CommuteClassifier.isCommute(
                            distanceMeters: activity.distanceMeters,
                            durationSeconds: activity.duration
                        ),
                        activityDescription: virtualPower.activityDescription
                    )
                }

                // 上传前统一原子保存最终字节：覆盖任一路径删远端后失败，都能再次勾选恢复。
                try recoveryStore.save(prepared, fingerprint: fingerprint)
                // 替换文件准备完成后才删除远端；准备失败时保留原活动和远端 ID。
                if let remoteIdToReplace {
                    // 调用 deleteActivity：勾选重传默认覆盖远端。
                    try await webUploader.deleteActivity(id: remoteIdToReplace)
                    remoteActivities.removeAll { $0.id == remoteIdToReplace }
                    notes.append("已删除远端 \(remoteIdToReplace)：\(title)")
                }
                // 远端删除成功（或无需删除）后再重置本地幂等行。
                await stateStore.markPending(
                    fingerprint: fingerprint,
                    primarySourceId: prepared.primarySourceId,
                    primaryActivityId: prepared.primaryActivityId,
                    title: prepared.title,
                    startDate: prepared.startDate,
                    supplementSourceIds: prepared.supplementSourceIds,
                    distanceMeters: prepared.distanceMeters,
                    durationSeconds: prepared.durationSeconds,
                    batchAt: batchAt
                )
                // 调用 uploadFit：按当前设置通道上传（重传一律换 external_id）。
                let result = try await uploader.uploadFit(
                    prepared.uploadData,
                    externalId: overwriteExternalId(fingerprint),
                    filename: prepared.filename,
                    commute: prepared.commute,
                    description: prepared.activityDescription
                )

                if result.isDuplicate {
                    _ = try await handleDuplicate(
                        fingerprint: fingerprint,
                        title: prepared.title,
                        remoteId: result.remoteId ?? "unknown",
                        reason: "Strava 判定 duplicate",
                        skipRest: &skipRestDuplicates,
                        overwriteRest: &overwriteRestDuplicates,
                        fitData: prepared.uploadData,
                        filename: prepared.filename,
                        commute: prepared.commute,
                        activityDescription: prepared.activityDescription,
                        distanceMeters: prepared.distanceMeters,
                        durationSeconds: prepared.durationSeconds,
                        activityStart: prepared.startDate,
                        activityEnd: prepared.endDate,
                        uploader: uploader,
                        onDuplicate: { _ in .overwriteRestOfBatch },
                        progress: &progress,
                        notes: &notes,
                        remoteActivities: &remoteActivities
                    )
                } else {
                    await stateStore.markUploaded(
                        fingerprint: fingerprint,
                        remoteId: result.remoteId,
                        isDuplicate: false,
                        distanceMeters: prepared.distanceMeters,
                        durationSeconds: prepared.durationSeconds,
                        message: prepared.uploadMessage,
                        uploadChannel: uploader.mode
                    )
                    rememberRemote(
                        &remoteActivities,
                        remoteId: result.remoteId,
                        fingerprint: fingerprint,
                        startDate: prepared.startDate,
                        endDate: prepared.endDate,
                        distanceMeters: prepared.distanceMeters
                    )
                    progress.uploaded += 1
                }
                // 成功或已完成 duplicate 处理后，恢复文件不再需要。
                recoveryStore.remove(fingerprint: fingerprint)
            } catch {
                progress.failed += 1
                let retained = (try? recoveryStore.load(fingerprint: fingerprint)) != nil
                let message = retained
                    ? "\(error.localizedDescription)；已保留重传文件，可再次勾选重试"
                    : error.localizedDescription
                await stateStore.markFailed(fingerprint: fingerprint, message: message)
                notes.append("失败 \(title)：\(message)")
            }

            progress.processed += 1
            progress.message = "进度 \(progress.processed)/\(progress.total)"
            onProgress(progress)
        }

        return AutoSyncResult(
            uploaded: progress.uploaded,
            deduped: progress.deduped,
            failed: progress.failed,
            notes: notes
        )
    }
}
