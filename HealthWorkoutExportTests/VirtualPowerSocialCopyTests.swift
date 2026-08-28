import XCTest
@testable import HealthWorkoutExport

final class VirtualPowerSocialCopyTests: XCTestCase {
    /// 文案为用户确认的固定句，避免误改。
    func testConfirmedCopy() {
        XCTAssertEqual(
            VirtualPowerSocialCopy.activityDescription,
            "功率计还在许愿清单里，本场瓦特是风、坡和速度一起算的，看看就好～（出自 HealthWorkoutExport）"
        )
    }
}
