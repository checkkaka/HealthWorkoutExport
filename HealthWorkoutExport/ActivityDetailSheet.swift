import SwiftUI

/// 活动基础详情（不拉 FIT）。
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

    var body: some View {
        NavigationStack {
            List {
                Section("基本信息") {
                    LabeledContent("标题", value: title)
                    LabeledContent("数据源", value: sourceId)
                    LabeledContent("活动 ID", value: activityId)
                    if let activityTypeName {
                        LabeledContent("类型", value: activityTypeName)
                    }
                    LabeledContent("开始", value: startDate.formatted(date: .abbreviated, time: .shortened))
                    if let endDate {
                        LabeledContent("结束", value: endDate.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("时长", value: durationText(duration))
                    if let meters = distanceMeters, meters > 0 {
                        LabeledContent("距离", value: String(format: "%.2f 公里", meters / 1000))
                    }
                }
                Section("同步") {
                    Label(
                        isSynced ? "本地已有同步记录" : "尚未同步到 Strava（或记录已清除）",
                        systemImage: isSynced ? "checkmark.seal.fill" : "seal"
                    )
                    .foregroundStyle(isSynced ? .green : .secondary)
                }
            }
            .navigationTitle("活动详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
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
