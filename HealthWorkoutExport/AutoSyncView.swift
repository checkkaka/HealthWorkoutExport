import SwiftUI

/// 自动同步：入口 Tab 定主源；补源随主源联动；可跳过历史；进度来自 SyncSession。
struct AutoSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SyncSession.self) private var session

    /// 打开页时所在 Tab 的数据源 ID。
    var entrySourceId: String

    @State private var primarySourceId: String
    @State private var supplementIds: Set<String> = []
    @State private var mode: AutoSyncMode = .today
    @State private var historyRange: SyncHistoryRange = .days7
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var skipIfHistoryExists = false
    @State private var authFlags: [String: Bool] = [:]
    @State private var showStravaSettings = false
    @State private var showSyncHistory = false

    private var sources: [any WorkoutDataSource] { DataSourceRegistry.shared.all }

    init(entrySourceId: String) {
        self.entrySourceId = entrySourceId
        _primarySourceId = State(initialValue: entrySourceId)
    }

    var body: some View {
        NavigationStack {
            Form {
                if session.isRunning {
                    Section {
                        ProgressView(
                            value: session.progress.total == 0
                                ? 0
                                : Double(session.progress.processed) / Double(session.progress.total)
                        ) {
                            Text(session.progress.message.isEmpty ? "同步进行中…" : session.progress.message)
                        }
                        Text("上传 \(session.progress.uploaded) · 去重 \(session.progress.deduped) · 失败 \(session.progress.failed)")
                            .font(.footnote.monospacedDigit())
                        Button("停止同步", role: .destructive) {
                            // 调用 SyncSession.cancel：打断进行中的自动同步。
                            session.cancel()
                        }
                    } header: {
                        Text("后台同步进行中")
                    } footer: {
                        Text("关闭本页后同步仍会继续；可在同步记录页查看进度。")
                    }
                }

                Section("主数据源") {
                    Picker("主源", selection: $primarySourceId) {
                        ForEach(sources, id: \.id) { source in
                            Text(label(for: source)).tag(source.id)
                        }
                    }
                    .disabled(session.isRunning)
                    .onChange(of: primarySourceId) { _, _ in
                        applySupplementLinkage()
                    }
                }

                Section {
                    ForEach(sources, id: \.id) { source in
                        if source.id != primarySourceId {
                            Toggle(isOn: Binding(
                                get: { supplementIds.contains(source.id) },
                                set: { on in
                                    if on { supplementIds.insert(source.id) }
                                    else { supplementIds.remove(source.id) }
                                }
                            )) {
                                Text(label(for: source))
                            }
                            .disabled(session.isRunning || (!(authFlags[source.id] ?? false) && source.requiresLogin))
                        }
                    }
                } header: {
                    Text("补充数据源（随主源联动）")
                } footer: {
                    Text("切换主源后，会自动勾选其余已登录源。未登录的源不可勾选。开「跳过历史」时改补源也不会重传已有记录（远端速度异常除外）。")
                }

                Section {
                    Toggle("自动跳过已有同步记录的活动", isOn: $skipIfHistoryExists)
                        .disabled(session.isRunning)
                } footer: {
                    Text("开启：本地已同步（含同指纹/同主活动/开始+距离近似）则跳过；异常速度（摘要/最佳成绩≥\(Int(StravaSpeedAnomaly.maxSpeedKmh))，或峰值≥\(Int(StravaSpeedAnomaly.maxSpeedKmh))且均速≥\(Int(StravaSpeedAnomaly.averageSpeedKmh))）仍会重传（需 API）。关闭：本地一律不跳，远端已有会弹窗问你跳过或覆盖。")
                }

                Section("同步模式") {
                    Picker("模式", selection: $mode) {
                        ForEach(AutoSyncMode.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(session.isRunning)

                    if mode == .history {
                        Picker("历史范围", selection: $historyRange) {
                            ForEach(SyncHistoryRange.allCases) { r in
                                Text(r.title).tag(r)
                            }
                        }
                        .disabled(session.isRunning)
                        if historyRange == .custom {
                            ChineseWheelDateField(title: "开始", date: $customStart, enabled: !session.isRunning)
                            ChineseWheelDateField(title: "结束", date: $customEnd, enabled: !session.isRunning)
                        }
                    }
                }

                Section("Strava") {
                    Text("当前模式：\(StravaSettings.mode.title)")
                    Button("Strava 设置") { showStravaSettings = true }
                    Button("同步记录") { showSyncHistory = true }
                }

                if primarySourceId == XingzheDataSource.sourceId
                    || primarySourceId == HealthKitDataSource.sourceId {
                    Section {
                        Text("提示：行者 / 苹果健康轨迹一般已是 WGS，通常不必打开「上传前 GCJ-02 → WGS-84」；打开开关仍会按开关转换。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !session.isRunning, session.progress.total > 0 {
                    Section("上次进度") {
                        Text(session.progress.message.isEmpty ? "—" : session.progress.message)
                        Text("上传 \(session.progress.uploaded) · 去重 \(session.progress.deduped) · 失败 \(session.progress.failed)")
                            .font(.footnote.monospacedDigit())
                    }
                }

                if let text = session.lastResultText {
                    Section("结果") { Text(text).font(.footnote) }
                }
                if let error = session.lastError {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                Section {
                    if session.wasInterrupted, !session.isRunning, session.lastJob != nil {
                        Button("继续上次同步") {
                            session.resume()
                        }
                    }
                    Button("开始同步") {
                        startSync()
                    }
                    .disabled(session.isRunning || !(authFlags[primarySourceId] ?? false))
                }
            }
            .navigationTitle("自动同步")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showStravaSettings) {
                NavigationStack { StravaSettingsView() }
            }
            .sheet(isPresented: $showSyncHistory) {
                NavigationStack { SyncHistoryView(primarySourceId: primarySourceId) }
            }
            .task {
                await refreshAuth()
                primarySourceId = entrySourceId
                applySupplementLinkage()
            }
        }
    }

    private func label(for source: any WorkoutDataSource) -> String {
        let ok = authFlags[source.id] ?? false
        if source.requiresLogin && !ok {
            return "\(source.displayName)（未登录）"
        }
        return source.displayName
    }

    private func refreshAuth() async {
        var flags: [String: Bool] = [:]
        for source in sources {
            if source.requiresLogin {
                flags[source.id] = await source.isAuthenticated()
            } else {
                flags[source.id] = true
            }
        }
        authFlags = flags
    }

    /// 主源变更后：补源 = 其余已登录源。
    private func applySupplementLinkage() {
        var next = Set<String>()
        for source in sources where source.id != primarySourceId {
            let ok = authFlags[source.id] ?? false
            if !source.requiresLogin || ok {
                next.insert(source.id)
            }
        }
        supplementIds = next
    }

    private func startSync() {
        let job = SyncJobConfig(
            primarySourceId: primarySourceId,
            supplementSourceIds: Array(supplementIds),
            mode: mode,
            historyRange: historyRange,
            customStart: customStart,
            customEnd: customEnd,
            skipIfHistoryExists: skipIfHistoryExists
        )
        // 调用 SyncSession.start：App 级会话执行同步。
        session.start(job)
    }
}
