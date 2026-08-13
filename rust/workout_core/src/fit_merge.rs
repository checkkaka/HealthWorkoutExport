use std::collections::{HashMap, HashSet};

use crate::fit_alignment::{FitAlignmentError, FitStaticAlignment, resolve_static_offsets};

use super::{FitDecodeError, FitDocument, MAX_FIT_BYTES};

/// 合并时最多接收的补源文件数与总输入；避免多份恶意 FIT 同时放大内存。
pub const MAX_MERGE_SUPPLEMENTS: usize = 8;
pub const MAX_MERGE_INPUT_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq)]
pub enum FitMergeError {
    NeedSupplement,
    TooManySupplements,
    InputTooLarge,
    InvalidFit(FitDecodeError),
    Alignment(FitAlignmentError),
    DeveloperIndexExhausted,
}

impl From<FitAlignmentError> for FitMergeError {
    fn from(value: FitAlignmentError) -> Self {
        Self::Alignment(value)
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum FitSupplementMode {
    FillRecords,
    #[default]
    SensorsOnly,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FitMergeOptions {
    pub supplement_mode: FitSupplementMode,
    pub alignment: FitStaticAlignment,
}

impl Default for FitMergeOptions {
    fn default() -> Self {
        Self {
            supplement_mode: FitSupplementMode::SensorsOnly,
            alignment: FitStaticAlignment::Absolute,
        }
    }
}

impl From<FitDecodeError> for FitMergeError {
    fn from(value: FitDecodeError) -> Self {
        Self::InvalidFit(value)
    }
}

/// 主源优先的传感器补源合并。
///
/// 仅对已有且同秒的 Record 补心率、踏频、功率、温度，并对已有 Session
/// 补平均/最大心率、踏频和功率；主源已有值与未知字段始终不改写，也不插入记录。
/// 不处理时钟偏移、GPS/距离、Event、Lap 或 developer fields：这些语义无法安全推断。
pub fn merge_fit_sensors(primary: &[u8], supplements: &[&[u8]]) -> Result<Vec<u8>, FitMergeError> {
    merge_fit(primary, supplements, &FitMergeOptions::default())
}

/// 主源优先的完整 FIT 合并；偏移值会加到每个补源时间戳后再参与对齐。
pub fn merge_fit(
    primary: &[u8],
    supplements: &[&[u8]],
    options: &FitMergeOptions,
) -> Result<Vec<u8>, FitMergeError> {
    validate_inputs(primary, supplements)?;
    let offsets = resolve_static_offsets(&options.alignment, supplements.len())?;
    let mut primary = FitDocument::parse(primary)?;
    let sources = supplements
        .iter()
        .map(|data| FitDocument::parse(data).map_err(FitMergeError::from))
        .collect::<Result<Vec<_>, _>>()?;
    let developer_index_maps = allocate_developer_indexes(&primary, &sources)?;

    let mut records = message_index_by_timestamp(&primary, 20);
    let primary_range = timestamp_range(records.keys().copied());
    let mut aligned_ranges = Vec::with_capacity(sources.len());

    for (source_number, source) in sources.iter().enumerate() {
        let offset = offsets[source_number];
        let developer_indexes = &developer_index_maps[source_number];
        let mut aligned_min = None;
        let mut aligned_max = None;
        for (source_index, message) in source.messages().iter().enumerate() {
            if message.global_number() != 20 {
                continue;
            }
            let Some(timestamp) = source.read_u32(source_index, 253) else {
                continue;
            };
            let Some(aligned) = aligned_timestamp(timestamp, offset) else {
                continue;
            };
            aligned_min = Some(aligned_min.map_or(aligned, |value: u32| value.min(aligned)));
            aligned_max = Some(aligned_max.map_or(aligned, |value: u32| value.max(aligned)));
            if let Some(&target_index) = records.get(&aligned) {
                match options.supplement_mode {
                    FitSupplementMode::SensorsOnly => copy_fields(
                        &mut primary,
                        target_index,
                        source,
                        source_index,
                        &[3, 4, 7, 13],
                    )?,
                    FitSupplementMode::FillRecords => {
                        primary.copy_all_missing_native_fields_from(
                            target_index,
                            source,
                            source_index,
                        )?;
                        primary.copy_all_missing_developer_fields_from(
                            target_index,
                            source,
                            source_index,
                            developer_indexes,
                        )?;
                    }
                }
            } else if options.supplement_mode == FitSupplementMode::FillRecords {
                let target_index =
                    primary.append_message_from(source, source_index, developer_indexes)?;
                primary.set_or_insert_u32(target_index, 253, aligned)?;
                records.insert(aligned, target_index);
            }
        }
        aligned_ranges.push(aligned_min.zip(aligned_max).map(|(start, end)| start..=end));
    }

    let primary_lap_count = primary
        .messages()
        .iter()
        .filter(|message| message.global_number() == 19)
        .count();
    if options.supplement_mode == FitSupplementMode::FillRecords {
        merge_outside_events_and_laps(
            &mut primary,
            &sources,
            &offsets,
            &developer_index_maps,
            primary_range.clone(),
        )?;
    }
    let has_extra_laps = primary
        .messages()
        .iter()
        .filter(|message| message.global_number() == 19)
        .count()
        > primary_lap_count;
    merge_session(
        &mut primary,
        &sources,
        &offsets,
        &developer_index_maps,
        &aligned_ranges,
        primary_range,
        options.supplement_mode,
        has_extra_laps,
        records.keys().copied(),
    )?;
    if options.supplement_mode == FitSupplementMode::FillRecords {
        for (source, developer_indexes) in sources.iter().zip(&developer_index_maps) {
            if source
                .messages()
                .iter()
                .any(|message| message.has_developer_fields())
            {
                for (index, message) in source.messages().iter().enumerate() {
                    if matches!(message.global_number(), 206 | 207) {
                        primary.append_message_from(source, index, developer_indexes)?;
                    }
                }
            }
        }
        primary.sort_messages_for_merge();
        rebase_record_distances(&mut primary)?;
    }
    primary.to_bytes().map_err(Into::into)
}

fn validate_inputs(primary: &[u8], supplements: &[&[u8]]) -> Result<(), FitMergeError> {
    if supplements.is_empty() {
        return Err(FitMergeError::NeedSupplement);
    }
    if supplements.len() > MAX_MERGE_SUPPLEMENTS {
        return Err(FitMergeError::TooManySupplements);
    }
    let input_size = supplements.iter().try_fold(primary.len(), |total, data| {
        total
            .checked_add(data.len())
            .ok_or(FitMergeError::InputTooLarge)
    })?;
    if input_size > MAX_MERGE_INPUT_BYTES || primary.len() > MAX_FIT_BYTES {
        return Err(FitMergeError::InputTooLarge);
    }
    Ok(())
}

fn allocate_developer_indexes(
    primary: &FitDocument,
    sources: &[FitDocument],
) -> Result<Vec<HashMap<u8, u8>>, FitMergeError> {
    let mut used = primary.developer_data_indexes();
    sources
        .iter()
        .map(|source| {
            let mut source_indexes = source
                .developer_data_indexes()
                .into_iter()
                .collect::<Vec<_>>();
            source_indexes.sort_unstable();
            let mut mapping = HashMap::new();
            for source_index in source_indexes {
                let target = if !used.contains(&source_index) {
                    source_index
                } else {
                    (0..u8::MAX)
                        .find(|candidate| !used.contains(candidate))
                        .ok_or(FitMergeError::DeveloperIndexExhausted)?
                };
                used.insert(target);
                mapping.insert(source_index, target);
            }
            Ok(mapping)
        })
        .collect()
}

fn message_index_by_timestamp(document: &FitDocument, global: u16) -> HashMap<u32, usize> {
    document
        .messages()
        .iter()
        .enumerate()
        .filter(|(_, message)| message.global_number() == global)
        .filter_map(|(index, _)| {
            document
                .read_u32(index, 253)
                .map(|timestamp| (timestamp, index))
        })
        .collect()
}

fn aligned_timestamp(timestamp: u32, offset: i32) -> Option<u32> {
    u32::try_from(i64::from(timestamp) + i64::from(offset)).ok()
}

fn timestamp_range(timestamps: impl Iterator<Item = u32>) -> Option<std::ops::RangeInclusive<u32>> {
    let mut timestamps = timestamps;
    let first = timestamps.next()?;
    let (minimum, maximum) = timestamps.fold((first, first), |(minimum, maximum), value| {
        (minimum.min(value), maximum.max(value))
    });
    Some(minimum..=maximum)
}

fn merge_outside_events_and_laps(
    primary: &mut FitDocument,
    sources: &[FitDocument],
    offsets: &[i32],
    developer_index_maps: &[HashMap<u8, u8>],
    primary_range: Option<std::ops::RangeInclusive<u32>>,
) -> Result<(), FitMergeError> {
    let mut event_keys = primary
        .messages()
        .iter()
        .enumerate()
        .filter(|(_, message)| message.global_number() == 21)
        .filter_map(|(index, _)| event_key(primary, index))
        .collect::<HashSet<_>>();
    let mut lap_ranges = primary
        .messages()
        .iter()
        .enumerate()
        .filter(|(_, message)| message.global_number() == 19)
        .filter_map(|(index, _)| lap_range(primary, index, 0))
        .collect::<Vec<_>>();

    for (source_number, source) in sources.iter().enumerate() {
        let offset = offsets[source_number];
        let developer_indexes = &developer_index_maps[source_number];
        for (index, message) in source.messages().iter().enumerate() {
            if message.global_number() == 21 {
                let Some(timestamp) = source
                    .read_u32(index, 253)
                    .and_then(|value| aligned_timestamp(value, offset))
                else {
                    continue;
                };
                if primary_range
                    .as_ref()
                    .is_some_and(|range| range.contains(&timestamp))
                {
                    continue;
                }
                let key = (
                    timestamp,
                    source.read_u8(index, 0).unwrap_or(u8::MAX),
                    source.read_u8(index, 1).unwrap_or(u8::MAX),
                );
                if event_keys.insert(key) {
                    let target = primary.append_message_from(source, index, developer_indexes)?;
                    primary.set_or_insert_u32(target, 253, timestamp)?;
                }
            } else if message.global_number() == 19 {
                let Some(range) = lap_range(source, index, offset) else {
                    continue;
                };
                let outside_primary = primary_range.as_ref().is_none_or(|primary| {
                    *range.end() < i64::from(*primary.start())
                        || *range.start() > i64::from(*primary.end())
                });
                if !outside_primary
                    || lap_ranges
                        .iter()
                        .any(|existing| ranges_overlap(existing, &range))
                {
                    continue;
                }
                let target = primary.append_message_from(source, index, developer_indexes)?;
                primary.set_or_insert_u32(target, 253, u32::try_from(*range.end()).unwrap())?;
                if source.messages()[index].has_field(2) {
                    primary.set_or_insert_u32(target, 2, u32::try_from(*range.start()).unwrap())?;
                }
                lap_ranges.push(range);
            }
        }
    }
    Ok(())
}

fn event_key(document: &FitDocument, index: usize) -> Option<(u32, u8, u8)> {
    Some((
        document.read_u32(index, 253)?,
        document.read_u8(index, 0).unwrap_or(u8::MAX),
        document.read_u8(index, 1).unwrap_or(u8::MAX),
    ))
}

fn lap_range(
    document: &FitDocument,
    index: usize,
    offset: i32,
) -> Option<std::ops::RangeInclusive<i64>> {
    let end = i64::from(document.read_u32(index, 253)?) + i64::from(offset);
    let start = document
        .read_u32(index, 2)
        .map(|value| i64::from(value) + i64::from(offset))
        .unwrap_or(end);
    (start >= 0 && end >= 0 && start <= i64::from(u32::MAX) && end <= i64::from(u32::MAX))
        .then(|| start.min(end)..=start.max(end))
}

fn ranges_overlap<T: Ord>(
    left: &std::ops::RangeInclusive<T>,
    right: &std::ops::RangeInclusive<T>,
) -> bool {
    left.start() <= right.end() && right.start() <= left.end()
}

#[allow(clippy::too_many_arguments)]
fn merge_session(
    primary: &mut FitDocument,
    sources: &[FitDocument],
    offsets: &[i32],
    developer_index_maps: &[HashMap<u8, u8>],
    aligned_ranges: &[Option<std::ops::RangeInclusive<u32>>],
    primary_range: Option<std::ops::RangeInclusive<u32>>,
    mode: FitSupplementMode,
    has_extra_laps: bool,
    merged_timestamps: impl Iterator<Item = u32>,
) -> Result<(), FitMergeError> {
    let original_session = primary
        .messages()
        .iter()
        .position(|message| message.global_number() == 18);
    let original_distance = original_session.and_then(|index| primary.read_u32(index, 9));
    let original_calories = original_session.and_then(|index| primary.read_u16(index, 11));
    let original_timer = original_session.and_then(|index| primary.read_u32(index, 8));
    let mut session = original_session;

    if mode == FitSupplementMode::SensorsOnly && original_session.is_none() {
        return Ok(());
    }

    for (source_number, source) in sources.iter().enumerate() {
        let offset = offsets[source_number];
        let developer_indexes = &developer_index_maps[source_number];
        let Some(source_index) = source
            .messages()
            .iter()
            .position(|message| message.global_number() == 18)
        else {
            continue;
        };
        if let Some(target) = session {
            match mode {
                FitSupplementMode::SensorsOnly => copy_fields(
                    primary,
                    target,
                    source,
                    source_index,
                    &[16, 17, 18, 19, 20, 21],
                )?,
                FitSupplementMode::FillRecords => {
                    let missing_start = !primary.messages()[target].has_field(2);
                    let missing_end = !primary.messages()[target].has_field(253);
                    primary.copy_all_missing_native_fields_from(target, source, source_index)?;
                    primary.copy_all_missing_developer_fields_from(
                        target,
                        source,
                        source_index,
                        developer_indexes,
                    )?;
                    for (field, missing) in [(2, missing_start), (253, missing_end)] {
                        if missing
                            && let Some(value) = source
                                .read_u32(source_index, field)
                                .and_then(|value| aligned_timestamp(value, offset))
                        {
                            primary.set_or_insert_u32(target, field, value)?;
                        }
                    }
                }
            }
        } else {
            let target = primary.append_message_from(source, source_index, developer_indexes)?;
            for field in [2, 253] {
                if let Some(value) = source
                    .read_u32(source_index, field)
                    .and_then(|value| aligned_timestamp(value, offset))
                {
                    primary.set_or_insert_u32(target, field, value)?;
                }
            }
            session = Some(target);
        }
    }

    let Some(session) = session else {
        return Ok(());
    };
    if mode == FitSupplementMode::SensorsOnly {
        return Ok(());
    }

    if original_session.is_some()
        && let Some(primary_range) = primary_range.as_ref()
    {
        let mut extra_distance = 0u64;
        let mut extra_calories = 0u64;
        let mut extra_timer = 0u64;
        let mut accepted_ranges = Vec::new();
        for (source, range) in sources.iter().zip(aligned_ranges) {
            let Some(range) = range.as_ref() else {
                continue;
            };
            if ranges_overlap(primary_range, range)
                || accepted_ranges
                    .iter()
                    .any(|accepted| ranges_overlap(accepted, range))
            {
                continue;
            }
            accepted_ranges.push(range.clone());
            if let Some(source_session) = source
                .messages()
                .iter()
                .position(|message| message.global_number() == 18)
            {
                extra_distance += u64::from(source.read_u32(source_session, 9).unwrap_or_default());
                extra_calories +=
                    u64::from(source.read_u16(source_session, 11).unwrap_or_default());
                extra_timer += u64::from(source.read_u32(source_session, 8).unwrap_or_default());
            }
        }
        if extra_distance > 0 {
            primary.set_or_insert_u32(
                session,
                9,
                u32::try_from(u64::from(original_distance.unwrap_or_default()) + extra_distance)
                    .unwrap_or(u32::MAX - 1),
            )?;
        }
        if extra_calories > 0 {
            primary.set_or_insert_u16(
                session,
                11,
                u16::try_from(u64::from(original_calories.unwrap_or_default()) + extra_calories)
                    .unwrap_or(u16::MAX - 1),
            )?;
        }
        if extra_timer > 0 {
            primary.set_or_insert_u32(
                session,
                8,
                u32::try_from(u64::from(original_timer.unwrap_or_default()) + extra_timer)
                    .unwrap_or(u32::MAX - 1),
            )?;
        }
    }

    if let Some(range) = timestamp_range(merged_timestamps) {
        extend_time_range(primary, session, &range)?;
        if !has_extra_laps
            && let Some(lap) = primary
                .messages()
                .iter()
                .position(|message| message.global_number() == 19)
        {
            extend_time_range(primary, lap, &range)?;
        }
    }
    Ok(())
}

fn extend_time_range(
    document: &mut FitDocument,
    index: usize,
    range: &std::ops::RangeInclusive<u32>,
) -> Result<(), FitMergeError> {
    let start = document
        .read_u32(index, 2)
        .map_or(*range.start(), |value| value.min(*range.start()));
    let end = document
        .read_u32(index, 253)
        .map_or(*range.end(), |value| value.max(*range.end()));
    document.set_or_insert_u32(index, 2, start)?;
    document.set_or_insert_u32(index, 253, end)?;
    let span_millis = end
        .saturating_sub(start)
        .saturating_mul(1_000)
        .min(u32::MAX - 1);
    if document
        .read_u32(index, 7)
        .is_none_or(|elapsed| elapsed < span_millis)
    {
        document.set_or_insert_u32(index, 7, span_millis)?;
    }
    Ok(())
}

fn rebase_record_distances(document: &mut FitDocument) -> Result<(), FitMergeError> {
    let record_indexes = document
        .messages()
        .iter()
        .enumerate()
        .filter_map(|(index, message)| (message.global_number() == 20).then_some(index))
        .collect::<Vec<_>>();
    let mut floor = None;
    let mut shift = 0u64;
    for index in record_indexes {
        let Some(raw) = document.read_u32(index, 5) else {
            continue;
        };
        let mut adjusted = u64::from(raw) + shift;
        if let Some(previous) = floor
            && adjusted < previous
        {
            shift += previous - adjusted;
            adjusted = previous;
        }
        let adjusted = u32::try_from(adjusted).unwrap_or(u32::MAX - 1);
        if adjusted != raw {
            document.set_u32(index, 5, adjusted)?;
        }
        floor = Some(u64::from(adjusted));
    }
    Ok(())
}

fn copy_fields(
    target: &mut FitDocument,
    target_index: usize,
    source: &FitDocument,
    source_index: usize,
    fields: &[u8],
) -> Result<(), FitMergeError> {
    for &field in fields {
        if source.field_bytes(source_index, field).is_some() {
            target.copy_missing_field_from(target_index, source, source_index, field)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::{
        FitMergeError, FitMergeOptions, FitSupplementMode, MAX_MERGE_SUPPLEMENTS, merge_fit,
        merge_fit_sensors,
    };
    use crate::fit::{FitDocument, crc16};
    use crate::fit_alignment::FitStaticAlignment;

    #[test]
    fn primary_wins_and_only_missing_sensor_fields_are_filled() {
        let primary = fit_file(
            &[
                message(
                    20,
                    &[
                        (253, 0x86, &1_000u32.to_le_bytes()),
                        (3, 0x02, &[140]),
                        (7, 0x84, &100u16.to_le_bytes()),
                        (99, 0x0d, &[1, 2]),
                    ],
                ),
                message(20, &[(253, 0x86, &1_001u32.to_le_bytes())]),
                message(18, &[(16, 0x02, &[130])]),
            ]
            .concat(),
        );
        let secondary = fit_file(
            &[
                message(
                    20,
                    &[
                        (253, 0x86, &1_000u32.to_le_bytes()),
                        (0, 0x85, &123i32.to_le_bytes()),
                        (3, 0x02, &[120]),
                        (4, 0x02, &[90]),
                        (7, 0x84, &200u16.to_le_bytes()),
                        (13, 0x01, &[20]),
                        (100, 0x0d, &[9]),
                    ],
                ),
                message(
                    20,
                    &[
                        (253, 0x86, &1_001u32.to_le_bytes()),
                        (3, 0x02, &[141]),
                        (7, 0x84, &201u16.to_le_bytes()),
                    ],
                ),
                message(
                    20,
                    &[(253, 0x86, &1_002u32.to_le_bytes()), (3, 0x02, &[150])],
                ),
                message(
                    18,
                    &[
                        (16, 0x02, &[120]),
                        (17, 0x02, &[180]),
                        (18, 0x02, &[88]),
                        (20, 0x84, &220u16.to_le_bytes()),
                        (9, 0x86, &999u32.to_le_bytes()),
                    ],
                ),
            ]
            .concat(),
        );

        let output = merge_fit_sensors(&primary, &[&secondary]).unwrap();
        let document = FitDocument::parse(&output).unwrap();
        let records = document
            .messages()
            .iter()
            .enumerate()
            .filter(|(_, message)| message.global_number() == 20)
            .collect::<Vec<_>>();
        assert_eq!(records.len(), 2, "副源独有秒不得插入");
        let first = records[0].0;
        let second = records[1].0;
        assert_eq!(document.read_u8(first, 3), Some(140), "冲突心率保留主源");
        assert_eq!(document.read_u16(first, 7), Some(100), "冲突功率保留主源");
        assert_eq!(document.read_u8(first, 4), Some(90));
        assert_eq!(document.field_bytes(first, 13), Some(&[20][..]));
        assert_eq!(document.field_bytes(first, 99), Some(&[1, 2][..]));
        assert!(!document.messages()[first].has_field(0), "不得补 GPS");
        assert!(
            !document.messages()[first].has_field(100),
            "未知字段不得补入"
        );
        assert_eq!(document.read_u8(second, 3), Some(141));
        assert_eq!(document.read_u16(second, 7), Some(201));

        let session = document
            .messages()
            .iter()
            .position(|message| message.global_number() == 18)
            .unwrap();
        assert_eq!(document.read_u8(session, 16), Some(130), "会话冲突保留主源");
        assert_eq!(document.read_u8(session, 17), Some(180));
        assert_eq!(document.read_u8(session, 18), Some(88));
        assert_eq!(document.read_u16(session, 20), Some(220));
        assert!(
            !document.messages()[session].has_field(9),
            "不得补距离等非传感器汇总"
        );
    }

    #[test]
    fn fill_records_aligns_inserts_sorts_rebases_and_extends_session() {
        let primary = fit_file(
            &[
                message(
                    21,
                    &[
                        (253, 0x86, &1_000u32.to_le_bytes()),
                        (0, 0x00, &[0]),
                        (1, 0x00, &[0]),
                    ],
                ),
                message(
                    20,
                    &[
                        (253, 0x86, &1_000u32.to_le_bytes()),
                        (3, 0x02, &[140]),
                        (5, 0x86, &0u32.to_le_bytes()),
                        (99, 0x0d, &[1, 2]),
                    ],
                ),
                message(
                    20,
                    &[
                        (253, 0x86, &1_001u32.to_le_bytes()),
                        (3, 0x02, &[141]),
                        (5, 0x86, &10_000u32.to_le_bytes()),
                    ],
                ),
                message(
                    19,
                    &[
                        (2, 0x86, &1_000u32.to_le_bytes()),
                        (253, 0x86, &1_001u32.to_le_bytes()),
                    ],
                ),
                message(
                    18,
                    &[
                        (2, 0x86, &1_000u32.to_le_bytes()),
                        (253, 0x86, &1_001u32.to_le_bytes()),
                        (7, 0x86, &1_000u32.to_le_bytes()),
                        (8, 0x86, &1_000u32.to_le_bytes()),
                        (9, 0x86, &10_000u32.to_le_bytes()),
                        (11, 0x84, &10u16.to_le_bytes()),
                    ],
                ),
            ]
            .concat(),
        );
        let aligned_source = fit_file(
            &[
                message(
                    20,
                    &[
                        (253, 0x86, &1_101u32.to_le_bytes()),
                        (3, 0x02, &[99]),
                        (7, 0x84, &200u16.to_le_bytes()),
                    ],
                ),
                message(
                    20,
                    &[
                        (253, 0x86, &1_102u32.to_le_bytes()),
                        (3, 0x02, &[150]),
                        (7, 0x84, &210u16.to_le_bytes()),
                        (100, 0x0d, &[9]),
                    ],
                ),
                message(
                    18,
                    &[
                        (2, 0x86, &1_100u32.to_le_bytes()),
                        (253, 0x86, &1_102u32.to_le_bytes()),
                    ],
                ),
            ]
            .concat(),
        );
        let disjoint_source = fit_file(
            &[
                message(
                    21,
                    &[
                        (253, 0x86, &1_200u32.to_le_bytes()),
                        (0, 0x00, &[0]),
                        (1, 0x00, &[0]),
                    ],
                ),
                message(
                    21,
                    &[
                        (253, 0x86, &1_200u32.to_le_bytes()),
                        (0, 0x00, &[0]),
                        (1, 0x00, &[0]),
                    ],
                ),
                message(
                    20,
                    &[
                        (253, 0x86, &1_200u32.to_le_bytes()),
                        (5, 0x86, &0u32.to_le_bytes()),
                    ],
                ),
                message(
                    20,
                    &[
                        (253, 0x86, &1_201u32.to_le_bytes()),
                        (5, 0x86, &10_000u32.to_le_bytes()),
                    ],
                ),
                message(
                    19,
                    &[
                        (2, 0x86, &1_200u32.to_le_bytes()),
                        (253, 0x86, &1_201u32.to_le_bytes()),
                    ],
                ),
                message(
                    18,
                    &[
                        (2, 0x86, &1_200u32.to_le_bytes()),
                        (253, 0x86, &1_201u32.to_le_bytes()),
                        (7, 0x86, &1_000u32.to_le_bytes()),
                        (8, 0x86, &1_000u32.to_le_bytes()),
                        (9, 0x86, &10_000u32.to_le_bytes()),
                        (11, 0x84, &20u16.to_le_bytes()),
                    ],
                ),
            ]
            .concat(),
        );

        let output = merge_fit(
            &primary,
            &[&aligned_source, &disjoint_source],
            &FitMergeOptions {
                supplement_mode: FitSupplementMode::FillRecords,
                alignment: FitStaticAlignment::PerFile(vec![-100, 0]),
            },
        )
        .unwrap();
        let document = FitDocument::parse(&output).unwrap();
        let records = document
            .messages()
            .iter()
            .enumerate()
            .filter(|(_, message)| message.global_number() == 20)
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        assert_eq!(records.len(), 5);
        assert_eq!(document.read_u8(records[1], 3), Some(141), "同秒主心率优先");
        assert_eq!(
            document.read_u16(records[1], 7),
            Some(200),
            "主缺功率由副补"
        );
        assert_eq!(document.read_u32(records[2], 253), Some(1_002));
        assert_eq!(document.field_bytes(records[2], 100), Some(&[9][..]));
        assert_eq!(document.field_bytes(records[0], 99), Some(&[1, 2][..]));
        let timestamps = records
            .iter()
            .map(|index| document.read_u32(*index, 253).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(timestamps, vec![1_000, 1_001, 1_002, 1_200, 1_201]);
        let distances = records
            .iter()
            .filter_map(|index| document.read_u32(*index, 5))
            .collect::<Vec<_>>();
        assert_eq!(distances, vec![0, 10_000, 10_000, 20_000]);

        let events = document
            .messages()
            .iter()
            .enumerate()
            .filter(|(_, message)| message.global_number() == 21)
            .map(|(index, _)| document.read_u32(index, 253).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(events, vec![1_000, 1_200], "事件排序并去重");
        let laps = document
            .messages()
            .iter()
            .enumerate()
            .filter(|(_, message)| message.global_number() == 19)
            .map(|(index, _)| document.read_u32(index, 253).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(laps, vec![1_001, 1_201]);

        let session = document
            .messages()
            .iter()
            .position(|message| message.global_number() == 18)
            .unwrap();
        assert_eq!(document.read_u32(session, 2), Some(1_000));
        assert_eq!(document.read_u32(session, 253), Some(1_201));
        assert_eq!(document.read_u32(session, 7), Some(201_000));
        assert_eq!(document.read_u32(session, 8), Some(2_000));
        assert_eq!(document.read_u32(session, 9), Some(20_000));
        assert_eq!(document.read_u16(session, 11), Some(30));

        let sensors_only = merge_fit(
            &primary,
            &[&aligned_source],
            &FitMergeOptions {
                supplement_mode: FitSupplementMode::SensorsOnly,
                alignment: FitStaticAlignment::Manual(-100),
            },
        )
        .unwrap();
        let sensors_only = FitDocument::parse(&sensors_only).unwrap();
        let sensor_records = sensors_only
            .messages()
            .iter()
            .enumerate()
            .filter(|(_, message)| message.global_number() == 20)
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        assert_eq!(sensor_records.len(), 2, "传感器模式不得插入缺秒");
        assert_eq!(sensors_only.read_u16(sensor_records[1], 7), Some(200));
    }

    #[test]
    fn rejects_missing_or_excessive_supplements_before_parsing() {
        let primary = fit_file(&[]);
        assert_eq!(
            merge_fit_sensors(&primary, &[]),
            Err(FitMergeError::NeedSupplement)
        );
        let sources =
            std::iter::repeat_n(primary.as_slice(), MAX_MERGE_SUPPLEMENTS + 1).collect::<Vec<_>>();
        assert_eq!(
            merge_fit_sensors(&primary, &sources),
            Err(FitMergeError::TooManySupplements)
        );
    }

    #[test]
    fn developer_payload_is_filled_and_inserted() {
        let mut primary_body = [
            message(207, &[(3, 0x02, &[7])]),
            message(206, &[(0, 0x02, &[7]), (1, 0x02, &[9]), (2, 0x02, &[0x86])]),
        ]
        .concat();
        primary_body.extend_from_slice(&[
            0x60, 0, 0, 20, 0, 1, // Record definition with developer fields
            253, 4, 0x86, // timestamp
            1,    // developer field count
            9, 4, 7, // field 9, size 4, developer index 7
            0, // data header
        ]);
        primary_body.extend_from_slice(&1_000u32.to_le_bytes());
        primary_body.extend_from_slice(&[1, 2, 3, 4]);
        let primary = fit_file(&primary_body);
        let mut source_body = [
            message(207, &[(3, 0x02, &[7])]),
            message(206, &[(0, 0x02, &[7]), (1, 0x02, &[9]), (2, 0x02, &[0x86])]),
        ]
        .concat();
        source_body.extend_from_slice(&[
            0x60, 0, 0, 20, 0, 1, // Record definition with developer fields
            253, 4, 0x86, // timestamp
            1,    // developer field count
            9, 4, 7, // field 9, size 4, developer index 7
            0, // data header
        ]);
        source_body.extend_from_slice(&1_000u32.to_le_bytes());
        source_body.extend_from_slice(&[0xCA, 0xFE, 0xBA, 0xBE]);
        source_body.push(0);
        source_body.extend_from_slice(&1_001u32.to_le_bytes());
        source_body.extend_from_slice(&[0xDE, 0xAD, 0xBE, 0xEF]);
        let source = fit_file(&source_body);

        let output = merge_fit(
            &primary,
            &[&source],
            &FitMergeOptions {
                supplement_mode: FitSupplementMode::FillRecords,
                alignment: FitStaticAlignment::Absolute,
            },
        )
        .unwrap();
        let document = FitDocument::parse(&output).unwrap();
        let existing = document
            .messages()
            .iter()
            .enumerate()
            .find(|(index, message)| {
                message.global_number() == 20 && document.read_u32(*index, 253) == Some(1_000)
            })
            .unwrap()
            .0;
        let inserted = document
            .messages()
            .iter()
            .enumerate()
            .find(|(index, message)| {
                message.global_number() == 20 && document.read_u32(*index, 253) == Some(1_001)
            })
            .unwrap()
            .0;
        assert_eq!(
            document.developer_field_bytes(existing, 9, 7),
            Some(&[1, 2, 3, 4][..]),
            "主源 developer index 7 必须保留"
        );
        assert_eq!(
            document.developer_field_bytes(existing, 9, 0),
            Some(&[0xCA, 0xFE, 0xBA, 0xBE][..]),
            "冲突的补源 developer index 应重映射"
        );
        assert_eq!(
            document.developer_field_bytes(inserted, 9, 0),
            Some(&[0xDE, 0xAD, 0xBE, 0xEF][..])
        );
        let developer_metadata = document
            .messages()
            .iter()
            .enumerate()
            .filter(|(_, message)| matches!(message.global_number(), 206 | 207))
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        assert_eq!(developer_metadata.len(), 4);
        assert!(developer_metadata.into_iter().all(|index| index < existing));
        let metadata_indexes = document
            .messages()
            .iter()
            .enumerate()
            .filter_map(|(index, message)| {
                (message.global_number() == 207)
                    .then(|| document.read_u8(index, 3))
                    .flatten()
            })
            .collect::<HashSet<_>>();
        assert_eq!(metadata_indexes, HashSet::from([0, 7]));
    }

    #[test]
    fn overlapping_supplements_are_not_double_counted_and_sensors_keep_missing_session() {
        let primary = fit_file(
            &[
                message(20, &[(253, 0x86, &1_000u32.to_le_bytes())]),
                message(
                    18,
                    &[
                        (9, 0x86, &10_000u32.to_le_bytes()),
                        (11, 0x84, &10u16.to_le_bytes()),
                    ],
                ),
            ]
            .concat(),
        );
        let supplement = |heart_rate| {
            fit_file(
                &[
                    message(
                        20,
                        &[
                            (253, 0x86, &1_200u32.to_le_bytes()),
                            (3, 0x02, &[heart_rate]),
                        ],
                    ),
                    message(
                        18,
                        &[
                            (8, 0x86, &1_000u32.to_le_bytes()),
                            (9, 0x86, &5_000u32.to_le_bytes()),
                            (11, 0x84, &5u16.to_le_bytes()),
                        ],
                    ),
                ]
                .concat(),
            )
        };
        let first = supplement(140);
        let second = supplement(150);
        let output = merge_fit(
            &primary,
            &[&first, &second],
            &FitMergeOptions {
                supplement_mode: FitSupplementMode::FillRecords,
                alignment: FitStaticAlignment::Absolute,
            },
        )
        .unwrap();
        let document = FitDocument::parse(&output).unwrap();
        let session = document
            .messages()
            .iter()
            .position(|message| message.global_number() == 18)
            .unwrap();
        assert_eq!(document.read_u32(session, 9), Some(15_000));
        assert_eq!(document.read_u16(session, 11), Some(15));
        assert_eq!(document.read_u32(session, 8), Some(1_000));

        let primary_without_session =
            fit_file(&message(20, &[(253, 0x86, &1_200u32.to_le_bytes())]));
        let sensors_only = merge_fit_sensors(&primary_without_session, &[&first]).unwrap();
        let sensors_only = FitDocument::parse(&sensors_only).unwrap();
        assert!(
            sensors_only
                .messages()
                .iter()
                .all(|message| message.global_number() != 18),
            "旧 sensorsOnly API 不得凭空新增 Session"
        );
    }

    fn message(global: u16, fields: &[(u8, u8, &[u8])]) -> Vec<u8> {
        let mut data = vec![0x40, 0, 0];
        data.extend_from_slice(&global.to_le_bytes());
        data.push(u8::try_from(fields.len()).unwrap());
        for (number, base_type, value) in fields {
            data.extend_from_slice(&[*number, u8::try_from(value.len()).unwrap(), *base_type]);
        }
        data.push(0);
        for (_, _, value) in fields {
            data.extend_from_slice(value);
        }
        data
    }

    fn fit_file(body: &[u8]) -> Vec<u8> {
        let mut output = vec![14, 0x20, 0x54, 0x08];
        output.extend_from_slice(&(body.len() as u32).to_le_bytes());
        output.extend_from_slice(b".FIT");
        output.extend_from_slice(&crc16(&output).to_le_bytes());
        output.extend_from_slice(body);
        output.extend_from_slice(&crc16(&output).to_le_bytes());
        output
    }
}
