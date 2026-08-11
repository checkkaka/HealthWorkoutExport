import Foundation
import FITSwiftSDK

/// 对骑行 Activity FIT 按 Gribble + Open-Meteo 估算虚拟功率并写入原生 Record.power。
/// 开启后一律覆盖已有功率计/补源功率；应在轨迹 GCJ→WGS 转换之后调用。
enum FitVirtualPowerFiller {
    private static let semicirclesPerDegree = 2_147_483_648.0 / 180.0
    /// 速度/海拔平滑半窗（秒侧索引半径）。
    private static let smoothRadius = 2
    /// 单秒估算失败时，邻域均值起始半径（秒）；不够再逐步扩大。
    private static let neighborAverageRadiusSeconds: TimeInterval = 5
    /// 邻域半径每次扩大的步长（秒）。
    private static let neighborAverageExpandStepSeconds: TimeInterval = 5
    /// 参与估算的秒中「估算环节失败」占比达到此阈值时，整条活动放弃虚拟功率。
    private static let activityFailRateThreshold = 0.10

    struct FillResult: Sendable {
        var data: Data
        /// 写入/覆盖功率的 record 秒数（含踏频 0、邻域均值回填）。
        var filledCount: Int
        /// 估算环节失败的秒数（含已用邻域均值补上的）。
        var failedCount: Int
        /// 写入 `powerSource=virtual` 的秒数（直接估算成功，不含 failed）。
        var virtualMarkedCount: Int
        /// 失败率 ≥10% 导致整条放弃写入。
        var activityRejected: Bool
        /// 是否使用了 Open-Meteo（否则为退化默认大气）。
        var usedWeather: Bool
        /// 天气采样点数。
        var weatherPointCount: Int
        /// 可展示备注。
        var note: String
    }

    /// 骑行活动一律估算并覆盖已有 `power`（含功率计数据）。
    /// 单秒估算失败：先用前后 5 秒功率均值回填并标 failed；不够则继续扩大区间。
    /// 失败率 ≥10% 则整条不采用（总兜底）。
    static func fillIfNeeded(
        _ data: Data,
        settings: VirtualPowerPhysics.Params? = nil,
        includeInertia: Bool? = nil,
        weatherCache: OpenMeteoWeatherCache? = nil,
        weatherProvider: ((Double, Double, Date, Date) async throws -> [WeatherSample])? = nil
    ) async throws -> FillResult {
        let messages = try FitMerger.decode(data)
        // 调用 isCyclingActivity：非骑行不估虚拟功率，避免跑步等误填。
        guard isCyclingActivity(messages) else {
            return FillResult(
                data: data,
                filledCount: 0,
                failedCount: 0,
                virtualMarkedCount: 0,
                activityRejected: false,
                usedWeather: false,
                weatherPointCount: 0,
                note: "虚拟功率跳过：非骑行运动"
            )
        }

        let records = messages.recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        // 无 record 时无法估算；有功率的秒也会被覆盖，不再因「已有功率」跳过。
        guard !records.isEmpty else {
            return FillResult(
                data: data,
                filledCount: 0,
                failedCount: 0,
                virtualMarkedCount: 0,
                activityRejected: false,
                usedWeather: false,
                weatherPointCount: 0,
                note: "虚拟功率跳过：无记录"
            )
        }

        let baseParams = settings ?? VirtualPowerSettings.physicsParams()
        // 调用 VirtualPowerSettings.includeInertia：未显式传入时用设置里的惯性开关。
        let useInertia = includeInertia ?? VirtualPowerSettings.includeInertia
        var weatherStations: [WeatherStation] = []
        var usedWeather = false
        var weatherPointCount = 0
        var weatherAnchorCount = 0

        let anchors = weatherAnchors(from: records)
        if !anchors.isEmpty,
           let start = records.first?.getTimestamp()?.date,
           let end = records.last?.getTimestamp()?.date {
            let provider = weatherProvider ?? { lat, lon, start, end in
                if let weatherCache {
                    // 调用 OpenMeteoWeatherCache：同批按日+粗网格去重请求。
                    return try await weatherCache.hourly(
                        latitude: lat,
                        longitude: lon,
                        start: start,
                        end: end
                    )
                }
                return try await defaultWeatherProvider(lat: lat, lon: lon, start: start, end: end)
            }
            do {
                // 沿途多锚点拉天气；同粗网格 key 只请求一次，再挂到各锚点坐标上做空间插值。
                var seriesByKey: [String: [WeatherSample]] = [:]
                var builtStations: [WeatherStation] = []
                for anchor in anchors {
                    do {
                        let key = OpenMeteoWeatherCache.cacheKey(
                            latitude: anchor.lat,
                            longitude: anchor.lon,
                            start: start,
                            end: end
                        )
                        if seriesByKey[key] == nil {
                            seriesByKey[key] = try await provider(anchor.lat, anchor.lon, start, end)
                        }
                        guard let samples = seriesByKey[key], !samples.isEmpty else { continue }
                        builtStations.append(
                            WeatherStation(
                                lat: anchor.lat,
                                lon: anchor.lon,
                                series: samples.map { ($0.date, $0) }
                            )
                        )
                        weatherPointCount = max(weatherPointCount, samples.count)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let urlError as URLError where urlError.code == .cancelled {
                        throw CancellationError()
                    } catch {
                        // 单锚点失败：保留已建成的站，继续后续锚点。
                        continue
                    }
                }
                weatherStations = builtStations
                weatherAnchorCount = weatherStations.count
                usedWeather = !weatherStations.isEmpty
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            } catch {
                // 整段异常：清空半成品站，与 usedWeather/note 保持一致，退化为默认大气。
                weatherStations = []
                weatherAnchorCount = 0
                weatherPointCount = 0
                usedWeather = false
            }
        }

        let kinematics = buildKinematics(records: records)
        let n = records.count
        /// 各秒最终功率草案：直接估算 / 邻域均值；nil 表示仍无功率。
        var draftPower = [UInt16?](repeating: nil, count: n)
        /// 该秒是否为「估算环节失败」（计入失败率；邻域补上后仍算失败）。
        var estimateFailed = [Bool](repeating: false, count: n)
        /// 该秒是否为直接估算成功（含踏频 0 写 0）。
        var estimateSuccess = [Bool](repeating: false, count: n)

        for (index, record) in records.enumerated() {
            let kin = kinematics[index]
            let cadence = record.getCadence().map { Double($0) }

            // 踏频为 0：即使低速也按滑行写 0，避免停车段留下空洞。
            if let cadence, cadence <= 0 {
                draftPower[index] = 0
                estimateSuccess[index] = true
                continue
            }

            // 速度测值缺失：该秒估算失败，稍后用邻域均值。
            guard let speed = kin.speedMps else {
                estimateFailed[index] = true
                continue
            }
            // 有效低速/停车：物理功率本为 0，记成功滑行，不计入失败率（无踏频停驶同理）。
            if speed <= 0.1 {
                draftPower[index] = 0
                estimateSuccess[index] = true
                continue
            }

            let sample = weatherAt(
                date: kin.date,
                lat: kin.lat,
                lon: kin.lon,
                stations: weatherStations
            )
            let rho: Double
            let headwind: Double
            if let sample {
                let elevation = kin.altitudeM ?? 0
                let stationPressure = pressureAtElevation(
                    mslHpa: sample.pressureMslHpa,
                    elevationM: elevation,
                    temperatureC: sample.temperatureC
                )
                rho = VirtualPowerPhysics.airDensity(
                    temperatureC: sample.temperatureC,
                    pressureHpa: stationPressure,
                    relativeHumidityPercent: sample.relativeHumidityPercent
                )
                if let bearing = kin.bearingDegrees {
                    headwind = VirtualPowerPhysics.headwindMps(
                        windSpeedMps: sample.windSpeedMps,
                        windFromDegrees: sample.windFromDegrees,
                        ridingBearingDegrees: bearing
                    )
                } else {
                    headwind = 0
                }
            } else {
                rho = VirtualPowerPhysics.defaultAirDensity
                headwind = 0
            }

            var params = baseParams
            params.airDensity = rho
            // 关惯性时加速度按 0，避免加减速不对称抬高均功率。
            let accel = useInertia ? kin.accelerationMps2 : 0
            // 调用 VirtualPowerPhysics：Gribble（可选惯性）估算该秒功率。
            let watts = VirtualPowerPhysics.powerWatts(
                groundSpeedMps: speed,
                gradePercent: kin.gradePercent,
                headwindMps: headwind,
                accelerationMps2: accel,
                params: params,
                cadenceRpm: cadence
            )
            let clipped = UInt16(min(max(watts.rounded(), 0), Double(UInt16.max)))
            draftPower[index] = clipped
            estimateSuccess[index] = true
        }

        // 估算失败秒：先 ±5s 邻域均值，不够则逐步扩大，仍只用「直接成功」秒。
        for index in 0..<n {
            guard estimateFailed[index], draftPower[index] == nil else { continue }
            // 调用 neighborAveragePower：从 5s 起扩大区间补该秒功率。
            if let avg = neighborAveragePower(
                at: index,
                draftPower: draftPower,
                estimateFailed: estimateFailed,
                records: records
            ) {
                draftPower[index] = avg
            }
        }

        // 失败率分母：本场参与估算的全部 record 秒。
        let attempted = n
        let failed = estimateFailed.filter { $0 }.count
        let failRate = attempted > 0 ? Double(failed) / Double(attempted) : 0

        // 失败率 ≥10%：整条放弃，不改写任何功率/标记。
        if failRate >= activityFailRateThreshold {
            let weatherNote = usedWeather
                ? "天气锚点 \(weatherAnchorCount)、时序 \(weatherPointCount) 点"
                : "天气退化（默认密度/无风）"
            return FillResult(
                data: data,
                filledCount: 0,
                failedCount: failed,
                virtualMarkedCount: 0,
                activityRejected: true,
                usedWeather: usedWeather,
                weatherPointCount: weatherPointCount,
                note: String(
                    format: "虚拟功率整条放弃：失败率 %.1f%%（%d/%d）≥10%%（%@）",
                    failRate * 100,
                    failed,
                    attempted,
                    weatherNote
                )
            )
        }

        var filled = 0
        var sumPower = 0.0
        var maxPower: UInt16 = 0
        var powerCount = 0
        var successRecords: [RecordMesg] = []
        var failedRecords: [RecordMesg] = []

        for (index, record) in records.enumerated() {
            guard let power = draftPower[index] else {
                // 扩大到整场仍无可用邻域（极少见）：清除残留功率计值并标 failed。
                if estimateFailed[index] {
                    // 调用 removeField：去掉该秒原生 power，不保留功率计旧值。
                    record.removeField(fieldNum: RecordMesg.powerFieldNum)
                    failedRecords.append(record)
                }
                continue
            }
            // 调用 setPower：覆盖该秒已有功率计/补源功率。
            try record.setPower(power)
            filled += 1
            sumPower += Double(power)
            maxPower = max(maxPower, power)
            powerCount += 1
            if estimateSuccess[index] {
                successRecords.append(record)
            } else {
                // 邻域均值回填：功率有值，来源仍标 failed。
                failedRecords.append(record)
            }
        }

        guard filled > 0 || !failedRecords.isEmpty else {
            return FillResult(
                data: data,
                filledCount: 0,
                failedCount: failed,
                virtualMarkedCount: 0,
                activityRejected: false,
                usedWeather: usedWeather,
                weatherPointCount: weatherPointCount,
                note: "虚拟功率未写入：无可处理记录"
            )
        }

        // Session 用整场；Lap 只按本次草稿功率聚合，不读残留 getPower。
        if filled > 0, powerCount > 0 {
            let avg = UInt16(min(max((sumPower / Double(powerCount)).rounded(), 0), Double(UInt16.max)))
            for session in messages.sessionMesgs {
                // 调用 setAvgPower/setMaxPower：覆盖会话原有功率统计。
                try session.setAvgPower(avg)
                try session.setMaxPower(maxPower)
            }
            for lap in messages.lapMesgs {
                // 调用 lapPowerStats：按该圈时间窗只统计 draftPower 非空秒。
                if let stats = lapPowerStats(lap: lap, records: records, draftPower: draftPower) {
                    // 调用 setAvgPower/setMaxPower：覆盖该圈原有功率统计。
                    try lap.setAvgPower(stats.avg)
                    try lap.setMaxPower(stats.max)
                } else {
                    // 该圈本次草稿无功率：清除残留 avg/max，避免旧功率计汇总留下。
                    lap.removeField(fieldNum: LapMesg.avgPowerFieldNum)
                    lap.removeField(fieldNum: LapMesg.maxPowerFieldNum)
                }
            }
        }

        // 调用 VirtualPowerSourceMark：成功 virtual、失败 failed；developer index 避开已占用值。
        let markTimestamp = records.first?.getTimestamp() ?? DateTime()
        let markBundle = try VirtualPowerSourceMark.makeBundle(timestamp: markTimestamp, messages: messages)
        for record in successRecords {
            try VirtualPowerSourceMark.markRecord(
                record,
                bundle: markBundle,
                value: VirtualPowerSourceMark.virtualValue
            )
        }
        for record in failedRecords {
            try VirtualPowerSourceMark.markRecord(
                record,
                bundle: markBundle,
                value: VirtualPowerSourceMark.failedValue
            )
        }

        let encoded = try FitMessagesReencoder.encode(
            messages,
            extraDeviceInfos: [markBundle.deviceInfo],
            developerDataIds: [markBundle.developerDataId],
            fieldDescriptions: [markBundle.fieldDescription]
        )
        let weatherNote: String
        if usedWeather {
            weatherNote = "天气锚点 \(weatherAnchorCount)、时序 \(weatherPointCount) 点"
        } else {
            weatherNote = "天气退化（默认密度/无风）"
        }
        let note = "虚拟功率已覆盖写入 \(filled) 秒（估算失败 \(failed) 秒已用扩大邻域均值或标 failed，\(weatherNote)）"
        return FillResult(
            data: encoded,
            filledCount: filled,
            failedCount: failed,
            virtualMarkedCount: successRecords.count,
            activityRejected: false,
            usedWeather: usedWeather,
            weatherPointCount: weatherPointCount,
            note: note
        )
    }

    /// 从 ±5s 起按步长扩大时间窗，取窗内直接估算成功功率的算术平均；
    /// 扩大到覆盖整场仍无可用功率则 nil。失败率 ≥10% 是总兜底，故此处优先尽量补上。
    private static func neighborAveragePower(
        at index: Int,
        draftPower: [UInt16?],
        estimateFailed: [Bool],
        records: [RecordMesg]
    ) -> UInt16? {
        guard let centerTs = records[index].getTimestamp()?.timestamp else { return nil }
        let center = TimeInterval(centerTs)
        // 整场时间跨度：扩大上限，避免无限循环。
        let maxRadius: TimeInterval = {
            let times = records.compactMap { $0.getTimestamp()?.timestamp }.map { TimeInterval($0) }
            guard let lo = times.min(), let hi = times.max() else {
                return neighborAverageRadiusSeconds
            }
            return max(neighborAverageRadiusSeconds, hi - lo)
        }()

        var radius = neighborAverageRadiusSeconds
        while radius <= maxRadius + 0.001 {
            var sum = 0.0
            var count = 0
            for j in draftPower.indices {
                guard j != index, let power = draftPower[j] else { continue }
                // 其它估算失败秒不参与均值，避免失败点互相污染。
                if estimateFailed[j] { continue }
                guard let ts = records[j].getTimestamp()?.timestamp else { continue }
                if abs(TimeInterval(ts) - center) <= radius {
                    sum += Double(power)
                    count += 1
                }
            }
            if count > 0 {
                return UInt16(min(max((sum / Double(count)).rounded(), 0), Double(UInt16.max)))
            }
            // 当前半径无点：再扩大一步。
            if radius >= maxRadius { break }
            radius = min(maxRadius, radius + neighborAverageExpandStepSeconds)
        }
        return nil
    }

    /// Session 运动类型是否为骑行；无 session 时不估。
    private static func isCyclingActivity(_ messages: FitMessages) -> Bool {
        let sports = messages.sessionMesgs.compactMap { $0.getSport() }
        guard !sports.isEmpty else { return false }
        return sports.contains(.cycling)
    }

    /// 沿途天气站：一个 GPS 锚点 + 该点的逐小时时序。
    private struct WeatherStation {
        var lat: Double
        var lon: Double
        var series: [(Date, WeatherSample)]
    }

    private static func defaultWeatherProvider(
        lat: Double,
        lon: Double,
        start: Date,
        end: Date
    ) async throws -> [WeatherSample] {
        // 调用 OpenMeteoWeatherClient：按 7 天分流拉天气逐小时样本。
        try await OpenMeteoWeatherClient.fetchHourly(
            latitude: lat,
            longitude: lon,
            start: start,
            end: end
        )
    }

    /// 按 Lap 起止时间窗，只统计本次草稿功率的 avg/max；窗口无效或草稿全空则 nil。
    private static func lapPowerStats(
        lap: LapMesg,
        records: [RecordMesg],
        draftPower: [UInt16?]
    ) -> (avg: UInt16, max: UInt16)? {
        guard let start = lap.getStartTime()?.timestamp,
              let end = lap.getTimestamp()?.timestamp,
              end >= start else { return nil }
        var sum = 0.0
        var maxP: UInt16 = 0
        var n = 0
        for (index, record) in records.enumerated() {
            guard index < draftPower.count,
                  let ts = record.getTimestamp()?.timestamp,
                  ts >= start, ts <= end,
                  let power = draftPower[index] else { continue }
            sum += Double(power)
            maxP = max(maxP, power)
            n += 1
        }
        guard n > 0 else { return nil }
        let avg = UInt16(min(max((sum / Double(n)).rounded(), 0), Double(UInt16.max)))
        return (avg, maxP)
    }

    private struct Kinematics {
        var date: Date
        var speedMps: Double?
        var altitudeM: Double?
        var lat: Double?
        var lon: Double?
        var gradePercent: Double
        var accelerationMps2: Double
        var bearingDegrees: Double?
    }

    private static func buildKinematics(records: [RecordMesg]) -> [Kinematics] {
        let n = records.count
        var speeds = [Double?](repeating: nil, count: n)
        var alts = [Double?](repeating: nil, count: n)
        var lats = [Double?](repeating: nil, count: n)
        var lons = [Double?](repeating: nil, count: n)
        var times = [Date?](repeating: nil, count: n)
        var dists = [Double?](repeating: nil, count: n)

        for i in 0..<n {
            let r = records[i]
            // FIT timestamp 使用 Garmin epoch；由 SDK 统一转换为 Unix Date。
            times[i] = r.getTimestamp()?.date
            speeds[i] = r.getSpeed() ?? r.getEnhancedSpeed()
            // 海拔优先原生 altitude，缺失时回退 enhanced_altitude。
            alts[i] = r.getAltitude() ?? r.getEnhancedAltitude()
            if let la = r.getPositionLat(), let lo = r.getPositionLong() {
                lats[i] = Double(la) / semicirclesPerDegree
                lons[i] = Double(lo) / semicirclesPerDegree
            }
            dists[i] = r.getDistance()
        }

        // 调用 replaceGlitchSpeedsWithPrevious：跳变+回落确认的飞点改用上一秒速度。
        let cleanedSpeeds = VirtualPowerPhysics.replaceGlitchSpeedsWithPrevious(
            speeds: speeds,
            times: times
        )
        let smoothSpeed = smooth(cleanedSpeeds, radius: smoothRadius, fillMissingCenter: false)
        let smoothAlt = smooth(alts, radius: smoothRadius, fillMissingCenter: true)

        var result = [Kinematics](repeating: Kinematics(
            date: Date(), speedMps: nil, altitudeM: nil, lat: nil, lon: nil,
            gradePercent: 0, accelerationMps2: 0, bearingDegrees: nil
        ), count: n)

        for i in 0..<n {
            let date = times[i] ?? Date()
            var grade = 0.0
            var accel = 0.0
            var bearing: Double?

            if i > 0, let t0 = times[i - 1], let t1 = times[i] {
                let dt = t1.timeIntervalSince(t0)
                if dt > 0 {
                    if let a0 = smoothAlt[i - 1], let a1 = smoothAlt[i] {
                        let dd: Double
                        if let d0 = dists[i - 1], let d1 = dists[i], d1 > d0 {
                            dd = d1 - d0
                        } else if let la0 = lats[i - 1], let lo0 = lons[i - 1],
                                  let la1 = lats[i], let lo1 = lons[i] {
                            dd = haversineMeters(lat1: la0, lon1: lo0, lat2: la1, lon2: lo1)
                        } else if let s = smoothSpeed[i] {
                            dd = s * dt
                        } else {
                            dd = 0
                        }
                        grade = VirtualPowerPhysics.gradePercent(deltaAltitudeM: a1 - a0, deltaDistanceM: dd)
                    }
                    if let s0 = smoothSpeed[i - 1], let s1 = smoothSpeed[i] {
                        let rawAccel = (s1 - s0) / dt
                        // 调用 sanitizedAcceleration：飞点已在速度侧处理，这里只钳 ±2.0。
                        accel = VirtualPowerPhysics.sanitizedAccelerationMps2(
                            smoothedAccelerationMps2: rawAccel,
                            dtSeconds: dt
                        )
                    }
                    if let la0 = lats[i - 1], let lo0 = lons[i - 1],
                       let la1 = lats[i], let lo1 = lons[i] {
                        let dist = haversineMeters(lat1: la0, lon1: lo0, lat2: la1, lon2: lo1)
                        if dist > 1 {
                            bearing = VirtualPowerPhysics.bearingDegrees(
                                lat1: la0, lon1: lo0, lat2: la1, lon2: lo1
                            )
                        }
                    }
                }
            }

            result[i] = Kinematics(
                date: date,
                speedMps: smoothSpeed[i] ?? cleanedSpeeds[i],
                altitudeM: smoothAlt[i] ?? alts[i],
                lat: lats[i],
                lon: lons[i],
                gradePercent: grade,
                accelerationMps2: accel,
                bearingDegrees: bearing
            )
        }
        return result
    }

    /// 滑动均值；`fillMissingCenter=false` 时中心点本身为 nil 则保持 nil（速度缺测不发明值）。
    private static func smooth(
        _ values: [Double?],
        radius: Int,
        fillMissingCenter: Bool
    ) -> [Double?] {
        guard !values.isEmpty else { return values }
        var out = [Double?](repeating: nil, count: values.count)
        for i in values.indices {
            if values[i] == nil, !fillMissingCenter {
                out[i] = nil
                continue
            }
            var sum = 0.0
            var n = 0
            let lo = max(0, i - radius)
            let hi = min(values.count - 1, i + radius)
            for j in lo...hi {
                if let v = values[j] {
                    sum += v
                    n += 1
                }
            }
            out[i] = n > 0 ? sum / Double(n) : values[i]
        }
        return out
    }

    /// 沿轨迹抽天气锚点：约每 5 km 或 10 分钟一点，最多 12 个，首尾必含。
    /// 粗网格缓存仍去重同城请求；多锚点用于跨区域/长距离时的空间插值。
    private static let weatherAnchorMinGapMeters = 5_000.0
    private static let weatherAnchorMinGapSeconds: TimeInterval = 600
    private static let weatherAnchorMaxCount = 12

    /// 返回沿途天气查询坐标（测试也可直接调用）。
    static func weatherAnchorCoordinates(from records: [RecordMesg]) -> [(lat: Double, lon: Double)] {
        var anchors: [(lat: Double, lon: Double)] = []
        var lastLat: Double?
        var lastLon: Double?
        var lastTime: Date?
        var traveled = 0.0

        func append(_ lat: Double, _ lon: Double) {
            if let prev = anchors.last {
                let d = haversineMeters(lat1: prev.lat, lon1: prev.lon, lat2: lat, lon2: lon)
                if d < 50 { return }
            }
            anchors.append((lat, lon))
        }

        for record in records {
            guard let la = record.getPositionLat(), let lo = record.getPositionLong() else { continue }
            let lat = Double(la) / semicirclesPerDegree
            let lon = Double(lo) / semicirclesPerDegree
            let time = record.getTimestamp()?.date

            if anchors.isEmpty {
                append(lat, lon)
                lastLat = lat
                lastLon = lon
                lastTime = time
                continue
            }
            if let la0 = lastLat, let lo0 = lastLon {
                traveled += haversineMeters(lat1: la0, lon1: lo0, lat2: lat, lon2: lon)
            }
            let timeGap: TimeInterval = {
                guard let t0 = lastTime, let t1 = time else { return 0 }
                return t1.timeIntervalSince(t0)
            }()
            if traveled >= weatherAnchorMinGapMeters || timeGap >= weatherAnchorMinGapSeconds {
                append(lat, lon)
                traveled = 0
                lastTime = time
            }
            lastLat = lat
            lastLon = lon
        }

        if let la = records.last?.getPositionLat(), let lo = records.last?.getPositionLong() {
            append(Double(la) / semicirclesPerDegree, Double(lo) / semicirclesPerDegree)
        }

        if anchors.count <= weatherAnchorMaxCount {
            return anchors
        }
        // 超上限时均匀抽稀，保留首尾。
        var thinned: [(lat: Double, lon: Double)] = [anchors[0]]
        let inner = weatherAnchorMaxCount - 2
        for i in 1...inner {
            let idx = Int((Double(i) / Double(inner + 1)) * Double(anchors.count - 1))
            thinned.append(anchors[idx])
        }
        thinned.append(anchors[anchors.count - 1])
        return thinned
    }

    private static func weatherAnchors(from records: [RecordMesg]) -> [(lat: Double, lon: Double)] {
        weatherAnchorCoordinates(from: records)
    }

    /// 按位置选最近天气站，再按时间插值；无 GPS 时退回第一站。
    private static func weatherAt(
        date: Date,
        lat: Double?,
        lon: Double?,
        stations: [WeatherStation]
    ) -> WeatherSample? {
        guard !stations.isEmpty else { return nil }
        guard let lat, let lon else {
            return interpolateWeather(at: date, samples: stations[0].series)
        }
        if stations.count == 1 {
            return interpolateWeather(at: date, samples: stations[0].series)
        }

        let ranked = stations
            .map { station -> (WeatherStation, Double) in
                let d = haversineMeters(lat1: lat, lon1: lon, lat2: station.lat, lon2: station.lon)
                return (station, d)
            }
            .sorted { $0.1 < $1.1 }

        let nearest = ranked[0]
        let second = ranked[1]
        guard let s0 = interpolateWeather(at: date, samples: nearest.0.series) else {
            return interpolateWeather(at: date, samples: second.0.series)
        }
        // 第二站过远或重合：直接用最近站。
        guard nearest.1 + second.1 > 1,
              let s1 = interpolateWeather(at: date, samples: second.0.series),
              second.1 < 25_000 else {
            return s0
        }
        let w = nearest.1 / (nearest.1 + second.1)
        return WeatherSample(
            date: date,
            temperatureC: lerp(s0.temperatureC, s1.temperatureC, w),
            relativeHumidityPercent: lerp(s0.relativeHumidityPercent, s1.relativeHumidityPercent, w),
            pressureMslHpa: lerp(s0.pressureMslHpa, s1.pressureMslHpa, w),
            windSpeedMps: lerp(s0.windSpeedMps, s1.windSpeedMps, w),
            windFromDegrees: lerpAngle(s0.windFromDegrees, s1.windFromDegrees, w)
        )
    }

    private static func interpolateWeather(
        at date: Date,
        samples: [(Date, WeatherSample)]
    ) -> WeatherSample? {
        guard !samples.isEmpty else { return nil }
        if date <= samples.first!.0 { return samples.first!.1 }
        if date >= samples.last!.0 { return samples.last!.1 }
        for i in 0..<(samples.count - 1) {
            let (t0, s0) = samples[i]
            let (t1, s1) = samples[i + 1]
            if date >= t0 && date <= t1 {
                let span = t1.timeIntervalSince(t0)
                guard span > 0 else { return s0 }
                let w = date.timeIntervalSince(t0) / span
                return WeatherSample(
                    date: date,
                    temperatureC: lerp(s0.temperatureC, s1.temperatureC, w),
                    relativeHumidityPercent: lerp(s0.relativeHumidityPercent, s1.relativeHumidityPercent, w),
                    pressureMslHpa: lerp(s0.pressureMslHpa, s1.pressureMslHpa, w),
                    windSpeedMps: lerp(s0.windSpeedMps, s1.windSpeedMps, w),
                    windFromDegrees: lerpAngle(s0.windFromDegrees, s1.windFromDegrees, w)
                )
            }
        }
        return samples.last?.1
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private static func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let diff = ((b - a + 540).truncatingRemainder(dividingBy: 360)) - 180
        return (a + diff * t + 360).truncatingRemainder(dividingBy: 360)
    }

    /// 海平面气压按海拔订正到站点气压（简易等温近似）。
    private static func pressureAtElevation(mslHpa: Double, elevationM: Double, temperatureC: Double) -> Double {
        let tK = temperatureC + 273.15
        let exponent = (VirtualPowerPhysics.gravity * 0.0289644 * elevationM) / (8.3144598 * tK)
        return mslHpa * exp(-exponent)
    }

    private static func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}
