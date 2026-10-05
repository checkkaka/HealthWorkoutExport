import SwiftUI

/// 自定义范围：点按弹出中文年月日滚轮（取消 / 确定）。
struct ChineseWheelDateField: View {
    let title: String
    @Binding var date: Date
    var enabled: Bool = true

    @State private var showPicker = false

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    var body: some View {
        Button {
            guard enabled else { return }
            showPicker = true
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(Self.displayFormatter.string(from: date))
                    .foregroundStyle(enabled ? Color.accentColor : .secondary)
            }
        }
        .disabled(!enabled)
        .sheet(isPresented: $showPicker) {
            ChineseWheelDatePickerSheet(date: $date)
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.hidden)
        }
    }
}

/// 选择日期：年 / 月 / 日滚轮 + 取消 / 确定。
struct ChineseWheelDatePickerSheet: View {
    @Binding var date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Date

    init(date: Binding<Date>) {
        _date = date
        _draft = State(initialValue: date.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("选择日期")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 8)

            DatePicker(
                "",
                selection: $draft,
                displayedComponents: .date
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)

            Divider()
            HStack(spacing: 0) {
                Button("取消") { dismiss() }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.primary)
                    .padding(.vertical, 14)
                Divider().frame(height: 44)
                Button("确定") {
                    date = draft
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(.orange)
                .fontWeight(.semibold)
                .padding(.vertical, 14)
            }
        }
        .background(Color(.systemBackground))
    }
}

struct DateRangePickerView: View {
    @Binding var preset: DateRangePreset
    @Binding var customStart: Date
    @Binding var customEnd: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("时间范围", selection: $preset) {
                ForEach(DateRangePreset.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if preset == .custom {
                ChineseWheelDateField(title: "开始", date: $customStart)
                ChineseWheelDateField(title: "结束", date: $customEnd)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 列表摘要的本地组合筛选：日期由数据源查询，距离与均速在已加载摘要上再筛。
/// 输入用原始字符串保存，避免 SwiftUI 数字 TextField 每敲一键就按小数位重排文本。
struct ActivityListFilter: Equatable {
    var minimumDistanceText = ""
    var minimumAverageSpeedText = ""

    var isEnabled: Bool {
        requiredDistanceKm != nil || requiredAverageSpeedKmh != nil
    }

    func matches(distanceMeters: Double?, duration: TimeInterval) -> Bool {
        guard requiredDistanceKm != nil || requiredAverageSpeedKmh != nil else {
            return true
        }
        guard let distanceMeters, distanceMeters > 0 else { return false }
        let distanceKm = distanceMeters / 1_000
        guard requiredDistanceKm.map({ distanceKm >= $0 }) ?? true else { return false }
        guard let requiredAverageSpeedKmh else { return true }
        guard duration > 0 else { return false }
        return distanceKm / (duration / 3_600) >= requiredAverageSpeedKmh
    }

    private var requiredDistanceKm: Double? {
        Self.parsePositive(minimumDistanceText)
    }

    private var requiredAverageSpeedKmh: Double? {
        Self.parsePositive(minimumAverageSpeedText)
    }

    private static func parsePositive(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }
}

struct ActivityListFilterView: View {
    @Binding var filter: ActivityListFilter

    var body: some View {
        LabeledContent("最短距离（km）") {
            TextField("不限", text: $filter.minimumDistanceText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
        LabeledContent("最低平均速度（km/h）") {
            TextField("不限", text: $filter.minimumAverageSpeedText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
        if filter.isEnabled {
            Button("清除筛选", role: .destructive) { filter = .init() }
        }
    }
}

/// 列表排序：时间 / 距离 / 均速（距离÷时长），无值的条目固定排在末尾。
enum ActivitySortKey: String, CaseIterable, Identifiable {
    case date
    case distance
    case averageSpeed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .date: "时间"
        case .distance: "距离"
        case .averageSpeed: "均速"
        }
    }
}

struct ActivitySortOrder: Equatable {
    var key: ActivitySortKey = .date
    var ascending = false
}

extension ActivitySortOrder {
    /// 无指标的条目固定排末尾；指标相同或均缺失时，按当前方向比较时间。
    func sorted<T>(_ items: [T], metric: (T) -> Double?, date: (T) -> Date) -> [T] {
        items.sorted { a, b in
            let (x, y) = (metric(a), metric(b))
            switch (x, y) {
            case let (lhs?, rhs?):
                if lhs == rhs {
                    return ascending ? date(a) < date(b) : date(a) > date(b)
                }
                return ascending ? lhs < rhs : lhs > rhs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return ascending ? date(a) < date(b) : date(a) > date(b)
            }
        }
    }

    /// 均速 km/h：无距离或零时长时返回 nil。
    static func averageSpeedKmh(distanceMeters: Double?, duration: TimeInterval) -> Double? {
        guard let distanceMeters, distanceMeters > 0, duration > 0 else { return nil }
        return distanceMeters / 1_000 / (duration / 3_600)
    }
}

/// 排序工具栏 Menu：点同一个键切换正/倒序，换新键默认倒序（与时间默认最新在前一致）。
struct ActivitySortMenu: View {
    @Binding var sortOrder: ActivitySortOrder

    var body: some View {
        Menu {
            ForEach(ActivitySortKey.allCases) { key in
                Button {
                    if sortOrder.key == key {
                        sortOrder.ascending.toggle()
                    } else {
                        sortOrder = ActivitySortOrder(key: key, ascending: false)
                    }
                } label: {
                    if sortOrder.key == key {
                        Label(
                            sortOrder.ascending ? "\(key.label) 正序" : "\(key.label) 倒序",
                            systemImage: sortOrder.ascending ? "arrow.up" : "arrow.down"
                        )
                    } else {
                        Text(key.label)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("排序")
    }
}

/// 三个运动列表共用的只读远端扫描；关闭页面会取消未完成的请求。
struct StravaScanSheet: View {
    let activities: [SourceActivity]
    @Environment(\.dismiss) private var dismiss
    @State private var results: [String: StravaScanResult] = [:]
    @State private var isScanning = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("扫描当前列表范围，共 \(activities.count) 条。只读取 Strava 并保存本地标记、补全缺失 ID；不会上传、覆盖或删除远端活动。")
                    Text("时间覆盖至少85%、时长差不超过10%（至少容许60秒）、距离差不超过5%（至少100米）才标为完整匹配。缺少距离或多条候选时保留待核对标记。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if isScanning {
                        ProgressView("正在读取 Strava 活动并匹配…")
                    } else if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else {
                        ForEach(StravaScanResult.Status.allCases, id: \.rawValue) { status in
                            let count = results.values.filter { $0.status == status }.count
                            if count > 0 { LabeledContent(status.title, value: "\(count) 条") }
                        }
                    }
                }
                ForEach(activities) { activity in
                    if let result = results[SyncStateStore.primaryKey(sourceId: activity.sourceId, activityId: activity.id)] {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(activity.title).font(.headline)
                            Text(activity.startDate.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            StravaScanResultLine(result: result)
                            if result.remoteId != nil { StravaRemoteIDLine(remoteId: result.remoteId) }
                        }
                    }
                }
            }
            .navigationTitle("Strava 活动扫描")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isScanning ? "取消" : "完成") { dismiss() }
                }
            }
            .task {
                do {
                    results = try await StravaActivityScan.scan(activities)
                } catch {
                    if !Task.isCancelled { errorMessage = error.localizedDescription }
                }
                isScanning = false
            }
        }
    }
}

struct StravaScanResultLine: View {
    let result: StravaScanResult?

    var body: some View {
        if let result {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.status.title).font(.caption.weight(.semibold))
                    .foregroundStyle(result.status == .complete ? Color.green : Color.orange)
                Text(result.detail).font(.caption2).foregroundStyle(.secondary)
                Text("扫描于 \(result.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct ExportSheetView: View {
    @Bindable var viewModel: ExportViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ExportFormSheet(
            exportFormat: $viewModel.exportFormat,
            fitExportSource: $viewModel.fitExportSource,
            canExportSyncedFIT: viewModel.canExportSyncedFIT,
            exportTimeZone: $viewModel.exportTimeZone,
            timeZoneOptions: viewModel.timeZoneOptions,
            selectedCount: viewModel.selectedWorkouts.count,
            isExporting: viewModel.isExporting,
            exportProgress: viewModel.exportProgress,
            shareURL: viewModel.shareURL,
            errorMessage: viewModel.errorMessage,
            formatFootnote: "原始 FIT 按所选时区生成；Strava 同步版保持上传时内容，时区仅影响导出文件名。",
            onExport: { await viewModel.runExport() },
            onDelete: { viewModel.deleteExportedFile() },
            onDismiss: { dismiss() }
        )
    }
}

/// 第三方源导出面板（与健康导出同一套表单）。
struct SourceExportSheetView: View {
    @Bindable var viewModel: SourceExportViewModel
    let source: any WorkoutDataSource
    let activities: [SourceActivity]
    @Environment(\.dismiss) private var dismiss

    private var selectedCount: Int {
        viewModel.selectedActivities(from: activities).count
    }

    var body: some View {
        ExportFormSheet(
            exportFormat: $viewModel.exportFormat,
            fitExportSource: $viewModel.fitExportSource,
            canExportSyncedFIT: viewModel.canExportSyncedFIT,
            exportTimeZone: $viewModel.exportTimeZone,
            timeZoneOptions: viewModel.timeZoneOptions,
            selectedCount: selectedCount,
            isExporting: viewModel.isExporting,
            exportProgress: viewModel.exportProgress,
            shareURL: viewModel.shareURL,
            errorMessage: viewModel.errorMessage,
            formatFootnote: "原始 FIT 从源站下载；Strava 同步版保持上传时内容。JSON 仅为活动摘要。时区影响文件名与 JSON 日期。",
            onExport: {
                await viewModel.runExport(source: source, activities: activities)
            },
            onDelete: { viewModel.deleteExportedFile(selectedCount: selectedCount) },
            onDismiss: { dismiss() }
        )
    }
}

/// 导出表单：格式 / 时区 / 进度 / 分享。
private struct ExportFormSheet: View {
    @Binding var exportFormat: ExportFormat
    @Binding var fitExportSource: FITExportSource
    let canExportSyncedFIT: Bool
    @Binding var exportTimeZone: TimeZone
    let timeZoneOptions: [TimeZone]
    let selectedCount: Int
    let isExporting: Bool
    let exportProgress: ExportProgress
    let shareURL: URL?
    let errorMessage: String?
    let formatFootnote: String
    let onExport: () async -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("格式", selection: $exportFormat) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    if exportFormat == .fit {
                        Picker("FIT 来源", selection: $fitExportSource) {
                            ForEach(FITExportSource.allCases) { source in
                                Text(source.title).tag(source)
                                    .disabled(source == .strava && !canExportSyncedFIT)
                            }
                        }
                        .pickerStyle(.segmented)
                        if !canExportSyncedFIT {
                            Text("所选记录缺少本地同步版 FIT，重新同步后才可选择。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else if fitExportSource == .strava {
                            Text("导出当时实际上传成功并保存在本机的最终 FIT；旧同步记录需重新同步一次后才可用。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker("时区", selection: $exportTimeZone) {
                        ForEach(timeZoneOptions, id: \.identifier) { zone in
                            Text(ExportTimeZone.displayName(for: zone)).tag(zone)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(formatFootnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("进度") {
                    if isExporting {
                        ProgressView(value: exportProgress.fraction) {
                            Text("正在导出 \(exportProgress.completed)/\(exportProgress.total)")
                        }
                    } else if shareURL != nil {
                        Label("导出完成", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("将导出 \(selectedCount) 条训练")
                            .foregroundStyle(.secondary)
                    }
                }

                if let shareURL {
                    Section {
                        ShareLink(item: shareURL) {
                            Label("分享文件", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("删除文件", systemImage: "trash")
                        }
                        .disabled(isExporting)
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
            .navigationTitle("导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onDismiss() }
                        .disabled(isExporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(shareURL == nil ? "开始" : "再导出") {
                        Task { await onExport() }
                    }
                    .disabled(isExporting || selectedCount == 0)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isExporting)
    }
}
