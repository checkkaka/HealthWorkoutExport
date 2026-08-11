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

  func testHealthKitSummaryHelpersMatchSwiftBaseline() {
    XCTAssertEqual(HKWorkoutActivityType.cycling.localizedChineseName, "骑车")
    XCTAssertEqual(
      HealthKitPlugin.millisecondsSinceEpoch(Date(timeIntervalSince1970: 1)),
      1_000
    )
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
