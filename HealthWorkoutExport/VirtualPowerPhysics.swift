import Foundation

/// Gribble 骑行物理模型：由速度/坡度/风/加速度估算腿部功率（瓦）。
enum VirtualPowerPhysics {
    /// 重力加速度（m/s²），与 Gribble 计算器一致。
    static let gravity = 9.8067
    /// 海平面标准空气密度回退值（kg/m³）。
    static let defaultAirDensity = 1.225

    /// 骑手+车+装备总质量与气动/滚阻参数。
    struct Params: Equatable, Sendable {
        /// 总质量（kg），含人车水壶等。
        var totalMassKg: Double
        /// 气动阻力面积 Cd·A（m²）。
        var cda: Double
        /// 滚动阻力系数（无量纲）。
        var crr: Double
        /// 传动损失百分比（如 2 表示 2%）。
        var drivetrainLossPercent: Double
        /// 空气密度（kg/m³）。
        var airDensity: Double
    }

    /// 业余站姿起步约 1.3–1.6 m/s²，滚动冲刺多 <1；钳位上限为真冲刺留余量。
    static let maxRealisticAccelerationMps2 = 2.0
    /// 原速变化率达到该值（m/s²）才可能是 GPS 飞点；约等于 8 km/h/s。
    static let gpsSpeedJumpGlitchMps2 = 8.0 / 3.6
    /// 尖峰回落后与跳变前速度相差不超过该值（m/s）视为回落连贯；约等于 5 km/h。
    static let gpsGlitchRecoveryMaxDeltaMps = 5.0 / 3.6

    /// 估算腿部功率。cadenceRpm==0 时强制滑行功率 0；负功率钳为 0。
    static func powerWatts(
        groundSpeedMps: Double,
        gradePercent: Double,
        headwindMps: Double,
        accelerationMps2: Double,
        params: Params,
        cadenceRpm: Double? = nil
    ) -> Double {
        if let cadenceRpm, cadenceRpm <= 0 {
            return 0
        }
        guard groundSpeedMps > 0.1 else { return 0 }

        let beta = atan(gradePercent / 100)
        let mass = params.totalMassKg
        let fg = gravity * mass * sin(beta)
        let fr = gravity * mass * cos(beta) * params.crr
        let airSpeed = groundSpeedMps + headwindMps
        let fa = 0.5 * params.cda * params.airDensity * airSpeed * abs(airSpeed)
        let fk = mass * accelerationMps2
        let force = fg + fr + fa + fk
        let eta = max(0.5, 1 - params.drivetrainLossPercent / 100)
        let legs = force * groundSpeedMps / eta
        return max(0, legs)
    }

    /// 飞点须同时满足：跳变过大 + 下一秒相对尖峰回落（前后不连贯）。
    static func isGpsSpeedGlitch(
        previousMps: Double,
        candidateMps: Double,
        followingMps: Double,
        dtToCandidate: Double,
        dtToFollowing: Double
    ) -> Bool {
        guard dtToCandidate > 0, dtToFollowing > 0 else { return false }
        let jumpRate = abs(candidateMps - previousMps) / dtToCandidate
        guard jumpRate >= gpsSpeedJumpGlitchMps2 else { return false }

        // 回落靠近跳变前，或从尖峰回落至少一半且比尖峰更接近前值。
        let backNearPrevious = abs(followingMps - previousMps) <= gpsGlitchRecoveryMaxDeltaMps
        let spikeDelta = abs(candidateMps - previousMps)
        let recoveredTowardPrevious =
            spikeDelta > 0
            && abs(followingMps - candidateMps) >= spikeDelta * 0.5
            && abs(followingMps - previousMps) < abs(candidateMps - previousMps)
        return backNearPrevious || recoveredTowardPrevious
    }

    /// 检出飞点后用上一秒速度替换，避免尖峰进入平滑与气动项。
    static func replaceGlitchSpeedsWithPrevious(
        speeds: [Double?],
        times: [Date?]
    ) -> [Double?] {
        guard speeds.count == times.count, speeds.count >= 3 else { return speeds }
        var out = speeds
        for i in 1..<(speeds.count - 1) {
            guard let previous = out[i - 1] ?? speeds[i - 1],
                  let candidate = speeds[i],
                  let following = speeds[i + 1],
                  let t0 = times[i - 1],
                  let t1 = times[i],
                  let t2 = times[i + 1] else { continue }
            let dt1 = t1.timeIntervalSince(t0)
            let dt2 = t2.timeIntervalSince(t1)
            // 调用 isGpsSpeedGlitch：跳变+回落双条件确认后再改速度。
            if isGpsSpeedGlitch(
                previousMps: previous,
                candidateMps: candidate,
                followingMps: following,
                dtToCandidate: dt1,
                dtToFollowing: dt2
            ) {
                out[i] = previous
            }
        }
        return out
    }

    /// 清洗加速度：钳到业余冲刺合理上限 ±2.0（飞点应先在速度序列中替换）。
    static func sanitizedAccelerationMps2(
        smoothedAccelerationMps2: Double,
        dtSeconds: Double
    ) -> Double {
        guard dtSeconds > 0 else { return 0 }
        return min(
            max(smoothedAccelerationMps2, -maxRealisticAccelerationMps2),
            maxRealisticAccelerationMps2
        )
    }

    /// 由气温、气压、相对湿度计算空气密度（kg/m³）。
    static func airDensity(
        temperatureC: Double,
        pressureHpa: Double,
        relativeHumidityPercent: Double
    ) -> Double {
        let tK = temperatureC + 273.15
        let rh = min(100, max(0, relativeHumidityPercent)) / 100
        // Magnus：饱和水汽压（hPa）。
        let es = 6.112 * exp((17.67 * temperatureC) / (temperatureC + 243.5))
        let e = rh * es
        let pd = max(0, pressureHpa - e)
        let rhoDry = (pd * 100) / (287.058 * tK)
        let rhoVapor = (e * 100) / (461.495 * tK)
        return rhoDry + rhoVapor
    }

    /// 把气压场风向（来自哪）与骑行方位合成迎风分量（正=迎风，m/s）。
    static func headwindMps(
        windSpeedMps: Double,
        windFromDegrees: Double,
        ridingBearingDegrees: Double
    ) -> Double {
        let delta = (windFromDegrees - ridingBearingDegrees) * .pi / 180
        return windSpeedMps * cos(delta)
    }

    /// 由相邻点海拔与水平距离估算坡度百分比。
    static func gradePercent(deltaAltitudeM: Double, deltaDistanceM: Double) -> Double {
        guard deltaDistanceM > 0.5 else { return 0 }
        return (deltaAltitudeM / deltaDistanceM) * 100
    }

    /// 两点方位角（度，0=北，顺时针）。
    static func bearingDegrees(
        lat1: Double, lon1: Double,
        lat2: Double, lon2: Double
    ) -> Double {
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let y = sin(dLon) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }
}
