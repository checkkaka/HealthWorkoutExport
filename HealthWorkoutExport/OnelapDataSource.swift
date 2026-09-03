import Foundation

/// 顽鹿数据源：App 内账号登录后列活动并下载 FIT。
final class OnelapDataSource: WorkoutDataSource, @unchecked Sendable {
    static let sourceId = "onelap"

    let id = OnelapDataSource.sourceId
    let displayName = "顽鹿"
    let requiresLogin = true

    private let client = OnelapClient()
    private let accountKey = "onelap.account"
    private let passwordKey = "onelap.password"
    private let tokenKey = "onelap.token"
    private let uidKey = "onelap.uid"
    private let refreshKey = "onelap.refresh"

    func isAuthenticated() async -> Bool {
        if await client.isLoggedIn { return true }
        if let token = KeychainStore.get(account: tokenKey),
           let uid = KeychainStore.get(account: uidKey),
           !token.isEmpty {
            await client.restore(
                token: token,
                uid: uid,
                refreshToken: KeychainStore.get(account: refreshKey)
            )
            return true
        }
        // 有账号密码则尝试静默重登。
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
        // 调用 OnelapClient.login：完成顽鹿签名登录。
        try await client.login(account: credentials.account, password: credentials.password)
        KeychainStore.set(credentials.account, account: accountKey)
        KeychainStore.set(credentials.password, account: passwordKey)
        await persistSnapshot()
    }

    func logout() async {
        await client.clearSession()
        KeychainStore.delete(account: accountKey)
        KeychainStore.delete(account: passwordKey)
        KeychainStore.delete(account: tokenKey)
        KeychainStore.delete(account: uidKey)
        KeychainStore.delete(account: refreshKey)
    }

    func listActivities(from: Date, to: Date) async throws -> [SourceActivity] {
        try await withFreshSession {
            let rides = try await client.listRides(from: from, to: to)
            return rides.map { ride in
                let end = ride.startTime.addingTimeInterval(max(ride.durationSeconds, 1))
                return SourceActivity(
                    id: ride.id,
                    sourceId: id,
                    title: "顽鹿骑行",
                    startDate: ride.startTime,
                    endDate: end,
                    duration: ride.durationSeconds,
                    distanceMeters: ride.distanceMeters
                )
            }
        }
    }

    func fetchFitData(for activity: SourceActivity) async throws -> Data {
        try await withFreshSession {
            try await client.downloadFit(activityId: activity.id)
        }
    }

    /// 会话失效：先 refresh_token，失败再用账号密码重登一次。
    private func withFreshSession<T>(_ body: () async throws -> T) async throws -> T {
        guard await isAuthenticated() else { throw WorkoutDataSourceError.notAuthenticated }
        do {
            return try await body()
        } catch WorkoutDataSourceError.notAuthenticated {
            try await refreshSession()
            return try await body()
        }
    }

    private func refreshSession() async throws {
        do {
            try await client.refreshAccessToken(using: KeychainStore.get(account: refreshKey))
            await persistSnapshot()
            return
        } catch {
            // refresh 没有或失败：账号密码重登。
        }
        await client.clearSession()
        KeychainStore.delete(account: tokenKey)
        KeychainStore.delete(account: uidKey)
        guard let account = KeychainStore.get(account: accountKey),
              let password = KeychainStore.get(account: passwordKey),
              !account.isEmpty, !password.isEmpty else {
            throw WorkoutDataSourceError.notAuthenticated
        }
        try await login(credentials: SourceCredentials(account: account, password: password))
    }

    private func persistSnapshot() async {
        guard let snap = await client.sessionSnapshot() else { return }
        KeychainStore.set(snap.token, account: tokenKey)
        KeychainStore.set(snap.uid, account: uidKey)
        if let refresh = snap.refreshToken, !refresh.isEmpty {
            KeychainStore.set(refresh, account: refreshKey)
        } else {
            KeychainStore.delete(account: refreshKey)
        }
    }
}
