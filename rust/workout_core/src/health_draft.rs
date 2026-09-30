//! FIT → Apple Health write draft. This module performs no HealthKit or network I/O.
//! Units and timestamp fields are explicit so native writers never infer missing data.
use crate::fit::{FitDecodeError, FitDocument};
use serde::Serialize;
use std::collections::BTreeMap;
use std::fmt;
use std::io::{self, Write};

const FIT_EPOCH_UNIX_SECONDS: i64 = 631_065_600;
const MAX_POINTS: usize = 1_000_000;
const MAX_JSON_BYTES: usize = 64 * 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum HealthDraftError {
    InvalidFingerprint,
    InvalidFit(FitDecodeError),
    MissingTime,
    TooManyPoints,
    OutputTooLarge,
}

impl fmt::Display for HealthDraftError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Draft<'a> {
    fingerprint: &'a str,
    activity_type: u32,
    start_ms: i64,
    end_ms: i64,
    duration_seconds: f64,
    distance_meters: Option<f64>,
    energy_kilocalories: Option<f64>,
    locations: Vec<RoutePoint>,
    heart_rate: Vec<Sample>,
    cadence: Vec<Sample>,
    power: Vec<Sample>,
    speed: Vec<Sample>,
    events: Vec<Event>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Sample {
    date_ms: i64,
    value: f64,
    unit: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RoutePoint {
    latitude: f64,
    longitude: f64,
    altitude_meters: Option<f64>,
    timestamp_ms: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Event {
    #[serde(rename = "type")]
    kind: &'static str,
    date_ms: i64,
}

/// Mirrors Swift `HealthWorkoutDraft.fromFIT`, including the first-session summary,
/// standard-before-enhanced records, and omission of initial/final timer events.
/// Invalid FIT sentinels are absent values, never zero-filled samples.
pub fn decode_fit_health_draft_json(
    data: &[u8],
    fingerprint: &str,
) -> Result<Vec<u8>, HealthDraftError> {
    if !crate::sync_state::is_valid_fingerprint(fingerprint) {
        return Err(HealthDraftError::InvalidFingerprint);
    }
    let document = FitDocument::parse(data).map_err(HealthDraftError::InvalidFit)?;
    let session = document
        .messages()
        .iter()
        .position(|m| m.global_number() == 18);
    let mut records: Vec<_> = document
        .messages()
        .iter()
        .enumerate()
        .filter(|(_, m)| m.global_number() == 20)
        .map(|(index, _)| (document.read_u32(index, 253), index))
        .collect();
    // Stable ordering also preserves the Swift first-altitude-at-a-date rule.
    records.sort_by_key(|&(timestamp, _)| timestamp);
    let first_time = records.iter().find_map(|&(time, _)| time);
    let last_time = records.iter().rev().find_map(|&(time, _)| time);
    let start = session
        .and_then(|i| document.read_u32(i, 2))
        .or(first_time)
        .ok_or(HealthDraftError::MissingTime)?;
    let end = session
        .and_then(|i| document.read_u32(i, 253))
        .or(last_time)
        .ok_or(HealthDraftError::MissingTime)?;
    let mut draft = Draft {
        fingerprint,
        activity_type: healthkit_activity_type(session.and_then(|i| document.read_u8(i, 5))),
        start_ms: timestamp_ms(start),
        end_ms: timestamp_ms(end.max(start)),
        duration_seconds: session
            .and_then(|i| document.read_u32(i, 8))
            .map(|v| f64::from(v) / 1000.0)
            .unwrap_or(f64::from(end.saturating_sub(start))),
        distance_meters: document
            .messages()
            .iter()
            .enumerate()
            .filter(|(_, m)| m.global_number() == 18)
            .find_map(|(i, _)| document.read_u32(i, 9))
            .or_else(|| {
                records
                    .iter()
                    .rev()
                    .find_map(|&(_, i)| document.read_u32(i, 5))
            })
            .map(|v| f64::from(v) / 100.0),
        energy_kilocalories: session
            .and_then(|i| document.read_u16(i, 11))
            .map(f64::from),
        locations: Vec::new(),
        heart_rate: Vec::new(),
        cadence: Vec::new(),
        power: Vec::new(),
        speed: Vec::new(),
        events: Vec::new(),
    };
    let mut altitudes = BTreeMap::new();
    for &(time, index) in &records {
        if let Some(time) = time
            && let Some(altitude) = document
                .read_u16(index, 2)
                .map(u32::from)
                .or_else(|| document.read_u32(index, 78))
        {
            altitudes
                .entry(time)
                .or_insert(f64::from(altitude) / 5.0 - 500.0);
        }
    }
    let mut point_count = 0;
    for (time, index) in records {
        let Some(time) = time else { continue };
        let date_ms = timestamp_ms(time);
        for (value, samples, unit) in [
            (
                document.read_u8(index, 3).map(f64::from),
                &mut draft.heart_rate,
                "count/min",
            ),
            (
                document.read_u8(index, 4).map(f64::from),
                &mut draft.cadence,
                "rpm",
            ),
            (
                document.read_u16(index, 7).map(f64::from),
                &mut draft.power,
                "W",
            ),
            (
                document
                    .read_u16(index, 6)
                    .map(u32::from)
                    .or_else(|| document.read_u32(index, 73))
                    .map(|v| f64::from(v) / 1000.0),
                &mut draft.speed,
                "m/s",
            ),
        ] {
            if let Some(value) = value {
                count_point(&mut point_count)?;
                samples.push(Sample {
                    date_ms,
                    value,
                    unit,
                });
            }
        }
        if let (Some(lat), Some(lon)) = (document.read_i32(index, 0), document.read_i32(index, 1)) {
            let latitude = f64::from(lat) * 180.0 / 2_147_483_648.0;
            let longitude = f64::from(lon) * 180.0 / 2_147_483_648.0;
            if (-90.0..=90.0).contains(&latitude) && (-180.0..=180.0).contains(&longitude) {
                count_point(&mut point_count)?;
                draft.locations.push(RoutePoint {
                    latitude,
                    longitude,
                    altitude_meters: altitudes.get(&time).copied(),
                    timestamp_ms: date_ms,
                });
            }
        }
    }
    for (i, message) in document.messages().iter().enumerate() {
        if message.global_number() != 21 || document.read_u8(i, 0) != Some(0) {
            continue;
        }
        let Some(time) = document.read_u32(i, 253) else {
            continue;
        };
        let kind = match document.read_u8(i, 1) {
            Some(0) if time > start => "resume",
            Some(1 | 4 | 8 | 9) if time != end => "pause",
            _ => continue,
        };
        count_point(&mut point_count)?;
        draft.events.push(Event {
            kind,
            date_ms: timestamp_ms(time),
        });
    }
    // FIT event blocks need not be in chronological wire order. Preserve ties.
    draft.events.sort_by_key(|event| event.date_ms);
    let mut output = BoundedOutput(Vec::new());
    serde_json::to_writer(&mut output, &draft).map_err(|_| HealthDraftError::OutputTooLarge)?;
    Ok(output.0)
}

fn count_point(count: &mut usize) -> Result<(), HealthDraftError> {
    if *count >= MAX_POINTS {
        return Err(HealthDraftError::TooManyPoints);
    }
    *count += 1;
    Ok(())
}

fn timestamp_ms(timestamp: u32) -> i64 {
    (FIT_EPOCH_UNIX_SECONDS + i64::from(timestamp)) * 1000
}

fn healthkit_activity_type(sport: Option<u8>) -> u32 {
    match sport {
        Some(1) => 37,
        Some(2) => 13,
        Some(11) => 52,
        Some(17) => 24,
        Some(5) => 46,
        Some(10) => 50,
        Some(15) => 35,
        Some(4) => 16,
        Some(7) => 41,
        Some(6) => 6,
        Some(8) => 48,
        Some(25) => 21,
        Some(13) => 61,
        Some(14) => 67,
        Some(31) => 9,
        _ => 3000,
    }
}

struct BoundedOutput(Vec<u8>);
impl Write for BoundedOutput {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > MAX_JSON_BYTES.saturating_sub(self.0.len()) {
            return Err(io::Error::other("Health draft exceeds JSON size limit"));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    type Field = (u8, u8, Vec<u8>);
    fn u8f(number: u8, value: u8) -> Field {
        (number, 0x02, vec![value])
    }
    fn u16f(number: u8, value: u16) -> Field {
        (number, 0x84, value.to_le_bytes().to_vec())
    }
    fn u32f(number: u8, value: u32) -> Field {
        (number, 0x86, value.to_le_bytes().to_vec())
    }
    fn i32f(number: u8, value: i32) -> Field {
        (number, 0x85, value.to_le_bytes().to_vec())
    }
    fn fit(messages: Vec<(u16, Vec<Field>)>) -> Vec<u8> {
        let mut body = Vec::new();
        for (global, fields) in messages {
            body.extend_from_slice(&[0x40, 0, 0]);
            body.extend_from_slice(&global.to_le_bytes());
            body.push(fields.len() as u8);
            for (number, base, value) in &fields {
                body.extend_from_slice(&[*number, value.len() as u8, *base]);
            }
            body.push(0);
            for (_, _, value) in fields {
                body.extend(value);
            }
        }
        let mut data = vec![12, 0x20, 0, 0];
        data.extend_from_slice(&(body.len() as u32).to_le_bytes());
        data.extend_from_slice(b".FIT");
        data.extend(body);
        let mut crc = 0_u16;
        for byte in &data {
            crc ^= u16::from(*byte);
            for _ in 0..8 {
                crc = if crc & 1 != 0 {
                    (crc >> 1) ^ 0xA001
                } else {
                    crc >> 1
                };
            }
        }
        data.extend_from_slice(&crc.to_le_bytes());
        data
    }
    fn decode(messages: Vec<(u16, Vec<Field>)>) -> Value {
        serde_json::from_slice(
            &decode_fit_health_draft_json(&fit(messages), &"a".repeat(64)).unwrap(),
        )
        .unwrap()
    }
    fn timer(time: u32, kind: u8) -> (u16, Vec<Field>) {
        (21, vec![u32f(253, time), u8f(0, 0), u8f(1, kind)])
    }

    #[test]
    fn converts_session_summary_all_series_route_and_timer_events() {
        let value = decode(vec![
            (
                18,
                vec![
                    u32f(2, 100),
                    u32f(253, 200),
                    u8f(5, 2),
                    u32f(8, 80_500),
                    u32f(9, 12_345),
                    u16f(11, 321),
                ],
            ),
            (
                20,
                vec![
                    u32f(253, 110),
                    u8f(3, 120),
                    u8f(4, 90),
                    u16f(7, 220),
                    u16f(6, 5678),
                    u16f(2, 3000),
                    i32f(0, 1 << 29),
                    i32f(1, 1 << 30),
                ],
            ),
            timer(100, 0),
            timer(130, 4),
            timer(140, 0),
            timer(200, 1),
            (21, vec![u32f(253, 150), u8f(0, 3), u8f(1, 4)]),
        ]);
        assert_eq!(value["activityType"], 13);
        assert_eq!(value["startMs"], timestamp_ms(100));
        assert_eq!(value["endMs"], timestamp_ms(200));
        assert_eq!(value["durationSeconds"], 80.5);
        assert_eq!(value["distanceMeters"], 123.45);
        assert_eq!(value["energyKilocalories"], 321.0);
        for (key, number, unit) in [
            ("heartRate", 120.0, "count/min"),
            ("cadence", 90.0, "rpm"),
            ("power", 220.0, "W"),
            ("speed", 5.678, "m/s"),
        ] {
            assert_eq!(
                value[key],
                json!([{"dateMs":timestamp_ms(110),"value":number,"unit":unit}])
            );
        }
        assert_eq!(
            value["locations"],
            json!([{"latitude":45.0,"longitude":90.0,"altitudeMeters":100.0,"timestampMs":timestamp_ms(110)}])
        );
        assert_eq!(
            value["events"],
            json!([{"type":"pause","dateMs":timestamp_ms(130)},{"type":"resume","dateMs":timestamp_ms(140)}])
        );
    }

    #[test]
    fn canonicalizes_event_order_and_skips_invalid_timestamps() {
        let value = decode(vec![
            (20, vec![u32f(253, 100)]),
            (20, vec![u32f(253, 200)]),
            timer(140, 0),
            timer(130, 4),
            timer(u32::MAX, 4),
        ]);
        assert_eq!(
            value["events"],
            json!([
                {"type":"pause","dateMs":timestamp_ms(130)},
                {"type":"resume","dateMs":timestamp_ms(140)},
            ])
        );
    }

    #[test]
    fn sorts_record_fallbacks_and_does_not_invent_missing_measurements() {
        let value = decode(vec![
            (20, vec![u32f(253, 120), u32f(5, 9900)]),
            (20, vec![u32f(253, 100)]),
            (20, vec![u8f(3, 123)]), // No time: cannot associate this measurement.
        ]);
        assert_eq!(value["startMs"], timestamp_ms(100));
        assert_eq!(value["endMs"], timestamp_ms(120));
        assert_eq!(value["durationSeconds"], 20.0);
        assert_eq!(value["activityType"], 3000);
        assert_eq!(value["distanceMeters"], 99.0);
        assert!(value["energyKilocalories"].is_null());
        for key in [
            "locations",
            "heartRate",
            "cadence",
            "power",
            "speed",
            "events",
        ] {
            assert_eq!(value[key], json!([]));
        }
        let no_summary = decode(vec![(20, vec![u32f(253, 100)])]);
        assert!(no_summary["distanceMeters"].is_null());
        assert_eq!(no_summary["durationSeconds"], 0.0);
    }

    #[test]
    fn uses_standard_fields_before_enhanced_and_skips_invalid_sentinels() {
        let value = decode(vec![
            (
                20,
                vec![
                    u32f(253, 100),
                    u16f(6, 1000),
                    u32f(73, 2000),
                    u16f(2, 2500),
                    u32f(78, 5000),
                    i32f(0, 0),
                    i32f(1, 0),
                ],
            ),
            (
                20,
                vec![
                    u32f(253, 101),
                    u16f(6, u16::MAX),
                    u32f(73, 2500),
                    u16f(2, u16::MAX),
                    u32f(78, 3000),
                    i32f(0, 0),
                    i32f(1, 0),
                ],
            ),
            (
                20,
                vec![
                    u32f(253, 102),
                    u8f(3, u8::MAX),
                    u8f(4, u8::MAX),
                    u16f(7, u16::MAX),
                    u32f(73, u32::MAX),
                    i32f(0, i32::MAX),
                    i32f(1, 0),
                ],
            ),
            (20, vec![u32f(253, 103), i32f(0, 1_500_000_000), i32f(1, 0)]),
        ]);
        assert_eq!(value["speed"][0]["value"], 1.0);
        assert_eq!(value["speed"][1]["value"], 2.5);
        assert_eq!(value["speed"].as_array().unwrap().len(), 2);
        assert_eq!(value["locations"][0]["altitudeMeters"], 0.0);
        assert_eq!(value["locations"][1]["altitudeMeters"], 100.0);
        assert_eq!(value["locations"].as_array().unwrap().len(), 2);
        for key in ["heartRate", "cadence", "power"] {
            assert_eq!(value[key], json!([]));
        }
    }

    #[test]
    fn preserves_first_altitude_at_duplicate_timestamp_and_missing_altitude() {
        let value = decode(vec![
            (20, vec![u32f(253, 100), u16f(2, 3000)]),
            (
                20,
                vec![u32f(253, 100), u16f(2, 4000), i32f(0, 0), i32f(1, 0)],
            ),
            (20, vec![u32f(253, 101), i32f(0, 0), i32f(1, 0)]),
        ]);
        assert_eq!(value["locations"][0]["altitudeMeters"], 100.0);
        assert!(value["locations"][1]["altitudeMeters"].is_null());
    }

    #[test]
    fn matches_swift_sport_mapping_and_clamps_reversed_session_end() {
        for (sport, activity) in [
            (1, 37),
            (2, 13),
            (11, 52),
            (17, 24),
            (5, 46),
            (10, 50),
            (15, 35),
            (4, 16),
            (7, 41),
            (6, 6),
            (8, 48),
            (25, 21),
            (13, 61),
            (14, 67),
            (31, 9),
            (0, 3000),
            (255, 3000),
        ] {
            assert_eq!(healthkit_activity_type(Some(sport)), activity);
        }
        let value = decode(vec![(18, vec![u32f(2, 200), u32f(253, 100)])]);
        assert_eq!(value["endMs"], timestamp_ms(200));
        assert_eq!(value["durationSeconds"], 0.0);
    }

    #[test]
    fn includes_all_pause_variants_but_omits_initial_and_final_transitions() {
        let mut messages = vec![(18, vec![u32f(2, 100), u32f(253, 200)])];
        for kind in [1, 4, 8, 9] {
            messages.push(timer(150, kind));
            messages.push(timer(200, kind));
        }
        messages.extend([timer(99, 0), timer(100, 0), timer(151, 0), timer(160, 2)]);
        let value = decode(messages);
        let events = value["events"].as_array().unwrap();
        assert_eq!(events.len(), 5);
        assert_eq!(events[4]["type"], "resume");
    }

    #[test]
    fn rejects_invalid_fingerprint_bad_fit_missing_time_and_resource_overflow() {
        let empty = fit(vec![]);
        assert_eq!(
            decode_fit_health_draft_json(&empty, "not-a-fingerprint"),
            Err(HealthDraftError::InvalidFingerprint)
        );
        assert_eq!(
            decode_fit_health_draft_json(&empty, &"a".repeat(64)),
            Err(HealthDraftError::MissingTime)
        );
        let mut corrupt = fit(vec![(20, vec![u32f(253, 100)])]);
        *corrupt.last_mut().unwrap() ^= 1;
        assert_eq!(
            decode_fit_health_draft_json(&corrupt, &"a".repeat(64)),
            Err(HealthDraftError::InvalidFit(FitDecodeError::InvalidCrc))
        );
        let mut count = MAX_POINTS;
        assert_eq!(
            count_point(&mut count),
            Err(HealthDraftError::TooManyPoints)
        );
        let mut output = BoundedOutput(vec![0; MAX_JSON_BYTES]);
        assert!(output.write_all(b"x").is_err());
    }
}
