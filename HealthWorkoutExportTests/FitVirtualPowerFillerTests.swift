import XCTest
import FITSwiftSDK
@testable import HealthWorkoutExport

final class FitVirtualPowerFillerTests: XCTestCase {
    /// 已有功率的秒也应被虚拟功率覆盖；踏频 0 仍写 0。
    func testOverwritesExistingPowerRecords() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let fit = try makeFit(
            start: start,
            records: [
                (0, speed: 8, alt: 10, power: 180, cadence: 80),
                (1, speed: 8, alt: 10, power: nil, cadence: 80),
                (2, speed: 8, alt: 10, power: nil, cadence: 0)
            ]
        )
        let params = VirtualPowerPhysics.Params(
            totalMassKg: 80,
            cda: 0.32,
            crr: 0.004,
            drivetrainLossPercent: 2,
            airDensity: 1.226
        )
        // 调用 FitVirtualPowerFiller：注入空天气，验证已有功率也被覆盖。
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            settings: params,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertEqual(result.filledCount, 3)
        let messages = try FitMerger.decode(result.data)
        let records = messages.recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        XCTAssertNotNil(records[0].getPower())
        XCTAssertNotEqual(records[0].getPower(), 180, "已有功率应被覆盖")
        XCTAssertNotNil(records[1].getPower())
        XCTAssertNotEqual(records[1].getPower(), 180)
        XCTAssertEqual(records[2].getPower(), 0, "踏频 0 应填 0")
    }

    /// 文件全部已有功率时仍估算并覆盖写入。
    func testOverwritesWhenAllPowerPresent() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let fit = try makeFit(
            start: start,
            records: [
                (0, speed: 8, alt: 10, power: 200, cadence: 90),
                (1, speed: 8, alt: 10, power: 210, cadence: 90)
            ]
        )
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertEqual(result.filledCount, 2)
        XCTAssertFalse(result.activityRejected)
        let records = try FitMerger.decode(result.data).recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        XCTAssertNotEqual(records[0].getPower(), 200)
        XCTAssertNotEqual(records[1].getPower(), 210)
        XCTAssertEqual(
            VirtualPowerSourceMark.powerSource(of: records[0]),
            VirtualPowerSourceMark.virtualValue
        )
        XCTAssertEqual(
            VirtualPowerSourceMark.powerSource(of: records[1]),
            VirtualPowerSourceMark.virtualValue
        )
    }

    /// 天气 provider 抛取消时应向上抛出，不得吞掉。
    func testRethrowsCancellationFromWeather() async {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let fit = try! makeFit(
            start: start,
            records: [(0, speed: 8, alt: 10, power: nil, cadence: 80)]
        )
        do {
            _ = try await FitVirtualPowerFiller.fillIfNeeded(
                fit,
                weatherProvider: { _, _, _, _ in throw CancellationError() }
            )
            XCTFail("应抛出 CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("意外错误：\(error)")
        }
    }

    /// 低速 + 踏频 0 也应写入 0，而不是跳过。
    func testZeroCadenceAtLowSpeedWritesZero() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let fit = try makeFit(
            start: start,
            records: [(0, speed: 0.05, alt: 10, power: nil, cadence: 0)]
        )
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertEqual(result.filledCount, 1)
        let records = try FitMerger.decode(result.data).recordMesgs
        XCTAssertEqual(records.first?.getPower(), 0)
    }

    /// 估算写入的秒应带 developer 字段 powerSource=virtual；原有功率秒同样覆盖并打标。
    func testMarksFilledRecordsWithPowerSourceVirtual() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let fit = try makeFit(
            start: start,
            records: [
                (0, speed: 8, alt: 10, power: 180, cadence: 80),
                (1, speed: 8, alt: 10, power: nil, cadence: 80)
            ]
        )
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertEqual(result.filledCount, 2)
        XCTAssertFalse(result.activityRejected)

        let messages = try FitMerger.decode(result.data)
        XCTAssertFalse(messages.developerDataIdMesgs.isEmpty)
        XCTAssertTrue(
            messages.fieldDescriptionMesgs.contains {
                $0.getFieldName(index: 0) == VirtualPowerSourceMark.fieldName
            }
        )
        XCTAssertTrue(
            messages.deviceInfoMesgs.contains { $0.getProductName() == "VirtPower Est" }
        )

        let records = messages.recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        XCTAssertNotEqual(records[0].getPower(), 180, "原有功率应被覆盖")
        XCTAssertEqual(
            VirtualPowerSourceMark.powerSource(of: records[0]),
            VirtualPowerSourceMark.virtualValue
        )
        XCTAssertEqual(
            VirtualPowerSourceMark.powerSource(of: records[1]),
            VirtualPowerSourceMark.virtualValue
        )
        XCTAssertEqual(result.virtualMarkedCount, 2)
        XCTAssertTrue(VirtualPowerSourceMark.containsVirtualMarkedRecord(in: messages))
    }

    /// 单秒缺速度失败时，应用前后 5 秒功率均值回填，并标 failed。
    func testFailedSecondUsesNeighborAveragePower() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let fit = try makeFit(
            start: start,
            records: [
                (0, speed: 8, alt: 10, power: nil, cadence: 80),
                (1, speed: nil, alt: 10, power: nil, cadence: 80),
                (2, speed: 8, alt: 10, power: nil, cadence: 80)
            ]
        )
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertFalse(result.activityRejected)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.filledCount, 3)

        let records = try FitMerger.decode(result.data).recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        let p0 = try XCTUnwrap(records[0].getPower())
        let p1 = try XCTUnwrap(records[1].getPower())
        let p2 = try XCTUnwrap(records[2].getPower())
        let expected = UInt16(((Double(p0) + Double(p2)) / 2.0).rounded())
        XCTAssertEqual(p1, expected)

        let mark = records[1].developerFields.first {
            $0.getName() == VirtualPowerSourceMark.fieldName
        }
        XCTAssertEqual(mark?.getValue(index: 0) as? String, VirtualPowerSourceMark.failedValue)
        XCTAssertEqual(
            records[0].developerFields.first { $0.getName() == VirtualPowerSourceMark.fieldName }?
                .getValue(index: 0) as? String,
            VirtualPowerSourceMark.virtualValue
        )
    }

    /// 参与估算秒失败率 ≥10% 时整条放弃，不写任何功率。
    func testRejectsActivityWhenFailRateAtLeastTenPercent() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        // 10 秒缺功率，其中 1 秒无速度 → 失败率 10%，应整条放弃。
        var specs: [(offset: Double, speed: Double?, alt: Double, power: UInt16?, cadence: UInt8)] = []
        for i in 0..<10 {
            specs.append((Double(i), speed: i == 5 ? nil : 8, alt: 10, power: nil, cadence: 80))
        }
        let fit = try makeFit(start: start, records: specs)
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertTrue(result.activityRejected)
        XCTAssertEqual(result.filledCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.data, fit)
        XCTAssertTrue(result.note.contains("整条放弃"))
    }

    /// 失败率低于 10% 时不放弃，邻域补上的秒仍写入。
    func testKeepsActivityWhenFailRateBelowTenPercent() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        // 11 秒缺功率，1 秒失败 → ≈9.09% < 10%。
        var specs: [(offset: Double, speed: Double?, alt: Double, power: UInt16?, cadence: UInt8)] = []
        for i in 0..<11 {
            specs.append((Double(i), speed: i == 5 ? nil : 8, alt: 10, power: nil, cadence: 80))
        }
        let fit = try makeFit(start: start, records: specs)
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertFalse(result.activityRejected)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.filledCount, 11)
    }

    /// GPS 速度飞点（跳变+回落）应先换成上一秒速度，功率不再虚高到上千瓦。
    func testGpsSpeedJumpDoesNotInflateVirtualPower() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let fit = try makeFit(
            start: start,
            records: [
                (0, speed: 9.6, alt: 10, power: nil, cadence: 90),   // ~34.6 km/h
                (1, speed: 16.8, alt: 10, power: nil, cadence: 90),  // ~60.5 km/h 飞点
                (2, speed: 9.7, alt: 10, power: nil, cadence: 90),   // 回落
                (3, speed: 9.5, alt: 10, power: nil, cadence: 90)
            ]
        )
        let params = VirtualPowerPhysics.Params(
            totalMassKg: 71,
            cda: 0.35,
            crr: 0.005,
            drivetrainLossPercent: 2,
            airDensity: 1.225
        )
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            settings: params,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertFalse(result.activityRejected)
        let records = try FitMerger.decode(result.data).recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        let spikePower = try XCTUnwrap(records[1].getPower())
        // 飞点已换成上秒速度后，不应再出现含假加速/假高速的上千瓦。
        XCTAssertLessThan(spikePower, 500, "飞点秒功率应被压住，实际 \(spikePower)")
    }

    /// 关闭惯性后，加速段功率应不高于开启惯性。
    func testIncludeInertiaOffIgnoresAcceleration() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let fit = try makeFit(
            start: start,
            records: [
                (0, speed: 6, alt: 10, power: nil, cadence: 90),
                (1, speed: 8, alt: 10, power: nil, cadence: 90),
                (2, speed: 10, alt: 10, power: nil, cadence: 90),
                (3, speed: 10, alt: 10, power: nil, cadence: 90)
            ]
        )
        let params = VirtualPowerPhysics.Params(
            totalMassKg: 71.5,
            cda: 0.3,
            crr: 0.005,
            drivetrainLossPercent: 2,
            airDensity: 1.225
        )
        let withInertia = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            settings: params,
            includeInertia: true,
            weatherProvider: { _, _, _, _ in [] }
        )
        let withoutInertia = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            settings: params,
            includeInertia: false,
            weatherProvider: { _, _, _, _ in [] }
        )
        let powered: ([RecordMesg]) -> [UInt16] = { records in
            records.compactMap { $0.getPower() }
        }
        let onRecords = try FitMerger.decode(withInertia.data).recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        let offRecords = try FitMerger.decode(withoutInertia.data).recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        let onPowers = powered(onRecords)
        let offPowers = powered(offRecords)
        XCTAssertEqual(onPowers.count, offPowers.count)
        let onSum = onPowers.reduce(0, +)
        let offSum = offPowers.reduce(0, +)
        XCTAssertGreaterThan(onSum, offSum, "开惯性总功率应高于关惯性")
        XCTAssertLessThanOrEqual(offPowers[1], onPowers[1])
        XCTAssertLessThanOrEqual(offPowers[2], onPowers[2])
    }

    /// 无踏频时停车低速应记 0W 成功，不因停驶段抬高失败率导致整条放弃。
    func testNilCadenceStoppedSecondsAreVirtualZeroNotFailures() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        // 10 秒停车 + 1 秒骑行：若把低速当失败，失败率会 ≥10/11 而整条放弃。
        var specs: [(offset: Double, speed: Double?, alt: Double, power: UInt16?, cadence: UInt8?)] = []
        for i in 0..<10 {
            specs.append((Double(i), speed: 0, alt: 10, power: nil, cadence: nil))
        }
        specs.append((10, speed: 8, alt: 10, power: nil, cadence: nil))
        let fit = try makeFit(start: start, records: specs)
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertFalse(result.activityRejected)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.filledCount, 11)
        XCTAssertEqual(result.virtualMarkedCount, 11)
        let records = try FitMerger.decode(result.data).recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        XCTAssertEqual(records[0].getPower(), 0)
        XCTAssertEqual(
            VirtualPowerSourceMark.powerSource(of: records[0]),
            VirtualPowerSourceMark.virtualValue
        )
        XCTAssertNotNil(records[10].getPower())
        XCTAssertGreaterThan(records[10].getPower() ?? 0, 0)
    }

    /// 非骑行运动应整文件跳过。
    func testSkipsNonCyclingSport() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let fit = try makeFit(
            start: start,
            sport: .running,
            records: [(0, speed: 8, alt: 10, power: nil, cadence: 80)]
        )
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            weatherProvider: { _, _, _, _ in
                XCTFail("非骑行不应请求天气")
                return []
            }
        )
        XCTAssertEqual(result.filledCount, 0)
        XCTAssertEqual(result.data, fit)
        XCTAssertTrue(result.note.contains("非骑行"))
    }

    /// 仅有 enhanced_altitude 时也应能估算坡度相关功率（不因缺 altitude 失败）。
    func testUsesEnhancedAltitudeFallback() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let startFit = DateTime(date: start)
        let fileId = FileIdMesg()
        try fileId.setType(File.activity)
        try fileId.setManufacturer(Manufacturer.development)
        try fileId.setProduct(1)
        try fileId.setTimeCreated(startFit)
        try fileId.setSerialNumber(1)
        let encoder = Encoder()
        encoder.write(mesg: fileId)
        let semicircles = 2_147_483_648.0 / 180.0
        for i in 0..<3 {
            let record = RecordMesg()
            try record.setTimestamp(DateTime(date: start.addingTimeInterval(Double(i))))
            try record.setSpeed(8)
            try record.setEnhancedAltitude(10 + Double(i))
            try record.setCadence(80)
            try record.setPositionLat(Int32((31.2 * semicircles).rounded()))
            try record.setPositionLong(Int32((121.5 * semicircles).rounded()))
            try record.setDistance(8 * Double(i))
            encoder.write(mesg: record)
        }
        let session = SessionMesg()
        try session.setTimestamp(DateTime(date: start.addingTimeInterval(2)))
        try session.setStartTime(startFit)
        try session.setTotalElapsedTime(2)
        try session.setTotalTimerTime(2)
        try session.setSport(.cycling)
        encoder.write(mesg: session)
        let fit = encoder.close()

        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertEqual(result.filledCount, 3)
        XCTAssertFalse(result.activityRejected)
    }

    /// 平路海拔不变时，原生 Record.grade 仍应抬高该秒功率（不能只靠海拔差分）。
    func testPrefersNativeRecordGradeOverAltitudeDelta() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let startFit = DateTime(date: start)
        let fileId = FileIdMesg()
        try fileId.setType(File.activity)
        try fileId.setManufacturer(Manufacturer.development)
        try fileId.setProduct(1)
        try fileId.setTimeCreated(startFit)
        try fileId.setSerialNumber(1)
        let encoder = Encoder()
        encoder.write(mesg: fileId)
        let semicircles = 2_147_483_648.0 / 180.0
        for i in 0..<3 {
            let record = RecordMesg()
            try record.setTimestamp(DateTime(date: start.addingTimeInterval(Double(i))))
            try record.setSpeed(8)
            try record.setAltitude(10)
            try record.setCadence(80)
            try record.setPositionLat(Int32((31.2 * semicircles).rounded()))
            try record.setPositionLong(Int32((121.5 * semicircles).rounded()))
            try record.setDistance(8 * Double(i))
            if i >= 1 {
                try record.setGrade(8)
            }
            encoder.write(mesg: record)
        }
        let session = SessionMesg()
        try session.setTimestamp(DateTime(date: start.addingTimeInterval(2)))
        try session.setStartTime(startFit)
        try session.setTotalElapsedTime(2)
        try session.setTotalTimerTime(2)
        try session.setSport(.cycling)
        encoder.write(mesg: session)
        let fit = encoder.close()

        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertEqual(result.filledCount, 3)
        let records = try FitMerger.decode(result.data).recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        let p0 = try XCTUnwrap(records[0].getPower())
        let p2 = try XCTUnwrap(records[2].getPower())
        XCTAssertGreaterThan(p2, p0 + 100, "第 2 秒有原生 8% 坡度，功率应明显高于平路第 0 秒")
    }

    /// 长轨迹应按距离抽出多个天气锚点（而不只是起点）。
    func testWeatherAnchorsSampleAlongRoute() throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let semicircles = 2_147_483_648.0 / 180.0
        // 约每秒向北移动 ~0.001° ≈ 111 m，200 秒约 22 km → 应有多个锚点。
        let fileId = FileIdMesg()
        try fileId.setType(File.activity)
        try fileId.setManufacturer(Manufacturer.development)
        try fileId.setProduct(1)
        try fileId.setTimeCreated(DateTime(date: start))
        try fileId.setSerialNumber(1)
        let encoder = Encoder()
        encoder.write(mesg: fileId)
        var records: [RecordMesg] = []
        for i in 0..<200 {
            let record = RecordMesg()
            try record.setTimestamp(DateTime(date: start.addingTimeInterval(Double(i))))
            let lat = 31.0 + Double(i) * 0.001
            try record.setPositionLat(Int32((lat * semicircles).rounded()))
            try record.setPositionLong(Int32((121.5 * semicircles).rounded()))
            try record.setSpeed(10)
            encoder.write(mesg: record)
            records.append(record)
        }
        _ = encoder.close()
        let anchors = FitVirtualPowerFiller.weatherAnchorCoordinates(from: records)
        XCTAssertGreaterThanOrEqual(anchors.count, 3)
        XCTAssertLessThanOrEqual(anchors.count, 12)
    }

    /// ±5s 不够时继续扩大邻域，用更远的成功秒均值回填（仍标 failed）。
    func testExpandsNeighborWindowBeyondFiveSeconds() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        // 10 秒成功 + 1 秒孤立失败（距最近成功 11s）→ ±5s 不够，扩大后应能补上。
        var specs: [(offset: Double, speed: Double?, alt: Double, power: UInt16?, cadence: UInt8?)] = []
        for i in 0..<10 {
            specs.append((Double(i), speed: 8, alt: 10, power: 150, cadence: 90))
        }
        specs.append((20, speed: nil, alt: 10, power: 999, cadence: 90))
        let fit = try makeFit(start: start, records: specs, lapAvgPower: 500, lapMaxPower: 999)
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertFalse(result.activityRejected)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.filledCount, 11, "扩大邻域后孤立失败秒也应写入功率")

        let messages = try FitMerger.decode(result.data)
        let records = messages.recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        XCTAssertEqual(records.count, 11)
        let filledFail = try XCTUnwrap(records[10].getPower())
        XCTAssertNotEqual(filledFail, 999, "不得保留功率计残留值")
        // 半径扩到 15s 时，落入窗的是 offset 5…9 的成功秒。
        let neighborPowers = records[5...9].compactMap { $0.getPower() }.map { Double($0) }
        XCTAssertEqual(neighborPowers.count, 5)
        let expected = UInt16((neighborPowers.reduce(0, +) / Double(neighborPowers.count)).rounded())
        XCTAssertEqual(filledFail, expected)
        XCTAssertEqual(
            VirtualPowerSourceMark.powerSource(of: records[10]),
            VirtualPowerSourceMark.failedValue
        )

        let lap = try XCTUnwrap(messages.lapMesgs.first)
        let lapMax = try XCTUnwrap(lap.getMaxPower())
        XCTAssertNotEqual(lapMax, 999, "Lap 峰功率不得保留残留功率计峰值")
        XCTAssertLessThan(lapMax, 999)
    }

    /// 失败秒无时间戳时邻域无法定位：须清除残留功率计值并标 failed（失败率 <10%）。
    func testClearsResidualPowerWhenFailedSecondHasNoTimestamp() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let fit = try makeFitWithTimestamplessFailedRecord(
            start: start,
            successCount: 10,
            residualPower: 999
        )
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertFalse(result.activityRejected)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.filledCount, 10)

        let messages = try FitMerger.decode(result.data)
        let failedRecords = messages.recordMesgs.filter {
            VirtualPowerSourceMark.powerSource(of: $0) == VirtualPowerSourceMark.failedValue
        }
        XCTAssertEqual(failedRecords.count, 1)
        XCTAssertNil(failedRecords[0].getPower(), "无时间戳失败秒应清除残留功率")
        XCTAssertNil(failedRecords[0].getTimestamp())

        let virtualRecords = messages.recordMesgs.filter {
            VirtualPowerSourceMark.powerSource(of: $0) == VirtualPowerSourceMark.virtualValue
        }
        XCTAssertEqual(virtualRecords.count, 10)
        XCTAssertFalse(messages.recordMesgs.contains { $0.getPower() == 999 })
    }

    /// 相邻失败秒不得互相污染；邻域均值也不得吃功率计残留值。
    func testNeighborAverageIgnoresAdjacentFailedSecondsAndMeterResidue() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        // 19 成功 + 2 相邻失败 → 失败率 ≈9.5% <10%；两失败带残留 888/999。
        var specs: [(offset: Double, speed: Double?, alt: Double, power: UInt16?, cadence: UInt8?)] = []
        for i in 0..<19 {
            specs.append((Double(i), speed: 8, alt: 10, power: nil, cadence: 90))
        }
        specs.append((19, speed: nil, alt: 10, power: 888, cadence: 90))
        specs.append((20, speed: nil, alt: 10, power: 999, cadence: 90))
        let fit = try makeFit(start: start, records: specs)
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertFalse(result.activityRejected)
        XCTAssertEqual(result.failedCount, 2)
        XCTAssertEqual(result.filledCount, 21)

        let records = try FitMerger.decode(result.data).recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        let p19 = try XCTUnwrap(records[19].getPower())
        let p20 = try XCTUnwrap(records[20].getPower())
        XCTAssertNotEqual(p19, 888)
        XCTAssertNotEqual(p19, 999)
        XCTAssertNotEqual(p20, 888)
        XCTAssertNotEqual(p20, 999)

        // ±5s 内成功秒：offset 14…18；相邻失败秒被 estimateFailed 排除。
        let neighborsFor19 = records[14...18].compactMap { $0.getPower() }.map { Double($0) }
        XCTAssertEqual(neighborsFor19.count, 5)
        let expected19 = UInt16((neighborsFor19.reduce(0, +) / Double(neighborsFor19.count)).rounded())
        XCTAssertEqual(p19, expected19, "不得纳入相邻失败秒或功率计残留")

        // t=20 的 ±5s 成功秒：15…18（19 为失败已跳过，即便已有草稿）。
        let neighborsFor20 = records[15...18].compactMap { $0.getPower() }.map { Double($0) }
        XCTAssertEqual(neighborsFor20.count, 4)
        let expected20 = UInt16((neighborsFor20.reduce(0, +) / Double(neighborsFor20.count)).rounded())
        XCTAssertEqual(p20, expected20)

        XCTAssertEqual(
            VirtualPowerSourceMark.powerSource(of: records[19]),
            VirtualPowerSourceMark.failedValue
        )
        XCTAssertEqual(
            VirtualPowerSourceMark.powerSource(of: records[20]),
            VirtualPowerSourceMark.failedValue
        )
    }

    /// 任一 session 为骑行时整文件处理（含跑步+骑行多运动）。
    func testProcessesWhenAnySessionIsCycling() async throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let fit = try makeMultiSportFit(
            start: start,
            sports: [.running, .cycling],
            records: [(0, speed: 8, alt: 10, power: nil, cadence: 80)]
        )
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertEqual(result.filledCount, 1)
        XCTAssertFalse(result.note.contains("非骑行"))
    }

    private func makeFit(
        start: Date,
        sport: Sport = .cycling,
        records: [(offset: Double, speed: Double?, alt: Double, power: UInt16?, cadence: UInt8?)],
        lapAvgPower: UInt16? = nil,
        lapMaxPower: UInt16? = nil
    ) throws -> Data {
        let startFit = DateTime(date: start)
        let fileId = FileIdMesg()
        try fileId.setType(File.activity)
        try fileId.setManufacturer(Manufacturer.development)
        try fileId.setProduct(1)
        try fileId.setTimeCreated(startFit)
        try fileId.setSerialNumber(1)

        let encoder = Encoder()
        encoder.write(mesg: fileId)
        let semicircles = 2_147_483_648.0 / 180.0
        let endOffset = records.last?.offset ?? 0
        for spec in records {
            let record = RecordMesg()
            try record.setTimestamp(DateTime(date: start.addingTimeInterval(spec.offset)))
            if let speed = spec.speed {
                try record.setSpeed(speed)
                try record.setDistance(speed * spec.offset)
            } else {
                try record.setDistance(0)
            }
            try record.setAltitude(spec.alt)
            if let cadence = spec.cadence {
                try record.setCadence(cadence)
            }
            try record.setPositionLat(Int32((31.2 * semicircles).rounded()))
            try record.setPositionLong(Int32((121.5 * semicircles).rounded()))
            if let power = spec.power {
                try record.setPower(power)
            }
            encoder.write(mesg: record)
        }
        let lap = LapMesg()
        try lap.setStartTime(startFit)
        try lap.setTimestamp(DateTime(date: start.addingTimeInterval(endOffset)))
        try lap.setTotalElapsedTime(endOffset)
        try lap.setTotalTimerTime(endOffset)
        if let lapAvgPower {
            try lap.setAvgPower(lapAvgPower)
        }
        if let lapMaxPower {
            try lap.setMaxPower(lapMaxPower)
        }
        encoder.write(mesg: lap)
        let session = SessionMesg()
        try session.setTimestamp(DateTime(date: start.addingTimeInterval(endOffset)))
        try session.setStartTime(startFit)
        try session.setTotalElapsedTime(endOffset)
        try session.setTotalTimerTime(endOffset)
        try session.setSport(sport)
        encoder.write(mesg: session)
        return encoder.close()
    }

    /// 构造：若干带时间戳的成功秒 + 1 条无时间戳、无速度、带残留功率的失败秒。
    private func makeFitWithTimestamplessFailedRecord(
        start: Date,
        successCount: Int,
        residualPower: UInt16
    ) throws -> Data {
        let startFit = DateTime(date: start)
        let fileId = FileIdMesg()
        try fileId.setType(File.activity)
        try fileId.setManufacturer(Manufacturer.development)
        try fileId.setProduct(1)
        try fileId.setTimeCreated(startFit)
        try fileId.setSerialNumber(1)

        let encoder = Encoder()
        encoder.write(mesg: fileId)
        let semicircles = 2_147_483_648.0 / 180.0
        let endOffset = Double(max(successCount - 1, 0))
        for i in 0..<successCount {
            let record = RecordMesg()
            try record.setTimestamp(DateTime(date: start.addingTimeInterval(Double(i))))
            try record.setSpeed(8)
            try record.setDistance(8 * Double(i))
            try record.setAltitude(10)
            try record.setCadence(90)
            try record.setPositionLat(Int32((31.2 * semicircles).rounded()))
            try record.setPositionLong(Int32((121.5 * semicircles).rounded()))
            encoder.write(mesg: record)
        }
        // 无 timestamp、无 speed：估算失败且邻域无法按时间定位。
        let failed = RecordMesg()
        try failed.setAltitude(10)
        try failed.setCadence(90)
        try failed.setPower(residualPower)
        try failed.setPositionLat(Int32((31.2 * semicircles).rounded()))
        try failed.setPositionLong(Int32((121.5 * semicircles).rounded()))
        encoder.write(mesg: failed)

        let session = SessionMesg()
        try session.setTimestamp(DateTime(date: start.addingTimeInterval(endOffset)))
        try session.setStartTime(startFit)
        try session.setTotalElapsedTime(endOffset)
        try session.setTotalTimerTime(endOffset)
        try session.setSport(.cycling)
        encoder.write(mesg: session)
        return encoder.close()
    }

    /// 写入多个 session（不同运动），用于多运动门禁回归。
    private func makeMultiSportFit(
        start: Date,
        sports: [Sport],
        records: [(offset: Double, speed: Double?, alt: Double, power: UInt16?, cadence: UInt8?)]
    ) throws -> Data {
        let startFit = DateTime(date: start)
        let fileId = FileIdMesg()
        try fileId.setType(File.activity)
        try fileId.setManufacturer(Manufacturer.development)
        try fileId.setProduct(1)
        try fileId.setTimeCreated(startFit)
        try fileId.setSerialNumber(1)

        let encoder = Encoder()
        encoder.write(mesg: fileId)
        let semicircles = 2_147_483_648.0 / 180.0
        let endOffset = records.last?.offset ?? 0
        for spec in records {
            let record = RecordMesg()
            try record.setTimestamp(DateTime(date: start.addingTimeInterval(spec.offset)))
            if let speed = spec.speed {
                try record.setSpeed(speed)
                try record.setDistance(speed * spec.offset)
            } else {
                try record.setDistance(0)
            }
            try record.setAltitude(spec.alt)
            if let cadence = spec.cadence {
                try record.setCadence(cadence)
            }
            try record.setPositionLat(Int32((31.2 * semicircles).rounded()))
            try record.setPositionLong(Int32((121.5 * semicircles).rounded()))
            if let power = spec.power {
                try record.setPower(power)
            }
            encoder.write(mesg: record)
        }
        for (index, sport) in sports.enumerated() {
            let session = SessionMesg()
            try session.setTimestamp(DateTime(date: start.addingTimeInterval(endOffset + Double(index))))
            try session.setStartTime(startFit)
            try session.setTotalElapsedTime(endOffset)
            try session.setTotalTimerTime(endOffset)
            try session.setSport(sport)
            encoder.write(mesg: session)
        }
        return encoder.close()
    }
}
