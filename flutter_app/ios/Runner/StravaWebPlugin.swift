import Flutter
import Foundation
import Security
import UIKit
import WebKit

/// Strava 网页登录原生边界。Cookie 始终留在 iOS，并只用于固定的 Strava 请求目标。
final class StravaWebPlugin: NSObject, FlutterPlugin {
  static let maximumCookieHeaderBytes = 16_384

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
    case clearing
  }

  private var operation = Operation.idle
  private var pendingLoginResult: FlutterResult?
  private var loginController: UINavigationController?
  private var probeSession: URLSession?
  private var probeTask: URLSessionDataTask?

  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
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
      finalURL?.scheme?.lowercased() == "https",
      finalURL?.host?.lowercased() == cookieRequestHost,
      finalURL?.path == "/athlete/training_activities",
      let object = try? JSONSerialization.jsonObject(with: body),
      let root = object as? [String: Any]
    else { return false }
    return root["models"] is [Any] || root["activities"] is [Any]
  }

  static func isAllowedLoginNavigation(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
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

  private static func normalizedStoredCookieHeader(_ rawValue: String?) -> String? {
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
    guard let host = topViewController() else {
      result(error("web_login_unavailable", "无法显示 Strava 网页登录", retryable: true))
      return
    }

    operation = .login
    pendingLoginResult = result
    let controller = StravaWebLoginController(
      loginURL: Self.loginURL,
      onCancel: { [weak self] in
        guard let self else { return }
        finishLogin(with: error("web_login_cancelled", "已取消 Strava 网页登录"))
      },
      onFinish: { [weak self] cookies in self?.verifyAndSaveLogin(cookies: cookies) }
    )
    let navigation = UINavigationController(rootViewController: controller)
    navigation.isModalInPresentation = true
    loginController = navigation
    host.present(navigation, animated: true) { [weak self, weak navigation] in
      guard let self, operation == .login, navigation?.presentingViewController == nil else {
        return
      }
      finishLogin(with: error("web_login_unavailable", "无法显示 Strava 网页登录", retryable: true))
    }
  }

  private func verifyAndSaveLogin(cookies: [HTTPCookie]) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard operation == .login else { return }
    guard let header = Self.cookieHeader(from: cookies) else {
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
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let session = URLSession(
      configuration: configuration,
      delegate: StravaWebNoRedirectDelegate(),
      delegateQueue: nil
    )
    probeSession = session
    var request = URLRequest(url: Self.probeURL)
    request.timeoutInterval = 15
    request.httpShouldHandleCookies = false
    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    request.setValue("https://www.strava.com/athlete/training", forHTTPHeaderField: "Referer")
    let task = session.dataTask(with: request) { data, response, networkError in
      DispatchQueue.main.async {
        guard self.operation == .probing else { return }
        if networkError != nil {
          completion(
            self.error(
              "web_login_verification_failed",
              "无法验证 Strava 网页登录，请重试",
              retryable: true
            ))
          return
        }
        guard let http = response as? HTTPURLResponse,
          Self.isAuthenticatedProbe(
            statusCode: http.statusCode,
            finalURL: http.url,
            body: data ?? Data()
          )
        else {
          completion(
            self.error("web_login_not_ready", "Strava 尚未登录成功，请重新登录", retryable: true)
          )
          return
        }
        completion(nil)
      }
    }
    probeTask = task
    task.resume()
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
    let controller = loginController
    loginController = nil
    controller?.viewControllers.compactMap { $0 as? StravaWebLoginController }
      .forEach { $0.stopLoading() }
    operation = .idle
    if controller?.presentingViewController != nil {
      controller?.dismiss(animated: true)
    }
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

  @objc private func applicationDidEnterBackground() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard operation == .login || operation == .probing else { return }
    finishLogin(
      with: error("web_login_interrupted", "Strava 网页登录已中断，请重试", retryable: true)
    )
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
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
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

  private func topViewController() -> UIViewController? {
    guard
      let active = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }),
      var top = active.windows.first(where: { $0.isKeyWindow })?.rootViewController
        ?? active.windows.first(where: { !$0.isHidden })?.rootViewController
    else { return nil }
    while let presented = top.presentedViewController { top = presented }
    return top
  }

  private func keychainError(_ status: OSStatus) -> FlutterError {
    FlutterError(
      code: "keychain_error",
      message: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain operation failed",
      details: ["status": Int(status)]
    )
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
      !data.isEmpty
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
    operation = .probing
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
    if let range = html.range(of: #"name="csrf-token" content="([^"]+)""#, options: .regularExpression) {
      let tag = String(html[range])
      if let tokenRange = tag.range(of: #"content="([^"]+)""#, options: .regularExpression) {
        let token = String(tag[tokenRange])
          .replacingOccurrences(of: "content=\"", with: "")
          .replacingOccurrences(of: "\"", with: "")
        if !token.isEmpty { return token }
      }
    }
    if let range = html.range(
      of: #"name="authenticity_token" value="([^"]+)""#,
      options: .regularExpression
    ) {
      let tag = String(html[range])
      if let tokenRange = tag.range(of: #"value="([^"]+)""#, options: .regularExpression) {
        let token = String(tag[tokenRange])
          .replacingOccurrences(of: "value=\"", with: "")
          .replacingOccurrences(of: "\"", with: "")
        if !token.isEmpty { return token }
      }
    }
    return nil
  }

  static func duplicateActivityId(from body: String) -> String? {
    guard let range = body.range(of: #"/activities/(\d+)"#, options: .regularExpression) else {
      return nil
    }
    let match = String(body[range])
    return match.split(separator: "/").last.map(String.init)
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
    let csrf = try await fetchCSRFToken(cookieHeader: cookieHeader)
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
    let (respData, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    let text = String(data: respData, encoding: .utf8) ?? ""
    if text.localizedCaseInsensitiveContains("duplicate") {
      return [
        "remoteId": duplicateActivityId(from: text) as Any,
        "isDuplicate": true,
      ]
    }
    guard (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return ["isDuplicate": false]
  }

  private static func fetchCSRFToken(cookieHeader: String) async throws -> String {
    for path in ["/about", "/upload/select"] {
      var request = URLRequest(url: URL(string: "https://www.strava.com\(path)")!)
      request.httpShouldHandleCookies = false
      request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
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

/// 登录探测不跟随重定向，避免手工 Cookie 头被带到重定向目标。
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

private final class StravaWebLoginController: UIViewController, WKNavigationDelegate {
  private let loginURL: URL
  private let onCancel: () -> Void
  private let onFinish: ([HTTPCookie]) -> Void
  private var isFinishing = false
  private var webView: WKWebView?

  init(loginURL: URL, onCancel: @escaping () -> Void, onFinish: @escaping ([HTTPCookie]) -> Void) {
    self.loginURL = loginURL
    self.onCancel = onCancel
    self.onFinish = onFinish
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "登录 Strava"
    let configuration = WKWebViewConfiguration()
    // 登录、读取和 clearCookies 共用默认 Cookie store，确保清理语义可验证。
    configuration.websiteDataStore = .default()
    let webView = WKWebView(frame: view.bounds, configuration: configuration)
    self.webView = webView
    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    webView.navigationDelegate = self
    view.addSubview(webView)
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "取消", style: .plain, target: self, action: #selector(cancel)
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "完成", style: .done, target: self, action: #selector(finish)
    )
    webView.load(URLRequest(url: loginURL))
  }

  func stopLoading() {
    webView?.stopLoading()
    webView?.navigationDelegate = nil
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url,
      StravaWebPlugin.isAllowedLoginNavigation(url)
    else {
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

  @objc private func cancel() {
    guard !isFinishing else { return }
    isFinishing = true
    stopLoading()
    onCancel()
  }

  @objc private func finish() {
    guard !isFinishing else { return }
    isFinishing = true
    stopLoading()
    navigationItem.rightBarButtonItem?.isEnabled = false
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
      DispatchQueue.main.async { self?.onFinish(cookies) }
    }
  }
}
