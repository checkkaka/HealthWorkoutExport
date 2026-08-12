import Flutter
import Foundation
import Security

/// 行者和顽鹿的固定键凭据 vault；MethodChannel 不接受 account/key 参数。
final class ThirdPartyVaultPlugin: NSObject, FlutterPlugin {
  private static let channelName = "health_workout_export/third_party_vault"
  private static let service = "com.checkkaka.HealthWorkoutExport"

  enum Vault: String {
    case xingzhe
    case onelap

    var accounts: [String] {
      switch self {
      case .xingzhe: ["xingzhe.account", "xingzhe.password", "xingzhe.session"]
      case .onelap: ["onelap.account", "onelap.password", "onelap.token", "onelap.uid"]
      }
    }

    var journalAccount: String { "\(rawValue).vaultJournal" }
    var displayName: String { self == .xingzhe ? "行者" : "顽鹿" }
  }

  struct XingzheAuthorization {
    let account: String
    let password: String
    let sessionId: String
  }

  struct OnelapAuthorization {
    let account: String
    let password: String
    let token: String
    let uid: String
  }

  struct StateEntry: Codable {
    let account: String
    let value: String?
  }

  private struct VaultJournal: Codable {
    let previous: [StateEntry]
  }

  enum AuthorizationError: Error { case invalidArguments }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler(ThirdPartyVaultPlugin().handle)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let operation = Operation(rawValue: call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    DispatchQueue.main.async {
      if let error = self.recoverJournalIfNeeded(for: operation.vault) {
        result(error)
        return
      }
      switch operation {
      case .xingzheStatus, .onelapStatus:
        self.reportStatus(for: operation.vault, result: result)
      case .xingzheLease, .onelapLease:
        self.issueLease(for: operation.vault, result: result)
      case .writeXingzheAuthorization:
        do {
          let authorization = try Self.parseXingzheAuthorization(arguments: call.arguments)
          self.apply(
            values: [authorization.account, authorization.password, authorization.sessionId],
            for: .xingzhe,
            result: result
          )
        } catch { result(self.invalidArguments()) }
      case .writeOnelapAuthorization:
        do {
          let authorization = try Self.parseOnelapAuthorization(arguments: call.arguments)
          self.apply(
            values: [authorization.account, authorization.password, authorization.token, authorization.uid],
            for: .onelap,
            result: result
          )
        } catch { result(self.invalidArguments()) }
      case .clearXingzheAuthorization, .clearOnelapAuthorization:
        self.apply(values: Array(repeating: nil, count: operation.vault.accounts.count), for: operation.vault, result: result)
      }
    }
  }

  static func parseXingzheAuthorization(arguments: Any?) throws -> XingzheAuthorization {
    guard
      let arguments = arguments as? [String: Any],
      let account = nonEmpty(arguments["account"] as? String),
      let password = nonEmpty(arguments["password"] as? String),
      let sessionId = nonEmpty(arguments["sessionId"] as? String)
    else { throw AuthorizationError.invalidArguments }
    return XingzheAuthorization(account: account, password: password, sessionId: sessionId)
  }

  static func parseOnelapAuthorization(arguments: Any?) throws -> OnelapAuthorization {
    guard
      let arguments = arguments as? [String: Any],
      let account = nonEmpty(arguments["account"] as? String),
      let password = nonEmpty(arguments["password"] as? String),
      let token = nonEmpty(arguments["token"] as? String),
      let uid = nonEmpty(arguments["uid"] as? String)
    else { throw AuthorizationError.invalidArguments }
    return OnelapAuthorization(account: account, password: password, token: token, uid: uid)
  }

  static func statusPayload(for vault: Vault, values: [String: String?]) -> [String: Any] {
    var payload: [String: Any] = [
      "hasAccount": nonEmpty(values[vault.accounts[0]] ?? nil) != nil,
      "hasPassword": nonEmpty(values[vault.accounts[1]] ?? nil) != nil,
    ]
    if vault == .xingzhe {
      payload["hasSessionId"] = nonEmpty(values["xingzhe.session"] ?? nil) != nil
    } else {
      payload["hasToken"] = nonEmpty(values["onelap.token"] ?? nil) != nil
      payload["hasUid"] = nonEmpty(values["onelap.uid"] ?? nil) != nil
    }
    return payload
  }

  static func leasePayload(for vault: Vault, values: [String: String?]) -> [String: Any]? {
    guard
      let account = nonEmpty(values[vault.accounts[0]] ?? nil),
      let password = nonEmpty(values[vault.accounts[1]] ?? nil)
    else { return nil }
    switch vault {
    case .xingzhe:
      var payload: [String: Any] = ["account": account, "password": password]
      if let sessionId = nonEmpty(values["xingzhe.session"] ?? nil) {
        payload["sessionId"] = sessionId
      }
      return payload
    case .onelap:
      var payload: [String: Any] = ["account": account, "password": password]
      if
        let token = nonEmpty(values["onelap.token"] ?? nil),
        let uid = nonEmpty(values["onelap.uid"] ?? nil)
      {
        payload["token"] = token
        payload["uid"] = uid
      }
      return payload
    }
  }

  private enum Operation: String {
    case xingzheStatus, xingzheLease, writeXingzheAuthorization, clearXingzheAuthorization
    case onelapStatus, onelapLease, writeOnelapAuthorization, clearOnelapAuthorization

    var vault: Vault {
      switch self {
      case .xingzheStatus, .xingzheLease, .writeXingzheAuthorization, .clearXingzheAuthorization: .xingzhe
      case .onelapStatus, .onelapLease, .writeOnelapAuthorization, .clearOnelapAuthorization: .onelap
      }
    }
  }

  private func reportStatus(for vault: Vault, result: FlutterResult) {
    let loaded = loadState(for: vault)
    result(loaded.error ?? Self.statusPayload(for: vault, values: loaded.values ?? [:]))
  }

  private func issueLease(for vault: Vault, result: FlutterResult) {
    let loaded = loadState(for: vault)
    if let error = loaded.error { result(error); return }
    if let payload = Self.leasePayload(for: vault, values: loaded.values ?? [:]) {
      result(payload)
    } else {
      result(vaultError("\(vault.rawValue)_not_configured", "\(vault.displayName) 凭据尚未配置"))
    }
  }

  /// 日志先记录完整旧值，clear/写入中的任一步失败都会恢复；未能回滚时日志保留供下次重试。
  private func apply(values: [String?], for vault: Vault, result: FlutterResult) {
    let loaded = loadState(for: vault)
    guard let previous = loaded.values else {
      result(loaded.error ?? vaultError("vault_read_failed", "无法读取\(vault.displayName)凭据状态"))
      return
    }
    let entries = zip(vault.accounts, values).map { StateEntry(account: $0.0, value: $0.1) }
    guard
      let journalData = try? JSONEncoder().encode(VaultJournal(previous: stateEntries(for: vault, values: previous))),
      let journal = String(data: journalData, encoding: .utf8)
    else { result(vaultError("vault_journal_failed", "无法准备\(vault.displayName)凭据事务")); return }
    if let error = store(value: journal, account: vault.journalAccount) { result(error); return }
    if let error = write(entries) {
      if restore(stateEntries(for: vault, values: previous)), remove(account: vault.journalAccount) == nil {
        result(error)
      } else { result(rollbackError(for: vault)) }
      return
    }
    if let error = remove(account: vault.journalAccount) {
      // 日志留存，下一次任何固定操作先恢复旧状态，避免暴露半提交凭据。
      result(error)
      return
    }
    result(nil)
  }

  private func recoverJournalIfNeeded(for vault: Vault) -> FlutterError? {
    let stored = storedValue(account: vault.journalAccount)
    if let error = stored.error { return error }
    guard let raw = stored.value else { return nil }
    guard
      let data = raw.data(using: .utf8),
      let journal = try? JSONDecoder().decode(VaultJournal.self, from: data),
      journal.previous.map(\.account) == vault.accounts
    else { return purgeUnrecoverableVault(vault) }
    guard restore(journal.previous), remove(account: vault.journalAccount) == nil else {
      return vaultError("\(vault.rawValue)_vault_recovery_failed", "\(vault.displayName)凭据事务恢复失败，请重试")
    }
    return nil
  }

  private func purgeUnrecoverableVault(_ vault: Vault) -> FlutterError? {
    var failed = false
    for account in vault.accounts where remove(account: account) != nil { failed = true }
    if !failed, remove(account: vault.journalAccount) == nil { return nil }
    return vaultError("\(vault.rawValue)_vault_recovery_failed", "\(vault.displayName)凭据事务恢复失败，请重试")
  }

  private func loadState(for vault: Vault) -> (values: [String: String?]?, error: FlutterError?) {
    var values: [String: String?] = [:]
    for account in vault.accounts {
      let stored = storedValue(account: account)
      if let error = stored.error { return (nil, error) }
      values[account] = stored.value
    }
    return (values, nil)
  }

  private func stateEntries(for vault: Vault, values: [String: String?]) -> [StateEntry] {
    vault.accounts.map { StateEntry(account: $0, value: values[$0] ?? nil) }
  }

  private func write(_ entries: [StateEntry]) -> FlutterError? {
    for entry in entries {
      if let error = entry.value.map({ store(value: $0, account: entry.account) }) ?? remove(account: entry.account) { return error }
    }
    return nil
  }

  private func restore(_ entries: [StateEntry]) -> Bool {
    var restored = true
    for entry in entries {
      if (entry.value.map { store(value: $0, account: entry.account) } ?? remove(account: entry.account)) != nil {
        restored = false
      }
    }
    return restored
  }

  // 仅供原生单测模拟中途失败；Flutter 没有此通用读写入口。
  static func performFixedTransaction(
    entries: [StateEntry],
    read: (String) -> (value: String?, error: FlutterError?),
    mutate: (String, String?) -> FlutterError?,
    restore: (String?, String) -> Bool
  ) -> (error: FlutterError?, rollbackFailed: Bool) {
    var previous: [String: String?] = [:]
    for entry in entries {
      let stored = read(entry.account)
      if let error = stored.error { return (error, false) }
      previous[entry.account] = stored.value
    }
    var written: [String] = []
    for entry in entries {
      if let error = mutate(entry.account, entry.value) {
        var rollbackFailed = false
        for account in written.reversed() where !restore(previous[account] ?? nil, account) {
          rollbackFailed = true
        }
        return (error, rollbackFailed)
      }
      written.append(entry.account)
    }
    return (nil, false)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
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
      return (nil, vaultError("keychain_invalid_data", "Keychain value is not valid UTF-8"))
    }
    return (value, nil)
  }

  private func store(value: String, account: String) -> FlutterError? {
    let query = keychainQuery(account: account)
    let attributes: [String: Any] = [
      kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if update == errSecSuccess { return nil }
    guard update == errSecItemNotFound else { return keychainError(update) }
    let item = query.merging(attributes) { _, newValue in newValue }
    let add = SecItemAdd(item as CFDictionary, nil)
    return add == errSecSuccess ? nil : keychainError(add)
  }

  private func remove(account: String) -> FlutterError? {
    let status = SecItemDelete(keychainQuery(account: account) as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound ? nil : keychainError(status)
  }

  private func keychainQuery(account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
  }

  private func invalidArguments() -> FlutterError { vaultError("invalid_arguments", "需要完整且非空的凭据") }
  private func keychainError(_ status: OSStatus) -> FlutterError {
    FlutterError(code: "keychain_error", message: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain operation failed", details: ["status": Int(status)])
  }
  private func rollbackError(for vault: Vault) -> FlutterError {
    vaultError("keychain_rollback_failed", "\(vault.displayName)凭据事务失败且回滚不完整，请重试")
  }
  private func vaultError(_ code: String, _ message: String) -> FlutterError { FlutterError(code: code, message: message, details: nil) }
}
