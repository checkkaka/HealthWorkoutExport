import SwiftUI

/// 自动同步：入口 Tab 定主源；补源随主源联动；可跳过历史；进度来自 SyncSession。
struct AutoSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SyncSession.self) private var session

    /// 打开页时所在 Tab 的数据源 ID。
    var entrySourceId: String
    /// 列表已选活动；非空时只同步这些。
    var selectedActivityIds: [String]
    var selectedStart: Date?
    var selectedEnd: Date?
    /// 同步记录勾选重传的指纹；非空时走覆盖重传。
    var resyncFingerprints: [String]

    @State private var primarySourceId: String
    @State private var supplementIds: Set<String> = []
    @State private var mode: AutoSyncMode = .today
    @State private var historyRange: SyncHistoryRange = .days7
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var skipIfHistoryExists = false
    @State private var uploadToStrava = true
    @State private var writeToAppleHealth = WriteToAppleHealthSetting.enabled
    @State private var customTitle = ""
    @State private var authFlags: [String: Bool] = [:]
    @State private var showStravaSettings = false
    @State private var showSyncHistory = false
    @State private var virtualPowerEnabled = VirtualPowerSettings.enabled
    @State private var includeInertia = VirtualPowerSettings.includeInertia
    @State private var riderMassKg = VirtualPowerSettings.riderMassKg
    @State private var bikeMassKg = VirtualPowerSettings.bikeMassKg
    @State private var cda = VirtualPowerSettings.cda
    @State private var previewPolicy = SyncPreviewPolicy.saved

    private var isResync: Bool { !resyncFingerprints.isEmpty }
    private var isSelectedSync: Bool { !selectedActivityIds.isEmpty }
    private var canWriteAppleHealth: Bool {
        (isResync ? entrySourceId : primarySourceId) != HealthKitDataSource.sourceId
    }
    private var hasSyncTarget: Bool { uploadToStrava || (canWriteAppleHealth && writeToAppleHealth) }
    private var syncTargetFooter: String {
        isResync
            ? "勾选记录只使用本地已保存的 FIT；可分别传 Strava、写入健康，或同时执行。"
            : "可只写入苹果健康，或同时上传 Strava；健康里已有接近训练时会询问。"
    }

    private var sources: [any WorkoutDataSource] { DataSourceRegistry.shared.all }

    private var primarySourcePicker: some View {
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

    private var supplementSourceSection: some View {
        Section {
            ForEach(sources, id: \.id) { source in
                if source.id != primarySourceId {
                    let sourceLabel = label(for: source)
                    Toggle(isOn: Binding(
                        get: { supplementIds.contains(source.id) },
                        set: { on in
                            if on { supplementIds.insert(source.id) }
                            else { supplementIds.remove(source.id) }
                            Self.saveSupplementIds(supplementIds)
                        }
                    )) {
                        Text(sourceLabel)
                    }
                    .disabled(session.isRunning || (!(authFlags[source.id] ?? false) && source.requiresLogin))
                }
            }
        } header: {
            Text("补充数据源")
        } footer: {
            Text("默认不勾选，记住上次的选择；切换主源只会把新主源从补源里移除。未登录的源不可勾选。开「跳过历史」时改补源也不会重传已有记录（远端速度异常除外）。")
        }
    }

    private var syncTargetSection: some View {
        Section {
            Toggle("上传到 Strava", isOn: $uploadToStrava)
                .disabled(session.isRunning || !canWriteAppleHealth)
            if canWriteAppleHealth {
                Toggle("写入苹果健康", isOn: $writeToAppleHealth)
                    .disabled(session.isRunning)
                    .onChange(of: writeToAppleHealth) { _, on in
                        WriteToAppleHealthSetting.enabled = on
                        guard on else { return }
                        Task {
                            try? await DataSourceRegistry.shared.healthKit.underlyingHealthKit
                                .requestAuthorization(writeWorkouts: true)
                        }
                    }
            }
        } header: {
            Text("同步目标")
        } footer: {
            Text(syncTargetFooter)
        }
    }

    init(
        entrySourceId: String,
        selectedActivityIds: [String] = [],
        selectedStart: Date? = nil,
        selectedEnd: Date? = nil,
        resyncFingerprints: [String] = [],
        initialPreviewPolicy: SyncPreviewPolicy? = nil
    ) {
        self.entrySourceId = entrySourceId
        self.selectedActivityIds = selectedActivityIds
        self.selectedStart = selectedStart
        self.selectedEnd = selectedEnd
        self.resyncFingerprints = resyncFingerprints
        _primarySourceId = State(initialValue: entrySourceId)
        _previewPolicy = State(initialValue: initialPreviewPolicy ?? .saved)
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

                if uploadToStrava {
                    Section {
                        TextField("自定义标题（可选）", text: $customTitle)
                            .disabled(session.isRunning)
                    } header: {
                        Text("Strava 标题")
                    } footer: {
                        Text("填写则本批全部用这个标题。留空：通勤自动改成「通勤🚲」，其它用数据源原名。虚拟功率说明会接到活动描述末尾（需 API）。")
                    }
                }

                if isSelectedSync, !isResync {
                    Section {
                        Text("将同步列表已选 \(selectedActivityIds.count) 条，不再按当天/历史范围。")
                            .font(.footnote)
                    }
                }

                if !isResync {
                if !isSelectedSync {
                Section("主数据源") {
                    primarySourcePicker
                }
                }

                supplementSourceSection

                Section {
                    Toggle("自动跳过已有同步记录的活动", isOn: $skipIfHistoryExists)
                        .disabled(session.isRunning)
                } footer: {
                    Text("开启：本地已同步（含同指纹/同主活动/开始+距离近似）则跳过；异常速度（摘要/最佳成绩≥\(Int(StravaSpeedAnomaly.maxSpeedKmh))，或峰值≥\(Int(StravaSpeedAnomaly.maxSpeedKmh))且均速≥\(Int(StravaSpeedAnomaly.averageSpeedKmh))）仍会重传（需 API）。关闭：本地一律不跳，远端已有会弹窗问你跳过或覆盖。")
                }

                Section {
                    Picker("上传前确认", selection: $previewPolicy) {
                        ForEach(SyncPreviewPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(session.isRunning)
                } footer: {
                    Text("仅异常确认：出现警告、错误或补源匹配不明确时暂停；每条确认：每个最终 FIT 都先看地图和曲线。选择会自动记住。")
                }

                if !isSelectedSync {
                Section("同步模式") {
                    Picker("模式", selection: $mode) {
                        ForEach(AutoSyncMode.allCases, id: \.rawValue) { m in
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
                }

                }

                syncTargetSection

                Section("Strava") {
                    Text("当前模式：\(StravaSettings.mode.title)")
                    Button("Strava 设置") { showStravaSettings = true }
                    if !isResync {
                        Button("同步记录") { showSyncHistory = true }
                    }
                }

                if primarySourceId != KeepDataSource.sourceId {
                Section {
                    Toggle("虚拟功率（估算并覆盖）", isOn: $virtualPowerEnabled)
                        .disabled(session.isRunning)
                    if virtualPowerEnabled {
                        Toggle("计入惯性（加速/减速）", isOn: $includeInertia)
                            .disabled(session.isRunning)
                        HStack {
                            Text("骑手重量 kg")
                            TextField("70", value: $riderMassKg, format: .number.precision(.fractionLength(1)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                        .disabled(session.isRunning)
                        HStack {
                            Text("车重 kg")
                            TextField("8.5", value: $bikeMassKg, format: .number.precision(.fractionLength(1)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                        .disabled(session.isRunning)
                        HStack {
                            Text("CdA m²")
                            TextField("0.3", value: $cda, format: .number.precision(.fractionLength(3)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                        .disabled(session.isRunning)
                    }
                } header: {
                    Text("虚拟功率")
                } footer: {
                    Text("开启后对骑行 FIT 一律用 Gribble + Open-Meteo 估算原生 power，并覆盖已有功率计/补源功率。心率不参与计算；踏频低于 30 时按滑行记 0 W。Crr 固定 0.005，传动损失固定 2%。关闭「计入惯性」后均功率通常略低、更稳，尖峰也会明显下降。虚拟功率说明接到描述末尾；网页上传同请求无法写标题/描述。")
                }

                } else {
                    Section {
                        Text("Keep 跑步保留跑步类型，不标记骑行通勤、不估算骑行功率；导出的轨迹已转换为 WGS-84，不会重复纠偏。")
                    }
                }

                if primarySourceId == XingzheDataSource.sourceId {
                    Section {
                        Text("提示：行者轨迹一般已是 WGS，通常不必打开「上传前 GCJ-02 → WGS-84」；打开开关仍会按开关转换。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if primarySourceId == HealthKitDataSource.sourceId {
                    Section {
                        Text("主源为苹果健康：上传前始终不做 GCJ-02 → WGS-84 转换（HealthKit 轨迹已是 WGS，设置开关对此不生效）。")
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
                    if !isResync, session.wasInterrupted, !session.isRunning, session.lastJob != nil {
                        Button("继续上次同步") {
                            session.resume()
                        }
                        Button("整批重试") {
                            session.retryBatch()
                        }
                    }
                    Button("开始同步") {
                        startSync()
                    }
                    .disabled(session.isRunning || !hasSyncTarget || (!isResync && !(authFlags[primarySourceId] ?? false)))
                }
            }
            .navigationTitle(isResync ? "勾选重传" : "自动同步")
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
                loadSavedSupplements()
            }
            .onChange(of: virtualPowerEnabled) { _, _ in persistVirtualPowerSettings() }
            .onChange(of: includeInertia) { _, _ in persistVirtualPowerSettings() }
            .onChange(of: riderMassKg) { _, _ in persistVirtualPowerSettings() }
            .onChange(of: bikeMassKg) { _, _ in persistVirtualPowerSettings() }
            .onChange(of: cda) { _, _ in persistVirtualPowerSettings() }
            .onChange(of: previewPolicy) { _, value in SyncPreviewPolicy.saved = value }
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

    private static let supplementSourceIdsKey = "autoSync.supplementSourceIds"

    private static var savedSupplementIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: supplementSourceIdsKey) ?? [])
    }

    private static func saveSupplementIds(_ ids: Set<String>) {
        UserDefaults.standard.set(ids.sorted(), forKey: supplementSourceIdsKey)
    }

    /// 打开页面：载入上次选择的补源，并剔除当前主源和未登录源（默认为空）。
    private func loadSavedSupplements() {
        supplementIds = Self.savedSupplementIds.filter { id in
            guard let source = sources.first(where: { $0.id == id }), id != primarySourceId else { return false }
            return !source.requiresLogin || (authFlags[source.id] ?? false)
        }
    }

    /// 主源变更后：仅把新主源从补源里移除，其余保持上次选择。
    private func applySupplementLinkage() {
        guard supplementIds.remove(primarySourceId) != nil else { return }
        Self.saveSupplementIds(supplementIds)
    }

    private func startSync() {
        persistVirtualPowerSettings()
        WriteToAppleHealthSetting.enabled = writeToAppleHealth
        let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? nil : trimmed
        if isResync {
            session.startResync(
                fingerprints: resyncFingerprints,
                customTitle: title,
                uploadToStrava: uploadToStrava,
                writeToAppleHealth: canWriteAppleHealth && writeToAppleHealth
            )
            return
        }
        let job = SyncJobConfig(
            primarySourceId: primarySourceId,
            supplementSourceIds: Array(supplementIds),
            mode: mode,
            historyRange: historyRange,
            customStart: customStart,
            customEnd: customEnd,
            skipIfHistoryExists: skipIfHistoryExists,
            selectedActivityIds: selectedActivityIds,
            selectedStart: selectedStart,
            selectedEnd: selectedEnd,
            customTitle: title,
            previewPolicy: previewPolicy,
            uploadToStrava: uploadToStrava,
            writeToAppleHealth: primarySourceId != HealthKitDataSource.sourceId && writeToAppleHealth
        )
        // 调用 SyncSession.start：App 级会话执行同步。
        session.start(job)
    }

    /// 把表单中的虚拟功率开关与开放参数写入 UserDefaults。
    private func persistVirtualPowerSettings() {
        VirtualPowerSettings.enabled = virtualPowerEnabled
        VirtualPowerSettings.includeInertia = includeInertia
        VirtualPowerSettings.riderMassKg = riderMassKg
        VirtualPowerSettings.bikeMassKg = bikeMassKg
        VirtualPowerSettings.cda = cda
    }
}
