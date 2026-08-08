import Foundation
import HealthKit
import FITSwiftSDK

/// 将 WorkoutBundle 编码为 Garmin Activity FIT 二进制。
enum FitActivityEncoder {
    /// 度转 FIT semicircle。
    private static let semicirclesPerDegree = 2_147_483_648.0 / 180.0

    /// 编码单次训练为 FIT Data；timeZone 决定 Activity 的本地时间戳。
    /// FITSwiftSDK 也声明了 TimeZone，这里必须用 Foundation.TimeZone 消歧。
    static func encode(_ bundle: WorkoutBundle, timeZone: Foundation.TimeZone = .current) throws -> Data {
        let start = bundle.summary.startDate
        let end = bundle.summary.endDate
        let startFit = DateTime(date: start)
        let endFit = DateTime(date: end)
        let elapsed = max(end.timeIntervalSince(start), bundle.summary.duration)

        var messages: [Mesg] = []

        // 调用 EventMesg：写入计时开始，符合 Activity 文件最佳实践。
        let eventStart = EventMesg()
        try eventStart.setTimestamp(startFit)
        try eventStart.setEvent(.timer)
        try eventStart.setEventType(.start)
        messages.append(eventStart)

        // 把 HealthKit 的暂停/继续事件映射为 FIT timer 事件，保证 Garmin 端计时时间准确。
        // 精确匹配事件名，避免 pauseOrResumeRequest 之类被误判。
        for event in bundle.events {
            let eventType: EventType?
            switch event.type {
            case "pause", "motionPaused": eventType = .stopAll
            case "resume", "motionResumed": eventType = .start
            default: eventType = nil
            }
            if let eventType {
                let mesg = EventMesg()
                try mesg.setTimestamp(DateTime(date: event.date))
                try mesg.setEvent(.timer)
                try mesg.setEventType(eventType)
                messages.append(mesg)
            }
        }

        let records = try buildRecords(from: bundle, startFit: startFit)
        messages.append(contentsOf: records)

        // 调用 EventMesg：写入计时结束。
        let eventStop = EventMesg()
        try eventStop.setTimestamp(endFit)
        try eventStop.setEvent(.timer)
        try eventStop.setEventType(.stopAll)
        messages.append(eventStop)

        // 从心率序列计算平均/最大值，供 Session/Lap 汇总展示。
        let heartRates = bundle.series[HKQuantityTypeIdentifier.heartRate.rawValue]?.map(\.value) ?? []
        let avgHR = heartRates.isEmpty ? nil : UInt8(min(max((heartRates.reduce(0, +) / Double(heartRates.count)).rounded(), 0), 255))
        let maxHR = heartRates.max().map { UInt8(min(max($0.rounded(), 0), 255)) }

        // 调用 LapMesg：整次训练作为一圈汇总。
        let lap = LapMesg()
        try lap.setMessageIndex(0)
        try lap.setTimestamp(endFit)
        try lap.setStartTime(startFit)
        try lap.setTotalElapsedTime(elapsed)
        try lap.setTotalTimerTime(elapsed)
        if let distance = bundle.summary.totalDistanceMeters {
            try lap.setTotalDistance(distance)
            if elapsed > 0 {
                try lap.setAvgSpeed(distance / elapsed)
            }
        }
        if let kcal = bundle.summary.totalEnergyKilocalories {
            try lap.setTotalCalories(UInt16(min(max(kcal.rounded(), 0), Double(UInt16.max))))
        }
        if let avgHR { try lap.setAvgHeartRate(avgHR) }
        if let maxHR { try lap.setMaxHeartRate(maxHR) }
        try lap.setSport(mapSport(bundle.summary.activityType))
        try lap.setSubSport(.generic)
        messages.append(lap)

        // 调用 SessionMesg：会话级汇总。
        let session = SessionMesg()
        try session.setMessageIndex(0)
        try session.setTimestamp(endFit)
        try session.setStartTime(startFit)
        try session.setTotalElapsedTime(elapsed)
        try session.setTotalTimerTime(elapsed)
        if let distance = bundle.summary.totalDistanceMeters {
            try session.setTotalDistance(distance)
            if elapsed > 0 {
                try session.setAvgSpeed(distance / elapsed)
            }
        }
        if let kcal = bundle.summary.totalEnergyKilocalories {
            try session.setTotalCalories(UInt16(min(max(kcal.rounded(), 0), Double(UInt16.max))))
        }
        if let avgHR { try session.setAvgHeartRate(avgHR) }
        if let maxHR { try session.setMaxHeartRate(maxHR) }
        try session.setSport(mapSport(bundle.summary.activityType))
        try session.setSubSport(.generic)
        try session.setFirstLapIndex(0)
        try session.setNumLaps(1)
        messages.append(session)

        // 调用 ActivityMesg：文件级 Activity 收尾（每文件恰好一条）。
        let activity = ActivityMesg()
        try activity.setTimestamp(endFit)
        try activity.setTotalTimerTime(elapsed)
        try activity.setNumSessions(1)
        let timezoneOffset = timeZone.secondsFromGMT(for: end)
        try activity.setLocalTimestamp(LocalDateTime(Int(endFit.timestamp) + timezoneOffset))
        messages.append(activity)

        return try finalizeFile(messages: messages, startTime: startFit)
    }

    private static func finalizeFile(messages: [Mesg], startTime: DateTime) throws -> Data {
        let manufacturerId = Manufacturer.development
        let productId: UInt16 = 1
        let serialNumber = UInt32.random(in: 1..<UInt32.max)

        // 调用 FileIdMesg：每个 FIT 文件必须包含。
        let fileId = FileIdMesg()
        try fileId.setType(File.activity)
        try fileId.setManufacturer(manufacturerId)
        try fileId.setProduct(productId)
        try fileId.setTimeCreated(startTime)
        try fileId.setSerialNumber(serialNumber)

        // 调用 DeviceInfoMesg：标注导出来源设备信息。
        let deviceInfo = DeviceInfoMesg()
        try deviceInfo.setDeviceIndex(DeviceIndexValues.creator)
        try deviceInfo.setManufacturer(manufacturerId)
        try deviceInfo.setProduct(productId)
        try deviceInfo.setProductName("HK Export")
        try deviceInfo.setSerialNumber(serialNumber)
        try deviceInfo.setSoftwareVersion(1.0)
        try deviceInfo.setTimestamp(startTime)

        // 调用 Encoder：按顺序写出并计算 CRC。
        let encoder = Encoder()
        encoder.write(mesg: fileId)
        encoder.write(mesg: deviceInfo)
        encoder.write(mesgs: messages)
        return encoder.close()
    }

    /// 合并 GPS / 心率等时间线生成 Record 消息。
    private static func buildRecords(from bundle: WorkoutBundle, startFit: DateTime) throws -> [Mesg] {
        struct Frame {
            var timestamp: Date
            var lat: Double?
            var lon: Double?
            var altitude: Double?
            var speed: Double?
            var heartRate: Double?
            var distance: Double?
            var cadence: Double?
            var power: Double?
            /// 步幅（米，写入 FIT 时转毫米 StepLength）。
            var strideLength: Double?
            /// 垂直振幅（米，写入 FIT 时转毫米）。
            var verticalOscillation: Double?
            /// 触地时间（毫秒，对应 FIT StanceTime）。
            var groundContactTime: Double?
        }

        var framesBySecond: [Int: Frame] = [:]

        func secondKey(_ date: Date) -> Int {
            Int(date.timeIntervalSince1970)
        }

        for point in bundle.route {
            let date = point.timestamp ?? bundle.summary.startDate
            let key = secondKey(date)
            var frame = framesBySecond[key] ?? Frame(timestamp: date)
            frame.lat = point.latitude
            frame.lon = point.longitude
            frame.altitude = point.altitude
            if let speed = point.speed { frame.speed = speed }
            framesBySecond[key] = frame
        }

        if let hr = bundle.series[HKQuantityTypeIdentifier.heartRate.rawValue] {
            for sample in hr {
                let key = secondKey(sample.date)
                var frame = framesBySecond[key] ?? Frame(timestamp: sample.date)
                frame.heartRate = sample.value
                framesBySecond[key] = frame
            }
        }

        // HealthKit 的距离样本是分段增量；FIT Record.distance 语义是累计总距离，须按时间累加。
        let distanceKeys = [
            HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
            HKQuantityTypeIdentifier.distanceCycling.rawValue,
            HKQuantityTypeIdentifier.distanceSwimming.rawValue
        ]
        let distanceSamples = distanceKeys
            .compactMap { bundle.series[$0] }
            .flatMap { $0 }
            .sorted { $0.date < $1.date }
        var cumulativeDistance = 0.0
        for sample in distanceSamples {
            cumulativeDistance += sample.value
            let key = secondKey(sample.date)
            var frame = framesBySecond[key] ?? Frame(timestamp: sample.date)
            frame.distance = cumulativeDistance
            framesBySecond[key] = frame
        }

        let speedKeys = [
            HKQuantityTypeIdentifier.runningSpeed.rawValue,
            HKQuantityTypeIdentifier.cyclingSpeed.rawValue
        ]
        for keyName in speedKeys {
            guard let samples = bundle.series[keyName] else { continue }
            for sample in samples {
                let key = secondKey(sample.date)
                var frame = framesBySecond[key] ?? Frame(timestamp: sample.date)
                frame.speed = sample.value
                framesBySecond[key] = frame
            }
        }

        if let cadence = bundle.series[HKQuantityTypeIdentifier.cyclingCadence.rawValue] {
            for sample in cadence {
                let key = secondKey(sample.date)
                var frame = framesBySecond[key] ?? Frame(timestamp: sample.date)
                frame.cadence = sample.value
                framesBySecond[key] = frame
            }
        }

        if let power = bundle.series[HKQuantityTypeIdentifier.runningPower.rawValue] {
            for sample in power {
                let key = secondKey(sample.date)
                var frame = framesBySecond[key] ?? Frame(timestamp: sample.date)
                frame.power = sample.value
                framesBySecond[key] = frame
            }
        }

        // 跑步动态三项：步幅 / 垂直振幅 / 触地时间。
        if let stride = bundle.series[HKQuantityTypeIdentifier.runningStrideLength.rawValue] {
            for sample in stride {
                let key = secondKey(sample.date)
                var frame = framesBySecond[key] ?? Frame(timestamp: sample.date)
                frame.strideLength = sample.value
                framesBySecond[key] = frame
            }
        }
        if let osc = bundle.series[HKQuantityTypeIdentifier.runningVerticalOscillation.rawValue] {
            for sample in osc {
                let key = secondKey(sample.date)
                var frame = framesBySecond[key] ?? Frame(timestamp: sample.date)
                frame.verticalOscillation = sample.value
                framesBySecond[key] = frame
            }
        }
        if let gct = bundle.series[HKQuantityTypeIdentifier.runningGroundContactTime.rawValue] {
            for sample in gct {
                let key = secondKey(sample.date)
                var frame = framesBySecond[key] ?? Frame(timestamp: sample.date)
                frame.groundContactTime = sample.value
                framesBySecond[key] = frame
            }
        }

        let sorted = framesBySecond.values.sorted { $0.timestamp < $1.timestamp }
        if sorted.isEmpty {
            // 至少写一条 Record，保证文件结构完整。
            let record = RecordMesg()
            try record.setTimestamp(startFit)
            return [record]
        }

        var messages: [Mesg] = []
        for frame in sorted {
            let record = RecordMesg()
            try record.setTimestamp(DateTime(date: frame.timestamp))
            if let lat = frame.lat, let lon = frame.lon {
                try record.setPositionLat(Int32((lat * semicirclesPerDegree).rounded()))
                try record.setPositionLong(Int32((lon * semicirclesPerDegree).rounded()))
            }
            if let altitude = frame.altitude {
                try record.setAltitude(altitude)
            }
            if let speed = frame.speed {
                try record.setSpeed(speed)
            }
            if let heartRate = frame.heartRate {
                let bpm = UInt8(min(max(heartRate.rounded(), 0), 255))
                try record.setHeartRate(bpm)
            }
            if let distance = frame.distance {
                try record.setDistance(distance)
            }
            if let cadence = frame.cadence {
                try record.setCadence(UInt8(min(max(cadence.rounded(), 0), 255)))
            }
            if let power = frame.power {
                try record.setPower(UInt16(min(max(power.rounded(), 0), Double(UInt16.max))))
            }
            if let stride = frame.strideLength {
                // HealthKit 单位米 → FIT StepLength 毫米。
                try record.setStepLength(stride * 1000)
            }
            if let osc = frame.verticalOscillation {
                // HealthKit 单位米 → FIT VerticalOscillation 毫米。
                try record.setVerticalOscillation(osc * 1000)
            }
            if let gct = frame.groundContactTime {
                // 双方单位都是毫秒。
                try record.setStanceTime(gct)
            }
            messages.append(record)
        }
        return messages
    }

    private static func mapSport(_ type: HKWorkoutActivityType) -> Sport {
        switch type {
        case .running: return .running
        case .cycling: return .cycling
        case .walking: return .walking
        case .hiking: return .hiking
        case .swimming: return .swimming
        case .traditionalStrengthTraining, .functionalStrengthTraining: return .training
        case .yoga, .pilates, .flexibility: return .training
        case .elliptical: return .fitnessEquipment
        case .rowing: return .rowing
        case .highIntensityIntervalTraining: return .training
        case .dance: return .fitnessEquipment
        case .soccer: return .soccer
        case .basketball: return .basketball
        case .tennis: return .tennis
        case .golf: return .golf
        case .downhillSkiing: return .alpineSkiing
        case .snowboarding: return .snowboarding
        case .climbing: return .rockClimbing
        default: return .generic
        }
    }
}
