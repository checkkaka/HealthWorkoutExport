import Flutter
import Foundation
import Security

/// Flutter 与系统 Keychain 的最小桥接；凭据始终保留在设备 Keychain 中。
final class KeychainPlugin: NSObject, FlutterPlugin {
  private static let channelName = "health_workout_export/keychain"
  private static let service = "com.checkkaka.HealthWorkoutExport"

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
    default:
      result(FlutterMethodNotImplemented)
    }
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
    var query = keychainQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      result(nil)
      return
    }
    guard status == errSecSuccess else {
      result(keychainError(status))
      return
    }
    guard
      let data = item as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      result(
        FlutterError(
          code: "keychain_invalid_data",
          message: "Keychain value is not valid UTF-8",
          details: nil
        )
      )
      return
    }
    result(value)
  }

  private func write(value: String, account: String, result: FlutterResult) {
    let query = keychainQuery(account: account)
    let attributes: [String: Any] = [
      kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]

    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      result(nil)
      return
    }
    guard updateStatus == errSecItemNotFound else {
      result(keychainError(updateStatus))
      return
    }

    let item = query.merging(attributes) { _, newValue in newValue }
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    result(addStatus == errSecSuccess ? nil : keychainError(addStatus))
  }

  private func delete(account: String, result: FlutterResult) {
    let status = SecItemDelete(keychainQuery(account: account) as CFDictionary)
    result(
      status == errSecSuccess || status == errSecItemNotFound
        ? nil
        : keychainError(status)
    )
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
      message: "A non-empty account and required value are expected",
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
}
