#[path = "fit_document.rs"]
mod fit_document;
#[path = "fit_merge.rs"]
mod fit_merge;
#[path = "health_fit.rs"]
mod health_fit;

pub use fit_document::{FitDocument, FitMessage, MAX_FIT_BYTES};
pub use fit_merge::{
    FitMergeError, MAX_MERGE_INPUT_BYTES, MAX_MERGE_SUPPLEMENTS, merge_fit_sensors,
};
pub use health_fit::{HealthFitError, encode_health_workout_bundle_json};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FitDecodeError {
    NotFit,
    Truncated,
    InvalidCrc,
    InvalidDefinition,
    MissingDefinition(u8),
    InvalidCompressedTimestamp,
    TooLarge,
    TooManyMessages,
    TooManyFields,
    OutputTooLarge,
    FieldNotFound,
    InvalidFieldValue,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct FitContentSummary {
    pub gps_point_count: usize,
    pub heart_rate_point_count: usize,
}

/// FIT-07 的保守修复结果：没有确认尖峰时 `data` 与输入逐字节相同。
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FitSpeedSpikeFixResult {
    pub data: Vec<u8>,
    pub fixed_count: usize,
}

pub const MAX_REASONABLE_SPEED_MPS: f64 = 80.0 / 3.6;
const MAX_SPIKE_GAP_SECONDS: u32 = 8;
const SPEED_SCALE: f64 = 1_000.0;
const DISTANCE_SCALE: f64 = 100.0;
const SEMICIRCLES_PER_DEGREE: f64 = 2_147_483_648.0 / 180.0;

impl FitContentSummary {
    pub const fn quality_score(self) -> usize {
        self.gps_point_count * 10 + self.heart_rate_point_count
    }
}

/// 校验并解码单个 FIT 文件，返回与 Swift `FitContentProbe` 对等的内容摘要。
pub fn decode_fit(data: &[u8]) -> Result<FitContentSummary, FitDecodeError> {
    let document = FitDocument::parse(data)?;
    let mut summary = FitContentSummary::default();
    for (index, message) in document.messages().iter().enumerate() {
        if message.global_number() != 20 {
            continue;
        }
        let latitude = document.read_i32(index, 0);
        let longitude = document.read_i32(index, 1);
        if latitude.is_some_and(|value| value != i32::MAX)
            && longitude.is_some_and(|value| value != i32::MAX)
        {
            summary.gps_point_count += 1;
        }
        if document
            .read_u8(index, 3)
            .is_some_and(|value| value != u8::MAX)
        {
            summary.heart_rate_point_count += 1;
        }
    }
    Ok(summary)
}

/// 严格有效性检查：除 `.FIT` 文件头外，同时验证长度、消息边界和 CRC。
pub fn is_valid_fit(data: &[u8]) -> bool {
    decode_fit(data).is_ok()
}

/// 当前无修改参数：严格校验后原样输出，未知消息、数组字段和 developer fields 不会丢失。
pub fn reencode_fit(data: &[u8]) -> Result<Vec<u8>, FitDecodeError> {
    FitDocument::parse(data)?.to_bytes()
}

/// 修复短间隔内已由位置、距离或速度字段证明的离谱速度尖峰。
///
/// 只修改标准 Record（global 20）中已经存在的速度、位置和距离字段；未知字段、
/// developer fields 与无尖峰文件保持原样，输出由 `FitDocument` 重算 FIT CRC。
pub fn fix_fit_speed_spikes(data: &[u8]) -> Result<FitSpeedSpikeFixResult, FitDecodeError> {
    let mut document = FitDocument::parse(data)?;
    let mut record_indexes = document
        .messages()
        .iter()
        .enumerate()
        .filter_map(|(index, message)| {
            (message.global_number() == 20)
                .then(|| {
                    document
                        .read_u32(index, 253)
                        .map(|timestamp| (timestamp, index))
                })
                .flatten()
        })
        .collect::<Vec<_>>();
    record_indexes.sort_unstable();
    if record_indexes.len() < 2 {
        return Ok(FitSpeedSpikeFixResult {
            data: data.to_vec(),
            fixed_count: 0,
        });
    }

    let mut fixed_count = 0;
    for _ in 0..5 {
        let activity_average =
            activity_average_speed_mps(&document, &record_indexes).unwrap_or(5.0);
        let mut fixed_this_pass = 0;
        for pair in record_indexes.windows(2) {
            let (previous_time, previous) = pair[0];
            let (current_time, current) = pair[1];
            let Some(gap) = current_time.checked_sub(previous_time) else {
                continue;
            };
            if gap == 0 || gap > MAX_SPIKE_GAP_SECONDS {
                continue;
            }
            let implied = implied_speed_mps(&document, previous, current, gap);
            let field_speed = record_speed_mps(&document, current);
            if implied
                .unwrap_or_default()
                .max(field_speed.unwrap_or_default())
                <= MAX_REASONABLE_SPEED_MPS
            {
                continue;
            }

            let average = neighbor_average_speed_mps(&document, &record_indexes, current)
                .unwrap_or(activity_average)
                .clamp(0.0, MAX_REASONABLE_SPEED_MPS);
            apply_spike_fix(&mut document, previous, current, gap, average, implied)?;
            fixed_this_pass += 1;
        }
        fixed_count += fixed_this_pass;
        if fixed_this_pass == 0 {
            break;
        }
    }

    Ok(FitSpeedSpikeFixResult {
        data: document.to_bytes()?,
        fixed_count,
    })
}

fn apply_spike_fix(
    document: &mut FitDocument,
    previous: usize,
    current: usize,
    gap_seconds: u32,
    average_speed_mps: f64,
    implied_speed_mps: Option<f64>,
) -> Result<(), FitDecodeError> {
    let speed_raw = (average_speed_mps * SPEED_SCALE).round() as u64;
    if document.read_u16(current, 6).is_some() {
        document.set_u16(
            current,
            6,
            u16::try_from(speed_raw).map_err(|_| FitDecodeError::InvalidFieldValue)?,
        )?;
    }
    if document.read_u32(current, 73).is_some() {
        document.set_u32(
            current,
            73,
            u32::try_from(speed_raw).map_err(|_| FitDecodeError::InvalidFieldValue)?,
        )?;
    }

    if implied_speed_mps.is_some_and(|speed| speed > MAX_REASONABLE_SPEED_MPS)
        && let (Some(latitude), Some(longitude), Some(_), Some(_)) = (
            document.read_i32(previous, 0),
            document.read_i32(previous, 1),
            document.read_i32(current, 0),
            document.read_i32(current, 1),
        )
    {
        document.set_i32(current, 0, latitude)?;
        document.set_i32(current, 1, longitude)?;
    }
    if let (Some(previous_distance), Some(_)) = (
        document.read_u32(previous, 5),
        document.read_u32(current, 5),
    ) {
        let distance_raw =
            (average_speed_mps * f64::from(gap_seconds) * DISTANCE_SCALE).round() as u64;
        if let Some(distance) = u64::from(previous_distance).checked_add(distance_raw)
            && let Ok(distance) = u32::try_from(distance)
        {
            document.set_u32(current, 5, distance)?;
        }
    }
    Ok(())
}

fn record_speed_mps(document: &FitDocument, index: usize) -> Option<f64> {
    document
        .read_u16(index, 6)
        .map(|value| f64::from(value) / SPEED_SCALE)
        .or_else(|| {
            document
                .read_u32(index, 73)
                .map(|value| f64::from(value) / SPEED_SCALE)
        })
}

fn implied_speed_mps(
    document: &FitDocument,
    previous: usize,
    current: usize,
    gap_seconds: u32,
) -> Option<f64> {
    if let (Some(lat0), Some(lon0), Some(lat1), Some(lon1)) = (
        document.read_i32(previous, 0),
        document.read_i32(previous, 1),
        document.read_i32(current, 0),
        document.read_i32(current, 1),
    ) {
        return Some(
            haversine_meters(
                f64::from(lat0) / SEMICIRCLES_PER_DEGREE,
                f64::from(lon0) / SEMICIRCLES_PER_DEGREE,
                f64::from(lat1) / SEMICIRCLES_PER_DEGREE,
                f64::from(lon1) / SEMICIRCLES_PER_DEGREE,
            ) / f64::from(gap_seconds),
        );
    }
    let (previous_distance, current_distance) = (
        document.read_u32(previous, 5)?,
        document.read_u32(current, 5)?,
    );
    current_distance
        .checked_sub(previous_distance)
        .map(|delta| f64::from(delta) / DISTANCE_SCALE / f64::from(gap_seconds))
}

fn neighbor_average_speed_mps(
    document: &FitDocument,
    record_indexes: &[(u32, usize)],
    current: usize,
) -> Option<f64> {
    let position = record_indexes
        .iter()
        .position(|(_, index)| *index == current)?;
    let start = position.saturating_sub(8);
    let end = (position + 9).min(record_indexes.len());
    let speeds = record_indexes[start..end]
        .iter()
        .filter_map(|(_, index)| {
            (*index != current)
                .then(|| record_speed_mps(document, *index))
                .flatten()
        })
        .filter(|speed| *speed <= MAX_REASONABLE_SPEED_MPS)
        .collect::<Vec<_>>();
    (!speeds.is_empty()).then(|| speeds.iter().sum::<f64>() / speeds.len() as f64)
}

fn activity_average_speed_mps(
    document: &FitDocument,
    record_indexes: &[(u32, usize)],
) -> Option<f64> {
    let speeds = record_indexes
        .iter()
        .filter_map(|(_, index)| record_speed_mps(document, *index))
        .filter(|speed| *speed > 0.0 && *speed <= MAX_REASONABLE_SPEED_MPS)
        .collect::<Vec<_>>();
    if speeds.len() >= 5 {
        return Some(speeds.iter().sum::<f64>() / speeds.len() as f64);
    }
    let (first_time, first_index) = *record_indexes.first()?;
    let (last_time, last_index) = *record_indexes.last()?;
    let (first_distance, last_distance) = (
        document.read_u32(first_index, 5)?,
        document.read_u32(last_index, 5)?,
    );
    last_time
        .checked_sub(first_time)
        .filter(|duration| *duration > 0)
        .and_then(|duration| {
            last_distance
                .checked_sub(first_distance)
                .map(|distance| f64::from(distance) / DISTANCE_SCALE / f64::from(duration))
        })
        .or_else(|| (!speeds.is_empty()).then(|| speeds.iter().sum::<f64>() / speeds.len() as f64))
}

fn haversine_meters(latitude0: f64, longitude0: f64, latitude1: f64, longitude1: f64) -> f64 {
    let latitude0 = latitude0.to_radians();
    let latitude1 = latitude1.to_radians();
    let delta_latitude = latitude1 - latitude0;
    let delta_longitude = (longitude1 - longitude0).to_radians();
    let a = (delta_latitude / 2.0).sin().powi(2)
        + latitude0.cos() * latitude1.cos() * (delta_longitude / 2.0).sin().powi(2);
    2.0 * 6_371_000.0 * a.sqrt().min(1.0).asin()
}

fn crc16(bytes: &[u8]) -> u16 {
    const TABLE: [u16; 16] = [
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401, 0xA001, 0x6C00, 0x7800,
        0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    ];
    bytes.iter().fold(0, |mut crc, &byte| {
        crc = (crc >> 4) ^ TABLE[((crc ^ u16::from(byte)) & 0xF) as usize];
        (crc >> 4) ^ TABLE[((crc ^ u16::from(byte >> 4)) & 0xF) as usize]
    })
}

#[cfg(test)]
mod tests {
    use super::{
        FitContentSummary, FitDecodeError, FitDocument, MAX_FIT_BYTES, decode_fit,
        fix_fit_speed_spikes, is_valid_fit, reencode_fit,
    };

    // 当前项目锁定的 FITSwiftSDK Encoder 生成：一个含时间、经纬度和心率的 Record。
    const SWIFT_RECORD_FIT: &[u8] = &[
        0x0E, 0x20, 0xD5, 0x52, 0x20, 0, 0, 0, 0x2E, 0x46, 0x49, 0x54, 0x6F, 0x47, 0x40, 0, 0,
        0x14, 0, 4, 0xFD, 4, 0x86, 0, 4, 0x85, 1, 4, 0x85, 3, 1, 2, 0, 0x11, 0x22, 0x33, 0x44, 4,
        3, 2, 1, 8, 7, 6, 5, 0x8C, 0xD9, 0xFB,
    ];

    #[test]
    fn rejects_non_fit_and_truncated_header() {
        assert_eq!(
            decode_fit(br#"{ "error": true }"#),
            Err(FitDecodeError::NotFit)
        );
        assert_eq!(decode_fit(&[14; 11]), Err(FitDecodeError::Truncated));
    }

    #[test]
    fn validates_header_and_file_crc() {
        let valid = SWIFT_RECORD_FIT.to_vec();
        assert!(is_valid_fit(&valid));

        let mut bad_header_crc = valid.clone();
        bad_header_crc[1] ^= 1;
        assert_eq!(decode_fit(&bad_header_crc), Err(FitDecodeError::InvalidCrc));

        let mut bad_file_crc = valid;
        let data_byte = bad_file_crc.len() - 3;
        bad_file_crc[data_byte] ^= 1;
        assert_eq!(decode_fit(&bad_file_crc), Err(FitDecodeError::InvalidCrc));
    }

    #[test]
    fn rejects_truncated_definition_and_data_message_with_valid_crc() {
        let truncated_definition = fit_file(&[0x40, 0, 0, 20, 0, 1, 0, 4]);
        assert_eq!(
            decode_fit(&truncated_definition),
            Err(FitDecodeError::Truncated)
        );

        let truncated_message = fit_file(&[
            0x40, 0, 0, 20, 0, 1, 3, 1, 0x02, // Record 定义
            0x00, // 缺少一个 heart_rate 字节
        ]);
        assert_eq!(
            decode_fit(&truncated_message),
            Err(FitDecodeError::Truncated)
        );
    }

    #[test]
    fn matches_swift_fixed_sample_content_score() {
        let summary = decode_fit(SWIFT_RECORD_FIT).unwrap();
        assert_eq!(
            summary,
            FitContentSummary {
                gps_point_count: 1,
                heart_rate_point_count: 1
            }
        );
        assert_eq!(summary.quality_score(), 11);
    }

    #[test]
    fn lossless_reencode_preserves_unknown_array_field() {
        let input = fit_file(&[
            0x40, 0, 0, 0x34, 0x12, 1, // 未知 global message 0x1234
            77, 3, 0x0D, // 未知数组字段，3 个 byte
            0x00, 0xA1, 0xB2, 0xC3,
        ]);
        assert_eq!(reencode_fit(&input).unwrap(), input);
    }

    #[test]
    fn fixes_only_a_short_interval_proven_speed_spike_and_keeps_unknown_payload() {
        let input = spike_fit(1);
        let fixed = fix_fit_speed_spikes(&input).unwrap();
        // 与 Swift 一致：回退中间瞬移点后，紧随其后的远端点也会在同一轮处理。
        assert_eq!(fixed.fixed_count, 2);
        assert!(is_valid_fit(&fixed.data));

        let document = FitDocument::parse(&fixed.data).unwrap();
        let middle = document
            .messages()
            .iter()
            .enumerate()
            .find_map(|(index, message)| {
                (message.global_number() == 20 && document.read_u32(index, 253) == Some(1_001))
                    .then_some(index)
            })
            .unwrap();
        assert_eq!(document.read_u16(middle, 6), Some(5_000));
        assert_eq!(document.read_i32(middle, 0), document.read_i32(0, 0));
        assert_eq!(document.read_i32(middle, 1), document.read_i32(0, 1));
        assert_eq!(document.read_u32(middle, 5), Some(500));
        assert_eq!(
            document.field_bytes(middle, 99),
            Some(&[0xDE, 0xAD, 0xBE][..])
        );
    }

    #[test]
    fn leaves_long_gap_spikes_byte_for_byte_unchanged() {
        let input = spike_fit(9);
        assert_eq!(
            fix_fit_speed_spikes(&input).unwrap(),
            super::FitSpeedSpikeFixResult {
                data: input,
                fixed_count: 0,
            }
        );
    }

    #[test]
    fn accepts_12_byte_header_and_zero_14_byte_header_crc() {
        let data = [
            0x40, 0, 0, 20, 0, 1, 3, 1, 0x02, // Record + heart_rate
            0x00, 140,
        ];
        let twelve_byte_header = fit_file_with_header(&data, 12, false);
        assert_eq!(
            decode_fit(&twelve_byte_header)
                .unwrap()
                .heart_rate_point_count,
            1
        );
        assert_eq!(
            reencode_fit(&twelve_byte_header).unwrap(),
            twelve_byte_header
        );

        let zero_header_crc = fit_file_with_header(&data, 14, true);
        assert_eq!(
            decode_fit(&zero_header_crc).unwrap().heart_rate_point_count,
            1
        );
        assert_eq!(reencode_fit(&zero_header_crc).unwrap(), zero_header_crc);
    }

    #[test]
    fn replacing_local_definition_changes_following_message_shape() {
        let input = fit_file(&[
            0x40, 0, 0, 20, 0, 1, // local 0 = Record
            3, 1, 0x02, // heart_rate
            0x00, 140, 0x40, 0, 0, 0x34, 0x12, 1, // local 0 改为未知消息
            77, 3, 0x0D, // 三字节数组字段
            0x00, 0xA1, 0xB2, 0xC3,
        ]);
        assert_eq!(
            decode_fit(&input).unwrap(),
            FitContentSummary {
                gps_point_count: 0,
                heart_rate_point_count: 1,
            }
        );
        assert_eq!(reencode_fit(&input).unwrap(), input);
    }

    #[test]
    fn expands_compressed_timestamp_and_reencodes_canonically_after_edit() {
        let input = fit_file(&[
            0x41,
            0,
            0,
            20,
            0,
            1, // local 1 = 带完整 timestamp 的 Record
            253,
            4,
            0x86,
            0x01,
            0xE8,
            0x03,
            0,
            0, // t=1000
            0x40,
            0,
            0,
            20,
            0,
            1, // local 0 = 省略 timestamp、供压缩头使用的 Record
            3,
            1,
            0x02, // heart_rate
            0x80 | 9,
            141, // compressed t=1001 (low five bits = 9)
        ]);
        let mut document = FitDocument::parse(&input).unwrap();
        assert_eq!(document.messages().len(), 2);
        assert_eq!(document.read_u32(0, 253), Some(1000));
        assert_eq!(document.read_u32(1, 253), Some(1001));
        assert_eq!(document.read_u8(1, 3), Some(141));

        document.set_u8(1, 3, 150).unwrap();
        let output = document.to_bytes().unwrap();
        assert_ne!(output, input);
        let reparsed = FitDocument::parse(&output).unwrap();
        assert_eq!(reparsed.read_u32(1, 253), Some(1001));
        assert_eq!(reparsed.read_u8(1, 3), Some(150));
    }

    #[test]
    fn compressed_timestamp_can_start_from_zero_without_a_full_timestamp() {
        let input = fit_file(&[
            0x40,
            0,
            0,
            20,
            0,
            1, // local 0 = 省略 timestamp 的 Record
            3,
            1,
            0x02, // heart_rate
            0x80 | 17,
            141,
        ]);
        let mut document = FitDocument::parse(&input).unwrap();
        assert_eq!(document.read_u32(0, 253), Some(17));
        assert_eq!(document.read_u8(0, 3), Some(141));

        document.set_u8(0, 3, 150).unwrap();
        let reparsed = FitDocument::parse(&document.to_bytes().unwrap()).unwrap();
        assert_eq!(reparsed.read_u32(0, 253), Some(17));
        assert_eq!(reparsed.read_u8(0, 3), Some(150));
    }

    #[test]
    fn edited_native_field_preserves_unknown_array_and_developer_payload() {
        let input = fit_file(&[
            0x60, 0, 0, 0x34, 0x12, 2, // 未知 global message，含 developer definition
            77, 3, 0x0D, // 未知 byte 数组
            78, 2, 0x84, // 未知 u16
            1,    // developer field count
            9, 4, 7, // field 9, size 4, developer_data_index 7
            0x00, 0xA1, 0xB2, 0xC3, // native array
            0x34, 0x12, // native u16
            0xDE, 0xAD, 0xBE, 0xEF, // developer payload
        ]);
        let mut document = FitDocument::parse(&input).unwrap();
        assert_eq!(document.read_u16(0, 78), Some(0x1234));
        assert_eq!(document.field_bytes(0, 77), Some(&[0xA1, 0xB2, 0xC3][..]));
        assert_eq!(
            document.developer_field_bytes(0, 9, 7),
            Some(&[0xDE, 0xAD, 0xBE, 0xEF][..])
        );

        document.set_u16(0, 78, 0x5678).unwrap();
        let output = document.to_bytes().unwrap();
        let reparsed = FitDocument::parse(&output).unwrap();
        assert_eq!(reparsed.read_u16(0, 78), Some(0x5678));
        assert_eq!(reparsed.field_bytes(0, 77), Some(&[0xA1, 0xB2, 0xC3][..]));
        assert_eq!(
            reparsed.developer_field_bytes(0, 9, 7),
            Some(&[0xDE, 0xAD, 0xBE, 0xEF][..])
        );
    }

    #[test]
    fn typed_read_and_edit_respect_big_endian_definition() {
        let input = fit_file(&[
            0x40, 0, 1, 0x12, 0x34, 2, // big-endian unknown message
            1, 4, 0x85, // sint32
            2, 2, 0x84, // uint16
            0x00, 0xFF, 0xFF, 0xFF, 0x9C, 0x12, 0x34,
        ]);
        let mut document = FitDocument::parse(&input).unwrap();
        assert_eq!(document.read_i32(0, 1), Some(-100));
        assert_eq!(document.read_u16(0, 2), Some(0x1234));
        document.set_i32(0, 1, -200).unwrap();
        document.set_u16(0, 2, 0x5678).unwrap();
        let reparsed = FitDocument::parse(&document.to_bytes().unwrap()).unwrap();
        assert_eq!(reparsed.read_i32(0, 1), Some(-200));
        assert_eq!(reparsed.read_u16(0, 2), Some(0x5678));
    }

    #[test]
    fn typed_access_rejects_wrong_base_types_and_maps_invalid_sentinels_to_none() {
        let input = fit_file(&[
            0x40, 0, 0, 0x34, 0x12, 7, 1, 1, 0x02, // uint8 invalid = 0xFF
            2, 1, 0x0A, // uint8z invalid = 0
            3, 2, 0x84, // uint16 invalid = 0xFFFF
            4, 2, 0x8B, // uint16z invalid = 0
            5, 4, 0x85, // sint32 invalid = 0x7FFFFFFF
            6, 4, 0x86, // uint32 invalid = 0xFFFFFFFF
            7, 4, 0x8C, // uint32z invalid = 0
            0x00, 0xFF, 0, 0xFF, 0xFF, 0, 0, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0,
            0, 0,
        ]);
        let mut document = FitDocument::parse(&input).unwrap();
        assert_eq!(document.read_u8(0, 1), None);
        assert_eq!(document.read_u8(0, 2), None);
        assert_eq!(document.read_u16(0, 3), None);
        assert_eq!(document.read_u16(0, 4), None);
        assert_eq!(document.read_i32(0, 5), None);
        assert_eq!(document.read_u32(0, 6), None);
        assert_eq!(document.read_u32(0, 7), None);
        assert_eq!(document.read_u16(0, 1), None);
        assert_eq!(
            document.set_u16(0, 1, 1),
            Err(FitDecodeError::InvalidFieldValue)
        );
        assert_eq!(
            document.set_u8(0, 1, u8::MAX),
            Err(FitDecodeError::InvalidFieldValue)
        );
        assert_eq!(
            document.set_u16(0, 3, u16::MAX),
            Err(FitDecodeError::InvalidFieldValue)
        );
        assert_eq!(
            document.set_i32(0, 5, i32::MAX),
            Err(FitDecodeError::InvalidFieldValue)
        );
        assert_eq!(
            document.set_u32(0, 7, 0),
            Err(FitDecodeError::InvalidFieldValue)
        );
        document.set_u16(0, 3, 42).unwrap();
        assert_eq!(document.read_u16(0, 3), Some(42));
    }

    #[test]
    fn enforces_input_and_field_shape_limits() {
        assert!(matches!(
            FitDocument::parse(&vec![0; MAX_FIT_BYTES + 1]),
            Err(FitDecodeError::TooLarge)
        ));
        let input = fit_file(&[
            0x40, 0, 0, 20, 0, 1, 3, 1, 0x02, // heart rate
            0x00, 140,
        ]);
        let mut document = FitDocument::parse(&input).unwrap();
        assert_eq!(
            document.set_field_bytes(0, 3, &[1, 2]),
            Err(FitDecodeError::InvalidFieldValue)
        );
        assert_eq!(
            document.set_u8(0, 99, 1),
            Err(FitDecodeError::FieldNotFound)
        );

        let zero_native_field = fit_file(&[
            0x40, 0, 0, 20, 0, 1, 3, 0, 0x02, // 零长度原生字段
        ]);
        assert_eq!(
            FitDocument::parse(&zero_native_field).unwrap_err(),
            FitDecodeError::InvalidDefinition
        );
        let zero_developer_field = fit_file(&[
            0x60, 0, 0, 20, 0, 0, 1, 3, 0, 0, // 零长度 developer field
        ]);
        assert_eq!(
            FitDocument::parse(&zero_developer_field).unwrap_err(),
            FitDecodeError::InvalidDefinition
        );
    }

    fn fit_file(data: &[u8]) -> Vec<u8> {
        fit_file_with_header(data, 14, false)
    }

    fn spike_fit(gap_seconds: u32) -> Vec<u8> {
        let mut data = vec![
            0x40, 0, 0, 20, 0, 6, // Record definition
            253, 4, 0x86, // timestamp
            0, 4, 0x85, // position_lat
            1, 4, 0x85, // position_long
            5, 4, 0x86, // distance (cm)
            6, 2, 0x84, // speed (m/s * 1000)
            99, 3, 0x0D, // 未知 byte 数组
        ];
        let latitude0 = (31.0_f64 * 2_147_483_648.0 / 180.0).round() as i32;
        let latitude1 = (31.045_f64 * 2_147_483_648.0 / 180.0).round() as i32;
        let longitude = (120.0_f64 * 2_147_483_648.0 / 180.0).round() as i32;
        append_spike_record(&mut data, 1_000, latitude0, longitude, 0, 5_000, [1, 2, 3]);
        append_spike_record(
            &mut data,
            1_000 + gap_seconds,
            latitude1,
            longitude,
            500_000,
            60_000,
            [0xDE, 0xAD, 0xBE],
        );
        append_spike_record(
            &mut data,
            1_000 + gap_seconds + 1,
            latitude1 + 1_193,
            longitude,
            500_500,
            5_000,
            [4, 5, 6],
        );
        fit_file(&data)
    }

    fn append_spike_record(
        data: &mut Vec<u8>,
        timestamp: u32,
        latitude: i32,
        longitude: i32,
        distance: u32,
        speed: u16,
        unknown: [u8; 3],
    ) {
        data.push(0);
        data.extend_from_slice(&timestamp.to_le_bytes());
        data.extend_from_slice(&latitude.to_le_bytes());
        data.extend_from_slice(&longitude.to_le_bytes());
        data.extend_from_slice(&distance.to_le_bytes());
        data.extend_from_slice(&speed.to_le_bytes());
        data.extend_from_slice(&unknown);
    }

    fn fit_file_with_header(data: &[u8], header_size: u8, zero_header_crc: bool) -> Vec<u8> {
        assert!(matches!(header_size, 12 | 14));
        let mut bytes = vec![header_size, 0x20, 0x54, 0x08];
        bytes.extend_from_slice(&(data.len() as u32).to_le_bytes());
        bytes.extend_from_slice(b".FIT");
        if header_size == 14 {
            let header_crc = if zero_header_crc { 0 } else { crc16(&bytes) };
            bytes.extend_from_slice(&header_crc.to_le_bytes());
        }
        bytes.extend_from_slice(data);
        let file_crc = crc16(&bytes);
        bytes.extend_from_slice(&file_crc.to_le_bytes());
        bytes
    }

    fn crc16(bytes: &[u8]) -> u16 {
        const TABLE: [u16; 16] = [
            0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401, 0xA001, 0x6C00, 0x7800,
            0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
        ];
        bytes.iter().fold(0, |mut crc, &byte| {
            crc = (crc >> 4) ^ TABLE[((crc ^ u16::from(byte)) & 0xF) as usize];
            (crc >> 4) ^ TABLE[((crc ^ u16::from(byte >> 4)) & 0xF) as usize]
        })
    }
}
