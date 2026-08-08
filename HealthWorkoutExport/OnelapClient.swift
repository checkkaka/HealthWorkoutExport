import Foundation
import CryptoKit

/// 顽鹿 HTTP 客户端：MD5 签名登录、骑行列表、FIT 下载（对齐 OnelapSyncStrava）。
actor OnelapClient {
    private static let secret = "fe9f8382418fcdeb136461cac6acae7b"
    private static let loginURL = URL(string: "https://www.onelap.cn/api/login")!
    private static let rideBase = "https://otm.onelap.cn/api/otm/ride_record"

    private var token: String?
    private var uid: String?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isLoggedIn: Bool { token != nil && !(token?.isEmpty ?? true) }

    func restore(token: String, uid: String) {
        self.token = token
        self.uid = uid
    }

    func clearSession() {
        token = nil
        uid = nil
    }

    func login(account: String, password: String) async throws {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = Self.randomNonce(16)
        let passwordMD5 = Self.md5Hex(password)
        let signStr = "account=\(account)&nonce=\(nonce)&password=\(passwordMD5)&timestamp=\(timestamp)&key=\(Self.secret)"
        let sign = Self.md5Hex(signStr)

        var request = URLRequest(url: Self.loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.onelap.cn", forHTTPHeaderField: "Origin")
        request.setValue(nonce, forHTTPHeaderField: "nonce")
        request.setValue(timestamp, forHTTPHeaderField: "timestamp")
        request.setValue(sign, forHTTPHeaderField: "sign")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "account": account,
            "password": passwordMD5
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WorkoutDataSourceError.loginFailed("顽鹿登录失败")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["data"] as? [[String: Any]],
              let first = arr.first,
              let token = first["token"] as? String else {
            throw WorkoutDataSourceError.loginFailed("顽鹿登录响应无效")
        }
        var uidValue = ""
        if let userinfo = first["userinfo"] as? [String: Any] {
            if let n = userinfo["uid"] as? NSNumber {
                uidValue = n.stringValue
            } else if let s = userinfo["uid"] as? String {
                uidValue = s
            } else if let i = userinfo["uid"] as? Int {
                uidValue = String(i)
            }
        }
        self.token = token
        self.uid = uidValue
    }

    struct Ride: Sendable {
        let id: String
        let startTime: Date
        let durationSeconds: TimeInterval
        let distanceMeters: Double?
    }

    func listRides(from: Date, to: Date) async throws -> [Ride] {
        try requireAuth()
        var matched: [Ride] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current

        for page in 1...500 {
            let body: [String: Any] = ["page": page, "limit": 20]
            let root = try await postJSON(path: "/list", body: body)
            guard let code = root["code"] as? Int, code == 200,
                  let data = root["data"] as? [String: Any] else {
                throw WorkoutDataSourceError.fetchFailed("顽鹿活动列表失败")
            }
            let list = (data["list"] as? [[String: Any]]) ?? []
            var stop = false
            for item in list {
                let id = "\(item["id"] ?? item["activity_id"] ?? "")"
                let startStr = "\(item["start_riding_time"] ?? item["startTime"] ?? "")"
                guard !id.isEmpty, let start = formatter.date(from: startStr) else { continue }
                if start < from {
                    stop = true
                    break
                }
                if start >= to { continue }
                let seconds = (item["time_seconds"] as? Double)
                    ?? (item["time"] as? Double)
                    ?? Double(item["time_seconds"] as? Int ?? item["time"] as? Int ?? 0)
                let distanceKm = (item["distance_km"] as? Double)
                    ?? ((item["totalDistance"] as? Double).map { $0 / 1000 })
                matched.append(Ride(
                    id: id,
                    startTime: start,
                    durationSeconds: seconds,
                    distanceMeters: distanceKm.map { $0 * 1000 }
                ))
            }
            let pagination = data["pagination"] as? [String: Any]
            let hasMore = (pagination?["has_more"] as? Bool) ?? false
            if stop || !hasMore || list.isEmpty { break }
        }
        return matched
    }

    func downloadFit(activityId: String) async throws -> Data {
        try requireAuth()
        let analysis = try await getJSON(path: "/analysis/\(activityId)")
        guard let code = analysis["code"] as? Int, code == 200,
              let data = analysis["data"] as? [String: Any],
              let record = data["ridingRecord"] as? [String: Any] else {
            throw WorkoutDataSourceError.fetchFailed("顽鹿活动详情失败")
        }

        // 对齐 WanSync：优先 CDN 直链（durl / fit_url），fileKey 的 fit_content 常为稀疏摘要。
        var candidates: [URL] = []
        for raw in [
            Self.stringValue(record["durl"]),
            Self.stringValue(record["fit_url"]),
            Self.stringValue(record["fitUrl"]),
            Self.stringValue(record["fileKey"])
        ] {
            guard let raw, Self.looksLikeHTTP(raw), let url = URL(string: raw) else { continue }
            if !candidates.contains(url) { candidates.append(url) }
        }
        // 次选：fit_content/{activityId}、fit_content/{base64(fileKey)}。
        if let idURL = URL(string: "\(Self.rideBase)/analysis/fit_content/\(activityId)") {
            candidates.append(idURL)
        }
        if let fileKey = Self.stringValue(record["fileKey"]), !fileKey.isEmpty {
            let encoded = Data(fileKey.utf8).base64EncodedString()
            if let u = URL(string: "\(Self.rideBase)/analysis/fit_content/\(encoded)") {
                candidates.append(u)
            }
        }
        guard !candidates.isEmpty else {
            throw WorkoutDataSourceError.fetchFailed("该顽鹿活动没有 FIT 文件")
        }

        var best: Data?
        var bestScore = -1
        var lastError: String?
        for url in candidates {
            do {
                let fitData = try await fetchFitBytes(from: url)
                guard FitContentProbe.isValidFit(fitData) else {
                    lastError = "非 FIT 内容：\(url.host ?? "")"
                    continue
                }
                let score = FitContentProbe.qualityScore(fitData)
                if score > bestScore {
                    bestScore = score
                    best = fitData
                }
                // 轨迹+心率都够用就提前结束，少打几次 CDN。
                if FitContentProbe.gpsPointCount(fitData) >= 30,
                   FitContentProbe.heartRatePointCount(fitData) >= 10 {
                    break
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        guard let best else {
            throw WorkoutDataSourceError.fetchFailed(lastError ?? "顽鹿 FIT 下载失败")
        }
        return best
    }

    /// 拉取 FIT 字节；CDN 先无鉴权，仅顽鹿 HTTPS 域名失败后再附带登录凭证。
    private func fetchFitBytes(from url: URL) async throws -> Data {
        var plain = URLRequest(url: url)
        plain.httpMethod = "GET"
        plain.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: plain)
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty {
            return data
        }
        var authed = try await authorizedRequest(url: url)
        authed.httpMethod = "GET"
        let (authData, authResp) = try await session.data(for: authed)
        guard let http = authResp as? HTTPURLResponse, (200..<300).contains(http.statusCode), !authData.isEmpty else {
            throw WorkoutDataSourceError.fetchFailed("顽鹿 FIT 下载失败 HTTP")
        }
        return authData
    }

    private static func stringValue(_ any: Any?) -> String? {
        guard let any else { return nil }
        let s = "\(any)".trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || s == "<null>" ? nil : s
    }

    private static func looksLikeHTTP(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    func sessionSnapshot() -> (token: String, uid: String)? {
        guard let token, let uid else { return nil }
        return (token, uid)
    }

    private func requireAuth() throws {
        guard token != nil else { throw WorkoutDataSourceError.notAuthenticated }
    }

    private func authorizedRequest(url: URL) async throws -> URLRequest {
        try requireAuth()
        guard Self.isTrustedAuthenticatedURL(url) else {
            throw WorkoutDataSourceError.fetchFailed("拒绝向非顽鹿 HTTPS 域名发送登录凭证")
        }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        if let uid {
            request.setValue("ouid=\(uid)", forHTTPHeaderField: "Cookie")
        }
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func isTrustedAuthenticatedURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "onelap.cn" || host.hasSuffix(".onelap.cn")
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = URL(string: Self.rideBase + path)!
        var request = try await authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WorkoutDataSourceError.fetchFailed("顽鹿请求失败")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkoutDataSourceError.fetchFailed("顽鹿响应无效")
        }
        return root
    }

    private func getJSON(path: String) async throws -> [String: Any] {
        let url = URL(string: Self.rideBase + path)!
        var request = try await authorizedRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WorkoutDataSourceError.fetchFailed("顽鹿请求失败")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkoutDataSourceError.fetchFailed("顽鹿响应无效")
        }
        return root
    }

    private static func md5Hex(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomNonce(_ length: Int) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}
