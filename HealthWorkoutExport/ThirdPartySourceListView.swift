import SwiftUI

/// 行者/顽鹿/Keep 活动列表 Tab：未登录引导账号密码登录，已登录按时间范围列活动并可导出。
struct ThirdPartySourceListView: View {
    @Environment(SyncSession.self) private var session
    let sourceId: String

    @State private var activities: [SourceActivity] = []
    @State private var isLoading = false
    @State private var isAuthenticated = false
    @State private var errorMessage: String?
    @State private var showLogin = false
    @State private var preset: DateRangePreset = .days30
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var showAutoSync = false
    @State private var showStravaSettings = false
    @State private var showRefreshConfirmation = false
    @State private var showSyncHistory = false
    @State private var loadGeneration = 0
    @State private var uploadedKeys: Set<String> = []
    @State private var virtualPowerKeys: Set<String> = []
    @State private var syncedFITKeys: Set<String> = []
    @State private var localRemoteIds: [String: String] = [:]
    @State private var detailActivity: SourceActivity?
    @State private var exportViewModel = SourceExportViewModel()
    @State private var filter = ActivityListFilter()
    @State private var sortOrder = ActivitySortOrder()
    @State private var showStravaScan = false
    @State private var scanActivities: [SourceActivity] = []
    @State private var stravaScans: [String: StravaScanResult] = [:]

    private var filteredActivities: [SourceActivity] {
        sortOrder.sorted(
            activities.filter {
                filter.matches(distanceMeters: $0.distanceMeters, duration: $0.duration)
            },
            metric: { activity in
                switch sortOrder.key {
                case .date:
                    activity.startDate.timeIntervalSince1970
                case .distance:
                    activity.distanceMeters
                case .averageSpeed:
                    ActivitySortOrder.averageSpeedKmh(
                        distanceMeters: activity.distanceMeters,
                        duration: activity.duration
                    )
                }
            },
            date: \.startDate
        )
    }

    private var requiresSelectionForFilteredAutoSync: Bool {
        filter.isEnabled && exportViewModel.selectedIDs.isEmpty
    }

    private var source: (any WorkoutDataSource)? {
        DataSourceRegistry.shared.source(id: sourceId)
    }

    private var displayName: String {
        source?.displayName ?? sourceId
    }

    var body: some View {
        NavigationStack {
            Group {
                if !isAuthenticated {
                    ContentUnavailableView {
                        Label("未登录\(displayName)", systemImage: "person.crop.circle.badge.exclamationmark")
                    } description: {
                        Text(sourceId == KeepDataSource.sourceId
                            ? "Keep 跑步（实验性）：使用非官方接口，可能随平台变更失效。密码仅用于本次登录，不保存；账号和令牌保存在本机钥匙串。"
                            : "使用账号密码登录后可查看活动、导出并参与自动同步。凭证仅保存在本机。")
                    } actions: {
                        Button("登录\(displayName)") { showLogin = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    listContent
                }
            }
            .navigationTitle(displayName)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showLogin) {
                NavigationStack {
                    SourceLoginView(sourceName: displayName) { creds in
                        try await source?.login(credentials: creds)
                        isAuthenticated = true
                        await reload()
                    }
                }
            }
            .sheet(isPresented: $showAutoSync, onDismiss: {
                Task { await refreshSyncState() }
            }) {
                AutoSyncView(
                    entrySourceId: sourceId,
                    selectedActivityIds: Array(exportViewModel.selectedIDs),
                    selectedStart: exportViewModel.selectedActivities(from: activities).map(\.startDate).min(),
                    selectedEnd: exportViewModel.selectedActivities(from: activities).map(\.endDate).max()
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
                NavigationStack { SyncHistoryView(primarySourceId: sourceId) }
            }
            .sheet(isPresented: $exportViewModel.showExportSheet) {
                if let source {
                    SourceExportSheetView(
                        viewModel: exportViewModel,
                        source: source,
                        activities: activities
                    )
                }
            }
            .sheet(item: $detailActivity) { activity in
                ActivityDetailSheet(
                    title: activity.title,
                    sourceId: activity.sourceId,
                    activityId: activity.id,
                    startDate: activity.startDate,
                    endDate: activity.endDate,
                    duration: activity.duration,
                    distanceMeters: activity.distanceMeters,
                    isSynced: uploadedKeys.contains(
                        SyncStateStore.primaryKey(sourceId: activity.sourceId, activityId: activity.id)
                    ),
                    activityTypeName: nil
                )
            }
            .task { await refreshAuthAndLoad() }
            .onChange(of: preset) { _, _ in
                Task { await reload() }
            }
            .onChange(of: customStart) { _, _ in
                guard preset == .custom else { return }
                Task { await reload() }
            }
            .onChange(of: customEnd) { _, _ in
                guard preset == .custom else { return }
                Task { await reload() }
            }
            .onChange(of: filter) { _, _ in
                exportViewModel.selectedIDs.formIntersection(Set(filteredActivities.map(\.id)))
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                if isAuthenticated {
                    Button("全选") { exportViewModel.selectAll(from: filteredActivities) }
                    Button("取消全选") { exportViewModel.deselectAll() }
                    Divider()
                }
                Button("自动同步") { showAutoSync = true }
                    .disabled(requiresSelectionForFilteredAutoSync)
                Button("同步记录") { showSyncHistory = true }
                Button("扫描 Strava 匹配并补全 ID") {
                    scanActivities = filteredActivities.filter {
                        exportViewModel.selectedIDs.isEmpty || exportViewModel.selectedIDs.contains($0.id)
                    }
                    showStravaScan = true
                }
                .disabled(!isAuthenticated || isLoading || filteredActivities.isEmpty || session.isRunning)
                Button("Strava 设置") { showStravaSettings = true }
                if isAuthenticated {
                    Divider()
                    Button("退出登录", role: .destructive) {
                        Task {
                            loadGeneration += 1
                            isLoading = false
                            await source?.logout()
                            isAuthenticated = false
                            activities = []
                            exportViewModel.clearSelection()
                        }
                    }
                } else {
                    Button("登录\(displayName)") { showLogin = true }
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
                exportViewModel.prepareExport(from: activities, syncedFITKeys: syncedFITKeys)
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(!isAuthenticated || exportViewModel.selectedIDs.isEmpty || isLoading)
        }
    }

    private var listContent: some View {
        List {
            Section {
                DateRangePickerView(preset: $preset, customStart: $customStart, customEnd: $customEnd)
            }
            Section {
                ActivityListFilterView(filter: $filter)
            } header: {
                Text("筛选条件")
            } footer: {
                Text("与日期同时生效；距离和平均速度均为大于等于，留空或 0 表示不限。启用筛选后请勾选记录再自动同步。")
            }
            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                        Text(preset == .all ? "正在加载全部活动（分页较慢，请稍候）…" : "正在加载…")
                    }
                }
            } else if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            } else if activities.isEmpty {
                Section {
                    ContentUnavailableView("这段时间没有活动", systemImage: "tray")
                }
            } else if filteredActivities.isEmpty {
                Section {
                    ContentUnavailableView(
                        "没有符合筛选的活动",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("试试降低最短距离或最低平均速度")
                    )
                }
            } else {
                Section {
                    ForEach(filteredActivities) { activity in
                        let synced = uploadedKeys.contains(
                            SyncStateStore.primaryKey(sourceId: activity.sourceId, activityId: activity.id)
                        )
                        let remoteId = localRemoteIds[
                            SyncStateStore.primaryKey(sourceId: activity.sourceId, activityId: activity.id)
                        ]
                        SourceActivityRowView(
                            activity: activity,
                            isSelected: exportViewModel.selectedIDs.contains(activity.id),
                            isSynced: synced,
                            hasVirtualPower: virtualPowerKeys.contains(
                                SyncStateStore.primaryKey(sourceId: activity.sourceId, activityId: activity.id)
                            ),
                            hasSyncedFIT: syncedFITKeys.contains(
                                SyncStateStore.primaryKey(sourceId: activity.sourceId, activityId: activity.id)
                            ),
                            remoteId: remoteId,
                            scanResult: stravaScans[SyncStateStore.primaryKey(sourceId: activity.sourceId, activityId: activity.id)],
                            onToggle: { exportViewModel.toggleSelection(activity.id) },
                            onOpenDetail: { detailActivity = activity }
                        )
                    }
                } header: {
                    Text("\(exportViewModel.selectedIDs.count)/\(filteredActivities.count) 已选")
                }
            }

            if let exportError = exportViewModel.errorMessage, !exportViewModel.showExportSheet {
                Section {
                    Text(exportError)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { showRefreshConfirmation = true }
        .confirmationDialog("重新获取活动记录？", isPresented: $showRefreshConfirmation, titleVisibility: .visible) {
            Button("确认刷新") { Task { await reload(forceRefresh: true) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将跳过缓存重新读取当前范围，全部历史可能耗时较长。")
        }
    }

    private func refreshAuthAndLoad() async {
        isAuthenticated = await source?.isAuthenticated() ?? false
        if isAuthenticated { await reload() }
    }

    private func reload(forceRefresh: Bool = false) async {
        guard let source, isAuthenticated else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }
        let requestedPreset = preset
        let range = preset.resolve(customStart: customStart, customEnd: customEnd)
        do {
            // 「全部」复用一天内的摘要；下拉强制读取源数据。
            let list: [SourceActivity]
            if requestedPreset == .all, !forceRefresh,
               let cached: [SourceActivity] = ActivityListCache.read(sourceId) {
                list = cached
            } else {
                list = try await source.listActivities(from: range.start, to: range.end)
                guard generation == loadGeneration else { return }
                if requestedPreset == .all { ActivityListCache.write(list, key: sourceId) }
            }
            guard generation == loadGeneration else { return }
            activities = list
            // 调用 clearSelection：列表刷新后清空勾选，与健康页一致。
            exportViewModel.clearSelection()
            await refreshSyncState()
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            if let keepError = error as? KeepFailure, case .expired = keepError {
                isAuthenticated = false
            }
            if let sourceError = error as? WorkoutDataSourceError {
                switch sourceError {
                case .notAuthenticated, .loginFailed:
                    isAuthenticated = false
                default:
                    break
                }
            }
            errorMessage = error.localizedDescription
            activities = []
            exportViewModel.clearSelection()
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

/// 第三方活动行：勾选 + 详情 + 同步徽标。
private struct SourceActivityRowView: View {
    let activity: SourceActivity
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
                            Text(activity.title).font(.body.weight(.semibold))
                            if isSynced {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                            if remoteId != nil {
                                Image(systemName: activity.sourceId == KeepDataSource.sourceId ? "figure.run.circle.fill" : "bicycle.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text(activity.startDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text(durationText(activity.duration))
                            if let meters = activity.distanceMeters, meters > 0 {
                                Text(String(format: "%.2f 公里", meters / 1000))
                            }
                        }
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                StravaRemoteIDLine(remoteId: remoteId)
                StravaScanResultLine(result: scanResult)
            }
        }
        .padding(.vertical, 2)
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "—"
    }
}
