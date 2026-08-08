import SwiftUI
import UniformTypeIdentifiers

/// 已导入待合并的 FIT 候选（文件导入或从体能训练编码而来）。
private struct MergeCandidate: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    /// 来源体能训练的 UUID（文件导入为 nil），用于去重。
    var sourceUUID: UUID?
}

struct FitMergeView: View {
    @Bindable var viewModel: ExportViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [MergeCandidate] = []
    @State private var primaryID: UUID?
    @State private var showImporter = false
    @State private var showWorkoutPicker = false
    @State private var isPreparing = false
    @State private var isMerging = false
    @State private var mergedURL: URL?
    @State private var errorMessage: String?
    /// 时间对齐方式：绝对时间 / 手动偏移 / 自动对齐。
    @State private var alignMode: AlignMode = .automatic
    /// 手动偏移秒数：加到所有副文件时间戳（副时钟快则填负数）。
    @State private var manualOffsetSeconds: Int = 0
    /// 上次自动对齐估出的各副文件偏移，合并成功后展示。
    @State private var alignResultText: String?

    private enum AlignMode: String, CaseIterable, Identifiable {
        case absolute
        case manual
        case automatic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .absolute: return "绝对时间"
            case .manual: return "手动偏移"
            case .automatic: return "自动对齐"
            }
        }
    }

    private static let fitType = UTType(filenameExtension: "fit") ?? .data

    private var isBusy: Bool { isPreparing || isMerging }

    /// 操作按钮文案：单条导出，多条合并。
    private var actionTitle: String {
        candidates.count <= 1 ? "导出" : "合并"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("添加 FIT 文件", systemImage: "plus.circle")
                    }
                    .disabled(isBusy)

                    Button {
                        showWorkoutPicker = true
                    } label: {
                        Label("从体能训练选择", systemImage: "figure.run")
                    }
                    .disabled(isBusy || viewModel.workouts.isEmpty)
                } footer: {
                    Text("可从文件、体能训练两边挑选，也可只用一边。选 1 条则直接导出 FIT；选 2 条及以上则合并（点选主数据源，冲突以主为准）。FIT 每条记录都有绝对时间戳；设备时钟不准时请用「手动偏移」或「自动对齐」。")
                }

                if candidates.count >= 2 {
                    Section {
                        Picker("时间对齐", selection: $alignMode) {
                            ForEach(AlignMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isBusy)
                        .onChange(of: alignMode) { _, _ in
                            mergedURL = nil
                            alignResultText = nil
                        }

                        if alignMode == .manual {
                            Stepper(value: $manualOffsetSeconds, in: -7200...7200, step: 1) {
                                Text("副文件偏移 \(manualOffsetSeconds) 秒")
                            }
                            TextField("偏移秒数", value: $manualOffsetSeconds, format: .number)
                                .keyboardType(.numbersAndPunctuation)
                            Text("加到副文件时间戳。副设备时钟偏快填负数（例如迈金快约 14.5 分可填 -871）。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else if alignMode == .automatic {
                            Text("按主/副速度互相关自动估偏移；估不出时再试累计距离。适合设备时钟不一致的同场记录。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("直接按 FIT 绝对时间戳对齐，不做时钟校正。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("时间轴")
                    }
                }

                if !candidates.isEmpty {
                    Section("候选（点选主数据源）") {
                        ForEach(candidates) { candidate in
                            Button {
                                primaryID = candidate.id
                                mergedURL = nil
                            } label: {
                                HStack {
                                    Image(systemName: candidate.id == primaryID ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(candidate.id == primaryID ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.name)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        if candidate.id == primaryID {
                                            Text("主数据源")
                                                .font(.caption)
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(candidate.data.count), countStyle: .file))
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            let removed = offsets.map { candidates[$0].id }
                            candidates.remove(atOffsets: offsets)
                            if let primaryID, removed.contains(primaryID) {
                                self.primaryID = candidates.first?.id
                            }
                            mergedURL = nil
                        }
                    }
                }

                Section {
                    if isPreparing {
                        HStack {
                            ProgressView()
                            Text("正在生成 FIT…")
                                .foregroundStyle(.secondary)
                        }
                    } else if isMerging {
                        HStack {
                            ProgressView()
                            Text(candidates.count <= 1 ? "正在导出…" : "正在合并…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let mergedURL {
                        Label(candidates.count <= 1 ? "导出完成" : "合并完成", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if let alignResultText {
                            Text(alignResultText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ShareLink(item: mergedURL) {
                            Label("分享结果", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            // 调用 deleteMergedFile：删除产物目录并清空状态。
                            deleteMergedFile()
                        } label: {
                            Label("删除文件", systemImage: "trash")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("合并 FIT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) {
                        Task { await runAction() }
                    }
                    .disabled(candidates.isEmpty || primaryID == nil || isBusy)
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [Self.fitType],
                allowsMultipleSelection: true
            ) { result in
                importFiles(result)
            }
            .sheet(isPresented: $showWorkoutPicker) {
                WorkoutPickForMergeView(workouts: viewModel.workouts) { summaries in
                    Task { await addWorkouts(summaries) }
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
    }

    /// 读入所选文件内容；尚无主数据源时默认第一项为主。
    /// 导入即用 FitMerger.decode 校验，坏文件不进候选；按文件名+大小去重。
    private func importFiles(_ result: Result<[URL], Error>) {
        errorMessage = nil
        mergedURL = nil
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let name = url.lastPathComponent
                    if candidates.contains(where: { $0.name == name && $0.data.count == data.count }) {
                        continue
                    }
                    // 调用 FitMerger.decode：导入时即校验文件可解析，坏文件当场报错。
                    _ = try FitMerger.decode(data, name: name)
                    candidates.append(MergeCandidate(name: name, data: data))
                } catch {
                    errorMessage = "读取 \(url.lastPathComponent) 失败：\(error.localizedDescription)"
                }
            }
            if primaryID == nil {
                primaryID = candidates.first?.id
            }
        }
    }

    /// 把选中的体能训练编码为 FIT 并加入候选列表。
    private func addWorkouts(_ summaries: [WorkoutSummary]) async {
        guard !summaries.isEmpty else { return }
        errorMessage = nil
        mergedURL = nil
        isPreparing = true
        defer { isPreparing = false }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = viewModel.exportTimeZone
        formatter.dateFormat = "yyyyMMdd_HHmmss"

        for summary in summaries {
            // 同一训练已在候选里则跳过，避免重复合并。
            if candidates.contains(where: { $0.sourceUUID == summary.uuid }) { continue }
            do {
                // 调用 encodeWorkoutAsFIT：把该次训练转成 FIT 字节（编码在后台线程）。
                let data = try await viewModel.encodeWorkoutAsFIT(summary)
                let name = "\(summary.activityName)_\(formatter.string(from: summary.startDate)).fit"
                candidates.append(MergeCandidate(name: name, data: data, sourceUUID: summary.uuid))
            } catch {
                errorMessage = "编码 \(summary.activityName) 失败：\(error.localizedDescription)"
                break
            }
        }
        if primaryID == nil {
            primaryID = candidates.first?.id
        }
    }

    /// 合并产物目录前缀；带 "HealthWorkoutExport-" 前缀可被导出流水线的历史清理一并覆盖。
    private static let mergeDirPrefix = "HealthWorkoutExport-Merge-"

    /// 1 条直接写出 FIT；≥2 条按主数据源合并。
    private func runAction() async {
        guard let primaryID,
              let primary = candidates.first(where: { $0.id == primaryID }) else { return }

        isMerging = true
        errorMessage = nil
        alignResultText = nil
        // 调用 deleteMergedFile：写新产物前删掉上一次的，避免临时文件累积。
        deleteMergedFile()
        defer { isMerging = false }

        do {
            let output: Data
            let filePrefix: String
            if candidates.count == 1 {
                output = primary.data
                filePrefix = "export"
            } else {
                let primaryData = primary.data
                let primaryName = primary.name
                let otherPairs = candidates.filter { $0.id != primaryID }.map { ($0.data, $0.name) }
                let timeAlign: FitMergeTimeAlign
                switch alignMode {
                case .absolute:
                    timeAlign = .absolute
                case .manual:
                    timeAlign = .manual(seconds: manualOffsetSeconds)
                    alignResultText = "手动偏移：副文件 \(manualOffsetSeconds) 秒"
                case .automatic:
                    // 调用 estimateOffset：合并前算出各副文件偏移，既用于界面展示，
                    // 也以 .perFile 传给 merge 复用，避免 merge 内部重复估算。
                    var lines: [String] = []
                    var offsets: [Int] = []
                    for other in otherPairs {
                        let off = try await Task.detached(priority: .userInitiated) {
                            try FitMerger.estimateOffset(primary: primaryData, secondary: other.0)
                        }.value
                        offsets.append(off)
                        lines.append("\(other.1)：\(off) 秒")
                    }
                    alignResultText = "自动对齐偏移（加到副文件）：\n" + lines.joined(separator: "\n")
                    timeAlign = .perFile(offsets: offsets)
                }
                // 合并是 CPU 密集操作，放后台线程避免卡 UI。
                output = try await Task.detached(priority: .userInitiated) {
                    // 调用 FitMerger.merge：主文件优先、副文件补缺（含时间对齐）。
                    try FitMerger.merge(
                        primary: primaryData,
                        primaryName: primaryName,
                        others: otherPairs,
                        timeAlign: timeAlign
                    )
                }.value
                filePrefix = "merged"
            }
            // 调用 cleanupOldMergeDirs：清掉历史合并残留（含上次 App 会话遗留）。
            Self.cleanupOldMergeDirs()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(Self.mergeDirPrefix + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let url = dir.appendingPathComponent("\(filePrefix)_\(formatter.string(from: Date())).fit")
            try output.write(to: url, options: .atomic)
            mergedURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 删除当前合并产物（整目录），并清空完成与错误状态。
    private func deleteMergedFile() {
        if let mergedURL {
            try? FileManager.default.removeItem(at: mergedURL.deletingLastPathComponent())
        }
        mergedURL = nil
        errorMessage = nil
        alignResultText = nil
    }

    /// 清掉所有历史合并目录。
    /// ponytail: 与导出的 shareURL 目录前缀不同（HealthWorkoutExport-Merge- vs HealthWorkoutExport-），
    /// 合并清理不会误删导出面板尚未分享的文件。
    private static func cleanupOldMergeDirs() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(mergeDirPrefix) {
            try? fm.removeItem(at: entry)
        }
    }
}

/// 从当前列表勾选体能训练，确认后交给合并面板编码为 FIT。
private struct WorkoutPickForMergeView: View {
    let workouts: [WorkoutSummary]
    let onConfirm: ([WorkoutSummary]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(workouts) { workout in
                    Button {
                        if selected.contains(workout.id) {
                            selected.remove(workout.id)
                        } else {
                            selected.insert(workout.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected.contains(workout.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(workout.id) ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workout.activityName)
                                    .foregroundStyle(.primary)
                                Text(workout.startDate.formatted(date: .abbreviated, time: .shortened))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("选择体能训练")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(selected.count == workouts.count && !workouts.isEmpty ? "取消全选" : "全选") {
                        if selected.count == workouts.count {
                            selected = []
                        } else {
                            selected = Set(workouts.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        let picked = workouts.filter { selected.contains($0.id) }
                        dismiss()
                        onConfirm(picked)
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}
