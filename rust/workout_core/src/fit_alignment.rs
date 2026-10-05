use std::{collections::BTreeMap, error::Error, fmt};

pub const MAX_ALIGNMENT_OFFSET_SECONDS: i32 = 7_200;

const MIN_SERIES_SAMPLES: usize = 30;
const MIN_SPEED_PAIRS: usize = 80;
const MAX_MEAN_SPEED_DIFF_MPS: f64 = 1.0;
const MAX_DISTANCE_DIFF_METERS: f64 = 12.0;
const MAX_DISTANCE_DELTA_SPREAD_SECONDS: i32 = 30;

/// 已从 FIT Record 提取的按秒数值；速度使用 m/s，累计距离使用 m。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FitAlignmentSample {
    pub timestamp_seconds: u32,
    pub value: f64,
}

/// 不需要读取 FIT 内容即可确定的时间对齐方式。
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FitStaticAlignment {
    Absolute,
    Manual(i32),
    PerFile(Vec<i32>),
}

#[derive(Clone, Debug, PartialEq)]
pub enum FitAlignmentError {
    InvalidSample,
    OffsetOutOfRange(i32),
    PerFileCountMismatch {
        expected: usize,
        actual: usize,
    },
    InsufficientSpeedOverlap,
    SpeedMismatch {
        offset_seconds: i32,
        mean_difference_mps: f64,
    },
    InsufficientReliableData,
}

impl fmt::Display for FitAlignmentError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSample => formatter.write_str("对齐样本含有无效数值"),
            Self::OffsetOutOfRange(seconds) => write!(
                formatter,
                "偏移 {seconds} 秒超出 ±{MAX_ALIGNMENT_OFFSET_SECONDS} 秒范围"
            ),
            Self::PerFileCountMismatch { expected, actual } => {
                write!(
                    formatter,
                    "逐文件偏移数量不匹配：需要 {expected}，实际 {actual}"
                )
            }
            Self::InsufficientSpeedOverlap => formatter.write_str("±2 小时内速度配对样本不足"),
            Self::SpeedMismatch {
                offset_seconds,
                mean_difference_mps,
            } => write!(
                formatter,
                "最优偏移 {offset_seconds} 秒下平均速度差仍为 {mean_difference_mps:.2} m/s"
            ),
            Self::InsufficientReliableData => {
                formatter.write_str("缺少足够且可靠的速度或累计距离样本")
            }
        }
    }
}

impl Error for FitAlignmentError {}

/// 解析绝对、统一手动或逐文件偏移；返回值依次对应各副文件。
pub fn resolve_static_offsets(
    alignment: &FitStaticAlignment,
    supplement_count: usize,
) -> Result<Vec<i32>, FitAlignmentError> {
    match alignment {
        FitStaticAlignment::Absolute => Ok(vec![0; supplement_count]),
        FitStaticAlignment::Manual(seconds) => {
            validate_offset(*seconds)?;
            Ok(vec![*seconds; supplement_count])
        }
        FitStaticAlignment::PerFile(offsets) => {
            if offsets.len() != supplement_count {
                return Err(FitAlignmentError::PerFileCountMismatch {
                    expected: supplement_count,
                    actual: offsets.len(),
                });
            }
            for seconds in offsets {
                validate_offset(*seconds)?;
            }
            Ok(offsets.clone())
        }
    }
}

/// 估算应加到副文件时间戳上的秒偏移；速度充足时不以距离结果掩盖速度不匹配。
pub fn estimate_fit_offset(
    primary_speeds: &[FitAlignmentSample],
    secondary_speeds: &[FitAlignmentSample],
    primary_distances: &[FitAlignmentSample],
    secondary_distances: &[FitAlignmentSample],
) -> Result<i32, FitAlignmentError> {
    validate_samples(primary_speeds)?;
    validate_samples(secondary_speeds)?;
    validate_samples(primary_distances)?;
    validate_samples(secondary_distances)?;

    if primary_speeds.len() >= MIN_SERIES_SAMPLES && secondary_speeds.len() >= MIN_SERIES_SAMPLES {
        let Some((offset_seconds, mean_difference_mps)) =
            best_speed_offset(primary_speeds, secondary_speeds)
        else {
            return Err(FitAlignmentError::InsufficientSpeedOverlap);
        };
        if mean_difference_mps > MAX_MEAN_SPEED_DIFF_MPS {
            return Err(FitAlignmentError::SpeedMismatch {
                offset_seconds,
                mean_difference_mps,
            });
        }
        return Ok(offset_seconds);
    }

    if primary_distances.len() >= MIN_SERIES_SAMPLES
        && secondary_distances.len() >= MIN_SERIES_SAMPLES
        && let Some(offset) = median_distance_offset(primary_distances, secondary_distances)
    {
        return Ok(offset);
    }

    Err(FitAlignmentError::InsufficientReliableData)
}

fn validate_offset(seconds: i32) -> Result<(), FitAlignmentError> {
    if (-MAX_ALIGNMENT_OFFSET_SECONDS..=MAX_ALIGNMENT_OFFSET_SECONDS).contains(&seconds) {
        Ok(())
    } else {
        Err(FitAlignmentError::OffsetOutOfRange(seconds))
    }
}

fn validate_samples(samples: &[FitAlignmentSample]) -> Result<(), FitAlignmentError> {
    if samples
        .iter()
        .all(|sample| sample.value.is_finite() && sample.value >= 0.0)
    {
        Ok(())
    } else {
        Err(FitAlignmentError::InvalidSample)
    }
}

fn best_speed_offset(
    primary: &[FitAlignmentSample],
    secondary: &[FitAlignmentSample],
) -> Option<(i32, f64)> {
    let primary = sample_map(primary);
    let secondary = sample_map(secondary);
    let mut best = None;
    let mut best_mean = f64::MAX;
    let mut best_pairs = 0;

    for offset in -MAX_ALIGNMENT_OFFSET_SECONDS..=MAX_ALIGNMENT_OFFSET_SECONDS {
        let mut sum = 0.0;
        let mut pairs = 0;
        for (timestamp, primary_speed) in &primary {
            let secondary_timestamp = i64::from(*timestamp) - i64::from(offset);
            if let Ok(secondary_timestamp) = u32::try_from(secondary_timestamp)
                && let Some(secondary_speed) = secondary.get(&secondary_timestamp)
            {
                sum += (primary_speed - secondary_speed).abs();
                pairs += 1;
            }
        }
        if pairs < MIN_SPEED_PAIRS {
            continue;
        }
        let mean = sum / pairs as f64;
        if mean < best_mean - 0.01 || ((mean - best_mean).abs() <= 0.01 && pairs > best_pairs) {
            best = Some(offset);
            best_mean = mean;
            best_pairs = pairs;
        }
    }

    best.map(|offset| (offset, best_mean))
}

fn sample_map(samples: &[FitAlignmentSample]) -> BTreeMap<u32, f64> {
    samples
        .iter()
        .map(|sample| (sample.timestamp_seconds, sample.value))
        .collect()
}

fn median_distance_offset(
    primary: &[FitAlignmentSample],
    secondary: &[FitAlignmentSample],
) -> Option<i32> {
    let mut primary = primary.to_vec();
    let mut secondary = secondary.to_vec();
    primary.sort_by_key(|sample| sample.timestamp_seconds);
    secondary.sort_by_key(|sample| sample.timestamp_seconds);

    let mut deltas = Vec::new();
    let mut primary_index = 0;
    for secondary_sample in secondary {
        if secondary_sample.value <= 50.0 {
            continue;
        }
        while primary_index + 1 < primary.len()
            && primary[primary_index + 1].value <= secondary_sample.value
        {
            primary_index += 1;
        }

        let mut best = &primary[primary_index];
        if primary_index + 1 < primary.len()
            && (primary[primary_index + 1].value - secondary_sample.value).abs()
                < (best.value - secondary_sample.value).abs()
        {
            best = &primary[primary_index + 1];
        }
        if (best.value - secondary_sample.value).abs() < MAX_DISTANCE_DIFF_METERS {
            let delta =
                i64::from(best.timestamp_seconds) - i64::from(secondary_sample.timestamp_seconds);
            if let Ok(delta) = i32::try_from(delta) {
                deltas.push(delta);
            }
        }
    }

    if deltas.len() < MIN_SERIES_SAMPLES {
        return None;
    }
    deltas.sort_unstable();
    let median = deltas[deltas.len() / 2];
    let concentrated = deltas
        .iter()
        .filter(|delta| delta.abs_diff(median) <= MAX_DISTANCE_DELTA_SPREAD_SECONDS as u32)
        .count();
    (concentrated * 10 >= deltas.len() * 6).then_some(median)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn estimates_speed_skew_and_rejects_different_activity() {
        let primary = (0..120)
            .map(|second| FitAlignmentSample {
                timestamp_seconds: 1_000 + second,
                value: 4.0 + f64::from((second * 17 + second * second) % 31) / 10.0,
            })
            .collect::<Vec<_>>();
        let secondary = primary
            .iter()
            .map(|sample| FitAlignmentSample {
                timestamp_seconds: sample.timestamp_seconds + 871,
                value: sample.value,
            })
            .collect::<Vec<_>>();
        assert_eq!(
            estimate_fit_offset(&primary, &secondary, &[], &[]),
            Ok(-871)
        );

        let mismatched = secondary
            .iter()
            .map(|sample| FitAlignmentSample {
                value: sample.value + 6.0,
                ..*sample
            })
            .collect::<Vec<_>>();
        assert!(matches!(
            estimate_fit_offset(&primary, &mismatched, &[], &[]),
            Err(FitAlignmentError::SpeedMismatch { .. })
        ));
    }

    #[test]
    fn falls_back_to_concentrated_distance_offsets() {
        let primary = (0..=200)
            .map(|second| FitAlignmentSample {
                timestamp_seconds: 10_000 + second,
                value: f64::from(second) * 5.0,
            })
            .collect::<Vec<_>>();
        let secondary = primary
            .iter()
            .map(|sample| FitAlignmentSample {
                timestamp_seconds: sample.timestamp_seconds + 40,
                value: sample.value,
            })
            .collect::<Vec<_>>();
        assert_eq!(estimate_fit_offset(&[], &[], &primary, &secondary), Ok(-40));

        let mismatched = (0..=120)
            .map(|second| FitAlignmentSample {
                timestamp_seconds: 10_000 + second,
                value: f64::from(second) * 17.0,
            })
            .collect::<Vec<_>>();
        assert_eq!(
            estimate_fit_offset(&[], &[], &primary, &mismatched),
            Err(FitAlignmentError::InsufficientReliableData)
        );
    }

    #[test]
    fn resolves_and_validates_static_offsets() {
        assert_eq!(
            resolve_static_offsets(&FitStaticAlignment::Absolute, 2),
            Ok(vec![0, 0])
        );
        assert_eq!(
            resolve_static_offsets(&FitStaticAlignment::Manual(-100), 2),
            Ok(vec![-100, -100])
        );
        assert_eq!(
            resolve_static_offsets(&FitStaticAlignment::PerFile(vec![-40, 20]), 2),
            Ok(vec![-40, 20])
        );
        assert_eq!(
            resolve_static_offsets(&FitStaticAlignment::PerFile(vec![-40]), 2),
            Err(FitAlignmentError::PerFileCountMismatch {
                expected: 2,
                actual: 1
            })
        );
        assert_eq!(
            resolve_static_offsets(&FitStaticAlignment::Manual(7_201), 1),
            Err(FitAlignmentError::OffsetOutOfRange(7_201))
        );
    }
}
