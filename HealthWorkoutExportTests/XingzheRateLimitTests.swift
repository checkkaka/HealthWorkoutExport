import XCTest
@testable import HealthWorkoutExport

final class XingzheRateLimitTests: XCTestCase {
    func testParseAvailableInOneSecond() {
        let body = #"{"code":400,"data":{},"msg":"request limit exceeded, available in 1 seconds "}"#
        XCTAssertEqual(XingzheRateLimit.waitSeconds(statusCode: 400, body: body), 1)
    }

    func testParseAvailableInThreeSeconds() {
        let body = "request limit exceeded, available in 3 seconds"
        XCTAssertEqual(XingzheRateLimit.parseAvailableSeconds(body), 3)
    }

    func testNilWhenNotRateLimited() {
        XCTAssertNil(XingzheRateLimit.waitSeconds(statusCode: 500, body: "server error"))
    }
}
