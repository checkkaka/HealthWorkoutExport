import Foundation
import HealthKit
import FITSwiftSDK
import CommonCrypto
import Security
import zlib
import OSLog

/// Keep 非官方跑步协议；与 Rust keep.rs 使用相同格式。参考 running_page（MIT），
/// 许可见 docs/third-party/running-page-MIT.txt。密码仅用于单次登录，不保存或自动重试。
enum KeepFailure: LocalizedError {
    case invalid, unsupported, expired, rejected, limit, storage
    case field(String)
    case malformed(Int)
    case transport(Int)
    var errorDescription: String? {
        switch self {
        case .field(let name): "Keep 数据格式无效（字段 \(name)）"
        case .invalid: "Keep 数据格式无效，可能需要更新接口适配"
        case .malformed(let line): "Keep 数据格式无效（诊断 K\(line)）"
        case .transport(let code): "Keep 网络请求失败（诊断 N\(code)）"
        case .unsupported: "仅支持 Keep 室内和室外跑步"
        case .expired: "Keep 登录已失效，请重新登录"
        case .rejected: "Keep 请求被拒绝，请检查账号或稍后手动重试"
        case .limit: "Keep 数据超过读取上限，未返回不完整结果"
        case .storage: "无法读写本机 Keep 登录信息，请解锁设备后重试"
        }
    }
}

/// 有界解码真实样本；室内跑步不生成轨迹，坐标在导出时只转换一次。
enum KeepCodec {
    static func number(_ value: Any?) -> Double? {
        let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 4096 && token.utf8.allSatisfy { (33...126).contains($0) }
    }
    static func activity(_ data: [String: Any]) throws -> SourceActivity {
        guard let kind = data["dataType"] as? String else { throw KeepFailure.malformed(#line) }
        guard ["indoorRunning", "outdoorRunning"].contains(kind) else { throw KeepFailure.unsupported }
        guard let id = data["id"] as? String, validID(id) else { throw KeepFailure.field("id") }
        guard let start = number(data["startTime"]) else { throw KeepFailure.field("startTime.missing") }
        guard let end = number(data["endTime"]) else { throw KeepFailure.field("endTime.missing") }
        guard start.rounded() == start, end.rounded() == end else { throw KeepFailure.field("time.fraction") }
        guard (631_065_600_000...4_925_000_000_000).contains(start), end <= 4_925_000_000_000 else { throw KeepFailure.field("time.range") }
        guard end >= start, end - start <= 360_000_000 else { throw KeepFailure.field("time.order") }
        guard let duration = number(data["duration"]) else { throw KeepFailure.field("duration.missing") }
        guard duration > 0 else { throw KeepFailure.field("duration.zero") }
        // Keep 历史记录的运动计时与起止时间独立；保留原值，分别限制为最多 100 小时。
        guard duration <= 360_000 else { throw KeepFailure.field("duration.range") }
        let distance = number(data["distance"])
        if let raw = data["distance"], !(raw is NSNull) {
            guard let distance, (0...5_000_000).contains(distance) else { throw KeepFailure.malformed(#line) }
        }
        return SourceActivity(id: id, sourceId: "keep", title: kind == "indoorRunning" ? "Keep 室内跑步" : "Keep 跑步",
            startDate: Date(timeIntervalSince1970: start / 1000), endDate: Date(timeIntervalSince1970: end / 1000),
            duration: duration, distanceMeters: distance,
            metadata: ["sport": "run", "indoor": kind == "indoorRunning" ? "true" : "false", "coordinates": "wgs84"])
    }
    static func timestamp(_ point: [String: Any], activity: SourceActivity) throws -> Date {
        let start = activity.startDate.timeIntervalSince1970 * 1000
        let end = max(activity.endDate.timeIntervalSince1970 * 1000, start + activity.duration * 1000)
        var candidates: [Double] = []
        // 历史样本的 unixTimestamp 可能是后续处理时间；越界时回退到同点 timestamp。
        if let raw = number(point["unixTimestamp"]), raw >= 0, raw.rounded() == raw {
            candidates += [raw, raw * 1000, raw * 100, start + raw * 100]
        }
        if let raw = number(point["timestamp"]), raw >= 0, raw.rounded() == raw {
            candidates += [start + raw * 100, raw * 100, raw, raw * 1000]
        }
        guard let ms = candidates.first(where: { $0 >= start && $0 <= end }) else {
            throw KeepFailure.field("sample.timeRange")
        }
        return Date(timeIntervalSince1970: ms / 1000)
    }
    static func samples(_ value: Any?, encrypted: Bool) throws -> [[String: Any]] {
        guard let value, !(value is NSNull) else { return [] }
        guard let text = value as? String else { throw KeepFailure.malformed(#line) }
        if text.isEmpty { return [] }
        guard text.utf8.count <= 8 * 1024 * 1024 else { throw KeepFailure.limit }
        guard let input = Data(base64Encoded: text) else { throw KeepFailure.malformed(#line) }
        var compressed = input
        if encrypted {
            guard !input.isEmpty, input.count % 16 == 0 else { throw KeepFailure.malformed(#line) }
            // 公开的旧协议兼容常量，不是用户密钥；AES-CBC 原文为 gzip，尾部填充由 gzip 忽略。
            let key = Array("56fe59;82g:d873c".utf8), iv = Array("2346892432920300".utf8)
            var output = [UInt8](repeating: 0, count: input.count + 16), written = 0
            let status = input.withUnsafeBytes { bytes in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                    key, key.count, iv, bytes.baseAddress, input.count, &output, output.count, &written)
            }
            guard status == kCCSuccess else { throw KeepFailure.malformed(#line) }
            compressed = Data(output.prefix(written))
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw KeepFailure.malformed(#line) }
        defer { inflateEnd(&stream) }
        var plain = Data()
        try compressed.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var status = Z_OK
            repeat {
                try Task.checkCancellation()
                var buffer = [UInt8](repeating: 0, count: 8192)
                status = buffer.withUnsafeMutableBytes { out in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = 8192
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw KeepFailure.malformed(#line) }
                let count = 8192 - Int(stream.avail_out)
                guard plain.count + count <= 16 * 1024 * 1024 else { throw KeepFailure.limit }
                plain.append(contentsOf: buffer.prefix(count))
                if status == Z_OK && count == 0 { throw KeepFailure.malformed(#line) }
            } while status != Z_STREAM_END
        }
        guard let values = try JSONSerialization.jsonObject(with: plain) as? [[String: Any]] else { throw KeepFailure.malformed(#line) }
        guard values.count <= 100_000 else { throw KeepFailure.limit }
        return values
    }
    static func fit(_ data: [String: Any]) throws -> Data {
        let activity = try activity(data)
        let indoor = activity.metadata["indoor"] == "true"
        var route: [RoutePoint] = []
        if !indoor {
            for point in try samples(data["geoPoints"], encrypted: true) {
                guard let lat = number(point["latitude"]), let lon = number(point["longitude"]),
                      (-90...90).contains(lat), (-180...180).contains(lon) else { throw KeepFailure.malformed(#line) }
                let altitude = number(point["altitude"])
                if let altitude, !(-500...10000).contains(altitude) { throw KeepFailure.malformed(#line) }
                let (latitude, longitude) = Gcj02ToWgs84.convert(latitude: lat, longitude: lon)
                route.append(RoutePoint(latitude: latitude, longitude: longitude, altitude: altitude,
                    timestamp: try timestamp(point, activity: activity), speed: nil))
            }
        }
        if let heart = data["heartRate"], !(heart is NSNull), !(heart is [String: Any]) { throw KeepFailure.malformed(#line) }
        let heart = data["heartRate"] as? [String: Any]
        var hr: [TimedSample] = []
        for point in try samples(heart?["heartRates"], encrypted: false) {
            guard let bpm = number(point["beatsPerMinute"]) else { throw KeepFailure.malformed(#line) }
            if bpm > 0 && bpm < 255 {
                hr.append(TimedSample(date: try timestamp(point, activity: activity), value: bpm, unit: "count/min"))
            }
        }
        let uuid = UUID()
        let summary = WorkoutSummary(id: uuid, uuid: uuid, activityType: .running, activityName: activity.title,
            startDate: activity.startDate, endDate: activity.endDate, duration: activity.duration,
            totalDistanceMeters: activity.distanceMeters,
            totalEnergyKilocalories: number(data["calorie"]).flatMap { (0...65534).contains($0) ? $0 : nil }, sourceName: "Keep")
        let bundle = WorkoutBundle(summary: summary, metadata: [:], events: [],
            series: [HKQuantityTypeIdentifier.heartRate.rawValue: hr], route: route.sorted { $0.timestamp! < $1.timestamp! })
        let bytes = try FitActivityEncoder.encode(bundle, timeZone: Foundation.TimeZone(secondsFromGMT: 0)!)
        let messages = try FitMerger.decode(bytes, name: "Keep")
        for session in messages.sessionMesgs {
            try session.setSubSport(indoor ? .treadmill : .generic)
            try session.setTotalTimerTime(activity.duration)
            if let distance = activity.distanceMeters { try session.setAvgSpeed(distance / activity.duration) }
        }
        for lap in messages.lapMesgs {
            try lap.setSubSport(indoor ? .treadmill : .generic)
            try lap.setTotalTimerTime(activity.duration)
            if let distance = activity.distanceMeters { try lap.setAvgSpeed(distance / activity.duration) }
        }
        for file in messages.activityMesgs { try file.setTotalTimerTime(activity.duration) }
        return try FitMessagesReencoder.encode(messages)
    }
}

private final class KeepRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class KeepClient: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.checkkaka.HealthWorkoutExport", category: "Keep")
    private let session: URLSession
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: config, delegate: KeepRedirectBlocker(), delegateQueue: nil)
    }
    func request(_ path: String, token: String? = nil, form: [String: String]? = nil, limit: Int = 8 * 1024 * 1024) async throws -> [String: Any] {
        try Task.checkCancellation()
        let endpoint = form != nil ? "login" : (path.hasPrefix("pd/v3/stats/") ? "list" : "detail")
        var request = URLRequest(url: URL(string: "https://api.gotokeep.com/" + path)!)
        if let token {
            guard KeepCodec.validToken(token) else { throw KeepFailure.expired }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            request.httpBody = Data(form.sorted { $0.key < $1.key }.map {
                "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
            }.joined(separator: "&").utf8)
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw KeepFailure.malformed(#line) }
            logger.notice("Keep \(endpoint, privacy: .public) HTTP \(http.statusCode)")
            guard http.statusCode != 401 && http.statusCode != 403 else { throw KeepFailure.expired }
            guard (200..<300).contains(http.statusCode) else { throw KeepFailure.rejected }
            guard response.expectedContentLength <= limit else { throw KeepFailure.limit }
            var data = Data()
            for try await byte in bytes {
                if data.count % 8192 == 0 { try Task.checkCancellation() }
                guard data.count < limit else { throw KeepFailure.limit }
                data.append(byte)
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw KeepFailure.malformed(#line) }
            let code = KeepCodec.number(root["code"])
            if code == 401 || code == 403 { throw KeepFailure.expired }
            guard root["ok"] as? Bool != false, code == nil || code == 0 || code == 200 else { throw KeepFailure.rejected }
            if form != nil && root["ok"] as? Bool != true { throw KeepFailure.rejected }
            guard let result = root["data"] as? [String: Any] else { throw KeepFailure.malformed(#line) }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as KeepFailure {
            logger.error("Keep \(endpoint, privacy: .public) \(error.localizedDescription, privacy: .public)")
            throw error
        }
        catch {
            try Task.checkCancellation()
            let code = (error as NSError).code
            logger.error("Keep \(endpoint, privacy: .public) underlying error code \(code)")
            if error is URLError { throw KeepFailure.transport(code) }
            throw KeepFailure.malformed(#line)
        }
    }
    func login(_ credentials: SourceCredentials) async throws -> String {
        guard !credentials.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              credentials.account.utf8.count <= 256, !credentials.account.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !credentials.password.isEmpty, credentials.password.utf8.count <= 1024 else { throw KeepFailure.rejected }
        let data = try await request("v1.1/users/login", form: ["mobile": credentials.account.trimmingCharacters(in: .whitespaces), "password": credentials.password], limit: 65536)
        guard let token = data["token"] as? String, KeepCodec.validToken(token) else { throw KeepFailure.malformed(#line) }
        return token
    }
    func detail(token: String, id: String) async throws -> [String: Any] {
        guard KeepCodec.validID(id) else { throw KeepFailure.malformed(#line) }
        let data = try await request("pd/v3/runninglog/\(id)", token: token)
        guard data["id"] as? String == id else { throw KeepFailure.malformed(#line) }
        return data
    }
    func list(token: String, from: Date, to: Date) async throws -> [SourceActivity] {
        guard from < to else { throw KeepFailure.malformed(#line) }
        let deadline = Date().addingTimeInterval(300)
        var cursor = 0.0, seen = Set<String>(), result: [SourceActivity] = []
        for page in 0..<128 {
            try Task.checkCancellation()
            guard Date() < deadline else { throw KeepFailure.limit }
            if page > 0 { try await Task.sleep(for: .seconds(1)) }
            let data = try await request("pd/v3/stats/detail?dateUnit=all&type=running&lastDate=\(Int64(cursor))", token: token, limit: 2 * 1024 * 1024)
            guard let records = data["records"] as? [[String: Any]] else { throw KeepFailure.malformed(#line) }
            var rows = 0
            for record in records {
                guard let logs = record["logs"] as? [[String: Any]] else { throw KeepFailure.malformed(#line) }
                for log in logs {
                    rows += 1
                    guard rows <= 10000, Date() < deadline else { throw KeepFailure.limit }
                    guard let stats = log["stats"] as? [String: Any] else { throw KeepFailure.malformed(#line) }
                    if stats["isDoubtful"] as? Bool == true { continue }
                    if let ms = KeepCodec.number(stats["startTime"]), ms < from.timeIntervalSince1970 * 1000 || ms >= to.timeIntervalSince1970 * 1000 { continue }
                    guard let id = stats["id"] as? String, KeepCodec.validID(id) else { throw KeepFailure.malformed(#line) }
                    if !seen.insert(id).inserted { continue }
                    guard seen.count <= 4096 else { throw KeepFailure.limit }
                    do {
                        let activity = try KeepCodec.activity(await detail(token: token, id: id))
                        if activity.startDate >= from && activity.startDate < to { result.append(activity) }
                    } catch KeepFailure.unsupported { continue }
                }
            }
            guard let next = KeepCodec.number(data["lastTimestamp"]), next >= 0, next <= 4_925_000_000_000, next.rounded() == next else { throw KeepFailure.malformed(#line) }
            if next == 0 || next < from.timeIntervalSince1970 * 1000 { return result.sorted { $0.startDate > $1.startDate } }
            guard cursor == 0 || next < cursor else { throw KeepFailure.malformed(#line) }
            cursor = next
        }
        throw KeepFailure.limit
    }
}

/// 独立钥匙串记录原子保存账号和令牌，不保存密码，也不读取其他平台的凭据。
final class KeepDataSource: WorkoutDataSource, @unchecked Sendable {
    static let sourceId = "keep"
    let id = sourceId
    let displayName = "Keep"
    let requiresLogin = true
    private let client = KeepClient()
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.checkkaka.HealthWorkoutExport", kSecAttrAccount as String: "keep.native.authorization"] }
    private func token() throws -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = item as? Data,
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: String],
              let token = value["token"], KeepCodec.validToken(token) else { throw KeepFailure.storage }
        return token
    }
    func isAuthenticated() async -> Bool { (try? token()) != nil }
    func login(credentials: SourceCredentials) async throws {
        ActivityListCache.clear(id)
        let token = try await client.login(credentials)
        let bytes = try JSONSerialization.data(withJSONObject: ["account": credentials.account, "token": token])
        let update = [kSecValueData as String: bytes]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = bytes
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeepFailure.storage }
    }
    func logout() async {
        ActivityListCache.clear(id)
 SecItemDelete(query as CFDictionary) }
    func listActivities(from: Date, to: Date) async throws -> [SourceActivity] {
        guard let token = try token() else { throw KeepFailure.expired }
        return try await client.list(token: token, from: from, to: to)
    }
    func fetchFitData(for activity: SourceActivity) async throws -> Data {
        guard activity.sourceId == id else { throw KeepFailure.malformed(#line) }
        guard let token = try token() else { throw KeepFailure.expired }
        return try KeepCodec.fit(await client.detail(token: token, id: activity.id))
    }
}
