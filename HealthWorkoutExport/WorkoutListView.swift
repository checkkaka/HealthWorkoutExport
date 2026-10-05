import SwiftUI
import HealthKit

struct WorkoutListView: View {
    @Environment(SyncSession.self) private var session
    @State private var viewModel = ExportViewModel()
    @State private var showFitMerge = false
    @State private var showAutoSync = false
    @State private var showStravaSettings = false
    @State private var showRefreshConfirmation = false
    @State private var showSyncHistory = false
    @State private var uploadedKeys: Set<String> = []
    @State private var virtualPowerKeys: Set<String> = []
    @State private var syncedFITKeys: Set<String> = []
    @State private var localRemoteIds: [String: String] = [:]
    @State private var detailWorkout: WorkoutSummary?
    @State private var filter = ActivityListFilter()
    @State private var sortOrder = ActivitySortOrder()
    @State private var showStravaScan = false
    @State private var scanActivities: [SourceActivity] = []
    @State private var stravaScans: [String: StravaScanResult] = [:]

    private var filteredWorkouts: [WorkoutSummary] {
        sortOrder.sorted(
            viewModel.workouts.filter {
                filter.matches(distanceMeters: $0.totalDistanceMeters, duration: $0.duration)
            },
            metric: { workout in
                switch sortOrder.key {
                case .date:
                    workout.startDate.timeIntervalSince1970
                case .distance:
                    workout.totalDistanceMeters
                case .averageSpeed:
                    ActivitySortOrder.averageSpeedKmh(
                        distanceMeters: workout.totalDistanceMeters,
                        duration: workout.duration
                    )
                }
            },
            date: \.startDate
        )
    }

    private var requiresSelectionForFilteredAutoSync: Bool {
        filter.isEnabled && viewModel.selectedIDs.isEmpty
    }

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
            .sheet(isPresented: $showAutoSync, onDismiss: {
                Task { await refreshSyncState() }
            }) {
                AutoSyncView(
                    entrySourceId: HealthKitDataSource.sourceId,
                    selectedActivityIds: viewModel.selectedWorkouts.map(\.id.uuidString),
                    selectedStart: viewModel.selectedWorkouts.map(\.startDate).min(),
                    selectedEnd: viewModel.selectedWorkouts.map(\.endDate).max()
                )
            }
            .sheet(isPresented: $showStravaSettings) {
                NavigationStack { StravaSettingsView() }
            }
            .sheet(isPresented: $showStravaScan, onDismiss: {
                Task { await refreshSyncState() }
            }) {
                StravaScanSheet(activities: scanActivities)
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
            .onChange(of: filter) { _, _ in
                viewModel.selectedIDs.formIntersection(Set(filteredWorkouts.map(\.id)))
            }
        }
    }

    private var mainList: some View {
        List {
            Section {
                DateRangePickerView(preset: $viewModel.preset, customStart: $viewModel.customStart, customEnd: $viewModel.customEnd)
            }
            Section {
                ActivityListFilterView(filter: $filter)
            } header: {
                Text("筛选条件")
            } footer: {
                Text("与日期同时生效；距离和平均速度均为大于等于，留空或 0 表示不限。启用筛选后请勾选记录再自动同步。")
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
            } else if filteredWorkouts.isEmpty {
                Section {
                    ContentUnavailableView(
                        "没有符合筛选的训练",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("试试降低最短距离或最低平均速度")
                    )
                }
            } else {
                Section {
                    ForEach(filteredWorkouts) { workout in
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
                            hasVirtualPower: virtualPowerKeys.contains(
                                SyncStateStore.primaryKey(
                                    sourceId: HealthKitDataSource.sourceId,
                                    activityId: workout.id.uuidString
                                )
                            ),
                            hasSyncedFIT: syncedFITKeys.contains(
                                SyncStateStore.primaryKey(
                                    sourceId: HealthKitDataSource.sourceId,
                                    activityId: workout.id.uuidString
                                )
                            ),
                            remoteId: remoteId,
                            scanResult: stravaScans[SyncStateStore.primaryKey(sourceId: HealthKitDataSource.sourceId, activityId: workout.id.uuidString)],
                            onToggle: { viewModel.toggleSelection(workout.id) },
                            onOpenDetail: { detailWorkout = workout }
                        )
                    }
                } header: {
                    Text("\(viewModel.selectedIDs.count)/\(filteredWorkouts.count) 已选")
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
        .refreshable { showRefreshConfirmation = true }
        .confirmationDialog("重新获取活动记录？", isPresented: $showRefreshConfirmation, titleVisibility: .visible) {
            Button("确认刷新") {
                Task {
                    await viewModel.reload(forceRefresh: true)
                    await refreshSyncState()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将跳过缓存重新读取当前范围，全部历史可能耗时较长。")
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
                Button("全选") { viewModel.selectedIDs = Set(filteredWorkouts.map(\.id)) }
                Button("取消全选") { viewModel.deselectAll() }
                Button("扫描 Strava 匹配并补全 ID") {
                    scanActivities = filteredWorkouts
                        .filter { viewModel.selectedIDs.isEmpty || viewModel.selectedIDs.contains($0.id) }
                        .map { workout in
                            SourceActivity(id: workout.id.uuidString, sourceId: HealthKitDataSource.sourceId,
                                title: workout.activityName, startDate: workout.startDate, endDate: workout.endDate,
                                duration: workout.duration, distanceMeters: workout.totalDistanceMeters,
                                metadata: ["sportType": workout.activityName])
                        }
                    showStravaScan = true
                }
                .disabled(viewModel.isLoading || filteredWorkouts.isEmpty || session.isRunning)
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
                .disabled(requiresSelectionForFilteredAutoSync)
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
            ActivitySortMenu(sortOrder: $sortOrder)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                viewModel.prepareExport(syncedFITKeys: syncedFITKeys)
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.selectedIDs.isEmpty || viewModel.isLoading)
        }
    }

    private func refreshSyncState() async {
        // 刷新同步徽标、运动列表扫描标记和关联的 Strava ID。
        uploadedKeys = await SyncStateStore.shared.uploadedPrimaryKeys()
        virtualPowerKeys = await SyncStateStore.shared.virtualPowerPrimaryKeys()
        syncedFITKeys = await SyncStateStore.shared.syncedFITPrimaryKeys()
        localRemoteIds = await SyncStateStore.shared.localRemoteIdsByPrimaryKey()
        stravaScans = await SyncStateStore.shared.stravaScansByPrimaryKey()
    }
}

struct WorkoutRowView: View {
    let workout: WorkoutSummary
    let isSelected: Bool
    let isSynced: Bool
    let hasVirtualPower: Bool
    let hasSyncedFIT: Bool
    let remoteId: String?
    var scanResult: StravaScanResult? = nil
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
                                if hasVirtualPower {
                                    Text("虚拟功率")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.blue)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.12), in: Capsule())
                                }
                                if hasSyncedFIT {
                                    Text("同步 FIT")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.teal)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(.teal.opacity(0.12), in: Capsule())
                                }
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
                StravaScanResultLine(result: scanResult)
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
