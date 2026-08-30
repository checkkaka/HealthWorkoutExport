import Charts
import MapKit
import SwiftUI

struct SyncPreviewView: View {
    let prompt: SyncPreviewPrompt
    let onDecision: (SyncPreviewDecision) -> Void

    @State private var supplementSelections: [String: String] = [:]

    private var prepared: PreparedFIT { prompt.preparedFIT }
    private var visibleIssues: [FITQualityIssue] {
        var ids = Set<String>()
        return prepared.qualityIssues.filter { ids.insert($0.id).inserted }
            .sorted { $0.severity > $1.severity }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    mapSection
                    summarySection
                    qualitySection
                    supplementSection
                    chartsSection
                    actionSection
                }
                .padding()
            }
            .navigationTitle(prompt.activity.title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("停止整批", role: .destructive) { onDecision(.stopBatch) }
                }
            }
            .onAppear {
                supplementSelections = Dictionary(uniqueKeysWithValues: prompt.candidateGroups.map {
                    ($0.sourceId, $0.selectedActivityId ?? "")
                })
            }
        }
    }

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("轨迹预览").font(.headline)
            TrackMapView(
                baseLayer: .openStreetMap,
                lines: previewLines,
                contentID: previewContentID,
                height: 320
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 16) {
                legend("原始主源", color: .orange)
                legend("最终上传", color: .blue)
                if !prepared.supplementInspections.isEmpty {
                    legend("补源", color: .gray)
                }
            }
            .font(.caption)
        }
    }

    private var originalCoordinates: [CLLocationCoordinate2D] {
        TrackMapProjection.coordinates(
            prepared.originalInspection.displayTrack(),
            sourceIsGCJ: prepared.report.convertedCoordinateCount > 0
        )
    }

    private var finalCoordinates: [CLLocationCoordinate2D] {
        TrackMapProjection.coordinates(prepared.finalInspection.displayTrack(), sourceIsGCJ: false)
    }

    private var previewLines: [TrackMapLine] {
        var lines = [
            TrackMapLine(id: "original", coordinates: originalCoordinates, color: .systemOrange),
            TrackMapLine(id: "final", coordinates: finalCoordinates, color: .systemBlue)
        ]
        lines += prepared.supplementInspections.enumerated().map { index, source in
            TrackMapLine(
                id: "supplement-\(index)",
                coordinates: TrackMapProjection.coordinates(
                    source.inspection.displayTrack(),
                    sourceIsGCJ: false
                ),
                color: .systemGray
            )
        }
        return lines
    }

    private var previewContentID: String {
        let supplementIDs = prepared.selectedSupplements.map {
            "\($0.sourceId):\($0.candidate.activity.id)"
        }.joined(separator: ",")
        return "preview-\(prompt.activity.id)-\(prepared.report.convertedCoordinateCount)-\(supplementIDs)"
    }

    private func legend(_ title: String, color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Capsule().fill(color).frame(width: 20, height: 4)
        }
    }

    private var summarySection: some View {
        let original = prepared.originalInspection.summary
        let final = prepared.finalInspection.summary
        return VStack(alignment: .leading, spacing: 8) {
            Text("完整审计摘要").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow { Text(""); Text("原始"); Text("最终") }
                    .foregroundStyle(.secondary)
                GridRow { Text("记录"); Text("\(original.recordCount)"); Text("\(final.recordCount)") }
                GridRow { Text("GPS"); Text("\(original.gpsCount)"); Text("\(final.gpsCount)") }
                GridRow { Text("心率"); Text("\(original.heartRateCount)"); Text("\(final.heartRateCount)") }
                GridRow { Text("踏频"); Text("\(original.cadenceCount)"); Text("\(final.cadenceCount)") }
                GridRow { Text("功率"); Text("\(original.powerCount)"); Text("\(final.powerCount)") }
                GridRow {
                    Text("距离")
                    Text(String(format: "%.2f km", original.distanceMeters / 1_000))
                    Text(String(format: "%.2f km", final.distanceMeters / 1_000))
                }
            }
            .font(.subheadline.monospacedDigit())
            Text("地图最多显示 2000 点；上表和质量规则始终检查全部记录。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("质量体检").font(.headline)
            if visibleIssues.isEmpty {
                Label("未发现异常", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(visibleIssues) { issue in
                    HStack(alignment: .top) {
                        Image(systemName: issue.severity == .error
                              ? "xmark.octagon.fill"
                              : issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .foregroundStyle(issue.severity == .error
                                             ? .red : issue.severity == .warning ? .orange : .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title).font(.subheadline.weight(.semibold))
                            Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !prepared.fieldSources.isEmpty {
                Divider()
                ForEach(FITSeriesKind.allCases) { kind in
                    if let source = prepared.fieldSources[kind] {
                        LabeledContent(kind.title, value: source)
                            .font(.caption)
                    }
                }
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var supplementSection: some View {
        if !prompt.candidateGroups.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("补源选择").font(.headline)
                ForEach(prompt.candidateGroups) { group in
                    Picker(group.sourceName, selection: Binding(
                        get: { supplementSelections[group.sourceId] ?? "" },
                        set: { supplementSelections[group.sourceId] = $0 }
                    )) {
                        Text("不使用该补源").tag("")
                        ForEach(group.candidates) { candidate in
                            Text("\(candidate.activity.startDate.formatted(date: .omitted, time: .shortened)) · \(candidate.reason) · \(Int(candidate.score * 100))分")
                                .tag(candidate.activity.id)
                        }
                    }
                }
                Button("按当前补源重新生成") { onDecision(.rebuild(supplementSelections)) }
                    .buttonStyle(.bordered)
            }
            .cardStyle()
        }
    }

    private var chartsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("数据曲线").font(.headline)
            ForEach(FITSeriesKind.allCases) { kind in
                let points = prepared.finalInspection.displaySeries(kind)
                if !points.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(kind.title)（\(kind.unit)）").font(.subheadline.weight(.semibold))
                        Chart(points) { point in
                            LineMark(
                                x: .value("时间", point.date),
                                y: .value(kind.title, point.value)
                            )
                            .interpolationMethod(.linear)
                        }
                        .frame(height: 150)
                    }
                }
            }
        }
        .cardStyle()
    }

    private var actionSection: some View {
        VStack(spacing: 10) {
            if prepared.hasErrors {
                Label("存在错误，不能上传或强制上传", systemImage: "hand.raised.fill")
                    .foregroundStyle(.red)
            } else if prepared.hasWarnings {
                Button("确认警告并强制上传") { onDecision(.forceUpload) }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            } else {
                Button("确认上传") { onDecision(.upload) }
                    .buttonStyle(.borderedProminent)
            }
            Button("跳过此条") { onDecision(.skip) }
                .buttonStyle(.bordered)
            Button("停止整批", role: .destructive) { onDecision(.stopBatch) }
        }
        .frame(maxWidth: .infinity)
    }
}

private extension View {
    func cardStyle() -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
