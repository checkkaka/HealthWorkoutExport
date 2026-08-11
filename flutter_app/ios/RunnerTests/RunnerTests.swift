import Flutter
import HealthKit
import UIKit
import XCTest

@testable import Runner

class RunnerTests: XCTestCase {

  func testHealthKitIntervalRequiresAscendingFiniteMilliseconds() throws {
    let interval = try HealthKitPlugin.parseInterval(arguments: ["startMs": 1_000, "endMs": 2_000])
    XCTAssertEqual(interval.start.timeIntervalSince1970, 1)
    XCTAssertEqual(interval.end.timeIntervalSince1970, 2)

    XCTAssertThrowsError(
      try HealthKitPlugin.parseInterval(arguments: ["startMs": 2_000, "endMs": 2_000])
    )
  }

  func testKeychainRejectsEmptyAccountBeforeSecurityCall() {
    var response: Any?
    KeychainPlugin().handle(
      FlutterMethodCall(methodName: "read", arguments: ["account": ""])
    ) { response = $0 }

    XCTAssertEqual((response as? FlutterError)?.code, "invalid_arguments")
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
        }
      )

      XCTAssertEqual(outcome.error?.code, "forced_failure")
      XCTAssertFalse(outcome.rollbackFailed)
      XCTAssertEqual(stored, original)
    }
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
