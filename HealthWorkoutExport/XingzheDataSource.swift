import Foundation

/// 行者数据源：账号密码登录网页会话，列活动并用 stream 编 FIT（无需开发者 API）。
final class XingzheDataSource: WorkoutDataSource, @unchecked Sendable {
    static let sourceId = "xingzhe"

    let id = XingzheDataSource.sourceId
    let displayName = "行者"
    let requiresLogin = true

    private let client = XingzheClient()
    private let accountKey = "xingzhe.account"
    private let passwordKey = "xingzhe.password"
    private let sessionKey = "xingzhe.session"

    func isAuthenticated() async -> Bool {
        if await client.isLoggedIn { return true }
        if let sid = KeychainStore.get(account: sessionKey), !sid.isEmpty {
            await client.restore(sessionId: sid)
            return true
        }
        if let account = KeychainStore.get(account: accountKey),
           let password = KeychainStore.get(account: passwordKey),
           !account.isEmpty, !password.isEmpty {
            do {
                try await login(credentials: SourceCredentials(account: account, password: password))
                return true
            } catch {
                return false
            }
        }
        return false
    }

    func login(credentials: SourceCredentials) async throws {
        // 调用 XingzheClient.login：RSA 加密密码换 sessionid。
        try await client.login(account: credentials.account, password: credentials.password)
        KeychainStore.set(credentials.account, account: accountKey)
        KeychainStore.set(credentials.password, account: passwordKey)
        if let sid = await client.currentSessionId() {
            KeychainStore.set(sid, account: sessionKey)
        }
        // 清理旧 OAuth 残留。
        KeychainStore.delete(account: "xingzhe.clientId")
        KeychainStore.delete(account: "xingzhe.clientSecret")
        KeychainStore.delete(account: "xingzhe.accessToken")
        KeychainStore.delete(account: "xingzhe.refreshToken")
    }

    func logout() async {
        await client.clearSession()
        KeychainStore.delete(account: accountKey)
        KeychainStore.delete(account: passwordKey)
        KeychainStore.delete(account: sessionKey)
    }

    func listActivities(from: Date, to: Date) async throws -> [SourceActivity] {
        guard await isAuthenticated() else { throw WorkoutDataSourceError.notAuthenticated }
        // 调用 listWorkouts：网页会话拉活动列表。
        let workouts = try await client.listWorkouts(from: from, to: to)
        return workouts.map { w in
            SourceActivity(
                id: w.id,
                sourceId: id,
                title: w.title,
                startDate: w.startDate,
                endDate: w.endDate,
                duration: w.duration,
                distanceMeters: w.distanceMeters
            )
        }
    }

    func fetchFitData(for activity: SourceActivity) async throws -> Data {
        guard await isAuthenticated() else { throw WorkoutDataSourceError.notAuthenticated }
        // 调用 fetchFitData：stream → FIT。
        return try await client.fetchFitData(
            workoutId: activity.id,
            title: activity.title,
            startDate: activity.startDate,
            duration: activity.duration,
            distanceMeters: activity.distanceMeters
        )
    }
}
