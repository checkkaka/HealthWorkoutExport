#![deny(unsafe_code)]

mod api;
pub mod fit;
#[allow(unsafe_code)]
mod frb_generated;
pub mod onelap;
pub mod strava;
pub mod sync_state;
pub mod weather;
pub mod xingzhe;

use sha2::{Digest, Sha256};
use std::fmt::Write;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

const SHORT_DISTANCE_KM: f64 = 5.0;
const SLOW_SPEED_KMH: f64 = 28.0;
const SLOW_COMMUTE_MAX_DISTANCE_KM: f64 = 16.0;
const TIGHT_START_DELTA_SECONDS: f64 = 5.0 * 60.0;
const MAX_START_DELTA_SECONDS: f64 = 45.0 * 60.0;
const MAX_DURATION_RATIO: f64 = 0.20;
const MAX_DISTANCE_RATIO: f64 = 0.05;
const MAX_DISTANCE_ABS_METERS: f64 = 100.0;
const MIN_ACTIVITY_OVERLAP_RATIO: f64 = 0.5;
const ACTIVITY_MATCH_MAX_START_DELTA_SECONDS: f64 = 15.0 * 60.0;
const ACTIVITY_MATCH_MAX_DURATION_RATIO: f64 = 0.20;
const GRAVITY_MPS2: f64 = 9.8067;
const MAX_REALISTIC_ACCELERATION_MPS2: f64 = 2.0;
const GPS_SPEED_JUMP_GLITCH_MPS2: f64 = 8.0 / 3.6;
const GPS_GLITCH_RECOVERY_MAX_DELTA_MPS: f64 = 5.0 / 3.6;

/// 生成与 Swift `SyncFingerprint.make` 相同的同步幂等指纹。
pub fn sync_fingerprint(
    primary_source_id: &str,
    primary_activity_id: &str,
    start_date_unix_seconds: f64,
    supplement_source_ids: &[&str],
    destination: &str,
) -> Option<String> {
    if !start_date_unix_seconds.is_finite() {
        return None;
    }
    let start = OffsetDateTime::from_unix_timestamp(start_date_unix_seconds.floor() as i64)
        .ok()?
        .format(&Rfc3339)
        .ok()?;
    let mut supplements = supplement_source_ids.to_vec();
    supplements.sort_unstable();
    let raw = format!(
        "{primary_source_id}|{primary_activity_id}|{start}|{}|{destination}",
        supplements.join(",")
    );
    let mut fingerprint = String::with_capacity(64);
    for byte in Sha256::digest(raw) {
        write!(&mut fingerprint, "{byte:02x}").ok()?;
    }
    Some(fingerprint)
}

/// 骑手、车辆与装备的总质量及骑行阻力参数。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VirtualPowerParams {
    pub total_mass_kg: f64,
    pub cda: f64,
    pub crr: f64,
    pub drivetrain_loss_percent: f64,
    pub air_density: f64,
}

/// 使用与 Swift `VirtualPowerPhysics.powerWatts` 相同的 Gribble 模型估算腿部功率。
pub fn virtual_power_watts(
    ground_speed_mps: f64,
    grade_percent: f64,
    headwind_mps: f64,
    acceleration_mps2: f64,
    params: VirtualPowerParams,
    cadence_rpm: Option<f64>,
) -> f64 {
    if cadence_rpm.is_some_and(|cadence| cadence <= 0.0) || ground_speed_mps <= 0.1 {
        return 0.0;
    }

    let beta = (grade_percent / 100.0).atan();
    let gravity_force = GRAVITY_MPS2 * params.total_mass_kg * beta.sin();
    let rolling_force = GRAVITY_MPS2 * params.total_mass_kg * beta.cos() * params.crr;
    let air_speed = ground_speed_mps + headwind_mps;
    let aerodynamic_force = 0.5 * params.cda * params.air_density * air_speed * air_speed.abs();
    let inertia_force = params.total_mass_kg * acceleration_mps2;
    let efficiency = (1.0 - params.drivetrain_loss_percent / 100.0).max(0.5);

    ((gravity_force + rolling_force + aerodynamic_force + inertia_force) * ground_speed_mps
        / efficiency)
        .max(0.0)
}

/// 由气温、气压与相对湿度计算空气密度（kg/m³）。
pub fn air_density(temperature_c: f64, pressure_hpa: f64, relative_humidity_percent: f64) -> f64 {
    let temperature_k = temperature_c + 273.15;
    let humidity = relative_humidity_percent.clamp(0.0, 100.0) / 100.0;
    let saturated_vapor_pressure =
        6.112 * ((17.67 * temperature_c) / (temperature_c + 243.5)).exp();
    let vapor_pressure = humidity * saturated_vapor_pressure;
    let dry_pressure = (pressure_hpa - vapor_pressure).max(0.0);

    (dry_pressure * 100.0) / (287.058 * temperature_k)
        + (vapor_pressure * 100.0) / (461.495 * temperature_k)
}

/// 把气压场风向（来自哪）与骑行方位合成为迎风分量（正值为迎风）。
pub fn headwind_mps(
    wind_speed_mps: f64,
    wind_from_degrees: f64,
    riding_bearing_degrees: f64,
) -> f64 {
    let delta = (wind_from_degrees - riding_bearing_degrees).to_radians();
    wind_speed_mps * delta.cos()
}

/// 仅在速度大幅跳变且随后回落时认定 GPS 飞点。
pub fn is_gps_speed_glitch(
    previous_mps: f64,
    candidate_mps: f64,
    following_mps: f64,
    dt_to_candidate: f64,
    dt_to_following: f64,
) -> bool {
    if dt_to_candidate <= 0.0 || dt_to_following <= 0.0 {
        return false;
    }
    let jump_rate = (candidate_mps - previous_mps).abs() / dt_to_candidate;
    if jump_rate < GPS_SPEED_JUMP_GLITCH_MPS2 {
        return false;
    }

    let back_near_previous =
        (following_mps - previous_mps).abs() <= GPS_GLITCH_RECOVERY_MAX_DELTA_MPS;
    let spike_delta = (candidate_mps - previous_mps).abs();
    let recovered_toward_previous = spike_delta > 0.0
        && (following_mps - candidate_mps).abs() >= spike_delta * 0.5
        && (following_mps - previous_mps).abs() < (candidate_mps - previous_mps).abs();

    back_near_previous || recovered_toward_previous
}

/// 检出飞点后用上一采样速度替换；时间值使用同一时间基准下的秒数。
pub fn replace_glitch_speeds_with_previous(
    speeds: &[Option<f64>],
    times_seconds: &[Option<f64>],
) -> Vec<Option<f64>> {
    if speeds.len() != times_seconds.len() || speeds.len() < 3 {
        return speeds.to_vec();
    }

    let mut cleaned = speeds.to_vec();
    for index in 1..speeds.len() - 1 {
        let Some(previous) = cleaned[index - 1].or(speeds[index - 1]) else {
            continue;
        };
        let (Some(candidate), Some(following), Some(t0), Some(t1), Some(t2)) = (
            speeds[index],
            speeds[index + 1],
            times_seconds[index - 1],
            times_seconds[index],
            times_seconds[index + 1],
        ) else {
            continue;
        };
        if is_gps_speed_glitch(previous, candidate, following, t1 - t0, t2 - t1) {
            cleaned[index] = Some(previous);
        }
    }
    cleaned
}

/// 将加速度钳制到现有 Swift 模型的业余冲刺合理上限。
pub fn sanitized_acceleration_mps2(acceleration_mps2: f64, dt_seconds: f64) -> f64 {
    if dt_seconds <= 0.0 {
        return 0.0;
    }
    acceleration_mps2.clamp(
        -MAX_REALISTIC_ACCELERATION_MPS2,
        MAX_REALISTIC_ACCELERATION_MPS2,
    )
}

/// 由相邻点海拔差与水平距离估算坡度百分比。
pub fn grade_percent(delta_altitude_m: f64, delta_distance_m: f64) -> f64 {
    if delta_distance_m <= 0.5 {
        return 0.0;
    }
    delta_altitude_m / delta_distance_m * 100.0
}

/// 计算两点方位角（度，0 为北，顺时针）。
pub fn bearing_degrees(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let p1 = lat1.to_radians();
    let p2 = lat2.to_radians();
    let longitude_delta = (lon2 - lon1).to_radians();
    let y = longitude_delta.sin() * p2.cos();
    let x = p1.cos() * p2.sin() - p1.sin() * p2.cos() * longitude_delta.cos();
    y.atan2(x).to_degrees().rem_euclid(360.0)
}

/// 仅用于跨来源活动匹配的时间区间。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ActivityInterval {
    start_seconds: f64,
    end_seconds: f64,
    duration_seconds: f64,
}

impl ActivityInterval {
    pub const fn new(start_seconds: f64, end_seconds: f64, duration_seconds: f64) -> Self {
        Self {
            start_seconds,
            end_seconds,
            duration_seconds,
        }
    }
}

/// 返回两条活动的匹配分数；不满足重叠或兜底容差时返回 `None`。
pub fn activity_match_score(primary: ActivityInterval, candidate: ActivityInterval) -> Option<f64> {
    let primary_duration = (primary.end_seconds - primary.start_seconds)
        .max(primary.duration_seconds)
        .max(1.0);
    let candidate_duration = (candidate.end_seconds - candidate.start_seconds)
        .max(candidate.duration_seconds)
        .max(1.0);

    let overlap = primary.end_seconds.min(candidate.end_seconds)
        - primary.start_seconds.max(candidate.start_seconds);
    if overlap > 0.0 {
        let union = primary.end_seconds.max(candidate.end_seconds)
            - primary.start_seconds.min(candidate.start_seconds);
        if union > 0.0 {
            let ratio = overlap / union;
            if ratio >= MIN_ACTIVITY_OVERLAP_RATIO {
                return Some(ratio);
            }
        }
    }

    let start_delta = (primary.start_seconds - candidate.start_seconds).abs();
    if start_delta > ACTIVITY_MATCH_MAX_START_DELTA_SECONDS {
        return None;
    }
    let duration_ratio =
        (primary_duration - candidate_duration).abs() / primary_duration.max(candidate_duration);
    if duration_ratio > ACTIVITY_MATCH_MAX_DURATION_RATIO {
        return None;
    }

    Some((1.0 - start_delta / ACTIVITY_MATCH_MAX_START_DELTA_SECONDS) * (1.0 - duration_ratio))
}

/// 返回候选列表中分数最高的活动下标；并列时保留最先出现的候选。
pub fn best_activity_match_index(
    primary: ActivityInterval,
    candidates: &[ActivityInterval],
) -> Option<usize> {
    let mut best = None;
    for (index, &candidate) in candidates.iter().enumerate() {
        let Some(score) = activity_match_score(primary, candidate) else {
            continue;
        };
        if best.is_none_or(|(_, best_score)| score > best_score) {
            best = Some((index, score));
        }
    }
    best.map(|(index, _)| index)
}

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
    use super::{
        ActivityInterval, VirtualPowerParams, activity_match_score, air_density, bearing_degrees,
        best_activity_match_index, grade_percent, headwind_mps, is_commute, is_gps_speed_glitch,
        replace_glitch_speeds_with_previous, sanitized_acceleration_mps2, stable_dedupe_matches,
        sync_fingerprint, virtual_power_watts,
    };

    #[test]
    fn virtual_power_matches_swift_gribble_boundaries() {
        let params = VirtualPowerParams {
            total_mass_kg: 80.0,
            cda: 0.32,
            crr: 0.004,
            drivetrain_loss_percent: 2.0,
            air_density: 1.226,
        };

        assert!((virtual_power_watts(10.0, 0.0, 0.0, 0.0, params, None) - 232.2).abs() < 0.5);
        assert_eq!(virtual_power_watts(12.0, -8.0, 0.0, 0.0, params, None), 0.0);
        assert_eq!(
            virtual_power_watts(10.0, 5.0, 0.0, 0.0, params, Some(0.0)),
            0.0
        );
    }

    #[test]
    fn air_density_matches_swift_dry_sea_level_value() {
        assert!((air_density(15.0, 1_013.25, 0.0) - 1.225).abs() < 0.01);
    }

    #[test]
    fn headwind_component_matches_swift_bearing_convention() {
        assert!(headwind_mps(5.0, 90.0, 0.0).abs() < 0.05);
        assert!((headwind_mps(5.0, 0.0, 0.0) - 5.0).abs() < 0.05);
    }

    #[test]
    fn gps_glitch_requires_a_jump_followed_by_recovery() {
        assert!(is_gps_speed_glitch(
            34.6 / 3.6,
            60.6 / 3.6,
            35.0 / 3.6,
            1.0,
            1.0
        ));
        assert!(!is_gps_speed_glitch(
            20.0 / 3.6,
            30.0 / 3.6,
            32.0 / 3.6,
            1.0,
            1.0
        ));
        assert!(!is_gps_speed_glitch(
            45.0 / 3.6,
            13.0 / 3.6,
            12.0 / 3.6,
            1.0,
            1.0
        ));
    }

    #[test]
    fn speed_cleaner_replaces_only_the_swift_glitch_sample() {
        let speeds = [
            Some(34.6 / 3.6),
            Some(60.6 / 3.6),
            Some(35.0 / 3.6),
            Some(34.8 / 3.6),
        ];
        let times = [Some(1_000.0), Some(1_001.0), Some(1_002.0), Some(1_003.0)];

        let cleaned = replace_glitch_speeds_with_previous(&speeds, &times);

        assert_eq!(cleaned[0], speeds[0]);
        assert_eq!(cleaned[1], speeds[0]);
        assert_eq!(cleaned[2], speeds[2]);
    }

    #[test]
    fn acceleration_cleaner_matches_swift_sprint_cap() {
        assert_eq!(sanitized_acceleration_mps2(1.6, 1.0), 1.6);
        assert_eq!(sanitized_acceleration_mps2(2.5, 1.0), 2.0);
        assert_eq!(sanitized_acceleration_mps2(-2.5, 1.0), -2.0);
        assert_eq!(sanitized_acceleration_mps2(1.0, 0.0), 0.0);
    }

    #[test]
    fn grade_uses_swift_half_meter_distance_boundary() {
        assert_eq!(grade_percent(1.0, 0.5), 0.0);
        assert_eq!(grade_percent(1.0, 20.0), 5.0);
    }

    #[test]
    fn bearing_matches_swift_north_clockwise_convention() {
        assert!(bearing_degrees(0.0, 0.0, 1.0, 0.0).abs() < 0.001);
        assert!((bearing_degrees(0.0, 0.0, 0.0, 1.0) - 90.0).abs() < 0.001);
    }

    #[test]
    fn activity_matcher_matches_swift_overlap_and_fallback_rules() {
        let primary = ActivityInterval::new(1_700_000_000.0, 1_700_003_600.0, 3_600.0);
        let high_overlap = ActivityInterval::new(1_700_000_300.0, 1_700_003_500.0, 3_200.0);
        let low_overlap_outside_tolerance =
            ActivityInterval::new(1_700_003_599.0, 1_700_010_799.0, 7_200.0);
        let fallback = ActivityInterval::new(1_699_999_100.0, 1_700_001_980.0, 2_880.0);
        let far = ActivityInterval::new(1_700_100_000.0, 1_700_103_600.0, 3_600.0);

        assert!(activity_match_score(primary, high_overlap).is_some());
        assert!(activity_match_score(primary, fallback).is_some());
        assert_eq!(
            activity_match_score(primary, low_overlap_outside_tolerance),
            None
        );
        assert_eq!(activity_match_score(primary, far), None);
    }

    #[test]
    fn activity_matcher_picks_the_highest_scoring_candidate() {
        let primary = ActivityInterval::new(1_700_000_000.0, 1_700_003_600.0, 3_600.0);
        let far = ActivityInterval::new(1_700_100_000.0, 1_700_103_600.0, 3_600.0);
        let best = ActivityInterval::new(1_700_000_300.0, 1_700_003_500.0, 3_200.0);

        assert_eq!(best_activity_match_index(primary, &[far, best]), Some(1));
    }

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

    #[test]
    fn sync_fingerprint_matches_swift_sha256_and_sorts_supplements() {
        let a = sync_fingerprint(
            "healthkit",
            "abc",
            1_700_000_000.0,
            &["xingzhe", "onelap"],
            "strava",
        );
        let b = sync_fingerprint(
            "healthkit",
            "abc",
            1_700_000_000.999,
            &["onelap", "xingzhe"],
            "strava",
        );

        assert_eq!(
            a.as_deref(),
            Some("acf456b5da1096d0b5ef26ed1b77d078d509e37b0c20d55bdf1396414ef7a153")
        );
        assert_eq!(a, b);
    }

    #[test]
    fn sync_fingerprint_preserves_empty_fields_and_each_business_field() {
        let empty = sync_fingerprint("", "", 1_700_000_000.999, &[], "strava");
        assert_eq!(
            empty.as_deref(),
            Some("3ace46d36978a272e0e877ec50739b02ea8476d936cb387d47e00501d2b4d8a7")
        );
        assert_eq!(
            sync_fingerprint(
                "healthkit",
                "abc",
                1_700_000_000.0,
                &["", "onelap"],
                "strava"
            )
            .as_deref(),
            Some("2ee38594241d391357fb40cf6a8037f852a719f0e9aa7dc7d336ed6579dbd57d")
        );

        let base = sync_fingerprint("healthkit", "abc", 1_700_000_000.0, &["onelap"], "strava");
        for changed in [
            sync_fingerprint("xingzhe", "abc", 1_700_000_000.0, &["onelap"], "strava"),
            sync_fingerprint("healthkit", "def", 1_700_000_000.0, &["onelap"], "strava"),
            sync_fingerprint("healthkit", "abc", 1_700_000_001.0, &["onelap"], "strava"),
            sync_fingerprint("healthkit", "abc", 1_700_000_000.0, &["xingzhe"], "strava"),
            sync_fingerprint("healthkit", "abc", 1_700_000_000.0, &["onelap"], "garmin"),
        ] {
            assert_ne!(base, changed);
        }
        assert_eq!(sync_fingerprint("h", "a", f64::NAN, &[], "strava"), None);
    }
}
