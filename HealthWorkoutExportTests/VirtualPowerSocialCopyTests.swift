import XCTest
@testable import HealthWorkoutExport

final class VirtualPowerSocialCopyTests: XCTestCase {
    /// 文案为用户确认的固定句，避免误改。
    func testConfirmedCopy() {
        XCTAssertEqual(
            VirtualPowerSocialCopy.activityDescription,
            "没钱买功率计，本场瓦特靠风速、坡度和速度等参数拼出来的，仅供参考（出自HealthWorkoutExport）"
        )
    }
}
