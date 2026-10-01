use super::fit_weather::{coordinate, weather_at};
use super::{FitDecodeError, FitDocument, FitWeatherStation, haversine_meters};
use crate::{
    COASTING_MAX_CADENCE_RPM, VirtualPowerParams, grade_percent,
    replace_glitch_speeds_with_previous, sanitized_acceleration_mps2, virtual_power_watts,
};

const RECORD: u16 = 20;
const SESSION: u16 = 18;
const LAP: u16 = 19;
const SPORT_FIELD: u8 = 5;
const CYCLING: u8 = 2;
const TIMESTAMP: u8 = 253;
const ALTITUDE: u8 = 2;
const CADENCE: u8 = 4;
const DISTANCE: u8 = 5;
const SPEED: u8 = 6;
const POWER: u8 = 7;
const ENHANCED_SPEED: u8 = 73;
const ENHANCED_ALTITUDE: u8 = 78;
const AVG_POWER: u8 = 20;
const MAX_POWER: u8 = 21;
const LAP_AVG_POWER: u8 = 19;
const LAP_MAX_POWER: u8 = 20;
const START_TIME: u8 = 2;
const SPEED_SCALE: f64 = 1_000.0;
const DISTANCE_SCALE: f64 = 100.0;
const ALTITUDE_SCALE: f64 = 5.0;
const ALTITUDE_OFFSET: f64 = 500.0;
const NEIGHBOR_START_SECONDS: u32 = 5;
const FAILURE_RATE_LIMIT: f64 = 0.10;
const MAX_WRITABLE_POWER: f64 = (u16::MAX - 1) as f64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FitVirtualPowerFillMode {
    Overwrite,
    FillMissing,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FitVirtualPowerFillOptions {
    pub params: VirtualPowerParams,
    pub include_inertia: bool,
    pub mode: FitVirtualPowerFillMode,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FitVirtualPowerFillResult {
    pub data: Vec<u8>,
    pub filled_count: usize,
    pub failed_count: usize,
    pub virtual_marked_count: usize,
    pub activity_rejected: bool,
    /// 与实际写入 FIT 的 powerSource=virtual developer 标记一致。
    pub power_source_virtual: bool,
}

/// 为骑行 FIT 的既有 Record 估算功率；先完成整场草算和失败率检查，再原子式输出。
pub fn fill_fit_virtual_power(
    data: &[u8],
    options: FitVirtualPowerFillOptions,
) -> Result<FitVirtualPowerFillResult, FitDecodeError> {
    fill_fit_virtual_power_with_weather(data, options, &[])
}

pub fn fill_fit_virtual_power_with_weather(
    data: &[u8],
    options: FitVirtualPowerFillOptions,
    stations: &[FitWeatherStation],
) -> Result<FitVirtualPowerFillResult, FitDecodeError> {
    let params = options.params;
    if ![
        params.total_mass_kg,
        params.cda,
        params.crr,
        params.drivetrain_loss_percent,
        params.air_density,
    ]
    .iter()
    .all(|v| v.is_finite())
        || params.total_mass_kg <= 0.0
        || params.cda <= 0.0
        || params.crr < 0.0
        || params.air_density <= 0.0
        || !(0.0..100.0).contains(&params.drivetrain_loss_percent)
    {
        return Err(FitDecodeError::InvalidFieldValue);
    }
    let mut document = FitDocument::parse(data)?;
    if !document
        .messages()
        .iter()
        .enumerate()
        .any(|(index, message)| {
            message.global_number() == SESSION
                && document.read_u8(index, SPORT_FIELD) == Some(CYCLING)
        })
    {
        return Ok(unchanged(data));
    }

    let mut records = document
        .messages()
        .iter()
        .enumerate()
        .filter(|(_, message)| message.global_number() == RECORD)
        .map(|(index, _)| index)
        .collect::<Vec<_>>();
    records.sort_by_key(|index| document.read_u32(*index, TIMESTAMP).unwrap_or(u32::MAX));
    if records.is_empty() {
        return Ok(unchanged(data));
    }

    let targets = records
        .iter()
        .map(|index| {
            options.mode == FitVirtualPowerFillMode::Overwrite
                || document.read_u16(*index, POWER).is_none()
        })
        .collect::<Vec<_>>();
    let attempted = targets.iter().filter(|target| **target).count();
    if attempted == 0 {
        return Ok(unchanged(data));
    }

    let kinematics = kinematics(&document, &records);
    let distance = document
        .messages()
        .iter()
        .enumerate()
        .find_map(|(i, m)| {
            (m.global_number() == SESSION)
                .then(|| document.read_u32(i, 9).map(|v| f64::from(v) / 100.0))
                .flatten()
        })
        .or_else(|| {
            records.iter().rev().find_map(|i| {
                document
                    .read_u32(*i, DISTANCE)
                    .map(|v| f64::from(v) / DISTANCE_SCALE)
            })
        });
    let record_duration = records
        .first()
        .and_then(|i| document.read_u32(*i, TIMESTAMP))
        .zip(
            records
                .last()
                .and_then(|i| document.read_u32(*i, TIMESTAMP)),
        )
        .map(|(start, end)| f64::from(end.saturating_sub(start)))
        .unwrap_or(0.0);
    let duration = document
        .messages()
        .iter()
        .enumerate()
        .find_map(|(i, m)| {
            (m.global_number() == SESSION)
                .then(|| document.read_u32(i, 8).map(|v| f64::from(v) / 1_000.0))
                .flatten()
        })
        .unwrap_or(record_duration);
    let shelter = crate::commute_wind_shelter_factor(distance, duration);
    let mut draft = vec![None; records.len()];
    let mut failed = vec![false; records.len()];
    for position in 0..records.len() {
        if !targets[position] {
            continue;
        }
        let index = records[position];
        if document
            .read_u8(index, CADENCE)
            .is_some_and(|cadence| f64::from(cadence) < COASTING_MAX_CADENCE_RPM)
        {
            draft[position] = Some(0);
            continue;
        }
        let Some(speed) = kinematics[position].speed else {
            failed[position] = true;
            continue;
        };
        if speed <= 0.1 {
            draft[position] = Some(0);
            continue;
        }
        let acceleration = if options.include_inertia {
            kinematics[position].acceleration
        } else {
            0.0
        };
        let mut params = options.params;
        let mut headwind = 0.0;
        if let Some(time) = document.read_u32(index, TIMESTAMP)
            && let Some(sample) = weather_at(
                i64::from(time) + 631_065_600,
                coordinate(&document, index),
                stations,
            )
        {
            let altitude = document
                .read_u16(index, ALTITUDE)
                .map(|v| f64::from(v) / ALTITUDE_SCALE - ALTITUDE_OFFSET)
                .or_else(|| {
                    document
                        .read_u32(index, ENHANCED_ALTITUDE)
                        .map(|v| f64::from(v) / ALTITUDE_SCALE - ALTITUDE_OFFSET)
                })
                .unwrap_or(0.0);
            let pressure = sample.pressure_msl_hpa
                * (-(9.8067 * 0.0289644 * altitude)
                    / (8.3144598 * (sample.temperature_c + 273.15)))
                    .exp();
            params.air_density = crate::air_density(
                sample.temperature_c,
                pressure,
                sample.relative_humidity_percent,
            );
            if let Some(previous) = position.checked_sub(1)
                && let Some(a) = coordinate(&document, records[previous])
                && let Some(b) = coordinate(&document, index)
                && haversine_meters(a.0, a.1, b.0, b.1) > 1.0
            {
                headwind = crate::headwind_mps(
                    crate::rider_height_wind_mps(sample.wind_speed_mps) * shelter,
                    sample.wind_from_degrees,
                    crate::bearing_degrees(a.0, a.1, b.0, b.1),
                );
            }
        }
        let watts = virtual_power_watts(
            speed,
            kinematics[position].grade,
            headwind,
            acceleration,
            params,
            document.read_u8(index, CADENCE).map(f64::from),
        );
        draft[position] = watts
            .is_finite()
            .then(|| watts.round().clamp(0.0, MAX_WRITABLE_POWER) as u16);
        failed[position] = draft[position].is_none();
    }

    for position in 0..records.len() {
        if failed[position] {
            draft[position] = neighbor_power(position, &records, &document, &draft, &failed);
        }
    }
    let failed_count = failed.iter().filter(|value| **value).count();
    if failed_count as f64 / attempted as f64 >= FAILURE_RATE_LIMIT {
        return Ok(FitVirtualPowerFillResult {
            data: data.to_vec(),
            filled_count: 0,
            failed_count,
            virtual_marked_count: 0,
            activity_rejected: true,
            power_source_virtual: false,
        });
    }

    let mut filled_count = 0;
    for (position, index) in records.iter().copied().enumerate() {
        if !targets[position] {
            continue;
        }
        if let Some(power) = draft[position] {
            document.set_or_insert_u16(index, POWER, power)?;
            filled_count += 1;
        } else if options.mode == FitVirtualPowerFillMode::Overwrite {
            document.remove_field(index, POWER);
        }
    }
    update_power_summaries(&mut document, &records)?;
    let marks = records
        .iter()
        .enumerate()
        .filter_map(|(position, index)| targets[position].then_some((*index, failed[position])))
        .collect::<Vec<_>>();
    document.mark_virtual_power(&marks)?;
    let data = document.to_bytes()?;
    Ok(FitVirtualPowerFillResult {
        data,
        filled_count,
        failed_count,
        virtual_marked_count: records
            .iter()
            .enumerate()
            .filter(|(position, _)| {
                targets[*position] && !failed[*position] && draft[*position].is_some()
            })
            .count(),
        activity_rejected: false,
        power_source_virtual: records.iter().enumerate().any(|(position, _)| {
            targets[position] && !failed[position] && draft[position].is_some()
        }),
    })
}

fn unchanged(data: &[u8]) -> FitVirtualPowerFillResult {
    FitVirtualPowerFillResult {
        data: data.to_vec(),
        filled_count: 0,
        failed_count: 0,
        virtual_marked_count: 0,
        activity_rejected: false,
        power_source_virtual: false,
    }
}

#[derive(Clone, Copy)]
struct Kinematics {
    speed: Option<f64>,
    grade: f64,
    acceleration: f64,
}

fn kinematics(document: &FitDocument, records: &[usize]) -> Vec<Kinematics> {
    let times = records
        .iter()
        .map(|index| document.read_u32(*index, TIMESTAMP).map(f64::from))
        .collect::<Vec<_>>();
    let speeds = records
        .iter()
        .map(|index| {
            document
                .read_u16(*index, SPEED)
                .map(|value| f64::from(value) / SPEED_SCALE)
                .or_else(|| {
                    document
                        .read_u32(*index, ENHANCED_SPEED)
                        .map(|value| f64::from(value) / SPEED_SCALE)
                })
        })
        .collect::<Vec<_>>();
    let speeds = replace_glitch_speeds_with_previous(&speeds, &times);
    let smoothed_speeds = smooth(&speeds, false);
    let altitudes = records
        .iter()
        .map(|index| {
            document
                .read_u16(*index, ALTITUDE)
                .map(|value| f64::from(value) / ALTITUDE_SCALE - ALTITUDE_OFFSET)
                .or_else(|| {
                    document
                        .read_u32(*index, ENHANCED_ALTITUDE)
                        .map(|value| f64::from(value) / ALTITUDE_SCALE - ALTITUDE_OFFSET)
                })
        })
        .collect::<Vec<_>>();
    let altitudes = smooth(&altitudes, true);

    (0..records.len())
        .map(|position| {
            let Some(previous) = position.checked_sub(1) else {
                return Kinematics {
                    speed: smoothed_speeds[position].or(speeds[position]),
                    grade: document
                        .read_i16(records[position], 9)
                        .map(|v| f64::from(v) / 100.0)
                        .unwrap_or(0.0),
                    acceleration: 0.0,
                };
            };
            let dt = match (times[previous], times[position]) {
                (Some(a), Some(b)) if b > a => b - a,
                _ => 0.0,
            };
            let distance = match (
                document.read_u32(records[previous], DISTANCE),
                document.read_u32(records[position], DISTANCE),
            ) {
                (Some(a), Some(b)) if b > a => f64::from(b - a) / DISTANCE_SCALE,
                _ => coordinate(document, records[previous])
                    .zip(coordinate(document, records[position]))
                    .map(|(a, b)| haversine_meters(a.0, a.1, b.0, b.1))
                    .unwrap_or_else(|| smoothed_speeds[position].unwrap_or(0.0) * dt),
            };
            let grade = document
                .read_i16(records[position], 9)
                .map(|v| f64::from(v) / 100.0)
                .unwrap_or_else(|| {
                    if dt <= 0.0 {
                        0.0
                    } else {
                        match (altitudes[previous], altitudes[position]) {
                            (Some(a), Some(b)) => grade_percent(b - a, distance),
                            _ => 0.0,
                        }
                    }
                });
            let acceleration = match (smoothed_speeds[previous], smoothed_speeds[position]) {
                (Some(a), Some(b)) => sanitized_acceleration_mps2((b - a) / dt.max(0.0), dt),
                _ => 0.0,
            };
            Kinematics {
                speed: smoothed_speeds[position].or(speeds[position]),
                grade,
                acceleration,
            }
        })
        .collect()
}

fn smooth(values: &[Option<f64>], fill_missing_center: bool) -> Vec<Option<f64>> {
    (0..values.len())
        .map(|position| {
            if values[position].is_none() && !fill_missing_center {
                return None;
            }
            let start = position.saturating_sub(2);
            let end = (position + 3).min(values.len());
            let samples = values[start..end].iter().flatten().collect::<Vec<_>>();
            (!samples.is_empty())
                .then(|| samples.iter().copied().sum::<f64>() / samples.len() as f64)
        })
        .collect()
}

fn neighbor_power(
    position: usize,
    records: &[usize],
    document: &FitDocument,
    draft: &[Option<u16>],
    failed: &[bool],
) -> Option<u16> {
    let center = document.read_u32(records[position], TIMESTAMP)?;
    let (minimum, maximum) = records
        .iter()
        .filter_map(|index| document.read_u32(*index, TIMESTAMP))
        .fold((center, center), |(minimum, maximum), value| {
            (minimum.min(value), maximum.max(value))
        });
    let maximum_radius = center
        .saturating_sub(minimum)
        .max(maximum.saturating_sub(center));
    let mut radius = NEIGHBOR_START_SECONDS;
    loop {
        let powers = records
            .iter()
            .enumerate()
            .filter_map(|(other, index)| {
                if other == position || failed[other] {
                    return None;
                }
                let timestamp = document.read_u32(*index, TIMESTAMP)?;
                (timestamp.abs_diff(center) <= radius)
                    .then_some(draft[other])
                    .flatten()
            })
            .collect::<Vec<_>>();
        if !powers.is_empty() {
            return Some(
                (powers.iter().map(|value| f64::from(*value)).sum::<f64>() / powers.len() as f64)
                    .round() as u16,
            );
        }
        if radius >= maximum_radius {
            return None;
        }
        radius = maximum_radius.min(radius.saturating_add(NEIGHBOR_START_SECONDS));
    }
}

fn update_power_summaries(
    document: &mut FitDocument,
    records: &[usize],
) -> Result<(), FitDecodeError> {
    let powers = records
        .iter()
        .filter_map(|index| document.read_u16(*index, POWER))
        .collect::<Vec<_>>();
    let session_indexes = document
        .messages()
        .iter()
        .enumerate()
        .filter_map(|(index, message)| (message.global_number() == SESSION).then_some(index))
        .collect::<Vec<_>>();
    if powers.is_empty() {
        for index in session_indexes {
            document.remove_field(index, AVG_POWER);
            document.remove_field(index, MAX_POWER);
        }
        return Ok(());
    }
    let average = (powers.iter().map(|value| u64::from(*value)).sum::<u64>() as f64
        / powers.len() as f64)
        .round() as u16;
    let maximum = *powers.iter().max().unwrap();
    for index in session_indexes {
        document.set_or_insert_u16(index, AVG_POWER, average)?;
        document.set_or_insert_u16(index, MAX_POWER, maximum)?;
    }
    let lap_indexes = document
        .messages()
        .iter()
        .enumerate()
        .filter_map(|(index, message)| (message.global_number() == LAP).then_some(index))
        .collect::<Vec<_>>();
    for index in lap_indexes {
        let start = document.read_u32(index, START_TIME);
        let end = document.read_u32(index, TIMESTAMP);
        let lap_powers = records
            .iter()
            .filter_map(|record| {
                let time = document.read_u32(*record, TIMESTAMP)?;
                (start.is_none_or(|value| time >= value) && end.is_none_or(|value| time <= value))
                    .then(|| document.read_u16(*record, POWER))
                    .flatten()
            })
            .collect::<Vec<_>>();
        if lap_powers.is_empty() {
            document.remove_field(index, LAP_AVG_POWER);
            document.remove_field(index, LAP_MAX_POWER);
            continue;
        }
        let lap_average = (lap_powers
            .iter()
            .map(|value| u64::from(*value))
            .sum::<u64>() as f64
            / lap_powers.len() as f64)
            .round() as u16;
        document.set_or_insert_u16(index, LAP_AVG_POWER, lap_average)?;
        document.set_or_insert_u16(index, LAP_MAX_POWER, *lap_powers.iter().max().unwrap())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{FitVirtualPowerFillMode, FitVirtualPowerFillOptions, fill_fit_virtual_power};
    use crate::{
        VirtualPowerParams,
        fit::{FitDocument, is_valid_fit},
    };

    fn options() -> FitVirtualPowerFillOptions {
        FitVirtualPowerFillOptions {
            params: VirtualPowerParams {
                total_mass_kg: 80.0,
                cda: 0.32,
                crr: 0.004,
                drivetrain_loss_percent: 2.0,
                air_density: 1.226,
            },
            include_inertia: false,
            mode: FitVirtualPowerFillMode::Overwrite,
        }
    }

    #[test]
    fn fills_records_updates_lap_and_session_and_preserves_unknown_payload() {
        let output =
            fill_fit_virtual_power(&cycling_fit(&[5_000, 5_000, 5_000]), options()).unwrap();
        assert_eq!(output.filled_count, 3);
        assert_eq!(output.failed_count, 0);
        assert_eq!(output.virtual_marked_count, 3);
        assert!(output.power_source_virtual);
        assert!(is_valid_fit(&output.data));
        let document = FitDocument::parse(&output.data).unwrap();
        let record = document
            .messages()
            .iter()
            .position(|m| m.global_number() == 20)
            .unwrap();
        assert_eq!(
            document.developer_field_bytes(record, 0, 0),
            Some(&b"virtual\0"[..])
        );
        assert_eq!(
            document.field_bytes(record, 99),
            Some(&[0xDE, 0xAD, 0xBE][..])
        );
        assert_eq!(document.read_u16(record, 7), Some(0)); // cadence 0 仍按滑行写 0 W。
        assert!(document.read_u16(record + 1, 7).is_some());
        assert_eq!(
            document.read_u16(record + 3, 20),
            document.read_u16(record + 4, 19)
        );
        assert_eq!(
            document.read_u16(record + 3, 21),
            document.read_u16(record + 4, 20)
        );
    }

    #[test]
    fn rejects_whole_activity_when_failure_rate_reaches_threshold() {
        let input = cycling_fit(&[u16::MAX; 10]);
        let output = fill_fit_virtual_power(&input, options()).unwrap();
        assert!(output.activity_rejected);
        assert_eq!(output.failed_count, 9); // 首秒 cadence=0，按滑行成功写 0W。
        assert_eq!(output.data, input);
    }

    #[test]
    fn native_grade_overrides_flat_altitude_and_marks_survive_repeated_fill() {
        let input = cycling_fit_with_grade(&[5_000; 3], 1_000);
        let climb = fill_fit_virtual_power(&input, options()).unwrap();
        let flat =
            fill_fit_virtual_power(&cycling_fit_with_grade(&[5_000; 3], 0), options()).unwrap();
        let climb_doc = FitDocument::parse(&climb.data).unwrap();
        let flat_doc = FitDocument::parse(&flat.data).unwrap();
        let record = climb_doc
            .messages()
            .iter()
            .position(|m| m.global_number() == 20)
            .unwrap();
        assert!(
            climb_doc.read_u16(record + 1, 7).unwrap()
                > flat_doc.read_u16(record + 1, 7).unwrap() + 300
        );
        let again = fill_fit_virtual_power(&climb.data, options()).unwrap();
        let again_doc = FitDocument::parse(&again.data).unwrap();
        assert_eq!(climb_doc.messages().len(), again_doc.messages().len());
        assert_eq!(again.virtual_marked_count, 3);
    }

    #[test]
    fn non_finite_parameters_do_not_silently_write_zero_power() {
        let mut params = options();
        params.params.total_mass_kg = f64::INFINITY;
        assert!(fill_fit_virtual_power(&cycling_fit(&[5_000; 3]), params).is_err());
    }

    #[test]
    fn hourly_wind_reaches_power_and_uses_garmin_epoch() {
        let input = cycling_fit(&[5_000; 3]);
        let station = super::FitWeatherStation {
            latitude: 0.0,
            longitude: 0.0,
            samples: vec![
                crate::weather::WeatherSample {
                    time_seconds: 631_066_600,
                    temperature_c: 20.0,
                    relative_humidity_percent: 50.0,
                    pressure_msl_hpa: 1013.25,
                    wind_speed_mps: 0.0,
                    wind_from_degrees: 90.0,
                },
                crate::weather::WeatherSample {
                    time_seconds: 631_066_602,
                    temperature_c: 20.0,
                    relative_humidity_percent: 50.0,
                    pressure_msl_hpa: 1013.25,
                    wind_speed_mps: 10.0,
                    wind_from_degrees: 90.0,
                },
            ],
        };
        let windy =
            super::fill_fit_virtual_power_with_weather(&input, options(), &[station]).unwrap();
        let calm = fill_fit_virtual_power(&input, options()).unwrap();
        let windy_doc = FitDocument::parse(&windy.data).unwrap();
        let calm_doc = FitDocument::parse(&calm.data).unwrap();
        let record = windy_doc
            .messages()
            .iter()
            .position(|m| m.global_number() == 20)
            .unwrap();
        assert!(
            windy_doc.read_u16(record + 2, 7).unwrap()
                > calm_doc.read_u16(record + 2, 7).unwrap() + 50
        );
    }

    fn cycling_fit(speeds: &[u16]) -> Vec<u8> {
        cycling_fit_with_grade(speeds, i16::MAX)
    }

    fn cycling_fit_with_grade(speeds: &[u16], grade: i16) -> Vec<u8> {
        let mut data = Vec::new();
        definition(
            &mut data,
            0,
            20,
            &[
                (253, 4, 0x86),
                (0, 4, 0x85),
                (1, 4, 0x85),
                (2, 2, 0x84),
                (4, 1, 0x02),
                (6, 2, 0x84),
                (7, 2, 0x84),
                (9, 2, 0x83),
                (99, 3, 0x0D),
            ],
        );
        for (index, speed) in speeds.iter().enumerate() {
            data.push(0);
            data.extend_from_slice(&(1_000 + index as u32).to_le_bytes());
            data.extend_from_slice(&0i32.to_le_bytes());
            data.extend_from_slice(&(index as i32 * 1_000).to_le_bytes());
            data.extend_from_slice(&2_500u16.to_le_bytes());
            data.push((index != 0) as u8 * 80);
            data.extend_from_slice(&speed.to_le_bytes());
            data.extend_from_slice(&123u16.to_le_bytes());
            data.extend_from_slice(&grade.to_le_bytes());
            data.extend_from_slice(&[0xDE, 0xAD, 0xBE]);
        }
        definition(
            &mut data,
            1,
            18,
            &[(5, 1, 0x00), (20, 2, 0x84), (21, 2, 0x84)],
        );
        data.push(1);
        data.extend_from_slice(&[2]);
        data.extend_from_slice(&11u16.to_le_bytes());
        data.extend_from_slice(&12u16.to_le_bytes());
        definition(
            &mut data,
            2,
            19,
            &[(2, 4, 0x86), (253, 4, 0x86), (19, 2, 0x84), (20, 2, 0x84)],
        );
        data.push(2);
        data.extend_from_slice(&1_000u32.to_le_bytes());
        data.extend_from_slice(&(1_000 + speeds.len() as u32 - 1).to_le_bytes());
        data.extend_from_slice(&13u16.to_le_bytes());
        data.extend_from_slice(&14u16.to_le_bytes());
        fit_file(&data)
    }

    fn definition(data: &mut Vec<u8>, local: u8, global: u16, fields: &[(u8, u8, u8)]) {
        data.push(0x40 | local);
        data.extend_from_slice(&[0, 0]);
        data.extend_from_slice(&global.to_le_bytes());
        data.push(fields.len() as u8);
        for &(number, size, base_type) in fields {
            data.extend_from_slice(&[number, size, base_type]);
        }
    }

    fn fit_file(data: &[u8]) -> Vec<u8> {
        let mut bytes = vec![14, 0x20, 0x54, 0x08];
        bytes.extend_from_slice(&(data.len() as u32).to_le_bytes());
        bytes.extend_from_slice(b".FIT");
        bytes.extend_from_slice(&super::super::crc16(&bytes).to_le_bytes());
        bytes.extend_from_slice(data);
        bytes.extend_from_slice(&super::super::crc16(&bytes).to_le_bytes());
        bytes
    }
}
