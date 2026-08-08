import XCTest
import FITSwiftSDK
@testable import HealthWorkoutExport

final class FitVirtualPowerFillerTests: XCTestCase {
    /// 已有功率的秒不得被覆盖；缺功率秒应写入原生 power。
    func testFillsOnlyNilPowerRecords() async throws {
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
        // 调用 FitVirtualPowerFiller：注入空天气，验证只补缺。
        let result = try await FitVirtualPowerFiller.fillIfNeeded(
            fit,
            settings: params,
            weatherProvider: { _, _, _, _ in [] }
        )
        XCTAssertEqual(result.filledCount, 2)
        let messages = try FitMerger.decode(result.data)
        let records = messages.recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        XCTAssertEqual(records[0].getPower(), 180, "已有功率不得覆盖")
        XCTAssertNotNil(records[1].getPower())
        XCTAssertNotEqual(records[1].getPower(), 180)
        XCTAssertEqual(records[2].getPower(), 0, "踏频 0 应填 0")
    }

    /// 文件全部已有功率时跳过重写。
    func testSkipsWhenAllPowerPresent() async throws {
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
            weatherProvider: { _, _, _, _ in
                XCTFail("不应请求天气")
                return []
            }
        )
        XCTAssertEqual(result.filledCount, 0)
        XCTAssertEqual(result.data, fit)
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

    /// 估算写入的秒应带 developer 字段 powerSource=virtual；原有功率秒不打标。
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
        XCTAssertEqual(result.filledCount, 1)
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
        let existingPowerSource = records[0].developerFields.first {
            $0.getName() == VirtualPowerSourceMark.fieldName
        }
        XCTAssertNil(existingPowerSource, "已有功率秒不应标记 virtual")

        let filledPowerSource = records[1].developerFields.first {
            $0.getName() == VirtualPowerSourceMark.fieldName
        }
        XCTAssertNotNil(filledPowerSource)
        let value = filledPowerSource?.getValue(index: 0) as? String
        XCTAssertEqual(value, VirtualPowerSourceMark.virtualValue)
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

    /// 缺功率秒失败率 ≥10% 时整条放弃，不写任何功率。
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

    private func makeFit(
        start: Date,
        sport: Sport = .cycling,
        records: [(offset: Double, speed: Double?, alt: Double, power: UInt16?, cadence: UInt8)]
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
            try record.setCadence(spec.cadence)
            try record.setPositionLat(Int32((31.2 * semicircles).rounded()))
            try record.setPositionLong(Int32((121.5 * semicircles).rounded()))
            if let power = spec.power {
                try record.setPower(power)
            }
            encoder.write(mesg: record)
        }
        let session = SessionMesg()
        try session.setTimestamp(DateTime(date: start.addingTimeInterval(records.last?.offset ?? 0)))
        try session.setStartTime(startFit)
        try session.setTotalElapsedTime(records.last?.offset ?? 1)
        try session.setTotalTimerTime(records.last?.offset ?? 1)
        try session.setSport(sport)
        encoder.write(mesg: session)
        return encoder.close()
    }
}
