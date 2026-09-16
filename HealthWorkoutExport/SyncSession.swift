import Foundation
import Observation
import UIKit

enum SyncPreviewPolicy: String, CaseIterable, Identifiable, Sendable {
    case issuesOnly
    case everyActivity

    var id: String { rawValue }
    var title: String { self == .issuesOnly ? "仅异常确认" : "每条确认" }

    static var saved: Self {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "sync_preview_policy"),
                  let value = Self(rawValue: raw) else { return .issuesOnly }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sync_preview_policy") }
    }
}

struct SupplementCandidateGroup: Identifiable, Sendable {
    var sourceId: String
    var sourceName: String
    var candidates: [ActivityMatchCandidate]
    var selectedActivityId: String?
    var id: String { sourceId }
}

struct SyncPreviewPrompt: Identifiable, Sendable {
    var id = UUID()
    var activity: SourceActivity
    var preparedFIT: PreparedFIT
    var candidateGroups: [SupplementCandidateGroup]
}

enum SyncPreviewDecision: Sendable {
    case upload
    case forceUpload
    case skip
    case stopBatch
    /// sourceId → activityId；空字符串表示当前活动不使用该补源。
    case rebuild([String: String])
}

/// 一次自动同步的可恢复配置（中断后「继续」或「整批重试」复用原数据源与范围）。
struct SyncJobConfig: Equatable, Sendable {
    var primarySourceId: String
    var supplementSourceIds: [String]
    var mode: AutoSyncMode
    var historyRange: SyncHistoryRange
    var customStart: Date
    var customEnd: Date
    /// 本地已有该主活动 uploaded 记录则跳过（忽略补源差异）。
    var skipIfHistoryExists: Bool
    /// 列表已选活动 ID；非空时只同步这些，不再按当天/历史范围。
    var selectedActivityIds: [String] = []
    var selectedStart: Date? = nil
    var selectedEnd: Date? = nil
    /// 本批自定义 Strava 标题；空则通勤用「通勤🚲」，其它用源标题。
    var customTitle: String? = nil
    var previewPolicy: SyncPreviewPolicy = .saved
    /// 是否上传 Strava；默认开，保持现有同步行为。
    var uploadToStrava: Bool = true
    /// 是否写入苹果健康；可与 Strava 同时执行或单独执行。
    var writeToAppleHealth: Bool = false
}

/// App 级同步会话：进度跨页面可见，支持取消、继续与整批重试。
@MainActor
@Observable
final class SyncSession {
    static let shared = SyncSession()

    private(set) var isRunning = false
    private(set) var wasInterrupted = false
    private(set) var progress = AutoSyncProgress.zero
    private(set) var lastResultText: String?
    private(set) var lastError: String?
    private(set) var lastJob: SyncJobConfig?

    /// 供界面展示；真正决策走 UIKit 置顶弹窗，避免 sheet 挡住。
    var duplicatePrompt: StravaDuplicatePrompt?
    private var duplicateContinuation: CheckedContinuation<StravaDuplicateDecision, Never>?
    var healthNearbyPrompt: AppleHealthNearbyPrompt?
    private var healthNearbyContinuation: CheckedContinuation<AppleHealthNearbyDecision, Never>?
    var previewPrompt: SyncPreviewPrompt?
    private var previewContinuation: CheckedContinuation<SyncPreviewDecision, Never>?
    private weak var duplicateAlert: UIAlertController?
    private weak var healthNearbyAlert: UIAlertController?
    private var runningTask: Task<Void, Never>?
    private let engine = AutoSyncEngine()

    private init() {}

    func start(_ job: SyncJobConfig) {
        guard !isRunning, job.uploadToStrava || job.writeToAppleHealth else { return }
        lastJob = job
        wasInterrupted = false
        lastError = nil
        lastResultText = nil
        progress = .zero
        isRunning = true

        runningTask = Task { @MainActor in
            defer {
                self.isRunning = false
                self.runningTask = nil
            }
            do {
                var text = ""
                if job.uploadToStrava {
                    // 调用 AutoSyncEngine.run：按任务配置上传 Strava。
                    let result = try await engine.run(
                        primarySourceId: job.primarySourceId,
                        supplementSourceIds: job.supplementSourceIds,
                        mode: job.mode,
                        historyRange: job.historyRange,
                        customStart: job.customStart,
                        customEnd: job.customEnd,
                        skipIfHistoryExists: job.skipIfHistoryExists,
                        selectedActivityIds: job.selectedActivityIds,
                        selectedStart: job.selectedStart,
                        selectedEnd: job.selectedEnd,
                        customTitle: job.customTitle,
                        previewPolicy: job.previewPolicy,
                        onProgress: { [weak self] p in
                            self?.progress = p
                        },
                        onDuplicate: { [weak self] prompt in
                            guard let self else { return .skip }
                            return await self.awaitDuplicateDecision(prompt)
                        },
                        onPreview: { [weak self] prompt in
                            guard let self else { return .skip }
                            return await self.awaitPreviewDecision(prompt)
                        }
                    )
                    try Task.checkCancellation()
                    text = "Strava：上传 \(result.uploaded)，去重 \(result.deduped)，失败 \(result.failed)。"
                    if !result.notes.isEmpty {
                        text += "\n" + result.notes.prefix(8).joined(separator: "\n")
                    }
                }
                if job.writeToAppleHealth, job.primarySourceId != HealthKitDataSource.sourceId {
                    do {
                        let health = try await AppleHealthImportPass().run(
                            job: job,
                            progressSeed: self.progress,
                            onProgress: { [weak self] p in
                                self?.progress = p
                            },
                            onNearby: { [weak self] prompt in
                                guard let self else { return .skipOnce }
                                return await self.awaitHealthNearbyDecision(prompt)
                            }
                        )
                        if !text.isEmpty { text += "\n" }
                        text += "健康：写入 \(health.written)，跳过 \(health.skipped)，失败 \(health.failed)。"
                        if !health.notes.isEmpty {
                            text += "\n" + health.notes.prefix(8).joined(separator: "\n")
                        }
                    } catch is CancellationError {
                        self.lastResultText = text
                        self.wasInterrupted = true
                        self.lastError = job.uploadToStrava
                            ? "健康写入已取消，Strava 已完成。可再开同步补写健康。"
                            : "健康写入已取消。"
                        self.resolveHealthNearby(.cancelBatch)
                        return
                    } catch {
                        text += "\n健康写入出错：\(error.localizedDescription)"
                        self.lastResultText = text
                        self.wasInterrupted = false
                        return
                    }
                }
                self.lastResultText = text
                self.wasInterrupted = false
            } catch is CancellationError {
                self.wasInterrupted = true
                self.lastError = "同步已取消，可点「继续上次同步」接着跑（已上传的会跳过）"
                self.resolveDuplicate(.skip)
                self.resolvePreview(.stopBatch)
                self.resolveHealthNearby(.cancelBatch)
            } catch {
                self.wasInterrupted = true
                self.lastError = error.localizedDescription
                self.resolveDuplicate(.skip)
                self.resolvePreview(.stopBatch)
                self.resolveHealthNearby(.cancelBatch)
            }
        }
    }

    /// 勾选重传：默认覆盖不弹窗；与普通自动同步互斥。
    func startResync(
        fingerprints: [String],
        customTitle: String? = nil,
        uploadToStrava: Bool = true,
        writeToAppleHealth: Bool = false
    ) {
        guard !isRunning, uploadToStrava || writeToAppleHealth else { return }
        guard !fingerprints.isEmpty else { return }
        wasInterrupted = false
        lastError = nil
        lastResultText = nil
        progress = .zero
        isRunning = true

        runningTask = Task { @MainActor in
            defer {
                self.isRunning = false
                self.runningTask = nil
            }
            do {
                var text = ""
                if uploadToStrava {
                    // 调用 AutoSyncEngine.resyncFingerprints：只重传勾选记录。
                    let result = try await engine.resyncFingerprints(
                        fingerprints,
                        customTitle: customTitle
                    ) { [weak self] p in
                        self?.progress = p
                    }
                    try Task.checkCancellation()
                    text = "Strava：上传 \(result.uploaded)，去重 \(result.deduped)，失败 \(result.failed)。"
                    if !result.notes.isEmpty {
                        text += "\n" + result.notes.prefix(8).joined(separator: "\n")
                    }
                }
                if writeToAppleHealth {
                    let health = try await AppleHealthImportPass().run(
                        fingerprints: fingerprints,
                        progressSeed: self.progress,
                        onProgress: { [weak self] p in
                            self?.progress = p
                        },
                        onNearby: { [weak self] prompt in
                            guard let self else { return .skipOnce }
                            return await self.awaitHealthNearbyDecision(prompt)
                        }
                    )
                    if !text.isEmpty { text += "\n" }
                    text += "健康：写入 \(health.written)，跳过 \(health.skipped)，失败 \(health.failed)。"
                    if !health.notes.isEmpty {
                        text += "\n" + health.notes.prefix(8).joined(separator: "\n")
                    }
                }
                self.lastResultText = text
                self.wasInterrupted = false
            } catch is CancellationError {
                self.wasInterrupted = true
                self.lastError = "勾选重传已取消"
            } catch {
                self.wasInterrupted = true
                self.lastError = error.localizedDescription
            }
        }
    }

    /// 继续中断任务：复用原配置，并跳过已经同步完成的活动。
    func resume() {
        guard var lastJob, !isRunning else { return }
        lastJob.skipIfHistoryExists = true
        start(lastJob)
    }

    /// 整批重试：复用原配置，但不按本地同步记录跳过。
    func retryBatch() {
        guard var lastJob, !isRunning else { return }
        lastJob.skipIfHistoryExists = false
        start(lastJob)
    }

    func cancel() {
        guard isRunning else { return }
        runningTask?.cancel()
        wasInterrupted = true
        progress.message = "正在取消…"
        resolveDuplicate(.skip)
        resolvePreview(.stopBatch)
        resolveHealthNearby(.cancelBatch)
    }

    func resolveDuplicate(_ decision: StravaDuplicateDecision) {
        if let alert = duplicateAlert {
            duplicateAlert = nil
            alert.dismiss(animated: true)
        }
        guard let continuation = duplicateContinuation else {
            duplicatePrompt = nil
            return
        }
        duplicateContinuation = nil
        duplicatePrompt = nil
        continuation.resume(returning: decision)
    }

    private func awaitDuplicateDecision(_ prompt: StravaDuplicatePrompt) async -> StravaDuplicateDecision {
        await withCheckedContinuation { continuation in
            self.duplicateContinuation = continuation
            self.duplicatePrompt = prompt
            // 调用 presentDuplicateAlert：盖在任意 sheet 之上，避免看不见覆盖选项。
            self.presentDuplicateAlert(prompt)
        }
    }

    func resolvePreview(_ decision: SyncPreviewDecision) {
        guard let continuation = previewContinuation else {
            previewPrompt = nil
            return
        }
        previewContinuation = nil
        previewPrompt = nil
        continuation.resume(returning: decision)
    }

    private func awaitPreviewDecision(_ prompt: SyncPreviewPrompt) async -> SyncPreviewDecision {
        await withCheckedContinuation { continuation in
            previewContinuation = continuation
            previewPrompt = prompt
        }
    }

    func resolveHealthNearby(_ decision: AppleHealthNearbyDecision) {
        if let alert = healthNearbyAlert {
            healthNearbyAlert = nil
            alert.dismiss(animated: true)
        }
        guard let continuation = healthNearbyContinuation else {
            healthNearbyPrompt = nil
            return
        }
        healthNearbyContinuation = nil
        healthNearbyPrompt = nil
        continuation.resume(returning: decision)
    }

    private func awaitHealthNearbyDecision(_ prompt: AppleHealthNearbyPrompt) async -> AppleHealthNearbyDecision {
        await withCheckedContinuation { continuation in
            healthNearbyContinuation = continuation
            healthNearbyPrompt = prompt
            presentHealthNearbyAlert(prompt)
        }
    }

    private func presentHealthNearbyAlert(_ prompt: AppleHealthNearbyPrompt) {
        guard let host = topViewController() else {
            resolveHealthNearby(.skipOnce)
            return
        }
        let alert = UIAlertController(
            title: "健康已有接近训练：\(prompt.activityTitle)",
            message: "\(prompt.nearbySummary)\n「本批一律…」只对这次同步的健康写入有效，不影响 Strava。",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "写入", style: .default) { [weak self] _ in
            self?.healthNearbyAlert = nil
            self?.resolveHealthNearby(.write)
        })
        alert.addAction(UIAlertAction(title: "本批都写", style: .default) { [weak self] _ in
            self?.healthNearbyAlert = nil
            self?.resolveHealthNearby(.writeRestOfBatch)
        })
        alert.addAction(UIAlertAction(title: "跳过", style: .default) { [weak self] _ in
            self?.healthNearbyAlert = nil
            self?.resolveHealthNearby(.skip)
        })
        alert.addAction(UIAlertAction(title: "本批都跳过", style: .default) { [weak self] _ in
            self?.healthNearbyAlert = nil
            self?.resolveHealthNearby(.skipRestOfBatch)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.healthNearbyAlert = nil
            self?.resolveHealthNearby(.skipOnce)
        })
        if let pop = alert.popoverPresentationController {
            pop.sourceView = host.view
            pop.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        healthNearbyAlert = alert
        host.present(alert, animated: true)
    }

    /// 用 key window 最顶层 VC 弹 ActionSheet，不被自动同步/同步记录 sheet 挡住。
    private func presentDuplicateAlert(_ prompt: StravaDuplicatePrompt) {
        guard let host = topViewController() else { return }
        let canOverwrite = StravaSpeedAnomaly.isOpenableRemoteId(prompt.remoteId)
        let message: String
        if canOverwrite {
            message = "\(prompt.reason)\n远端 ID：\(prompt.remoteId)\n覆盖用网页 Cookie 删除后按当前模式重传。「本批一律…」只对这次同步有效。"
        } else {
            message = "\(prompt.reason)\n尚无可用远端 ID，无法覆盖删除，只能跳过。「本批一律跳过」只对这次同步有效。"
        }
        let alert = UIAlertController(
            title: "重复：\(prompt.activityTitle)",
            message: message,
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "跳过", style: .default) { [weak self] _ in
            self?.duplicateAlert = nil
            self?.resolveDuplicate(.skip)
        })
        alert.addAction(UIAlertAction(title: "本批一律跳过", style: .default) { [weak self] _ in
            self?.duplicateAlert = nil
            self?.resolveDuplicate(.skipRestOfBatch)
        })
        if canOverwrite {
            alert.addAction(UIAlertAction(title: "打开远端活动", style: .default) { [weak self] _ in
                self?.duplicateAlert = nil
                self?.resolveDuplicate(.openRemote)
            })
            alert.addAction(UIAlertAction(title: "覆盖（网页删后重传）", style: .destructive) { [weak self] _ in
                self?.duplicateAlert = nil
                self?.resolveDuplicate(.overwrite)
            })
            alert.addAction(UIAlertAction(title: "本批一律覆盖", style: .destructive) { [weak self] _ in
                self?.duplicateAlert = nil
                self?.resolveDuplicate(.overwriteRestOfBatch)
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.duplicateAlert = nil
            self?.resolveDuplicate(.skip)
        })
        if let pop = alert.popoverPresentationController {
            pop.sourceView = host.view
            pop.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        duplicateAlert = alert
        host.present(alert, animated: true)
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
