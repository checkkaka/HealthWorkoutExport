import Charts
import SwiftUI

/// 活动详情按需下载原始 FIT，并可与本机保存的最终同步版对比。
struct ActivityDetailSheet: View {
    let title: String
    let sourceId: String
    let activityId: String
    let startDate: Date
    let endDate: Date?
    let duration: TimeInterval
    let distanceMeters: Double?
    let isSynced: Bool
    let activityTypeName: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(SyncSession.self) private var session
    @State private var selectedVersion = Version.original
    @State private var originalInspection: FITInspection?
    @State private var syncedInspection: FITInspection?
    @State private var originalExportURL: URL?
    @State private var syncedExportURL: URL?
    @State private var latestSyncRecord: SyncStateRecord?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var showSyncPreview = false
    @State private var showOverwriteConfirmation = false

    private enum Version: String, CaseIterable, Identifiable {
        case original
        case synced
        var id: String { rawValue }
        var title: String { self == .original ? "原始文件" : "Strava 同步版" }
    }

    private var inspection: FITInspection? {
        selectedVersion == .original ? originalInspection : syncedInspection
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("正在读取 FIT…")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            basicSection
                            versionSection
                            if let inspection {
                                mapSection(inspection)
                                qualitySection(inspection)
                                chartSection(inspection)
                            }
                            actionSection
                            if let errorMessage {
                                Text(errorMessage).foregroundStyle(.red).font(.footnote)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("活动详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await loadFITs() }
            .sheet(isPresented: $showSyncPreview) {
                AutoSyncView(
                    entrySourceId: sourceId,
                    selectedActivityIds: [activityId],
                    selectedStart: startDate,
                    selectedEnd: endDate ?? startDate.addingTimeInterval(duration),
                    initialPreviewPolicy: .everyActivity
                )
            }
            .confirmationDialog(
                "确认重新生成并覆盖？",
                isPresented: $showOverwriteConfirmation,
                titleVisibility: .visible
            ) {
                if let record = latestSyncRecord {
                    Button("覆盖 Strava 活动", role: .destructive) {
                        session.startResync(fingerprints: [record.fingerprint])
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("覆盖会删除原 Strava 活动，已有点赞、评论和照片可能丢失。最终 FIT 会先保存恢复文件，再删除和上传。")
            }
        }
    }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.title3.weight(.semibold))
            if let activityTypeName { LabeledContent("类型", value: activityTypeName) }
            LabeledContent("数据源", value: sourceId)
            LabeledContent("开始", value: startDate.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("时长", value: durationText(duration))
            if let distanceMeters {
                LabeledContent("距离", value: String(format: "%.2f 公里", distanceMeters / 1_000))
            }
        }
        .detailCard()
    }

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("文件版本", selection: $selectedVersion) {
                Text("原始文件").tag(Version.original)
                if syncedInspection != nil { Text("Strava 同步版").tag(Version.synced) }
            }
            .pickerStyle(.segmented)
            if selectedVersion == .synced {
                Text("这是上传成功时本机保存的最终字节；原始 FIT 从未被覆盖。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .detailCard()
    }

    private func mapSection(_ inspection: FITInspection) -> some View {
        let originalIsGCJ = selectedVersion == .original && originalUsesGCJCoordinates
        let coordinates = TrackMapProjection.coordinates(
            inspection.displayTrack(),
            sourceIsGCJ: originalIsGCJ
        )
        let baseLayer: TrackMapBaseLayer = selectedVersion == .original ? .china : .openStreetMap
        return VStack(alignment: .leading, spacing: 8) {
            Text("地图").font(.headline)
            TrackMapView(
                baseLayer: baseLayer,
                lines: [.init(
                    id: selectedVersion.rawValue,
                    coordinates: coordinates,
                    color: selectedVersion == .original ? .systemOrange : .systemBlue
                )],
                contentID: "detail-\(selectedVersion.rawValue)-\(inspection.summary.gpsCount)-\(originalIsGCJ)",
                height: 300
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(selectedVersion == .original
                 ? "原始 \(originalIsGCJ ? "GCJ-02" : "WGS-84") · 国内底图"
                 : "WGS-84 · OpenStreetMap")
                .font(.caption).foregroundStyle(.secondary)
            Text("展示抽样最多 2000 点；质量体检使用全部 \(inspection.summary.recordCount) 条记录。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .detailCard()
    }

    private var syncAppliedGCJConversion: Bool {
        latestSyncRecord?.message?.contains("个 GCJ 坐标点") == true
    }

    private var originalUsesGCJCoordinates: Bool {
        latestSyncRecord == nil ? StravaSettings.gcjCorrectionEnabled : syncAppliedGCJConversion
    }

    private func qualitySection(_ inspection: FITInspection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("质量与字段覆盖").font(.headline)
            LabeledContent("GPS", value: "\(inspection.summary.gpsCount)/\(inspection.summary.recordCount)")
            LabeledContent("心率", value: "\(inspection.summary.heartRateCount)/\(inspection.summary.recordCount)")
            LabeledContent("踏频", value: "\(inspection.summary.cadenceCount)/\(inspection.summary.recordCount)")
            LabeledContent("功率", value: "\(inspection.summary.powerCount)/\(inspection.summary.recordCount)")
            ForEach(FITSeriesKind.allCases) { kind in
                if !(inspection.series[kind] ?? []).isEmpty {
                    LabeledContent("\(kind.title)来源", value: fieldSource(for: kind))
                }
            }
            ForEach(inspection.issues) { issue in
                Label {
                    VStack(alignment: .leading) {
                        Text(issue.title)
                        Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: issue.severity == .error
                          ? "xmark.octagon.fill"
                          : issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                }
                .foregroundStyle(issue.severity == .error ? .red : issue.severity == .warning ? .orange : .blue)
            }
        }
        .detailCard()
    }

    private func chartSection(_ inspection: FITInspection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("五项曲线").font(.headline)
            ForEach(FITSeriesKind.allCases) { kind in
                let points = inspection.displaySeries(kind)
                if !points.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(kind.title)（\(kind.unit)）").font(.subheadline.weight(.semibold))
                        Chart(points) { point in
                            LineMark(
                                x: .value("时间", point.date),
                                y: .value(kind.title, point.value)
                            )
                        }
                        .frame(height: 140)
                    }
                }
            }
        }
        .detailCard()
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("操作").font(.headline)
            if let originalExportURL {
                ShareLink(item: originalExportURL) { Label("导出原始 FIT", systemImage: "square.and.arrow.up") }
            }
            if let syncedExportURL {
                ShareLink(item: syncedExportURL) { Label("导出 Strava 同步版 FIT", systemImage: "square.and.arrow.up") }
            }
            Button { showSyncPreview = true } label: {
                Label("进入同步预览", systemImage: "map")
            }
            if latestSyncRecord != nil {
                Button(role: .destructive) {
                    showOverwriteConfirmation = true
                } label: {
                    Label("重新生成并覆盖", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if let remoteId = latestSyncRecord?.remoteId,
               StravaSpeedAnomaly.isOpenableRemoteId(remoteId),
               let url = URL(string: "https://www.strava.com/activities/\(remoteId)") {
                Link(destination: url) { Label("打开 Strava", systemImage: "safari") }
            }
        }
        .detailCard()
    }

    @MainActor
    private func loadFITs() async {
        loading = true
        defer { loading = false }
        let records = await SyncStateStore.shared.allRecords().filter {
            $0.primarySourceId == sourceId && $0.primaryActivityId == activityId
        }
        latestSyncRecord = records.first
        if let url = await SyncStateStore.shared.syncedFITURL(
            primarySourceId: sourceId,
            primaryActivityId: activityId
        ), let data = try? Data(contentsOf: url) {
            syncedInspection = FITInspector.inspect(data, name: "Strava 同步版")
            syncedExportURL = exportCopy(data, filename: "\(sourceId)-\(activityId)-strava.fit")
        }
        guard let source = DataSourceRegistry.shared.source(id: sourceId) else {
            errorMessage = "未知数据源"
            return
        }
        let activity = SourceActivity(
            id: activityId,
            sourceId: sourceId,
            title: title,
            startDate: startDate,
            endDate: endDate ?? startDate.addingTimeInterval(duration),
            duration: duration,
            distanceMeters: distanceMeters
        )
        do {
            let data = try await source.fetchFitData(for: activity)
            originalInspection = FITInspector.inspect(data, name: "原始 FIT")
            originalExportURL = exportCopy(data, filename: "\(sourceId)-\(activityId)-original.fit")
        } catch {
            errorMessage = "原始 FIT 读取失败：\(error.localizedDescription)"
            if syncedInspection != nil { selectedVersion = .synced }
        }
    }

    private func exportCopy(_ data: Data, filename: String) -> URL? {
        let safeName = filename.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func fieldSource(for kind: FITSeriesKind) -> String {
        let primary = DataSourceRegistry.shared.source(id: sourceId)?.displayName ?? sourceId
        guard selectedVersion == .synced else { return primary }
        if kind == .power, latestSyncRecord?.hasVirtualPower == true { return "虚拟功率" }
        let originalCount = originalInspection?.series[kind]?.count ?? 0
        let finalCount = syncedInspection?.series[kind]?.count ?? 0
        guard finalCount > originalCount else { return primary }
        return "\(primary) + 补源"
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "—"
    }
}

private extension View {
    func detailCard() -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
