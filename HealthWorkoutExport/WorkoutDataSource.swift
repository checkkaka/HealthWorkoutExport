import Foundation

/// 第三方源登录凭证（账号密码）。
struct SourceCredentials: Sendable, Equatable {
    var account: String
    var password: String
}

/// 跨数据源统一的活动摘要，供列表展示与同步匹配。
struct SourceActivity: Identifiable, Hashable, Sendable {
    /// 稳定业务 ID（健康用 UUID，行者/顽鹿用平台 ID）。
    let id: String
    let sourceId: String
    let title: String
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let distanceMeters: Double?
    /// 源侧原始载荷（如下载 URL 提示），仅本机使用。
    var metadata: [String: String]

    init(
        id: String,
        sourceId: String,
        title: String,
        startDate: Date,
        endDate: Date,
        duration: TimeInterval,
        distanceMeters: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sourceId = sourceId
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.distanceMeters = distanceMeters
        self.metadata = metadata
    }
}

enum WorkoutDataSourceError: LocalizedError {
    case notAuthenticated
    case loginFailed(String)
    case fetchFailed(String)
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "请先登录该数据源"
        case .loginFailed(let message): return message
        case .fetchFailed(let message): return message
        case .unsupported: return "当前数据源不支持此操作"
        }
    }
}

/// 可插拔运动数据源（对应 Java interface）：登录、列活动、拉 FIT。
protocol WorkoutDataSource: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var requiresLogin: Bool { get }

    func isAuthenticated() async -> Bool
    func login(credentials: SourceCredentials) async throws
    func logout() async
    func listActivities(from: Date, to: Date) async throws -> [SourceActivity]
    func fetchFitData(for activity: SourceActivity) async throws -> Data
}

/// 数据源注册表：Tab 与同步引擎只依赖此处，后续加源只注册实现。
@MainActor
final class DataSourceRegistry {
    static let shared = DataSourceRegistry()

    let healthKit: HealthKitDataSource
    let xingzhe: XingzheDataSource
    let onelap: OnelapDataSource

    var all: [any WorkoutDataSource] { [healthKit, xingzhe, onelap] }

    private init() {
        let health = HealthKitService()
        healthKit = HealthKitDataSource(healthKit: health)
        xingzhe = XingzheDataSource()
        onelap = OnelapDataSource()
    }

    func source(id: String) -> (any WorkoutDataSource)? {
        all.first { $0.id == id }
    }
}

/// 同步历史时间范围：快捷项含「全部」+ 自定义。
enum SyncHistoryRange: String, CaseIterable, Identifiable {
    case days7
    case days30
    case days90
    case all
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .days7: return "近7天"
        case .days30: return "近30天"
        case .days90: return "近90天"
        case .all: return "全部"
        case .custom: return "自定义"
        }
    }

    /// 解析为半开区间 [start, end)。「全部」用 2000-01-01 起，由各源自行截断。
    func resolve(customStart: Date, customEnd: Date, now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let end = now
        switch self {
        case .days7:
            return (calendar.date(byAdding: .day, value: -7, to: end) ?? end, end)
        case .days30:
            return (calendar.date(byAdding: .day, value: -30, to: end) ?? end, end)
        case .days90:
            return (calendar.date(byAdding: .day, value: -90, to: end) ?? end, end)
        case .all:
            var comps = DateComponents()
            comps.year = 2000
            comps.month = 1
            comps.day = 1
            return (calendar.date(from: comps) ?? end, end)
        case .custom:
            let start = min(customStart, customEnd)
            let endDay = max(customStart, customEnd)
            let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDay)) ?? endDay
            return (calendar.startOfDay(for: start), endExclusive)
        }
    }
}

enum SyncDayRange {
    /// 本地日历「今天」：[今日 00:00, 明日 00:00)。
    static func today(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        return (start, end)
    }
}
