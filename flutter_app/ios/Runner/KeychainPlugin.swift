import Flutter
import Foundation
import Security

/// Flutter 与系统 Keychain 的最小桥接；凭据始终保留在设备 Keychain 中。
final class KeychainPlugin: NSObject, FlutterPlugin {
  private static let channelName = "health_workout_export/keychain"
  private static let service = "com.checkkaka.HealthWorkoutExport"
  private static let stravaClientIDAccount = "strava.clientId"
  private static let stravaClientSecretAccount = "strava.clientSecret"
  private static let stravaAccessTokenAccount = "strava.accessToken"
  private static let stravaRefreshTokenAccount = "strava.refreshToken"
  private static let stravaExpiresAtKey = "strava.expiresAt"

  struct StravaAuthorization {
    let clientId: String
    let clientSecret: String
    let accessToken: String
    let refreshToken: String
    let expiresAtSeconds: Double
  }

  enum AuthorizationError: Error {
    case invalidArguments
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = KeychainPlugin()
    channel.setMethodCallHandler(instance.handle)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "read":
      guard let account = account(from: call) else {
        result(invalidArguments())
        return
      }
      read(account: account, result: result)
    case "write":
      guard
        let account = account(from: call),
        let arguments = call.arguments as? [String: Any],
        let value = arguments["value"] as? String
      else {
        result(invalidArguments())
        return
      }
      write(value: value, account: account, result: result)
    case "delete":
      guard let account = account(from: call) else {
        result(invalidArguments())
        return
      }
      delete(account: account, result: result)
    case "writeStravaAuthorization":
      do {
        writeStravaAuthorization(
          try Self.parseStravaAuthorization(arguments: call.arguments),
          result: result
        )
      } catch {
        result(invalidArguments())
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func parseStravaAuthorization(arguments: Any?) throws -> StravaAuthorization {
    guard
      let arguments = arguments as? [String: Any],
      let clientId = arguments["clientId"] as? String,
      !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let clientSecret = arguments["clientSecret"] as? String,
      !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let accessToken = arguments["accessToken"] as? String,
      !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let refreshToken = arguments["refreshToken"] as? String,
      !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let expiresAtSeconds = arguments["expiresAtSeconds"] as? Double,
      expiresAtSeconds.isFinite,
      expiresAtSeconds > 0
    else {
      throw AuthorizationError.invalidArguments
    }
    return StravaAuthorization(
      clientId: clientId,
      clientSecret: clientSecret,
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAtSeconds: expiresAtSeconds
    )
  }

  private func account(from call: FlutterMethodCall) -> String? {
    guard
      let arguments = call.arguments as? [String: Any],
      let account = arguments["account"] as? String,
      !account.isEmpty
    else {
      return nil
    }
    return account
  }

  private func read(account: String, result: FlutterResult) {
    let stored = storedValue(account: account)
    if let error = stored.error {
      result(error)
    } else {
      result(stored.value)
    }
  }

  private func write(value: String, account: String, result: FlutterResult) {
    result(store(value: value, account: account))
  }

  private func delete(account: String, result: FlutterResult) {
    result(remove(account: account))
  }

  /// OAuth 成功后一次提交完整授权；任一 Keychain 写入失败则恢复原值。
  private func writeStravaAuthorization(
    _ authorization: StravaAuthorization,
    result: FlutterResult
  ) {
    let outcome = Self.performStravaAuthorizationTransaction(
      authorization,
      read: { self.storedValue(account: $0) },
      write: { self.store(value: $1, account: $0) },
      restore: { self.restore($0, account: $1) }
    )
    if outcome.rollbackFailed {
      result(rollbackError())
      return
    }
    if let error = outcome.error {
      result(error)
      return
    }
    UserDefaults.standard.set(authorization.expiresAtSeconds, forKey: Self.stravaExpiresAtKey)
    result(nil)
  }

  static func performStravaAuthorizationTransaction(
    _ authorization: StravaAuthorization,
    read: (String) -> (value: String?, error: FlutterError?),
    write: (String, String) -> FlutterError?,
    restore: (String?, String) -> Bool
  ) -> (error: FlutterError?, rollbackFailed: Bool) {
    let values = [
      (Self.stravaClientIDAccount, authorization.clientId),
      (Self.stravaClientSecretAccount, authorization.clientSecret),
      (Self.stravaRefreshTokenAccount, authorization.refreshToken),
      (Self.stravaAccessTokenAccount, authorization.accessToken),
    ]
    var previous: [String: String?] = [:]
    for (account, _) in values {
      let stored = read(account)
      if let error = stored.error {
        return (error, false)
      }
      previous[account] = stored.value
    }

    var written: [String] = []
    for (account, value) in values {
      if let error = write(account, value) {
        var restored = true
        for writtenAccount in written.reversed() {
          if !restore(previous[writtenAccount] ?? nil, writtenAccount) {
            restored = false
          }
        }
        return (error, !restored)
      }
      written.append(account)
    }
    return (nil, false)
  }

  private func storedValue(account: String) -> (value: String?, error: FlutterError?) {
    var query = keychainQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return (nil, nil) }
    guard status == errSecSuccess else { return (nil, keychainError(status)) }
    guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
      return (
        nil,
        FlutterError(
          code: "keychain_invalid_data",
          message: "Keychain value is not valid UTF-8",
          details: nil
        )
      )
    }
    return (value, nil)
  }

  private func store(value: String, account: String) -> FlutterError? {
    let query = keychainQuery(account: account)
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

  private func remove(account: String) -> FlutterError? {
    let status = SecItemDelete(keychainQuery(account: account) as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound ? nil : keychainError(status)
  }

  private func restore(_ value: String?, account: String) -> Bool {
    if let value {
      return store(value: value, account: account) == nil
    }
    return remove(account: account) == nil
  }

  private func keychainQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: account,
    ]
  }

  private func invalidArguments() -> FlutterError {
    FlutterError(
      code: "invalid_arguments",
      message: "Non-empty required values are expected",
      details: nil
    )
  }

  private func keychainError(_ status: OSStatus) -> FlutterError {
    FlutterError(
      code: "keychain_error",
      message: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain operation failed",
      details: ["status": Int(status)]
    )
  }

  private func rollbackError() -> FlutterError {
    FlutterError(
      code: "keychain_rollback_failed",
      message: "Keychain authorization transaction failed and rollback was incomplete",
      details: nil
    )
  }
}
