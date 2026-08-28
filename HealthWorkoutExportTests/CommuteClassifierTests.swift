import XCTest
@testable import HealthWorkoutExport

final class CommuteClassifierTests: XCTestCase {
    func testShortDistanceIsCommute() {
        // 4km / 20min
        XCTAssertTrue(CommuteClassifier.isCommute(distanceMeters: 4000, durationSeconds: 1200))
    }

    func testSlowUnder16KmIsCommute() {
        // 12km / 30min ≈ 24 km/h < 28
        XCTAssertTrue(CommuteClassifier.isCommute(distanceMeters: 12_000, durationSeconds: 1800))
    }

    func testFastLongRideNotCommute() {
        // 20km / 40min = 30 km/h
        XCTAssertFalse(CommuteClassifier.isCommute(distanceMeters: 20_000, durationSeconds: 2400))
    }

    func testSlowButLongNotCommute() {
        // 20km / 50min = 24 km/h but distance >= 16
        XCTAssertFalse(CommuteClassifier.isCommute(distanceMeters: 20_000, durationSeconds: 3000))
    }

    func testCommuteUsesBikeTitleUnlessCustom() {
        XCTAssertEqual(
            CommuteClassifier.stravaActivityName(
                customTitle: nil,
                isCommute: true,
                originalTitle: "骑车"
            ),
            "通勤🚲"
        )
        XCTAssertEqual(
            CommuteClassifier.stravaActivityName(
                customTitle: " 回家 ",
                isCommute: true,
                originalTitle: "骑车"
            ),
            "回家"
        )
        XCTAssertEqual(
            CommuteClassifier.stravaActivityName(
                customTitle: nil,
                isCommute: false,
                originalTitle: "骑车"
            ),
            "骑车"
        )
    }

    func testVirtualPowerCopyAppendsAtEnd() {
        XCTAssertEqual(
            VirtualPowerSocialCopy.appended(to: nil),
            VirtualPowerSocialCopy.activityDescription
        )
        XCTAssertEqual(
            VirtualPowerSocialCopy.appended(to: "晨骑"),
            "晨骑\n\n" + VirtualPowerSocialCopy.activityDescription
        )
        XCTAssertEqual(
            VirtualPowerSocialCopy.appended(to: VirtualPowerSocialCopy.activityDescription),
            VirtualPowerSocialCopy.activityDescription
        )
    }

    func testCommuteUsesRoadsideWindShelter() {
        XCTAssertEqual(
            CommuteClassifier.windShelterFactor(distanceMeters: 3_430, durationSeconds: 507),
            0.7,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CommuteClassifier.windShelterFactor(distanceMeters: 20_000, durationSeconds: 2_400),
            1.0,
            accuracy: 0.001
        )
    }
}
