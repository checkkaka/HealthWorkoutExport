import Charts
import MapKit
import SwiftUI

enum RideSummaryMetric: String, CaseIterable, Identifiable {
    case distance
    case duration
    case averageSpeed
    case totalAscent
    case averageHeartRate
    case averagePower
    case maximumSpeed
    case maximumHeartRate
    case averageCadence
    case maximumPower
    case totalDescent
    case calories

    static let defaultOrder: [RideSummaryMetric] = [
        .distance, .duration, .averageSpeed, .totalAscent, .averageHeartRate, .averagePower
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .distance: "总距离"
        case .duration: "骑行时间"
        case .averageSpeed: "平均速度"
        case .totalAscent: "总爬升"
        case .averageHeartRate: "平均心率"
        case .averagePower: "平均功率"
        case .maximumSpeed: "最高速度"
        case .maximumHeartRate: "最高心率"
        case .averageCadence: "平均踏频"
        case .maximumPower: "最大功率"
        case .totalDescent: "总下降"
        case .calories: "消耗热量"
        }
    }

    var symbol: String {
        switch self {
        case .distance: "ruler"
        case .duration: "clock"
        case .averageSpeed: "gauge.with.dots.needle.50percent"
        case .maximumSpeed: "speedometer"
        case .totalAscent: "arrow.up.right"
        case .averageHeartRate: "heart"
        case .maximumHeartRate: "heart.fill"
        case .averagePower, .maximumPower: "bolt.fill"
        case .averageCadence: "circle.dotted"
        case .totalDescent: "arrow.down.right"
        case .calories: "flame.fill"
        }
    }

    var tint: Color {
        switch self {
        case .distance, .averageSpeed, .maximumSpeed: .blue
        case .duration: .indigo
        case .totalAscent, .totalDescent: .green
        case .averageHeartRate, .maximumHeartRate: .red
        case .averagePower, .maximumPower: .orange
        case .averageCadence: .purple
        case .calories: .pink
        }
    }

    func display(in summary: FITInspectionSummary) -> (value: String, unit: String) {
        func whole(_ value: Double?, unit: String) -> (String, String) {
            guard let value else { return ("—", unit) }
            return (String(format: "%.0f", value), unit)
        }

        switch self {
        case .distance:
            guard summary.hasDistance else { return ("—", "km") }
            return (String(format: "%.2f", summary.distanceMeters / 1_000), "km")
        case .duration:
            guard summary.hasDuration else { return ("—", "") }
            let total = Int(summary.durationSeconds.rounded())
            let hours = total / 3_600
            let minutes = total % 3_600 / 60
            let seconds = total % 60
            let duration = hours > 0
                ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                : String(format: "%d:%02d", minutes, seconds)
            return (duration, "")
        case .averageSpeed:
            guard let value = summary.averageSpeedKPH else { return ("—", "km/h") }
            return (String(format: "%.1f", value), "km/h")
        case .totalAscent:
            return whole(summary.totalAscentMeters, unit: "m")
        case .averageHeartRate:
            return whole(summary.averageHeartRateBPM, unit: "bpm")
        case .averagePower:
            return whole(summary.averagePowerWatts, unit: "W")
        case .maximumSpeed:
            guard summary.maximumSpeedKPH > 0 else { return ("—", "km/h") }
            return (String(format: "%.1f", summary.maximumSpeedKPH), "km/h")
        case .maximumHeartRate:
            return whole(summary.maximumHeartRateBPM, unit: "bpm")
        case .averageCadence:
            return whole(summary.averageCadenceRPM, unit: "rpm")
        case .maximumPower:
            return whole(summary.maximumPowerWatts, unit: "W")
        case .totalDescent:
            return whole(summary.totalDescentMeters, unit: "m")
        case .calories:
            guard let value = summary.totalCalories else { return ("—", "kcal") }
            return ("\(value)", "kcal")
        }
    }
}

struct RideSummaryMetricPreferences {
    private static let key = "ride_summary_metrics"
    static let didChangeNotification = Notification.Name("RideSummaryMetricPreferences.didChange")

    static func load(defaults: UserDefaults = .standard) -> [RideSummaryMetric] {
        let metrics = defaults.stringArray(forKey: key)?.compactMap(RideSummaryMetric.init(rawValue:)) ?? []
        let unique = metrics.reduce(into: [RideSummaryMetric]()) { result, metric in
            if !result.contains(metric) { result.append(metric) }
        }
        return unique.isEmpty ? RideSummaryMetric.defaultOrder : unique
    }

    static func save(_ metrics: [RideSummaryMetric], defaults: UserDefaults = .standard) {
        let unique = metrics.reduce(into: [RideSummaryMetric]()) { result, metric in
            if !result.contains(metric) { result.append(metric) }
        }
        let persisted = unique.isEmpty ? RideSummaryMetric.defaultOrder : unique
        defaults.set(persisted.map(\.rawValue), forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: defaults)
    }
}

struct SyncPreviewView: View {
    let prompt: SyncPreviewPrompt
    let onDecision: (SyncPreviewDecision) -> Void

    @ScaledMetric(relativeTo: .body) private var mapTopInset = RideOverviewLayout.mapTopInset
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
                    overviewSection
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

    private var overviewSection: some View {
        RideOverviewSection(
            summary: prepared.finalInspection.summary,
            activityTitle: prompt.activity.title,
            activityMetadata: "\(prompt.activity.startDate.formatted(date: .abbreviated, time: .shortened)) · \(prompt.activity.sourceId)"
        ) {
            TrackMapView(
                baseLayer: .openStreetMap,
                lines: previewLines,
                contentID: previewContentID,
                height: RideOverviewLayout.mapHeight,
                topContentInset: mapTopInset,
                bottomContentInset: RideOverviewLayout.mapBottomInset
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("轨迹预览").font(.headline)
                    HStack(spacing: 16) {
                        legend("原始主源", color: .orange)
                        legend("最终上传", color: .blue)
                        if !prepared.supplementInspections.isEmpty {
                            legend("补源", color: .gray)
                        }
                    }
                    .font(.caption)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(12)
            }
        }
        .padding(.horizontal, -16)
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
            Divider()
            auditDetails
        }
        .cardStyle()
    }

    private var auditDetails: some View {
        let original = prepared.originalInspection.summary
        let final = prepared.finalInspection.summary
        func distanceText(_ summary: FITInspectionSummary) -> String {
            summary.hasDistance ? String(format: "%.2f km", summary.distanceMeters / 1_000) : "—"
        }
        return DisclosureGroup("数据审计详情") {
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
                    Text(distanceText(original))
                    Text(distanceText(final))
                }
            }
            .font(.caption.monospacedDigit())
            Text("地图最多显示 2000 点；此处和质量规则始终检查全部记录。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .font(.subheadline)
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

enum RideOverviewLayout {
    static let mapHeight: CGFloat = 700
    static let panelTop: CGFloat = 410
    static let mapTopInset: CGFloat = 100
    static let mapBottomInset: CGFloat = mapHeight - panelTop + 20
}

struct RideSummarySection: View {
    let summary: FITInspectionSummary
    let activityTitle: String
    let activityMetadata: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var distanceFontSize: CGFloat = 40
    @State private var metrics = RideSummaryMetricPreferences.load()
    @State private var showingCustomization = false

    private var columnCount: Int { dynamicTypeSize.isAccessibilitySize ? 2 : 3 }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0), count: columnCount)
    }
    private var gridMetrics: [RideSummaryMetric] {
        metrics.filter { $0 != .distance }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("骑行摘要").font(.headline)
                Spacer()
                Button {
                    showingCustomization = true
                } label: {
                    Label("自定义", systemImage: "slider.horizontal.3")
                        .font(.subheadline)
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(activityTitle)
                        .font(.title3.weight(.semibold))
                    Text(activityMetadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if metrics.contains(.distance) {
                    distanceHero
                }
            }
            if !gridMetrics.isEmpty {
                LazyVGrid(columns: columns, spacing: 0) {
                    ForEach(Array(gridMetrics.enumerated()), id: \.element.id) { index, metric in
                        metricView(metric, index: index)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(
            minHeight: RideOverviewLayout.mapHeight - RideOverviewLayout.panelTop,
            alignment: .topLeading
        )
        .background(
            Color(uiColor: .systemBackground),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .shadow(color: .black.opacity(0.14), radius: 14, y: -2)
        .onChange(of: metrics) { _, newValue in
            RideSummaryMetricPreferences.save(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: RideSummaryMetricPreferences.didChangeNotification,
            object: UserDefaults.standard
        )) { _ in
            let stored = RideSummaryMetricPreferences.load()
            if stored != metrics { metrics = stored }
        }
        .sheet(isPresented: $showingCustomization) {
            RideSummaryMetricSettingsView(metrics: $metrics)
        }
    }

    private var distanceHero: some View {
        let display = RideSummaryMetric.distance.display(in: summary)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(display.value)
                .font(.system(size: distanceFontSize, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(display.unit)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("总距离 \(display.value) \(display.unit)")
    }

    private func metricView(_ metric: RideSummaryMetric, index: Int) -> some View {
        let display = metric.display(in: summary)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: metric.symbol)
                    .foregroundStyle(metric.tint)
                Text(metric.title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(display.value)
                    .font(.title3.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !display.unit.isEmpty {
                    Text(display.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .trailing) {
            if index % columnCount != columnCount - 1, index < gridMetrics.count - 1 {
                Rectangle().fill(.secondary.opacity(0.16)).frame(width: 1)
            }
        }
        .overlay(alignment: .bottom) {
            if index < gridMetrics.count - columnCount {
                Rectangle().fill(.secondary.opacity(0.16)).frame(height: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RideOverviewSection<MapContent: View>: View {
    let summary: FITInspectionSummary
    let activityTitle: String
    let activityMetadata: String
    private let mapContent: MapContent

    init(
        summary: FITInspectionSummary,
        activityTitle: String,
        activityMetadata: String,
        @ViewBuilder mapContent: () -> MapContent
    ) {
        self.summary = summary
        self.activityTitle = activityTitle
        self.activityMetadata = activityMetadata
        self.mapContent = mapContent()
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemBackground)
            mapContent
            RideSummarySection(
                summary: summary,
                activityTitle: activityTitle,
                activityMetadata: activityMetadata
            )
                .padding(.horizontal, 12)
                .padding(.top, RideOverviewLayout.panelTop)
                .zIndex(1)
        }
        .frame(minHeight: RideOverviewLayout.mapHeight, alignment: .top)
    }
}

private struct RideSummaryMetricSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var metrics: [RideSummaryMetric]

    private var hiddenMetrics: [RideSummaryMetric] {
        RideSummaryMetric.allCases.filter { !metrics.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(metrics) { metric in
                        HStack {
                            Label(metric.title, systemImage: metric.symbol)
                                .foregroundStyle(metric.tint)
                            Spacer()
                            Toggle("显示 \(metric.title)", isOn: visibilityBinding(for: metric))
                                .labelsHidden()
                                .disabled(metrics.count == 1)
                        }
                    }
                    .onMove { metrics.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("显示中")
                } footer: {
                    Text("点击编辑后可拖动排序；至少保留一个指标。")
                }

                if !hiddenMetrics.isEmpty {
                    Section("未显示") {
                        ForEach(hiddenMetrics) { metric in
                            Button {
                                metrics.append(metric)
                            } label: {
                                Label("显示 \(metric.title)", systemImage: "plus.circle")
                            }
                        }
                    }
                }

                Section {
                    Button("恢复默认") {
                        metrics = RideSummaryMetric.defaultOrder
                    }
                }
            }
            .navigationTitle("自定义骑行摘要")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func visibilityBinding(for metric: RideSummaryMetric) -> Binding<Bool> {
        Binding(
            get: { metrics.contains(metric) },
            set: { isVisible in
                if isVisible {
                    if !metrics.contains(metric) { metrics.append(metric) }
                } else if metrics.count > 1 {
                    metrics.removeAll { $0 == metric }
                }
            }
        )
    }
}

private extension View {
    func cardStyle() -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
