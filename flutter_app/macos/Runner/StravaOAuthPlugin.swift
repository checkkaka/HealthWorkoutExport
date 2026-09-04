import Foundation
import Security

enum StravaOAuthSecurityError: Error {
  case invalidAuthorizationURL
  case existingState
  case randomGenerationFailed
}

/// OAuth 边界的可测试纯规则；授权码与完整回调地址不会在本地持久化或记录。
enum StravaOAuthSecurity {
  static let expectedCallbackScheme = "healthworkoutexport"

  static func makeState() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw StravaOAuthSecurityError.randomGenerationFailed
    }
    return Data(bytes)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func authorizationURL(from rawURL: String, state: String) throws -> URL {
    guard
      var components = URLComponents(string: rawURL),
      components.scheme?.lowercased() == "https",
      components.host?.lowercased() == "www.strava.com",
      components.path == "/oauth/mobile/authorize",
      components.queryItems?.contains(where: { $0.name == "state" }) != true
    else {
      if URLComponents(string: rawURL)?.queryItems?.contains(where: { $0.name == "state" }) == true
      {
        throw StravaOAuthSecurityError.existingState
      }
      throw StravaOAuthSecurityError.invalidAuthorizationURL
    }
    components.queryItems =
      (components.queryItems ?? []) + [URLQueryItem(name: "state", value: state)]
    guard let url = components.url else {
      throw StravaOAuthSecurityError.invalidAuthorizationURL
    }
    return url
  }

  static func isValidCallback(
    _ callback: URL,
    callbackScheme: String,
    expectedState: String
  ) -> Bool {
    guard
      callback.scheme?.caseInsensitiveCompare(callbackScheme) == .orderedSame,
      callback.host?.lowercased() == "localhost",
      callback.path == "/callback"
    else {
      return false
    }
    let states =
      URLComponents(url: callback, resolvingAgainstBaseURL: false)?
      .queryItems?
      .filter { $0.name == "state" }
      .compactMap(\.value) ?? []
    return states.count == 1 && constantTimeEqual(states[0], expectedState)
  }

  static func isValidCallbackScheme(_ scheme: String) -> Bool {
    let bytes = Array(scheme.utf8)
    guard let first = bytes.first, isASCIIAlpha(first) else { return false }
    return bytes.dropFirst().allSatisfy {
      isASCIIAlpha($0) || (48...57).contains($0) || $0 == 43 || $0 == 45 || $0 == 46
    }
  }

  private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte)
  }

  private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}

#if os(iOS) || os(macOS)
  import AuthenticationServices
  #if os(iOS)
    import Flutter
    import UIKit
  #else
    import AppKit
    import FlutterMacOS
  #endif

  /// Flutter 的 Strava OAuth 浏览器会话边界；token 交换与保存留给 Dart/Rust 层。
  final class StravaOAuthPlugin: NSObject, FlutterPlugin {
    private static let channelName = "health_workout_export/strava_oauth"
    private var authSession: ASWebAuthenticationSession?

    static func register(with registrar: FlutterPluginRegistrar) {
      let plugin = StravaOAuthPlugin()
      #if os(iOS)
        let messenger = registrar.messenger()
      #else
        let messenger = registrar.messenger
      #endif
      let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
      channel.setMethodCallHandler(plugin.handle)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      guard call.method == "authorize" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let authorizationURL = arguments["authorizationUrl"] as? String,
        let callbackScheme = arguments["callbackScheme"] as? String,
        !authorizationURL.isEmpty,
        StravaOAuthSecurity.isValidCallbackScheme(callbackScheme),
        callbackScheme.caseInsensitiveCompare(StravaOAuthSecurity.expectedCallbackScheme)
          == .orderedSame
      else {
        result(error("invalid_arguments", "authorizationUrl 和合法 callbackScheme 均不能为空"))
        return
      }
      DispatchQueue.main.async { [weak self] in
        self?.authorize(
          authorizationURL: authorizationURL,
          callbackScheme: callbackScheme,
          result: result
        )
      }
    }

    private func authorize(
      authorizationURL: String,
      callbackScheme: String,
      result: @escaping FlutterResult
    ) {
      guard authSession == nil else {
        result(error("oauth_in_progress", "已有 Strava 授权正在进行"))
        return
      }

      let state: String
      let url: URL
      do {
        state = try StravaOAuthSecurity.makeState()
        url = try StravaOAuthSecurity.authorizationURL(from: authorizationURL, state: state)
      } catch StravaOAuthSecurityError.existingState {
        result(error("invalid_arguments", "authorizationUrl 不得预置 state"))
        return
      } catch {
        result(self.error("oauth_configuration_error", "Strava 授权地址或随机状态无效"))
        return
      }

      let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) {
        [weak self] callback, sessionError in
        DispatchQueue.main.async {
          guard let self else { return }
          self.authSession = nil
          if let sessionError {
            let code = (sessionError as? ASWebAuthenticationSessionError)?.code
            result(
              code == .canceledLogin
                ? self.error("oauth_cancelled", "已取消 Strava 授权")
                : self.error("oauth_failed", "Strava 授权会话失败")
            )
            return
          }
          guard
            let callback,
            StravaOAuthSecurity.isValidCallback(
              callback,
              callbackScheme: callbackScheme,
              expectedState: state
            )
          else {
            result(self.error("oauth_invalid_callback", "Strava 回调 scheme 或 state 校验失败"))
            return
          }

          let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
          if items.contains(where: { $0.name == "error" && $0.value == "access_denied" }) {
            result(self.error("oauth_cancelled", "已取消 Strava 授权"))
            return
          }
          if items.contains(where: { $0.name == "error" }) {
            result(self.error("oauth_failed", "Strava 拒绝了授权请求"))
            return
          }
          let codes = items.filter { $0.name == "code" }.compactMap(\.value).filter { !$0.isEmpty }
          guard codes.count == 1 else {
            result(self.error("oauth_invalid_callback", "Strava 回调缺少唯一授权码"))
            return
          }
          result(codes[0])
        }
      }
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = false
      authSession = session
      if !session.start() {
        authSession = nil
        result(error("oauth_failed", "无法启动 Strava 授权会话"))
      }
    }

    private func error(_ code: String, _ message: String) -> FlutterError {
      FlutterError(code: code, message: message, details: nil)
    }
  }

  extension StravaOAuthPlugin: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
      #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }),
          let window = activeScene.windows.first(where: { $0.isKeyWindow })
            ?? activeScene.windows.first(where: { !$0.isHidden })
        {
          return window
        }
        return scenes.flatMap(\.windows).first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
      #else
        return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
      #endif
    }
  }
#endif
