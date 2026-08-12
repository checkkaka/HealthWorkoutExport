use std::ops::Range;
use std::sync::Arc;

use super::{FitDecodeError, crc16};

pub const MAX_FIT_BYTES: usize = 64 * 1024 * 1024;
const MAX_MESSAGES: usize = 500_000;
const MAX_FIELDS: usize = 1_000_000;
const MAX_DOCUMENT_MEMORY_BYTES: usize = 128 * 1024 * 1024;
const ALLOCATION_OVERHEAD_BYTES: usize = 16;

const BASE_TYPE_ENUM: u8 = 0x00;
const BASE_TYPE_SINT32: u8 = 0x85;
const BASE_TYPE_UINT8: u8 = 0x02;
const BASE_TYPE_UINT16: u8 = 0x84;
const BASE_TYPE_UINT32: u8 = 0x86;
const BASE_TYPE_UINT8Z: u8 = 0x0A;
const BASE_TYPE_UINT16Z: u8 = 0x8B;
const BASE_TYPE_UINT32Z: u8 = 0x8C;
const BASE_TYPE_BYTE: u8 = 0x0D;

#[derive(Clone, Debug, Eq, PartialEq)]
struct FieldDefinition {
    number: u8,
    size: usize,
    base_type: u8,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DeveloperFieldDefinition {
    number: u8,
    size: usize,
    developer_data_index: u8,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct MessageDefinition {
    global_number: u16,
    big_endian: bool,
    fields: Vec<FieldDefinition>,
    developer_fields: Vec<DeveloperFieldDefinition>,
}

#[derive(Clone, Debug)]
enum FieldValue {
    Source(Range<usize>),
    Owned(Vec<u8>),
}

#[derive(Clone, Debug)]
struct FitField {
    definition: FieldDefinition,
    value: FieldValue,
}

#[derive(Clone, Debug)]
struct FitDeveloperField {
    definition: DeveloperFieldDefinition,
    value: FieldValue,
}

/// 单条已展开的 FIT 数据消息。未知 global message 与未知字段均保留原始字节。
#[derive(Clone, Debug)]
pub struct FitMessage {
    global_number: u16,
    big_endian: bool,
    fields: Vec<FitField>,
    developer_fields: Vec<FitDeveloperField>,
}

impl FitMessage {
    pub const fn global_number(&self) -> u16 {
        self.global_number
    }

    pub fn has_field(&self, number: u8) -> bool {
        self.fields
            .iter()
            .any(|field| field.definition.number == number)
    }
}

/// 有界、可修改且能无损携带未知字段的 FIT 文档。
#[derive(Clone, Debug)]
pub struct FitDocument {
    source: Arc<[u8]>,
    protocol_version: u8,
    profile_version: [u8; 2],
    messages: Vec<FitMessage>,
    dirty: bool,
}

impl FitDocument {
    pub fn parse(data: &[u8]) -> Result<Self, FitDecodeError> {
        if data.len() > MAX_FIT_BYTES {
            return Err(FitDecodeError::TooLarge);
        }
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
        if data_size > MAX_FIT_BYTES {
            return Err(FitDecodeError::TooLarge);
        }
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

        let source: Arc<[u8]> = Arc::from(data);
        let mut definitions: [Option<MessageDefinition>; 16] = std::array::from_fn(|_| None);
        let mut cursor = header_size;
        let mut messages = Vec::new();
        let mut field_count = 0usize;
        let mut memory_bytes = data.len();
        let mut timestamp = 0u32;
        let mut last_time_offset = 0u8;

        while cursor < data_end {
            let record_header = data[cursor];
            if record_header & 0x80 != 0 {
                let local_number = usize::from((record_header >> 5) & 0x03);
                cursor += 1;
                let definition = definitions[local_number]
                    .as_ref()
                    .ok_or(FitDecodeError::MissingDefinition(local_number as u8))?;
                if definition.fields.iter().any(|field| field.number == 253) {
                    return Err(FitDecodeError::InvalidCompressedTimestamp);
                }
                let offset = record_header & 0x1f;
                let delta = offset.wrapping_sub(last_time_offset) & 0x1f;
                timestamp = timestamp
                    .checked_add(u32::from(delta))
                    .ok_or(FitDecodeError::InvalidCompressedTimestamp)?;
                last_time_offset = offset;
                let mut message = parse_message(&mut cursor, data_end, definition)?;
                insert_compressed_timestamp(&mut message, timestamp);
                field_count = checked_field_total(field_count, &message)?;
                memory_bytes = checked_memory_total(memory_bytes, &message)?;
                push_message(&mut messages, message)?;
                continue;
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
                let count = usize::from(fixed[4]);
                let raw_fields = take(
                    data,
                    &mut cursor,
                    data_end,
                    count.checked_mul(3).ok_or(FitDecodeError::Truncated)?,
                )?;
                let mut fields = Vec::with_capacity(count);
                for raw in raw_fields.chunks_exact(3) {
                    let size = usize::from(raw[1]);
                    if size == 0 {
                        return Err(FitDecodeError::InvalidDefinition);
                    }
                    fields.push(FieldDefinition {
                        number: raw[0],
                        size,
                        base_type: raw[2],
                    });
                }

                let developer_fields = if record_header & 0x20 != 0 {
                    let count = usize::from(take(data, &mut cursor, data_end, 1)?[0]);
                    let raw_fields = take(
                        data,
                        &mut cursor,
                        data_end,
                        count.checked_mul(3).ok_or(FitDecodeError::Truncated)?,
                    )?;
                    let mut fields = Vec::with_capacity(count);
                    for raw in raw_fields.chunks_exact(3) {
                        let size = usize::from(raw[1]);
                        if size == 0 {
                            return Err(FitDecodeError::InvalidDefinition);
                        }
                        fields.push(DeveloperFieldDefinition {
                            number: raw[0],
                            size,
                            developer_data_index: raw[2],
                        });
                    }
                    fields
                } else {
                    Vec::new()
                };
                definitions[usize::from(record_header & 0x0f)] = Some(MessageDefinition {
                    global_number,
                    big_endian,
                    fields,
                    developer_fields,
                });
                continue;
            }

            cursor += 1;
            let local_number = usize::from(record_header & 0x0f);
            let definition = definitions[local_number]
                .as_ref()
                .ok_or(FitDecodeError::MissingDefinition(local_number as u8))?;
            let message = parse_message(&mut cursor, data_end, definition)?;
            if let Some(value) = raw_timestamp(&source, &message) {
                timestamp = value;
                last_time_offset = (value & 0x1f) as u8;
            }
            field_count = checked_field_total(field_count, &message)?;
            memory_bytes = checked_memory_total(memory_bytes, &message)?;
            push_message(&mut messages, message)?;
        }

        Ok(Self {
            source,
            protocol_version: data[1],
            profile_version: [data[2], data[3]],
            messages,
            dirty: false,
        })
    }

    pub fn messages(&self) -> &[FitMessage] {
        &self.messages
    }

    pub fn field_bytes(&self, message_index: usize, field_number: u8) -> Option<&[u8]> {
        let field = self
            .messages
            .get(message_index)?
            .fields
            .iter()
            .find(|field| field.definition.number == field_number)?;
        Some(value_bytes(&self.source, &field.value))
    }

    pub fn developer_field_bytes(
        &self,
        message_index: usize,
        field_number: u8,
        developer_data_index: u8,
    ) -> Option<&[u8]> {
        let field = self
            .messages
            .get(message_index)?
            .developer_fields
            .iter()
            .find(|field| {
                field.definition.number == field_number
                    && field.definition.developer_data_index == developer_data_index
            })?;
        Some(value_bytes(&self.source, &field.value))
    }

    pub fn read_u8(&self, message_index: usize, field_number: u8) -> Option<u8> {
        let field = self.field(message_index, field_number)?;
        let value = value_bytes(&self.source, &field.value).first().copied()?;
        match field.definition.base_type {
            BASE_TYPE_ENUM | BASE_TYPE_UINT8 | BASE_TYPE_BYTE if value != u8::MAX => Some(value),
            BASE_TYPE_UINT8Z if value != 0 => Some(value),
            _ => None,
        }
    }

    pub fn read_u16(&self, message_index: usize, field_number: u8) -> Option<u16> {
        let message = self.messages.get(message_index)?;
        let field = self.field(message_index, field_number)?;
        let bytes: [u8; 2] = self
            .field_bytes(message_index, field_number)?
            .get(..2)?
            .try_into()
            .ok()?;
        let value = if message.big_endian {
            u16::from_be_bytes(bytes)
        } else {
            u16::from_le_bytes(bytes)
        };
        match field.definition.base_type {
            BASE_TYPE_UINT16 if value != u16::MAX => Some(value),
            BASE_TYPE_UINT16Z if value != 0 => Some(value),
            _ => None,
        }
    }

    pub fn read_u32(&self, message_index: usize, field_number: u8) -> Option<u32> {
        let message = self.messages.get(message_index)?;
        let field = self.field(message_index, field_number)?;
        let bytes: [u8; 4] = self
            .field_bytes(message_index, field_number)?
            .get(..4)?
            .try_into()
            .ok()?;
        let value = if message.big_endian {
            u32::from_be_bytes(bytes)
        } else {
            u32::from_le_bytes(bytes)
        };
        match field.definition.base_type {
            BASE_TYPE_UINT32 if value != u32::MAX => Some(value),
            BASE_TYPE_UINT32Z if value != 0 => Some(value),
            _ => None,
        }
    }

    pub fn read_i32(&self, message_index: usize, field_number: u8) -> Option<i32> {
        let message = self.messages.get(message_index)?;
        let field = self.field(message_index, field_number)?;
        if field.definition.base_type != BASE_TYPE_SINT32 {
            return None;
        }
        let bytes: [u8; 4] = value_bytes(&self.source, &field.value)
            .get(..4)?
            .try_into()
            .ok()?;
        let value = if message.big_endian {
            i32::from_be_bytes(bytes)
        } else {
            i32::from_le_bytes(bytes)
        };
        (value != i32::MAX).then_some(value)
    }

    pub fn set_u8(
        &mut self,
        message_index: usize,
        field_number: u8,
        value: u8,
    ) -> Result<(), FitDecodeError> {
        let base_type = self.base_type(message_index, field_number)?;
        if !matches!(
            base_type,
            BASE_TYPE_ENUM | BASE_TYPE_UINT8 | BASE_TYPE_UINT8Z | BASE_TYPE_BYTE
        ) || invalid_u8(base_type, value)
        {
            return Err(FitDecodeError::InvalidFieldValue);
        }
        self.set_field_bytes(message_index, field_number, &[value])
    }

    pub fn set_u16(
        &mut self,
        message_index: usize,
        field_number: u8,
        value: u16,
    ) -> Result<(), FitDecodeError> {
        let base_type = self.base_type(message_index, field_number)?;
        if !matches!(base_type, BASE_TYPE_UINT16 | BASE_TYPE_UINT16Z)
            || invalid_u16(base_type, value)
        {
            return Err(FitDecodeError::InvalidFieldValue);
        }
        let big_endian = self
            .messages
            .get(message_index)
            .ok_or(FitDecodeError::FieldNotFound)?
            .big_endian;
        let bytes = if big_endian {
            value.to_be_bytes()
        } else {
            value.to_le_bytes()
        };
        self.set_field_bytes(message_index, field_number, &bytes)
    }

    pub fn set_u32(
        &mut self,
        message_index: usize,
        field_number: u8,
        value: u32,
    ) -> Result<(), FitDecodeError> {
        let base_type = self.base_type(message_index, field_number)?;
        if !matches!(base_type, BASE_TYPE_UINT32 | BASE_TYPE_UINT32Z)
            || invalid_u32(base_type, value)
        {
            return Err(FitDecodeError::InvalidFieldValue);
        }
        let big_endian = self
            .messages
            .get(message_index)
            .ok_or(FitDecodeError::FieldNotFound)?
            .big_endian;
        let bytes = if big_endian {
            value.to_be_bytes()
        } else {
            value.to_le_bytes()
        };
        self.set_field_bytes(message_index, field_number, &bytes)
    }

    pub fn set_i32(
        &mut self,
        message_index: usize,
        field_number: u8,
        value: i32,
    ) -> Result<(), FitDecodeError> {
        if self.base_type(message_index, field_number)? != BASE_TYPE_SINT32 || value == i32::MAX {
            return Err(FitDecodeError::InvalidFieldValue);
        }
        let big_endian = self.messages[message_index].big_endian;
        let bytes = if big_endian {
            value.to_be_bytes()
        } else {
            value.to_le_bytes()
        };
        self.set_field_bytes(message_index, field_number, &bytes)
    }

    pub fn set_field_bytes(
        &mut self,
        message_index: usize,
        field_number: u8,
        value: &[u8],
    ) -> Result<(), FitDecodeError> {
        let message = self
            .messages
            .get_mut(message_index)
            .ok_or(FitDecodeError::FieldNotFound)?;
        let field = message
            .fields
            .iter_mut()
            .find(|field| field.definition.number == field_number)
            .ok_or(FitDecodeError::FieldNotFound)?;
        if field.definition.size != value.len() {
            return Err(FitDecodeError::InvalidFieldValue);
        }
        field.value = FieldValue::Owned(value.to_vec());
        self.dirty = true;
        Ok(())
    }

    fn field(&self, message_index: usize, field_number: u8) -> Option<&FitField> {
        self.messages
            .get(message_index)?
            .fields
            .iter()
            .find(|field| field.definition.number == field_number)
    }

    fn base_type(&self, message_index: usize, field_number: u8) -> Result<u8, FitDecodeError> {
        self.field(message_index, field_number)
            .map(|field| field.definition.base_type)
            .ok_or(FitDecodeError::FieldNotFound)
    }

    pub fn to_bytes(&self) -> Result<Vec<u8>, FitDecodeError> {
        if !self.dirty {
            return Ok(self.source.to_vec());
        }

        let mut output = vec![
            14,
            self.protocol_version,
            self.profile_version[0],
            self.profile_version[1],
            0,
            0,
            0,
            0,
            b'.',
            b'F',
            b'I',
            b'T',
            0,
            0,
        ];
        let mut slots: [Option<MessageDefinition>; 16] = std::array::from_fn(|_| None);
        let mut next_slot = 0usize;
        for message in &self.messages {
            let definition = definition_of(message);
            let local = if let Some(index) = slots
                .iter()
                .position(|slot| slot.as_ref() == Some(&definition))
            {
                index
            } else {
                let index = next_slot;
                next_slot = (next_slot + 1) % slots.len();
                write_definition(&mut output, index as u8, &definition)?;
                slots[index] = Some(definition);
                index
            };
            checked_extend(&mut output, &[local as u8])?;
            for field in &message.fields {
                checked_extend(&mut output, value_bytes(&self.source, &field.value))?;
            }
            for field in &message.developer_fields {
                checked_extend(&mut output, value_bytes(&self.source, &field.value))?;
            }
        }

        let body_len =
            u32::try_from(output.len() - 14).map_err(|_| FitDecodeError::OutputTooLarge)?;
        output[4..8].copy_from_slice(&body_len.to_le_bytes());
        let header_crc = crc16(&output[..12]);
        output[12..14].copy_from_slice(&header_crc.to_le_bytes());
        let file_crc = crc16(&output);
        checked_extend(&mut output, &file_crc.to_le_bytes())?;
        Ok(output)
    }
}

fn parse_message(
    cursor: &mut usize,
    end: usize,
    definition: &MessageDefinition,
) -> Result<FitMessage, FitDecodeError> {
    let mut fields = Vec::with_capacity(definition.fields.len());
    for field in &definition.fields {
        fields.push(FitField {
            definition: field.clone(),
            value: FieldValue::Source(take_range(cursor, end, field.size)?),
        });
    }
    let mut developer_fields = Vec::with_capacity(definition.developer_fields.len());
    for field in &definition.developer_fields {
        developer_fields.push(FitDeveloperField {
            definition: field.clone(),
            value: FieldValue::Source(take_range(cursor, end, field.size)?),
        });
    }
    Ok(FitMessage {
        global_number: definition.global_number,
        big_endian: definition.big_endian,
        fields,
        developer_fields,
    })
}

fn insert_compressed_timestamp(message: &mut FitMessage, timestamp: u32) {
    let bytes = if message.big_endian {
        timestamp.to_be_bytes().to_vec()
    } else {
        timestamp.to_le_bytes().to_vec()
    };
    message.fields.insert(
        0,
        FitField {
            definition: FieldDefinition {
                number: 253,
                size: 4,
                base_type: BASE_TYPE_UINT32,
            },
            value: FieldValue::Owned(bytes),
        },
    );
}

fn raw_timestamp(source: &[u8], message: &FitMessage) -> Option<u32> {
    let field = message.fields.iter().find(|field| {
        field.definition.number == 253 && field.definition.base_type == BASE_TYPE_UINT32
    })?;
    let bytes: [u8; 4] = value_bytes(source, &field.value)
        .get(..4)?
        .try_into()
        .ok()?;
    let value = if message.big_endian {
        u32::from_be_bytes(bytes)
    } else {
        u32::from_le_bytes(bytes)
    };
    (value != u32::MAX).then_some(value)
}

fn checked_field_total(current: usize, message: &FitMessage) -> Result<usize, FitDecodeError> {
    let total = current
        .checked_add(message.fields.len())
        .and_then(|value| value.checked_add(message.developer_fields.len()))
        .ok_or(FitDecodeError::TooManyFields)?;
    if total > MAX_FIELDS {
        Err(FitDecodeError::TooManyFields)
    } else {
        Ok(total)
    }
}

fn checked_memory_total(current: usize, message: &FitMessage) -> Result<usize, FitDecodeError> {
    let mut added = std::mem::size_of::<FitMessage>()
        .checked_mul(2)
        .ok_or(FitDecodeError::TooManyFields)?;
    added = added
        .checked_add(
            message
                .fields
                .capacity()
                .checked_mul(std::mem::size_of::<FitField>())
                .ok_or(FitDecodeError::TooManyFields)?,
        )
        .and_then(|value| {
            value.checked_add(
                message
                    .developer_fields
                    .capacity()
                    .checked_mul(std::mem::size_of::<FitDeveloperField>())?,
            )
        })
        .ok_or(FitDecodeError::TooManyFields)?;
    if !message.fields.is_empty() {
        added = added
            .checked_add(ALLOCATION_OVERHEAD_BYTES)
            .ok_or(FitDecodeError::TooManyFields)?;
    }
    if !message.developer_fields.is_empty() {
        added = added
            .checked_add(ALLOCATION_OVERHEAD_BYTES)
            .ok_or(FitDecodeError::TooManyFields)?;
    }
    for value in message
        .fields
        .iter()
        .map(|field| &field.value)
        .chain(message.developer_fields.iter().map(|field| &field.value))
    {
        if let FieldValue::Owned(bytes) = value {
            added = added
                .checked_add(bytes.capacity())
                .and_then(|value| value.checked_add(ALLOCATION_OVERHEAD_BYTES))
                .ok_or(FitDecodeError::TooManyFields)?;
        }
    }
    let total = current
        .checked_add(added)
        .ok_or(FitDecodeError::TooManyFields)?;
    if total > MAX_DOCUMENT_MEMORY_BYTES {
        Err(FitDecodeError::TooManyFields)
    } else {
        Ok(total)
    }
}

fn invalid_u8(base_type: u8, value: u8) -> bool {
    match base_type {
        BASE_TYPE_UINT8Z => value == 0,
        _ => value == u8::MAX,
    }
}

fn invalid_u16(base_type: u8, value: u16) -> bool {
    match base_type {
        BASE_TYPE_UINT16Z => value == 0,
        _ => value == u16::MAX,
    }
}

fn invalid_u32(base_type: u8, value: u32) -> bool {
    match base_type {
        BASE_TYPE_UINT32Z => value == 0,
        _ => value == u32::MAX,
    }
}

fn push_message(messages: &mut Vec<FitMessage>, message: FitMessage) -> Result<(), FitDecodeError> {
    if messages.len() >= MAX_MESSAGES {
        return Err(FitDecodeError::TooManyMessages);
    }
    messages.push(message);
    Ok(())
}

fn definition_of(message: &FitMessage) -> MessageDefinition {
    MessageDefinition {
        global_number: message.global_number,
        big_endian: message.big_endian,
        fields: message
            .fields
            .iter()
            .map(|field| field.definition.clone())
            .collect(),
        developer_fields: message
            .developer_fields
            .iter()
            .map(|field| field.definition.clone())
            .collect(),
    }
}

fn write_definition(
    output: &mut Vec<u8>,
    local: u8,
    definition: &MessageDefinition,
) -> Result<(), FitDecodeError> {
    let mut header = 0x40 | local;
    if !definition.developer_fields.is_empty() {
        header |= 0x20;
    }
    checked_extend(output, &[header, 0, u8::from(definition.big_endian)])?;
    let global_number = if definition.big_endian {
        definition.global_number.to_be_bytes()
    } else {
        definition.global_number.to_le_bytes()
    };
    checked_extend(output, &global_number)?;
    let field_count =
        u8::try_from(definition.fields.len()).map_err(|_| FitDecodeError::TooManyFields)?;
    checked_extend(output, &[field_count])?;
    for field in &definition.fields {
        let size = u8::try_from(field.size).map_err(|_| FitDecodeError::InvalidDefinition)?;
        checked_extend(output, &[field.number, size, field.base_type])?;
    }
    if !definition.developer_fields.is_empty() {
        let count = u8::try_from(definition.developer_fields.len())
            .map_err(|_| FitDecodeError::TooManyFields)?;
        checked_extend(output, &[count])?;
        for field in &definition.developer_fields {
            let size = u8::try_from(field.size).map_err(|_| FitDecodeError::InvalidDefinition)?;
            checked_extend(output, &[field.number, size, field.developer_data_index])?;
        }
    }
    Ok(())
}

fn value_bytes<'a>(source: &'a [u8], value: &'a FieldValue) -> &'a [u8] {
    match value {
        FieldValue::Source(range) => &source[range.clone()],
        FieldValue::Owned(bytes) => bytes,
    }
}

fn checked_extend(output: &mut Vec<u8>, bytes: &[u8]) -> Result<(), FitDecodeError> {
    let next = output
        .len()
        .checked_add(bytes.len())
        .ok_or(FitDecodeError::OutputTooLarge)?;
    if next > MAX_FIT_BYTES {
        return Err(FitDecodeError::OutputTooLarge);
    }
    output.extend_from_slice(bytes);
    Ok(())
}

fn take<'a>(
    data: &'a [u8],
    cursor: &mut usize,
    end: usize,
    count: usize,
) -> Result<&'a [u8], FitDecodeError> {
    let range = take_range(cursor, end, count)?;
    Ok(&data[range])
}

fn take_range(
    cursor: &mut usize,
    end: usize,
    count: usize,
) -> Result<Range<usize>, FitDecodeError> {
    let next = cursor.checked_add(count).ok_or(FitDecodeError::Truncated)?;
    if next > end {
        return Err(FitDecodeError::Truncated);
    }
    let range = *cursor..next;
    *cursor = next;
    Ok(range)
}

#[cfg(test)]
mod tests {
    use super::{
        BASE_TYPE_UINT8, FieldDefinition, FieldValue, FitField, FitMessage, MAX_MESSAGES,
        checked_memory_total,
    };

    #[test]
    fn ast_memory_budget_stops_object_amplification_before_message_limit() {
        let message = FitMessage {
            global_number: 20,
            big_endian: false,
            fields: (0..16)
                .map(|number| FitField {
                    definition: FieldDefinition {
                        number,
                        size: 1,
                        base_type: BASE_TYPE_UINT8,
                    },
                    value: FieldValue::Source(0..1),
                })
                .collect(),
            developer_fields: Vec::new(),
        };
        let mut memory = 0;
        let mut accepted = 0;
        while let Ok(next) = checked_memory_total(memory, &message) {
            memory = next;
            accepted += 1;
        }
        assert!(accepted < MAX_MESSAGES);
    }
}
