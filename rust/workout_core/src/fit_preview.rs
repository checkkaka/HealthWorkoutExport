use super::FitDocument;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const FIT_EPOCH: f64 = 631_065_600.0;
const SERIES_KEYS: [&str; 5] = ["speed", "altitude", "heartRate", "cadence", "power"];
#[derive(Clone)]
struct Point {
    index: usize,
    time: f64,
    value: f64,
}
fn u8_value(doc: &FitDocument, i: usize, field: u8) -> Option<f64> {
    doc.read_u8(i, field)
        .filter(|x| *x != u8::MAX)
        .map(f64::from)
}
fn u16_value(doc: &FitDocument, i: usize, field: u8) -> Option<f64> {
    doc.read_u16(i, field)
        .filter(|x| *x != u16::MAX)
        .map(f64::from)
}
fn u32_value(doc: &FitDocument, i: usize, field: u8) -> Option<f64> {
    doc.read_u32(i, field)
        .filter(|x| *x != u32::MAX)
        .map(f64::from)
}
fn timestamp(doc: &FitDocument, i: usize) -> Option<u32> {
    doc.read_u32(i, 253).filter(|x| *x != u32::MAX)
}
fn coordinate(doc: &FitDocument, i: usize, f: u8) -> Option<i32> {
    doc.read_i32(i, f).filter(|x| *x != i32::MAX)
}
fn degree(raw: i32) -> f64 {
    f64::from(raw) * 180.0 / 2_147_483_648.0
}
fn issue(id: &str, severity: &str, title: &str, detail: impl Into<String>) -> Value {
    json!({"id":id,"severity":severity,"title":title,"detail":detail.into()})
}
fn sample<T: Clone>(items: &[T], limit: usize) -> Vec<T> {
    if items.len() <= limit {
        return items.to_vec();
    }
    (0..limit)
        .map(|i| items[(i * (items.len() - 1) + (limit - 1) / 2) / (limit - 1)].clone())
        .collect()
}
fn average(points: &[Point]) -> Option<f64> {
    if points.is_empty() {
        return None;
    }
    let (mut sum, mut weight) = (0.0, 0.0);
    for pair in points.windows(2) {
        let (a, b) = (&pair[0], &pair[1]);
        let dt = b.time - a.time;
        if b.index == a.index + 1 && dt > 0.0 {
            sum += (a.value + b.value) * 0.5 * dt;
            weight += dt;
        }
    }
    Some(if weight > 0.0 {
        sum / weight
    } else {
        points.iter().map(|p| p.value).sum::<f64>() / points.len() as f64
    })
}
fn maximum(points: &[Point]) -> Option<f64> {
    points.iter().map(|p| p.value).reduce(f64::max)
}
fn distance(a: (f64, f64), b: (f64, f64)) -> f64 {
    let dlat = (b.0 - a.0).to_radians();
    let dlon = (b.1 - a.1).to_radians();
    let h = (dlat * 0.5).sin().powi(2)
        + a.0.to_radians().cos() * b.0.to_radians().cos() * (dlon * 0.5).sin().powi(2);
    12_742_000.0 * h.clamp(0.0, 1.0).sqrt().asin()
}
fn coordinate_hashes(doc: &FitDocument) -> (String, String, usize) {
    let (mut shape, mut values) = (Sha256::new(), Sha256::new());
    let mut invalid = 0;
    for (global, pairs) in [
        (20, &[(0u8, 1u8)][..]),
        (19, &[(3, 4), (5, 6)][..]),
        (18, &[(3, 4), (29, 30), (31, 32), (38, 39)][..]),
    ] {
        let mut indexes = doc
            .messages()
            .iter()
            .enumerate()
            .filter(|(_, m)| m.global_number() == global)
            .map(|(i, _)| i)
            .collect::<Vec<_>>();
        indexes.sort_by_key(|i| timestamp(doc, *i).unwrap_or(0));
        for (index, i) in indexes.into_iter().enumerate() {
            for &(lat_field, lon_field) in pairs {
                let time = timestamp(doc, i);
                let lat = coordinate(doc, i, lat_field);
                let lon = coordinate(doc, i, lon_field);
                let mut structure = Vec::with_capacity(20);
                structure.extend(global.to_le_bytes());
                structure.extend([lat_field, lon_field]);
                structure.extend((index as u64).to_le_bytes());
                structure.push(u8::from(time.is_some()));
                structure.extend(time.unwrap_or(0).to_le_bytes());
                structure.extend([u8::from(lat.is_some()), u8::from(lon.is_some())]);
                shape.update(&structure);
                values.update(&structure);
                values.update(lat.unwrap_or(0).to_le_bytes());
                values.update(lon.unwrap_or(0).to_le_bytes());
                if (lat.is_some() || lon.is_some())
                    && !matches!((lat,lon),(Some(a),Some(b)) if degree(a).abs()<=90.0 && degree(b).abs()<=180.0)
                {
                    invalid += 1;
                }
            }
        }
    }
    (
        shape
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
        values
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
        invalid,
    )
}

/// Bounded display inspection; hashes cover the full coordinate snapshot, never only sampled points.
/// Field IDs/scales follow Garmin's official FIT profile and FITInspection.swift's priorities.
pub fn inspect_fit_preview_json(data: &[u8]) -> Result<String, String> {
    let doc=match FitDocument::parse(data){Ok(doc)=>doc,Err(_)=>return Ok(json!({"summary":{},"track":[],"series":{},"issues":[issue("invalid-fit","error","FIT 无法解析","FIT 内容无效或超过安全限制")]}).to_string())};
    let mut records = doc
        .messages()
        .iter()
        .enumerate()
        .filter(|(_, m)| m.global_number() == 20)
        .map(|(i, _)| i)
        .collect::<Vec<_>>();
    records.sort_by_key(|i| timestamp(&doc, *i).unwrap_or(0));
    let sessions = doc
        .messages()
        .iter()
        .enumerate()
        .filter(|(_, m)| m.global_number() == 18)
        .map(|(i, _)| i)
        .collect::<Vec<_>>();
    let mut series: [Vec<Point>; 5] = std::array::from_fn(|_| Vec::new());
    let mut track = Vec::new();
    let mut times = Vec::new();
    let mut previous: Option<(f64, f64, f64)> = None;
    let mut maximum_gps_speed: f64 = 0.0;
    for (index, &i) in records.iter().enumerate() {
        let Some(time) = timestamp(&doc, i).map(|t| f64::from(t) + FIT_EPOCH) else {
            continue;
        };
        times.push(time);
        let fields = [
            u16_value(&doc, i, 6)
                .or_else(|| u32_value(&doc, i, 73))
                .map(|x| x * 0.0036),
            u16_value(&doc, i, 2)
                .or_else(|| u32_value(&doc, i, 78))
                .map(|x| x / 5.0 - 500.0),
            u8_value(&doc, i, 3),
            u8_value(&doc, i, 4),
            u16_value(&doc, i, 7),
        ];
        for (k, value) in fields.into_iter().enumerate() {
            if let Some(value) = value {
                series[k].push(Point { index, time, value });
            }
        }
        if let (Some(lat), Some(lon)) = (coordinate(&doc, i, 0), coordinate(&doc, i, 1)) {
            let (lat, lon) = (degree(lat), degree(lon));
            if lat.abs() > 90.0 || lon.abs() > 180.0 {
                continue;
            }
            track.push((time, lat, lon));
            if let Some((last_time, last_lat, last_lon)) = previous {
                let dt = time - last_time;
                if dt > 0.0 && dt <= 8.0 {
                    maximum_gps_speed = maximum_gps_speed
                        .max(distance((last_lat, last_lon), (lat, lon)) / dt * 3.6);
                }
            }
            previous = Some((time, lat, lon));
        }
    }
    let session_u32 = |field| sessions.iter().find_map(|i| u32_value(&doc, *i, field));
    let session_u16 = |field| sessions.iter().find_map(|i| u16_value(&doc, *i, field));
    let session_u8 = |field| sessions.iter().find_map(|i| u8_value(&doc, *i, field));
    let duration = session_u32(8).map(|x| x / 1000.0).or_else(|| {
        if times.len() > 1 {
            Some(times[times.len() - 1] - times[0])
        } else {
            None
        }
    });
    let meters = session_u32(9)
        .or_else(|| records.iter().rev().find_map(|i| u32_value(&doc, *i, 5)))
        .map(|x| x / 100.0);
    let maximum_speed = session_u32(125)
        .or_else(|| session_u16(15))
        .map(|x| x * 0.0036)
        .or_else(|| maximum(&series[0]))
        .unwrap_or(0.0);
    let average_speed = session_u32(124)
        .or_else(|| session_u16(14))
        .map(|x| x * 0.0036)
        .or_else(|| match (meters, duration) {
            (Some(d), Some(t)) if d > 0.0 && t > 0.0 => Some(d / t * 3.6),
            _ => None,
        })
        .or_else(|| average(&series[0]));
    let summary = json!({"recordCount":records.len(),"gpsCount":track.len(),"heartRateCount":series[2].len(),"cadenceCount":series[3].len(),"powerCount":series[4].len(),
        "durationSeconds":duration.unwrap_or(0.0),"hasDuration":duration.is_some(),"distanceMeters":meters.unwrap_or(0.0),"hasDistance":meters.is_some(),
        "averageSpeedKph":average_speed,"maximumSpeedKph":maximum_speed,"maximumGpsSpeedKph":maximum_gps_speed,
        "averageHeartRateBpm":session_u8(16).or_else(||average(&series[2])),"maximumHeartRateBpm":session_u8(17).or_else(||maximum(&series[2])),
        "averageCadenceRpm":session_u8(18).or_else(||average(&series[3])),"averagePowerWatts":session_u16(20).or_else(||average(&series[4])),"maximumPowerWatts":session_u16(21).or_else(||maximum(&series[4])),
        "totalAscentMeters":session_u16(22),"totalDescentMeters":session_u16(23),"totalCalories":session_u16(11)});
    let (shape_hash, value_hash, invalid) = coordinate_hashes(&doc);
    let mut issues = Vec::new();
    if times.is_empty() {
        issues.push(issue(
            "no-timestamp",
            "error",
            "没有有效时间记录",
            "FIT 中没有带时间戳的 Record，无法同步",
        ));
    }
    if invalid > 0 {
        issues.push(issue(
            "invalid-coordinate",
            "error",
            "存在非法坐标",
            format!("发现 {invalid} 条缺少经纬度配对或超出有效范围的坐标"),
        ));
    }
    if track.len() < 5 {
        issues.push(issue(
            "few-gps-points",
            "warning",
            "GPS 点过少",
            format!("仅有 {} 个有效 GPS 点", track.len()),
        ));
    }
    if maximum_speed > 80.0 {
        issues.push(issue(
            "speed-over-80",
            "warning",
            "速度字段异常",
            format!("最高速度字段 {maximum_speed:.1} km/h，超过 80 km/h"),
        ));
    }
    if maximum_gps_speed > 120.0 {
        issues.push(issue(
            "gps-speed-over-120",
            "warning",
            "GPS 推算速度异常",
            format!("相邻轨迹点推算最高 {maximum_gps_speed:.1} km/h，超过 120 km/h"),
        ));
    }
    if series[2].is_empty() {
        issues.push(issue(
            "missing-heart-rate",
            "info",
            "缺少心率",
            "该 FIT 没有心率记录",
        ));
    }
    if series[4].is_empty() {
        issues.push(issue(
            "missing-power",
            "info",
            "缺少功率",
            "该 FIT 没有功率记录",
        ));
    }
    let chart: serde_json::Map<String, Value> = SERIES_KEYS
        .iter()
        .enumerate()
        .map(|(i, key)| {
            (
                (*key).to_owned(),
                Value::Array(
                    sample(&series[i], 600)
                        .iter()
                        .map(|p| json!({"timeSeconds":p.time,"value":p.value}))
                        .collect(),
                ),
            )
        })
        .collect();
    let output=json!({"summary":summary,"track":sample(&track,2000).iter().map(|(time,lat,lon)|json!({"timeSeconds":time,"latitude":lat,"longitude":lon})).collect::<Vec<_>>(),"series":chart,"issues":issues,"coordinateShapeHash":shape_hash,"coordinateValueHash":value_hash}).to_string();
    if output.len() > 4 * 1024 * 1024 {
        return Err("FIT 检查结果超过安全限制".to_owned());
    }
    Ok(output)
}

/// Same planar mean displacement used by the Swift processing report, over changed pairs only.
pub fn average_coordinate_displacement(
    original: &[u8],
    final_fit: &[u8],
) -> Result<f64, super::FitDecodeError> {
    let before = FitDocument::parse(original)?;
    let after = FitDocument::parse(final_fit)?;
    if coordinate_hashes(&before).0 != coordinate_hashes(&after).0 {
        return Ok(0.0);
    }
    fn values(document: &FitDocument) -> Vec<(Option<i32>, Option<i32>)> {
        let mut result = Vec::new();
        for (global, pairs) in [
            (20, &[(0u8, 1u8)][..]),
            (19, &[(3, 4), (5, 6)][..]),
            (18, &[(3, 4), (29, 30), (31, 32), (38, 39)][..]),
        ] {
            let mut indexes = document
                .messages()
                .iter()
                .enumerate()
                .filter(|(_, m)| m.global_number() == global)
                .map(|(i, _)| i)
                .collect::<Vec<_>>();
            indexes.sort_by_key(|i| timestamp(document, *i).unwrap_or(0));
            for i in indexes {
                for &(a, b) in pairs {
                    result.push((coordinate(document, i, a), coordinate(document, i, b)));
                }
            }
        }
        result
    }
    let (mut total, mut count) = (0.0, 0usize);
    for (a, b) in values(&before).into_iter().zip(values(&after)) {
        if let ((Some(lat1), Some(lon1)), (Some(lat2), Some(lon2))) = (a, b) {
            if lat1 == lat2 && lon1 == lon2 {
                continue;
            }
            let scale = 180.0 / 2_147_483_648.0;
            let y = (f64::from(lat2) - f64::from(lat1)) * scale * 111_320.0;
            let mean = (f64::from(lat1) + f64::from(lat2)) * 0.5 * scale;
            let x =
                (f64::from(lon2) - f64::from(lon1)) * scale * 111_320.0 * mean.to_radians().cos();
            total += x.hypot(y);
            count += 1;
        }
    }
    Ok(if count == 0 {
        0.0
    } else {
        total / count as f64
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn message(global: u16, fields: &[(u8, u8, Vec<u8>)]) -> Vec<u8> {
        let mut out = vec![0x40, 0, 0];
        out.extend(global.to_le_bytes());
        out.push(fields.len() as u8);
        for (number, kind, value) in fields {
            out.extend([*number, value.len() as u8, *kind]);
        }
        out.push(0);
        for (_, _, value) in fields {
            out.extend(value);
        }
        out
    }
    fn fit(body: Vec<u8>) -> Vec<u8> {
        let mut data = vec![14, 0x20, 0, 0];
        data.extend((body.len() as u32).to_le_bytes());
        data.extend(b".FIT");
        data.extend(super::super::crc16(&data).to_le_bytes());
        data.extend(body);
        data.extend(super::super::crc16(&data).to_le_bytes());
        data
    }
    fn record(time: u32, lat: Option<i32>, hr: u8) -> Vec<u8> {
        let mut fields = vec![
            (253, 0x86, time.to_le_bytes().to_vec()),
            (3, 0x02, vec![hr]),
            (73, 0x86, 3000u32.to_le_bytes().to_vec()),
        ];
        if let Some(lat) = lat {
            fields.push((0, 0x85, lat.to_le_bytes().to_vec()));
            fields.push((1, 0x85, 100i32.to_le_bytes().to_vec()));
        }
        message(20, &fields)
    }
    fn inspect(data: &[u8]) -> Value {
        serde_json::from_str(&inspect_fit_preview_json(data).unwrap()).unwrap()
    }
    #[test]
    fn rejects_invalid_fit_as_quality_error() {
        let v = inspect(b"bad");
        assert_eq!(v["issues"][0]["id"], "invalid-fit");
    }
    #[test]
    fn uses_timestamped_valid_sensors_and_weighted_summary() {
        let v = inspect(&fit([
            record(1000, Some(100), 100),
            record(1010, Some(101), 120),
            record(1030, Some(102), 140),
        ]
        .concat()));
        assert_eq!(v["summary"]["heartRateCount"], 3);
        assert_eq!(v["summary"]["durationSeconds"], 30.0);
        assert!(
            (v["summary"]["averageHeartRateBpm"].as_f64().unwrap() - 123.3333333).abs() < 0.001
        );
        assert!((v["summary"]["maximumSpeedKph"].as_f64().unwrap() - 10.8).abs() < 0.001);
        assert_eq!(v["series"]["speed"][0]["timeSeconds"], 631066600.0);
    }
    #[test]
    fn detects_partial_coordinate_and_missing_timestamps() {
        let v = inspect(&fit(message(20, &[(0, 0x85, 1i32.to_le_bytes().to_vec())])));
        let ids = v["issues"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x["id"].as_str().unwrap())
            .collect::<Vec<_>>();
        assert!(ids.contains(&"invalid-coordinate"));
        assert!(ids.contains(&"no-timestamp"));
    }
    #[test]
    fn hashes_every_coordinate_and_downsamples_only_display() {
        let body = (0..2500u32)
            .flat_map(|i| record(1000 + i, Some(i as i32), 100))
            .collect();
        let first = inspect(&fit(body));
        let body = (0..2500u32)
            .flat_map(|i| record(1000 + i, Some(i as i32 + if i == 1 { 1 } else { 0 }), 100))
            .collect();
        let second = inspect(&fit(body));
        assert_eq!(first["track"].as_array().unwrap().len(), 2000);
        assert_eq!(first["series"]["heartRate"].as_array().unwrap().len(), 600);
        assert_eq!(first["coordinateShapeHash"], second["coordinateShapeHash"]);
        assert_ne!(first["coordinateValueHash"], second["coordinateValueHash"]);
    }
    #[test]
    fn displacement_uses_full_matching_snapshot_and_only_changed_pairs() {
        let original = fit([record(1000, Some(0), 100), record(1001, Some(0), 100)].concat());
        let changed = fit([record(1000, Some(11930), 100), record(1001, Some(0), 100)].concat());
        let meters = average_coordinate_displacement(&original, &changed).unwrap();
        assert!((meters - 111.32).abs() < 0.02);
        assert_eq!(
            average_coordinate_displacement(&original, &original).unwrap(),
            0.0
        );
        assert_eq!(
            average_coordinate_displacement(&original, &fit(record(1000, Some(0), 100))).unwrap(),
            0.0
        );
    }

    #[test]
    fn session_summary_precedes_record_fallback() {
        let session = message(
            18,
            &[
                (8, 0x86, 60_000u32.to_le_bytes().to_vec()),
                (9, 0x86, 500_000u32.to_le_bytes().to_vec()),
                (16, 0x02, vec![150]),
            ],
        );
        let v = inspect(&fit([
            session,
            record(1000, None, 100),
            record(1010, None, 110),
        ]
        .concat()));
        assert_eq!(v["summary"]["durationSeconds"], 60.0);
        assert_eq!(v["summary"]["distanceMeters"], 5000.0);
        assert_eq!(v["summary"]["averageHeartRateBpm"], 150.0);
    }
}
