import Flutter
import HealthKit
@testable import Runner
import UIKit
import XCTest

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
}
