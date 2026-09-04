import AppKit
import FlutterMacOS
import Foundation
import Security
import WebKit

/// macOS Strava 网页登录：WKWebView 窗口 + Keychain Cookie + CSRF 上传。
final class StravaWebPlugin: NSObject, FlutterPlugin, WKNavigationDelegate {
  static let maximumCookieHeaderBytes = 16_384
  private static let channelName = "health_workout_export/strava_web"
  private static let keychainService = "com.checkkaka.HealthWorkoutExport"
  private static let cookieAccount = "strava.webCookie"
  private static let loginURL = URL(string: "https://www.strava.com/login")!
  private static let loginHosts: Set<String> = [
    "strava.com", "www.strava.com", "accounts.google.com", "appleid.apple.com",
    "facebook.com", "www.facebook.com", "m.facebook.com",
  ]

  private var pendingLogin: FlutterResult?
  private var loginWindow: NSWindow?
  private var webView: WKWebView?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger)
    channel.setMethodCallHandler(StravaWebPlugin().handle)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "login":
      DispatchQueue.main.async { self.presentLogin(result: result) }
    case "hasCookie":
      result(Self.normalizedHeader(self.readCookie()) != nil)
    case "clearCookies":
      DispatchQueue.main.async { self.clearCookies(result: result) }
    case "uploadFit":
      DispatchQueue.main.async { self.uploadFit(arguments: call.arguments, result: result) }
    default:
      result(FlutterMethodNotImplemented)
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
    guard
      let range = html.range(of: #"name="csrf-token" content="([^"]+)""#, options: .regularExpression)
    else { return nil }
    let tag = String(html[range])
    guard let tokenRange = tag.range(of: #"content="([^"]+)""#, options: .regularExpression) else {
      return nil
    }
    let token = String(tag[tokenRange])
      .replacingOccurrences(of: "content=\"", with: "")
      .replacingOccurrences(of: "\"", with: "")
    return token.isEmpty ? nil : token
  }

  private func presentLogin(result: @escaping FlutterResult) {
    guard pendingLogin == nil else {
      result(
        FlutterError(code: "web_operation_in_progress", message: "已有网页登录正在进行", details: nil)
      )
      return
    }
    pendingLogin = result
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 640))
    webView.navigationDelegate = self
    self.webView = webView
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Strava 登录"
    let done = NSButton(
      title: "完成登录",
      target: self,
      action: #selector(completeLogin)
    )
    done.frame = NSRect(x: 12, y: 640, width: 120, height: 28)
    webView.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 680))
    container.addSubview(webView)
    container.addSubview(done)
    window.contentView = container
    window.delegate = self
    window.center()
    window.makeKeyAndOrderFront(nil)
    loginWindow = window
    webView.load(URLRequest(url: Self.loginURL))
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let host = navigationAction.request.url?.host?.lowercased(),
      let scheme = navigationAction.request.url?.scheme?.lowercased(),
      scheme == "https",
      Self.loginHosts.contains(host) || host.hasSuffix(".strava.com")
    else {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  @objc private func completeLogin() {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
      guard let self else { return }
      let header = Self.cookieHeader(from: cookies)
      if let header, self.storeCookie(header) == nil {
        self.finishLogin(true)
      } else {
        self.finishLogin(
          FlutterError(code: "web_login_failed", message: "未找到可用的 Strava 登录 Cookie", details: nil)
        )
      }
    }
  }

  private func finishLogin(_ value: Any?) {
    let result = pendingLogin
    pendingLogin = nil
    loginWindow?.delegate = nil
    loginWindow?.close()
    loginWindow = nil
    webView = nil
    result?(value)
  }

  private func clearCookies(result: @escaping FlutterResult) {
    _ = removeCookie()
    let store = WKWebsiteDataStore.default().httpCookieStore
    store.getAllCookies { cookies in
      let group = DispatchGroup()
      for cookie in cookies where cookie.domain.lowercased().contains("strava.com") {
        group.enter()
        store.delete(cookie) { group.leave() }
      }
      group.notify(queue: .main) { result(nil) }
    }
  }

  private func uploadFit(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let arguments = arguments as? [String: Any],
      let filename = arguments["filename"] as? String,
      Self.isSafeUploadFilename(filename),
      let typed = arguments["data"] as? FlutterStandardTypedData,
      !typed.data.isEmpty,
      let cookie = Self.normalizedHeader(readCookie())
    else {
      result(FlutterError(code: "invalid_arguments", message: "网页上传需要 FIT 与已登录 Cookie", details: nil))
      return
    }
    Task {
      do {
        let payload = try await Self.performCookieUpload(
          data: typed.data,
          filename: filename,
          cookieHeader: cookie
        )
        await MainActor.run { result(payload) }
      } catch {
        await MainActor.run {
          result(
            FlutterError(
              code: "web_upload_failed",
              message: "Strava 网页上传失败，请重新登录后重试",
              details: nil
            )
          )
        }
      }
    }
  }

  private static func performCookieUpload(
    data: Data,
    filename: String,
    cookieHeader: String
  ) async throws -> [String: Any] {
    var csrf: String?
    for path in ["/about", "/upload/select"] {
      var request = URLRequest(url: URL(string: "https://www.strava.com\(path)")!)
      request.httpShouldHandleCookies = false
      request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
      let (body, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        let html = String(data: body, encoding: .utf8)
      else { continue }
      csrf = extractCSRFToken(from: html)
      if csrf != nil { break }
    }
    guard let csrf else { throw URLError(.userAuthenticationRequired) }
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
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    let (respData, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    let text = String(data: respData, encoding: .utf8) ?? ""
    if text.localizedCaseInsensitiveContains("duplicate") {
      return ["isDuplicate": true]
    }
    guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
    return ["isDuplicate": false]
  }

  private static func cookieHeader(from cookies: [HTTPCookie]) -> String? {
    let parts = cookies.compactMap { cookie -> String? in
      var domain = cookie.domain.lowercased()
      while domain.hasPrefix(".") { domain.removeFirst() }
      guard domain == "strava.com" || domain.hasSuffix(".strava.com") else { return nil }
      guard !cookie.name.isEmpty, !cookie.value.isEmpty else { return nil }
      return "\(cookie.name)=\(cookie.value)"
    }
    guard !parts.isEmpty else { return nil }
    let header = parts.joined(separator: "; ")
    return header.utf8.count <= maximumCookieHeaderBytes ? header : nil
  }

  private static func normalizedHeader(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty || value.utf8.count > maximumCookieHeaderBytes ? nil : value
  }

  private func keychainQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: Self.cookieAccount,
    ]
  }

  private func readCookie() -> String? {
    var query = keychainQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func storeCookie(_ value: String) -> OSStatus? {
    let query = keychainQuery()
    let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
    let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if update == errSecSuccess { return nil }
    guard update == errSecItemNotFound else { return update }
    let add = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    return add == errSecSuccess ? nil : add
  }

  private func removeCookie() -> OSStatus? {
    let status = SecItemDelete(keychainQuery() as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound ? nil : status
  }
}

extension StravaWebPlugin: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    if pendingLogin != nil {
      finishLogin(false)
    }
  }
}
