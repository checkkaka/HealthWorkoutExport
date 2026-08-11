#![forbid(unsafe_code)]

const SHORT_DISTANCE_KM: f64 = 5.0;
const SLOW_SPEED_KMH: f64 = 28.0;
const SLOW_COMMUTE_MAX_DISTANCE_KM: f64 = 16.0;
const TIGHT_START_DELTA_SECONDS: f64 = 5.0 * 60.0;
const MAX_START_DELTA_SECONDS: f64 = 45.0 * 60.0;
const MAX_DURATION_RATIO: f64 = 0.20;
const MAX_DISTANCE_RATIO: f64 = 0.05;
const MAX_DISTANCE_ABS_METERS: f64 = 100.0;

/// 根据距离和时长判断 Strava 活动是否应标记为通勤。
///
/// 规则与现有 Swift 实现一致：距离小于 5km，或均速低于 28km/h 且距离小于 16km。
pub fn is_commute(distance_meters: Option<f64>, duration_seconds: f64) -> bool {
    let Some(distance_meters) = distance_meters else {
        return false;
    };
    if distance_meters <= 0.0 || duration_seconds <= 0.0 {
        return false;
    }

    let distance_km = distance_meters / 1_000.0;
    if distance_km < SHORT_DISTANCE_KM {
        return true;
    }

    let speed_kmh = distance_km / (duration_seconds / 3_600.0);
    speed_kmh < SLOW_SPEED_KMH && distance_km < SLOW_COMMUTE_MAX_DISTANCE_KM
}

/// 判断两条跨来源活动是否为同一场，用于同步幂等去重。
///
/// 开始时间相差不超过 5 分钟时只要求距离接近；5 至 45 分钟时还要求两边时长接近。
pub fn stable_dedupe_matches(
    start_a_seconds: f64,
    distance_a_meters: f64,
    start_b_seconds: f64,
    distance_b_meters: f64,
    duration_a_seconds: Option<f64>,
    duration_b_seconds: Option<f64>,
) -> bool {
    if !(distance_a_meters > 0.0 && distance_b_meters > 0.0) {
        return false;
    }

    let start_delta = (start_a_seconds - start_b_seconds).abs();
    if !(start_delta <= MAX_START_DELTA_SECONDS) {
        return false;
    }

    let distance_difference = (distance_a_meters - distance_b_meters).abs();
    let distance_limit =
        MAX_DISTANCE_ABS_METERS.max(distance_a_meters.max(distance_b_meters) * MAX_DISTANCE_RATIO);
    if !(distance_difference <= distance_limit) {
        return false;
    }
    if start_delta <= TIGHT_START_DELTA_SECONDS {
        return true;
    }

    let (Some(duration_a), Some(duration_b)) = (duration_a_seconds, duration_b_seconds) else {
        return false;
    };
    if !(duration_a > 0.0 && duration_b > 0.0) {
        return false;
    }

    (duration_a - duration_b).abs() / duration_a.max(duration_b) <= MAX_DURATION_RATIO
}

#[cfg(test)]
mod tests {
    use super::{is_commute, stable_dedupe_matches};

    #[test]
    fn matches_existing_commute_rules() {
        let cases = [
            (Some(4_000.0), 1_200.0, true),
            (Some(12_000.0), 1_800.0, true),
            (Some(20_000.0), 2_400.0, false),
            (Some(20_000.0), 3_000.0, false),
            (Some(16_000.0), 3_600.0, false),
            (Some(5_000.0), 5_000.0 / 1_000.0 / 28.0 * 3_600.0, false),
            (None, 1_200.0, false),
            (Some(4_000.0), 0.0, false),
        ];

        for (distance_meters, duration_seconds, expected) in cases {
            assert_eq!(
                is_commute(distance_meters, duration_seconds),
                expected,
                "distance={distance_meters:?}, duration={duration_seconds}"
            );
        }
    }

    #[test]
    fn stable_dedupe_matches_existing_rules() {
        let start = 1_700_000_000.0;

        assert!(stable_dedupe_matches(
            start,
            10_890.0,
            start + 3.0 * 60.0,
            11_430.0,
            None,
            None
        ));
        assert!(!stable_dedupe_matches(
            start,
            3_000.0,
            start + 3.0 * 60.0,
            11_000.0,
            None,
            None
        ));
        assert!(!stable_dedupe_matches(
            start,
            12_040.0,
            start + 20.0 * 60.0,
            11_800.0,
            None,
            None
        ));
        assert!(stable_dedupe_matches(
            start,
            12_040.0,
            start + 20.0 * 60.0,
            11_800.0,
            Some(24.0 * 60.0 + 2.0),
            Some(24.0 * 60.0 + 12.0)
        ));
    }
}
