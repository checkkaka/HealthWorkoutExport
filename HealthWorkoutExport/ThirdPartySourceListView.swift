import SwiftUI

/// 行者/顽鹿活动列表 Tab：未登录引导账号密码登录，已登录按时间范围列活动。
struct ThirdPartySourceListView: View {
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
    @State private var showSyncHistory = false
    @State private var loadGeneration = 0
    @State private var uploadedKeys: Set<String> = []
    @State private var detailActivity: SourceActivity?

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
                        Text("使用账号密码登录后可查看活动并参与自动同步。凭证仅保存在本机。")
                    } actions: {
                        Button("登录\(displayName)") { showLogin = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    listContent
                }
            }
            .navigationTitle(displayName)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("自动同步") { showAutoSync = true }
                        Button("同步记录") { showSyncHistory = true }
                        Button("Strava 设置") { showStravaSettings = true }
                        if isAuthenticated {
                            Divider()
                            Button("退出登录", role: .destructive) {
                                Task {
                                    await source?.logout()
                                    isAuthenticated = false
                                    activities = []
                                }
                            }
                        } else {
                            Button("登录\(displayName)") { showLogin = true }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!isAuthenticated || isLoading)
                }
            }
            .sheet(isPresented: $showLogin) {
                NavigationStack {
                    SourceLoginView(sourceName: displayName) { creds in
                        try await source?.login(credentials: creds)
                        isAuthenticated = true
                        await reload()
                    }
                }
            }
            .sheet(isPresented: $showAutoSync) {
                AutoSyncView(entrySourceId: sourceId)
            }
            .sheet(isPresented: $showStravaSettings) {
                NavigationStack { StravaSettingsView() }
            }
            .sheet(isPresented: $showSyncHistory) {
                NavigationStack { SyncHistoryView(primarySourceId: sourceId) }
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
        }
    }

    private var listContent: some View {
        List {
            Section {
                DateRangePickerView(preset: $preset, customStart: $customStart, customEnd: $customEnd)
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
            } else {
                Section("\(activities.count) 条活动") {
                    ForEach(activities) { activity in
                        let synced = uploadedKeys.contains(
                            SyncStateStore.primaryKey(sourceId: activity.sourceId, activityId: activity.id)
                        )
                        Button {
                            detailActivity = activity
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(activity.title).font(.body.weight(.semibold))
                                    if synced {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.caption)
                                            .foregroundStyle(.green)
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
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .refreshable { await reload() }
    }

    private func refreshAuthAndLoad() async {
        isAuthenticated = await source?.isAuthenticated() ?? false
        if isAuthenticated { await reload() }
    }

    private func reload() async {
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
        let range = preset.resolve(customStart: customStart, customEnd: customEnd)
        do {
            // 调用 listActivities：刷新第三方源活动列表。
            let list = try await source.listActivities(from: range.start, to: range.end)
            guard generation == loadGeneration else { return }
            activities = list
            // 调用 uploadedPrimaryKeys：刷新已同步徽标。
            uploadedKeys = await SyncStateStore.shared.uploadedPrimaryKeys()
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
            activities = []
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "—"
    }
}
