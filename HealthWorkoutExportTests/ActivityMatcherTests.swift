import XCTest
@testable import HealthWorkoutExport

final class ActivityMatcherTests: XCTestCase {
    func testOverlapMatch() {
        let primary = SourceActivity(
            id: "p1", sourceId: "healthkit", title: "主",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            duration: 3600, distanceMeters: 20_000
        )
        let good = SourceActivity(
            id: "s1", sourceId: "xingzhe", title: "补",
            startDate: Date(timeIntervalSince1970: 1_700_000_300),
            endDate: Date(timeIntervalSince1970: 1_700_003_500),
            duration: 3200, distanceMeters: 19_000
        )
        let far = SourceActivity(
            id: "s2", sourceId: "xingzhe", title: "远",
            startDate: Date(timeIntervalSince1970: 1_700_100_000),
            endDate: Date(timeIntervalSince1970: 1_700_103_600),
            duration: 3600, distanceMeters: 20_000
        )
        let match = ActivityMatcher.bestMatch(primary: primary, candidates: [far, good])
        XCTAssertEqual(match?.id, "s1")
    }

    func testNoMatchWhenTooFar() {
        let primary = SourceActivity(
            id: "p1", sourceId: "healthkit", title: "主",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            duration: 3600, distanceMeters: 20_000
        )
        let far = SourceActivity(
            id: "s2", sourceId: "onelap", title: "远",
            startDate: Date(timeIntervalSince1970: 1_700_100_000),
            endDate: Date(timeIntervalSince1970: 1_700_103_600),
            duration: 3600, distanceMeters: 20_000
        )
        XCTAssertNil(ActivityMatcher.bestMatch(primary: primary, candidates: [far]))
    }

    func testNoMatchWhenOverlapIsTiny() {
        let primary = SourceActivity(
            id: "p1", sourceId: "healthkit", title: "主",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            duration: 3600, distanceMeters: 20_000
        )
        let barelyOverlapping = SourceActivity(
            id: "s1", sourceId: "xingzhe", title: "擦边",
            startDate: Date(timeIntervalSince1970: 1_700_003_599),
            endDate: Date(timeIntervalSince1970: 1_700_010_799),
            duration: 7200, distanceMeters: 40_000
        )
        XCTAssertNil(ActivityMatcher.bestMatch(primary: primary, candidates: [barelyOverlapping]))
    }

    func testLowOverlapFallsBackToStartAndDurationTolerance() {
        let primary = SourceActivity(
            id: "p1", sourceId: "healthkit", title: "主",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            duration: 3600, distanceMeters: 20_000
        )
        let withinTolerance = SourceActivity(
            id: "s1", sourceId: "xingzhe", title: "补",
            startDate: Date(timeIntervalSince1970: 1_699_999_100),
            endDate: Date(timeIntervalSince1970: 1_700_001_980),
            duration: 2880, distanceMeters: 19_000
        )
        XCTAssertEqual(
            ActivityMatcher.bestMatch(primary: primary, candidates: [withinTolerance])?.id,
            "s1"
        )
    }
}
