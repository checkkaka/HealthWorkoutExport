import Foundation

/// 自动同步虚拟功率开关与骑手/车辆参数（UserDefaults）。
enum VirtualPowerSettings {
    /// 是否在自动同步时对缺功率 FIT 回填虚拟功率。
    private static let enabledKey = "virtualPower.enabled"
    /// 骑手质量（kg），含头盔衣物。
    private static let riderMassKey = "virtualPower.riderMassKg"
    /// 车重（kg），含码表水壶等。
    private static let bikeMassKey = "virtualPower.bikeMassKg"
    /// 气动阻力面积 CdA（m²）。
    private static let cdaKey = "virtualPower.cda"
    /// 是否计入惯性项（m·a·v）；关则加速度按 0，均功率通常更稳、略低。
    private static let includeInertiaKey = "virtualPower.includeInertia"

    /// 滚动阻力系数：不开放配置，固定偏保守公路胎。
    static let crr: Double = 0.005
    /// 传动损失百分比：不开放配置，固定常用值。
    static let drivetrainLossPercent: Double = 2

    /// 默认关：避免未填参数时误写功率。
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 默认开：与功率计均功率语义更接近（加速计入、减速不记负功）。
    static var includeInertia: Bool {
        get {
            // 未写过该键时默认 true；显式关掉后保持 false。
            if UserDefaults.standard.object(forKey: includeInertiaKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: includeInertiaKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: includeInertiaKey) }
    }

    /// 默认 70 kg。
    static var riderMassKg: Double {
        get {
            let v = UserDefaults.standard.double(forKey: riderMassKey)
            return v > 0 ? v : 70
        }
        set { UserDefaults.standard.set(newValue, forKey: riderMassKey) }
    }

    /// 默认公路车 8.5 kg。
    static var bikeMassKg: Double {
        get {
            let v = UserDefaults.standard.double(forKey: bikeMassKey)
            return v > 0 ? v : 8.5
        }
        set { UserDefaults.standard.set(newValue, forKey: bikeMassKey) }
    }

    /// 默认 CdA 0.3 m²（介于弯把与刹把之间的常用折中）。
    static var cda: Double {
        get {
            let v = UserDefaults.standard.double(forKey: cdaKey)
            return v > 0 ? v : 0.3
        }
        set { UserDefaults.standard.set(newValue, forKey: cdaKey) }
    }

    /// 组装物理参数（空气密度由天气覆盖）。
    static func physicsParams(airDensity: Double = VirtualPowerPhysics.defaultAirDensity) -> VirtualPowerPhysics.Params {
        VirtualPowerPhysics.Params(
            totalMassKg: riderMassKg + bikeMassKg,
            cda: cda,
            crr: crr,
            drivetrainLossPercent: drivetrainLossPercent,
            airDensity: airDensity
        )
    }

    /// 参数是否可算（质量与 CdA 为正）。
    static var isConfigured: Bool {
        riderMassKg > 0 && bikeMassKg > 0 && cda > 0 && crr > 0
    }
}
