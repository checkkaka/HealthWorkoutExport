import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ExportViewModel {
    /// HealthKit 服务，负责授权与查询。
    @ObservationIgnored private let healthKit = HealthKitService()
    /// 导出流水线。
    @ObservationIgnored private let pipeline: ExportPipeline

    init() {
        // 调用 ExportPipeline：绑定同一 HealthKitService 实例做批量导出。
        pipeline = ExportPipeline(healthKit: healthKit)
    }

    var authorizationGranted = false
    var isLoading = false
    var isExporting = false
    /// 导出格式：JSON 或 FIT 二选一。
    var exportFormat: ExportFormat = .json
    /// 导出文件使用的时区（影响 JSON 日期、FIT 本地时间与文件名）。
    var exportTimeZone: TimeZone = .current
    /// 时区下拉候选（含当前时区与上海）。
    let timeZoneOptions = ExportTimeZone.options()
    var errorMessage: String?
    var workouts: [WorkoutSummary] = []
    var selectedIDs: Set<UUID> = []
    var preset: DateRangePreset = .days30
    var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    var customEnd = Date()
    var exportProgress = ExportProgress(completed: 0, total: 0)
    var shareURL: URL?
    var showExportSheet = false

    var selectedWorkouts: [WorkoutSummary] {
        workouts.filter { selectedIDs.contains($0.id) }
    }

    var currentRange: (start: Date, end: Date) {
        preset.resolve(customStart: customStart, customEnd: customEnd)
    }

    /// 启动时请求权限并加载列表。
    func bootstrap() async {
        guard healthKit.isHealthDataAvailable else {
            errorMessage = HealthKitServiceError.unavailable.localizedDescription
            return
        }
        do {
            // 调用 requestAuthorization：向用户申请健康数据读取权限。
            try await healthKit.requestAuthorization()
            authorizationGranted = true
            // 调用 reload：按当前时间范围刷新训练列表。
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            authorizationGranted = false
        }
    }

    /// 按时间范围重新查询训练摘要。
    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let range = currentRange
            // 调用 fetchWorkoutSummaries：仅拉摘要保证列表秒开。
            let list = try await healthKit.fetchWorkoutSummaries(from: range.start, to: range.end)
            workouts = list
            // 加载后默认不选，由用户手动勾选要导出的训练。
            selectedIDs = []
        } catch {
            errorMessage = error.localizedDescription
            workouts = []
            selectedIDs = []
        }
    }

    /// 将单次体能训练编码为 FIT（合并面板「从体能训练选择」用）。
    func encodeWorkoutAsFIT(_ summary: WorkoutSummary) async throws -> Data {
        // 调用 fetchWorkoutBundle：拉该次训练的完整明细。
        let bundle = try await healthKit.fetchWorkoutBundle(for: summary)
        let timeZone = exportTimeZone
        // 编码是 CPU 密集操作，放后台线程执行避免长训练卡住 UI。
        return try await Task.detached(priority: .userInitiated) {
            // 调用 FitActivityEncoder：按当前导出时区生成 FIT。
            try FitActivityEncoder.encode(bundle, timeZone: timeZone)
        }.value
    }

    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func selectAll() {
        selectedIDs = Set(workouts.map(\.id))
    }

    func deselectAll() {
        selectedIDs.removeAll()
    }

    /// 打开导出面板。
    func prepareExport() {
        guard !selectedWorkouts.isEmpty else {
            errorMessage = ExportPipelineError.nothingSelected.localizedDescription
            return
        }
        shareURL = nil
        exportProgress = ExportProgress(completed: 0, total: selectedWorkouts.count)
        showExportSheet = true
    }

    /// 执行批量导出。
    func runExport() async {
        guard !isExporting else { return }
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        do {
            // 调用 pipeline.export：并发拉明细并按所选时区写 JSON/FIT。
            let url = try await pipeline.export(
                summaries: selectedWorkouts,
                format: exportFormat,
                timeZone: exportTimeZone
            ) { [weak self] progress in
                self?.exportProgress = progress
            }
            shareURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 删除本次导出产物（临时文件），并清空分享状态。
    func deleteExportedFile() {
        guard let shareURL else { return }
        let fm = FileManager.default
        // 导出物在 HealthWorkoutExport-* 目录内时整目录删掉，避免残留。
        let parent = shareURL.deletingLastPathComponent()
        if parent.lastPathComponent.hasPrefix("HealthWorkoutExport-") {
            try? fm.removeItem(at: parent)
        } else {
            try? fm.removeItem(at: shareURL)
        }
        self.shareURL = nil
        exportProgress = ExportProgress(completed: 0, total: selectedWorkouts.count)
    }

    /// 打开系统设置以便用户调整健康权限。
    func openHealthSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
