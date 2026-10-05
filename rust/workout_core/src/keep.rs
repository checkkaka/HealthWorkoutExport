//! Experimental read-only Keep account adapter. No user credentials are retained.
//!
//! Compatibility reference (MIT): yihong0618/running_page, commit
//! 6ffdd23ad8cd96118ba0cd93ccf07320676e01e3, run_page/keep_sync.py.
//! This is an unofficial, version-sensitive protocol; no refresh or password retry is attempted.
//! FIT timestamps are canonical UTC. We do not guess an IANA offset using today's DST rules.

use crate::strava::StravaCancellation;
use aes::cipher::{BlockDecryptMut, KeyIvInit};
use base64::Engine;
use serde::Deserialize;
use serde_json::Value;
use std::io::Read;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeepError {
    InvalidResponse,
    UnsupportedActivity,
    SessionExpired,
    LoginRejected,
    Rejected,
    Cancelled,
    LimitExceeded,
    InvalidInput,
    Transport,
    RedirectBlocked,
    HttpStatus,
    ClientBuild,
    PaginationLoop,
    Timeout,
}
impl std::fmt::Display for KeepError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Keep{self:?}")
    }
}

#[derive(Clone, Debug)]
pub struct KeepWorkout {
    pub id: String,
    pub title: String,
    pub start_time_seconds: f64,
    pub end_time_seconds: f64,
    pub duration_seconds: f64,
    pub distance_meters: Option<f64>,
    pub indoor: bool,
}

fn parse_run(data: &Value) -> Result<KeepWorkout, KeepError> {
    let indoor = match data.get("dataType").and_then(Value::as_str) {
        Some("indoorRunning") => true,
        Some("outdoorRunning") => false,
        Some(_) => return Err(KeepError::UnsupportedActivity),
        None => return Err(KeepError::InvalidResponse),
    };
    let id = data
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| valid_id(id))
        .ok_or(KeepError::InvalidResponse)?;
    let start = integer(data.get("startTime"))?;
    let end = integer(data.get("endTime"))?;
    let duration = number(data.get("duration")).ok_or(KeepError::InvalidResponse)?;
    if !(631_065_600_000..=4_925_000_000_000).contains(&start)
        || end < start
        || end - start > 100 * 3600 * 1000
        || duration <= 0.0
        || duration > (end - start) as f64 / 1000.0 + 1.0
    {
        return Err(KeepError::InvalidResponse);
    }
    let distance = match data.get("distance").filter(|v| !v.is_null()) {
        Some(v) => Some(
            number(Some(v))
                .filter(|v| *v >= 0.0 && *v <= 5_000_000.0)
                .ok_or(KeepError::InvalidResponse)?,
        ),
        None => None,
    };
    Ok(KeepWorkout {
        id: id.to_owned(),
        title: if indoor {
            "Keep 室内跑步"
        } else {
            "Keep 跑步"
        }
        .to_owned(),
        start_time_seconds: start as f64 / 1000.0,
        end_time_seconds: end as f64 / 1000.0,
        duration_seconds: duration,
        distance_meters: distance,
        indoor,
    })
}
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 256
        && id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-'))
}
fn number(value: Option<&Value>) -> Option<f64> {
    value
        .and_then(|v| v.as_f64().or_else(|| v.as_str()?.parse().ok()))
        .filter(|v| v.is_finite())
}
fn integer(value: Option<&Value>) -> Result<i64, KeepError> {
    number(value)
        .filter(|v| v.fract() == 0.0 && v.abs() <= 9_007_199_254_740_991.0)
        .map(|v| v as i64)
        .ok_or(KeepError::InvalidResponse)
}
fn optional_sample_blob(value: Option<&Value>) -> Result<Option<&str>, KeepError> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok((!text.is_empty()).then_some(text.as_str())),
        Some(_) => Err(KeepError::InvalidResponse),
    }
}
fn detail_to_fit(data: &Value, cancel: &StravaCancellation) -> Result<Vec<u8>, KeepError> {
    if cancel.is_cancelled() {
        return Err(KeepError::Cancelled);
    }
    let run = parse_run(data)?;
    let start = integer(data.get("startTime"))?;
    let end = integer(data.get("endTime"))?;
    // Missing samples are allowed; a changed or malformed schema must not silently lose them.
    let geo_blob = optional_sample_blob(data.get("geoPoints"))?;
    let hr_blob = match data.get("heartRate") {
        None | Some(Value::Null) => None,
        Some(Value::Object(heart_rate)) => optional_sample_blob(heart_rate.get("heartRates"))?,
        Some(_) => return Err(KeepError::InvalidResponse),
    };
    let mut route = Vec::new();
    if !run.indoor
        && let Some(text) = geo_blob
    {
        for point in decode_blob::<GeoPoint>(text, true, cancel)? {
            check_cancel(cancel)?;
            if !point.latitude.is_finite()
                || !point.longitude.is_finite()
                || !(-90.0..=90.0).contains(&point.latitude)
                || !(-180.0..=180.0).contains(&point.longitude)
                || point
                    .altitude
                    .is_some_and(|v| !v.is_finite() || !(-500.0..=10000.0).contains(&v))
            {
                return Err(KeepError::InvalidResponse);
            }
            let timestamp = point_timestamp(
                &serde_json::json!({"timestamp":point.timestamp,"unixTimestamp":point.unix_timestamp}),
                start,
                end,
            )?;
            let (latitude, longitude) = crate::fit::gcj02_to_wgs84(point.latitude, point.longitude);
            route.push(serde_json::json!({"latitude":latitude,"longitude":longitude,"altitudeMeters":point.altitude,"timestampMs":timestamp}));
        }
    }
    let mut hr = Vec::new();
    if let Some(text) = hr_blob {
        for point in decode_blob::<HeartRatePoint>(text, false, cancel)? {
            check_cancel(cancel)?;
            if point.beats_per_minute > 0.0 && point.beats_per_minute < 255.0 {
                let timestamp = point_timestamp(
                    &serde_json::json!({"timestamp":point.timestamp,"unixTimestamp":point.unix_timestamp}),
                    start,
                    end,
                )?;
                hr.push(serde_json::json!({"dateMs":timestamp,"value":point.beats_per_minute}));
            }
        }
    }
    let calories = number(data.get("calorie")).filter(|v| *v >= 0.0 && *v <= 65534.0);
    let bundle = serde_json::json!({"uuid":run.id,"startMs":integer(data.get("startTime"))?,
        "endMs":integer(data.get("endTime"))?,"durationSeconds":run.duration_seconds,
        "activityType":37,"sourceName":"Keep","subSport":if run.indoor {1}else{0},
        "totalDistanceMeters":run.distance_meters,"totalEnergyKcal":calories,"events":[],
        "series":{"HKQuantityTypeIdentifierHeartRate":hr},"route":route});
    crate::fit::encode_health_workout_bundle_json(
        &serde_json::to_vec(&bundle).map_err(|_| KeepError::InvalidResponse)?,
        0,
    )
    .map_err(|_| KeepError::InvalidResponse)
}
fn point_timestamp(point: &Value, start: i64, end: i64) -> Result<i64, KeepError> {
    let (raw, is_unix) = if let Some(value) = point.get("unixTimestamp").filter(|v| !v.is_null()) {
        (integer(Some(value))?, true)
    } else {
        (integer(point.get("timestamp"))?, false)
    };
    if raw < 0 {
        return Err(KeepError::InvalidResponse);
    }
    // Keep has emitted relative deciseconds, epoch deciseconds, and Unix milliseconds/seconds.
    // Select only candidates inside this specific workout; never infer route times from point order.
    let candidates = if is_unix {
        [
            Some(raw),
            raw.checked_mul(1000),
            raw.checked_mul(100),
            raw.checked_mul(100).and_then(|v| start.checked_add(v)),
        ]
    } else {
        [
            raw.checked_mul(100).and_then(|v| start.checked_add(v)),
            raw.checked_mul(100),
            Some(raw),
            raw.checked_mul(1000),
        ]
    };
    candidates
        .into_iter()
        .flatten()
        .find(|value| *value >= start && *value <= end)
        .ok_or(KeepError::InvalidResponse)
}
fn checked_data(root: &Value, login: bool) -> Result<&Value, KeepError> {
    let code = number(root.get("code"));
    if code.is_some_and(|v| v == 401.0 || v == 403.0) {
        return Err(if login {
            KeepError::LoginRejected
        } else {
            KeepError::SessionExpired
        });
    }
    if root.get("ok") == Some(&Value::Bool(false)) || code.is_some_and(|v| v != 0.0 && v != 200.0) {
        return Err(if login {
            KeepError::LoginRejected
        } else {
            KeepError::Rejected
        });
    }
    if login && root.get("ok") != Some(&Value::Bool(true)) {
        return Err(KeepError::InvalidResponse);
    }
    root.get("data")
        .filter(|v| v.is_object())
        .ok_or(KeepError::InvalidResponse)
}

const MAX_BLOB_BYTES: usize = 8 * 1024 * 1024;
const MAX_DECOMPRESSED_BYTES: usize = 16 * 1024 * 1024;
const MAX_SAMPLES: usize = 100_000;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GeoPoint {
    latitude: f64,
    longitude: f64,
    altitude: Option<f64>,
    timestamp: Option<Value>,
    unix_timestamp: Option<Value>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HeartRatePoint {
    beats_per_minute: f64,
    timestamp: Option<Value>,
    unix_timestamp: Option<Value>,
}
fn check_cancel(cancel: &StravaCancellation) -> Result<(), KeepError> {
    if cancel.is_cancelled() {
        Err(KeepError::Cancelled)
    } else {
        Ok(())
    }
}

// Deserialize incrementally so a short JSON array of tiny elements cannot allocate an unbounded Vec.
struct BoundedSamples<T>(Vec<T>);
impl<'de, T: Deserialize<'de>> Deserialize<'de> for BoundedSamples<T> {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Visitor<T>(std::marker::PhantomData<T>);
        impl<'de, T: Deserialize<'de>> serde::de::Visitor<'de> for Visitor<T> {
            type Value = BoundedSamples<T>;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("bounded samples")
            }
            fn visit_seq<A: serde::de::SeqAccess<'de>>(
                self,
                mut seq: A,
            ) -> Result<Self::Value, A::Error> {
                let mut values = Vec::new();
                while let Some(value) = seq.next_element()? {
                    if values.len() == MAX_SAMPLES {
                        return Err(serde::de::Error::custom("KeepLimitExceeded"));
                    }
                    values.push(value);
                }
                Ok(BoundedSamples(values))
            }
        }
        deserializer.deserialize_seq(Visitor(std::marker::PhantomData))
    }
}
fn decode_blob<T: serde::de::DeserializeOwned>(
    text: &str,
    encrypted: bool,
    cancel: &StravaCancellation,
) -> Result<Vec<T>, KeepError> {
    check_cancel(cancel)?;
    if text.len() > MAX_BLOB_BYTES {
        return Err(KeepError::LimitExceeded);
    }
    let mut compressed = base64::engine::general_purpose::STANDARD
        .decode(text)
        .map_err(|_| KeepError::InvalidResponse)?;
    if encrypted {
        // Public compatibility constants from Keep's legacy running-log format; not user secrets.
        const KEY: [u8; 16] = *b"56fe59;82g:d873c";
        const IV: [u8; 16] = *b"2346892432920300";
        if compressed.is_empty() || compressed.len() % 16 != 0 {
            return Err(KeepError::InvalidResponse);
        }
        cbc::Decryptor::<aes::Aes128>::new(&KEY.into(), &IV.into())
            .decrypt_padded_mut::<aes::cipher::block_padding::NoPadding>(&mut compressed)
            .map_err(|_| KeepError::InvalidResponse)?;
    }
    let mut decoder = flate2::read::GzDecoder::new(compressed.as_slice());
    let mut plain = Vec::new();
    let mut chunk = [0_u8; 8192];
    loop {
        check_cancel(cancel)?;
        let count = decoder
            .read(&mut chunk)
            .map_err(|_| KeepError::InvalidResponse)?;
        if count == 0 {
            break;
        }
        if plain.len() + count > MAX_DECOMPRESSED_BYTES {
            return Err(KeepError::LimitExceeded);
        }
        plain.extend_from_slice(&chunk[..count]);
    }
    check_cancel(cancel)?;
    let values: BoundedSamples<T> = serde_json::from_slice(&plain).map_err(|error| {
        if error.to_string().starts_with("KeepLimitExceeded") {
            KeepError::LimitExceeded
        } else {
            KeepError::InvalidResponse
        }
    })?;
    check_cancel(cancel)?;
    Ok(values.0)
}

fn valid_token(token: &str) -> bool {
    !token.is_empty() && token.len() <= 4096 && token.bytes().all(|c| c.is_ascii_graphic())
}

pub struct KeepClient {
    client: reqwest::Client,
    base: reqwest::Url,
}
impl KeepClient {
    pub fn new() -> Result<Self, KeepError> {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(20))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| KeepError::ClientBuild)?;
        Ok(Self {
            client,
            base: reqwest::Url::parse("https://api.gotokeep.com/")
                .map_err(|_| KeepError::ClientBuild)?,
        })
    }
    /// One explicit account/password request, without retries or retained credentials.
    pub async fn login(
        &self,
        account: &str,
        password: &str,
        cancel: &StravaCancellation,
    ) -> Result<String, KeepError> {
        check_cancel(cancel)?;
        if account.trim().is_empty()
            || account.len() > 256
            || account.chars().any(char::is_control)
            || password.is_empty()
            || password.len() > 1024
        {
            return Err(KeepError::InvalidInput);
        }
        let request = self
            .client
            .post(self.url("v1.1/users/login")?)
            .form(&[("mobile", account.trim()), ("password", password)]);
        let root = self.request_json(request, true, 64 * 1024, cancel).await?;
        let data = checked_data(&root, true)?;
        let token = data
            .get("token")
            .and_then(Value::as_str)
            .filter(|token| valid_token(token))
            .ok_or(KeepError::InvalidResponse)?;
        Ok(token.to_owned())
    }
    pub async fn list_workouts(
        &self,
        token: &str,
        from: i64,
        to: i64,
        cancel: &StravaCancellation,
    ) -> Result<Vec<KeepWorkout>, KeepError> {
        check_cancel(cancel)?;
        if !valid_token(token) || from < 0 || to <= from || to > 4_925_000_000 {
            return Err(KeepError::InvalidInput);
        }
        tokio::time::timeout(
            std::time::Duration::from_secs(300),
            self.list_pages(token, from, to, cancel),
        )
        .await
        .map_err(|_| KeepError::Timeout)?
    }
    async fn list_pages(
        &self,
        token: &str,
        from: i64,
        to: i64,
        cancel: &StravaCancellation,
    ) -> Result<Vec<KeepWorkout>, KeepError> {
        let mut cursor = 0_i64;
        let mut seen = std::collections::HashSet::new();
        let mut workouts = Vec::new();
        for page in 0..128 {
            check_cancel(cancel)?;
            if page > 0 {
                cancel
                    .run(tokio::time::sleep(std::time::Duration::from_secs(1)))
                    .await
                    .map_err(|_| KeepError::Cancelled)?;
            }
            let mut url = self.url("pd/v3/stats/detail")?;
            url.query_pairs_mut()
                .append_pair("dateUnit", "all")
                .append_pair("type", "running")
                .append_pair("lastDate", &cursor.to_string());
            let root = self
                .request_json(
                    self.client.get(url).bearer_auth(token),
                    false,
                    2 * 1024 * 1024,
                    cancel,
                )
                .await?;
            let data = checked_data(&root, false)?;
            let records = data
                .get("records")
                .and_then(Value::as_array)
                .ok_or(KeepError::InvalidResponse)?;
            let mut rows = 0_usize;
            for record in records {
                let logs = record
                    .get("logs")
                    .and_then(Value::as_array)
                    .ok_or(KeepError::InvalidResponse)?;
                for log in logs {
                    rows += 1;
                    if rows > 10_000 {
                        return Err(KeepError::LimitExceeded);
                    }
                    let stats = log
                        .get("stats")
                        .filter(|v| v.is_object())
                        .ok_or(KeepError::InvalidResponse)?;
                    if stats.get("isDoubtful") == Some(&Value::Bool(true)) {
                        continue;
                    }
                    if let Ok(start) = integer(stats.get("startTime"))
                        && (start < from * 1000 || start >= to * 1000)
                    {
                        continue;
                    }
                    let id = stats
                        .get("id")
                        .and_then(Value::as_str)
                        .filter(|id| valid_id(id))
                        .ok_or(KeepError::InvalidResponse)?;
                    if !seen.insert(id.to_owned()) {
                        continue;
                    }
                    if seen.len() > 4096 {
                        return Err(KeepError::LimitExceeded);
                    }
                    let root = self.detail(token, id, cancel).await?;
                    let detail = checked_data(&root, false)?;
                    if detail.get("id").and_then(Value::as_str) != Some(id) {
                        return Err(KeepError::InvalidResponse);
                    }
                    match parse_run(detail) {
                        Ok(workout)
                            if workout.start_time_seconds >= from as f64
                                && workout.start_time_seconds < to as f64 =>
                        {
                            workouts.push(workout)
                        }
                        Ok(_) | Err(KeepError::UnsupportedActivity) => {}
                        Err(error) => return Err(error),
                    }
                }
            }
            let next = integer(data.get("lastTimestamp"))?;
            if next < 0 {
                return Err(KeepError::InvalidResponse);
            }
            if next == 0 || next < from * 1000 {
                workouts.sort_by(|a, b| {
                    b.start_time_seconds
                        .total_cmp(&a.start_time_seconds)
                        .then_with(|| a.id.cmp(&b.id))
                });
                return Ok(workouts);
            }
            if cursor != 0 && next >= cursor {
                return Err(KeepError::PaginationLoop);
            }
            cursor = next;
        }
        Err(KeepError::LimitExceeded)
    }
    pub async fn download_fit(
        &self,
        token: &str,
        id: &str,
        cancel: &StravaCancellation,
    ) -> Result<Vec<u8>, KeepError> {
        check_cancel(cancel)?;
        if !valid_token(token) || !valid_id(id) {
            return Err(KeepError::InvalidInput);
        }
        let root = self.detail(token, id, cancel).await?;
        let data = checked_data(&root, false)?;
        if data.get("id").and_then(Value::as_str) != Some(id) {
            return Err(KeepError::InvalidResponse);
        }
        let fit = detail_to_fit(data, cancel)?;
        check_cancel(cancel)?;
        Ok(fit)
    }
    async fn detail(
        &self,
        token: &str,
        id: &str,
        cancel: &StravaCancellation,
    ) -> Result<Value, KeepError> {
        let url = self.url(&format!("pd/v3/runninglog/{id}"))?;
        self.request_json(
            self.client.get(url).bearer_auth(token),
            false,
            MAX_BLOB_BYTES,
            cancel,
        )
        .await
    }
    fn url(&self, path: &str) -> Result<reqwest::Url, KeepError> {
        self.base.join(path).map_err(|_| KeepError::InvalidInput)
    }
    async fn request_json(
        &self,
        request: reqwest::RequestBuilder,
        login: bool,
        limit: usize,
        cancel: &StravaCancellation,
    ) -> Result<Value, KeepError> {
        check_cancel(cancel)?;
        let mut response = cancel
            .run(request.send())
            .await
            .map_err(|_| KeepError::Cancelled)?
            .map_err(|error| {
                if error.is_timeout() {
                    KeepError::Timeout
                } else {
                    KeepError::Transport
                }
            })?;
        let status = response.status();
        if status.is_redirection() {
            return Err(KeepError::RedirectBlocked);
        }
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            return Err(if login {
                KeepError::LoginRejected
            } else {
                KeepError::SessionExpired
            });
        }
        if !status.is_success() {
            return Err(if login && status.is_client_error() {
                KeepError::LoginRejected
            } else {
                KeepError::HttpStatus
            });
        }
        if response
            .content_length()
            .is_some_and(|size| size > limit as u64)
        {
            return Err(KeepError::LimitExceeded);
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = cancel
            .run(response.chunk())
            .await
            .map_err(|_| KeepError::Cancelled)?
            .map_err(|error| {
                if error.is_timeout() {
                    KeepError::Timeout
                } else {
                    KeepError::Transport
                }
            })?
        {
            if bytes.len() + chunk.len() > limit {
                return Err(KeepError::LimitExceeded);
            }
            bytes.extend_from_slice(&chunk);
        }
        check_cancel(cancel)?;
        serde_json::from_slice(&bytes).map_err(|_| KeepError::InvalidResponse)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    const GEO: &str = "ZMkcnWvLvuibuuBifdNcf46NfNNalMwPCHBhAyVx2bEuHp9zn6kdWGNBBSVXll6yeyl6/3ClyyRi/nxO0qhw7gAcQXDhcYNSW2yftI57nbijCaQRHzMJtdGP4zfckYa+e9tk9uj8YQJqqmVQAdfMGw==";
    const HR: &str =
        "H4sIAAAAAAACA4uuVirJzE0tLknMLVCyMjTQUUpKTSwpDkgt8s3MKy1JBYqZGNTqoKgywqrKtDYWAAT8juJNAAAA";

    #[test]
    fn encrypted_geo_and_gzip_hr_export_actual_wgs84_samples_once() {
        let mut data = run(false);
        data["geoPoints"] = json!(GEO);
        data["heartRate"] = json!({"heartRates":HR});
        let fit = detail_to_fit(&data, &StravaCancellation::new()).unwrap();
        let doc = crate::fit::FitDocument::parse(&fit).unwrap();
        let records = doc
            .messages()
            .iter()
            .enumerate()
            .filter(|(_, m)| m.global_number() == 20)
            .map(|(i, _)| i)
            .collect::<Vec<_>>();
        assert_eq!(records.len(), 2);
        let (lat, lon) = crate::fit::gcj02_to_wgs84(39.9042, 116.4074);
        let units = 2_147_483_648.0 / 180.0;
        assert!((f64::from(doc.read_i32(records[0], 0).unwrap()) / units - lat).abs() < 1e-6);
        assert!((f64::from(doc.read_i32(records[0], 1).unwrap()) / units - lon).abs() < 1e-6);
        assert_eq!(doc.read_u8(records[0], 3), Some(140));
        assert_eq!(doc.read_u8(records[1], 3), Some(145));
        assert_eq!(
            doc.read_u32(records[0], 253),
            Some(1_700_000_001 - 631_065_600)
        );
        data["dataType"] = json!("indoorRunning");
        let indoor = detail_to_fit(&data, &StravaCancellation::new()).unwrap();
        assert_eq!(crate::fit::decode_fit(&indoor).unwrap().gps_point_count, 0);
        assert_eq!(
            crate::fit::decode_fit(&indoor)
                .unwrap()
                .heart_rate_point_count,
            2
        );
    }

    #[test]
    fn malformed_encryption_and_cancellation_fail_closed() {
        assert_eq!(
            decode_blob::<Value>("bad", true, &StravaCancellation::new()),
            Err(KeepError::InvalidResponse)
        );
        let c = StravaCancellation::new();
        c.cancel();
        assert_eq!(
            decode_blob::<Value>(HR, false, &c),
            Err(KeepError::Cancelled)
        );
    }

    #[test]
    fn non_string_geo_blobs_fail_closed_for_outdoor_and_indoor_runs() {
        for indoor in [false, true] {
            for value in [json!({}), json!([]), json!(42), json!(true)] {
                let mut data = run(indoor);
                data["geoPoints"] = value.clone();
                assert_eq!(
                    detail_to_fit(&data, &StravaCancellation::new()),
                    Err(KeepError::InvalidResponse),
                    "indoor={indoor}, geoPoints={value}"
                );
            }
        }
    }

    #[test]
    fn non_string_heart_rate_blobs_fail_closed_for_outdoor_and_indoor_runs() {
        for indoor in [false, true] {
            for value in [
                json!({}),
                json!([]),
                json!([{ "timestamp": 10, "beatsPerMinute": 140 }]),
                json!(42),
                json!(true),
            ] {
                let mut data = run(indoor);
                data["heartRate"] = json!({"heartRates": value});
                assert_eq!(
                    detail_to_fit(&data, &StravaCancellation::new()),
                    Err(KeepError::InvalidResponse),
                    "indoor={indoor}, heartRates={value}"
                );
            }
        }
    }

    #[test]
    fn non_object_heart_rate_containers_fail_closed_for_outdoor_and_indoor_runs() {
        for indoor in [false, true] {
            for value in [json!([]), json!(42), json!(true), json!(""), json!(HR)] {
                let mut data = run(indoor);
                data["heartRate"] = value.clone();
                assert_eq!(
                    detail_to_fit(&data, &StravaCancellation::new()),
                    Err(KeepError::InvalidResponse),
                    "indoor={indoor}, heartRate={value}"
                );
            }
        }
    }

    #[test]
    fn absent_and_empty_sample_blobs_preserve_summaries_without_inventing_samples() {
        for indoor in [false, true] {
            for geo in [None, Some(Value::Null), Some(json!(""))] {
                for heart_rate in [
                    None,
                    Some(Value::Null),
                    Some(json!({})),
                    Some(json!({"heartRates": null})),
                    Some(json!({"heartRates": ""})),
                ] {
                    let mut data = run(indoor);
                    let fields = data.as_object_mut().unwrap();
                    fields.remove("geoPoints");
                    fields.remove("heartRate");
                    if let Some(value) = &geo {
                        fields.insert("geoPoints".to_owned(), value.clone());
                    }
                    if let Some(value) = &heart_rate {
                        fields.insert("heartRate".to_owned(), value.clone());
                    }
                    let fit = detail_to_fit(&data, &StravaCancellation::new()).unwrap();
                    let summary = crate::fit::decode_fit(&fit).unwrap();
                    assert_eq!(summary.gps_point_count, 0);
                    assert_eq!(summary.heart_rate_point_count, 0);
                    let document = crate::fit::FitDocument::parse(&fit).unwrap();
                    let session = document
                        .messages()
                        .iter()
                        .position(|message| message.global_number() == 18)
                        .unwrap();
                    assert_eq!(document.read_u8(session, 6), Some(u8::from(indoor)));
                    assert_eq!(document.read_u32(session, 8), Some(540_000));
                    assert_eq!(document.read_u32(session, 9), Some(160_000));
                }
            }
        }
    }

    #[test]
    fn compression_bombs_and_excess_sample_counts_are_bounded() {
        use base64::Engine;
        use std::io::Write;
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        gz.write_all(&vec![b' '; 16 * 1024 * 1024 + 1]).unwrap();
        let text = base64::engine::general_purpose::STANDARD.encode(gz.finish().unwrap());
        assert_eq!(
            decode_blob::<Value>(&text, false, &StravaCancellation::new()),
            Err(KeepError::LimitExceeded)
        );
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        gz.write_all(format!("[{}null]", "null,".repeat(100_000)).as_bytes())
            .unwrap();
        let text = base64::engine::general_purpose::STANDARD.encode(gz.finish().unwrap());
        assert_eq!(
            decode_blob::<Value>(&text, false, &StravaCancellation::new()),
            Err(KeepError::LimitExceeded)
        );
    }

    // Synthetic loopback fixtures only. These tests never contact Keep or use real credentials.
    fn server(responses: Vec<(u16, String)>) -> (KeepClient, std::thread::JoinHandle<Vec<String>>) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let mut client = KeepClient::new().unwrap();
        client.base =
            reqwest::Url::parse(&format!("http://{}/", listener.local_addr().unwrap())).unwrap();
        let thread = std::thread::spawn(move || {
            let mut requests = Vec::new();
            for (status, body) in responses {
                let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
                let (mut stream, _) = loop {
                    match listener.accept() {
                        Ok(s) => break s,
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            assert!(
                                std::time::Instant::now() < deadline,
                                "fixture request deadline"
                            );
                            std::thread::sleep(std::time::Duration::from_millis(2));
                        }
                        Err(e) => panic!("fixture accept: {e}"),
                    }
                };
                stream
                    .set_read_timeout(Some(std::time::Duration::from_secs(2)))
                    .unwrap();
                let mut bytes = Vec::new();
                let mut chunk = [0; 4096];
                loop {
                    let n = stream.read(&mut chunk).unwrap();
                    assert!(n > 0);
                    bytes.extend_from_slice(&chunk[..n]);
                    assert!(bytes.len() < 65536);
                    if let Some(end) = bytes.windows(4).position(|v| v == b"\r\n\r\n") {
                        let headers = String::from_utf8_lossy(&bytes[..end]);
                        let length = headers
                            .lines()
                            .find_map(|l| {
                                l.to_ascii_lowercase()
                                    .strip_prefix("content-length:")
                                    .and_then(|v| v.trim().parse::<usize>().ok())
                            })
                            .unwrap_or(0);
                        if bytes.len() >= end + 4 + length {
                            break;
                        }
                    }
                }
                requests.push(String::from_utf8(bytes).unwrap());
                let response = format!(
                    "HTTP/1.1 {status} Fixture\r\nContent-Length: {}\r\nContent-Type: application/json\r\nLocation: https://example.invalid/never-follow\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                stream.write_all(response.as_bytes()).unwrap();
            }
            requests
        });
        (client, thread)
    }
    fn response(data: Value) -> (u16, String) {
        (200, json!({"ok":true,"data":data}).to_string())
    }

    #[tokio::test]
    async fn login_uses_one_form_request_and_rejects_redirects_or_failed_envelopes() {
        let (client, requests) = server(vec![response(json!({"token":"synthetic-token"}))]);
        assert_eq!(
            client
                .login("13800000000", "p&=word", &StravaCancellation::new())
                .await
                .unwrap(),
            "synthetic-token"
        );
        let requests = requests.join().unwrap();
        assert_eq!(requests.len(), 1);
        assert!(requests[0].starts_with("POST /v1.1/users/login "));
        assert!(requests[0].contains("mobile=13800000000&password=p%26%3Dword"));
        assert!(!requests[0].to_ascii_lowercase().contains("authorization:"));
        for (status, body, expected) in [
            (302, "{}", KeepError::RedirectBlocked),
            (401, "{}", KeepError::LoginRejected),
            (
                200,
                r#"{"ok":false,"data":{"token":"synthetic-token"}}"#,
                KeepError::LoginRejected,
            ),
        ] {
            let (client, requests) = server(vec![(status, body.to_owned())]);
            assert_eq!(
                client
                    .login("13800000000", "password", &StravaCancellation::new())
                    .await,
                Err(expected)
            );
            assert_eq!(requests.join().unwrap().len(), 1);
        }
    }

    #[tokio::test]
    async fn list_paginates_all_logs_deduplicates_and_filters_half_open_running_range() {
        let a = run(false);
        let mut b = run(true);
        b["id"] = json!("synthetic_second_rn");
        let (client, requests) = server(vec![
            response(
                json!({"records":[{"logs":[{"stats":{"id":a["id"],"isDoubtful":false}},{"stats":{"id":a["id"]}},{"stats":{"id":"doubtful","isDoubtful":true}}]},
                {"logs":[{"stats":{"id":b["id"]}}]}],"lastTimestamp":1700000000000_i64}),
            ),
            response(a),
            response(b),
            response(json!({"records":[],"lastTimestamp":0})),
        ]);
        let runs = client
            .list_workouts(
                "synthetic-token",
                1_699_999_999,
                1_700_000_001,
                &StravaCancellation::new(),
            )
            .await
            .unwrap();
        assert_eq!(runs.len(), 2);
        assert!(runs.iter().any(|r| r.indoor));
        let requests = requests.join().unwrap();
        assert_eq!(requests.len(), 4);
        assert!(requests[0].contains("dateUnit=all&type=running&lastDate=0"));
        assert!(requests[3].contains("lastDate=1700000000000"));
        for request in requests {
            assert!(
                request
                    .to_ascii_lowercase()
                    .contains("authorization: bearer synthetic-token")
            );
        }
        let (client, requests) = server(vec![
            response(
                json!({"records":[{"logs":[{"stats":{"id":run(false)["id"]}}]}],"lastTimestamp":0}),
            ),
            response(run(false)),
        ]);
        assert!(
            client
                .list_workouts(
                    "synthetic-token",
                    1_699_999_999,
                    1_700_000_000,
                    &StravaCancellation::new()
                )
                .await
                .unwrap()
                .is_empty()
        );
        requests.join().unwrap();
    }

    #[tokio::test]
    async fn list_repeated_cursor_and_expired_session_fail_clearly() {
        let page = json!({"records":[],"lastTimestamp":1700000000000_i64});
        let (client, requests) = server(vec![response(page.clone()), response(page)]);
        assert_eq!(
            client
                .list_workouts(
                    "synthetic-token",
                    1_699_999_999,
                    1_700_001_000,
                    &StravaCancellation::new()
                )
                .await
                .unwrap_err(),
            KeepError::PaginationLoop
        );
        requests.join().unwrap();
        let (client, requests) = server(vec![(401, "{}".to_owned())]);
        assert_eq!(
            client
                .download_fit(
                    "synthetic-token",
                    "synthetic_run",
                    &StravaCancellation::new()
                )
                .await
                .unwrap_err(),
            KeepError::SessionExpired
        );
        requests.join().unwrap();
    }

    #[tokio::test]
    async fn precancelled_and_invalid_inputs_send_no_request() {
        let client = KeepClient::new().unwrap();
        let cancel = StravaCancellation::new();
        cancel.cancel();
        assert_eq!(
            client.login("13800000000", "p", &cancel).await.unwrap_err(),
            KeepError::Cancelled
        );
        assert_eq!(
            client
                .list_workouts("bad\nsecret", 0, 1, &StravaCancellation::new())
                .await
                .unwrap_err(),
            KeepError::InvalidInput
        );
        assert_eq!(
            client
                .download_fit(
                    "synthetic-token",
                    "../../secret",
                    &StravaCancellation::new()
                )
                .await
                .unwrap_err(),
            KeepError::InvalidInput
        );
    }

    #[tokio::test]
    async fn bounded_http_responses_and_download_identity_are_checked() {
        let oversized = " ".repeat(64 * 1024 + 1);
        let (client, requests) = server(vec![(200, oversized)]);
        assert_eq!(
            client
                .login("13800000000", "synthetic", &StravaCancellation::new())
                .await
                .unwrap_err(),
            KeepError::LimitExceeded
        );
        requests.join().unwrap();
        let (client, requests) = server(vec![response(run(false))]);
        assert_eq!(
            client
                .download_fit(
                    "synthetic-token",
                    "different-run-id",
                    &StravaCancellation::new()
                )
                .await
                .unwrap_err(),
            KeepError::InvalidResponse
        );
        requests.join().unwrap();
    }

    #[tokio::test]
    async fn cancellation_interrupts_a_waiting_response_body() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let mut client = KeepClient::new().unwrap();
        client.base =
            reqwest::Url::parse(&format!("http://{}/", listener.local_addr().unwrap())).unwrap();
        let (sent, received) = tokio::sync::oneshot::channel();
        let (release, wait) = std::sync::mpsc::channel();
        let thread = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut bytes = [0; 8192];
            assert!(socket.read(&mut bytes).unwrap() > 0);
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 10000\r\n\r\n{")
                .unwrap();
            sent.send(()).unwrap();
            let _ = wait.recv_timeout(std::time::Duration::from_secs(5));
        });
        let cancel = StravaCancellation::new();
        let other = cancel.clone();
        let task = tokio::spawn(async move {
            client
                .download_fit("synthetic-token", "synthetic-run", &other)
                .await
        });
        received.await.unwrap();
        cancel.cancel();
        let result = tokio::time::timeout(std::time::Duration::from_millis(500), task)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(result.unwrap_err(), KeepError::Cancelled);
        release.send(()).unwrap();
        thread.join().unwrap();
    }

    #[test]
    fn production_origin_is_fixed_https_and_missing_login_success_is_rejected() {
        let client = KeepClient::new().unwrap();
        assert_eq!(client.base.as_str(), "https://api.gotokeep.com/");
        assert_eq!(
            checked_data(&json!({"data":{"token":"synthetic-token"}}), true),
            Err(KeepError::InvalidResponse)
        );
    }

    #[test]
    fn malformed_summaries_and_missing_sample_times_do_not_create_tracks() {
        for (field, value) in [
            ("duration", json!(0)),
            ("distance", json!(-1)),
            ("startTime", json!(1700000000)),
            ("endTime", json!(1699999999000_i64)),
        ] {
            let mut data = run(false);
            data[field] = value;
            assert_eq!(parse_run(&data).unwrap_err(), KeepError::InvalidResponse);
        }
        let start = 1_700_000_000_000;
        assert_eq!(
            point_timestamp(&json!({"unixTimestamp":10}), start, start + 10000).unwrap(),
            start + 1000
        );
    }

    fn run(indoor: bool) -> serde_json::Value {
        json!({"id":"synthetic_user_9223370000000000000_rn",
            "dataType":if indoor {"indoorRunning"} else {"outdoorRunning"},
            "startTime":1700000000000_i64,"endTime":1700000600000_i64,
            "duration":540,"distance":1600,"geoPoints":null,"heartRate":null})
    }

    #[test]
    fn summaries_keep_full_ids_units_and_run_classification() {
        let summary = parse_run(&run(true)).unwrap();
        assert_eq!(summary.id, "synthetic_user_9223370000000000000_rn");
        assert_eq!(summary.start_time_seconds, 1_700_000_000.0);
        assert_eq!(summary.end_time_seconds, 1_700_000_600.0);
        assert_eq!(summary.duration_seconds, 540.0);
        assert_eq!(summary.distance_meters, Some(1600.0));
        assert!(summary.indoor);
        let mut walking = run(false);
        walking["dataType"] = json!("outdoorWalking");
        assert_eq!(
            parse_run(&walking).unwrap_err(),
            KeepError::UnsupportedActivity
        );
    }

    #[test]
    fn indoor_fit_preserves_summary_without_inventing_positions() {
        let fit = detail_to_fit(&run(true), &crate::strava::StravaCancellation::new()).unwrap();
        let document = crate::fit::FitDocument::parse(&fit).unwrap();
        let session = document
            .messages()
            .iter()
            .position(|m| m.global_number() == 18)
            .unwrap();
        assert_eq!(document.read_u8(session, 5), Some(1));
        assert_eq!(document.read_u8(session, 6), Some(1));
        assert_eq!(document.read_u32(session, 8), Some(540_000));
        assert_eq!(document.read_u32(session, 9), Some(160_000));
        for (index, message) in document.messages().iter().enumerate() {
            if message.global_number() == 20 {
                assert_eq!(document.read_i32(index, 0), None);
                assert_eq!(document.read_i32(index, 1), None);
            }
        }
        assert!(fit.windows(5).any(|bytes| bytes == b"Keep\0"));
    }

    #[test]
    fn point_timestamp_variants_normalize_to_the_same_unix_milliseconds() {
        let start = 1_700_000_000_000_i64;
        let end = start + 600_000;
        for point in [
            json!({"timestamp":10}),
            json!({"timestamp":17_000_000_010_i64}),
            json!({"unixTimestamp":1_700_000_001_000_i64}),
            json!({"unixTimestamp":1_700_000_001_i64}),
        ] {
            assert_eq!(point_timestamp(&point, start, end).unwrap(), start + 1000);
        }
        assert_eq!(
            point_timestamp(&json!({}), start, end),
            Err(KeepError::InvalidResponse)
        );
        assert_eq!(
            point_timestamp(&json!({"timestamp":-10}), start, end),
            Err(KeepError::InvalidResponse)
        );
    }

    #[test]
    fn sensitive_errors_never_include_remote_text_or_tokens() {
        let response = json!({"ok":false,"code":401,"error":"synthetic-password-token"});
        assert_eq!(
            checked_data(&response, false).unwrap_err(),
            KeepError::SessionExpired
        );
        assert_eq!(
            checked_data(&response, true).unwrap_err(),
            KeepError::LoginRejected
        );
        assert!(!KeepError::SessionExpired.to_string().contains("synthetic"));
    }
}
