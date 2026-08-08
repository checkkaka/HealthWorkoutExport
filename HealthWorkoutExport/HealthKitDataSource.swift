import Foundation

/// Apple 健康数据源：包装现有 HealthKitService 与 FitActivityEncoder。
final class HealthKitDataSource: WorkoutDataSource, @unchecked Sendable {
    static let sourceId = "healthkit"

    let id = HealthKitDataSource.sourceId
    let displayName = "健康"
    let requiresLogin = false

    private let healthKit: HealthKitService

    init(healthKit: HealthKitService) {
        self.healthKit = healthKit
    }

    var underlyingHealthKit: HealthKitService { healthKit }

    func isAuthenticated() async -> Bool {
        healthKit.isHealthDataAvailable
    }

    func login(credentials: SourceCredentials) async throws {
        // 调用 requestAuthorization：健康源走系统授权而非账号密码。
        try await healthKit.requestAuthorization()
    }

    func logout() async {}

    func listActivities(from: Date, to: Date) async throws -> [SourceActivity] {
        // 调用 fetchWorkoutSummaries：按时间范围拉健康训练摘要。
        let summaries = try await healthKit.fetchWorkoutSummaries(from: from, to: to)
        return summaries.map { s in
            SourceActivity(
                id: s.uuid.uuidString,
                sourceId: id,
                title: s.activityName,
                startDate: s.startDate,
                endDate: s.endDate,
                duration: s.duration,
                distanceMeters: s.totalDistanceMeters,
                metadata: ["healthUUID": s.uuid.uuidString]
            )
        }
    }

    func fetchFitData(for activity: SourceActivity) async throws -> Data {
        guard let uuidString = activity.metadata["healthUUID"] ?? Optional(activity.id),
              let uuid = UUID(uuidString: uuidString) else {
            throw WorkoutDataSourceError.fetchFailed("无效的健康训练 ID")
        }
        // 调用 fetchWorkoutSummaries：用窄窗口找回摘要以便拉明细。
        let windowStart = activity.startDate.addingTimeInterval(-60)
        let windowEnd = activity.endDate.addingTimeInterval(60)
        let summaries = try await healthKit.fetchWorkoutSummaries(from: windowStart, to: windowEnd)
        guard let summary = summaries.first(where: { $0.uuid == uuid }) else {
            throw WorkoutDataSourceError.fetchFailed("未找到对应健康训练")
        }
        // 调用 fetchWorkoutBundle：拉完整样本与路线。
        let bundle = try await healthKit.fetchWorkoutBundle(for: summary)
        // 调用 FitActivityEncoder：编码为 FIT 供合并/上传。
        return try await Task.detached(priority: .userInitiated) {
            try FitActivityEncoder.encode(bundle, timeZone: .current)
        }.value
    }
}
