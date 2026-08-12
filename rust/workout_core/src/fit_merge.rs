use std::collections::HashMap;

use super::{FitDecodeError, FitDocument, MAX_FIT_BYTES};

/// 合并时最多接收的补源文件数与总输入；避免多份恶意 FIT 同时放大内存。
pub const MAX_MERGE_SUPPLEMENTS: usize = 8;
pub const MAX_MERGE_INPUT_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FitMergeError {
    NeedSupplement,
    TooManySupplements,
    InputTooLarge,
    InvalidFit(FitDecodeError),
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

    let mut primary = FitDocument::parse(primary)?;
    let records = primary
        .messages()
        .iter()
        .enumerate()
        .filter(|(_, message)| message.global_number() == 20)
        .filter_map(|(index, _)| {
            primary
                .read_u32(index, 253)
                .map(|timestamp| (timestamp, index))
        })
        .collect::<HashMap<_, _>>();
    let session = primary
        .messages()
        .iter()
        .position(|message| message.global_number() == 18);

    for data in supplements {
        let source = FitDocument::parse(data)?;
        for (source_index, message) in source.messages().iter().enumerate() {
            if message.global_number() == 20 {
                let Some(timestamp) = source.read_u32(source_index, 253) else {
                    continue;
                };
                let Some(&target_index) = records.get(&timestamp) else {
                    continue;
                };
                copy_fields(
                    &mut primary,
                    target_index,
                    &source,
                    source_index,
                    &[3, 4, 7, 13],
                )?;
            } else if message.global_number() == 18 {
                if let Some(target_index) = session {
                    copy_fields(
                        &mut primary,
                        target_index,
                        &source,
                        source_index,
                        &[16, 17, 18, 19, 20, 21],
                    )?;
                }
                break;
            }
        }
    }
    primary.to_bytes().map_err(Into::into)
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
    use super::{FitMergeError, MAX_MERGE_SUPPLEMENTS, merge_fit_sensors};
    use crate::fit::{FitDocument, crc16};

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
