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

    private func makeFit(
        start: Date,
        records: [(offset: Double, speed: Double, alt: Double, power: UInt16?, cadence: UInt8)]
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
            try record.setSpeed(spec.speed)
            try record.setAltitude(spec.alt)
            try record.setCadence(spec.cadence)
            try record.setPositionLat(Int32((31.2 * semicircles).rounded()))
            try record.setPositionLong(Int32((121.5 * semicircles).rounded()))
            try record.setDistance(spec.speed * spec.offset)
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
        try session.setSport(.cycling)
        encoder.write(mesg: session)
        return encoder.close()
    }
}
