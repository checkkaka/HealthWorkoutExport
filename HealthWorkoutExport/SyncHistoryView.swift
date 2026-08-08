import SwiftUI
import UIKit

/// 本地同步记录：筛选 / 勾选重传 / 补全远端 ID；按入口主源过滤。
struct SyncHistoryView: View {
    /// 入口主数据源 ID（healthkit / xingzhe / onelap）。
    let primarySourceId: String

    @Environment(SyncSession.self) private var session

    /// 异常速度阈值文案。
    private static var anomalyRuleLabel: String {
        "摘要最高速≥\(Int(StravaSpeedAnomaly.maxSpeedKmh))，或最佳成绩≥\(Int(StravaSpeedAnomaly.maxSpeedKmh))，或峰值≥\(Int(StravaSpeedAnomaly.maxSpeedKmh))且均速≥\(Int(StravaSpeedAnomaly.averageSpeedKmh))"
    }

    @State private var records: [SyncStateRecord] = []
    @State private var confirmClear = false
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var isScanning = false
    @State private var scanProgressText = ""
    @State private var anomalies: [SpeedAnomaly] = []
    @State private var scanSkipped = 0
    @State private var isSelecting = false
    @State private var selectedFingerprints: Set<String> = []
    @State private var activeFilters: Set<HistoryFilter> = []
    @State private var isBackfilling = false
    /// 预计算批次，避免滚动时反复 Dictionary.grouping / Date.formatted。
    @State private var cachedBatches: [SyncBatchGroup] = []

    private var primaryDisplayName: String {
        DataSourceRegistry.shared.source(id: primarySourceId)?.displayName ?? primarySourceId
    }

    /// 同步记录筛选：多选为「且」。
    private enum HistoryFilter: String, CaseIterable, Identifiable, Hashable {
        case failed
        case noRemoteId
        case duplicate
        case api
        case web

        var id: String { rawValue }

        var title: String {
            switch self {
            case .failed: return "失败"
            case .noRemoteId: return "无远端 ID"
            case .duplicate: return "去重"
            case .api: return "API"
            case .web: return "网页"
            }
        }
    }

    /// 扫描命中的远端异常速度活动。
    private struct SpeedAnomaly: Identifiable {
        var id: String
        var name: String
        var maxSpeedKmh: Double
        var listedMaxSpeedKmh: Double
        var averageSpeedKmh: Double
        var startDate: Date?
        var localTitle: String?
        var hasLocalRecord: Bool
        var fromBestEffort: Bool
    }

    private var filteredRecords: [SyncStateRecord] {
        records.filter { matchesFilters($0) }
    }

    /// 当前筛选下的指纹集合。
    private var filteredFingerprints: Set<String> {
        Set(filteredRecords.map(\.fingerprint))
    }

    /// 当前筛选列表是否已全部勾选（用于「全选 / 取消全选」文案与行为）。
    private var isFilteredFullySelected: Bool {
        let ids = filteredFingerprints
        return !ids.isEmpty && selectedFingerprints == ids
    }

    var body: some View {
        List {
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
                }
            }

            Section {
                Text("只显示主源为「\(primaryDisplayName)」的本机同步记录。筛选辅助查找；勾选后可单独重传。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                filterChips

                Button {
                    Task { await backfillRemoteIds() }
                } label: {
                    if isBackfilling {
                        HStack {
                            ProgressView()
                            Text("补全远端 ID…")
                        }
                    } else {
                        Text("补全远端 ID")
                    }
                }
                .disabled(isBackfilling || session.isRunning || records.isEmpty)

                Button {
                    Task { await scanAnomalousSpeeds() }
                } label: {
                    if isScanning {
                        HStack {
                            ProgressView()
                            Text(scanProgressText.isEmpty ? "扫描中…" : scanProgressText)
                        }
                    } else {
                        Text("扫描异常速度（仅骑车）")
                    }
                }
                .disabled(isScanning)
            } footer: {
                Text("补全：开始时间差小于 2 分钟对上即写回 ID。勾选重传：有数字 ID 先网页删除再按当前通道上传，默认覆盖不弹窗。异常扫描规则：\(Self.anomalyRuleLabel) km/h。")
            }

            if isSelecting {
                Section {
                    Text("已选 \(selectedFingerprints.count)/\(filteredRecords.count) 条")
                        .font(.footnote.monospacedDigit())
                    Button(isFilteredFullySelected ? "取消全选（全部批次）" : "全选（全部批次）") {
                        toggleSelectAllFiltered()
                    }
                    .disabled(filteredRecords.isEmpty || session.isRunning)
                    Button("同步勾选") {
                        startSelectedResync()
                    }
                    .disabled(selectedFingerprints.isEmpty || session.isRunning)
                    Button("取消选择", role: .cancel) {
                        isSelecting = false
                        selectedFingerprints = []
                    }
                } header: {
                    Text("勾选重传")
                } footer: {
                    Text("顶部全选作用于当前筛选下的全部批次；各批次标题旁圆点只选该批。")
                }
            }

            if !anomalies.isEmpty {
                Section("异常速度（\(anomalies.count)）") {
                    ForEach(anomalies) { item in
                        Button {
                            openRemoteId(item.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(String(
                                    format: "峰值 %.0f · 均速 %.0f · 摘要最高速 %.0f km/h · ID %@",
                                    item.maxSpeedKmh,
                                    item.averageSpeedKmh,
                                    item.listedMaxSpeedKmh,
                                    item.id
                                ))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.red)
                                HStack(spacing: 8) {
                                    if item.hasLocalRecord {
                                        Text("有本地记录")
                                            .font(.caption2)
                                            .foregroundStyle(.tint)
                                    } else {
                                        Text("无本地记录")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if item.fromBestEffort {
                                        Text("含最佳成绩异常")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                if let local = item.localTitle, local != item.name {
                                    Text("本地：\(local)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let start = item.startDate {
                                    Text(start.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if scanSkipped > 0 || (!scanProgressText.isEmpty && !isScanning) {
                Section {
                    Text(scanProgressText.isEmpty
                         ? "未发现符合规则的异常活动"
                         : scanProgressText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if filteredRecords.isEmpty {
                ContentUnavailableView(
                    records.isEmpty
                        ? "暂无\(primaryDisplayName)同步记录"
                        : "无符合筛选的记录",
                    systemImage: "tray",
                    description: Text(
                        records.isEmpty
                            ? "仅列出主源为\(primaryDisplayName)的记录"
                            : "试试去掉部分筛选条件"
                    )
                )
            } else {
                // Section 必须直接属于 List，才能按批次独立布局而不是混成一个容器。
                ForEach(cachedBatches) { batch in
                    Section {
                        ForEach(batch.records) { record in
                            historyRow(record)
                        }
                    } header: {
                        batchHeader(batch)
                    }
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            }
            if let toast {
                Section { Text(toast).font(.footnote) }
            }
            if let result = session.lastResultText, !session.isRunning {
                Section("上次结果") {
                    Text(result).font(.footnote)
                }
            }
            if let err = session.lastError, !session.isRunning {
                Section {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .navigationTitle("\(primaryDisplayName)同步")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(isSelecting ? "完成" : "选择") {
                    if isSelecting {
                        isSelecting = false
                        selectedFingerprints = []
                    } else {
                        isSelecting = true
                    }
                }
                .disabled(records.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空", role: .destructive) { confirmClear = true }
                    .disabled(records.isEmpty)
            }
        }
        .confirmationDialog(
            "清空「\(primaryDisplayName)」主源的本地同步记录？",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                Task { await clearAll() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清本主源记录，不会删除 Strava 上的活动，也不影响其他主源。")
        }
        .task {
            await reload()
        }
        .onChange(of: session.isRunning) { _, running in
            if !running {
                Task { await reload() }
            }
        }
        .onChange(of: activeFilters) { _, _ in
            // 筛选变更：丢掉不在当前列表里的勾选，避免「看不见却被重传」。
            selectedFingerprints = selectedFingerprints.intersection(filteredFingerprints)
            rebuildBatches()
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HistoryFilter.allCases) { filter in
                    let on = activeFilters.contains(filter)
                    Button {
                        if on {
                            activeFilters.remove(filter)
                        } else {
                            activeFilters.insert(filter)
                        }
                    } label: {
                        Text(filter.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(on ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(on ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func matchesFilters(_ record: SyncStateRecord) -> Bool {
        for filter in activeFilters {
            switch filter {
            case .failed:
                if record.status != .failed { return false }
            case .noRemoteId:
                if record.hasOpenableRemoteId { return false }
            case .duplicate:
                if record.isDuplicate != true { return false }
            case .api:
                if record.uploadChannel != .api { return false }
            case .web:
                if record.uploadChannel != .web { return false }
            }
        }
        return true
    }

    private func toggleSelection(_ fingerprint: String) {
        if selectedFingerprints.contains(fingerprint) {
            selectedFingerprints.remove(fingerprint)
        } else {
            selectedFingerprints.insert(fingerprint)
        }
    }

    private func toggleSelectAllFiltered() {
        let ids = filteredFingerprints
        if isFilteredFullySelected {
            selectedFingerprints = []
        } else {
            selectedFingerprints = ids
        }
    }

    /// 单批次全选 / 取消：只动该批指纹，不影响其他批次勾选。
    private func toggleSelectBatch(_ batch: SyncBatchGroup) {
        let ids = Set(batch.records.map(\.fingerprint))
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: selectedFingerprints) {
            selectedFingerprints.subtract(ids)
        } else {
            selectedFingerprints.formUnion(ids)
        }
    }

    private func rebuildBatches() {
        cachedBatches = Self.makeBatches(from: filteredRecords)
    }

    private func startSelectedResync() {
        guard !session.isRunning else {
            toast = "已有同步在进行"
            return
        }
        // 只重传当前筛选可见且已勾选的，防止筛掉的旧勾选被带上。
        let fps = Array(selectedFingerprints.intersection(filteredFingerprints))
        guard !fps.isEmpty else {
            toast = "当前筛选下没有已勾选项"
            return
        }
        // 调用 SyncSession.startResync：只重传勾选指纹。
        session.startResync(fingerprints: fps)
        toast = "开始勾选重传 \(fps.count) 条"
    }

    private func backfillRemoteIds() async {
        guard !isBackfilling else { return }
        isBackfilling = true
        defer { isBackfilling = false }
        errorMessage = nil
        toast = nil

        let web = StravaWebUploader()
        let api = StravaAPIUploader()
        let useApi = await api.isReady()
        let useWeb = await web.isReady()
        guard useApi || useWeb else {
            errorMessage = "请先完成 Strava API 授权或网页登录"
            return
        }

        do {
            let listed: [StravaActivitySpeedInfo]
            if useApi {
                listed = try await api.fetchAllListedActivitySpeeds()
            } else {
                listed = try await web.fetchAllListedActivitySpeeds()
            }
            let remotes: [SyncRemoteIdBackfill.RemoteCandidate] = listed.compactMap { info in
                guard let start = info.startDate,
                      StravaSpeedAnomaly.isOpenableRemoteId(info.id) else { return nil }
                return .init(id: info.id, startDate: start)
            }
            let missingBefore = records.filter { !$0.hasOpenableRemoteId }.count
            // 调用 backfillRemoteIds：按开始&lt;2分钟写回缺失远端 ID。
            let filled = await SyncStateStore.shared.backfillRemoteIds(
                primarySourceId: primarySourceId,
                remotes: remotes
            )
            await reload()
            let missingAfter = records.filter { !$0.hasOpenableRemoteId }.count
            toast = "补全 \(filled) 条 · 仍缺 \(missingAfter)（补前缺 \(missingBefore)）"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isOpenableRemoteId(_ remoteId: String) -> Bool {
        StravaSpeedAnomaly.isOpenableRemoteId(remoteId)
    }

    /// 按同步批次时间归纳；无 batchAt 的旧记录用更新时间按分钟归桶。
    private static func makeBatches(from records: [SyncStateRecord]) -> [SyncBatchGroup] {
        let grouped = Dictionary(grouping: records) { record -> TimeInterval in
            let date = record.batchAt ?? record.updatedAt
            if record.batchAt != nil {
                return date.timeIntervalSince1970
            }
            return floor(date.timeIntervalSince1970 / 60) * 60
        }
        return grouped
            .map { key, items in
                let sorted = items.sorted { lhs, rhs in
                    let ls = lhs.startDate ?? lhs.updatedAt
                    let rs = rhs.startDate ?? rhs.updatedAt
                    return ls > rs
                }
                let batchDate = Date(timeIntervalSince1970: key)
                let uploaded = sorted.filter { $0.status == .uploaded }.count
                let failed = sorted.filter { $0.status == .failed }.count
                let pending = sorted.filter { $0.status == .pending }.count
                let dup = sorted.filter { $0.isDuplicate == true }.count
                var footerParts = ["共 \(sorted.count) 条"]
                let plainUploaded = max(0, uploaded - dup)
                if plainUploaded > 0 { footerParts.append("上传 \(plainUploaded)") }
                if dup > 0 { footerParts.append("去重 \(dup)") }
                if failed > 0 { footerParts.append("失败 \(failed)") }
                if pending > 0 { footerParts.append("待处理 \(pending)") }
                return SyncBatchGroup(
                    id: key,
                    header: "批次 \(batchDate.formatted(date: .abbreviated, time: .shortened))",
                    footer: footerParts.joined(separator: " · "),
                    records: sorted
                )
            }
            .sorted { $0.id > $1.id }
    }

    private struct SyncBatchGroup: Identifiable, Equatable {
        var id: TimeInterval
        var header: String
        var footer: String
        var records: [SyncStateRecord]
    }

    private func openStrava(_ record: SyncStateRecord) {
        guard let remote = record.remoteId, isOpenableRemoteId(remote) else {
            toast = "该记录没有可用的 Strava 活动 ID"
            return
        }
        openRemoteId(remote)
    }

    private func openRemoteId(_ remoteId: String) {
        guard let url = URL(string: "https://www.strava.com/activities/\(remoteId)") else {
            toast = "无法打开远端 ID \(remoteId)"
            return
        }
        toast = nil
        UIApplication.shared.open(url)
    }

    /// 扫账号全部活动。优先网页 Cookie；复查 = 摘要最高速未≥80 的活动（查最佳成绩/速度流）。
    private func scanAnomalousSpeeds() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        anomalies = []
        scanSkipped = 0
        errorMessage = nil
        toast = nil

        let localByRemote: [String: String?] = {
            var map: [String: String?] = [:]
            for record in records {
                guard let remote = record.remoteId, isOpenableRemoteId(remote) else { continue }
                if map[remote] == nil {
                    map[remote] = record.title
                }
            }
            return map
        }()

        let web = StravaWebUploader()
        let api = StravaAPIUploader()
        let useWeb = await web.isReady()
        let useApi = await api.isReady()
        guard useWeb || useApi else {
            errorMessage = "请先登录 Strava 网页（推荐，不占 API 限额）或完成 API 授权"
            scanProgressText = ""
            return
        }
        let listChannel = useWeb ? "网页" : "API"
        let detailPreferApi = useApi
        scanProgressText = detailPreferApi
            ? "列表\(listChannel) + 详情 API（最佳成绩）…"
            : "仅网页扫描（无 API 时详情用速度流兜底）…"

        var hitMap: [String: SpeedAnomaly] = [:]
        var skipped = 0

        func upsert(_ info: StravaActivitySpeedInfo, forceLocal: Bool) {
            guard info.isAnomalous else { return }
            let existing = hitMap[info.id]
            hitMap[info.id] = SpeedAnomaly(
                id: info.id,
                name: info.name,
                maxSpeedKmh: max(existing?.maxSpeedKmh ?? 0, info.maxSpeedMps * 3.6),
                listedMaxSpeedKmh: max(existing?.listedMaxSpeedKmh ?? 0, info.listedMaxSpeedMps * 3.6),
                averageSpeedKmh: max(existing?.averageSpeedKmh ?? 0, info.averageSpeedMps * 3.6),
                startDate: info.startDate ?? existing?.startDate,
                localTitle: localByRemote[info.id] ?? existing?.localTitle,
                hasLocalRecord: forceLocal || localByRemote[info.id] != nil || (existing?.hasLocalRecord ?? false),
                fromBestEffort: info.fromBestEffort || (existing?.fromBestEffort ?? false)
            )
            anomalies = hitMap.values.sorted { $0.maxSpeedKmh > $1.maxSpeedKmh }
        }

        do {
            scanProgressText = "\(listChannel)拉取骑车列表…"
            let listed: [StravaActivitySpeedInfo]
            if useWeb {
                listed = try await web.fetchAllListedActivitySpeeds()
            } else {
                listed = try await api.fetchAllListedActivitySpeeds()
            }

            var needDetail: [String] = []
            var detailSeen = Set<String>()

            for (index, info) in listed.enumerated() {
                if index % 50 == 0 {
                    scanProgressText = "\(listChannel)列表粗筛 \(index + 1)/\(listed.count)…"
                }
                upsert(info, forceLocal: false)
                let listedOk = info.listedMaxSpeedMps >= StravaSpeedAnomaly.peakThresholdMps
                if !listedOk, detailSeen.insert(info.id).inserted {
                    needDetail.append(info.id)
                }
            }

            for remoteId in localByRemote.keys where detailSeen.insert(remoteId).inserted {
                needDetail.append(remoteId)
            }

            for (index, remoteId) in needDetail.enumerated() {
                let via = detailPreferApi ? "API" : "网页"
                scanProgressText = "\(via)复查最佳成绩 \(index + 1)/\(needDetail.count)…"
                do {
                    let info: StravaActivitySpeedInfo?
                    if detailPreferApi {
                        info = try await api.fetchActivitySpeed(id: remoteId)
                    } else {
                        info = try await web.fetchActivitySpeed(id: remoteId)
                    }
                    guard let info, info.isCycling else {
                        skipped += 1
                        continue
                    }
                    upsert(info, forceLocal: localByRemote[remoteId] != nil)
                } catch StravaUploadError.rateLimited {
                    scanProgressText = "API 限速，改网页复查 \(index + 1)/\(needDetail.count)…"
                    if useWeb, let info = try? await web.fetchActivitySpeed(id: remoteId), info.isCycling {
                        upsert(info, forceLocal: localByRemote[remoteId] != nil)
                    } else {
                        try await Task.sleep(nanoseconds: 65_000_000_000)
                        if let info = try await api.fetchActivitySpeed(id: remoteId), info.isCycling {
                            upsert(info, forceLocal: localByRemote[remoteId] != nil)
                        } else {
                            skipped += 1
                        }
                    }
                }
                if index + 1 < needDetail.count {
                    try await Task.sleep(nanoseconds: detailPreferApi ? 250_000_000 : 120_000_000)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            scanSkipped = skipped
            anomalies = hitMap.values.sorted { $0.maxSpeedKmh > $1.maxSpeedKmh }
            scanProgressText = "已中断：命中 \(hitMap.count)，跳过 \(skipped)"
            return
        }

        scanSkipped = skipped
        anomalies = hitMap.values.sorted { $0.maxSpeedKmh > $1.maxSpeedKmh }
        let withLocal = anomalies.filter(\.hasLocalRecord).count
        if anomalies.isEmpty {
            scanProgressText = "未发现骑车异常（详情跳过 \(skipped)）。需 API 才能稳定读到最佳成绩。"
        } else {
            scanProgressText = "异常 \(anomalies.count)（有本地 \(withLocal)，详情跳过 \(skipped)）"
        }
    }

    private func reload() async {
        let all = await SyncStateStore.shared.allRecords()
        records = all.filter { $0.primarySourceId == primarySourceId }
        rebuildBatches()
    }

    private func remove(_ fingerprint: String) async {
        await SyncStateStore.shared.remove(fingerprint: fingerprint)
        selectedFingerprints.remove(fingerprint)
        await reload()
    }

    private func clearAll() async {
        await SyncStateStore.shared.removeAll(primarySourceId: primarySourceId)
        selectedFingerprints = []
        isSelecting = false
        await reload()
    }

        @ViewBuilder
        private func batchHeader(_ batch: SyncBatchGroup) -> some View {
            HStack(spacing: 8) {
                if isSelecting {
                    let ids = Set(batch.records.map(\.fingerprint))
                    let selectedCount = ids.intersection(selectedFingerprints).count
                    let allOn = !ids.isEmpty && selectedCount == ids.count
                    let partial = selectedCount > 0 && !allOn
                    Button {
                        toggleSelectBatch(batch)
                    } label: {
                        Image(systemName: allOn
                              ? "checkmark.circle.fill"
                              : (partial ? "circle.lefthalf.filled" : "circle"))
                            .foregroundStyle(allOn || partial ? Color.accentColor : .secondary)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(allOn ? "取消全选本批次" : "全选本批次")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(batch.header)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                    Text(batch.footer)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }

        @ViewBuilder
        private func historyRow(_ record: SyncStateRecord) -> some View {
            Button {
                if isSelecting {
                    toggleSelection(record.fingerprint)
                } else {
                    openStrava(record)
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    if isSelecting {
                        Image(systemName: selectedFingerprints.contains(record.fingerprint)
                              ? "checkmark.circle.fill"
                              : "circle")
                            .foregroundStyle(
                                selectedFingerprints.contains(record.fingerprint)
                                ? Color.accentColor
                                : .secondary
                            )
                            .padding(.top, 2)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(record.title ?? record.primaryActivityId)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            if record.isDuplicate == true {
                                Text("去重")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.15), in: Capsule())
                            }
                            if let channel = record.uploadChannel {
                                Text(channel == .api ? "API" : "网页")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tint)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                        }
                        Text(statusLine(record))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let start = record.startDate {
                            Text("活动 \(Self.activityDateText(start))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let remote = record.remoteId,
                           StravaSpeedAnomaly.isOpenableRemoteId(remote) {
                            Text("远端 ID：\(remote)\(isSelecting ? "" : " · 点按打开 Strava")")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tint)
                        } else if let remote = record.remoteId {
                            Text("远端 ID：\(remote)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("无远端 ID，无法打开 Strava")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let message = record.message, !message.isEmpty {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(record.isDuplicate == true ? .orange : .secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    Task { await remove(record.fingerprint) }
                } label: {
                    Label("删除本地", systemImage: "trash")
                }
            }
        }

        private static let activityDateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateStyle = .medium
            f.timeStyle = .short
            return f
        }()

        private static func activityDateText(_ date: Date) -> String {
            activityDateFormatter.string(from: date)
        }

        private func statusLine(_ record: SyncStateRecord) -> String {
            var parts: [String] = []
            if record.isDuplicate == true {
                parts.append("去重")
            } else {
                switch record.status {
                case .pending: parts.append("待处理")
                case .uploaded: parts.append("已上传")
                case .failed: parts.append("失败")
                }
            }
            parts.append("主源 \(record.primarySourceId)")
            if let supplements = record.supplementSourceIds, !supplements.isEmpty {
                parts.append("补源 \(supplements.joined(separator: ","))")
            }
            if let channel = record.uploadChannel {
                parts.append(channel == .api ? "API" : "网页")
            }
            return parts.joined(separator: " · ")
        }
}
