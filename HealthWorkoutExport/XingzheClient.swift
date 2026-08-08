import Foundation
import Security
import HealthKit

/// 解析行者限流文案：`request limit exceeded, available in 1 seconds`。
enum XingzheRateLimit {
    static func waitSeconds(statusCode: Int, body: String) -> TimeInterval? {
        let lower = body.lowercased()
        let limited = statusCode == 400
            || lower.contains("request limit")
            || lower.contains("limit exceeded")
        guard limited, lower.contains("limit") else { return nil }
        return parseAvailableSeconds(body)
    }

    static func parseAvailableSeconds(_ text: String) -> TimeInterval {
        let pattern = #"available in\s+(\d+)\s+seconds?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text),
              let n = Double(text[r]) else {
            return 1.5
        }
        return max(n, 1)
    }
}

/// 行者网页会话客户端：账号密码登录拿 sessionid（对齐 WanSync / SyncOnelapToXoss），无需开发者 API。
actor XingzheClient {
    private static let loginURL = URL(string: "https://www.imxingzhe.com/api/v1/user/login/")!
    private static let listURL = "https://www.imxingzhe.com/api/v1/pgworkout/"
    private static let publicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDmuQkBbijudDAJgfffDeeIButq
    WHZvUwcRuvWdg89393FSdz3IJUHc0rgI/S3WuU8N0VePJLmVAZtCOK4qe4FY/eKm
    WpJmn7JfXB4HTMWjPVoyRZmSYjW4L8GrWmh51Qj7DwpTADadF3aq04o+s1b8LXJa
    8r6+TIqqL5WUHtRqmQIDAQAB
    -----END PUBLIC KEY-----
    """

    private var sessionId: String?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isLoggedIn: Bool { !(sessionId?.isEmpty ?? true) }

    func restore(sessionId: String) {
        self.sessionId = sessionId
    }

    func clearSession() {
        sessionId = nil
    }

    func currentSessionId() -> String? { sessionId }

    /// RSA 加密密码后 POST /api/v1/user/login/，从 Set-Cookie 取 sessionid。
    func login(account: String, password: String) async throws {
        let encrypted = try Self.encryptPassword(password)
        var request = URLRequest(url: Self.loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://www.imxingzhe.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.imxingzhe.com/user/login", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "account": account,
            "password": encrypted
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WorkoutDataSourceError.loginFailed("行者登录失败")
        }
        guard http.statusCode == 200 else {
            throw WorkoutDataSourceError.loginFailed("行者登录失败: HTTP \(http.statusCode)")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["data"] != nil else {
            throw WorkoutDataSourceError.loginFailed("行者账号或密码错误")
        }

        var sid = Self.extractSessionId(from: http)
        if sid == nil {
            sid = HTTPCookieStorage.shared.cookies(for: Self.loginURL)?
                .first(where: { $0.name == "sessionid" })?.value
        }
        guard let sid, !sid.isEmpty else {
            throw WorkoutDataSourceError.loginFailed("行者未返回 sessionid")
        }
        sessionId = sid
    }

    struct Workout: Sendable {
        let id: String
        let title: String
        let startDate: Date
        let endDate: Date
        let duration: TimeInterval
        let distanceMeters: Double?
    }

    func listWorkouts(from: Date, to: Date) async throws -> [Workout] {
        try requireAuth()
        // 一律 offset 翻页 + 请求间隔：按月打会更容易触发行者「1 秒限流」。
        return try await fetchWorkoutPages(from: from, to: to, year: nil, month: nil)
    }

    private func fetchWorkoutPages(
        from: Date,
        to: Date,
        year: Int?,
        month: Int?
    ) async throws -> [Workout] {
        var results: [Workout] = []
        var offset = 0
        let limit = 24
        let maxOffset = 5000
        var pageIndex = 0

        while offset < maxOffset {
            // 调用 paceIfNeeded：页与页之间留间隔，降低限流概率。
            if pageIndex > 0 {
                try await Task.sleep(nanoseconds: 1_200_000_000)
            }
            var urlString = "\(Self.listURL)?offset=\(offset)&limit=\(limit)"
            if let year { urlString += "&year=\(year)" }
            if let month { urlString += "&month=\(month)" }
            // 调用 getJSON：含限流自动等待重试。
            let root = try await getJSON(url: URL(string: urlString)!)
            let dataNode = (root["data"] as? [String: Any])?["data"] as? [[String: Any]]
                ?? root["data"] as? [[String: Any]]
                ?? []
            if dataNode.isEmpty { break }

            var allOlder = true
            for item in dataNode {
                let id = "\(item["id"] ?? "")"
                guard !id.isEmpty else { continue }
                let startMs = Self.asDouble(item["start_time"]) ?? 0
                guard startMs > 0 else { continue }
                let start = Date(timeIntervalSince1970: startMs / 1000)
                if start >= from { allOlder = false }
                if start < from || start >= to { continue }

                let duration = Self.asDouble(item["duration"]) ?? 0
                let distance = Self.asDouble(item["distance"])
                let title = (item["title"] as? String) ?? "行者运动"
                let end = start.addingTimeInterval(max(duration, 1))
                results.append(Workout(
                    id: id,
                    title: title,
                    startDate: start,
                    endDate: end,
                    duration: max(duration, 1),
                    distanceMeters: (distance ?? 0) > 0 ? distance : nil
                ))
            }
            offset += limit
            pageIndex += 1
            // 整页都早于 from：列表按新→旧排，后面更旧，可停。
            if allOlder || dataNode.count < limit { break }
        }
        return results.sorted { $0.startDate > $1.startDate }
    }

    /// stream → FIT（网页会话接口，无需 OpenAPI）。
    func fetchFitData(
        workoutId: String,
        title: String,
        startDate: Date,
        duration: TimeInterval,
        distanceMeters: Double?
    ) async throws -> Data {
        try requireAuth()
        let url = URL(string: "https://www.imxingzhe.com/api/v1/pgworkout/\(workoutId)/stream/")!
        let root = try await getJSON(url: url)
        let stream = root["data"] as? [String: Any] ?? root
        let bundle = try Self.buildBundle(
            workoutId: workoutId,
            title: title,
            startDate: startDate,
            duration: duration,
            distanceMeters: distanceMeters,
            stream: stream
        )
        return try await Task.detached(priority: .userInitiated) {
            try FitActivityEncoder.encode(bundle, timeZone: .current)
        }.value
    }

    private func requireAuth() throws {
        guard sessionId != nil else { throw WorkoutDataSourceError.notAuthenticated }
    }

    private func cookieHeader() -> String {
        "sessionid=\(sessionId!); _XingzheWeb_Token=true"
    }

    private func getJSON(url: URL) async throws -> [String: Any] {
        try requireAuth()
        // 限流时按服务端提示等待重试，最多 8 次。
        for attempt in 0..<8 {
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt < 7 {
                    try await Task.sleep(nanoseconds: 1_200_000_000)
                    continue
                }
                throw WorkoutDataSourceError.fetchFailed("行者网络错误：\(error.localizedDescription)")
            }
            guard let http = response as? HTTPURLResponse else {
                throw WorkoutDataSourceError.fetchFailed("行者无响应")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw WorkoutDataSourceError.notAuthenticated
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            if let wait = XingzheRateLimit.waitSeconds(statusCode: http.statusCode, body: text) {
                try await Task.sleep(nanoseconds: UInt64((wait + 0.35) * 1_000_000_000))
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw WorkoutDataSourceError.fetchFailed("行者请求失败 HTTP \(http.statusCode)：\(text.prefix(120))")
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WorkoutDataSourceError.fetchFailed("行者响应不是 JSON：\(text.prefix(120))")
            }
            let msg = (root["msg"] as? String) ?? (root["message"] as? String) ?? ""
            if let code = root["code"] as? Int, code != 0, code != 200 {
                if let wait = XingzheRateLimit.waitSeconds(statusCode: code, body: msg.isEmpty ? text : msg) {
                    try await Task.sleep(nanoseconds: UInt64((wait + 0.35) * 1_000_000_000))
                    continue
                }
                let dataEmpty = root["data"] == nil
                    || (root["data"] as? [String: Any])?.isEmpty == true
                    || (root["data"] as? [Any])?.isEmpty == true
                if dataEmpty {
                    throw WorkoutDataSourceError.fetchFailed("行者：\(msg.isEmpty ? "业务错误 \(code)" : msg)")
                }
            }
            return root
        }
        throw WorkoutDataSourceError.fetchFailed("行者请求限流，请稍后再试「全部」")
    }

    private static func extractSessionId(from http: HTTPURLResponse) -> String? {
        if let fields = http.allHeaderFields as? [String: String] {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: loginURL)
            if let sid = cookies.first(where: { $0.name == "sessionid" })?.value {
                return sid
            }
        }
        // iOS 有时把多个 Set-Cookie 合成一条。
        for (key, value) in http.allHeaderFields {
            let name = "\(key)".lowercased()
            guard name == "set-cookie" || name.contains("set-cookie") else { continue }
            if let match = "\(value)".range(of: #"sessionid=([^;,\s]+)"#, options: .regularExpression) {
                let full = String("\(value)"[match])
                return full.replacingOccurrences(of: "sessionid=", with: "")
            }
        }
        return nil
    }

    private static func encryptPassword(_ password: String) throws -> String {
        guard let secKey = publicKey() else {
            throw WorkoutDataSourceError.loginFailed("行者公钥无效")
        }
        let plain = Data(password.utf8)
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            secKey,
            .rsaEncryptionPKCS1,
            plain as CFData,
            &error
        ) as Data? else {
            throw WorkoutDataSourceError.loginFailed("行者密码加密失败")
        }
        return encrypted.base64EncodedString()
    }

    private static func publicKey() -> SecKey? {
        let lines = publicKeyPEM
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        guard let data = Data(base64Encoded: lines.joined()) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024
        ]
        return SecKeyCreateWithData(data as CFData, attrs as CFDictionary, nil)
    }

    private static func buildBundle(
        workoutId: String,
        title: String,
        startDate: Date,
        duration: TimeInterval,
        distanceMeters: Double?,
        stream: [String: Any]
    ) throws -> WorkoutBundle {
        let locations = stream["location"] as? [[Any]] ?? []
        let timestamps = (stream["timestamp"] as? [Any])?.compactMap(asDouble) ?? []
        let altitudes = (stream["altitude"] as? [Any])?.compactMap(asDouble) ?? []
        let heartrates = (stream["heartrate"] as? [Any])?.compactMap(asDouble) ?? []

        var route: [RoutePoint] = []
        var hrSamples: [TimedSample] = []
        let count = max(locations.count, timestamps.count)
        guard count > 0 else {
            throw WorkoutDataSourceError.fetchFailed("行者无轨迹点")
        }

        for i in 0..<count {
            let ts: Date
            if i < timestamps.count {
                let raw = timestamps[i]
                ts = raw > 1_000_000_000_000
                    ? Date(timeIntervalSince1970: raw / 1000)
                    : Date(timeIntervalSince1970: raw)
            } else {
                ts = startDate.addingTimeInterval(Double(i))
            }
            if i < locations.count {
                let pair = locations[i]
                let lng = asDouble(pair.count > 0 ? pair[0] : 0) ?? 0
                let lat = asDouble(pair.count > 1 ? pair[1] : 0) ?? 0
                let alt = i < altitudes.count ? altitudes[i] : nil
                route.append(RoutePoint(
                    latitude: lat,
                    longitude: lng,
                    altitude: alt,
                    timestamp: ts,
                    speed: nil
                ))
            }
            if i < heartrates.count, heartrates[i] > 0 {
                hrSamples.append(TimedSample(date: ts, value: heartrates[i], unit: "count/min"))
            }
        }

        let endDate = startDate.addingTimeInterval(max(duration, 1))
        let summary = WorkoutSummary(
            id: UUID(),
            uuid: UUID(),
            activityType: .cycling,
            activityName: title,
            startDate: startDate,
            endDate: endDate,
            duration: duration,
            totalDistanceMeters: distanceMeters,
            totalEnergyKilocalories: nil,
            sourceName: "行者"
        )
        var series: [String: [TimedSample]] = [:]
        if !hrSamples.isEmpty {
            series[HKQuantityTypeIdentifier.heartRate.rawValue] = hrSamples
        }
        return WorkoutBundle(
            summary: summary,
            metadata: ["xingzheId": workoutId],
            events: [],
            series: series,
            route: route
        )
    }

    private static func asDouble(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
