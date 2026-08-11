/// Flutter 调用的最小同步入口，直接复用已测试的核心规则。
#[flutter_rust_bridge::frb(sync)]
pub fn is_commute(distance_meters: Option<f64>, duration_seconds: f64) -> bool {
    crate::is_commute(distance_meters, duration_seconds)
}
