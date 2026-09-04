import Foundation
import Security
#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// 固定用途的 Strava 凭据 vault；Flutter 无法按任意 account 读取 Keychain。
final class KeychainPlugin: NSObject, FlutterPlugin {
  private static let channelName = "health_workout_export/keychain"
  private static let service = "com.checkkaka.HealthWorkoutExport"
  private static let stravaClientIDAccount = "strava.clientId"
  private static let stravaClientSecretAccount = "strava.clientSecret"
  private static let stravaAccessTokenAccount = "strava.accessToken"
  private static let stravaRefreshTokenAccount = "strava.refreshToken"
  private static let stravaJournalAccount = "strava.vaultJournal"
  private static let stravaExpiresAtKey = "strava.expiresAt"
  private static let authorizationAccounts = [
    stravaClientIDAccount,
    stravaClientSecretAccount,
    stravaRefreshTokenAccount,
    stravaAccessTokenAccount,
  ]

  struct StravaAuthorization {
    let clientId: String
    let clientSecret: String
    let accessToken: String
    let refreshToken: String
    let expiresAtSeconds: Double
  }

  struct StravaVaultState: Codable {
    let clientId: String?
    let clientSecret: String?
    let accessToken: String?
    let refreshToken: String?
    let expiresAtSeconds: Double?

    static let empty = StravaVaultState(
      clientId: nil,
      clientSecret: nil,
      accessToken: nil,
      refreshToken: nil,
      expiresAtSeconds: nil
    )

    fileprivate var accountValues: [(String, String?)] {
      [
        (KeychainPlugin.stravaClientIDAccount, clientId),
        (KeychainPlugin.stravaClientSecretAccount, clientSecret),
        (KeychainPlugin.stravaRefreshTokenAccount, refreshToken),
        (KeychainPlugin.stravaAccessTokenAccount, accessToken),
      ]
    }
  }

  private struct VaultJournal: Codable {
    let previous: StravaVaultState
  }

  enum AuthorizationError: Error {
    case invalidArguments
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    super.init()
    _ = recoverJournalIfNeeded()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    let instance = KeychainPlugin()
    channel.setMethodCallHandler(instance.handle)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard [
      "stravaStatus", "stravaLease", "writeStravaAuthorization",
      "clearStravaAuthorization",
    ].contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    DispatchQueue.main.async {
      switch call.method {
      case "stravaStatus", "stravaLease", "writeStravaAuthorization",
        "clearStravaAuthorization":
        if let recoveryError = self.recoverJournalIfNeeded() {
          result(recoveryError)
          return
        }
      default:
        break
      }

      switch call.method {
      case "stravaStatus":
        self.reportStatus(result: result)
      case "stravaLease":
        self.issueLease(arguments: call.arguments, result: result)
      case "writeStravaAuthorization":
        do {
          self.commit(
            try Self.parseStravaAuthorization(arguments: call.arguments),
            result: result
          )
        } catch {
          result(self.invalidArguments())
        }
      case "clearStravaAuthorization":
        self.apply(target: .empty, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  static func parseStravaAuthorization(arguments: Any?) throws -> StravaAuthorization {
    guard
      let arguments = arguments as? [String: Any],
      let clientId = nonEmpty(arguments["clientId"] as? String),
      let clientSecret = nonEmpty(arguments["clientSecret"] as? String),
      let accessToken = nonEmpty(arguments["accessToken"] as? String),
      let refreshToken = nonEmpty(arguments["refreshToken"] as? String),
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

  static func statusPayload(_ state: StravaVaultState) -> [String: Any] {
    [
      "clientId": nonEmpty(state.clientId) ?? "",
      "hasClientSecret": nonEmpty(state.clientSecret) != nil,
      "hasAccessToken": nonEmpty(state.accessToken) != nil,
      "hasRefreshToken": nonEmpty(state.refreshToken) != nil,
      "expiresAtSeconds": validExpiry(state.expiresAtSeconds) ?? 0,
    ]
  }

  /// refresh 与 upload 租约按最小权限返回，绝不包含 webCookie。
  static func leasePayload(purpose: String, state: StravaVaultState) -> [String: Any]? {
    guard let expiresAt = validExpiry(state.expiresAtSeconds) else { return nil }
    switch purpose {
    case "refresh":
      guard
        let clientId = nonEmpty(state.clientId),
        let clientSecret = nonEmpty(state.clientSecret),
        let refreshToken = nonEmpty(state.refreshToken)
      else { return nil }
      return [
        "clientId": clientId,
        "clientSecret": clientSecret,
        "refreshToken": refreshToken,
        "expiresAtSeconds": expiresAt,
      ]
    case "upload":
      guard let accessToken = nonEmpty(state.accessToken) else { return nil }
      return ["accessToken": accessToken, "expiresAtSeconds": expiresAt]
    default:
      return nil
    }
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return value
  }

  private static func validExpiry(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value > 0 else { return nil }
    return value
  }

  private func reportStatus(result: FlutterResult) {
    let loaded = loadState()
    if let error = loaded.error {
      result(error)
    } else {
      result(Self.statusPayload(loaded.state ?? .empty))
    }
  }

  private func issueLease(arguments: Any?, result: FlutterResult) {
    guard
      let arguments = arguments as? [String: Any],
      let purpose = arguments["purpose"] as? String,
      purpose == "refresh" || purpose == "upload"
    else {
      result(invalidArguments())
      return
    }
    let loaded = loadState()
    if let error = loaded.error {
      result(error)
    } else if let payload = Self.leasePayload(purpose: purpose, state: loaded.state ?? .empty) {
      result(payload)
    } else {
      result(
        FlutterError(
          code: "strava_not_configured",
          message: "Strava \(purpose) 凭据尚未配置",
          details: ["purpose": purpose]
        ))
    }
  }

  private func commit(_ authorization: StravaAuthorization, result: FlutterResult) {
    apply(
      target: StravaVaultState(
        clientId: authorization.clientId,
        clientSecret: authorization.clientSecret,
        accessToken: authorization.accessToken,
        refreshToken: authorization.refreshToken,
        expiresAtSeconds: authorization.expiresAtSeconds
      ),
      result: result
    )
  }

  /// journal 先保存完整旧状态；commit/clear 任一步失败都恢复旧值和 expiresAt。
  private func apply(target: StravaVaultState, result: FlutterResult) {
    let loaded = loadState()
    guard let previous = loaded.state else {
      result(loaded.error ?? vaultError("strava_vault_read_failed", "无法读取 Strava 凭据状态"))
      return
    }
    guard
      let journalData = try? JSONEncoder().encode(VaultJournal(previous: previous)),
      let journal = String(data: journalData, encoding: .utf8)
    else {
      result(vaultError("strava_vault_journal_failed", "无法准备 Strava 凭据事务"))
      return
    }
    if let journalError = store(value: journal, account: Self.stravaJournalAccount) {
      result(journalError)
      return
    }

    if let mutationError = writeState(target) {
      if restoreState(previous), remove(account: Self.stravaJournalAccount) == nil {
        result(mutationError)
      } else {
        result(rollbackError())
      }
      return
    }
    if let journalRemovalError = remove(account: Self.stravaJournalAccount) {
      // journal 留存使下一次启动能回滚到旧状态；本次不得宣告提交成功。
      result(journalRemovalError)
      return
    }
    result(nil)
  }

  private func loadState() -> (state: StravaVaultState?, error: FlutterError?) {
    var values: [String: String?] = [:]
    for account in Self.authorizationAccounts {
      let stored = storedValue(account: account)
      if let error = stored.error { return (nil, error) }
      values[account] = stored.value
    }
    let expiresObject = defaults.object(forKey: Self.stravaExpiresAtKey)
    var expiresAt = (expiresObject as? NSNumber)?.doubleValue
    if expiresObject != nil && Self.validExpiry(expiresAt) == nil {
      // 旧版本或外部写入的非法值不应锁死唯一的清除/重新授权入口。
      defaults.removeObject(forKey: Self.stravaExpiresAtKey)
      expiresAt = nil
    }
    return (
      StravaVaultState(
        clientId: values[Self.stravaClientIDAccount] ?? nil,
        clientSecret: values[Self.stravaClientSecretAccount] ?? nil,
        accessToken: values[Self.stravaAccessTokenAccount] ?? nil,
        refreshToken: values[Self.stravaRefreshTokenAccount] ?? nil,
        expiresAtSeconds: expiresAt
      ),
      nil
    )
  }

  private func writeState(_ state: StravaVaultState) -> FlutterError? {
    for (account, value) in state.accountValues {
      let error = value.map { store(value: $0, account: account) } ?? remove(account: account)
      if let error { return error }
    }
    if let expiresAt = state.expiresAtSeconds {
      defaults.set(expiresAt, forKey: Self.stravaExpiresAtKey)
    } else {
      defaults.removeObject(forKey: Self.stravaExpiresAtKey)
    }
    return nil
  }

  private func restoreState(_ state: StravaVaultState) -> Bool {
    var restored = true
    for (account, value) in state.accountValues {
      let error = value.map { store(value: $0, account: account) } ?? remove(account: account)
      if error != nil { restored = false }
    }
    if let expiresAt = state.expiresAtSeconds {
      defaults.set(expiresAt, forKey: Self.stravaExpiresAtKey)
    } else {
      defaults.removeObject(forKey: Self.stravaExpiresAtKey)
    }
    return restored
  }

  private func recoverJournalIfNeeded() -> FlutterError? {
    let stored = storedValue(account: Self.stravaJournalAccount)
    if let error = stored.error { return error }
    guard let rawJournal = stored.value else { return nil }
    guard
      let data = rawJournal.data(using: .utf8),
      let journal = try? JSONDecoder().decode(VaultJournal.self, from: data)
    else {
      return purgeUnrecoverableVault()
    }
    guard
      restoreState(journal.previous),
      remove(account: Self.stravaJournalAccount) == nil
    else {
      return vaultError(
        "strava_vault_recovery_failed",
        "Strava 凭据事务恢复失败，请重试"
      )
    }
    return nil
  }

  /// 损坏 journal 无法证明新旧哪组凭据完整，只能 fail-closed 并要求重新授权。
  private func purgeUnrecoverableVault() -> FlutterError? {
    var failed = false
    for account in Self.authorizationAccounts {
      if remove(account: account) != nil { failed = true }
    }
    defaults.removeObject(forKey: Self.stravaExpiresAtKey)
    if !failed, remove(account: Self.stravaJournalAccount) == nil { return nil }
    // 保留损坏 journal 作为 fail-closed 哨兵，下次调用继续清除而不是暴露半组凭据。
    return vaultError("strava_vault_recovery_failed", "Strava 凭据事务恢复失败，请重试")
  }

  /// 保留纯事务 helper 供回归测试覆盖中途失败与 expiresAt 回滚。
  static func performStravaAuthorizationTransaction(
    _ authorization: StravaAuthorization,
    read: (String) -> (value: String?, error: FlutterError?),
    write: (String, String) -> FlutterError?,
    restore: (String?, String) -> Bool,
    readExpiresAt: () -> Double?,
    writeExpiresAt: (Double?) -> Bool
  ) -> (error: FlutterError?, rollbackFailed: Bool) {
    performTransaction(
      values: [
        (Self.stravaClientIDAccount, authorization.clientId),
        (Self.stravaClientSecretAccount, authorization.clientSecret),
        (Self.stravaRefreshTokenAccount, authorization.refreshToken),
        (Self.stravaAccessTokenAccount, authorization.accessToken),
      ],
      expiresAt: authorization.expiresAtSeconds,
      read: read,
      mutate: { account, value in write(account, value!) },
      restore: restore,
      readExpiresAt: readExpiresAt,
      writeExpiresAt: writeExpiresAt
    )
  }

  static func performStravaClearTransaction(
    read: (String) -> (value: String?, error: FlutterError?),
    remove: (String) -> FlutterError?,
    restore: (String?, String) -> Bool,
    readExpiresAt: () -> Double?,
    writeExpiresAt: (Double?) -> Bool
  ) -> (error: FlutterError?, rollbackFailed: Bool) {
    performTransaction(
      values: Self.authorizationAccounts.map { ($0, nil) },
      expiresAt: nil,
      read: read,
      mutate: { account, _ in remove(account) },
      restore: restore,
      readExpiresAt: readExpiresAt,
      writeExpiresAt: writeExpiresAt
    )
  }

  private static func performTransaction(
    values: [(String, String?)],
    expiresAt: Double?,
    read: (String) -> (value: String?, error: FlutterError?),
    mutate: (String, String?) -> FlutterError?,
    restore: (String?, String) -> Bool,
    readExpiresAt: () -> Double?,
    writeExpiresAt: (Double?) -> Bool
  ) -> (error: FlutterError?, rollbackFailed: Bool) {
    var previous: [String: String?] = [:]
    for (account, _) in values {
      let stored = read(account)
      if let error = stored.error { return (error, false) }
      previous[account] = stored.value
    }
    let previousExpiresAt = readExpiresAt()
    var written: [String] = []

    func rollback() -> Bool {
      var restored = true
      for account in written.reversed() where !restore(previous[account] ?? nil, account) {
        restored = false
      }
      if !writeExpiresAt(previousExpiresAt) { restored = false }
      return restored
    }

    for (account, value) in values {
      if let error = mutate(account, value) {
        return (error, !rollback())
      }
      written.append(account)
    }
    guard writeExpiresAt(expiresAt) else {
      return (
        FlutterError(
          code: "strava_expiry_write_failed",
          message: "Strava token 过期时间写入失败",
          details: nil
        ),
        !rollback()
      )
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

  private func keychainQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: account,
    ]
  }

  private func invalidArguments() -> FlutterError {
    vaultError("invalid_arguments", "Non-empty required values are expected")
  }

  private func keychainError(_ status: OSStatus) -> FlutterError {
    FlutterError(
      code: "keychain_error",
      message: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain operation failed",
      details: ["status": Int(status)]
    )
  }

  private func rollbackError() -> FlutterError {
    vaultError(
      "keychain_rollback_failed",
      "Keychain authorization transaction failed and rollback was incomplete"
    )
  }

  private func vaultError(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }
}
