import SwiftUI
import HealthKit

struct WorkoutListView: View {
    @State private var viewModel = ExportViewModel()
    @State private var showFitMerge = false
    @State private var showAutoSync = false
    @State private var showStravaSettings = false
    @State private var showSyncHistory = false
    @State private var uploadedKeys: Set<String> = []
    @State private var localRemoteIds: [String: String] = [:]
    @State private var detailWorkout: WorkoutSummary?

    var body: some View {
        NavigationStack {
            Group {
                if !viewModel.authorizationGranted && viewModel.errorMessage != nil && viewModel.workouts.isEmpty && !viewModel.isLoading {
                    permissionView
                } else {
                    mainList
                }
            }
            .navigationTitle("体能训练")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .sheet(isPresented: $viewModel.showExportSheet) {
                ExportSheetView(viewModel: viewModel)
            }
            .sheet(isPresented: $showFitMerge) {
                FitMergeView(viewModel: viewModel)
            }
            .sheet(isPresented: $showAutoSync) {
                AutoSyncView(entrySourceId: HealthKitDataSource.sourceId)
            }
            .sheet(isPresented: $showStravaSettings) {
                NavigationStack { StravaSettingsView() }
            }
            .sheet(isPresented: $showSyncHistory, onDismiss: {
                Task { await refreshSyncState() }
            }) {
                NavigationStack { SyncHistoryView(primarySourceId: HealthKitDataSource.sourceId) }
            }
            .sheet(item: $detailWorkout) { workout in
                ActivityDetailSheet(
                    title: workout.activityName,
                    sourceId: HealthKitDataSource.sourceId,
                    activityId: workout.id.uuidString,
                    startDate: workout.startDate,
                    endDate: workout.endDate,
                    duration: workout.duration,
                    distanceMeters: workout.totalDistanceMeters,
                    isSynced: uploadedKeys.contains(
                        SyncStateStore.primaryKey(
                            sourceId: HealthKitDataSource.sourceId,
                            activityId: workout.id.uuidString
                        )
                    ),
                    activityTypeName: workout.activityName
                )
            }
            .task {
                // 调用 bootstrap：首次进入申请权限并加载列表。
                await viewModel.bootstrap()
                await refreshSyncState()
            }
            .onChange(of: viewModel.preset) { _, _ in
                Task { await viewModel.reload(); await refreshSyncState() }
            }
            .onChange(of: viewModel.customStart) { _, _ in
                guard viewModel.preset == .custom else { return }
                Task { await viewModel.reload(); await refreshSyncState() }
            }
            .onChange(of: viewModel.customEnd) { _, _ in
                guard viewModel.preset == .custom else { return }
                Task { await viewModel.reload(); await refreshSyncState() }
            }
        }
    }

    private var mainList: some View {
        List {
            Section {
                DateRangePickerView(preset: $viewModel.preset, customStart: $viewModel.customStart, customEnd: $viewModel.customEnd)
            }

            if viewModel.isLoading {
                Section {
                    HStack {
                        ProgressView()
                        Text("正在加载…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if viewModel.workouts.isEmpty {
                Section {
                    ContentUnavailableView(
                        "这段时间没有训练",
                        systemImage: "figure.run",
                        description: Text("换一个时间范围再试试")
                    )
                }
            } else {
                Section {
                    ForEach(viewModel.workouts) { workout in
                        let synced = uploadedKeys.contains(
                            SyncStateStore.primaryKey(
                                sourceId: HealthKitDataSource.sourceId,
                                activityId: workout.id.uuidString
                            )
                        )
                        let remoteId = localRemoteIds[
                            SyncStateStore.primaryKey(
                                sourceId: HealthKitDataSource.sourceId,
                                activityId: workout.id.uuidString
                            )
                        ]
                        WorkoutRowView(
                            workout: workout,
                            isSelected: viewModel.selectedIDs.contains(workout.id),
                            isSynced: synced,
                            remoteId: remoteId,
                            onToggle: { viewModel.toggleSelection(workout.id) },
                            onOpenDetail: { detailWorkout = workout }
                        )
                    }
                } header: {
                    Text("\(viewModel.selectedIDs.count)/\(viewModel.workouts.count) 已选")
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.reload()
            await refreshSyncState()
        }
    }

    private var permissionView: some View {
        ContentUnavailableView {
            Label("需要健康权限", systemImage: "heart.text.square")
        } description: {
            Text(viewModel.errorMessage ?? "请允许读取体能训练与相关数据，以便导出。")
        } actions: {
            Button("重新授权") {
                Task { await viewModel.bootstrap() }
            }
            .buttonStyle(.borderedProminent)
            Button("打开设置") {
                viewModel.openHealthSettings()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("全选") { viewModel.selectAll() }
                Button("取消全选") { viewModel.deselectAll() }
                Divider()
                Button {
                    showFitMerge = true
                } label: {
                    Label("合并 FIT 文件", systemImage: "arrow.triangle.merge")
                }
                Divider()
                Button {
                    showAutoSync = true
                } label: {
                    Label("自动同步", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    showSyncHistory = true
                } label: {
                    Label("同步记录", systemImage: "list.bullet.rectangle")
                }
                Button {
                    showStravaSettings = true
                } label: {
                    Label("Strava 设置", systemImage: "gearshape")
                }
            } label: {
                Text("选择")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                viewModel.prepareExport()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.selectedIDs.isEmpty || viewModel.isLoading)
        }
    }

    private func refreshSyncState() async {
        // 从本地同步记录同时刷新已同步徽标与 Strava 远端 ID。
        uploadedKeys = await SyncStateStore.shared.uploadedPrimaryKeys()
        localRemoteIds = await SyncStateStore.shared.localRemoteIdsByPrimaryKey()
    }
}

struct WorkoutRowView: View {
    let workout: WorkoutSummary
    let isSelected: Bool
    let isSynced: Bool
    let remoteId: String?
    let onToggle: () -> Void
    let onOpenDetail: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                Button(action: onOpenDetail) {
                    HStack(spacing: 12) {
                        Image(systemName: workout.activityType.systemImageName)
                            .frame(width: 28)
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(workout.activityName)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if isSynced {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                                if remoteId != nil {
                                    Image(systemName: "bicycle.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text(Self.dateText(workout.startDate))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        VStack(alignment: .trailing, spacing: 4) {
                            Text(Self.durationText(workout.duration))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.primary)
                            if let meters = workout.totalDistanceMeters, meters > 0 {
                                Text(Self.distanceText(meters))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                StravaRemoteIDLine(remoteId: remoteId)
            }
        }
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "—"
    }

    private static func distanceText(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f 公里", meters / 1000)
        }
        return String(format: "%.0f 米", meters)
    }
}

/// 活动列表统一的本地 Strava ID 行；有数字 ID 时点击打开远端活动。
struct StravaRemoteIDLine: View {
    let remoteId: String?

    var body: some View {
        HStack(spacing: 4) {
            Text("Strava 远端 ID：")
            if let remoteId,
               let url = URL(string: "https://www.strava.com/activities/\(remoteId)") {
                Link(destination: url) {
                    Label(remoteId, systemImage: "bicycle.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}
