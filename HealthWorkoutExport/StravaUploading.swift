import Foundation

enum StravaUploadMode: String, CaseIterable, Identifiable, Codable {
    case api
    case web

    var id: String { rawValue }
    var title: String {
        switch self {
        case .api: return "API"
        case .web: return "网页"
        }
    }
}

struct StravaUploadResult: Sendable {
    var remoteId: String?
    var isDuplicate: Bool
    /// API POST 成功后待轮询的 upload id；引擎后台补 remoteId，不阻塞下一条。
    var pendingUploadId: String? = nil
}

/// API 上传处理轮询节奏：先立刻查，再短退避，总墙钟约 60s。
enum StravaUploadPoll {
    /// 最多查询次数（含第 0 次立即查）。
    static let maxAttempts = 45

    /// 第 attempt 次查询前应等待的秒数（0-based）；0 = 立即。
    static func delaySeconds(beforeAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case ...0: return 0
        case 1: return 0.4
        case 2: return 0.8
        case 3: return 1.2
        default: return 1.5
        }
    }
}

enum StravaUploadError: LocalizedError {
    case notConfigured
    case unauthorized
    case uploadFailed(String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先在设置中配置 Strava"
        case .unauthorized: return "Strava 未授权或会话已过期"
        case .uploadFailed(let message): return message
        case .rateLimited: return "Strava 限速，请稍后重试"
        }
    }
}

/// Strava 上传抽象：API / 网页双模式共用。
protocol StravaUploading: AnyObject {
    var mode: StravaUploadMode { get }
    func isReady() async -> Bool
    /// commute：对应 Strava Uploads API 的 commute 表单字段（API 模式生效）。
    func uploadFit(
        _ data: Data,
        externalId: String,
        filename: String,
        commute: Bool
    ) async throws -> StravaUploadResult
}

/// Strava 凭证与模式配置（Keychain + UserDefaults）。
enum StravaSettings {
    private static let modeKey = "strava.uploadMode"
    private static let clientIdKey = "strava.clientId"
    private static let clientSecretKey = "strava.clientSecret"
    private static let accessTokenKey = "strava.accessToken"
    private static let refreshTokenKey = "strava.refreshToken"
    private static let expiresAtKey = "strava.expiresAt"
    private static let webCookieKey = "strava.webCookie"
    /// 上传前是否把 FIT 轨迹从 GCJ-02 转为 WGS-84（默认关，HealthKit 多半已是 WGS）。
    private static let gcjCorrectionKey = "strava.gcjCorrectionEnabled"

    static var mode: StravaUploadMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: modeKey),
               let mode = StravaUploadMode(rawValue: raw) {
                return mode
            }
            return .api
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    static var clientId: String {
        get { KeychainStore.get(account: clientIdKey) ?? "" }
        set {
            if newValue.isEmpty { KeychainStore.delete(account: clientIdKey) }
            else { KeychainStore.set(newValue, account: clientIdKey) }
        }
    }

    static var clientSecret: String {
        get { KeychainStore.get(account: clientSecretKey) ?? "" }
        set {
            if newValue.isEmpty { KeychainStore.delete(account: clientSecretKey) }
            else { KeychainStore.set(newValue, account: clientSecretKey) }
        }
    }

    static var accessToken: String {
        get { KeychainStore.get(account: accessTokenKey) ?? "" }
        set {
            if newValue.isEmpty { KeychainStore.delete(account: accessTokenKey) }
            else { KeychainStore.set(newValue, account: accessTokenKey) }
        }
    }

    static var refreshToken: String {
        get { KeychainStore.get(account: refreshTokenKey) ?? "" }
        set {
            if newValue.isEmpty { KeychainStore.delete(account: refreshTokenKey) }
            else { KeychainStore.set(newValue, account: refreshTokenKey) }
        }
    }

    static var expiresAt: TimeInterval {
        get { UserDefaults.standard.double(forKey: expiresAtKey) }
        set { UserDefaults.standard.set(newValue, forKey: expiresAtKey) }
    }

    static var webCookieHeader: String {
        get { KeychainStore.get(account: webCookieKey) ?? "" }
        set {
            if newValue.isEmpty { KeychainStore.delete(account: webCookieKey) }
            else { KeychainStore.set(newValue, account: webCookieKey) }
        }
    }

    /// 默认 false：国内 GCJ 轨迹偏移时再开；打开后对所有主源生效（含行者/健康）。
    static var gcjCorrectionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: gcjCorrectionKey) }
        set { UserDefaults.standard.set(newValue, forKey: gcjCorrectionKey) }
    }
}
