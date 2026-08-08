import Foundation
import Observation
import UIKit

/// 一次自动同步的可恢复配置（中断后「继续」用同一套参数再跑）。
struct SyncJobConfig: Equatable, Sendable {
    var primarySourceId: String
    var supplementSourceIds: [String]
    var mode: AutoSyncMode
    var historyRange: SyncHistoryRange
    var customStart: Date
    var customEnd: Date
    /// 本地已有该主活动 uploaded 记录则跳过（忽略补源差异）。
    var skipIfHistoryExists: Bool
}

/// App 级同步会话：进度跨页面可见，支持取消与继续。
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
    private weak var duplicateAlert: UIAlertController?
    private var runningTask: Task<Void, Never>?
    private let engine = AutoSyncEngine()

    private init() {}

    func start(_ job: SyncJobConfig) {
        guard !isRunning else { return }
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
                // 调用 AutoSyncEngine.run：按任务配置执行同步。
                let result = try await engine.run(
                    primarySourceId: job.primarySourceId,
                    supplementSourceIds: job.supplementSourceIds,
                    mode: job.mode,
                    historyRange: job.historyRange,
                    customStart: job.customStart,
                    customEnd: job.customEnd,
                    skipIfHistoryExists: job.skipIfHistoryExists,
                    onProgress: { [weak self] p in
                        self?.progress = p
                    },
                    onDuplicate: { [weak self] prompt in
                        guard let self else { return .skip }
                        return await self.awaitDuplicateDecision(prompt)
                    }
                )
                try Task.checkCancellation()
                var text = "完成：上传 \(result.uploaded)，去重 \(result.deduped)，失败 \(result.failed)。"
                if !result.notes.isEmpty {
                    text += "\n" + result.notes.prefix(8).joined(separator: "\n")
                }
                self.lastResultText = text
                self.wasInterrupted = false
            } catch is CancellationError {
                self.wasInterrupted = true
                self.lastError = "同步已取消，可点「继续上次同步」接着跑（已上传的会跳过）"
                self.resolveDuplicate(.skip)
            } catch {
                self.wasInterrupted = true
                self.lastError = error.localizedDescription
                self.resolveDuplicate(.skip)
            }
        }
    }

    /// 勾选重传：默认覆盖不弹窗；与普通自动同步互斥。
    func startResync(fingerprints: [String]) {
        guard !isRunning else { return }
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
                // 调用 AutoSyncEngine.resyncFingerprints：只重传勾选记录。
                let result = try await engine.resyncFingerprints(fingerprints) { [weak self] p in
                    self?.progress = p
                }
                try Task.checkCancellation()
                var text = "勾选重传完成：上传 \(result.uploaded)，去重 \(result.deduped)，失败 \(result.failed)。"
                if !result.notes.isEmpty {
                    text += "\n" + result.notes.prefix(8).joined(separator: "\n")
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

    func resume() {
        guard let lastJob, !isRunning else { return }
        start(lastJob)
    }

    func cancel() {
        guard isRunning else { return }
        runningTask?.cancel()
        wasInterrupted = true
        progress.message = "正在取消…"
        resolveDuplicate(.skip)
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
