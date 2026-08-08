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
