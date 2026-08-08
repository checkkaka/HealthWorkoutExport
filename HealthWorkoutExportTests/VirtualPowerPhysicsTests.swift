import XCTest
@testable import HealthWorkoutExport

final class VirtualPowerPhysicsTests: XCTestCase {
    /// 平路、无风、无加速度：功率应接近纯滚阻 + 风阻（Gribble）。
    func testFlatNoWindMatchesGribbleSteadyState() {
        let params = VirtualPowerPhysics.Params(
            totalMassKg: 80,
            cda: 0.32,
            crr: 0.004,
            drivetrainLossPercent: 2,
            airDensity: 1.226
        )
        // 调用 VirtualPowerPhysics.powerWatts：稳态平路 10 m/s。
        let watts = VirtualPowerPhysics.powerWatts(
            groundSpeedMps: 10,
            gradePercent: 0,
            headwindMps: 0,
            accelerationMps2: 0,
            params: params
        )
        // 手算：Fg=0；Fr=9.8067*80*0.004=3.138144；
        // Fa=0.5*0.32*1.226*100=19.616；F=22.754144；Pwheel=227.541；Plegs≈232.185
        XCTAssertEqual(watts, 232.2, accuracy: 0.5)
    }

    /// 下坡且无力蹬时，负功率钳制为 0。
    func testNegativePowerClampedToZero() {
        let params = VirtualPowerPhysics.Params(
            totalMassKg: 80,
            cda: 0.32,
            crr: 0.004,
            drivetrainLossPercent: 2,
            airDensity: 1.226
        )
        let watts = VirtualPowerPhysics.powerWatts(
            groundSpeedMps: 12,
            gradePercent: -8,
            headwindMps: 0,
            accelerationMps2: 0,
            params: params
        )
        XCTAssertEqual(watts, 0, accuracy: 0.01)
    }

    /// 踏频为 0 时视为滑行，功率强制 0。
    func testCadenceZeroForcesCoastingZero() {
        let params = VirtualPowerPhysics.Params(
            totalMassKg: 80,
            cda: 0.32,
            crr: 0.004,
            drivetrainLossPercent: 2,
            airDensity: 1.226
        )
        let watts = VirtualPowerPhysics.powerWatts(
            groundSpeedMps: 10,
            gradePercent: 5,
            headwindMps: 0,
            accelerationMps2: 0,
            params: params,
            cadenceRpm: 0
        )
        XCTAssertEqual(watts, 0, accuracy: 0.01)
    }

    /// 空气密度：15°C、1013.25 hPa、RH=0 应接近 1.225。
    func testAirDensityDrySeaLevel() {
        let rho = VirtualPowerPhysics.airDensity(
            temperatureC: 15,
            pressureHpa: 1013.25,
            relativeHumidityPercent: 0
        )
        XCTAssertEqual(rho, 1.225, accuracy: 0.01)
    }

    /// 迎风分量：正北骑、东风 → 侧风，迎风约 0。
    func testHeadwindComponentCrosswindNearZero() {
        let hw = VirtualPowerPhysics.headwindMps(
            windSpeedMps: 5,
            windFromDegrees: 90,
            ridingBearingDegrees: 0
        )
        XCTAssertEqual(hw, 0, accuracy: 0.05)
    }

    /// 正北骑、北风 → 迎风等于风速。
    func testHeadwindComponentHeadOn() {
        let hw = VirtualPowerPhysics.headwindMps(
            windSpeedMps: 5,
            windFromDegrees: 0,
            ridingBearingDegrees: 0
        )
        XCTAssertEqual(hw, 5, accuracy: 0.05)
    }
}
