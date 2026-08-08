import Foundation
import AuthenticationServices
import UIKit

/// Strava REST API 上传（默认模式）：OAuth + /uploads。
@MainActor
final class StravaAPIUploader: NSObject, StravaUploading {
    let mode: StravaUploadMode = .api
    /// OAuth 回调 scheme，需与 Info.plist / Strava 应用配置一致。
    static let callbackScheme = "healthworkoutexport"
    /// 主机名须与 Strava「授权回调域」一致（填 localhost）。
    static let redirectURI = "healthworkoutexport://localhost/callback"

    private var authSession: ASWebAuthenticationSession?
    /// 合并并发 refresh，避免多路 poll/上传同时换 token 把 refresh_token 打废。
    private var tokenRefreshTask: Task<Void, Error>?

    func isReady() async -> Bool {
        !StravaSettings.clientId.isEmpty
            && !StravaSettings.clientSecret.isEmpty
            && !StravaSettings.refreshToken.isEmpty
    }

    /// 浏览器 OAuth 授权，写入 refresh/access token。
    func authorize() async throws {
        let clientId = StravaSettings.clientId
        guard !clientId.isEmpty, !StravaSettings.clientSecret.isEmpty else {
            throw StravaUploadError.notConfigured
        }
        var comps = URLComponents(string: "https://www.strava.com/oauth/mobile/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            // activity:read_all：预检拉取本人活动列表（含私密）。
            URLQueryItem(name: "scope", value: "activity:read_all,activity:write,read")
        ]
        guard let url = comps.url else { throw StravaUploadError.notConfigured }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackScheme
            ) { callback, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callback else {
                    continuation.resume(throwing: StravaUploadError.unauthorized)
                    return
                }
                continuation.resume(returning: callback)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            if !session.start() {
                continuation.resume(throwing: StravaUploadError.unauthorized)
            }
        }

        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems
        guard let code = items?.first(where: { $0.name == "code" })?.value else {
            throw StravaUploadError.unauthorized
        }
        try await exchangeCode(code)
    }

    func uploadFit(
        _ data: Data,
        externalId: String,
        filename: String,
        commute: Bool
    ) async throws -> StravaUploadResult {
        try await ensureValidAccessToken()
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("data_type", "fit")
        appendField("external_id", externalId)
        // Strava Uploads API：commute 为表单字段，标记结果活动为通勤。
        if commute { appendField("commute", "1") }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(StravaSettings.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StravaUploadError.uploadFailed("无响应")
        }
        if http.statusCode == 429 { throw StravaUploadError.rateLimited }
        let text = String(data: respData, encoding: .utf8) ?? ""
        if http.statusCode == 401 { throw StravaUploadError.unauthorized }
        // 调用 isDuplicateUploadResponse：API/网页 duplicate 文案（含 HTML）。
        if StravaActivityLookup.isDuplicateUploadResponse(text) {
            let remoteId = StravaActivityLookup.parseDuplicateActivityId(text)
            return StravaUploadResult(remoteId: remoteId, isDuplicate: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw StravaUploadError.uploadFailed("上传失败 HTTP \(http.statusCode): \(text.prefix(200))")
        }
        let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]
        // 调用 jsonActivityId：POST 响应偶发已带 activity_id，有则直接用。
        if let activityId = StravaActivityLookup.jsonActivityId(json?["activity_id"]) {
            return StravaUploadResult(remoteId: activityId, isDuplicate: false)
        }
        let uploadId = json?["id"].map { "\($0)" }
        // POST 成功即返回：不阻塞等处理；pendingUploadId 供后台 resolveUpload 补 ID。
        // 无 activity_id 时不要回落成 upload id（会当成假远端活动）。
        return StravaUploadResult(remoteId: nil, isDuplicate: false, pendingUploadId: uploadId)
    }

    /// 轮询 upload 直至有 activity_id / duplicate / 超时；供后台补远端 ID。
    func resolveUpload(id: String) async throws -> StravaUploadResult {
        try await ensureValidAccessToken()
        return try await pollUpload(id: id)
    }

    /// 拉取单条活动有效峰值速度（max_speed ∪ best_efforts）；404 返回 nil。
    func fetchActivitySpeed(id: String) async throws -> StravaActivitySpeedInfo? {
        try await ensureValidAccessToken()
        var request = URLRequest(url: URL(string: "https://www.strava.com/api/v3/activities/\(id)")!)
        request.setValue("Bearer \(StravaSettings.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StravaUploadError.uploadFailed("无响应")
        }
        if http.statusCode == 401 { throw StravaUploadError.unauthorized }
        if http.statusCode == 429 { throw StravaUploadError.rateLimited }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StravaUploadError.uploadFailed("拉取活动 \(id) 失败 HTTP \(http.statusCode)")
        }
        return Self.parseActivitySpeedInfo(id: id, json: json)
    }

    /// 分页拉取本人全部活动列表里的摘要最高速/均速（不含 best_efforts，作粗筛）。
    func fetchAllListedActivitySpeeds(maxPages: Int = 50) async throws -> [StravaActivitySpeedInfo] {
        try await ensureValidAccessToken()
        var result: [StravaActivitySpeedInfo] = []
        var page = 1
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatterFallback = ISO8601DateFormatter()
        formatterFallback.formatOptions = [.withInternetDateTime]

        while page <= maxPages {
            var comps = URLComponents(string: "https://www.strava.com/api/v3/athlete/activities")!
            comps.queryItems = [
                URLQueryItem(name: "per_page", value: "200"),
                URLQueryItem(name: "page", value: "\(page)")
            ]
            var request = URLRequest(url: comps.url!)
            request.setValue("Bearer \(StravaSettings.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw StravaUploadError.uploadFailed("无响应")
            }
            if http.statusCode == 401 { throw StravaUploadError.unauthorized }
            if http.statusCode == 429 { throw StravaUploadError.rateLimited }
            guard (200..<300).contains(http.statusCode),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw StravaUploadError.uploadFailed("拉取活动列表失败 HTTP \(http.statusCode)")
            }
            if arr.isEmpty { break }
            for item in arr {
                let id = item["id"].map { "\($0)" } ?? ""
                guard !id.isEmpty else { continue }
                let sport = StravaSpeedAnomaly.sportType(from: item)
                guard StravaSpeedAnomaly.isCyclingSport(sport) else { continue }
                let maxSpeed = StravaSpeedAnomaly.doubleValue(item["max_speed"]) ?? 0
                let avgSpeed = StravaSpeedAnomaly.doubleValue(item["average_speed"]) ?? 0
                let name = (item["name"] as? String) ?? "活动 \(id)"
                let dateString = (item["start_date"] as? String) ?? (item["start_date_local"] as? String)
                let start = dateString.flatMap { formatter.date(from: $0) ?? formatterFallback.date(from: $0) }
                result.append(StravaActivitySpeedInfo(
                    id: id,
                    name: name,
                    startDate: start,
                    sportType: sport,
                    listedMaxSpeedMps: maxSpeed,
                    bestEffortPeakMps: 0,
                    maxSpeedMps: maxSpeed,
                    averageSpeedMps: avgSpeed,
                    fromBestEffort: false
                ))
            }
            if arr.count < 200 { break }
            page += 1
        }
        return result
    }

    static func parseActivitySpeedInfo(id: String, json: [String: Any]) -> StravaActivitySpeedInfo {
        let listedMax = StravaSpeedAnomaly.doubleValue(json["max_speed"]) ?? 0
        let avgSpeed = StravaSpeedAnomaly.doubleValue(json["average_speed"]) ?? 0
        let efforts = json["best_efforts"] as? [[String: Any]] ?? []
        let effortPeak = StravaSpeedAnomaly.bestEffortPeakMps(bestEfforts: efforts)
        let peak = max(listedMax, effortPeak)
        let name = (json["name"] as? String) ?? "活动 \(id)"
        let sport = StravaSpeedAnomaly.sportType(from: json)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatterFallback = ISO8601DateFormatter()
        formatterFallback.formatOptions = [.withInternetDateTime]
        let dateString = (json["start_date"] as? String) ?? (json["start_date_local"] as? String)
        let start = dateString.flatMap { formatter.date(from: $0) ?? formatterFallback.date(from: $0) }
        return StravaActivitySpeedInfo(
            id: id,
            name: name,
            startDate: start,
            sportType: sport,
            listedMaxSpeedMps: listedMax,
            bestEffortPeakMps: effortPeak,
            maxSpeedMps: peak,
            averageSpeedMps: avgSpeed,
            fromBestEffort: effortPeak > listedMax + 0.01
        )
    }

    /// 批次预取本人活动列表，供上传前时间窗去重（分页，循环外复用）。
    func fetchActivities(after: Date, before: Date) async throws -> [StravaActivityLookup.RemoteActivity] {
        try await ensureValidAccessToken()
        var result: [StravaActivityLookup.RemoteActivity] = []
        var page = 1
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatterFallback = ISO8601DateFormatter()
        formatterFallback.formatOptions = [.withInternetDateTime]

        while page <= 20 {
            var comps = URLComponents(string: "https://www.strava.com/api/v3/athlete/activities")!
            comps.queryItems = [
                URLQueryItem(name: "after", value: "\(Int(after.timeIntervalSince1970))"),
                URLQueryItem(name: "before", value: "\(Int(before.timeIntervalSince1970))"),
                URLQueryItem(name: "per_page", value: "200"),
                URLQueryItem(name: "page", value: "\(page)")
            ]
            var request = URLRequest(url: comps.url!)
            request.setValue("Bearer \(StravaSettings.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw StravaUploadError.uploadFailed("无响应")
            }
            if http.statusCode == 401 { throw StravaUploadError.unauthorized }
            if http.statusCode == 429 { throw StravaUploadError.rateLimited }
            guard (200..<300).contains(http.statusCode),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw StravaUploadError.uploadFailed("拉取活动列表失败 HTTP \(http.statusCode)")
            }
            if arr.isEmpty { break }
            for item in arr {
                let id = item["id"].map { "\($0)" } ?? ""
                guard !id.isEmpty else { continue }
                let dateString = (item["start_date"] as? String) ?? (item["start_date_local"] as? String)
                guard let dateString,
                      let start = formatter.date(from: dateString) ?? formatterFallback.date(from: dateString) else {
                    continue
                }
                // 无时长无法算区间重叠；宁可漏判也不误判（漏判只是白传一次）。
                let elapsed = (item["elapsed_time"] as? Double) ?? Double(item["elapsed_time"] as? Int ?? 0)
                guard elapsed > 0 else { continue }
                let distance = StravaSpeedAnomaly.doubleValue(item["distance"])
                result.append(.init(
                    id: id,
                    startDate: start,
                    endDate: start.addingTimeInterval(elapsed),
                    distanceMeters: (distance ?? 0) > 0 ? distance : nil
                ))
            }
            if arr.count < 200 { break }
            page += 1
        }
        return result
    }

    private func pollUpload(id: String) async throws -> StravaUploadResult {
        // 大批量时 Strava 处理排队更久；约 60s 仍无 activity_id 则宁可记「已传无 ID」，
        // 也不要把 upload id 当成活动 ID（数字看起来能打开，实际 404，还会污染本批预检）。
        for attempt in 0..<StravaUploadPoll.maxAttempts {
            let delay = StravaUploadPoll.delaySeconds(beforeAttempt: attempt)
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            var request = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads/\(id)")!)
            request.setValue("Bearer \(StravaSettings.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { continue }
            if http.statusCode == 401 {
                // 调用 ensureValidAccessToken：轮询中途 token 过期则刷新后再试。
                try await ensureValidAccessToken()
                continue
            }
            if http.statusCode == 429 {
                throw StravaUploadError.rateLimited
            }
            guard http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let err = json["error"] as? String, !err.isEmpty {
                if StravaActivityLookup.isDuplicateUploadResponse(err) {
                    // 调用 jsonActivityId：忽略 JSON null，避免写成 "<null>"。
                    let fromJson = StravaActivityLookup.jsonActivityId(json["activity_id"])
                    // 调用 parseDuplicateActivityId：JSON 无 activity_id 时从文案解析。
                    let fromText = StravaActivityLookup.parseDuplicateActivityId(err)
                    return StravaUploadResult(remoteId: fromJson ?? fromText, isDuplicate: true)
                }
                throw StravaUploadError.uploadFailed(err)
            }
            // 调用 jsonActivityId：仅数字 ID 才算处理完成；null 继续轮询。
            if let activityId = StravaActivityLookup.jsonActivityId(json["activity_id"]) {
                return StravaUploadResult(remoteId: activityId, isDuplicate: false)
            }
        }
        return StravaUploadResult(remoteId: nil, isDuplicate: false)
    }

    private func exchangeCode(_ code: String) async throws {
        var request = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id=\(StravaSettings.clientId)",
            "client_secret=\(StravaSettings.clientSecret)",
            "code=\(code)",
            "grant_type=authorization_code"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            throw StravaUploadError.unauthorized
        }
        StravaSettings.accessToken = access
        StravaSettings.refreshToken = refresh
        StravaSettings.expiresAt = (json["expires_at"] as? Double) ?? Double(json["expires_at"] as? Int ?? 0)
    }

    private func ensureValidAccessToken() async throws {
        guard !StravaSettings.refreshToken.isEmpty else { throw StravaUploadError.notConfigured }
        let now = Date().timeIntervalSince1970
        if !StravaSettings.accessToken.isEmpty, StravaSettings.expiresAt > now + 60 {
            return
        }
        if let tokenRefreshTask {
            try await tokenRefreshTask.value
            if !StravaSettings.accessToken.isEmpty,
               StravaSettings.expiresAt > Date().timeIntervalSince1970 + 60 {
                return
            }
        }
        let task = Task { @MainActor in
            try await self.refreshAccessToken()
        }
        tokenRefreshTask = task
        defer {
            if tokenRefreshTask == task { tokenRefreshTask = nil }
        }
        try await task.value
    }

    private func refreshAccessToken() async throws {
        var request = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id=\(StravaSettings.clientId)",
            "client_secret=\(StravaSettings.clientSecret)",
            "refresh_token=\(StravaSettings.refreshToken)",
            "grant_type=refresh_token"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw StravaUploadError.unauthorized
        }
        StravaSettings.accessToken = access
        if let refresh = json["refresh_token"] as? String {
            StravaSettings.refreshToken = refresh
        }
        StravaSettings.expiresAt = (json["expires_at"] as? Double) ?? Double(json["expires_at"] as? Int ?? 0)
    }
}

extension StravaAPIUploader: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
