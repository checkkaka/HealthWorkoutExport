import Foundation
import FITSwiftSDK

/// 对缺功率的 Activity FIT 按 Gribble + Open-Meteo 回填原生 Record.power。
enum FitVirtualPowerFiller {
    private static let semicirclesPerDegree = 2_147_483_648.0 / 180.0
    /// 速度/海拔平滑半窗（秒侧索引半径）。
    private static let smoothRadius = 2

    struct FillResult: Sendable {
        var data: Data
        /// 新写入功率的 record 秒数。
        var filledCount: Int
        /// 是否使用了 Open-Meteo（否则为退化默认大气）。
        var usedWeather: Bool
        /// 天气采样点数。
        var weatherPointCount: Int
        /// 可展示备注。
        var note: String
    }

    /// 仅当存在 `power == nil` 的 record 时回填；已有功率秒不动。
    static func fillIfNeeded(
        _ data: Data,
        settings: VirtualPowerPhysics.Params? = nil,
        weatherCache: OpenMeteoWeatherCache? = nil,
        weatherProvider: ((Double, Double, Date, Date) async throws -> [WeatherSample])? = nil
    ) async throws -> FillResult {
        let messages = try FitMerger.decode(data)
        let records = messages.recordMesgs.sorted {
            ($0.getTimestamp()?.timestamp ?? 0) < ($1.getTimestamp()?.timestamp ?? 0)
        }
        let missing = records.filter { $0.getPower() == nil }
        guard !missing.isEmpty else {
            return FillResult(
                data: data,
                filledCount: 0,
                usedWeather: false,
                weatherPointCount: 0,
                note: "虚拟功率跳过：文件已有功率或无记录"
            )
        }

        let baseParams = settings ?? VirtualPowerSettings.physicsParams()
        var weatherByTime: [(Date, WeatherSample)] = []
        var usedWeather = false
        var weatherPointCount = 0

        if let anchor = weatherAnchor(from: records),
           let firstTs = records.first?.getTimestamp()?.timestamp,
           let lastTs = records.last?.getTimestamp()?.timestamp {
            let start = Date(timeIntervalSince1970: TimeInterval(firstTs))
            let end = Date(timeIntervalSince1970: TimeInterval(lastTs))
            let provider = weatherProvider ?? { lat, lon, start, end in
                if let weatherCache {
                    // 调用 OpenMeteoWeatherCache：同批按日+粗网格复用天气。
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
                // 调用天气 provider：按轨迹锚点拉历史逐小时天气。
                let samples = try await provider(anchor.lat, anchor.lon, start, end)
                weatherByTime = samples.map { ($0.date, $0) }
                usedWeather = !samples.isEmpty
                weatherPointCount = samples.count
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            } catch {
                usedWeather = false
            }
        }

        let kinematics = buildKinematics(records: records)
        var filled = 0
        var sumPower = 0.0
        var maxPower: UInt16 = 0
        var powerCount = 0

        for (index, record) in records.enumerated() {
            if let existing = record.getPower() {
                sumPower += Double(existing)
                maxPower = max(maxPower, existing)
                powerCount += 1
                continue
            }
            let kin = kinematics[index]
            let cadence = record.getCadence().map { Double($0) }
            // 踏频为 0：即使低速也按滑行写 0，避免停车段留下空洞。
            if let cadence, cadence <= 0 {
                try record.setPower(0)
                filled += 1
                powerCount += 1
                continue
            }
            guard let speed = kin.speedMps, speed > 0.1 else { continue }

            let sample = interpolateWeather(at: kin.date, samples: weatherByTime)
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
            // 调用 VirtualPowerPhysics：Gribble+惯性估算该秒功率。
            let watts = VirtualPowerPhysics.powerWatts(
                groundSpeedMps: speed,
                gradePercent: kin.gradePercent,
                headwindMps: headwind,
                accelerationMps2: kin.accelerationMps2,
                params: params,
                cadenceRpm: cadence
            )
            let clipped = UInt16(min(max(watts.rounded(), 0), Double(UInt16.max)))
            try record.setPower(clipped)
            filled += 1
            sumPower += Double(clipped)
            maxPower = max(maxPower, clipped)
            powerCount += 1
        }

        guard filled > 0 else {
            return FillResult(
                data: data,
                filledCount: 0,
                usedWeather: usedWeather,
                weatherPointCount: weatherPointCount,
                note: "虚拟功率未写入：缺速度等运动学字段"
            )
        }

        // Session 用整场；Lap 按各自时间窗聚合，避免多圈共用一场均值。
        if powerCount > 0 {
            let avg = UInt16(min(max((sumPower / Double(powerCount)).rounded(), 0), Double(UInt16.max)))
            for session in messages.sessionMesgs {
                if session.getAvgPower() == nil {
                    try session.setAvgPower(avg)
                }
                if session.getMaxPower() == nil {
                    try session.setMaxPower(maxPower)
                }
            }
            for lap in messages.lapMesgs {
                // 调用 lapPowerStats：按该圈起止过滤 record 算 avg/max。
                guard let stats = lapPowerStats(lap: lap, records: records) else { continue }
                if lap.getAvgPower() == nil {
                    try lap.setAvgPower(stats.avg)
                }
                if lap.getMaxPower() == nil {
                    try lap.setMaxPower(stats.max)
                }
            }
        }

        let encoded = try FitMessagesReencoder.encode(messages)
        let weatherNote = usedWeather
            ? "天气 \(weatherPointCount) 点"
            : "天气退化（默认密度/无风）"
        return FillResult(
            data: encoded,
            filledCount: filled,
            usedWeather: usedWeather,
            weatherPointCount: weatherPointCount,
            note: "虚拟功率已回填 \(filled) 秒（\(weatherNote)）"
        )
    }

    private static func defaultWeatherProvider(
        lat: Double,
        lon: Double,
        start: Date,
        end: Date
    ) async throws -> [WeatherSample] {
        // 调用 OpenMeteoWeatherClient：拉 Archive 逐小时样本。
        try await OpenMeteoWeatherClient.fetchHourly(
            latitude: lat,
            longitude: lon,
            start: start,
            end: end
        )
    }

    /// 按 Lap 起止时间窗统计该圈功率 avg/max；窗口无效或无功率则返回 nil。
    private static func lapPowerStats(
        lap: LapMesg,
        records: [RecordMesg]
    ) -> (avg: UInt16, max: UInt16)? {
        guard let start = lap.getStartTime()?.timestamp,
              let end = lap.getTimestamp()?.timestamp,
              end >= start else { return nil }
        var sum = 0.0
        var maxP: UInt16 = 0
        var n = 0
        for record in records {
            guard let ts = record.getTimestamp()?.timestamp,
                  ts >= start, ts <= end,
                  let power = record.getPower() else { continue }
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
            if let ts = r.getTimestamp()?.timestamp {
                times[i] = Date(timeIntervalSince1970: TimeInterval(ts))
            }
            speeds[i] = r.getSpeed() ?? r.getEnhancedSpeed()
            alts[i] = r.getAltitude()
            if let la = r.getPositionLat(), let lo = r.getPositionLong() {
                lats[i] = Double(la) / semicirclesPerDegree
                lons[i] = Double(lo) / semicirclesPerDegree
            }
            dists[i] = r.getDistance()
        }

        let smoothSpeed = smooth(speeds, radius: smoothRadius)
        let smoothAlt = smooth(alts, radius: smoothRadius)

        var result = [Kinematics](repeating: Kinematics(
            date: Date(), speedMps: nil, altitudeM: nil,
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
                        accel = (s1 - s0) / dt
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
                speedMps: smoothSpeed[i] ?? speeds[i],
                altitudeM: smoothAlt[i] ?? alts[i],
                gradePercent: grade,
                accelerationMps2: accel,
                bearingDegrees: bearing
            )
        }
        return result
    }

    private static func smooth(_ values: [Double?], radius: Int) -> [Double?] {
        guard !values.isEmpty else { return values }
        var out = [Double?](repeating: nil, count: values.count)
        for i in values.indices {
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

    private static func weatherAnchor(from records: [RecordMesg]) -> (lat: Double, lon: Double)? {
        // 取第一条有 GPS 的点作为天气查询锚点（格点尺度下足够）。
        for record in records {
            if let la = record.getPositionLat(), let lo = record.getPositionLong() {
                return (Double(la) / semicirclesPerDegree, Double(lo) / semicirclesPerDegree)
            }
        }
        return nil
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
