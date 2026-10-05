import AppKit
import FlutterMacOS
import Foundation
import Security
import WebKit

/// macOS Strava 网页登录。Cookie 始终留在原生边界，只用于固定的 Strava 请求目标。
final class StravaWebPlugin: NSObject, FlutterPlugin, WKNavigationDelegate, NSWindowDelegate {
  static let maximumCookieHeaderBytes = 16_384
  static let maximumUploadBytes = 64 * 1_024 * 1_024
  static let maximumResponseBytes = 4 * 1_024 * 1_024

  private static let channelName = "health_workout_export/strava_web"
  private static let keychainService = "com.checkkaka.HealthWorkoutExport"
  private static let cookieAccount = "strava.webCookie"
  private static let loginURL = URL(string: "https://www.strava.com/login")!
  private static let probeURL = URL(
    string: "https://www.strava.com/athlete/training_activities?start_date=01%2F01%2F2010&end_date=12%2F31%2F2035&page=1&new_activity_only=false"
  )!
  private static let cookieRequestHost = "www.strava.com"
  private static let cookieRequestPath = "/athlete/training_activities"
  private static let loginHosts: Set<String> = [
    "strava.com",
    "www.strava.com",
    "accounts.google.com",
    "appleid.apple.com",
    "facebook.com",
    "www.facebook.com",
    "m.facebook.com",
  ]

  private enum Operation: Equatable {
    case idle
    case login
    case probing
    case uploading
    case deleting
    case listing
    case clearing
  }

  private var operation = Operation.idle
  private var pendingLoginResult: FlutterResult?
  private var loginWindow: NSWindow?
  private var webView: WKWebView?
  private var probeSession: URLSession?
  private var probeTask: Task<Void, Never>?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger)
    let plugin = StravaWebPlugin()
    channel.setMethodCallHandler(plugin.handle)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "login":
      DispatchQueue.main.async { self.presentLogin(result: result) }
    case "hasCookie":
      DispatchQueue.main.async { self.reportCookieReadiness(result: result) }
    case "clearCookies":
      DispatchQueue.main.async { self.clearCookies(result: result) }
    case "deleteActivity":
      DispatchQueue.main.async { self.deleteActivity(arguments: call.arguments, result: result) }
    case "readActivitySpeedData":
      DispatchQueue.main.async { self.readActivitySpeedData(arguments: call.arguments, result: result) }
    case "listActivityPage":
      DispatchQueue.main.async { self.listActivityPage(arguments: call.arguments, result: result) }
    case "openActivity":
      DispatchQueue.main.async { self.openActivity(arguments: call.arguments, result: result) }
    case "uploadFit":
      DispatchQueue.main.async { self.uploadFit(arguments: call.arguments, result: result) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func isStravaDomain(_ rawDomain: String) -> Bool {
    var domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while domain.hasPrefix(".") { domain.removeFirst() }
    return domain == "strava.com" || domain.hasSuffix(".strava.com")
  }

  static func isValidCookieName(_ name: String) -> Bool {
    guard !name.isEmpty else { return false }
    let tokenPunctuation = Set("!#$%&'*+-.^_`|~".utf8)
    return name.utf8.allSatisfy { byte in
      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        || tokenPunctuation.contains(byte)
    }
  }

  static func isValidCookieValue(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
      let value = scalar.value
      return value == 0x21 || (0x23...0x2b).contains(value)
        || (0x2d...0x3a).contains(value) || (0x3c...0x5b).contains(value)
        || (0x5d...0x7e).contains(value)
    }
  }

  /// 按目标请求的 domain/path 语义选择 Cookie；同名时只保留匹配更具体的一个。
  static func cookieHeader(
    from cookies: [HTTPCookie],
    requestHost: String = "www.strava.com",
    requestPath: String = "/athlete/training_activities"
  ) -> String? {
    struct Candidate {
      let name: String
      let value: String
      let domainLength: Int
      let pathLength: Int
    }

    let host = requestHost.lowercased()
    guard isStravaDomain(host), requestPath.hasPrefix("/") else { return nil }
    var selected: [Candidate] = []
    var indexes: [String: Int] = [:]
    let now = Date()

    for cookie in cookies {
      var domain = cookie.domain.lowercased()
      while domain.hasPrefix(".") { domain.removeFirst() }
      let path = cookie.path.isEmpty ? "/" : cookie.path
      guard
        isStravaDomain(domain),
        host == domain || host.hasSuffix(".\(domain)"),
        pathMatches(cookiePath: path, requestPath: requestPath),
        cookie.expiresDate.map({ $0 > now }) ?? true,
        isValidCookieName(cookie.name),
        isValidCookieValue(cookie.value)
      else { continue }

      let candidate = Candidate(
        name: cookie.name,
        value: cookie.value,
        domainLength: domain.count,
        pathLength: path.count
      )
      if let index = indexes[cookie.name] {
        let current = selected[index]
        if candidate.pathLength > current.pathLength
          || (candidate.pathLength == current.pathLength
            && candidate.domainLength > current.domainLength)
        {
          selected[index] = candidate
        }
      } else {
        indexes[cookie.name] = selected.count
        selected.append(candidate)
      }
    }

    guard !selected.isEmpty else { return nil }
    let header = selected.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    return header.utf8.count <= maximumCookieHeaderBytes ? header : nil
  }

  static func isAuthenticatedProbe(statusCode: Int, finalURL: URL?, body: Data) -> Bool {
    guard
      statusCode == 200,
      isExpectedEndpoint(finalURL, path: "/athlete/training_activities"),
      body.count <= maximumResponseBytes,
      let object = try? JSONSerialization.jsonObject(with: body),
      let root = object as? [String: Any]
    else { return false }
    return root["models"] is [Any] || root["activities"] is [Any]
  }

  static func isAllowedLoginNavigation(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
      url.user == nil, url.password == nil, url.port == nil || url.port == 443
    else {
      return false
    }
    return loginHosts.contains(host)
  }

  private static func pathMatches(cookiePath: String, requestPath: String) -> Bool {
    guard requestPath.hasPrefix(cookiePath) else { return false }
    if requestPath == cookiePath || cookiePath.hasSuffix("/") { return true }
    let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
    return requestPath[boundary] == "/"
  }

  static func normalizedStoredCookieHeader(_ rawValue: String?) -> String? {
    guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return nil
    }
    if value.lowercased().hasPrefix("cookie:") {
      value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !value.isEmpty, value.utf8.count <= maximumCookieHeaderBytes else { return nil }
    let pairs = value.split(separator: ";", omittingEmptySubsequences: false)
    guard !pairs.isEmpty else { return nil }
    for rawPair in pairs {
      let pair = rawPair.trimmingCharacters(in: .whitespaces)
      guard let separator = pair.firstIndex(of: "=") else { return nil }
      let name = String(pair[..<separator])
      let cookieValue = String(pair[pair.index(after: separator)...])
      guard isValidCookieName(name), isValidCookieValue(cookieValue) else { return nil }
    }
    return value
  }

  private func presentLogin(result: @escaping FlutterResult) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard operation == .idle else {
      result(error("web_operation_in_progress", "Strava 网页操作正在进行，请稍后重试", retryable: true))
      return
    }
    operation = .login
    pendingLoginResult = result
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let webView = WKWebView(
      frame: NSRect(x: 0, y: 0, width: 720, height: 640), configuration: configuration
    )
    webView.navigationDelegate = self
    self.webView = webView
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
      styleMask: [.titled, .closable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.title = "Strava 登录"
    let done = NSButton(title: "完成登录", target: self, action: #selector(completeLogin))
    done.frame = NSRect(x: 12, y: 640, width: 120, height: 28)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 680))
    container.addSubview(webView)
    container.addSubview(done)
    window.contentView = container
    window.delegate = self
    window.center()
    loginWindow = window
    window.makeKeyAndOrderFront(nil)
    webView.load(URLRequest(url: Self.loginURL))
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url, Self.isAllowedLoginNavigation(url) else {
      decisionHandler(.cancel)
      return
    }
    if navigationAction.targetFrame == nil {
      webView.load(navigationAction.request)
      decisionHandler(.cancel)
    } else {
      decisionHandler(.allow)
    }
  }

  @objc private func completeLogin() {
    guard operation == .login, let window = loginWindow else { return }
    webView?.stopLoading()
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
      DispatchQueue.main.async {
        guard let self, self.loginWindow === window else { return }
        self.verifyAndSaveLogin(cookies: cookies)
      }
    }
  }

  func windowWillClose(_ notification: Notification) {
    finishLogin(with: error("web_login_cancelled", "已取消 Strava 网页登录"))
  }

  private func verifyAndSaveLogin(cookies: [HTTPCookie]) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard operation == .login else { return }
    // Persist only root-path cookies, because this header is reused at /about and /upload.
    guard let header = Self.cookieHeader(from: cookies, requestPath: "/") else {
      finishLogin(with: error("web_login_failed", "未找到适用于 Strava 训练页面的安全登录 Cookie"))
      return
    }

    operation = .probing
    verifySession(cookieHeader: header) { [weak self] verificationError in
      guard let self, operation == .probing else { return }
      if let verificationError {
        // 探测失败绝不覆盖旧 Cookie，用户仍可重试或取消。
        finishLogin(with: verificationError)
      } else if let keychainError = storeCookieHeader(header) {
        finishLogin(with: keychainError)
      } else {
        finishLogin(with: true)
      }
    }
  }

  private func verifySession(
    cookieHeader: String,
    completion: @escaping (FlutterError?) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    let session = Self.makeIsolatedSession()
    probeSession = session
    var request = URLRequest(url: Self.probeURL)
    request.timeoutInterval = 15
    request.httpShouldHandleCookies = false
    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    request.setValue("https://www.strava.com/athlete/training", forHTTPHeaderField: "Referer")
    probeTask = Task {
      do {
        let (data, response) = try await Self.boundedResponse(for: request, session: session)
        await MainActor.run {
          guard self.operation == .probing, self.probeSession === session else { return }
          guard Self.isAuthenticatedProbe(
            statusCode: response.statusCode, finalURL: response.url, body: data
          ) else {
            completion(self.error("web_login_not_ready", "Strava 尚未登录成功，请重新登录", retryable: true))
            return
          }
          completion(nil)
        }
      } catch {
        await MainActor.run {
          guard self.operation == .probing, self.probeSession === session else { return }
          completion(self.error(
            "web_login_verification_failed", "无法验证 Strava 网页登录，请重试", retryable: true
          ))
        }
      }
    }
  }

  private func finishLogin(with response: Any?) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard operation == .login || operation == .probing else { return }
    probeTask?.cancel()
    probeSession?.invalidateAndCancel()
    probeTask = nil
    probeSession = nil
    let result = pendingLoginResult
    pendingLoginResult = nil
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView = nil
    let window = loginWindow
    loginWindow = nil
    window?.delegate = nil
    window?.close()
    operation = .idle
    result?(response)
  }

  private func reportCookieReadiness(result: @escaping FlutterResult) {
    dispatchPrecondition(condition: .onQueue(.main))
    let stored = readCookieHeader()
    if let storedError = stored.error {
      result(storedError)
    } else {
      result(Self.normalizedStoredCookieHeader(stored.value) != nil)
    }
  }

  private func clearCookies(result: @escaping FlutterResult) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard operation == .idle else {
      result(error("web_operation_in_progress", "Strava 网页操作正在进行，请稍后重试", retryable: true))
      return
    }
    operation = .clearing
    let keychainError = removeCookieHeader()
    let store = WKWebsiteDataStore.default().httpCookieStore
    store.getAllCookies { cookies in
      let group = DispatchGroup()
      for cookie in cookies where Self.isStravaDomain(cookie.domain) {
        group.enter()
        store.delete(cookie) { group.leave() }
      }
      group.notify(queue: .main) {
        // WebKit 删除 API 不返回错误，因此必须二次枚举确认后才宣告成功。
        store.getAllCookies { remainingCookies in
          DispatchQueue.main.async {
            self.completeClear(
              remainingCount: remainingCookies.filter { Self.isStravaDomain($0.domain) }.count,
              keychainError: keychainError,
              result: result
            )
          }
        }
      }
    }
  }

  private func completeClear(
    remainingCount: Int,
    keychainError: FlutterError?,
    result: @escaping FlutterResult
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard operation == .clearing else { return }
    operation = .idle
    if remainingCount > 0 {
      result(
        FlutterError(
          code: "web_cookie_clear_partial",
          message: "Strava 网页 Cookie 未完全清除，请重试",
          details: [
            "remainingCookieCount": remainingCount,
            "keychainDeleted": keychainError == nil,
            "retryable": true,
          ]
        ))
      return
    }
    if let keychainError {
      var details: [String: Any] = [
        "wkCookieDeletionVerified": true,
        "retryable": true,
      ]
      if let original = keychainError.details as? [String: Any], let status = original["status"] {
        details["status"] = status
      }
      result(
        FlutterError(
          code: keychainError.code,
          message: keychainError.message,
          details: details
        ))
    } else {
      result(nil)
    }
  }

  private func readCookieHeader() -> (value: String?, error: FlutterError?) {
    var query = keychainQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return (nil, nil) }
    guard status == errSecSuccess else { return (nil, keychainError(status)) }
    guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
      return (nil, error("keychain_invalid_data", "Strava Cookie 不是有效 UTF-8"))
    }
    return (value, nil)
  }

  private func storeCookieHeader(_ value: String) -> FlutterError? {
    let query = keychainQuery()
    let attributes: [String: Any] = [
      kSecValueData as String: Data(value.utf8),
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return nil }
    guard updateStatus == errSecItemNotFound else { return keychainError(updateStatus) }
    let item = query.merging(attributes) { _, newValue in newValue }
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    return addStatus == errSecSuccess ? nil : keychainError(addStatus)
  }

  private func removeCookieHeader() -> FlutterError? {
    let status = SecItemDelete(keychainQuery() as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound ? nil : keychainError(status)
  }

  private func keychainQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: Self.cookieAccount,
    ]
  }

  private func keychainError(_ status: OSStatus) -> FlutterError {
    FlutterError(
      code: "keychain_error",
      message: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain operation failed",
      details: ["status": Int(status)]
    )
  }

  static func activityURL(remoteId: String) -> URL? {
    guard !remoteId.isEmpty, remoteId.utf8.count <= 32,
      remoteId.utf8.allSatisfy({ (48...57).contains($0) })
    else { return nil }
    return URL(string: "https://www.strava.com/activities/\(remoteId)")
  }

  private func openActivity(arguments: Any?, result: @escaping FlutterResult) {
    guard let arguments = arguments as? [String: Any],
      let remoteId = arguments["remoteId"] as? String,
      let url = Self.activityURL(remoteId: remoteId)
    else {
      result(error("invalid_arguments", "远端活动 ID 必须为数字"))
      return
    }
    result(NSWorkspace.shared.open(url) ? nil : error("web_activity_open_failed", "无法打开 Strava 活动"))
  }

  private func deleteActivity(arguments: Any?, result: @escaping FlutterResult) {
    guard operation == .idle else {
      result(error("web_operation_in_progress", "Strava 网页操作正在进行，请稍后重试", retryable: true))
      return
    }
    guard let arguments = arguments as? [String: Any],
      let remoteId = arguments["remoteId"] as? String, Self.activityURL(remoteId: remoteId) != nil
    else {
      result(error("invalid_arguments", "远端活动 ID 必须为数字"))
      return
    }
    let stored = readCookieHeader()
    if let storedError = stored.error { result(storedError); return }
    guard let cookie = Self.normalizedStoredCookieHeader(stored.value) else {
      result(error("web_not_ready", "Strava 网页登录已失效，请重新登录"))
      return
    }
    operation = .deleting
    Task {
      do {
        try await Self.performCookieDelete(remoteId: remoteId, cookieHeader: cookie)
        await MainActor.run { self.operation = .idle; result(nil) }
      } catch {
        await MainActor.run {
          self.operation = .idle
          result(FlutterError(
            code: "web_delete_failed", message: "网页删除未确认，活动可能已删除，请检查后重试",
            details: ["retryable": false, "mayHaveDeleted": true]
          ))
        }
      }
    }
  }

  private func readActivitySpeedData(arguments: Any?, result: @escaping FlutterResult) {
    guard operation == .idle else {
      result(error("web_operation_in_progress", "Strava 网页操作正在进行，请稍后重试", retryable: true))
      return
    }
    guard let arguments = arguments as? [String: Any],
      let remoteId = arguments["remoteId"] as? String, let url = Self.activityURL(remoteId: remoteId)
    else { result(error("invalid_arguments", "远端活动 ID 必须为数字")); return }
    let stored = readCookieHeader()
    if let storedError = stored.error { result(storedError); return }
    guard let cookie = Self.normalizedStoredCookieHeader(stored.value) else {
      result(error("web_not_ready", "Strava 网页登录已失效，请重新登录")); return
    }
    operation = .listing
    Task {
      let session = Self.makeIsolatedSession()
      defer { session.invalidateAndCancel() }
      do {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.boundedResponse(for: request, session: session)
        if response.statusCode == 404 {
          await MainActor.run { self.operation = .idle; result(nil) }
          return
        }
        guard response.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
          throw URLError(.badServerResponse)
        }
        var payload: [String: Any] = ["pageHtml": html]
        var components = URLComponents(url: url.appendingPathComponent("streams"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "stream_types[]", value: "velocity_smooth")]
        var streamRequest = URLRequest(url: components.url!)
        streamRequest.httpShouldHandleCookies = false
        streamRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        streamRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        streamRequest.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        streamRequest.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        if let (streamData, streamResponse) = try? await Self.boundedResponse(for: streamRequest, session: session),
          streamResponse.statusCode == 200, let json = String(data: streamData, encoding: .utf8)
        { payload["streamsJson"] = json }
        await MainActor.run { self.operation = .idle; result(payload) }
      } catch {
        await MainActor.run {
          self.operation = .idle
          result(self.error("web_list_failed", "无法读取 Strava 活动详情，请重试", retryable: true))
        }
      }
    }
  }

  private func listActivityPage(arguments: Any?, result: @escaping FlutterResult) {
    guard operation == .idle else {
      result(error("web_operation_in_progress", "Strava 网页操作正在进行，请稍后重试", retryable: true))
      return
    }
    guard let arguments = arguments as? [String: Any],
      let page = Self.integerArgument(arguments["page"]),
      let afterMs = Self.integerArgument(arguments["afterMs"]),
      let beforeMs = Self.integerArgument(arguments["beforeMs"]),
      let url = Self.activityPageURL(page: page, afterMs: afterMs, beforeMs: beforeMs)
    else {
      result(error("invalid_arguments", "网页列表需要有效页码和日期区间"))
      return
    }
    let stored = readCookieHeader()
    if let storedError = stored.error { result(storedError); return }
    guard let cookie = Self.normalizedStoredCookieHeader(stored.value) else {
      result(error("web_not_ready", "Strava 网页登录已失效，请重新登录"))
      return
    }
    operation = .listing
    Task {
      let session = Self.makeIsolatedSession()
      defer { session.invalidateAndCancel() }
      do {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://www.strava.com/athlete/training", forHTTPHeaderField: "Referer")
        let (data, response) = try await Self.boundedResponse(for: request, session: session)
        guard Self.isAuthenticatedProbe(statusCode: response.statusCode, finalURL: response.url, body: data),
          let json = String(data: data, encoding: .utf8)
        else { throw URLError(.badServerResponse) }
        await MainActor.run { self.operation = .idle; result(json) }
      } catch {
        await MainActor.run {
          self.operation = .idle
          result(self.error("web_list_failed", "无法读取 Strava 网页活动列表，请重新登录后重试", retryable: true))
        }
      }
    }
  }

  private static func integerArgument(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
      number.doubleValue == Double(number.int64Value)
    else { return nil }
    return number.int64Value
  }

  static func activityPageURL(page: Int64, afterMs: Int64, beforeMs: Int64) -> URL? {
    guard (1...200).contains(page), afterMs < beforeMs,
      afterMs >= -2_208_988_800_000, beforeMs <= 7_258_118_400_000
    else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "MM/dd/yyyy"
    // Date-only server filters may use the athlete's timezone; widen by one day.
    let start = Date(timeIntervalSince1970: Double(afterMs) / 1_000 - 86_400)
    let end = Date(timeIntervalSince1970: Double(beforeMs) / 1_000 + 86_400)
    var components = URLComponents(string: "https://www.strava.com/athlete/training_activities")!
    components.queryItems = [
      URLQueryItem(name: "start_date", value: formatter.string(from: start)),
      URLQueryItem(name: "end_date", value: formatter.string(from: end)),
      URLQueryItem(name: "page", value: String(page)),
      URLQueryItem(name: "new_activity_only", value: "false"),
    ]
    return components.url
  }

  private func uploadFit(arguments: Any?, result: @escaping FlutterResult) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard operation == .idle else {
      result(error("web_operation_in_progress", "Strava 网页操作正在进行，请稍后重试", retryable: true))
      return
    }
    guard
      let arguments = arguments as? [String: Any],
      let filename = arguments["filename"] as? String,
      Self.isSafeUploadFilename(filename),
      let data = Self.fitData(from: arguments["data"]),
      !data.isEmpty, data.count <= Self.maximumUploadBytes
    else {
      result(error("invalid_arguments", "网页上传需要 FIT 字节和安全文件名"))
      return
    }
    let stored = readCookieHeader()
    if let storedError = stored.error {
      result(storedError)
      return
    }
    guard let cookieHeader = Self.normalizedStoredCookieHeader(stored.value) else {
      result(error("web_not_ready", "Strava 网页登录已失效，请重新登录"))
      return
    }
    operation = .uploading
    Task {
      do {
        let payload = try await Self.performCookieUpload(
          data: data,
          filename: filename,
          cookieHeader: cookieHeader
        )
        await MainActor.run {
          self.operation = .idle
          result(payload)
        }
      } catch {
        await MainActor.run {
          self.operation = .idle
          result(self.error("web_upload_failed", "Strava 网页上传失败，请重新登录后重试", retryable: true))
        }
      }
    }
  }

  static func isSafeUploadFilename(_ filename: String) -> Bool {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    return !filename.isEmpty
      && filename.utf8.count <= 128
      && filename.lowercased().hasSuffix(".fit")
      && filename.rangeOfCharacter(from: allowed.inverted) == nil
      && !filename.contains("..")
  }

  static func extractCSRFToken(from html: String) -> String? {
    extractCSRFPair(from: html)?.token
  }

  static func extractCSRFPair(from html: String) -> (param: String, token: String)? {
    let tagPattern = #"<(?:meta|input)\b[^>]*>"#
    guard let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: .caseInsensitive),
      let attributeRegex = try? NSRegularExpression(
        pattern: #"([a-zA-Z_-]+)\s*=\s*(["'])(.*?)\2"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
      )
    else { return nil }
    var token: String?
    var parameter = "authenticity_token"
    for match in tagRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
      guard let range = Range(match.range, in: html) else { continue }
      let tag = String(html[range])
      var attributes: [String: String] = [:]
      for attribute in attributeRegex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
        guard let nameRange = Range(attribute.range(at: 1), in: tag),
          let valueRange = Range(attribute.range(at: 3), in: tag)
        else { continue }
        attributes[String(tag[nameRange]).lowercased()] = String(tag[valueRange])
      }
      let name = attributes["name"]?.lowercased()
      if name == "csrf-param", let value = attributes["content"] { parameter = value }
      let candidate = name == "csrf-token" ? attributes["content"]
        : name == "authenticity_token" ? attributes["value"] : nil
      if token == nil, let candidate, !candidate.isEmpty, candidate.utf8.count <= 4_096,
        candidate.utf8.allSatisfy({ (0x21...0x7e).contains($0) })
      { token = candidate }
    }
    guard let token, isValidCookieName(parameter), parameter.utf8.count <= 128,
      parameter != "_method"
    else { return nil }
    return (parameter, token)
  }

  static func isSuccessfulDeletion(
    statusCode: Int, finalURL: URL?, remoteId: String, location: String?, body: Data
  ) -> Bool {
    guard activityURL(remoteId: remoteId) != nil,
      isExpectedEndpoint(finalURL, path: "/activities/\(remoteId)"),
      body.count <= maximumResponseBytes
    else { return false }
    if statusCode == 404 { return true }
    let text = String(data: body, encoding: .utf8) ?? ""
    if statusCode == 401 || statusCode == 403 || text.localizedCaseInsensitiveContains("log in") {
      return false
    }
    if (300..<400).contains(statusCode), let location,
      let destination = URL(string: location, relativeTo: finalURL)?.absoluteURL
    {
      return isExpectedEndpoint(destination, path: "/athlete/training")
        || isExpectedEndpoint(destination, path: "/dashboard")
    }
    return statusCode == 200 || statusCode == 204
  }

  private static func performCookieDelete(remoteId: String, cookieHeader: String) async throws {
    guard let url = activityURL(remoteId: remoteId) else { throw URLError(.badURL) }
    let session = makeIsolatedSession()
    defer { session.invalidateAndCancel() }
    var csrf: (param: String, token: String)?
    for path in [url.path, "/about", "/upload/select"] {
      var request = URLRequest(url: URL(string: "https://www.strava.com\(path)")!)
      request.httpShouldHandleCookies = false
      request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
      let (data, response) = try await boundedResponse(for: request, session: session)
      if response.statusCode == 404 && path == url.path { return }
      if response.statusCode == 401 || response.statusCode == 403 || (300..<400).contains(response.statusCode) {
        throw URLError(.userAuthenticationRequired)
      }
      if response.statusCode == 200, let html = String(data: data, encoding: .utf8) {
        csrf = extractCSRFPair(from: html)
      }
      if csrf != nil { break }
    }
    guard let csrf else { throw URLError(.userAuthenticationRequired) }
    let formAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    guard let parameter = csrf.param.addingPercentEncoding(withAllowedCharacters: formAllowed),
      let token = csrf.token.addingPercentEncoding(withAllowedCharacters: formAllowed)
    else { throw URLError(.badServerResponse) }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
    request.setValue("https://www.strava.com", forHTTPHeaderField: "Origin")
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
    request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
    request.httpBody = Data("_method=delete&\(parameter)=\(token)".utf8)
    // Submit once only. A transport failure must leave recovery pending, never replay a deletion.
    let (data, response) = try await boundedResponse(for: request, session: session)
    guard isSuccessfulDeletion(
      statusCode: response.statusCode, finalURL: response.url, remoteId: remoteId,
      location: response.value(forHTTPHeaderField: "Location"), body: data
    ) else { throw URLError(.badServerResponse) }
  }

  static func duplicateActivityId(from body: String) -> String? {
    guard body.range(of: "duplicate", options: .caseInsensitive) != nil else { return nil }
    for pattern in [#"duplicate of activity (\d+)"#, #"/activities/(\d+)"#] {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
        let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
        let range = Range(match.range(at: 1), in: body)
      else { continue }
      return String(body[range])
    }
    return nil
  }

  static func isExpectedEndpoint(_ url: URL?, path: String) -> Bool {
    guard let url else { return false }
    return url.scheme?.lowercased() == "https"
      && url.host?.lowercased() == cookieRequestHost
      && (url.port == nil || url.port == 443)
      && url.user == nil && url.password == nil && url.path == path
  }

  static func uploadResponse(statusCode: Int, finalURL: URL?, body: Data) throws -> [String: Any] {
    guard isExpectedEndpoint(finalURL, path: "/upload/files"),
      body.count <= maximumResponseBytes,
      (200..<300).contains(statusCode) || [400, 409, 422].contains(statusCode)
    else { throw URLError(.badServerResponse) }
    let text = String(data: body, encoding: .utf8) ?? ""
    let duplicateId = duplicateActivityId(from: text)
    let isDuplicate = duplicateId != nil || text.range(
      of: #"duplicate of(?: activity|\s*<a)"#,
      options: [.regularExpression, .caseInsensitive]
    ) != nil
    if isDuplicate {
      var payload: [String: Any] = ["isDuplicate": true]
      // Never box Optional.none into the Flutter standard codec.
      if let duplicateId { payload["remoteId"] = duplicateId }
      return payload
    }
    guard (200..<300).contains(statusCode) else { throw URLError(.badServerResponse) }
    return ["isDuplicate": false]
  }

  static func makeIsolatedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 120
    return URLSession(
      configuration: configuration,
      delegate: StravaWebNoRedirectDelegate(),
      delegateQueue: nil
    )
  }

  private static func boundedResponse(
    for request: URLRequest,
    session: URLSession
  ) async throws -> (Data, HTTPURLResponse) {
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse,
      isExpectedEndpoint(http.url, path: request.url?.path ?? ""),
      http.expectedContentLength <= Int64(maximumResponseBytes)
    else { throw URLError(.badServerResponse) }
    var data = Data()
    for try await byte in bytes {
      guard data.count < maximumResponseBytes else { throw URLError(.dataLengthExceedsMaximum) }
      data.append(byte)
    }
    return (data, http)
  }

  private static func fitData(from value: Any?) -> Data? {
    if let typed = value as? FlutterStandardTypedData { return typed.data }
    return value as? Data
  }

  private static func performCookieUpload(
    data: Data,
    filename: String,
    cookieHeader: String
  ) async throws -> [String: Any] {
    let session = makeIsolatedSession()
    defer { session.invalidateAndCancel() }
    let csrf = try await fetchCSRFToken(cookieHeader: cookieHeader, session: session)
    let boundary = "Boundary-\(UUID().uuidString)"
    var body = Data()
    func field(_ name: String, _ value: String) {
      body.append(Data("--\(boundary)\r\n".utf8))
      body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
      body.append(Data("\(value)\r\n".utf8))
    }
    field("_method", "post")
    field("authenticity_token", csrf)
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(
      Data("Content-Disposition: form-data; name=\"files[]\"; filename=\"\(filename)\"\r\n".utf8)
    )
    body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
    body.append(data)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    var request = URLRequest(url: URL(string: "https://www.strava.com/upload/files")!)
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
    request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    request.setValue("https://www.strava.com", forHTTPHeaderField: "Origin")
    request.setValue("https://www.strava.com/upload/select", forHTTPHeaderField: "Referer")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    let (responseData, response) = try await boundedResponse(for: request, session: session)
    return try uploadResponse(
      statusCode: response.statusCode, finalURL: response.url, body: responseData
    )
  }

  private static func fetchCSRFToken(cookieHeader: String, session: URLSession) async throws -> String {
    for path in ["/about", "/upload/select"] {
      try Task.checkCancellation()
      var request = URLRequest(url: URL(string: "https://www.strava.com\(path)")!)
      request.httpShouldHandleCookies = false
      request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
      request.setValue("text/html", forHTTPHeaderField: "Accept")
      let (data, response) = try await boundedResponse(for: request, session: session)
      guard response.statusCode == 200,
        let html = String(data: data, encoding: .utf8),
        let token = extractCSRFToken(from: html)
      else { continue }
      return token
    }
    throw URLError(.userAuthenticationRequired)
  }

  private func error(
    _ code: String,
    _ message: String,
    retryable: Bool = false
  ) -> FlutterError {
    FlutterError(code: code, message: message, details: retryable ? ["retryable": true] : nil)
  }
}

/// 所有带 Cookie 的请求均禁止重定向，避免凭证和 FIT 被发往其他目标。
private final class StravaWebNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
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
