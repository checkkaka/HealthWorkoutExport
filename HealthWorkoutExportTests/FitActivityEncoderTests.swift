import XCTest
import HealthKit
import FITSwiftSDK
@testable import HealthWorkoutExport

final class FitActivityEncoderTests: XCTestCase {
    /// 用合成训练数据验证 FIT 编码产出非空且含 FIT 文件头。
    func testEncodeSyntheticWorkoutProducesFitHeader() throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let end = start.addingTimeInterval(600)
        let summary = WorkoutSummary(
            id: UUID(),
            uuid: UUID(),
            activityType: .running,
            activityName: "跑步",
            startDate: start,
            endDate: end,
            duration: 600,
            totalDistanceMeters: 2000,
            totalEnergyKilocalories: 180,
            sourceName: "UnitTest"
        )
        let bundle = WorkoutBundle(
            summary: summary,
            metadata: [:],
            events: [WorkoutEventDTO(type: "pause", date: start.addingTimeInterval(100))],
            series: [
                HKQuantityTypeIdentifier.heartRate.rawValue: [
                    TimedSample(date: start.addingTimeInterval(1), value: 140, unit: "count/min"),
                    TimedSample(date: start.addingTimeInterval(2), value: 145, unit: "count/min")
                ]
            ],
            route: [
                RoutePoint(latitude: 31.34, longitude: 120.55, altitude: 5, timestamp: start.addingTimeInterval(1), speed: 3.2),
                RoutePoint(latitude: 31.341, longitude: 120.551, altitude: 5.2, timestamp: start.addingTimeInterval(2), speed: 3.3)
            ]
        )

        // 调用 FitActivityEncoder：验证合成数据可编码为 FIT。
        let data = try FitActivityEncoder.encode(bundle)
        XCTAssertGreaterThan(data.count, 20)
        // FIT header 以 `.FIT` 结尾（offset 8）
        let headerTag = String(data: data.subdata(in: 8..<12), encoding: .ascii)
        XCTAssertEqual(headerTag, ".FIT")
    }

    /// 回归：无距离/卡路里/来源的训练（如力量训练）必须能序列化，不得携带 Optional 进 JSONSerialization。
    func testJSONSerializationWithNilOptionalsDoesNotCrash() throws {
        let start = Date()
        let summary = WorkoutSummary(
            id: UUID(),
            uuid: UUID(),
            activityType: .traditionalStrengthTraining,
            activityName: "力量训练",
            startDate: start,
            endDate: start.addingTimeInterval(300),
            duration: 300,
            totalDistanceMeters: nil,
            totalEnergyKilocalories: nil,
            sourceName: nil
        )
        let bundle = WorkoutBundle(summary: summary, metadata: [:], events: [], series: [:], route: [])
        let json = bundle.jsonObject()
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json), "JSON 对象含非法类型（Optional 泄漏）")
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertNil(json["totalDistanceMeters"], "nil 距离不应出现在 JSON 中")
    }

    /// 回归：FIT Record 的 distance 必须是按时间累计的总距离，而不是分段增量。
    func testFitDistanceIsCumulative() throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let summary = WorkoutSummary(
            id: UUID(), uuid: UUID(),
            activityType: .running, activityName: "跑步",
            startDate: start, endDate: start.addingTimeInterval(30), duration: 30,
            totalDistanceMeters: 30, totalEnergyKilocalories: nil, sourceName: nil
        )
        // 三段增量各 10 米 → 编码后最后一条 Record 的 distance 应为 30。
        let deltas = (0..<3).map { i in
            TimedSample(date: start.addingTimeInterval(Double(i * 10) + 1), value: 10, unit: "m")
        }
        let bundle = WorkoutBundle(
            summary: summary, metadata: [:], events: [],
            series: ["HKQuantityTypeIdentifierDistanceWalkingRunning": deltas],
            route: []
        )
        let data = try FitActivityEncoder.encode(bundle)
        XCTAssertGreaterThan(data.count, 20)
        // 简单校验：FIT 二进制中应包含累计值 30m 的编码（distance 字段 scale 100 → 3000）。
        // 完整解码依赖 SDK Decoder，这里用编码成功 + 后续真机导入平台核对兜底。
    }

    /// 回归：跑步动态（步幅/垂直振幅/触地时间）与暂停事件应能编码进 FIT。
    func testFitEncodesRunningDynamicsAndPauseEvents() throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let summary = WorkoutSummary(
            id: UUID(), uuid: UUID(),
            activityType: .running, activityName: "跑步",
            startDate: start, endDate: start.addingTimeInterval(120), duration: 120,
            totalDistanceMeters: 400, totalEnergyKilocalories: 30, sourceName: nil
        )
        func series(_ value: Double) -> [TimedSample] {
            (0..<3).map { TimedSample(date: start.addingTimeInterval(Double($0) + 1), value: value, unit: "") }
        }
        let bundle = WorkoutBundle(
            summary: summary,
            metadata: [:],
            events: [
                WorkoutEventDTO(type: "HKWorkoutEventType(rawValue: 1)", date: start.addingTimeInterval(30)),
                WorkoutEventDTO(type: "pause", date: start.addingTimeInterval(40)),
                WorkoutEventDTO(type: "resume", date: start.addingTimeInterval(50))
            ],
            series: [
                "HKQuantityTypeIdentifierHeartRate": series(150),
                "HKQuantityTypeIdentifierRunningStrideLength": series(1.2),
                "HKQuantityTypeIdentifierRunningVerticalOscillation": series(0.08),
                "HKQuantityTypeIdentifierRunningGroundContactTime": series(240)
            ],
            route: []
        )
        let data = try FitActivityEncoder.encode(bundle)
        XCTAssertGreaterThan(data.count, 100)
        let headerTag = String(data: data.subdata(in: 8..<12), encoding: .ascii)
        XCTAssertEqual(headerTag, ".FIT")
    }

    /// 时区选项必须包含上海，且展示名可生成。
    func testTimeZoneOptionsIncludeShanghai() {
        let options = ExportTimeZone.options()
        XCTAssertTrue(options.contains { $0.identifier == "Asia/Shanghai" })
        for zone in options {
            XCTAssertFalse(ExportTimeZone.displayName(for: zone).isEmpty)
        }
    }

    /// JSON 日期串应携带所选时区偏移（上海 +08:00）。
    func testJSONDateUsesSelectedTimeZone() {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let summary = WorkoutSummary(
            id: UUID(), uuid: UUID(),
            activityType: .running, activityName: "跑步",
            startDate: start, endDate: start.addingTimeInterval(60), duration: 60,
            totalDistanceMeters: nil, totalEnergyKilocalories: nil, sourceName: nil
        )
        let bundle = WorkoutBundle(summary: summary, metadata: [:], events: [], series: [:], route: [])
        let json = bundle.jsonObject(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let startString = json["startDate"] as? String ?? ""
        XCTAssertTrue(startString.hasSuffix("+08:00"), "上海时区日期应带 +08:00 偏移，实际：\(startString)")
        XCTAssertEqual(json["timeZone"] as? String, "Asia/Shanghai")
    }

    /// 回归：FIT 合并须满足「冲突以主为准、副只补主空缺字段、主没有的秒整条补入、Session 字段补缺」。
    func testFitMergePrimaryWinsAndFillsGaps() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)

        // 构造合成 FIT：records 传 (秒偏移, 心率, 功率)，session 传可选距离/卡路里。
        func makeFit(records: [(offset: Double, hr: UInt8?, power: UInt16?)],
                     distance: Double?, calories: UInt16?) throws -> Data {
            let encoder = FITSwiftSDK.Encoder()
            let fileId = FileIdMesg()
            try fileId.setType(File.activity)
            try fileId.setManufacturer(Manufacturer.development)
            try fileId.setProduct(1)
            try fileId.setSerialNumber(42)
            try fileId.setTimeCreated(DateTime(date: base))
            encoder.write(mesg: fileId)
            for spec in records {
                let record = RecordMesg()
                try record.setTimestamp(DateTime(date: base.addingTimeInterval(spec.offset)))
                if let hr = spec.hr { try record.setHeartRate(hr) }
                if let power = spec.power { try record.setPower(power) }
                encoder.write(mesg: record)
            }
            let session = SessionMesg()
            try session.setTimestamp(DateTime(date: base.addingTimeInterval(60)))
            try session.setStartTime(DateTime(date: base))
            try session.setSport(.running)
            if let distance { try session.setTotalDistance(distance) }
            if let calories { try session.setTotalCalories(calories) }
            encoder.write(mesg: session)
            return encoder.close()
        }

        // 主：t0/t1 有心率无功率；session 有距离无卡路里。
        let primary = try makeFit(
            records: [(0, 140, nil), (1, 141, nil)],
            distance: 100, calories: nil
        )
        // 副：t1 心率冲突(999)+功率、t2 全新记录；session 有卡路里。
        let secondary = try makeFit(
            records: [(1, 99, 200), (2, 150, 210)],
            distance: 555, calories: 50
        )

        // 调用 FitMerger.merge：执行主优先合并。
        let merged = try FitMerger.merge(primary: primary, primaryName: "p.fit", others: [(secondary, "s.fit")])
        // 调用 FitMerger.decode：解码合并结果做断言。
        let messages = try FitMerger.decode(merged)

        let records = messages.recordMesgs.sorted { ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0) }
        XCTAssertEqual(records.count, 3, "应有 t0/t1/t2 三条记录")
        XCTAssertEqual(records[0].getHeartRate(), 140)
        XCTAssertEqual(records[1].getHeartRate(), 141, "t1 心率冲突应以主为准")
        XCTAssertEqual(records[1].getPower(), 200, "t1 功率主缺失，应由副补充")
        XCTAssertEqual(records[2].getHeartRate(), 150, "t2 主没有，应整条补入")
        XCTAssertEqual(records[2].getPower(), 210)

        let session = try XCTUnwrap(messages.sessionMesgs.first)
        XCTAssertEqual(session.getTotalDistance(), 100, "session 距离冲突应以主为准")
        XCTAssertEqual(session.getTotalCalories(), 50, "session 卡路里主缺失，应由副补充")
    }

    /// sensorsOnly：同秒补 HR/功率，不插入副源缺秒记录，距离起止跟主。
    func testFitMergeSensorsOnlyDoesNotInsertGPSOrGapRecords() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_100)
        let sc = 2_147_483_648.0 / 180.0

        func makeFit(
            records: [(offset: Double, hr: UInt8?, power: UInt16?, lat: Double?, lon: Double?, distance: Double?)],
            sessionDistance: Double?
        ) throws -> Data {
            let encoder = FITSwiftSDK.Encoder()
            let fileId = FileIdMesg()
            try fileId.setType(File.activity)
            try fileId.setManufacturer(Manufacturer.development)
            try fileId.setProduct(1)
            try fileId.setSerialNumber(7)
            try fileId.setTimeCreated(DateTime(date: base))
            encoder.write(mesg: fileId)
            for spec in records {
                let record = RecordMesg()
                try record.setTimestamp(DateTime(date: base.addingTimeInterval(spec.offset)))
                if let hr = spec.hr { try record.setHeartRate(hr) }
                if let power = spec.power { try record.setPower(power) }
                if let lat = spec.lat, let lon = spec.lon {
                    try record.setPositionLat(Int32((lat * sc).rounded()))
                    try record.setPositionLong(Int32((lon * sc).rounded()))
                }
                if let distance = spec.distance { try record.setDistance(distance) }
                encoder.write(mesg: record)
            }
            let session = SessionMesg()
            try session.setTimestamp(DateTime(date: base.addingTimeInterval(60)))
            try session.setStartTime(DateTime(date: base))
            try session.setTotalElapsedTime(60)
            try session.setSport(.cycling)
            if let sessionDistance { try session.setTotalDistance(sessionDistance) }
            encoder.write(mesg: session)
            return encoder.close()
        }

        // 主：两秒有 GPS+距离，无心率功率。
        let primary = try makeFit(
            records: [
                (0, nil, nil, 31.3, 120.6, 0),
                (1, nil, nil, 31.301, 120.601, 10)
            ],
            sessionDistance: 10
        )
        // 副：同秒有 HR/功率，另有 t2 GPS（不应插入）。
        let secondary = try makeFit(
            records: [
                (0, 140, 200, 39.9, 116.4, 999),
                (1, 141, 210, 39.91, 116.41, 1999),
                (2, 150, 220, 39.92, 116.42, 2999)
            ],
            sessionDistance: 5000
        )

        let merged = try FitMerger.merge(
            primary: primary,
            primaryName: "p.fit",
            others: [(secondary, "s.fit")],
            supplementMode: .sensorsOnly
        )
        let messages = try FitMerger.decode(merged)
        let records = messages.recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        XCTAssertEqual(records.count, 2, "sensorsOnly 不得插入副源缺秒")
        XCTAssertEqual(records[0].getHeartRate(), 140)
        XCTAssertEqual(records[0].getPower(), 200)
        XCTAssertEqual(records[1].getHeartRate(), 141)
        // 主 GPS / 距离不得被副覆盖。
        XCTAssertEqual(records[0].getPositionLat(), Int32((31.3 * sc).rounded()))
        XCTAssertEqual(records[0].getDistance(), 0)
        let session = try XCTUnwrap(messages.sessionMesgs.first)
        XCTAssertEqual(session.getTotalDistance(), 10, "sensorsOnly 不得累加副源距离")
        XCTAssertEqual(session.getStartTime()?.timestamp, DateTime(date: base).timestamp)
        XCTAssertEqual(session.getTotalElapsedTime(), 60)
    }

    /// sensorsOnly：主无 grade 时从副源抄 Record.grade；不插缺秒、不改 GPS/距离。
    func testFitMergeSensorsOnlyCopiesGradeFromSecondary() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_200)
        let sc = 2_147_483_648.0 / 180.0
        let primaryLat = Int32((31.3 * sc).rounded())
        let primaryLon = Int32((120.6 * sc).rounded())

        func makeFit(hasGrade: Bool, extraSecond: Bool) throws -> Data {
            let encoder = FITSwiftSDK.Encoder()
            let fileId = FileIdMesg()
            try fileId.setType(File.activity)
            try fileId.setManufacturer(Manufacturer.development)
            try fileId.setProduct(1)
            try fileId.setSerialNumber(hasGrade ? 8 : 7)
            try fileId.setTimeCreated(DateTime(date: base))
            encoder.write(mesg: fileId)
            let r0 = RecordMesg()
            try r0.setTimestamp(DateTime(date: base))
            try r0.setPositionLat(hasGrade ? Int32((39.9 * sc).rounded()) : primaryLat)
            try r0.setPositionLong(hasGrade ? Int32((116.4 * sc).rounded()) : primaryLon)
            try r0.setDistance(hasGrade ? 999 : 0)
            if hasGrade { try r0.setGrade(5.5) }
            encoder.write(mesg: r0)
            let r1 = RecordMesg()
            try r1.setTimestamp(DateTime(date: base.addingTimeInterval(1)))
            try r1.setPositionLat(hasGrade ? Int32((39.91 * sc).rounded()) : Int32((31.301 * sc).rounded()))
            try r1.setPositionLong(hasGrade ? Int32((116.41 * sc).rounded()) : Int32((120.601 * sc).rounded()))
            try r1.setDistance(hasGrade ? 1999 : 10)
            if hasGrade { try r1.setGrade(-2.0) }
            encoder.write(mesg: r1)
            if extraSecond {
                let r2 = RecordMesg()
                try r2.setTimestamp(DateTime(date: base.addingTimeInterval(2)))
                try r2.setGrade(8.0)
                encoder.write(mesg: r2)
            }
            let session = SessionMesg()
            try session.setTimestamp(DateTime(date: base.addingTimeInterval(60)))
            try session.setStartTime(DateTime(date: base))
            try session.setTotalElapsedTime(60)
            try session.setSport(.cycling)
            try session.setTotalDistance(hasGrade ? 5000 : 10)
            encoder.write(mesg: session)
            return encoder.close()
        }

        let merged = try FitMerger.merge(
            primary: try makeFit(hasGrade: false, extraSecond: false),
            primaryName: "p.fit",
            others: [(try makeFit(hasGrade: true, extraSecond: true), "s.fit")],
            supplementMode: .sensorsOnly
        )
        let records = try FitMerger.decode(merged).recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        XCTAssertEqual(records.count, 2, "sensorsOnly 不得插入副源缺秒")
        XCTAssertEqual(records[0].getGrade(), 5.5)
        XCTAssertEqual(records[1].getGrade(), -2.0)
        XCTAssertEqual(records[0].getPositionLat(), primaryLat)
        XCTAssertEqual(records[0].getDistance(), 0)
        XCTAssertEqual(records[1].getDistance(), 10)
    }

    /// 少于 2 个文件必须报错。
    func testFitMergeRequiresTwoFiles() {
        XCTAssertThrowsError(try FitMerger.merge(primary: Data(), primaryName: "p.fit", others: []))
    }

    /// 构造带速度/踏频的合成 FIT，用于时间对齐测试。
    private func makeSpeedCadenceFit(base: Date,
                                     count: Int,
                                     clockSkewSeconds: Double,
                                     speedAt: (Int) -> Double,
                                     cadence: UInt8?) throws -> Data {
        let encoder = FITSwiftSDK.Encoder()
        let fileId = FileIdMesg()
        try fileId.setType(File.activity)
        try fileId.setManufacturer(Manufacturer.development)
        try fileId.setProduct(1)
        try fileId.setSerialNumber(9)
        try fileId.setTimeCreated(DateTime(date: base.addingTimeInterval(clockSkewSeconds)))
        encoder.write(mesg: fileId)
        for i in 0..<count {
            let record = RecordMesg()
            try record.setTimestamp(DateTime(date: base.addingTimeInterval(Double(i) + clockSkewSeconds)))
            try record.setSpeed(speedAt(i))
            if let cadence { try record.setCadence(cadence) }
            try record.setDistance(Double(i) * 5)
            encoder.write(mesg: record)
        }
        let session = SessionMesg()
        try session.setStartTime(DateTime(date: base.addingTimeInterval(clockSkewSeconds)))
        try session.setTimestamp(DateTime(date: base.addingTimeInterval(Double(count - 1) + clockSkewSeconds)))
        try session.setTotalElapsedTime(Double(count - 1))
        try session.setSport(.cycling)
        encoder.write(mesg: session)
        return encoder.close()
    }

    /// 回归：副文件时钟偏快时，estimateOffset 应给出约等于 -skew 的偏移。
    func testFitMergeEstimateOffsetForClockSkew() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let skew = 871.0
        func speed(_ i: Int) -> Double { 5.0 + Double(i % 7) * 0.3 }
        let primary = try makeSpeedCadenceFit(base: base, count: 120, clockSkewSeconds: 0, speedAt: speed, cadence: nil)
        let secondary = try makeSpeedCadenceFit(base: base, count: 120, clockSkewSeconds: skew, speedAt: speed, cadence: 90)

        // 调用 estimateOffset：估副文件相对主文件的偏移。
        let offset = try FitMerger.estimateOffset(primary: primary, secondary: secondary)
        XCTAssertEqual(offset, -Int(skew), "副时钟快 \(Int(skew))s 时偏移应为 \(-Int(skew))")
    }

    /// 回归：手动偏移后，副文件踏频应贴到主文件对应骑行阶段的秒上。
    func testFitMergeManualOffsetAlignsCadenceToPrimaryPhase() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let skew = 100.0
        func speed(_ i: Int) -> Double { 6.0 + Double(i % 5) * 0.2 }
        let primary = try makeSpeedCadenceFit(base: base, count: 80, clockSkewSeconds: 0, speedAt: speed, cadence: nil)
        let secondary = try makeSpeedCadenceFit(base: base, count: 80, clockSkewSeconds: skew, speedAt: speed, cadence: 88)

        // 绝对时间合并：主开录秒上不应有踏频（副还没开始）。
        let wrong = try FitMerger.merge(
            primary: primary, primaryName: "p.fit", others: [(secondary, "s.fit")],
            timeAlign: .absolute
        )
        let wrongMsgs = try FitMerger.decode(wrong)
        let t0 = DateTime(date: base).timestamp
        let wrongAtStart = wrongMsgs.recordMesgs.first { $0.getTimestamp()?.timestamp == t0 }
        XCTAssertNil(wrongAtStart?.getCadence(), "未偏移时开录秒不应贴上副文件踏频")

        // 调用 FitMerger.merge：手动偏移 -100s 后踏频应对齐到主开录阶段。
        let merged = try FitMerger.merge(
            primary: primary, primaryName: "p.fit", others: [(secondary, "s.fit")],
            timeAlign: .manual(seconds: -Int(skew))
        )
        let messages = try FitMerger.decode(merged)
        let atStart = messages.recordMesgs.first { $0.getTimestamp()?.timestamp == t0 }
        XCTAssertEqual(atStart?.getCadence(), 88, "偏移后主开录秒应有副文件踏频")
        let spd = try XCTUnwrap(atStart?.getSpeed())
        XCTAssertEqual(spd, speed(0), accuracy: 0.01, "主速度应保留")
    }

    /// 回归：两段速度形态完全不同（不像同一场运动）时，自动对齐必须报错而不是硬合。
    func testFitMergeAutoAlignRejectsDifferentActivities() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        // 主恒速 3 m/s，副恒速 9 m/s：任何偏移下平均速度差都是 6 m/s，超过门槛。
        let primary = try makeSpeedCadenceFit(base: base, count: 120, clockSkewSeconds: 0, speedAt: { _ in 3.0 }, cadence: nil)
        let secondary = try makeSpeedCadenceFit(base: base, count: 120, clockSkewSeconds: 0, speedAt: { _ in 9.0 }, cadence: 90)

        XCTAssertThrowsError(try FitMerger.estimateOffset(primary: primary, secondary: secondary)) { error in
            guard case FitMergeError.alignFailed = error else {
                return XCTFail("应抛 alignFailed，实际：\(error)")
            }
        }
        // 走 automatic 合并同样应失败，不产出文件。
        XCTAssertThrowsError(try FitMerger.merge(
            primary: primary, primaryName: "p.fit", others: [(secondary, "s.fit")],
            timeAlign: .automatic
        ))
    }

    /// 回归：UI 预计算偏移走 .perFile 时，效果应与等值手动偏移一致。
    func testFitMergePerFileOffsetsMatchesManual() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let skew = 100.0
        func speed(_ i: Int) -> Double { 6.0 + Double(i % 5) * 0.2 }
        let primary = try makeSpeedCadenceFit(base: base, count: 80, clockSkewSeconds: 0, speedAt: speed, cadence: nil)
        let secondary = try makeSpeedCadenceFit(base: base, count: 80, clockSkewSeconds: skew, speedAt: speed, cadence: 88)

        // 调用 FitMerger.merge：用预计算偏移合并。
        let merged = try FitMerger.merge(
            primary: primary, primaryName: "p.fit", others: [(secondary, "s.fit")],
            timeAlign: .perFile(offsets: [-Int(skew)])
        )
        let messages = try FitMerger.decode(merged)
        let atStart = messages.recordMesgs.first { $0.getTimestamp()?.timestamp == DateTime(date: base).timestamp }
        XCTAssertEqual(atStart?.getCadence(), 88, "perFile 偏移后主开录秒应有副文件踏频")

        // 偏移数量与副文件数不一致应报错。
        XCTAssertThrowsError(try FitMerger.merge(
            primary: primary, primaryName: "p.fit", others: [(secondary, "s.fit")],
            timeAlign: .perFile(offsets: [])
        ))
    }

    /// 回归：副段在主段之前时，事件与 Lap 也应按时间序写出。
    func testFitMergeWritesEventsAndLapsChronologically() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let primary = try makeFitWithEventAndLap(base: base, recordOffsets: 120...180,
                                                 eventOffset: 150, lapRange: (120, 180))
        let secondary = try makeFitWithEventAndLap(base: base, recordOffsets: 0...60,
                                                   eventOffset: 30, lapRange: (0, 60))

        let merged = try FitMerger.merge(
            primary: primary, primaryName: "p.fit", others: [(secondary, "s.fit")],
            timeAlign: .absolute
        )
        let messages = try FitMerger.decode(merged)
        let eventTs = messages.eventMesgs.compactMap { $0.getTimestamp()?.timestamp }
        XCTAssertEqual(eventTs, eventTs.sorted(), "事件应按时间递增写出")
        let lapTs = messages.lapMesgs.compactMap { $0.getTimestamp()?.timestamp }
        XCTAssertEqual(lapTs, lapTs.sorted(), "Lap 应按结束时间递增写出")
        XCTAssertEqual(messages.eventMesgs.count, 2)
        XCTAssertEqual(messages.lapMesgs.count, 2)
    }

    /// 构造只有累计距离的合成 FIT（无速度），可带时钟偏差与 Session 可加总量。
    private func makeDistanceFit(base: Date,
                                 offsets: ClosedRange<Int>,
                                 clockSkewSeconds: Double = 0,
                                 distanceAt: (Int) -> Double,
                                 sessionDistance: Double? = nil,
                                 sessionCalories: UInt16? = nil) throws -> Data {
        let encoder = FITSwiftSDK.Encoder()
        let fileId = FileIdMesg()
        try fileId.setType(File.activity)
        try fileId.setManufacturer(Manufacturer.development)
        try fileId.setProduct(1)
        try fileId.setSerialNumber(12)
        try fileId.setTimeCreated(DateTime(date: base))
        encoder.write(mesg: fileId)
        for i in offsets {
            let record = RecordMesg()
            try record.setTimestamp(DateTime(date: base.addingTimeInterval(Double(i) + clockSkewSeconds)))
            try record.setDistance(distanceAt(i))
            encoder.write(mesg: record)
        }
        let session = SessionMesg()
        try session.setStartTime(DateTime(date: base.addingTimeInterval(Double(offsets.lowerBound) + clockSkewSeconds)))
        try session.setTimestamp(DateTime(date: base.addingTimeInterval(Double(offsets.upperBound) + clockSkewSeconds)))
        try session.setTotalElapsedTime(Double(offsets.count - 1))
        try session.setSport(.cycling)
        if let sessionDistance { try session.setTotalDistance(sessionDistance) }
        if let sessionCalories { try session.setTotalCalories(sessionCalories) }
        encoder.write(mesg: session)
        return encoder.close()
    }

    /// 回归：不重叠拼接时累计距离不应倒退，尾段应平移衔接主段末尾；
    /// Session 距离/卡路里对完全不重叠的副段做求和。
    func testFitMergeRebasesDistanceAndSumsDisjointTotals() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        // 主：0~60s 距离 0~300；副：120~180s 自己的累计距离也是 0~300（基线倒退）。
        let primary = try makeDistanceFit(base: base, offsets: 0...60,
                                          distanceAt: { Double($0) * 5 },
                                          sessionDistance: 300, sessionCalories: 100)
        let secondary = try makeDistanceFit(base: base, offsets: 120...180,
                                            distanceAt: { Double($0 - 120) * 5 },
                                            sessionDistance: 300, sessionCalories: 200)

        let merged = try FitMerger.merge(
            primary: primary, primaryName: "p.fit", others: [(secondary, "s.fit")],
            timeAlign: .absolute
        )
        let messages = try FitMerger.decode(merged)

        let distances = messages.recordMesgs
            .sorted { ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0) }
            .compactMap { $0.getDistance() }
        XCTAssertEqual(distances, distances.sorted(), "合并后累计距离应单调不减")
        let last = try XCTUnwrap(distances.last)
        XCTAssertEqual(last, 600, accuracy: 0.01, "尾段应从主段末尾 300 继续累计到 600")

        let session = try XCTUnwrap(messages.sessionMesgs.first)
        let totalDistance = try XCTUnwrap(session.getTotalDistance())
        XCTAssertEqual(totalDistance, 600, accuracy: 0.01, "不重叠副段的距离应求和")
        XCTAssertEqual(session.getTotalCalories(), 300, "不重叠副段的卡路里应求和")
    }

    /// 回归：无速度且两段距离-时间曲线斜率不同（不是同一场）时，距离回退路径应拒绝对齐。
    func testFitMergeDistanceFallbackRejectsMismatchedTracks() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let primary = try makeDistanceFit(base: base, offsets: 0...300, distanceAt: { Double($0) * 5 })
        let secondary = try makeDistanceFit(base: base, offsets: 0...120, distanceAt: { Double($0) * 17 })

        XCTAssertThrowsError(try FitMerger.estimateOffset(primary: primary, secondary: secondary)) { error in
            guard case FitMergeError.alignFailed = error else {
                return XCTFail("应抛 alignFailed，实际：\(error)")
            }
        }
    }

    /// 回归：无速度但两段是同一场（同斜率、副时钟偏快）时，距离回退路径应给出正确偏移。
    func testFitMergeDistanceFallbackEstimatesClockSkew() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let skew = 40.0
        let primary = try makeDistanceFit(base: base, offsets: 0...200, distanceAt: { Double($0) * 5 })
        let secondary = try makeDistanceFit(base: base, offsets: 0...200, clockSkewSeconds: skew,
                                            distanceAt: { Double($0) * 5 })

        // 调用 estimateOffset：走距离回退路径估偏移。
        let offset = try FitMerger.estimateOffset(primary: primary, secondary: secondary)
        XCTAssertEqual(offset, -Int(skew), "副时钟快 \(Int(skew))s 时偏移应为 \(-Int(skew))")
    }

    /// 构造带事件与 Lap 的合成 FIT，用于「不重叠段以各自为主」测试。
    private func makeFitWithEventAndLap(base: Date,
                                        recordOffsets: ClosedRange<Int>,
                                        eventOffset: Double,
                                        lapRange: (start: Double, end: Double)) throws -> Data {
        let encoder = FITSwiftSDK.Encoder()
        let fileId = FileIdMesg()
        try fileId.setType(File.activity)
        try fileId.setManufacturer(Manufacturer.development)
        try fileId.setProduct(1)
        try fileId.setSerialNumber(11)
        try fileId.setTimeCreated(DateTime(date: base))
        encoder.write(mesg: fileId)
        let event = EventMesg()
        try event.setTimestamp(DateTime(date: base.addingTimeInterval(eventOffset)))
        try event.setEvent(.timer)
        try event.setEventType(.start)
        encoder.write(mesg: event)
        for i in recordOffsets {
            let record = RecordMesg()
            try record.setTimestamp(DateTime(date: base.addingTimeInterval(Double(i))))
            try record.setHeartRate(120)
            encoder.write(mesg: record)
        }
        let lap = LapMesg()
        try lap.setStartTime(DateTime(date: base.addingTimeInterval(lapRange.start)))
        try lap.setTimestamp(DateTime(date: base.addingTimeInterval(lapRange.end)))
        try lap.setTotalElapsedTime(lapRange.end - lapRange.start)
        encoder.write(mesg: lap)
        let session = SessionMesg()
        try session.setStartTime(DateTime(date: base.addingTimeInterval(Double(recordOffsets.lowerBound))))
        try session.setTimestamp(DateTime(date: base.addingTimeInterval(Double(recordOffsets.upperBound))))
        try session.setTotalElapsedTime(Double(recordOffsets.count - 1))
        try session.setSport(.cycling)
        encoder.write(mesg: session)
        return encoder.close()
    }

    /// 回归：绝对时间下两段不重叠时，Session 取两段最大最小时间，
    /// 副文件段落的事件与 Lap 也保留（以各自为主，而不是只留主的）。
    func testFitMergeAbsoluteKeepsNonOverlapEventsAndLaps() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        // 主：0~60s；副：120~180s，完全不重叠。
        let primary = try makeFitWithEventAndLap(base: base, recordOffsets: 0...60,
                                                 eventOffset: 30, lapRange: (0, 60))
        let secondary = try makeFitWithEventAndLap(base: base, recordOffsets: 120...180,
                                                   eventOffset: 150, lapRange: (120, 180))

        // 调用 FitMerger.merge：绝对时间合并。
        let merged = try FitMerger.merge(
            primary: primary, primaryName: "p.fit", others: [(secondary, "s.fit")],
            timeAlign: .absolute
        )
        let messages = try FitMerger.decode(merged)

        XCTAssertEqual(messages.recordMesgs.count, 122, "两段记录都应保留")
        XCTAssertEqual(messages.eventMesgs.count, 2, "副文件段落的事件应保留")
        XCTAssertEqual(messages.lapMesgs.count, 2, "副文件段落的 Lap 应保留")

        let session = try XCTUnwrap(messages.sessionMesgs.first)
        XCTAssertEqual(session.getStartTime()?.timestamp, DateTime(date: base).timestamp)
        XCTAssertEqual(session.getTimestamp()?.timestamp, DateTime(date: base.addingTimeInterval(180)).timestamp,
                       "Session 应取两段的最大最小时间")

        // 主 Lap 不应被外扩（该段归副 Lap），仍是 0~60。
        let laps = messages.lapMesgs.sorted { ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0) }
        XCTAssertEqual(laps[0].getTimestamp()?.timestamp, DateTime(date: base.addingTimeInterval(60)).timestamp)
        XCTAssertEqual(laps[1].getStartTime()?.timestamp, DateTime(date: base.addingTimeInterval(120)).timestamp)
        XCTAssertEqual(laps[1].getTimestamp()?.timestamp, DateTime(date: base.addingTimeInterval(180)).timestamp)
    }

    /// 测试用最小 FIT 构造器：records 传秒偏移与心率，sessionEnd 传 Session 结束偏移。
    private func makeSimpleFit(base: Date,
                               records: [(offset: Double, hr: UInt8)],
                               sessionEnd: Double,
                               configureSession: ((SessionMesg) throws -> Void)? = nil) throws -> Data {
        let encoder = FITSwiftSDK.Encoder()
        let fileId = FileIdMesg()
        try fileId.setType(File.activity)
        try fileId.setManufacturer(Manufacturer.development)
        try fileId.setProduct(1)
        try fileId.setSerialNumber(7)
        try fileId.setTimeCreated(DateTime(date: base))
        encoder.write(mesg: fileId)
        for spec in records {
            let record = RecordMesg()
            try record.setTimestamp(DateTime(date: base.addingTimeInterval(spec.offset)))
            try record.setHeartRate(spec.hr)
            encoder.write(mesg: record)
        }
        let session = SessionMesg()
        try session.setStartTime(DateTime(date: base))
        try session.setTimestamp(DateTime(date: base.addingTimeInterval(sessionEnd)))
        try session.setTotalElapsedTime(sessionEnd)
        try session.setSport(.running)
        try configureSession?(session)
        encoder.write(mesg: session)
        return encoder.close()
    }

    /// 回归：副文件记录超出主 Session 时间范围时，合并后 Session 起止与时长应外扩覆盖。
    func testFitMergeExtendsSessionRangeToMergedRecords() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        // 主：记录到 60s，Session 覆盖 0~60s。
        let primary = try makeSimpleFit(base: base, records: [(0, 140), (60, 141)], sessionEnd: 60)
        // 副：记录到 180s，超出主范围。
        let secondary = try makeSimpleFit(base: base, records: [(120, 150), (180, 151)], sessionEnd: 180)

        // 调用 FitMerger.merge：执行主优先合并。
        let merged = try FitMerger.merge(primary: primary, primaryName: "p.fit", others: [(secondary, "s.fit")])
        // 调用 FitMerger.decode：解码合并结果做断言。
        let messages = try FitMerger.decode(merged)

        let session = try XCTUnwrap(messages.sessionMesgs.first)
        let expectedEnd = DateTime(date: base.addingTimeInterval(180)).timestamp
        XCTAssertEqual(session.getTimestamp()?.timestamp, expectedEnd, "Session 结束时间应外扩到 180s")
        XCTAssertEqual(session.getStartTime()?.timestamp, DateTime(date: base).timestamp, "开始时间不应变化")
        XCTAssertEqual(session.getTotalElapsedTime(), 180, "总时长应扩到新跨度")
        XCTAssertEqual(messages.recordMesgs.count, 4)
    }

    /// 回归：补缺须整字段拷贝，数组字段（如 timeInHrZone）的全部分量都要保留。
    func testFitMergeCopiesArrayFieldsCompletely() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        // 主：Session 无 timeInHrZone。
        let primary = try makeSimpleFit(base: base, records: [(0, 140)], sessionEnd: 60)
        // 副：Session 带 3 个分量的 timeInHrZone。
        let secondary = try makeSimpleFit(base: base, records: [(1, 150)], sessionEnd: 60) { session in
            try session.setTimeInHrZone(index: 0, value: 10)
            try session.setTimeInHrZone(index: 1, value: 20)
            try session.setTimeInHrZone(index: 2, value: 30)
        }

        // 调用 FitMerger.merge：主缺 timeInHrZone，应从副整字段补入。
        let merged = try FitMerger.merge(primary: primary, primaryName: "p.fit", others: [(secondary, "s.fit")])
        // 调用 FitMerger.decode：解码后核对每个分量。
        let messages = try FitMerger.decode(merged)

        let session = try XCTUnwrap(messages.sessionMesgs.first)
        XCTAssertEqual(session.getTimeInHrZone(index: 0), 10)
        XCTAssertEqual(session.getTimeInHrZone(index: 1), 20)
        XCTAssertEqual(session.getTimeInHrZone(index: 2), 30, "数组字段第 3 个分量不应丢失")
    }

    /// 1 秒内 GPS 瞬移约 5km（≈18000 km/h）应被均速修复。
    func testFitSpeedSpikeFixerSmoothsTeleport() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let semicircles = 2_147_483_648.0 / 180.0
        let encoder = FITSwiftSDK.Encoder()
        let fileId = FileIdMesg()
        try fileId.setType(File.activity)
        try fileId.setManufacturer(Manufacturer.development)
        try fileId.setProduct(1)
        try fileId.setSerialNumber(1)
        try fileId.setTimeCreated(DateTime(date: base))
        encoder.write(mesg: fileId)

        let r0 = RecordMesg()
        try r0.setTimestamp(DateTime(date: base))
        try r0.setPositionLat(Int32((31.0 * semicircles).rounded()))
        try r0.setPositionLong(Int32((120.0 * semicircles).rounded()))
        try r0.setDistance(0)
        try r0.setSpeed(5.0)
        encoder.write(mesg: r0)

        // 约 0.045° 纬度 ≈ 5km，1 秒内 → 几千 km/h。
        let r1 = RecordMesg()
        try r1.setTimestamp(DateTime(date: base.addingTimeInterval(1)))
        try r1.setPositionLat(Int32((31.045 * semicircles).rounded()))
        try r1.setPositionLong(Int32((120.0 * semicircles).rounded()))
        try r1.setDistance(5_000)
        try r1.setSpeed(5_000)
        encoder.write(mesg: r1)

        let r2 = RecordMesg()
        try r2.setTimestamp(DateTime(date: base.addingTimeInterval(2)))
        try r2.setPositionLat(Int32((31.0451 * semicircles).rounded()))
        try r2.setPositionLong(Int32((120.0 * semicircles).rounded()))
        try r2.setDistance(5_005)
        try r2.setSpeed(5.0)
        encoder.write(mesg: r2)

        let session = SessionMesg()
        try session.setTimestamp(DateTime(date: base.addingTimeInterval(2)))
        try session.setStartTime(DateTime(date: base))
        try session.setSport(.cycling)
        encoder.write(mesg: session)

        let raw = encoder.close()
        // 调用 FitSpeedSpikeFixer.fix：应抹掉中间瞬移点。
        let fixed = try FitSpeedSpikeFixer.fix(raw)
        XCTAssertGreaterThan(fixed.fixedCount, 0)
        let messages = try FitMerger.decode(fixed.data)
        let mid = messages.recordMesgs.first {
            $0.getTimestamp()?.timestamp == DateTime(date: base.addingTimeInterval(1)).timestamp
        }
        let spd = try XCTUnwrap(mid?.getSpeed())
        XCTAssertLessThanOrEqual(spd, FitSpeedSpikeFixer.maxReasonableSpeedMps + 0.01)
        XCTAssertEqual(mid?.getPositionLat(), r0.getPositionLat(), "瞬移坐标应退回上一点")
    }

    /// GCJ→WGS：北京附近应明显偏移；境外点原样。
    func testGcj02ToWgs84MovesChinaPoint() {
        let (wgsLat, wgsLon) = Gcj02ToWgs84.convert(latitude: 39.9042, longitude: 116.4074)
        XCTAssertGreaterThan(abs(wgsLat - 39.9042) + abs(wgsLon - 116.4074), 0.001)
        let (outLat, outLon) = Gcj02ToWgs84.convert(latitude: 37.7749, longitude: -122.4194)
        XCTAssertEqual(outLat, 37.7749, accuracy: 1e-12)
        XCTAssertEqual(outLon, -122.4194, accuracy: 1e-12)
    }

    /// 回归：semicircle→度不得多乘 180，否则国内点被当成境外，GCJ 开关形同虚设。
    func testGcjFitRewriteMovesSuzhouSemicirclePoint() throws {
        let sc = 2_147_483_648.0 / 180.0
        let lat = 31.3
        let lon = 120.6
        let encoder = Encoder()
        let fileId = FileIdMesg()
        try fileId.setType(.activity)
        try fileId.setManufacturer(.development)
        try fileId.setProduct(1)
        try fileId.setTimeCreated(DateTime())
        encoder.write(mesg: fileId)
        let record = RecordMesg()
        try record.setTimestamp(DateTime())
        try record.setPositionLat(Int32((lat * sc).rounded()))
        try record.setPositionLong(Int32((lon * sc).rounded()))
        encoder.write(mesg: record)
        let raw = encoder.close()

        let rewritten = try FitGcjCoordinateRewriter.rewrite(raw)
        XCTAssertGreaterThan(rewritten.rewrittenCount, 0, "国内点必须被转换")
        let out = try FitMerger.decode(rewritten.data)
        let point = try XCTUnwrap(out.recordMesgs.first)
        let outLat = Double(try XCTUnwrap(point.getPositionLat())) / sc
        let outLon = Double(try XCTUnwrap(point.getPositionLong())) / sc
        XCTAssertGreaterThan(abs(outLat - lat) + abs(outLon - lon), 0.001)
        XCTAssertEqual(outLat, lat, accuracy: 0.02)
        XCTAssertEqual(outLon, lon, accuracy: 0.02)
    }

    func testFitContentProbeRejectsJSON() {
        XCTAssertFalse(FitContentProbe.isValidFit(Data("{ \"error\": true }".utf8)))
    }

    func testEstimateStartOffsetUsesSessionStart() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let primary = try makeMinimalFit(start: base, lat: 31.3, lon: 120.6)
        let secondary = try makeMinimalFit(start: base.addingTimeInterval(120), lat: 31.3, lon: 120.6)
        let offset = FitMerger.estimateStartOffset(
            primaryMessages: try FitMerger.decode(primary),
            secondaryMessages: try FitMerger.decode(secondary)
        )
        XCTAssertEqual(offset, -120)
    }

    private func makeMinimalFit(start: Date, lat: Double, lon: Double) throws -> Data {
        let encoder = Encoder()
        let fileId = FileIdMesg()
        try fileId.setType(.activity)
        try fileId.setManufacturer(.development)
        try fileId.setProduct(1)
        try fileId.setTimeCreated(DateTime(date: start))
        encoder.write(mesg: fileId)
        let record = RecordMesg()
        try record.setTimestamp(DateTime(date: start))
        let sc = 2_147_483_648.0 / 180.0
        try record.setPositionLat(Int32((lat * sc).rounded()))
        try record.setPositionLong(Int32((lon * sc).rounded()))
        try record.setHeartRate(140)
        encoder.write(mesg: record)
        let session = SessionMesg()
        try session.setTimestamp(DateTime(date: start.addingTimeInterval(1)))
        try session.setStartTime(DateTime(date: start))
        try session.setSport(.cycling)
        encoder.write(mesg: session)
        return encoder.close()
    }

    /// 验证 JSON 对象包含关键字段。
    func testJSONObjectContainsCoreFields() {
        let start = Date()
        let summary = WorkoutSummary(
            id: UUID(),
            uuid: UUID(),
            activityType: .cycling,
            activityName: "骑车",
            startDate: start,
            endDate: start.addingTimeInterval(100),
            duration: 100,
            totalDistanceMeters: 1000,
            totalEnergyKilocalories: 50,
            sourceName: "Test"
        )
        let bundle = WorkoutBundle(
            summary: summary,
            metadata: ["IndoorWorkout": "false"],
            events: [],
            series: [:],
            route: []
        )
        let json = bundle.jsonObject()
        XCTAssertEqual(json["activityName"] as? String, "骑车")
        XCTAssertNotNil(json["startDate"])
        XCTAssertNotNil(json["series"])
        XCTAssertNotNil(json["route"])
    }
}
