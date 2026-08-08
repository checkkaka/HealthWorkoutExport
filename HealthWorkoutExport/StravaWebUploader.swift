import Foundation
import SwiftUI
import WebKit
import UIKit

/// 禁止自动跟随重定向：网页删除要靠 302 的目标地址判断成败。
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Strava 网页上传：用 Cookie 会话取 CSRF 后 multipart 提交 FIT。
final class StravaWebUploader: NSObject, StravaUploading, @unchecked Sendable {
    let mode: StravaUploadMode = .web

    private let noRedirectDelegate = NoRedirectDelegate()

    func isReady() async -> Bool {
        !normalizedCookieHeader().isEmpty
    }

    /// 用网页 Cookie 删除远端活动（对齐 stravaweblib：POST /activities/{id} + _method=delete）。
    /// 仅「覆盖」路径使用；日常上传仍走当前模式。
    func deleteActivity(id: String) async throws {
        let cookieHeader = normalizedCookieHeader()
        guard !cookieHeader.isEmpty else { throw StravaUploadError.notConfigured }

        var lastError: Error?
        // 两轮：活动页 CSRF → /about CSRF；请求形态对齐网页表单（勿带 XHR 头，易 500）。
        for attempt in 0..<2 {
            do {
                try await deleteActivityOnce(
                    id: id,
                    cookieHeader: cookieHeader,
                    preferAboutCSRF: attempt > 0
                )
                return
            } catch let error as StravaUploadError {
                if case .unauthorized = error { throw error }
                lastError = error
                if attempt == 0 {
                    try await Task.sleep(nanoseconds: 800_000_000)
                    continue
                }
                throw error
            } catch {
                lastError = error
                throw error
            }
        }
        throw lastError ?? StravaUploadError.uploadFailed("网页删除失败")
    }

    private func deleteActivityOnce(
        id: String,
        cookieHeader: String,
        preferAboutCSRF: Bool
    ) async throws {
        // 调用 fetchCSRFPair：取 csrf-param + token（默认 authenticity_token）。
        let csrf: (param: String, token: String)
        if preferAboutCSRF {
            csrf = try await fetchCSRFPair(cookieHeader: cookieHeader, path: "/about")
        } else {
            do {
                csrf = try await fetchCSRFPair(cookieHeader: cookieHeader, path: "/activities/\(id)")
            } catch {
                csrf = try await fetchCSRFPair(cookieHeader: cookieHeader, path: "/about")
            }
        }

        let session = URLSession(configuration: .ephemeral, delegate: noRedirectDelegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: URL(string: "https://www.strava.com/activities/\(id)")!)
        request.httpMethod = "POST"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.strava.com/activities/\(id)", forHTTPHeaderField: "Referer")
        request.setValue("https://www.strava.com", forHTTPHeaderField: "Origin")
        // 桌面 UA：移动端路径偶发 500；与 stravaweblib 一致不发 XHR / X-CSRF-Token。
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.httpShouldHandleCookies = false

        // 表单 URL 编码：+ / = 等必须 %XX，否则 Rails 把 + 当空格导致 CSRF 校验炸成 500。
        var formAllowed = CharacterSet.alphanumerics
        formAllowed.insert(charactersIn: "-._~")
        let encodedParam = csrf.param.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? csrf.param
        let encodedToken = csrf.token.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? csrf.token
        request.httpBody = "_method=delete&\(encodedParam)=\(encodedToken)".data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StravaUploadError.uploadFailed("删除无响应")
        }
        let location = http.value(forHTTPHeaderField: "Location") ?? ""
        let text = String(data: data, encoding: .utf8) ?? ""

        // 活动已不存在：覆盖目标已达成，当作删除成功。
        if http.statusCode == 404 || text.lowercased().contains("not found") {
            return
        }
        if http.statusCode == 401 || http.statusCode == 403
            || location.contains("/login")
            || text.lowercased().contains("log in") {
            throw StravaUploadError.unauthorized
        }
        // 成功：302 到 training（stravaweblib 判定），或 200/204。
        let okRedirect = (300..<400).contains(http.statusCode) && (
            location.contains("/athlete/training")
                || location.contains("/dashboard")
                || (!location.isEmpty && !location.contains("/login"))
        )
        if okRedirect || http.statusCode == 200 || http.statusCode == 204 {
            return
        }
        let snippet = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = snippet.isEmpty ? "" : "：\(snippet.prefix(80))"
        throw StravaUploadError.uploadFailed(
            "网页删除失败 HTTP \(http.statusCode)\(hint)。可重新「打开 Strava 登录」刷新 Cookie，或手动删远端后再同步"
        )
    }

    func uploadFit(
        _ data: Data,
        externalId: String,
        filename: String,
        commute: Bool
    ) async throws -> StravaUploadResult {
        // 网页上传入口不支持同请求设置 commute；保留参数以统一协议。
        _ = externalId
        _ = commute
        let cookieHeader = normalizedCookieHeader()
        guard !cookieHeader.isEmpty else { throw StravaUploadError.notConfigured }

        let csrf = try await fetchCSRF(cookieHeader: cookieHeader)
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("_method", "post")
        field("authenticity_token", csrf)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files[]\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "https://www.strava.com/upload/files")!)
        request.httpMethod = "POST"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://www.strava.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.strava.com/upload/select", forHTTPHeaderField: "Referer")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StravaUploadError.uploadFailed("无响应")
        }
        if http.statusCode == 429 { throw StravaUploadError.rateLimited }
        if (300..<400).contains(http.statusCode) {
            throw StravaUploadError.unauthorized
        }
        let text = String(data: respData, encoding: .utf8) ?? ""
        // 调用 isDuplicateUploadResponse：含 HTML `duplicate of <a href=/activities/…>`。
        if StravaActivityLookup.isDuplicateUploadResponse(text) {
            let remoteId = StravaActivityLookup.parseDuplicateActivityId(text)
            return StravaUploadResult(remoteId: remoteId, isDuplicate: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw StravaUploadError.uploadFailed("网页上传失败 HTTP \(http.statusCode)")
        }
        return StravaUploadResult(remoteId: nil, isDuplicate: false)
    }

    /// 网页 Cookie 拉训练列表（不占官方 API 配额）。endpoint 非公开，改版可能失效。
    func fetchAllListedActivitySpeeds(maxPages: Int = 200) async throws -> [StravaActivitySpeedInfo] {
        let cookie = normalizedCookieHeader()
        guard !cookie.isEmpty else { throw StravaUploadError.notConfigured }

        var result: [StravaActivitySpeedInfo] = []
        var page = 1
        // 宽时间窗覆盖历史；网页训练日志按页返回。
        let startDate = "01/01/2010"
        let endDate = "12/31/2035"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatterFallback = ISO8601DateFormatter()
        formatterFallback.formatOptions = [.withInternetDateTime]

        while page <= maxPages {
            var comps = URLComponents(string: "https://www.strava.com/athlete/training_activities")!
            comps.queryItems = [
                URLQueryItem(name: "start_date", value: startDate),
                URLQueryItem(name: "end_date", value: endDate),
                // 网页训练日志：尽量只拉骑行；仍以客户端 isCyclingSport 再滤一层。
                URLQueryItem(name: "activityType", value: "Ride"),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "new_activity_only", value: "false")
            ]
            var request = URLRequest(url: comps.url!)
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.strava.com/athlete/training", forHTTPHeaderField: "Referer")
            request.httpShouldHandleCookies = false

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw StravaUploadError.uploadFailed("网页列表无响应")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw StravaUploadError.unauthorized
            }
            if http.url?.absoluteString.contains("/login") == true {
                throw StravaUploadError.unauthorized
            }
            guard (200..<300).contains(http.statusCode),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let text = String(data: data, encoding: .utf8) ?? ""
                throw StravaUploadError.uploadFailed("网页训练列表失败 HTTP \(http.statusCode)：\(text.prefix(120))")
            }
            let models = (root["models"] as? [[String: Any]])
                ?? (root["activities"] as? [[String: Any]])
                ?? []
            if models.isEmpty { break }

            for item in models {
                let id = item["id"].map { "\($0)" } ?? ""
                guard !id.isEmpty else { continue }
                let sport = StravaSpeedAnomaly.sportType(from: item)
                // activityType=Ride 偶发仍带回其它类型，客户端强制只留骑车。
                guard StravaSpeedAnomaly.isCyclingSport(sport) || sport.isEmpty else { continue }
                let maxSpeed = StravaSpeedAnomaly.doubleValue(item["max_speed"]) ?? 0
                let avgSpeed = StravaSpeedAnomaly.doubleValue(item["average_speed"]) ?? 0
                let name = (item["name"] as? String) ?? "活动 \(id)"
                // 无类型字段时：名称像健走/跑步则跳过。
                if sport.isEmpty {
                    let lower = name.lowercased()
                    if lower.contains("健走") || lower.contains("步行") || lower.contains("跑步")
                        || lower.contains("walk") || lower.contains("run") {
                        continue
                    }
                }
                let dateString = (item["start_date"] as? String)
                    ?? (item["start_date_local"] as? String)
                    ?? (item["start_time"] as? String)
                let start = dateString.flatMap { formatter.date(from: $0) ?? formatterFallback.date(from: $0) }
                result.append(StravaActivitySpeedInfo(
                    id: id,
                    name: name,
                    startDate: start,
                    sportType: sport.isEmpty ? "Ride" : sport,
                    listedMaxSpeedMps: maxSpeed,
                    bestEffortPeakMps: 0,
                    maxSpeedMps: maxSpeed,
                    averageSpeedMps: avgSpeed,
                    fromBestEffort: false
                ))
            }
            // 网页每页通常约 20 条；不足一页则结束。
            if models.count < 10 { break }
            page += 1
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        return result
    }

    /// 网页 Cookie 拉训练列表做上传前区间预检（不占官方 API 配额）。
    /// after/before 按开始时间过滤；缺时长的条目跳过（无法算区间）。
    func fetchActivities(after: Date, before: Date, maxPages: Int = 50) async throws -> [StravaActivityLookup.RemoteActivity] {
        let cookie = normalizedCookieHeader()
        guard !cookie.isEmpty else { throw StravaUploadError.notConfigured }

        var result: [StravaActivityLookup.RemoteActivity] = []
        var page = 1
        let startDate = "01/01/2010"
        let endDate = "12/31/2035"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatterFallback = ISO8601DateFormatter()
        formatterFallback.formatOptions = [.withInternetDateTime]

        while page <= maxPages {
            var comps = URLComponents(string: "https://www.strava.com/athlete/training_activities")!
            comps.queryItems = [
                URLQueryItem(name: "start_date", value: startDate),
                URLQueryItem(name: "end_date", value: endDate),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "new_activity_only", value: "false")
            ]
            var request = URLRequest(url: comps.url!)
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.strava.com/athlete/training", forHTTPHeaderField: "Referer")
            request.httpShouldHandleCookies = false

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw StravaUploadError.uploadFailed("网页列表无响应")
            }
            if http.statusCode == 401 || http.statusCode == 403 { throw StravaUploadError.unauthorized }
            if http.url?.absoluteString.contains("/login") == true { throw StravaUploadError.unauthorized }
            guard (200..<300).contains(http.statusCode),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StravaUploadError.uploadFailed("网页训练列表失败 HTTP \(http.statusCode)")
            }
            let models = (root["models"] as? [[String: Any]])
                ?? (root["activities"] as? [[String: Any]])
                ?? []
            if models.isEmpty { break }

            var pageNewest: Date?
            for item in models {
                let id = item["id"].map { "\($0)" } ?? ""
                guard !id.isEmpty else { continue }
                let dateString = (item["start_date"] as? String)
                    ?? (item["start_date_local"] as? String)
                    ?? (item["start_time"] as? String)
                guard let dateString,
                      let start = formatter.date(from: dateString) ?? formatterFallback.date(from: dateString) else {
                    continue
                }
                pageNewest = pageNewest.map { max($0, start) } ?? start
                guard start >= after, start <= before else { continue }
                let elapsed = StravaSpeedAnomaly.doubleValue(item["elapsed_time"])
                    ?? StravaSpeedAnomaly.doubleValue(item["moving_time"])
                    ?? 0
                guard elapsed > 0 else { continue }
                let distance = StravaSpeedAnomaly.doubleValue(item["distance"])
                result.append(.init(
                    id: id,
                    startDate: start,
                    endDate: start.addingTimeInterval(elapsed),
                    distanceMeters: (distance ?? 0) > 0 ? distance : nil
                ))
            }
            // 列表通常新→旧：整页都早于 after 则可停。
            if let newest = pageNewest, newest < after { break }
            if models.count < 10 { break }
            page += 1
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        return result
    }

    /// 网页拉单条：只用活动页摘要 max_speed / average_speed / best_efforts（不用速度流毛刺当峰值）。
    func fetchActivitySpeed(id: String) async throws -> StravaActivitySpeedInfo? {
        let cookie = normalizedCookieHeader()
        guard !cookie.isEmpty else { throw StravaUploadError.notConfigured }

        var listedMax = 0.0
        var avgSpeed = 0.0
        var effortPeak = 0.0
        var name = "活动 \(id)"
        var sport = ""

        var pageReq = URLRequest(url: URL(string: "https://www.strava.com/activities/\(id)")!)
        pageReq.setValue(cookie, forHTTPHeaderField: "Cookie")
        pageReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        pageReq.httpShouldHandleCookies = false
        let (pageData, pageResp) = try await URLSession.shared.data(for: pageReq)
        if let http = pageResp as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }
            if http.statusCode == 401 || http.statusCode == 403 { throw StravaUploadError.unauthorized }
            if http.url?.absoluteString.contains("/login") == true { throw StravaUploadError.unauthorized }
        }
        guard let html = String(data: pageData, encoding: .utf8) else {
            throw StravaUploadError.uploadFailed("活动页无法解码")
        }

        // 优先从整段 JSON 解析，避免 firstDouble 误抓页面里其它数字。
        if let json = Self.extractActivityJSON(from: html) {
            listedMax = StravaSpeedAnomaly.doubleValue(json["max_speed"]) ?? listedMax
            avgSpeed = StravaSpeedAnomaly.doubleValue(json["average_speed"]) ?? avgSpeed
            sport = StravaSpeedAnomaly.sportType(from: json)
            if let n = json["name"] as? String, !n.isEmpty { name = n }
            if let efforts = json["best_efforts"] as? [[String: Any]] {
                effortPeak = StravaSpeedAnomaly.bestEffortPeakMps(bestEfforts: efforts)
            }
        } else {
            listedMax = Self.firstDouble(in: html, key: "max_speed") ?? listedMax
            avgSpeed = Self.firstDouble(in: html, key: "average_speed") ?? avgSpeed
            sport = Self.firstString(in: html, key: "sport_type")
                ?? Self.firstString(in: html, key: "type")
                ?? sport
            if let n = Self.firstString(in: html, key: "name"), !n.isEmpty { name = n }
            if let efforts = Self.extractBestEffortsArray(from: html) {
                effortPeak = StravaSpeedAnomaly.bestEffortPeakMps(bestEfforts: efforts)
            }
        }

        // 非骑车直接跳过（不进入异常列表）。
        if !sport.isEmpty, !StravaSpeedAnomaly.isCyclingSport(sport) {
            return nil
        }
        if sport.isEmpty {
            let lower = name.lowercased()
            if lower.contains("健走") || lower.contains("步行") || lower.contains("跑步")
                || lower.contains("walk") || lower.contains("run") {
                return nil
            }
            sport = "Ride"
        }

        // 骑车：速度流峰值作「瞬移」兜底（页面常不含 best_efforts；健走已在上面排除）。
        var streamPeak = 0.0
        do {
            var comps = URLComponents(string: "https://www.strava.com/activities/\(id)/streams")!
            comps.queryItems = [URLQueryItem(name: "stream_types[]", value: "velocity_smooth")]
            var streamReq = URLRequest(url: comps.url!)
            streamReq.setValue(cookie, forHTTPHeaderField: "Cookie")
            streamReq.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            streamReq.setValue("application/json", forHTTPHeaderField: "Accept")
            streamReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            streamReq.setValue("https://www.strava.com/activities/\(id)", forHTTPHeaderField: "Referer")
            streamReq.httpShouldHandleCookies = false
            let (streamData, streamResp) = try await URLSession.shared.data(for: streamReq)
            if let http = streamResp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                // 取高分位而非绝对 max，减少单点噪声；仍能抓住几千 km/h 瞬移。
                streamPeak = Self.velocityPeakMps(from: streamData, percentile: 0.995)
            }
        }

        let spikePeak = max(effortPeak, streamPeak)
        let peak = max(listedMax, spikePeak)
        return StravaActivitySpeedInfo(
            id: id,
            name: name,
            startDate: nil,
            sportType: sport,
            listedMaxSpeedMps: listedMax,
            bestEffortPeakMps: spikePeak,
            maxSpeedMps: peak,
            averageSpeedMps: avgSpeed,
            fromBestEffort: spikePeak > listedMax + 0.01
        )
    }

    /// 速度流峰值（m/s）：按分位数，避免单个毛刺；瞬移段仍会远超 80 km/h。
    private static func velocityPeakMps(from data: Data, percentile: Double) -> Double {
        var values: [Double] = []
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for item in arr {
                let type = (item["type"] as? String) ?? ""
                guard type.contains("velocity") || type.contains("speed"),
                      let raw = item["data"] as? [Any] else { continue }
                values = raw.compactMap(StravaSpeedAnomaly.doubleValue).filter { $0 > 0 }
                break
            }
        } else if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["velocity_smooth", "velocity", "speed"] {
                if let raw = root[key] as? [Any] {
                    values = raw.compactMap(StravaSpeedAnomaly.doubleValue).filter { $0 > 0 }
                    break
                }
                if let obj = root[key] as? [String: Any], let raw = obj["data"] as? [Any] {
                    values = raw.compactMap(StravaSpeedAnomaly.doubleValue).filter { $0 > 0 }
                    break
                }
            }
        }
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * percentile)))
        return sorted[idx]
    }

    /// 从活动页 HTML 抠一段含 max_speed 的 JSON 对象（比正则单字段更靠谱）。
    private static func extractActivityJSON(from html: String) -> [String: Any]? {
        guard let marker = html.range(of: "\"max_speed\"") else { return nil }
        // 向前找最近的 {，向后配对到 }。
        let prefix = html[..<marker.lowerBound]
        guard let braceStart = prefix.lastIndex(of: "{") else { return nil }
        var depth = 0
        var end = braceStart
        for idx in html[braceStart...].indices {
            let ch = html[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    end = idx
                    break
                }
            }
            // 对象过大则放弃，避免扫整页。
            if html.distance(from: braceStart, to: idx) > 200_000 { return nil }
        }
        guard depth == 0 else { return nil }
        let text = String(html[braceStart...end])
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["max_speed"] != nil else {
            return nil
        }
        return obj
    }

    private static func firstDouble(in html: String, key: String) -> Double? {
        let pattern = "\"\(key)\"\\s*:\\s*(-?[0-9]+(?:\\.[0-9]+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: html) else { return nil }
        return Double(html[r])
    }

    private static func firstString(in html: String, key: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[r])
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func extractBestEffortsArray(from html: String) -> [[String: Any]]? {
        guard let start = html.range(of: "\"best_efforts\"") else { return nil }
        guard let bracket = html[start.upperBound...].firstIndex(of: "[") else { return nil }
        var depth = 0
        var end = bracket
        for idx in html[bracket...].indices {
            let ch = html[idx]
            if ch == "[" { depth += 1 }
            if ch == "]" {
                depth -= 1
                if depth == 0 {
                    end = idx
                    break
                }
            }
        }
        guard depth == 0 else { return nil }
        let jsonText = String(html[bracket...end])
        guard let data = jsonText.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return arr
    }

    private func normalizedCookieHeader() -> String {
        var raw = StravaSettings.webCookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("cookie:") {
            raw = String(raw.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return raw
    }

    private func fetchCSRF(cookieHeader: String, path: String = "/about") async throws -> String {
        // 调用 fetchCSRFPair：上传等只需 token 字符串。
        try await fetchCSRFPair(cookieHeader: cookieHeader, path: path).token
    }

    /// 提取 csrf-param + csrf-token（对齐 stravaweblib）；缺 param 时默认 authenticity_token。
    private func fetchCSRFPair(
        cookieHeader: String,
        path: String = "/about"
    ) async throws -> (param: String, token: String) {
        let candidates: [String]
        if path == "/about" || path == "/upload/select" {
            candidates = [path, "/about", "/upload/select"]
        } else {
            candidates = [path, "/about", "/upload/select"]
        }
        var seen = Set<String>()
        for p in candidates where seen.insert(p).inserted {
            var request = URLRequest(url: URL(string: "https://www.strava.com\(p)")!)
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { continue }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw StravaUploadError.unauthorized
            }
            if http.statusCode == 302 || (http.url?.absoluteString.contains("/login") ?? false) {
                throw StravaUploadError.unauthorized
            }
            // 活动已删：404 时改走 /about 取 CSRF，外层会把删除 404 当成功。
            if http.statusCode == 404 { continue }
            guard http.statusCode == 200, let html = String(data: data, encoding: .utf8) else { continue }
            if let pair = extractCSRFPair(from: html) { return pair }
        }
        throw StravaUploadError.uploadFailed("无法提取 Strava CSRF token，请重新登录网页模式")
    }

    private func extractCSRF(from html: String) -> String? {
        extractCSRFPair(from: html)?.token
    }

    private func extractCSRFPair(from html: String) -> (param: String, token: String)? {
        var param = "authenticity_token"
        if let range = html.range(of: #"name="csrf-param" content="([^"]+)""#, options: .regularExpression) {
            let tag = String(html[range])
            if let r = tag.range(of: #"content="([^"]+)""#, options: .regularExpression) {
                let value = String(tag[r])
                    .replacingOccurrences(of: "content=\"", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                if !value.isEmpty { param = value }
            }
        }
        if let range = html.range(of: #"name="csrf-token" content="([^"]+)""#, options: .regularExpression) {
            let tag = String(html[range])
            if let r = tag.range(of: #"content="([^"]+)""#, options: .regularExpression) {
                let token = String(tag[r])
                    .replacingOccurrences(of: "content=\"", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                if !token.isEmpty { return (param, token) }
            }
        }
        if let range = html.range(of: #"name="authenticity_token" value="([^"]+)""#, options: .regularExpression) {
            let tag = String(html[range])
            if let r = tag.range(of: #"value="([^"]+)""#, options: .regularExpression) {
                let token = String(tag[r])
                    .replacingOccurrences(of: "value=\"", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                if !token.isEmpty { return ("authenticity_token", token) }
            }
        }
        return nil
    }
}

/// WKWebView 登录页：登录成功后把 Cookie 写回 StravaSettings。
struct StravaWebLoginView: UIViewControllerRepresentable {
    var onFinished: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = StravaWebLoginController()
        vc.onFinished = onFinished
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

final class StravaWebLoginController: UIViewController, WKNavigationDelegate {
    var onFinished: (() -> Void)?
    private var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "登录 Strava"
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        view.addSubview(webView)
        webView.load(URLRequest(url: URL(string: "https://www.strava.com/login")!))

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(finish)
        )
    }

    @objc private func finish() {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            let strava = cookies.filter { $0.domain.contains("strava.com") }
            let header = strava.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            if !header.isEmpty {
                StravaSettings.webCookieHeader = header
            }
            DispatchQueue.main.async {
                self.onFinished?()
            }
        }
    }
}
