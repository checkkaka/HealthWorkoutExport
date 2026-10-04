import Flutter
import HealthKit
import UIKit
import XCTest

@testable import Runner

class RunnerTests: XCTestCase {

  func testSyncFilesUseLegacyPathsAndStrictFingerprints() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SyncFilesTests.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = SyncFilesPlugin.Storage(rootURL: root)
    let fingerprint = String(repeating: "a", count: 64)

    XCTAssertEqual(try storage.url(for: .state), root.appendingPathComponent("sync_state.json"))
    XCTAssertEqual(
      try storage.url(for: .syncedFIT(fingerprint)),
      root.appendingPathComponent("synced_fits/\(fingerprint).fit")
    )
    XCTAssertEqual(
      try storage.url(for: .recovery(fingerprint)),
      root.appendingPathComponent("pending_resync/\(fingerprint).json")
    )
    XCTAssertTrue(SyncFilesPlugin.isValidFingerprint(fingerprint))
    XCTAssertFalse(SyncFilesPlugin.isValidFingerprint(String(repeating: "A", count: 64)))
    XCTAssertFalse(SyncFilesPlugin.isValidFingerprint("abc"))
  }

  func testSyncFilesRoundTripProtectionBackupAndIdempotentDelete() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SyncFilesTests.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = SyncFilesPlugin.Storage(rootURL: root)
    let fingerprint = String(repeating: "b", count: 64)
    // 旧磁盘格式是顶层 fingerprint -> record map；适配器必须原样兼容。
    let state = Data("{}".utf8)
    let fit = Data([0x0E, 0x10, 0x20, 0x30])

    try storage.write(state, kind: .state)
    try storage.write(fit, kind: .syncedFIT(fingerprint))
    XCTAssertEqual(try storage.read(.state), state)
    XCTAssertEqual(try storage.read(.syncedFIT(fingerprint)), fit)

    let stateURL = try storage.url(for: .state)
    let fitURL = try storage.url(for: .syncedFIT(fingerprint))
    #if !targetEnvironment(simulator)
      XCTAssertEqual(
        try FileManager.default.attributesOfItem(atPath: stateURL.path)[.protectionKey]
          as? FileProtectionType,
        .complete
      )
      XCTAssertEqual(
        try FileManager.default.attributesOfItem(atPath: fitURL.path)[.protectionKey]
          as? FileProtectionType,
        .complete
      )
    #endif
    XCTAssertEqual(try stateURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    XCTAssertEqual(try fitURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

    try storage.delete(.syncedFIT(fingerprint))
    try storage.delete(.syncedFIT(fingerprint))
    XCTAssertThrowsError(try storage.read(.syncedFIT(fingerprint))) {
      XCTAssertEqual($0 as? SyncFilesPlugin.StorageError, .missing)
    }
  }

  func testSyncFilesQuarantineCorruptJSONWithoutUsingTemporaryFallback() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SyncFilesTests.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = SyncFilesPlugin.Storage(rootURL: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: storage.url(for: .state))

    XCTAssertThrowsError(try storage.read(.state)) {
      XCTAssertEqual($0 as? SyncFilesPlugin.StorageError, .corrupt)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: try storage.url(for: .state).path))
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertEqual(quarantined.count, 1)
    XCTAssertTrue(quarantined[0].contains(".corrupt-"))

    try Data("[]".utf8).write(to: storage.url(for: .state))
    XCTAssertThrowsError(try storage.read(.state)) {
      XCTAssertEqual($0 as? SyncFilesPlugin.StorageError, .corrupt)
    }
  }

  func testSyncFilesRejectOversizedInputBeforeWriting() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SyncFilesTests.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = SyncFilesPlugin.Storage(rootURL: root)
    let fingerprint = String(repeating: "c", count: 64)

    XCTAssertThrowsError(
      try storage.write(Data(count: 64 * 1_024 * 1_024 + 1), kind: .syncedFIT(fingerprint))
    ) {
      XCTAssertEqual($0 as? SyncFilesPlugin.StorageError, .tooLarge)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: try storage.url(for: .syncedFIT(fingerprint)).path)
    )
  }

  func testSyncFilesMethodChannelReturnsStableMissingAndInvalidCodes() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SyncFilesTests.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = SyncFilesPlugin(storage: .init(rootURL: root))

    var response: Any?
    plugin.handle(FlutterMethodCall(methodName: "readState", arguments: nil)) { response = $0 }
    XCTAssertEqual((response as? FlutterError)?.code, "sync_file_missing")

    plugin.handle(
      FlutterMethodCall(methodName: "readSyncedFit", arguments: ["fingerprint": "../escape"])
    ) { response = $0 }
    XCTAssertEqual((response as? FlutterError)?.code, "invalid_arguments")

    plugin.handle(
      FlutterMethodCall(
        methodName: "writeState",
        arguments: ["bytes": FlutterStandardTypedData(bytes: Data("[]".utf8))]
      )
    ) { response = $0 }
    XCTAssertEqual((response as? FlutterError)?.code, "invalid_json")
    XCTAssertEqual((response as? FlutterError)?.message, "写入的同步文件不是 JSON 对象")
  }

  func testHealthKitIntervalRequiresAscendingFiniteMilliseconds() throws {
    let interval = try HealthKitPlugin.parseInterval(arguments: ["startMs": 1_000, "endMs": 2_000])
    XCTAssertEqual(interval.start.timeIntervalSince1970, 1)
    XCTAssertEqual(interval.end.timeIntervalSince1970, 2)

    XCTAssertThrowsError(
      try HealthKitPlugin.parseInterval(arguments: ["startMs": 2_000, "endMs": 2_000])
    )
  }

  func testKeychainDisablesGenericAccountMethods() {
    for method in ["read", "write", "delete"] {
      var response: Any?
      KeychainPlugin().handle(
        FlutterMethodCall(methodName: method, arguments: ["account": "strava.webCookie"])
      ) { response = $0 }

      XCTAssertTrue((response as? NSObject) === FlutterMethodNotImplemented)
    }
  }

  func testThirdPartyVaultExposesOnlyFixedSourceMethodsAndRedactsStatus() {
    for method in ["read", "write", "delete", "lease"] {
      var response: Any?
      ThirdPartyVaultPlugin().handle(
        FlutterMethodCall(methodName: method, arguments: ["account": "strava.webCookie"])
      ) { response = $0 }
      XCTAssertTrue((response as? NSObject) === FlutterMethodNotImplemented)
    }

    let xingzhe = ThirdPartyVaultPlugin.statusPayload(
      for: .xingzhe,
      values: [
        "xingzhe.account": "account",
        "xingzhe.password": "password-secret",
        "xingzhe.session": "session-secret",
      ]
    )
    XCTAssertEqual(xingzhe["hasAccount"] as? Bool, true)
    XCTAssertEqual(xingzhe["hasPassword"] as? Bool, true)
    XCTAssertEqual(xingzhe["hasSessionId"] as? Bool, true)
    XCTAssertNil(xingzhe["password"])
    XCTAssertNil(xingzhe["sessionId"])

    let onelap = ThirdPartyVaultPlugin.leasePayload(
      for: .onelap,
      values: [
        "onelap.account": "account",
        "onelap.password": "password-secret",
        "onelap.token": "token-secret",
        "onelap.uid": "uid",
      ]
    )
    XCTAssertEqual(onelap?["uid"] as? String, "uid")
    XCTAssertNil(onelap?["sessionId"])

    // 旧应用允许只保留账号密码并在冷启动重新登录；适配器不能把该恢复路径锁死。
    let legacyXingzhe = ThirdPartyVaultPlugin.leasePayload(
      for: .xingzhe,
      values: ["xingzhe.account": "account", "xingzhe.password": "password-secret"]
    )
    XCTAssertEqual(legacyXingzhe?["account"] as? String, "account")
    XCTAssertNil(legacyXingzhe?["sessionId"])
  }

  func testKeepVaultStoresOnlyAccountAndToken() throws {
    XCTAssertEqual(ThirdPartyVaultPlugin.Vault.keep.accounts, ["keep.account", "keep.token"])
    let authorization = try ThirdPartyVaultPlugin.parseKeepAuthorization(arguments: [
      "account": "synthetic-account", "token": "synthetic-token",
    ])
    XCTAssertEqual(authorization.token, "synthetic-token")
    for invalid in [
      ["account": "synthetic-account", "token": " "],
      ["account": "synthetic-account", "token": "synthetic-token", "password": "never-store"],
    ] as [[String: Any]] {
      XCTAssertThrowsError(try ThirdPartyVaultPlugin.parseKeepAuthorization(arguments: invalid))
    }
    let values: [String: String?] = ["keep.account": "synthetic-account", "keep.token": "synthetic-token"]
    let status = ThirdPartyVaultPlugin.statusPayload(for: .keep, values: values)
    XCTAssertEqual(Set(status.keys), Set(["hasAccount", "hasToken"]))
    XCTAssertEqual(status["hasToken"] as? Bool, true)
    let lease = ThirdPartyVaultPlugin.leasePayload(for: .keep, values: values)
    XCTAssertEqual(Set(lease?.keys.map { $0 } ?? []), Set(["account", "token"]))
    XCTAssertEqual(lease?["token"] as? String, "synthetic-token")
    XCTAssertNil(ThirdPartyVaultPlugin.leasePayload(for: .keep, values: ["keep.account": "account"]))
  }

  func testKeepResetDeletesCorruptValuesAndJournalsWithoutReading() {
    for journal in [Data([0xff, 0xfe]), Data("not-a-journal".utf8)] {
      var stored = [
        "keep.account": Data([0xff]), "keep.token": Data([0xfe]),
        "keep.vaultJournal": journal,
        "onelap.token": Data("other-provider".utf8),
        "synced.history": Data("workout-history".utf8),
      ]
      let expected = ["onelap.token": stored["onelap.token"]!, "synced.history": stored["synced.history"]!]
      var deleted: [String] = []
      let remove: (String) -> FlutterError? = { account in
        deleted.append(account)
        stored.removeValue(forKey: account)
        return nil
      }
      XCTAssertNil(ThirdPartyVaultPlugin.resetKeepAuthorization(remove: remove))
      XCTAssertEqual(deleted, ["keep.vaultJournal", "keep.account", "keep.token"])
      XCTAssertEqual(stored, expected)
      XCTAssertNil(ThirdPartyVaultPlugin.resetKeepAuthorization(remove: remove))
      XCTAssertEqual(stored, expected)
    }
  }

  func testKeepResetJournalDeletionFailureDoesNotTouchCredentials() {
    var stored = ["keep.account": "account", "keep.token": "token", "keep.vaultJournal": "journal"]
    let original = stored
    var deleted: [String] = []
    let error = ThirdPartyVaultPlugin.resetKeepAuthorization { account in
      deleted.append(account)
      if account == "keep.vaultJournal" { return FlutterError(code: "locked", message: nil, details: nil) }
      stored.removeValue(forKey: account)
      return nil
    }
    XCTAssertEqual(error?.code, "locked")
    XCTAssertEqual(deleted, ["keep.vaultJournal"])
    XCTAssertEqual(stored, original)
  }

  func testKeepResetDeletionFailureIsReportedAndCanBeRetried() {
    var stored = ["keep.account": "account", "keep.token": "token", "keep.vaultJournal": "journal", "onelap.token": "other"]
    var failToken = true
    let remove: (String) -> FlutterError? = { account in
      if account == "keep.token" && failToken { return FlutterError(code: "locked", message: nil, details: nil) }
      stored.removeValue(forKey: account)
      return nil
    }
    XCTAssertEqual(ThirdPartyVaultPlugin.resetKeepAuthorization(remove: remove)?.code, "locked")
    XCTAssertEqual(stored, ["keep.token": "token", "onelap.token": "other"])
    failToken = false
    XCTAssertNil(ThirdPartyVaultPlugin.resetKeepAuthorization(remove: remove))
    XCTAssertEqual(stored, ["onelap.token": "other"])
  }

  func testKeepVaultTokenFailureRollsBackAccount() {
    var stored = ["keep.account": "previous-account", "keep.token": "previous-token"]
    let original = stored
    let result = ThirdPartyVaultPlugin.performFixedTransaction(
      entries: [
        ThirdPartyVaultPlugin.StateEntry(account: "keep.account", value: "next-account"),
        ThirdPartyVaultPlugin.StateEntry(account: "keep.token", value: "next-token"),
      ],
      read: { (stored[$0], nil) },
      mutate: { account, value in
        if account == "keep.token" { return FlutterError(code: "forced_failure", message: nil, details: nil) }
        stored[account] = value
        return nil
      },
      restore: { value, account in stored[account] = value; return true }
    )
    XCTAssertNotNil(result.error)
    XCTAssertFalse(result.rollbackFailed)
    XCTAssertEqual(stored, original)
  }

  func testThirdPartyVaultParsesCompleteFixedCredentials() throws {
    let xingzhe = try ThirdPartyVaultPlugin.parseXingzheAuthorization(arguments: [
      "account": "account", "password": "password", "sessionId": "session",
    ])
    XCTAssertEqual(xingzhe.sessionId, "session")
    XCTAssertThrowsError(
      try ThirdPartyVaultPlugin.parseXingzheAuthorization(arguments: [
        "account": "account", "password": "", "sessionId": "session",
      ])
    )

    let onelap = try ThirdPartyVaultPlugin.parseOnelapAuthorization(arguments: [
      "account": "account", "password": "password", "token": "token", "uid": "uid",
    ])
    XCTAssertEqual(onelap.token, "token")
    XCTAssertThrowsError(
      try ThirdPartyVaultPlugin.parseOnelapAuthorization(arguments: [
        "account": "account", "password": "password", "token": "token", "uid": "",
      ])
    )
  }

  func testThirdPartyVaultClearRollsBackEveryChangedValueAfterPartialFailure() {
    let entries = [
      ThirdPartyVaultPlugin.StateEntry(account: "xingzhe.account", value: nil),
      ThirdPartyVaultPlugin.StateEntry(account: "xingzhe.password", value: nil),
      ThirdPartyVaultPlugin.StateEntry(account: "xingzhe.session", value: nil),
    ]
    let original = [
      "xingzhe.account": "account",
      "xingzhe.password": "password-secret",
      "xingzhe.session": "session-secret",
    ]
    var stored = original
    var mutateCount = 0
    let result = ThirdPartyVaultPlugin.performFixedTransaction(
      entries: entries,
      read: { (stored[$0], nil) },
      mutate: { account, _ in
        mutateCount += 1
        if mutateCount == 3 {
          return FlutterError(code: "forced_failure", message: nil, details: nil)
        }
        stored.removeValue(forKey: account)
        return nil
      },
      restore: { value, account in
        stored[account] = value
        return true
      }
    )
    XCTAssertEqual(result.error?.code, "forced_failure")
    XCTAssertFalse(result.rollbackFailed)
    XCTAssertEqual(stored, original)
  }

  func testStravaVaultStatusAndPurposeLeasesExposeLeastPrivilegeShapes() {
    let state = KeychainPlugin.StravaVaultState(
      clientId: "123",
      clientSecret: "client-secret",
      accessToken: "access-token",
      refreshToken: "refresh-token",
      expiresAtSeconds: 42
    )

    let status = KeychainPlugin.statusPayload(state)
    XCTAssertEqual(status["clientId"] as? String, "123")
    XCTAssertEqual(status["hasClientSecret"] as? Bool, true)
    XCTAssertEqual(status["hasAccessToken"] as? Bool, true)
    XCTAssertEqual(status["hasRefreshToken"] as? Bool, true)
    XCTAssertNil(status["clientSecret"])
    XCTAssertNil(status["accessToken"])
    XCTAssertNil(status["refreshToken"])

    let refresh = KeychainPlugin.leasePayload(purpose: "refresh", state: state)
    XCTAssertEqual(refresh?["clientSecret"] as? String, "client-secret")
    XCTAssertEqual(refresh?["refreshToken"] as? String, "refresh-token")
    XCTAssertNil(refresh?["accessToken"])
    let upload = KeychainPlugin.leasePayload(purpose: "upload", state: state)
    XCTAssertEqual(upload?["accessToken"] as? String, "access-token")
    XCTAssertNil(upload?["clientSecret"])
    XCTAssertNil(upload?["refreshToken"])
    XCTAssertNil(KeychainPlugin.leasePayload(purpose: "other", state: state))
  }

  func testKeychainParsesCompleteStravaAuthorization() throws {
    let authorization = try KeychainPlugin.parseStravaAuthorization(arguments: [
      "clientId": "123",
      "clientSecret": "secret",
      "accessToken": "access",
      "refreshToken": "refresh",
      "expiresAtSeconds": 42.0,
    ])
    XCTAssertEqual(authorization.clientId, "123")
    XCTAssertEqual(authorization.clientSecret, "secret")
    XCTAssertEqual(authorization.accessToken, "access")
    XCTAssertEqual(authorization.refreshToken, "refresh")
    XCTAssertEqual(authorization.expiresAtSeconds, 42)

    XCTAssertThrowsError(
      try KeychainPlugin.parseStravaAuthorization(arguments: [
        "clientId": "123",
        "clientSecret": "secret",
        "accessToken": "",
        "refreshToken": "refresh",
        "expiresAtSeconds": 42.0,
      ])
    )
  }

  func testKeychainAuthorizationRestoresEveryPriorValueAfterIntermediateFailure() throws {
    let authorization = try KeychainPlugin.parseStravaAuthorization(arguments: [
      "clientId": "new-id",
      "clientSecret": "new-secret",
      "accessToken": "new-access",
      "refreshToken": "new-refresh",
      "expiresAtSeconds": 42.0,
    ])
    let original = [
      "strava.clientId": "old-id",
      "strava.clientSecret": "old-secret",
      "strava.accessToken": "old-access",
      "strava.refreshToken": "old-refresh",
    ]

    for failureAt in 2...4 {
      var stored = original
      var writeCount = 0
      let outcome = KeychainPlugin.performStravaAuthorizationTransaction(
        authorization,
        read: { (stored[$0], nil) },
        write: { account, value in
          writeCount += 1
          if writeCount == failureAt {
            return FlutterError(code: "forced_failure", message: nil, details: nil)
          }
          stored[account] = value
          return nil
        },
        restore: { value, account in
          stored[account] = value
          return true
        },
        readExpiresAt: { 10 },
        writeExpiresAt: { _ in true }
      )

      XCTAssertEqual(outcome.error?.code, "forced_failure")
      XCTAssertFalse(outcome.rollbackFailed)
      XCTAssertEqual(stored, original)
    }
  }

  func testStravaVaultClearIsIdempotentAndRollsBackSecretsAndExpiry() {
    let original = [
      "strava.clientId": "old-id",
      "strava.clientSecret": "old-secret",
      "strava.accessToken": "old-access",
      "strava.refreshToken": "old-refresh",
    ]
    var stored = original
    var expiresAt: Double? = 42
    var removeCount = 0
    let forced = FlutterError(code: "forced_failure", message: nil, details: nil)

    let failed = KeychainPlugin.performStravaClearTransaction(
      read: { (stored[$0], nil) },
      remove: { account in
        removeCount += 1
        if removeCount == 3 { return forced }
        stored.removeValue(forKey: account)
        return nil
      },
      restore: { value, account in
        stored[account] = value
        return true
      },
      readExpiresAt: { expiresAt },
      writeExpiresAt: {
        expiresAt = $0
        return true
      }
    )
    XCTAssertEqual(failed.error?.code, "forced_failure")
    XCTAssertFalse(failed.rollbackFailed)
    XCTAssertEqual(stored, original)
    XCTAssertEqual(expiresAt, 42)

    stored.removeAll()
    expiresAt = nil
    let idempotent = KeychainPlugin.performStravaClearTransaction(
      read: { (stored[$0], nil) },
      remove: { account in
        stored.removeValue(forKey: account)
        return nil
      },
      restore: { _, _ in true },
      readExpiresAt: { expiresAt },
      writeExpiresAt: {
        expiresAt = $0
        return true
      }
    )
    XCTAssertNil(idempotent.error)
    XCTAssertFalse(idempotent.rollbackFailed)
    XCTAssertNil(expiresAt)
  }

  func testPreferencesRoundTripsLegacyStravaKeysAndRejectsInvalidArguments() {
    let suiteName = "RunnerTests.Preferences.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let plugin = PreferencesPlugin(defaults: defaults)

    var response: Any?
    plugin.handle(
      FlutterMethodCall(
        methodName: "write",
        arguments: ["key": "strava.uploadMode", "value": "web"]
      )
    ) { response = $0 }
    XCTAssertNil(response)

    plugin.handle(
      FlutterMethodCall(methodName: "read", arguments: ["key": "strava.uploadMode"])
    ) { response = $0 }
    XCTAssertEqual(response as? String, "web")

    plugin.handle(
      FlutterMethodCall(methodName: "read", arguments: ["key": ""])
    ) { response = $0 }
    XCTAssertEqual((response as? FlutterError)?.code, "invalid_arguments")

    plugin.handle(
      FlutterMethodCall(methodName: "read", arguments: ["key": "arbitrary.key"])
    ) { response = $0 }
    XCTAssertEqual((response as? FlutterError)?.code, "invalid_arguments")

    plugin.handle(
      FlutterMethodCall(methodName: "read", arguments: ["key": "strava.expiresAt"])
    ) { response = $0 }
    XCTAssertEqual((response as? FlutterError)?.code, "invalid_arguments")
  }

  func testHealthKitSummaryHelpersMatchSwiftBaseline() {
    XCTAssertEqual(HKWorkoutActivityType.cycling.localizedChineseName, "骑车")
    XCTAssertEqual(
      HealthKitPlugin.millisecondsSinceEpoch(Date(timeIntervalSince1970: 1)),
      1_000
    )
  }

  func testHealthKitBundleArgumentsRequireUniqueUUIDsAndPreserveOrder() throws {
    let first = UUID(uuidString: "A4B64E8C-0012-4A0B-993E-140FC6B721C0")!
    let second = UUID(uuidString: "C369A834-FF0B-4D46-BB79-39246FA8A589")!

    XCTAssertEqual(
      try HealthKitPlugin.parseWorkoutUUIDs(arguments: [
        "uuids": [first.uuidString, second.uuidString]
      ]),
      [first, second]
    )
    XCTAssertThrowsError(try HealthKitPlugin.parseWorkoutUUIDs(arguments: ["uuids": []]))
    XCTAssertThrowsError(
      try HealthKitPlugin.parseWorkoutUUIDs(arguments: [
        "uuids": [first.uuidString, first.uuidString]
      ])
    )
    XCTAssertThrowsError(
      try HealthKitPlugin.parseWorkoutUUIDs(arguments: ["uuids": ["not-a-uuid"]])
    )
  }

  func testHealthKitBundlePayloadMatchesCompleteNativeContract() {
    let date = Date(timeIntervalSince1970: 1.25)
    let sample = HealthKitPlugin.quantityPayload(date: date, value: 143, unit: "count/min")
    let event = HealthKitPlugin.eventPayload(type: .pause, date: date)
    let route = HealthKitPlugin.routePayload(
      latitude: 31.34,
      longitude: 120.55,
      altitude: 8.5,
      timestamp: date,
      speed: 4.2
    )
    let payload = HealthKitPlugin.bundlePayload(
      summary: ["uuid": "workout-id"],
      metadata: ["HKIndoorWorkout": "true"],
      events: [event],
      series: [HKQuantityTypeIdentifier.heartRate.rawValue: [sample]],
      route: [route]
    )

    XCTAssertEqual(payload["uuid"] as? String, "workout-id")
    XCTAssertEqual((payload["metadata"] as? [String: String])?["HKIndoorWorkout"], "true")
    XCTAssertEqual(((payload["events"] as? [[String: Any]])?.first)?["type"] as? String, "pause")
    XCTAssertEqual(((payload["events"] as? [[String: Any]])?.first)?["dateMs"] as? Int64, 1_250)
    let series = payload["series"] as? [String: [[String: Any]]]
    let heartRate = series?[HKQuantityTypeIdentifier.heartRate.rawValue]
    XCTAssertEqual(
      heartRate?.first?["unit"] as? String,
      "count/min"
    )
    XCTAssertEqual(
      ((payload["route"] as? [[String: Any]])?.first)?["altitudeMeters"] as? Double, 8.5)
    XCTAssertEqual(
      ((payload["route"] as? [[String: Any]])?.first)?["speedMetersPerSecond"] as? Double,
      4.2
    )
    let sparseRoute = HealthKitPlugin.routePayload(
      latitude: 31.34,
      longitude: 120.55,
      altitude: nil,
      timestamp: nil,
      speed: nil
    )
    XCTAssertNil(sparseRoute["altitudeMeters"])
    XCTAssertNil(sparseRoute["timestampMs"])
    XCTAssertNil(sparseRoute["speedMetersPerSecond"])
    XCTAssertEqual(
      HealthKitPlugin.metadataPayload(from: ["HKIndoorWorkout": true, "LapCount": 2]),
      ["HKIndoorWorkout": "true", "LapCount": "2"]
    )
  }

  func testHealthKitQuantityUnitsMatchSwiftBaseline() {
    XCTAssertEqual(HealthKitPlugin.preferredUnit(for: .heartRate).unitString, "count/min")
    XCTAssertEqual(HealthKitPlugin.preferredUnit(for: .activeEnergyBurned).unitString, "kcal")
    XCTAssertEqual(HealthKitPlugin.preferredUnit(for: .distanceCycling).unitString, "m")
    XCTAssertEqual(HealthKitPlugin.preferredUnit(for: .cyclingSpeed).unitString, "m/s")
    XCTAssertEqual(HealthKitPlugin.preferredUnit(for: .runningPower).unitString, "W")
    XCTAssertEqual(HealthKitPlugin.preferredUnit(for: .runningGroundContactTime).unitString, "ms")
    XCTAssertEqual(HealthKitPlugin.preferredUnit(for: .stepCount).unitString, "count")
  }

  func testHealthKitBundleFetchUsesBoundedOrderedFailFastMapping() async throws {
    XCTAssertEqual(HealthKitPlugin.detailConcurrencyLimit, 3)
    let probe = ConcurrencyProbe()
    let values = try await HealthKitPlugin.boundedConcurrentMap(Array(0..<8), limit: 3) { value in
      await probe.enter()
      try await Task<Never, Never>.sleep(for: .milliseconds(8 - value))
      await probe.leave()
      return value * 2
    }

    XCTAssertEqual(values, Array(0..<8).map { $0 * 2 })
    let maximum = await probe.maximum()
    XCTAssertEqual(maximum, 3)

    do {
      let _: [Int] = try await HealthKitPlugin.boundedConcurrentMap(Array(0..<8), limit: 3) {
        if $0 == 2 { throw NSError(domain: "RunnerTests", code: 2) }
        return $0
      }
      XCTFail("任一明细失败时批量读取必须整体失败")
    } catch {
      XCTAssertEqual((error as NSError).code, 2)
    }
  }

  func testStravaOAuthAddsStateAndRejectsWrongCallback() throws {
    let state = "expected-state"
    let url = try StravaOAuthSecurity.authorizationURL(
      from: "https://www.strava.com/oauth/mobile/authorize?client_id=123",
      state: state
    )
    XCTAssertEqual(
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first(where: { $0.name == "state" })?.value,
      state
    )
    XCTAssertTrue(
      StravaOAuthSecurity.isValidCallback(
        URL(string: "healthworkoutexport://localhost/callback?code=abc&state=expected-state")!,
        callbackScheme: "healthworkoutexport",
        expectedState: state
      )
    )
    XCTAssertFalse(
      StravaOAuthSecurity.isValidCallback(
        URL(string: "healthworkoutexport://evil/callback?code=abc&state=expected-state")!,
        callbackScheme: "healthworkoutexport",
        expectedState: state
      )
    )
    XCTAssertThrowsError(
      try StravaOAuthSecurity.authorizationURL(
        from: "https://www.strava.com/oauth/mobile/authorize?state=attacker",
        state: state
      )
    )
  }

  func testStravaWebCookiesOnlyIncludeExactStravaDomains() throws {
    func cookie(
      _ name: String,
      _ value: String,
      _ domain: String,
      path: String = "/"
    ) throws -> HTTPCookie {
      try XCTUnwrap(
        HTTPCookie(properties: [
          .name: name,
          .value: value,
          .domain: domain,
          .path: path,
          .secure: "TRUE",
        ]))
    }

    let cookies = try [
      cookie("session", "root", ".strava.com"),
      cookie("session", "athlete", ".strava.com", path: "/athlete"),
      cookie("session", "upload", ".strava.com", path: "/upload"),
      cookie("athlete", "two", "www.strava.com"),
      cookie("api", "three", "api.strava.com"),
      cookie("attacker", "three", "evilstrava.com"),
      cookie("suffix", "four", "strava.com.example.org"),
    ]

    XCTAssertTrue(StravaWebPlugin.isStravaDomain(".strava.com"))
    XCTAssertTrue(StravaWebPlugin.isStravaDomain("WWW.STRAVA.COM"))
    XCTAssertFalse(StravaWebPlugin.isStravaDomain("evilstrava.com"))
    XCTAssertEqual(
      StravaWebPlugin.cookieHeader(
        from: cookies,
        requestHost: "www.strava.com",
        requestPath: "/athlete/training_activities"
      ),
      "session=athlete; athlete=two"
    )
    XCTAssertEqual(StravaWebPlugin.cookieHeader(from: cookies), "session=athlete; athlete=two")
    XCTAssertTrue(StravaWebPlugin.isValidCookieName("session_id"))
    XCTAssertFalse(StravaWebPlugin.isValidCookieName("bad name"))
    XCTAssertFalse(StravaWebPlugin.isValidCookieName("bad:name"))
    XCTAssertTrue(StravaWebPlugin.isValidCookieValue("abc=123"))
    XCTAssertFalse(StravaWebPlugin.isValidCookieValue("abc;admin=true"))
    XCTAssertFalse(StravaWebPlugin.isValidCookieValue("abc\r\nX-Evil: yes"))
    XCTAssertFalse(StravaWebPlugin.isValidCookieValue("quoted\""))
    XCTAssertFalse(StravaWebPlugin.isValidCookieValue("comma,value"))
    XCTAssertFalse(StravaWebPlugin.isValidCookieValue(#"back\slash"#))
    XCTAssertFalse(StravaWebPlugin.isValidCookieValue("white space"))
    XCTAssertFalse(StravaWebPlugin.isValidCookieValue("非ASCII"))
    let oversizedCookies = try (0..<5).map {
      try cookie("oversized\($0)", String(repeating: "x", count: 4_000), ".strava.com")
    }
    XCTAssertNil(
      StravaWebPlugin.cookieHeader(
        from: oversizedCookies,
        requestHost: "www.strava.com",
        requestPath: "/athlete/training_activities"
      ))

    XCTAssertTrue(
      StravaWebPlugin.isAuthenticatedProbe(
        statusCode: 200,
        finalURL: URL(string: "https://www.strava.com/athlete/training_activities")!,
        body: Data(#"{"models":[]}"#.utf8)
      ))
    XCTAssertFalse(
      StravaWebPlugin.isAuthenticatedProbe(
        statusCode: 200,
        finalURL: URL(string: "https://www.strava.com/athlete/training_activities")!,
        body: Data("<html>login</html>".utf8)
      ))
    XCTAssertFalse(
      StravaWebPlugin.isAuthenticatedProbe(
        statusCode: 200,
        finalURL: URL(string: "https://evilstrava.com/athlete/training_activities")!,
        body: Data(#"{"models":[]}"#.utf8)
      ))
    XCTAssertFalse(
      StravaWebPlugin.isAuthenticatedProbe(
        statusCode: 403,
        finalURL: URL(string: "https://www.strava.com/athlete/training_activities")!,
        body: Data(#"{"models":[]}"#.utf8)
      ))

    XCTAssertTrue(
      StravaWebPlugin.isAllowedLoginNavigation(
        URL(string: "https://www.strava.com/login")!
      ))
    XCTAssertTrue(
      StravaWebPlugin.isAllowedLoginNavigation(
        URL(string: "https://accounts.google.com/signin")!
      ))
    XCTAssertFalse(
      StravaWebPlugin.isAllowedLoginNavigation(
        URL(string: "http://www.strava.com/login")!
      ))
    XCTAssertFalse(
      StravaWebPlugin.isAllowedLoginNavigation(
        URL(string: "javascript:alert(1)")!
      ))
    XCTAssertFalse(
      StravaWebPlugin.isAllowedLoginNavigation(
        URL(string: "https://evil.example/login")!
      ))
  }

  func testStravaWebUploadParsesCSRFAndRejectsUnsafeFilenames() {
    XCTAssertEqual(
      StravaWebPlugin.extractCSRFToken(
        from: #"<meta name="csrf-token" content="token-1">"#
      ),
      "token-1"
    )
    XCTAssertTrue(StravaWebPlugin.isSafeUploadFilename("ride.fit"))
    XCTAssertFalse(StravaWebPlugin.isSafeUploadFilename("../ride.fit"))
    XCTAssertFalse(StravaWebPlugin.isSafeUploadFilename("ride.fit.exe"))
    XCTAssertEqual(
      StravaWebPlugin.duplicateActivityId(from: #"duplicate of <a href="/activities/42">"#),
      "42"
    )
  }
}

private actor ConcurrencyProbe {
  private var active = 0
  private var maximumActive = 0

  func enter() {
    active += 1
    maximumActive = max(maximumActive, active)
  }

  func leave() {
    active -= 1
  }

  func maximum() -> Int { maximumActive }
}

extension RunnerTests {
  func testWebNetworkSessionHasNoAmbientCookiesCredentialsOrRedirects() throws {
    let session = StravaWebPlugin.makeIsolatedSession()
    defer { session.invalidateAndCancel() }
    XCTAssertNil(session.configuration.httpCookieStorage)
    XCTAssertNil(session.configuration.urlCredentialStorage)
    XCTAssertNil(session.configuration.urlCache)
    XCTAssertFalse(session.configuration.httpShouldSetCookies)
    XCTAssertEqual(session.configuration.timeoutIntervalForResource, 120)
    let url = URL(string: "https://www.strava.com/upload/files")!
    let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil))
    let task = session.dataTask(with: URLRequest(url: url))
    let delegate = try XCTUnwrap(session.delegate as? URLSessionTaskDelegate)
    var called = false
    delegate.urlSession?(
      session, task: task, willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: URL(string: "https://attacker.example/upload")!)
    ) { request in
      called = true
      XCTAssertNil(request)
    }
    XCTAssertTrue(called)
  }

  func testWebUploadRejectsUntrustedEndpointsAndErrorPages() throws {
    let url = URL(string: "https://www.strava.com/upload/files")!
    let body = Data(#"duplicate of <a href='/activities/42'>ride</a>"#.utf8)
    let duplicate = try StravaWebPlugin.uploadResponse(statusCode: 422, finalURL: url, body: body)
    XCTAssertEqual(duplicate["remoteId"] as? String, "42")
    XCTAssertEqual(duplicate["isDuplicate"] as? Bool, true)
    let missingId = try StravaWebPlugin.uploadResponse(
      statusCode: 200, finalURL: url, body: Data("duplicate of activity".utf8)
    )
    XCTAssertNil(missingId["remoteId"])
    for status in [302, 307, 401, 403, 429, 500] {
      XCTAssertThrowsError(try StravaWebPlugin.uploadResponse(statusCode: status, finalURL: url, body: body))
    }
    for raw in [
      "https://evilstrava.com/upload/files", "https://www.strava.com/login",
      "http://www.strava.com/upload/files", "https://www.strava.com:444/upload/files",
      "https://user@www.strava.com/upload/files",
    ] {
      XCTAssertThrowsError(try StravaWebPlugin.uploadResponse(
        statusCode: 200, finalURL: URL(string: raw), body: body
      ))
    }
    XCTAssertThrowsError(try StravaWebPlugin.uploadResponse(
      statusCode: 400, finalURL: url, body: Data("duplicate field name".utf8)
    ))
    XCTAssertThrowsError(try StravaWebPlugin.uploadResponse(
      statusCode: 200, finalURL: url, body: Data(count: StravaWebPlugin.maximumResponseBytes + 1)
    ))
  }

  func testWebTokensCookiesAndActivityLinksAreStrictlyBounded() {
    XCTAssertEqual(StravaWebPlugin.extractCSRFToken(
      from: #"<meta content='abc-_+/=' name='csrf-token'>"#
    ), "abc-_+/=")
    XCTAssertEqual(StravaWebPlugin.extractCSRFToken(
      from: #"<input value='form-token' name='authenticity_token'>"#
    ), "form-token")
    XCTAssertNil(StravaWebPlugin.extractCSRFToken(
      from: "<meta name='csrf-token' content='abc\r\nInjected: yes'>"
    ))
    XCTAssertNil(StravaWebPlugin.extractCSRFToken(
      from: "<meta name='csrf-token' content='\(String(repeating: "x", count: 4_097))'>"
    ))
    XCTAssertEqual(StravaWebPlugin.normalizedStoredCookieHeader("Cookie: session=abc=="), "session=abc==")
    XCTAssertNil(StravaWebPlugin.normalizedStoredCookieHeader("session=a;\r\nother=b"))
    XCTAssertNil(StravaWebPlugin.normalizedStoredCookieHeader("session=a\r\nInjected: yes"))
    XCTAssertNil(StravaWebPlugin.normalizedStoredCookieHeader("session=a;"))
    XCTAssertEqual(StravaWebPlugin.activityURL(remoteId: "123")?.absoluteString, "https://www.strava.com/activities/123")
    for value in ["", "../123", "https://evil.test", "123?x=y", "１２３", String(repeating: "1", count: 33)] {
      XCTAssertNil(StravaWebPlugin.activityURL(remoteId: value))
    }
    for raw in ["https://evilfacebook.com", "https://facebook.com.evil.test", "https://www.strava.com:444", "https://user@www.strava.com"] {
      XCTAssertFalse(StravaWebPlugin.isAllowedLoginNavigation(URL(string: raw)!))
    }
  }

  func testRootCookiePersistenceDoesNotReusePathScopedCookies() throws {
    func cookie(_ name: String, _ value: String, _ domain: String, _ path: String) throws -> HTTPCookie {
      try XCTUnwrap(HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: path]))
    }
    let cookies = try [
      cookie("session", "root", ".strava.com", "/"),
      cookie("session", "athlete", ".strava.com", "/athlete"),
      cookie("api", "private", "api.strava.com", "/"),
      cookie("attacker", "bad", "evilstrava.com", "/"),
    ]
    XCTAssertEqual(StravaWebPlugin.cookieHeader(from: cookies, requestPath: "/"), "session=root")
    XCTAssertEqual(StravaWebPlugin.cookieHeader(from: cookies), "session=athlete")
  }
}


extension RunnerTests {
  func testWebDeletionOnlyTrustsExpectedResponsesAndRedirectTargets() {
    let url = URL(string: "https://www.strava.com/activities/42")!
    for location in ["/athlete/training", "https://www.strava.com/dashboard"] {
      XCTAssertTrue(StravaWebPlugin.isSuccessfulDeletion(
        statusCode: 302, finalURL: url, remoteId: "42", location: location, body: Data()
      ))
    }
    for location in ["/login", "https://evil.test/dashboard", "//evil.test/athlete/training", "/activities/42", "https://www.strava.com:444/dashboard"] {
      XCTAssertFalse(StravaWebPlugin.isSuccessfulDeletion(
        statusCode: 302, finalURL: url, remoteId: "42", location: location, body: Data()
      ))
    }
    XCTAssertTrue(StravaWebPlugin.isSuccessfulDeletion(
      statusCode: 404, finalURL: url, remoteId: "42", location: nil, body: Data()
    ))
    XCTAssertFalse(StravaWebPlugin.isSuccessfulDeletion(
      statusCode: 403, finalURL: url, remoteId: "42", location: nil, body: Data("not found".utf8)
    ))
    XCTAssertFalse(StravaWebPlugin.isSuccessfulDeletion(
      statusCode: 200, finalURL: url, remoteId: "42", location: nil, body: Data("please log in".utf8)
    ))
    XCTAssertFalse(StravaWebPlugin.isSuccessfulDeletion(
      statusCode: 404, finalURL: URL(string: "https://evil.test/activities/42"),
      remoteId: "42", location: nil, body: Data()
    ))
    let csrf = StravaWebPlugin.extractCSRFPair(
      from: #"<meta name='csrf-param' content='csrf_param'><meta name='csrf-token' content='a+/='>"#
    )
    XCTAssertEqual(csrf?.param, "csrf_param")
    XCTAssertEqual(csrf?.token, "a+/=")
    XCTAssertNil(StravaWebPlugin.extractCSRFPair(
      from: #"<meta name='csrf-param' content='_method'><meta name='csrf-token' content='delete'>"#
    ))
  }

  func testWebActivityPageBoundsAndUtcDates() throws {
    let start = Int64(ISO8601DateFormatter().date(from: "2026-09-30T00:00:00Z")!.timeIntervalSince1970 * 1_000)
    let end = start + 86_400_000
    let url = try XCTUnwrap(StravaWebPlugin.activityPageURL(page: 2, afterMs: start, beforeMs: end))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
    XCTAssertEqual(items["start_date"], "09/29/2026")
    XCTAssertEqual(items["end_date"], "10/02/2026")
    XCTAssertEqual(items["page"], "2")
    XCTAssertEqual(components.host, "www.strava.com")
    XCTAssertEqual(components.path, "/athlete/training_activities")
    XCTAssertNil(StravaWebPlugin.activityPageURL(page: 0, afterMs: start, beforeMs: end))
    XCTAssertNil(StravaWebPlugin.activityPageURL(page: 201, afterMs: start, beforeMs: end))
    XCTAssertNil(StravaWebPlugin.activityPageURL(page: 1, afterMs: end, beforeMs: start))
    XCTAssertNil(StravaWebPlugin.activityPageURL(page: 1, afterMs: .min, beforeMs: .max))
  }
}


extension RunnerTests {
  func testOAuthRejectsUserinfoPortsFragmentsAndAmbiguousCallbacks() {
    for value in [
      "https://user@www.strava.com/oauth/mobile/authorize",
      "https://www.strava.com:444/oauth/mobile/authorize",
      "https://www.strava.com/oauth/mobile/authorize#fragment",
      "https://www.strava.com/oauth/mobile/%61uthorize",
    ] {
      XCTAssertThrowsError(try StravaOAuthSecurity.authorizationURL(from: value, state: "state"))
    }
    for value in [
      "healthworkoutexport://user@localhost/callback?state=state&code=code",
      "healthworkoutexport://localhost:443/callback?state=state&code=code",
      "healthworkoutexport://localhost/callback?state=state&code=code#fragment",
      "healthworkoutexport://localhost/callback?state=state&state=state&code=code",
    ] {
      XCTAssertFalse(StravaOAuthSecurity.isValidCallback(
        URL(string: value)!, callbackScheme: "healthworkoutexport", expectedState: "state"
      ))
    }
  }

  func testBatchSessionHasFixedPathBoundedJsonAndAtomicRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchSessionTests.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = SyncFilesPlugin.Storage(rootURL: root)
    XCTAssertEqual(try storage.url(for: .batchSession).lastPathComponent, "auto-sync-batch.json")
    let data = Data(#"{"version":1,"phase":"uploading"}"#.utf8)
    try storage.write(data, kind: .batchSession)
    XCTAssertEqual(try storage.read(.batchSession), data)
    XCTAssertThrowsError(try storage.write(Data("[]".utf8), kind: .batchSession))
    XCTAssertThrowsError(try storage.write(Data(count: 4 * 1_024 * 1_024 + 1), kind: .batchSession))
    XCTAssertEqual(try storage.read(.batchSession), data)
    try storage.delete(.batchSession)
    try storage.delete(.batchSession)
    XCTAssertThrowsError(try storage.read(.batchSession))
  }
}


extension RunnerTests {
  private func healthWriteDraftData(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    var payload: [String: Any] = [
      "fingerprint": String(repeating: "a", count: 64),
      "activityType": 13, "startMs": 1_000, "endMs": 4_000, "durationSeconds": 3.0,
      "distanceMeters": NSNull(), "energyKilocalories": NSNull(),
      "locations": [["latitude": 31.5, "longitude": 120.5, "timestampMs": 1_500]],
      "heartRate": [["dateMs": 1_500, "value": 140.0, "unit": "count/min"]],
      "cadence": [["dateMs": 1_500, "value": 90.0, "unit": "rpm"]],
      "power": [["dateMs": 1_500, "value": 180.0, "unit": "W"]],
      "speed": [["dateMs": 1_500, "value": 7.0, "unit": "m/s"]],
      "events": [["type": "pause", "dateMs": 2_000], ["type": "resume", "dateMs": 3_000]],
    ]
    edit(&payload)
    return try JSONSerialization.data(withJSONObject: payload)
  }

  func testHealthWriteDraftPreservesSparseValuesAndUnits() throws {
    let draft = try HealthWorkoutWriteDraft.parse(healthWriteDraftData())
    XCTAssertEqual(draft.workoutType, .cycling)
    XCTAssertEqual(draft.fingerprint, String(repeating: "a", count: 64))
    XCTAssertNil(draft.distanceMeters)
    XCTAssertNil(draft.energyKilocalories)
    XCTAssertNil(draft.locations.first?.altitudeMeters)
    XCTAssertEqual(draft.locations.first?.timestampMs, 1_500)
    XCTAssertEqual(draft.cadence.first?.unit, "rpm")
    XCTAssertEqual(draft.heartRate.first?.value, 140)
    XCTAssertEqual(draft.events.count, 2)
  }

  func testHealthWriteDraftRejectsMalformedBoundariesAndUnrecognizedUnits() throws {
    let mutations: [(inout [String: Any]) -> Void] = [
      { $0["fingerprint"] = "../unsafe" },
      { $0["activityType"] = 999_999 },
      { $0["startMs"] = true },
      { $0["startMs"] = 5_000 },
      { $0["durationSeconds"] = 10_000 },
      { $0["distanceMeters"] = -1 },
      { $0["heartRate"] = [["dateMs": -9_000_000_000_000_000, "value": 140, "unit": "count/min"]] },
      { $0["speed"] = [["dateMs": 1_500, "value": 7, "unit": "km/h"]] },
      { $0["power"] = [["dateMs": 1_500, "value": -10, "unit": "W"]] },
      { $0["locations"] = [["latitude": 91, "longitude": 120, "timestampMs": 1_500]] },
      { $0["events"] = [["type": "delete", "dateMs": 2_000]] },
      { $0["events"] = [["type": "pause", "dateMs": 3_000], ["type": "resume", "dateMs": 2_000]] },
    ]
    for mutation in mutations {
      XCTAssertThrowsError(try HealthWorkoutWriteDraft.parse(healthWriteDraftData(mutation)))
    }
    XCTAssertThrowsError(try HealthWorkoutWriteDraft.parse(Data()))
    XCTAssertThrowsError(try HealthWorkoutWriteDraft.parse(Data(count: HealthWorkoutWriteDraft.maximumBytes + 1)))
  }
}


extension RunnerTests {
  func testHealthWriteCollectionCoversRealSamplesOutsideSummary() throws {
    let data = try healthWriteDraftData {
      $0["heartRate"] = [["dateMs": 500, "value": 140, "unit": "count/min"]]
      $0["speed"] = [["dateMs": 5_000, "value": 7, "unit": "m/s"]]
    }
    let draft = try HealthWorkoutWriteDraft.parse(data)
    XCTAssertEqual(draft.startMs, 1_000)
    XCTAssertEqual(draft.endMs, 4_000)
    XCTAssertEqual(draft.collectionStartMs, 500)
    XCTAssertEqual(draft.collectionEndMs, 6_000)
  }
}


extension RunnerTests {
  func testHealthWriteEqualSummaryTimesRetainOneSecondCollection() throws {
    let data = try healthWriteDraftData {
      $0["startMs"] = 1_000
      $0["endMs"] = 1_000
      $0["durationSeconds"] = 0
      $0["locations"] = []
      $0["heartRate"] = [["dateMs": 1_000, "value": 140, "unit": "count/min"]]
      $0["cadence"] = []
      $0["power"] = []
      $0["speed"] = []
      $0["events"] = []
    }
    let draft = try HealthWorkoutWriteDraft.parse(data)
    XCTAssertEqual(draft.startMs, draft.endMs)
    XCTAssertGreaterThanOrEqual(draft.collectionEndMs, draft.collectionStartMs + 1_000)
  }

  func testHealthWriteEqualSummaryWithoutSamplesStillHasPositiveCollection() throws {
    let data = try healthWriteDraftData {
      $0["startMs"] = 1_000
      $0["endMs"] = 1_000
      $0["durationSeconds"] = 0
      for key in ["locations", "heartRate", "cadence", "power", "speed", "events"] { $0[key] = [] }
    }
    let draft = try HealthWorkoutWriteDraft.parse(data)
    XCTAssertEqual(draft.collectionEndMs, 2_000)
  }
}


extension RunnerTests {
  func testPreferencesPreserveLegacyPreviewAndHealthWriteKeys() throws {
    let suite = "PreferencesMigrationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("issuesOnly", forKey: "sync_preview_policy")
    defaults.set(true, forKey: "write_to_apple_health")
    let plugin = PreferencesPlugin(defaults: defaults)
    var value: Any?
    plugin.handle(FlutterMethodCall(methodName: "read", arguments: ["key": "sync_preview_policy"])) { value = $0 }
    XCTAssertEqual(value as? String, "issuesOnly")
    plugin.handle(FlutterMethodCall(methodName: "read", arguments: ["key": "write_to_apple_health"])) { value = $0 }
    XCTAssertEqual(value as? Bool, true)
    plugin.handle(FlutterMethodCall(methodName: "write", arguments: ["key": "sync_preview_policy", "value": "everyActivity"])) { value = $0 }
    XCTAssertNil(value)
    XCTAssertEqual(defaults.string(forKey: "sync_preview_policy"), "everyActivity")
    plugin.handle(FlutterMethodCall(methodName: "write", arguments: ["key": "write_to_apple_health", "value": false])) { value = $0 }
    XCTAssertNil(value)
    XCTAssertFalse(defaults.bool(forKey: "write_to_apple_health"))
  }
}


extension RunnerTests {
  func testHealthPreparedChannelKeepsUploadedArchiveSeparate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HealthPreparedTests.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = SyncFilesPlugin.Storage(rootURL: root)
    let fingerprint = String(repeating: "a", count: 64)
    let uploaded = Data([1, 2, 3])
    let health = Data([8, 9])
    try storage.write(uploaded, kind: .syncedFIT(fingerprint))
    let plugin = SyncFilesPlugin(storage: storage)
    func invoke(_ method: String, bytes: Data? = nil) -> Any? {
      var arguments: [String: Any] = ["fingerprint": fingerprint]
      if let bytes { arguments["bytes"] = FlutterStandardTypedData(bytes: bytes) }
      var response: Any?
      plugin.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { response = $0 }
      return response
    }
    XCTAssertNil(invoke("writeHealthPreparedFit", bytes: health))
    XCTAssertEqual(try XCTUnwrap(invoke("readHealthPreparedFit") as? FlutterStandardTypedData).data, health)
    XCTAssertEqual(try storage.read(.syncedFIT(fingerprint)), uploaded)
    XCTAssertNil(invoke("deleteHealthPreparedFit"))
    XCTAssertTrue(invoke("readHealthPreparedFit") is FlutterError)
    XCTAssertEqual(try storage.read(.syncedFIT(fingerprint)), uploaded)
  }
  #if os(macOS)
  func testSyncFitUsesOwnerOnlyPermissions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncPermissions.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = SyncFilesPlugin.Storage(rootURL: root)
    let kind = SyncFilesPlugin.FileKind.syncedFIT(String(repeating: "a", count: 64))
    try storage.write(Data([1]), kind: kind)
    let file = try storage.url(for: kind)
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
    let directoryPermissions = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(directoryPermissions?.intValue, 0o700)
  }
  #endif
}
