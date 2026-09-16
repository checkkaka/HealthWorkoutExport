import Foundation
import HealthKit

enum WriteToAppleHealthSetting {
    private static let key = "write_to_apple_health"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum AppleHealthNearbyDecision: Sendable {
    case write
    case writeRestOfBatch
    case skip
    case skipRestOfBatch
    /// 这次不写，但不记永久跳过（弹窗取消、找不到宿主）。
    case skipOnce
    /// 停掉本批健康写入，已处理的保持原样。
    case cancelBatch

    var shouldPersistSkip: Bool {
        switch self {
        case .skip, .skipRestOfBatch: return true
        case .write, .writeRestOfBatch, .skipOnce, .cancelBatch: return false
        }
    }
}

struct AppleHealthNearbyPrompt: Sendable {
    var activityTitle: String
    var nearbySummary: String
}

struct AppleHealthImportResult: Sendable {
    var written: Int
    var skipped: Int
    var failed: Int
    var notes: [String]
}

/// 将已生成的 FIT 写入苹果健康；普通同步和历史记录共用此流程。
@MainActor
final class AppleHealthImportPass {
    private let registry: DataSourceRegistry
    private let stateStore: SyncStateStore
    private let healthKit: HealthKitService

    init(
        registry: DataSourceRegistry? = nil,
        stateStore: SyncStateStore = .shared,
        healthKit: HealthKitService? = nil
    ) {
        let resolved = registry ?? .shared
        self.registry = resolved
        self.stateStore = stateStore
        self.healthKit = healthKit ?? resolved.healthKit.underlyingHealthKit
    }

    func run(
        job: SyncJobConfig,
        progressSeed: AutoSyncProgress,
        onProgress: @MainActor @escaping (AutoSyncProgress) -> Void,
        onNearby: @MainActor @escaping (AppleHealthNearbyPrompt) async -> AppleHealthNearbyDecision
    ) async throws -> AppleHealthImportResult {
        var result = AppleHealthImportResult(written: 0, skipped: 0, failed: 0, notes: [])
        guard job.primarySourceId != HealthKitDataSource.sourceId else { return result }
        guard let primary = registry.source(id: job.primarySourceId) else {
            result.notes.append("未知主数据源，未写入健康")
            return result
        }
        let supplements = job.supplementSourceIds
            .filter { $0 != job.primarySourceId }
            .compactMap { registry.source(id: $0) }
        let selectedIds = Set(job.selectedActivityIds.filter { !$0.isEmpty })
        guard let range = job.activityTimeRange() else {
            result.notes.append("已选活动缺少时间范围，未写入健康")
            return result
        }

        try await healthKit.requestAuthorization(writeWorkouts: true)
        var primaries = try await primary.listActivities(from: range.start, to: range.end)
        if !selectedIds.isEmpty {
            primaries = primaries.filter { selectedIds.contains($0.id) }
        }
        guard !primaries.isEmpty else { return result }

        var supplementLists: [String: [SourceActivity]] = [:]
        for source in supplements {
            supplementLists[source.id] = (try? await source.listActivities(from: range.start, to: range.end)) ?? []
        }

        var progress = progressSeed
        progress.total = primaries.count
        progress.processed = 0
        progress.message = "准备写入苹果健康…"
        onProgress(progress)

        var writeRest = false
        var skipRest = false
        let supplementIds = supplements.map(\.id)

        for activity in primaries {
            try Task.checkCancellation()
            let fingerprint = SyncFingerprint.make(
                primarySourceId: primary.id,
                primaryActivityId: activity.id,
                startDate: activity.startDate,
                supplementSourceIds: supplementIds
            )
            let record = await stateStore.record(for: fingerprint)
            if record?.appleHealthUUID != nil || record?.appleHealthSkipped == true {
                result.skipped += 1
                progress.processed += 1
                progress.message = "健康已处理，跳过：\(activity.title)"
                onProgress(progress)
                continue
            }

            do {
                let data = try await fitData(
                    for: activity,
                    fingerprint: fingerprint,
                    primary: primary,
                    supplements: supplements,
                    supplementLists: supplementLists
                )
                let step = try await importFIT(
                    data,
                    fingerprint: fingerprint,
                    activityTitle: activity.title,
                    writeRest: writeRest,
                    skipRest: skipRest,
                    onNearby: onNearby
                )
                writeRest = step.writeRest
                skipRest = step.skipRest
                switch step.outcome {
                case .written:
                    result.written += 1
                    progress.message = "已写入健康：\(activity.title)"
                case .skipped(let message):
                    result.skipped += 1
                    progress.message = message
                }
                progress.processed += 1
                onProgress(progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await stateStore.markAppleHealthFailed(
                    fingerprint: fingerprint,
                    message: error.localizedDescription
                )
                result.failed += 1
                result.notes.append("健康写入失败：\(activity.title)（\(error.localizedDescription)）")
                progress.processed += 1
                progress.message = "健康写入失败：\(activity.title)"
                onProgress(progress)
            }
        }
        return result
    }

    /// 历史勾选同步只读取本机保存的 FIT，绝不回源重新拉取。
    func run(
        fingerprints: [String],
        progressSeed: AutoSyncProgress,
        onProgress: @MainActor @escaping (AutoSyncProgress) -> Void,
        onNearby: @MainActor @escaping (AppleHealthNearbyPrompt) async -> AppleHealthNearbyDecision
    ) async throws -> AppleHealthImportResult {
        var result = AppleHealthImportResult(written: 0, skipped: 0, failed: 0, notes: [])
        try await healthKit.requestAuthorization(writeWorkouts: true)
        var progress = progressSeed
        progress.total = fingerprints.count
        progress.processed = 0
        progress.message = "准备从历史 FIT 写入苹果健康…"
        onProgress(progress)

        var writeRest = false
        var skipRest = false
        for fingerprint in fingerprints {
            try Task.checkCancellation()
            guard let record = await stateStore.record(for: fingerprint) else {
                result.failed += 1
                result.notes.append("找不到本地记录：\(fingerprint.prefix(8))")
                progress.processed += 1
                onProgress(progress)
                continue
            }
            let title = record.title ?? record.primaryActivityId
            guard let data = await stateStore.syncedFITData(fingerprint: fingerprint), !data.isEmpty else {
                result.failed += 1
                result.notes.append("本地没有已保存 FIT：\(title)")
                progress.processed += 1
                progress.message = "缺少本地 FIT：\(title)"
                onProgress(progress)
                continue
            }
            if record.appleHealthUUID != nil || record.appleHealthSkipped == true {
                result.skipped += 1
                progress.processed += 1
                progress.message = "健康已处理，跳过：\(title)"
                onProgress(progress)
                continue
            }

            do {
                let step = try await importFIT(
                    data,
                    fingerprint: fingerprint,
                    activityTitle: title,
                    writeRest: writeRest,
                    skipRest: skipRest,
                    onNearby: onNearby
                )
                writeRest = step.writeRest
                skipRest = step.skipRest
                switch step.outcome {
                case .written:
                    result.written += 1
                    progress.message = "已写入健康：\(title)"
                case .skipped(let message):
                    result.skipped += 1
                    progress.message = message
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await stateStore.markAppleHealthFailed(fingerprint: fingerprint, message: error.localizedDescription)
                result.failed += 1
                result.notes.append("健康写入失败：\(title)（\(error.localizedDescription)）")
                progress.message = "健康写入失败：\(title)"
            }
            progress.processed += 1
            onProgress(progress)
        }
        return result
    }

    private enum ImportOutcome {
        case written
        case skipped(String)
    }

    private func importFIT(
        _ data: Data,
        fingerprint: String,
        activityTitle: String,
        writeRest: Bool,
        skipRest: Bool,
        onNearby: @MainActor @escaping (AppleHealthNearbyPrompt) async -> AppleHealthNearbyDecision
    ) async throws -> (outcome: ImportOutcome, writeRest: Bool, skipRest: Bool) {
        let draft = try HealthWorkoutDraft.fromFIT(data, fingerprint: fingerprint)
        let reference = SourceActivity(
            id: fingerprint,
            sourceId: "local-fit",
            title: activityTitle,
            startDate: draft.start,
            endDate: draft.end,
            duration: draft.duration,
            distanceMeters: draft.distanceMeters
        )
        let windowStart = draft.start.addingTimeInterval(-ActivityMatcher.maxStartDelta)
        let windowEnd = draft.end.addingTimeInterval(ActivityMatcher.maxStartDelta)
        let nearby = try await healthKit.nearbyWorkouts(from: windowStart, to: windowEnd)
        if let ours = HealthProximity.alreadyImported(fingerprint: fingerprint, in: nearby) {
            await stateStore.markAppleHealthWritten(fingerprint: fingerprint, uuid: ours.uuid.uuidString)
            return (.skipped("健康已有本 App 记录：\(activityTitle)"), writeRest, skipRest)
        }
        let overlaps = HealthProximity.overlapping(reference, in: nearby)
            .filter { $0.syncIdentifier != fingerprint }
        var nextWriteRest = writeRest
        var nextSkipRest = skipRest
        var shouldWrite = overlaps.isEmpty || writeRest
        var persistSkip = false
        if !overlaps.isEmpty, !writeRest, !skipRest {
            let summary = overlaps.prefix(3).map {
                let source = $0.sourceName ?? "健康"
                let minutes = abs($0.startDate.timeIntervalSince(reference.startDate)) / 60
                return "\(source)（开始差 \(String(format: "%.1f", minutes)) 分钟）"
            }.joined(separator: "、")
            switch await onNearby(.init(
                activityTitle: activityTitle,
                nearbySummary: "健康里已有接近训练：\(summary)。写入会多一条记录，不能覆盖或删除 Apple Watch 的数据。"
            )) {
            case .write:
                shouldWrite = true
            case .writeRestOfBatch:
                nextWriteRest = true
                shouldWrite = true
            case .skip:
                shouldWrite = false
                persistSkip = true
            case .skipRestOfBatch:
                nextSkipRest = true
                shouldWrite = false
                persistSkip = true
            case .skipOnce:
                shouldWrite = false
            case .cancelBatch:
                throw CancellationError()
            }
            try Task.checkCancellation()
        } else if skipRest, !overlaps.isEmpty {
            shouldWrite = false
            persistSkip = true
        }
        guard shouldWrite else {
            if persistSkip {
                await stateStore.markAppleHealthSkipped(fingerprint: fingerprint)
            }
            return (.skipped(persistSkip ? "已跳过健康写入：\(activityTitle)" : "本次未写健康：\(activityTitle)"), nextWriteRest, nextSkipRest)
        }
        let uuid = try await healthKit.save(draft)
        await stateStore.markAppleHealthWritten(fingerprint: fingerprint, uuid: uuid.uuidString)
        return (.written, nextWriteRest, nextSkipRest)
    }

    private func fitData(
        for activity: SourceActivity,
        fingerprint: String,
        primary: any WorkoutDataSource,
        supplements: [any WorkoutDataSource],
        supplementLists: [String: [SourceActivity]]
    ) async throws -> Data {
        if let data = await stateStore.syncedFITData(fingerprint: fingerprint), !data.isEmpty {
            return data
        }
        if let url = await stateStore.syncedFITURL(
            primarySourceId: primary.id,
            primaryActivityId: activity.id
        ), let data = try? Data(contentsOf: url), !data.isEmpty {
            return data
        }
        let primaryFit = try await primary.fetchFitData(for: activity)
        var selected: [PreparedSupplement] = []
        for source in supplements {
            let ranked = ActivityMatcher.rankedCandidates(
                primary: activity,
                candidates: supplementLists[source.id] ?? []
            )
            guard let candidate = ranked.first(where: \.isEligible) else { continue }
            do {
                let data = try await source.fetchFitData(for: candidate.activity)
                selected.append(.init(
                    sourceId: source.id,
                    sourceName: source.displayName,
                    candidate: candidate,
                    data: data
                ))
            } catch {
                continue
            }
        }
        let prepared = try await PreparedFITBuilder.build(
            primaryData: primaryFit,
            primaryName: primary.displayName,
            supplements: selected,
            gcjEnabled: StravaSettings.gcjCorrectionEnabled
        )
        return prepared.data
    }
}

extension SyncJobConfig {
    /// 与 AutoSyncEngine.run 相同的时间窗；供健康第二段单独使用。
    func activityTimeRange() -> (start: Date, end: Date)? {
        let selectedIds = Set(selectedActivityIds.filter { !$0.isEmpty })
        if !selectedIds.isEmpty {
            guard let start = selectedStart, let end = selectedEnd else { return nil }
            return (start.addingTimeInterval(-3600), end.addingTimeInterval(3600))
        }
        switch mode {
        case .today:
            return SyncDayRange.today()
        case .history:
            return historyRange.resolve(customStart: customStart, customEnd: customEnd)
        }
    }
}
