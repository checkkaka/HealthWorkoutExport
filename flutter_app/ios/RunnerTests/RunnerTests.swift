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
