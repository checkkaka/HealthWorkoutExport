import Foundation

/// 虚拟功率写入 Strava 活动描述的固定社交文案（用户确认稿）。
enum VirtualPowerSocialCopy {
    /// 虚拟功率写入成功后附到活动 description（API 上传生效）。
    static let activityDescription =
        "功率计还在许愿清单里，本场瓦特是风、坡和速度一起算的，看看就好～（出自 HealthWorkoutExport）"

    /// 把虚拟功率说明接到已有描述末尾；已含则不重复。
    static func appended(to existing: String?) -> String {
        let note = activityDescription
        let current = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if current.isEmpty { return note }
        if current.contains(note) { return current }
        return current + "\n\n" + note
    }
}
