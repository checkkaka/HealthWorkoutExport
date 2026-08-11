#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FitDecodeError {
    NotFit,
    Truncated,
    InvalidCrc,
    InvalidDefinition,
    MissingDefinition(u8),
    UnsupportedCompressedTimestamp,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct FitContentSummary {
    pub gps_point_count: usize,
    pub heart_rate_point_count: usize,
}

impl FitContentSummary {
    pub const fn quality_score(self) -> usize {
        self.gps_point_count * 10 + self.heart_rate_point_count
    }
}

#[derive(Clone, Debug)]
struct FieldDefinition {
    number: u8,
    size: usize,
}

#[derive(Clone, Debug)]
struct MessageDefinition {
    global_number: u16,
    big_endian: bool,
    fields: Vec<FieldDefinition>,
    data_size: usize,
}

/// 校验并解码单个 FIT 文件，返回与 Swift `FitContentProbe` 对等的内容摘要。
pub fn decode_fit(data: &[u8]) -> Result<FitContentSummary, FitDecodeError> {
    if data.len() < 12 {
        return Err(FitDecodeError::Truncated);
    }
    let header_size = usize::from(data[0]);
    if !matches!(header_size, 12 | 14) || data[8..12] != *b".FIT" {
        return Err(FitDecodeError::NotFit);
    }
    if data.len() < header_size + 2 {
        return Err(FitDecodeError::Truncated);
    }
    if header_size == 14 {
        let stored = u16::from_le_bytes([data[12], data[13]]);
        if stored != 0 && stored != crc16(&data[..12]) {
            return Err(FitDecodeError::InvalidCrc);
        }
    }

    let data_size = u32::from_le_bytes(data[4..8].try_into().unwrap()) as usize;
    let data_end = header_size
        .checked_add(data_size)
        .ok_or(FitDecodeError::Truncated)?;
    let file_end = data_end.checked_add(2).ok_or(FitDecodeError::Truncated)?;
    if data.len() < file_end {
        return Err(FitDecodeError::Truncated);
    }
    if data.len() != file_end {
        return Err(FitDecodeError::InvalidDefinition);
    }
    let stored_file_crc = u16::from_le_bytes([data[data_end], data[data_end + 1]]);
    if stored_file_crc != crc16(&data[..data_end]) {
        return Err(FitDecodeError::InvalidCrc);
    }

    let mut definitions: [Option<MessageDefinition>; 16] = std::array::from_fn(|_| None);
    let mut cursor = header_size;
    let mut summary = FitContentSummary::default();
    while cursor < data_end {
        let record_header = data[cursor];
        if record_header & 0x80 != 0 {
            return Err(FitDecodeError::UnsupportedCompressedTimestamp);
        }
        if record_header & 0x40 != 0 {
            cursor += 1;
            let fixed = take(data, &mut cursor, data_end, 5)?;
            let big_endian = match fixed[1] {
                0 => false,
                1 => true,
                _ => return Err(FitDecodeError::InvalidDefinition),
            };
            let global_number = if big_endian {
                u16::from_be_bytes([fixed[2], fixed[3]])
            } else {
                u16::from_le_bytes([fixed[2], fixed[3]])
            };
            let field_count = usize::from(fixed[4]);
            let raw_fields = take(
                data,
                &mut cursor,
                data_end,
                field_count
                    .checked_mul(3)
                    .ok_or(FitDecodeError::Truncated)?,
            )?;
            let mut fields = Vec::with_capacity(field_count);
            let mut message_size = 0usize;
            for raw in raw_fields.chunks_exact(3) {
                let size = usize::from(raw[1]);
                message_size = message_size
                    .checked_add(size)
                    .ok_or(FitDecodeError::InvalidDefinition)?;
                fields.push(FieldDefinition {
                    number: raw[0],
                    size,
                });
            }
            if record_header & 0x20 != 0 {
                let developer_count =
                    usize::from(*take(data, &mut cursor, data_end, 1)?.first().unwrap());
                let raw_developer_fields = take(
                    data,
                    &mut cursor,
                    data_end,
                    developer_count
                        .checked_mul(3)
                        .ok_or(FitDecodeError::Truncated)?,
                )?;
                for raw in raw_developer_fields.chunks_exact(3) {
                    message_size = message_size
                        .checked_add(usize::from(raw[1]))
                        .ok_or(FitDecodeError::InvalidDefinition)?;
                }
            }
            definitions[usize::from(record_header & 0x0F)] = Some(MessageDefinition {
                global_number,
                big_endian,
                fields,
                data_size: message_size,
            });
            continue;
        }

        cursor += 1;
        let local_number = record_header & 0x0F;
        let definition = definitions[usize::from(local_number)]
            .as_ref()
            .ok_or(FitDecodeError::MissingDefinition(local_number))?;
        let message = take(data, &mut cursor, data_end, definition.data_size)?;
        if definition.global_number == 20 {
            let latitude = field_i32(definition, message, 0);
            let longitude = field_i32(definition, message, 1);
            if latitude.is_some_and(|value| value != i32::MAX)
                && longitude.is_some_and(|value| value != i32::MAX)
            {
                summary.gps_point_count += 1;
            }
            if field_u8(definition, message, 3).is_some_and(|value| value != u8::MAX) {
                summary.heart_rate_point_count += 1;
            }
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
    decode_fit(data)?;
    Ok(data.to_vec())
}

fn take<'a>(
    data: &'a [u8],
    cursor: &mut usize,
    end: usize,
    count: usize,
) -> Result<&'a [u8], FitDecodeError> {
    let next = cursor.checked_add(count).ok_or(FitDecodeError::Truncated)?;
    if next > end {
        return Err(FitDecodeError::Truncated);
    }
    let bytes = &data[*cursor..next];
    *cursor = next;
    Ok(bytes)
}

fn field_bytes<'a>(
    definition: &MessageDefinition,
    message: &'a [u8],
    number: u8,
) -> Option<&'a [u8]> {
    let mut offset = 0;
    for field in &definition.fields {
        let end = offset + field.size;
        if field.number == number {
            return message.get(offset..end);
        }
        offset = end;
    }
    None
}

fn field_i32(definition: &MessageDefinition, message: &[u8], number: u8) -> Option<i32> {
    let bytes: [u8; 4] = field_bytes(definition, message, number)?
        .get(..4)?
        .try_into()
        .ok()?;
    Some(if definition.big_endian {
        i32::from_be_bytes(bytes)
    } else {
        i32::from_le_bytes(bytes)
    })
}

fn field_u8(definition: &MessageDefinition, message: &[u8], number: u8) -> Option<u8> {
    field_bytes(definition, message, number)?.first().copied()
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
    use super::{FitContentSummary, FitDecodeError, decode_fit, is_valid_fit, reencode_fit};

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

    fn fit_file(data: &[u8]) -> Vec<u8> {
        fit_file_with_header(data, 14, false)
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
