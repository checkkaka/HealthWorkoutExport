use super::{MAX_FIT_BYTES, crc16};
use serde::Deserialize;
use std::collections::{BTreeMap, HashMap};
use std::fmt;

const FIT_EPOCH_UNIX_SECONDS: i64 = 631_065_600;
const MAX_POINTS: usize = 1_000_000;

const HEART_RATE: &str = "HKQuantityTypeIdentifierHeartRate";
const DISTANCE_KEYS: [&str; 3] = [
    "HKQuantityTypeIdentifierDistanceWalkingRunning",
    "HKQuantityTypeIdentifierDistanceCycling",
    "HKQuantityTypeIdentifierDistanceSwimming",
];
const SPEED_KEYS: [&str; 2] = [
    "HKQuantityTypeIdentifierRunningSpeed",
    "HKQuantityTypeIdentifierCyclingSpeed",
];
const CADENCE: &str = "HKQuantityTypeIdentifierCyclingCadence";
const POWER: &str = "HKQuantityTypeIdentifierRunningPower";
const STRIDE: &str = "HKQuantityTypeIdentifierRunningStrideLength";
const VERTICAL_OSCILLATION: &str = "HKQuantityTypeIdentifierRunningVerticalOscillation";
const GROUND_CONTACT_TIME: &str = "HKQuantityTypeIdentifierRunningGroundContactTime";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HealthFitError {
    InputTooLarge,
    InvalidJson,
    InvalidTime,
    InvalidValue,
    TooManyPoints,
    OutputTooLarge,
}

impl fmt::Display for HealthFitError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Bundle {
    uuid: String,
    start_ms: i64,
    end_ms: i64,
    duration_seconds: f64,
    activity_type: i64,
    #[serde(default)]
    total_energy_kcal: Option<f64>,
    #[serde(default)]
    total_distance_meters: Option<f64>,
    #[serde(default)]
    events: Vec<Event>,
    #[serde(default)]
    series: HashMap<String, Vec<Sample>>,
    #[serde(default)]
    route: Vec<RoutePoint>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Event {
    #[serde(rename = "type")]
    kind: String,
    date_ms: i64,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Sample {
    date_ms: i64,
    value: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RoutePoint {
    latitude: f64,
    longitude: f64,
    #[serde(default)]
    altitude_meters: Option<f64>,
    #[serde(default)]
    timestamp_ms: Option<i64>,
    #[serde(default)]
    speed_meters_per_second: Option<f64>,
}

#[derive(Default)]
struct Frame {
    latitude: Option<f64>,
    longitude: Option<f64>,
    altitude: Option<f64>,
    speed: Option<f64>,
    heart_rate: Option<f64>,
    distance: Option<f64>,
    cadence: Option<f64>,
    power: Option<f64>,
    stride: Option<f64>,
    vertical_oscillation: Option<f64>,
    ground_contact_time: Option<f64>,
}

#[derive(Clone, Eq, PartialEq)]
struct Definition {
    global_number: u16,
    fields: Vec<(u8, u8, u8)>,
}

struct Field {
    number: u8,
    base_type: u8,
    bytes: Vec<u8>,
}

struct Writer {
    body: Vec<u8>,
    definitions: [Option<Definition>; 16],
    next_slot: usize,
}

/// 将 iOS HealthKit bundle JSON 编码为单会话 Activity FIT。
pub fn encode_health_workout_bundle_json(
    json: &[u8],
    timezone_offset_seconds: i32,
) -> Result<Vec<u8>, HealthFitError> {
    if json.len() > MAX_FIT_BYTES {
        return Err(HealthFitError::InputTooLarge);
    }
    let bundle: Bundle = serde_json::from_slice(json).map_err(|_| HealthFitError::InvalidJson)?;
    validate_bundle(&bundle, timezone_offset_seconds)?;

    let start_unix = floor_seconds(bundle.start_ms);
    let end_unix = floor_seconds(bundle.end_ms);
    let start_fit = fit_timestamp(start_unix)?;
    let end_fit = fit_timestamp(end_unix)?;
    let wall_milliseconds = bundle
        .end_ms
        .checked_sub(bundle.start_ms)
        .ok_or(HealthFitError::InvalidTime)?;
    let wall_seconds = wall_milliseconds as f64 / 1000.0;
    let elapsed_seconds = wall_seconds.max(bundle.duration_seconds);
    let timer_seconds = active_timer_seconds(&bundle, wall_seconds);
    let sport = sport_for_healthkit(bundle.activity_type);
    let serial = stable_serial(&bundle.uuid);
    let mut writer = Writer::new();

    writer.message(
        0,
        vec![
            field_u8(0, 0x00, 4),
            field_u16(1, 255),
            field_u16(2, 1),
            field_u32(3, 0x8c, serial),
            field_u32(4, 0x86, start_fit),
        ],
    )?;
    writer.message(
        23,
        vec![
            field_u32(253, 0x86, start_fit),
            field_u8(0, 0x02, 0),
            field_u16(2, 255),
            field_u32(3, 0x8c, serial),
            field_u16(4, 1),
            field_u16(5, 100),
            field_bytes(27, 0x07, b"HK Export\0".to_vec()),
        ],
    )?;

    write_timer_event(&mut writer, start_fit, 0)?;
    let mut events: Vec<_> = bundle
        .events
        .iter()
        .filter_map(|event| event_type(&event.kind).map(|kind| (event.date_ms, kind)))
        .collect();
    events.sort_by_key(|event| event.0);
    for (date_ms, event_type) in events {
        if date_ms >= bundle.start_ms && date_ms <= bundle.end_ms {
            write_timer_event(
                &mut writer,
                fit_timestamp(floor_seconds(date_ms))?,
                event_type,
            )?;
        }
    }

    let frames = build_frames(&bundle)?;
    let heart_rates = bundle
        .series
        .get(HEART_RATE)
        .into_iter()
        .flatten()
        .map(|sample| sample.value)
        .filter(|value| value.is_finite() && *value >= 0.0)
        .collect::<Vec<_>>();
    for (timestamp, frame) in frames {
        write_record(&mut writer, fit_timestamp(timestamp)?, frame)?;
    }
    write_timer_event(&mut writer, end_fit, 4)?;

    let average_heart_rate = (!heart_rates.is_empty())
        .then(|| heart_rates.iter().sum::<f64>() / heart_rates.len() as f64);
    let maximum_heart_rate = heart_rates.iter().copied().reduce(f64::max);
    let average_speed = bundle
        .total_distance_meters
        .filter(|_| timer_seconds > 0.0)
        .map(|distance| distance / timer_seconds);
    writer.message(
        19,
        summary_fields(
            true,
            end_fit,
            start_fit,
            elapsed_seconds,
            timer_seconds,
            bundle.total_distance_meters,
            bundle.total_energy_kcal,
            average_speed,
            average_heart_rate,
            maximum_heart_rate,
            sport,
        )?,
    )?;
    writer.message(
        18,
        summary_fields(
            false,
            end_fit,
            start_fit,
            elapsed_seconds,
            timer_seconds,
            bundle.total_distance_meters,
            bundle.total_energy_kcal,
            average_speed,
            average_heart_rate,
            maximum_heart_rate,
            sport,
        )?,
    )?;
    let local_timestamp = i64::from(end_fit) + i64::from(timezone_offset_seconds);
    if !(0..=i64::from(u32::MAX - 1)).contains(&local_timestamp) {
        return Err(HealthFitError::InvalidTime);
    }
    writer.message(
        34,
        vec![
            field_u32(253, 0x86, end_fit),
            scaled_u32(0, timer_seconds, 1000.0)?,
            field_u16(1, 1),
            field_u8(2, 0x00, 0),
            field_u32(5, 0x86, local_timestamp as u32),
        ],
    )?;
    writer.finish()
}

fn validate_bundle(bundle: &Bundle, timezone_offset_seconds: i32) -> Result<(), HealthFitError> {
    if bundle.start_ms > bundle.end_ms
        || !bundle.duration_seconds.is_finite()
        || bundle.duration_seconds < 0.0
        || timezone_offset_seconds.unsigned_abs() > 86_400
    {
        return Err(HealthFitError::InvalidTime);
    }
    let point_count = bundle
        .route
        .len()
        .checked_add(bundle.events.len())
        .and_then(|count| {
            bundle
                .series
                .values()
                .try_fold(count, |sum, samples| sum.checked_add(samples.len()))
        })
        .ok_or(HealthFitError::TooManyPoints)?;
    if point_count > MAX_POINTS {
        return Err(HealthFitError::TooManyPoints);
    }
    for value in [bundle.total_energy_kcal, bundle.total_distance_meters]
        .into_iter()
        .flatten()
    {
        if !value.is_finite() || value < 0.0 {
            return Err(HealthFitError::InvalidValue);
        }
    }
    Ok(())
}

fn build_frames(bundle: &Bundle) -> Result<BTreeMap<i64, Frame>, HealthFitError> {
    let mut frames = BTreeMap::<i64, Frame>::new();
    for point in &bundle.route {
        if !point.latitude.is_finite()
            || !point.longitude.is_finite()
            || !(-90.0..=90.0).contains(&point.latitude)
            || !(-180.0..=180.0).contains(&point.longitude)
        {
            return Err(HealthFitError::InvalidValue);
        }
        validate_optional(point.altitude_meters, false)?;
        validate_optional(point.speed_meters_per_second, true)?;
        let frame = frames
            .entry(floor_seconds(point.timestamp_ms.unwrap_or(bundle.start_ms)))
            .or_default();
        frame.latitude = Some(point.latitude);
        frame.longitude = Some(point.longitude);
        frame.altitude = point.altitude_meters;
        if point.speed_meters_per_second.is_some() {
            frame.speed = point.speed_meters_per_second;
        }
    }
    apply_series(
        &mut frames,
        bundle.series.get(HEART_RATE),
        |frame, value| frame.heart_rate = Some(value),
        true,
    )?;

    let mut distance_samples = Vec::new();
    for (rank, key) in DISTANCE_KEYS.iter().enumerate() {
        if let Some(samples) = bundle.series.get(*key) {
            for (ordinal, sample) in samples.iter().enumerate() {
                validate_value(sample.value, true)?;
                distance_samples.push((sample.date_ms, rank, ordinal, sample.value));
            }
        }
    }
    distance_samples.sort_by_key(|sample| (sample.0, sample.1, sample.2));
    let mut distance = 0.0;
    for (date_ms, _, _, increment) in distance_samples {
        distance += increment;
        if !distance.is_finite() {
            return Err(HealthFitError::InvalidValue);
        }
        frames.entry(floor_seconds(date_ms)).or_default().distance = Some(distance);
    }
    for key in SPEED_KEYS {
        apply_series(
            &mut frames,
            bundle.series.get(key),
            |frame, value| frame.speed = Some(value),
            true,
        )?;
    }
    apply_series(
        &mut frames,
        bundle.series.get(CADENCE),
        |frame, value| frame.cadence = Some(value),
        true,
    )?;
    apply_series(
        &mut frames,
        bundle.series.get(POWER),
        |frame, value| frame.power = Some(value),
        true,
    )?;
    apply_series(
        &mut frames,
        bundle.series.get(STRIDE),
        |frame, value| frame.stride = Some(value),
        true,
    )?;
    apply_series(
        &mut frames,
        bundle.series.get(VERTICAL_OSCILLATION),
        |frame, value| frame.vertical_oscillation = Some(value),
        true,
    )?;
    apply_series(
        &mut frames,
        bundle.series.get(GROUND_CONTACT_TIME),
        |frame, value| frame.ground_contact_time = Some(value),
        true,
    )?;
    if frames.is_empty() {
        frames.insert(floor_seconds(bundle.start_ms), Frame::default());
    }
    Ok(frames)
}

fn apply_series(
    frames: &mut BTreeMap<i64, Frame>,
    samples: Option<&Vec<Sample>>,
    mut apply: impl FnMut(&mut Frame, f64),
    nonnegative: bool,
) -> Result<(), HealthFitError> {
    for sample in samples.into_iter().flatten() {
        validate_value(sample.value, nonnegative)?;
        apply(
            frames.entry(floor_seconds(sample.date_ms)).or_default(),
            sample.value,
        );
    }
    Ok(())
}

fn active_timer_seconds(bundle: &Bundle, wall_seconds: f64) -> f64 {
    let mut transitions: Vec<_> = bundle
        .events
        .iter()
        .filter(|event| event.date_ms >= bundle.start_ms && event.date_ms <= bundle.end_ms)
        .filter_map(|event| event_type(&event.kind).map(|kind| (event.date_ms, kind)))
        .collect();
    transitions.sort_by_key(|event| event.0);
    if transitions.is_empty() {
        return bundle.duration_seconds.min(wall_seconds).max(0.0);
    }
    let mut running = true;
    let mut segment_start = bundle.start_ms;
    let mut active_ms = 0_i64;
    for (date_ms, kind) in transitions {
        match (running, kind) {
            (true, 4) => {
                active_ms += date_ms - segment_start;
                running = false;
            }
            (false, 0) => {
                segment_start = date_ms;
                running = true;
            }
            _ => {}
        }
    }
    if running {
        active_ms += bundle.end_ms - segment_start;
    }
    active_ms.max(0) as f64 / 1000.0
}

fn event_type(kind: &str) -> Option<u8> {
    match kind {
        "pause" | "motionPaused" => Some(4),
        "resume" | "motionResumed" => Some(0),
        _ => None,
    }
}

fn write_timer_event(
    writer: &mut Writer,
    timestamp: u32,
    event_type: u8,
) -> Result<(), HealthFitError> {
    writer.message(
        21,
        vec![
            field_u32(253, 0x86, timestamp),
            field_u8(0, 0x00, 0),
            field_u8(1, 0x00, event_type),
        ],
    )
}

fn write_record(writer: &mut Writer, timestamp: u32, frame: Frame) -> Result<(), HealthFitError> {
    let mut fields = vec![field_u32(253, 0x86, timestamp)];
    if let (Some(latitude), Some(longitude)) = (frame.latitude, frame.longitude) {
        fields.push(field_i32(0, semicircles(latitude)));
        fields.push(field_i32(1, semicircles(longitude)));
    }
    if let Some(value) = frame.altitude {
        fields.push(scaled_u16_offset(2, value, 5.0, 500.0)?);
    }
    if let Some(value) = frame.heart_rate {
        fields.push(scaled_u8(3, value, 1.0)?);
    }
    if let Some(value) = frame.cadence {
        fields.push(scaled_u8(4, value, 1.0)?);
    }
    if let Some(value) = frame.distance {
        fields.push(scaled_u32(5, value, 100.0)?);
    }
    if let Some(value) = frame.speed {
        fields.push(scaled_u16(6, value, 1000.0)?);
    }
    if let Some(value) = frame.power {
        fields.push(scaled_u16(7, value, 1.0)?);
    }
    if let Some(value) = frame.vertical_oscillation {
        fields.push(scaled_u16(39, value, 10_000.0)?);
    }
    if let Some(value) = frame.ground_contact_time {
        fields.push(scaled_u16(41, value, 10.0)?);
    }
    if let Some(value) = frame.stride {
        fields.push(scaled_u16(85, value, 10_000.0)?);
    }
    writer.message(20, fields)
}

#[allow(clippy::too_many_arguments)]
fn summary_fields(
    lap: bool,
    timestamp: u32,
    start_time: u32,
    elapsed: f64,
    timer: f64,
    distance: Option<f64>,
    calories: Option<f64>,
    average_speed: Option<f64>,
    average_hr: Option<f64>,
    maximum_hr: Option<f64>,
    sport: u8,
) -> Result<Vec<Field>, HealthFitError> {
    let mut fields = vec![
        field_u16(254, 0),
        field_u32(253, 0x86, timestamp),
        field_u32(2, 0x86, start_time),
        scaled_u32(7, elapsed, 1000.0)?,
        scaled_u32(8, timer, 1000.0)?,
    ];
    if let Some(value) = distance {
        fields.push(scaled_u32(9, value, 100.0)?);
    }
    if let Some(value) = calories {
        fields.push(scaled_u16(11, value, 1.0)?);
    }
    if let Some(value) = average_speed {
        fields.push(scaled_u16(if lap { 13 } else { 14 }, value, 1000.0)?);
    }
    if let Some(value) = average_hr {
        fields.push(scaled_u8(if lap { 15 } else { 16 }, value, 1.0)?);
    }
    if let Some(value) = maximum_hr {
        fields.push(scaled_u8(if lap { 16 } else { 17 }, value, 1.0)?);
    }
    fields.push(field_u8(if lap { 25 } else { 5 }, 0x00, sport));
    fields.push(field_u8(if lap { 39 } else { 6 }, 0x00, 0));
    if !lap {
        fields.push(field_u16(25, 0));
        fields.push(field_u16(26, 1));
    }
    Ok(fields)
}

impl Writer {
    fn new() -> Self {
        Self {
            body: Vec::new(),
            definitions: std::array::from_fn(|_| None),
            next_slot: 0,
        }
    }

    fn message(&mut self, global_number: u16, fields: Vec<Field>) -> Result<(), HealthFitError> {
        let definition = Definition {
            global_number,
            fields: fields
                .iter()
                .map(|field| (field.number, field.bytes.len() as u8, field.base_type))
                .collect(),
        };
        let local = self
            .definitions
            .iter()
            .position(|current| current.as_ref() == Some(&definition))
            .unwrap_or_else(|| {
                let local = self.next_slot;
                self.next_slot = (self.next_slot + 1) % self.definitions.len();
                local
            });
        if self.definitions[local].as_ref() != Some(&definition) {
            self.push(&[0x40 | local as u8, 0, 0])?;
            self.push(&global_number.to_le_bytes())?;
            self.push(&[definition.fields.len() as u8])?;
            for &(number, size, base_type) in &definition.fields {
                self.push(&[number, size, base_type])?;
            }
            self.definitions[local] = Some(definition);
        }
        self.push(&[local as u8])?;
        for field in fields {
            self.push(&field.bytes)?;
        }
        Ok(())
    }

    fn push(&mut self, bytes: &[u8]) -> Result<(), HealthFitError> {
        if self
            .body
            .len()
            .checked_add(bytes.len())
            .is_none_or(|size| size > MAX_FIT_BYTES - 16)
        {
            return Err(HealthFitError::OutputTooLarge);
        }
        self.body.extend_from_slice(bytes);
        Ok(())
    }

    fn finish(self) -> Result<Vec<u8>, HealthFitError> {
        let body_size =
            u32::try_from(self.body.len()).map_err(|_| HealthFitError::OutputTooLarge)?;
        let mut output = vec![0x0e, 0x20, 0xd5, 0x52];
        output.extend_from_slice(&body_size.to_le_bytes());
        output.extend_from_slice(b".FIT");
        output.extend_from_slice(&crc16(&output).to_le_bytes());
        output.extend_from_slice(&self.body);
        output.extend_from_slice(&crc16(&output).to_le_bytes());
        Ok(output)
    }
}

fn field_bytes(number: u8, base_type: u8, bytes: Vec<u8>) -> Field {
    Field {
        number,
        base_type,
        bytes,
    }
}
fn field_u8(number: u8, base_type: u8, value: u8) -> Field {
    field_bytes(number, base_type, vec![value])
}
fn field_u16(number: u8, value: u16) -> Field {
    field_bytes(number, 0x84, value.to_le_bytes().to_vec())
}
fn field_u32(number: u8, base_type: u8, value: u32) -> Field {
    field_bytes(number, base_type, value.to_le_bytes().to_vec())
}
fn field_i32(number: u8, value: i32) -> Field {
    field_bytes(number, 0x85, value.to_le_bytes().to_vec())
}

fn scaled_u8(number: u8, value: f64, scale: f64) -> Result<Field, HealthFitError> {
    Ok(field_u8(number, 0x02, scaled(value, scale, 254)? as u8))
}
fn scaled_u16(number: u8, value: f64, scale: f64) -> Result<Field, HealthFitError> {
    Ok(field_u16(
        number,
        scaled(value, scale, u64::from(u16::MAX - 1))? as u16,
    ))
}
fn scaled_u16_offset(
    number: u8,
    value: f64,
    scale: f64,
    offset: f64,
) -> Result<Field, HealthFitError> {
    scaled_u16(number, value + offset, scale)
}
fn scaled_u32(number: u8, value: f64, scale: f64) -> Result<Field, HealthFitError> {
    Ok(field_u32(
        number,
        0x86,
        scaled(value, scale, u64::from(u32::MAX - 1))? as u32,
    ))
}
fn scaled(value: f64, scale: f64, maximum: u64) -> Result<u64, HealthFitError> {
    if !value.is_finite() || value < 0.0 {
        return Err(HealthFitError::InvalidValue);
    }
    Ok((value * scale).round().clamp(0.0, maximum as f64) as u64)
}

fn validate_optional(value: Option<f64>, nonnegative: bool) -> Result<(), HealthFitError> {
    if let Some(value) = value {
        validate_value(value, nonnegative)
    } else {
        Ok(())
    }
}
fn validate_value(value: f64, nonnegative: bool) -> Result<(), HealthFitError> {
    if !value.is_finite() || (nonnegative && value < 0.0) {
        Err(HealthFitError::InvalidValue)
    } else {
        Ok(())
    }
}

fn floor_seconds(milliseconds: i64) -> i64 {
    milliseconds.div_euclid(1000)
}
fn fit_timestamp(unix_seconds: i64) -> Result<u32, HealthFitError> {
    u32::try_from(
        unix_seconds
            .checked_sub(FIT_EPOCH_UNIX_SECONDS)
            .ok_or(HealthFitError::InvalidTime)?,
    )
    .ok()
    .filter(|value| *value != u32::MAX)
    .ok_or(HealthFitError::InvalidTime)
}
fn semicircles(degrees: f64) -> i32 {
    (degrees * 2_147_483_648.0 / 180.0).round() as i64 as i32
}
fn stable_serial(uuid: &str) -> u32 {
    let hash = uuid.bytes().fold(2_166_136_261_u32, |hash, byte| {
        (hash ^ u32::from(byte)).wrapping_mul(16_777_619)
    });
    hash.clamp(1, u32::MAX - 1)
}

fn sport_for_healthkit(activity_type: i64) -> u8 {
    match activity_type {
        37 => 1,
        13 => 2,
        52 => 11,
        24 => 17,
        46 => 5,
        20 | 50 | 57 | 62 | 63 | 66 => 10,
        14 | 16 => 4,
        35 => 15,
        41 => 7,
        6 => 6,
        48 => 8,
        21 => 25,
        61 => 13,
        67 => 14,
        9 => 31,
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fit::FitDocument;

    #[test]
    fn encodes_healthkit_activity_with_pause_aware_timer_and_merged_records() {
        let start_ms = 1_700_000_000_123_i64;
        let json = format!(
            r#"{{
                "uuid":"stable-id","startMs":{start_ms},"endMs":{},"durationSeconds":50.0,
                "activityType":13,"totalEnergyKcal":321.0,"totalDistanceMeters":30.0,
                "events":[
                    {{"type":"pause","dateMs":{}}},
                    {{"type":"resume","dateMs":{}}}
                ],
                "series":{{
                    "HKQuantityTypeIdentifierHeartRate":[{{"dateMs":{},"value":120.0,"unit":"count/min"}}],
                    "HKQuantityTypeIdentifierDistanceWalkingRunning":[{{"dateMs":{},"value":10.0,"unit":"m"}}],
                    "HKQuantityTypeIdentifierDistanceCycling":[{{"dateMs":{},"value":20.0,"unit":"m"}}],
                    "HKQuantityTypeIdentifierRunningSpeed":[{{"dateMs":{},"value":3.0,"unit":"m/s"}}],
                    "HKQuantityTypeIdentifierCyclingSpeed":[{{"dateMs":{},"value":4.0,"unit":"m/s"}}]
                }},
                "route":[
                    {{"latitude":1.0,"longitude":2.0,"timestampMs":{}}},
                    {{"latitude":3.0,"longitude":4.0,"timestampMs":{}}}
                ]
            }}"#,
            start_ms + 100_000,
            start_ms + 30_000,
            start_ms + 80_000,
            start_ms + 1_700,
            start_ms + 1_100,
            start_ms + 1_500,
            start_ms + 1_200,
            start_ms + 1_800,
            start_ms + 1_300,
            start_ms + 1_600,
        );
        let fit = encode_health_workout_bundle_json(json.as_bytes(), 28_800).unwrap();
        let document = FitDocument::parse(&fit).unwrap();
        let globals: Vec<_> = document
            .messages()
            .iter()
            .map(|message| message.global_number())
            .collect();
        for required in [0, 23, 21, 20, 19, 18, 34] {
            assert!(globals.contains(&required));
        }
        let record = globals.iter().position(|global| *global == 20).unwrap();
        assert_eq!(document.read_i32(record, 0), Some(semicircles(3.0)));
        assert_eq!(document.read_i32(record, 1), Some(semicircles(4.0)));
        assert_eq!(document.read_u32(record, 5), Some(3_000));
        assert_eq!(document.read_u16(record, 6), Some(4_000));
        let session = globals.iter().position(|global| *global == 18).unwrap();
        assert_eq!(document.read_u32(session, 8), Some(50_000));
        assert_eq!(document.read_u8(session, 5), Some(2));
        let activity = globals.iter().position(|global| *global == 34).unwrap();
        assert_eq!(document.read_u32(activity, 0), Some(50_000));
        assert_eq!(
            document.read_u32(activity, 5),
            Some(fit_timestamp(floor_seconds(start_ms + 100_000)).unwrap() + 28_800)
        );
    }

    #[test]
    fn maps_only_the_same_healthkit_activity_types_as_the_swift_encoder() {
        assert_eq!(sport_for_healthkit(66), 10); // Pilates
        assert_eq!(sport_for_healthkit(62), 10); // Flexibility
        assert_eq!(sport_for_healthkit(63), 10); // HIIT
        assert_eq!(sport_for_healthkit(61), 13); // Downhill skiing
        assert_eq!(sport_for_healthkit(67), 14); // Snowboarding
        assert_eq!(sport_for_healthkit(60), 0); // Cross-country skiing was generic in Swift.
        assert_eq!(sport_for_healthkit(71), 0); // Wheelchair running was generic in Swift.
        assert_eq!(sport_for_healthkit(84), 0); // Underwater diving was generic in Swift.
    }

    #[test]
    fn emits_start_record_when_bundle_has_no_samples() {
        let json = br#"{
            "uuid":"empty","startMs":1700000000123,"endMs":1700000010123,
            "durationSeconds":10.0,"activityType":37,"events":[],"series":{},"route":[]
        }"#;
        let fit = encode_health_workout_bundle_json(json, 0).unwrap();
        let document = FitDocument::parse(&fit).unwrap();
        let record = document
            .messages()
            .iter()
            .position(|message| message.global_number() == 20)
            .unwrap();
        assert_eq!(
            document.read_u32(record, 253),
            Some(fit_timestamp(1_700_000_000).unwrap())
        );
    }
}
