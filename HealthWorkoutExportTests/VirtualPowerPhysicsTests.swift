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

    /// 踏频很低但仍有速度：曲柄已停、车在溜，按滑行 0 W。
    func testLowCadenceWithSpeedForcesCoastingZero() {
        let params = VirtualPowerPhysics.Params(
            totalMassKg: 80,
            cda: 0.32,
            crr: 0.004,
            drivetrainLossPercent: 2,
            airDensity: 1.226
        )
        let watts = VirtualPowerPhysics.powerWatts(
            groundSpeedMps: 8,
            gradePercent: 0,
            headwindMps: 0,
            accelerationMps2: 0,
            params: params,
            cadenceRpm: 20
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

    /// Open-Meteo 10 m 风按公路车 1.0 m、α=1/7 折到约 0.72。
    func testTenMeterWindScalesToRiderHeight() {
        XCTAssertEqual(
            VirtualPowerPhysics.riderHeightWindMps(fromTenMeter: 10),
            7.2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            VirtualPowerPhysics.riderHeightWindMps(fromTenMeter: 0),
            0,
            accuracy: 0.001
        )
    }

    /// 大跳变且下一秒回落 → 判定飞点。
    func testGpsGlitchRequiresJumpAndRecovery() {
        XCTAssertTrue(
            VirtualPowerPhysics.isGpsSpeedGlitch(
                previousMps: 34.6 / 3.6,
                candidateMps: 60.6 / 3.6,
                followingMps: 35.0 / 3.6,
                dtToCandidate: 1,
                dtToFollowing: 1
            )
        )
    }

    /// 仅有跳变、后续继续升高 → 不当飞点（可能是真加速）。
    func testGpsGlitchRejectedWhenFollowingContinues() {
        XCTAssertFalse(
            VirtualPowerPhysics.isGpsSpeedGlitch(
                previousMps: 20 / 3.6,
                candidateMps: 30 / 3.6,
                followingMps: 32 / 3.6,
                dtToCandidate: 1,
                dtToFollowing: 1
            )
        )
    }

    /// 急刹后继续低速：跳变大但不回落靠近前值 → 不当飞点。
    func testHardBrakeNotTreatedAsGlitch() {
        XCTAssertFalse(
            VirtualPowerPhysics.isGpsSpeedGlitch(
                previousMps: 45 / 3.6,
                candidateMps: 13 / 3.6,
                followingMps: 12 / 3.6,
                dtToCandidate: 1,
                dtToFollowing: 1
            )
        )
    }

    /// 飞点速度替换为上一秒。
    func testReplaceGlitchSpeedsUsesPrevious() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let times: [Date?] = [
            t0,
            t0.addingTimeInterval(1),
            t0.addingTimeInterval(2),
            t0.addingTimeInterval(3)
        ]
        let speeds: [Double?] = [
            34.6 / 3.6,
            60.6 / 3.6,
            35.0 / 3.6,
            34.8 / 3.6
        ]
        let cleaned = VirtualPowerPhysics.replaceGlitchSpeedsWithPrevious(
            speeds: speeds,
            times: times
        )
        XCTAssertEqual(cleaned[1]!, speeds[0]!, accuracy: 0.001)
        XCTAssertEqual(cleaned[0]!, speeds[0]!, accuracy: 0.001)
        XCTAssertEqual(cleaned[2]!, speeds[2]!, accuracy: 0.001)
    }

    /// 正常冲刺加速应钳在 ±2.0。
    func testSanitizedAccelerationClampsToSprintCap() {
        let within = VirtualPowerPhysics.sanitizedAccelerationMps2(
            smoothedAccelerationMps2: 1.6,
            dtSeconds: 1
        )
        XCTAssertEqual(within, 1.6, accuracy: 0.001)

        let over = VirtualPowerPhysics.sanitizedAccelerationMps2(
            smoothedAccelerationMps2: 2.5,
            dtSeconds: 1
        )
        XCTAssertEqual(over, VirtualPowerPhysics.maxRealisticAccelerationMps2, accuracy: 0.001)

        let under = VirtualPowerPhysics.sanitizedAccelerationMps2(
            smoothedAccelerationMps2: -2.5,
            dtSeconds: 1
        )
        XCTAssertEqual(under, -VirtualPowerPhysics.maxRealisticAccelerationMps2, accuracy: 0.001)
    }
}
