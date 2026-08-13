use reqwest::{Client, Response, Url, redirect::Policy};
use serde::Deserialize;
use std::{
    collections::HashMap,
    fmt,
    future::Future,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use tokio::sync::Notify;

const FORECAST_ENDPOINT: &str = "https://api.open-meteo.com/v1/forecast";
const HISTORICAL_FORECAST_ENDPOINT: &str =
    "https://historical-forecast-api.open-meteo.com/v1/forecast";
const ARCHIVE_ENDPOINT: &str = "https://archive-api.open-meteo.com/v1/archive";
const HOURLY_FIELDS: &str =
    "temperature_2m,relative_humidity_2m,pressure_msl,wind_speed_10m,wind_direction_10m";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(12);
const MAX_RESPONSE_BYTES: usize = 256 * 1024;
const CACHE_GRID_DEGREES: f64 = 0.1;
const MAX_CACHE_ENTRIES: usize = 128;
const FORECAST_CACHE_TTL: Duration = Duration::from_secs(15 * 60);
const HISTORICAL_CACHE_TTL: Duration = Duration::from_secs(24 * 60 * 60);

/// 与旧 Swift 分流一致的 Open-Meteo 数据源。
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum WeatherSource {
    Forecast,
    HistoricalForecast,
    Archive,
}

/// Open-Meteo 单点逐小时天气样本，时间为 Unix 秒。
#[derive(Clone, Debug, PartialEq)]
pub struct WeatherSample {
    pub time_seconds: i64,
    pub temperature_c: f64,
    pub relative_humidity_percent: f64,
    pub pressure_msl_hpa: f64,
    pub wind_speed_mps: f64,
    pub wind_from_degrees: f64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WeatherError {
    InvalidInput,
    ClientBuild,
    Transport,
    HttpStatus(u16),
    ResponseTooLarge,
    InvalidResponse,
    Cancelled,
}

impl fmt::Display for WeatherError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidInput => f.write_str("天气请求参数无效"),
            Self::ClientBuild => f.write_str("天气客户端初始化失败"),
            Self::Transport => f.write_str("天气网络请求失败"),
            Self::HttpStatus(status) => write!(f, "天气请求失败 (HTTP {status})"),
            Self::ResponseTooLarge => f.write_str("天气响应过大"),
            Self::InvalidResponse => f.write_str("天气响应无效"),
            Self::Cancelled => f.write_str("天气请求已取消"),
        }
    }
}

impl std::error::Error for WeatherError {}

/// 网络读取可立即取消；取消是终止状态，绝不会触发 Archive 回退。
#[derive(Clone, Default)]
pub struct WeatherCancellation {
    cancelled: Arc<AtomicBool>,
    notify: Arc<Notify>,
}

impl WeatherCancellation {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        if !self.cancelled.swap(true, Ordering::AcqRel) {
            self.notify.notify_waiters();
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    async fn cancelled(&self) {
        if !self.is_cancelled() {
            self.notify.notified().await;
        }
    }

    async fn run<F: Future>(&self, future: F) -> Result<F::Output, WeatherError> {
        tokio::select! {
            biased;
            _ = self.cancelled() => Err(WeatherError::Cancelled),
            output = future => Ok(output),
        }
    }
}

/// 固定官方 HTTPS 端点的天气客户端；无可配置 host，也拒绝所有重定向。
#[derive(Clone)]
pub struct OpenMeteoWeatherClient {
    client: Client,
    forecast_endpoint: Url,
    historical_forecast_endpoint: Url,
    archive_endpoint: Url,
}

impl OpenMeteoWeatherClient {
    pub fn new() -> Result<Self, WeatherError> {
        let client = Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .redirect(Policy::none())
            .user_agent("HealthWorkoutExport/1")
            .build()
            .map_err(|_| WeatherError::ClientBuild)?;
        Ok(Self {
            client,
            forecast_endpoint: fixed_weather_url(FORECAST_ENDPOINT, "api.open-meteo.com")?,
            historical_forecast_endpoint: fixed_weather_url(
                HISTORICAL_FORECAST_ENDPOINT,
                "historical-forecast-api.open-meteo.com",
            )?,
            archive_endpoint: fixed_weather_url(ARCHIVE_ENDPOINT, "archive-api.open-meteo.com")?,
        })
    }

    /// 主源空结果或普通失败时回退 Archive；取消和 Archive 本身的失败直接返回。
    pub async fn fetch_hourly(
        &self,
        latitude: f64,
        longitude: f64,
        start_seconds: i64,
        end_seconds: i64,
        now_seconds: i64,
        cancellation: &WeatherCancellation,
    ) -> Result<Vec<WeatherSample>, WeatherError> {
        validate_request(latitude, longitude, start_seconds, end_seconds)?;
        let source = preferred_source(end_seconds, now_seconds)?;
        let result = self
            .fetch_source(
                source,
                latitude,
                longitude,
                start_seconds,
                end_seconds,
                now_seconds,
                cancellation,
            )
            .await;
        if source == WeatherSource::Archive || matches!(result, Err(WeatherError::Cancelled)) {
            return result;
        }
        match result {
            Ok(samples) if !samples.is_empty() => Ok(samples),
            Ok(_) | Err(_) => {
                self.fetch_source(
                    WeatherSource::Archive,
                    latitude,
                    longitude,
                    start_seconds,
                    end_seconds,
                    now_seconds,
                    cancellation,
                )
                .await
            }
        }
    }

    #[allow(clippy::too_many_arguments)] // 请求边界就是 source + 坐标、时段、时钟与取消令牌，拆分只会制造临时对象。
    async fn fetch_source(
        &self,
        source: WeatherSource,
        latitude: f64,
        longitude: f64,
        start_seconds: i64,
        end_seconds: i64,
        now_seconds: i64,
        cancellation: &WeatherCancellation,
    ) -> Result<Vec<WeatherSample>, WeatherError> {
        let url = self.make_url(
            source,
            latitude,
            longitude,
            start_seconds,
            end_seconds,
            now_seconds,
        )?;
        let mut response = cancellation
            .run(self.client.get(url).send())
            .await?
            .map_err(|_| WeatherError::Transport)?;
        if response.status().is_redirection() {
            return Err(WeatherError::HttpStatus(response.status().as_u16()));
        }
        if !response.status().is_success() {
            return Err(WeatherError::HttpStatus(response.status().as_u16()));
        }
        let body = read_body_limited(&mut response, cancellation).await?;
        decode_hourly(&body)
    }

    pub fn make_url(
        &self,
        source: WeatherSource,
        latitude: f64,
        longitude: f64,
        start_seconds: i64,
        end_seconds: i64,
        now_seconds: i64,
    ) -> Result<Url, WeatherError> {
        validate_request(latitude, longitude, start_seconds, end_seconds)?;
        let start = utc_day(start_seconds)?;
        let end = utc_day(end_seconds)?;
        let today = utc_day(now_seconds)?;
        let endpoint = match source {
            WeatherSource::Forecast => &self.forecast_endpoint,
            WeatherSource::HistoricalForecast => &self.historical_forecast_endpoint,
            WeatherSource::Archive => &self.archive_endpoint,
        };
        let mut url = endpoint.clone();
        let mut pairs = url.query_pairs_mut();
        pairs
            .append_pair("latitude", &latitude.to_string())
            .append_pair("longitude", &longitude.to_string())
            .append_pair("hourly", HOURLY_FIELDS)
            .append_pair("wind_speed_unit", "ms")
            .append_pair("timezone", "UTC");
        match source {
            WeatherSource::Forecast => {
                let past_days = ((today - start).whole_days()).clamp(0, 92);
                let forecast_days = ((end - today).whole_days() + 1).clamp(1, 16);
                pairs
                    .append_pair("past_days", &past_days.to_string())
                    .append_pair("forecast_days", &forecast_days.to_string());
            }
            WeatherSource::HistoricalForecast | WeatherSource::Archive => {
                pairs
                    .append_pair("start_date", &date_string(start))
                    .append_pair("end_date", &date_string(end));
            }
        }
        drop(pairs);
        Ok(url)
    }
}

/// 缓存仅在当前进程存活期间有效；Forecast 15 分钟，其余来源 24 小时，且最多保留 128 项。
#[derive(Default)]
pub struct OpenMeteoWeatherCache {
    entries: HashMap<String, CacheEntry>,
}

struct CacheEntry {
    samples: Vec<WeatherSample>,
    stored_at: Instant,
    source: WeatherSource,
}

impl OpenMeteoWeatherCache {
    pub fn get(
        &mut self,
        latitude: f64,
        longitude: f64,
        start_seconds: i64,
        end_seconds: i64,
        now_seconds: i64,
    ) -> Result<Option<Vec<WeatherSample>>, WeatherError> {
        let source = preferred_source(end_seconds, now_seconds)?;
        let key = cache_key(latitude, longitude, start_seconds, end_seconds, now_seconds)?;
        let Some(entry) = self.entries.get(&key) else {
            return Ok(None);
        };
        if entry.source == source && entry.stored_at.elapsed() < cache_ttl(source) {
            return Ok(Some(entry.samples.clone()));
        }
        self.entries.remove(&key);
        Ok(None)
    }

    pub fn insert(
        &mut self,
        latitude: f64,
        longitude: f64,
        start_seconds: i64,
        end_seconds: i64,
        now_seconds: i64,
        samples: Vec<WeatherSample>,
    ) -> Result<(), WeatherError> {
        let source = preferred_source(end_seconds, now_seconds)?;
        let key = cache_key(latitude, longitude, start_seconds, end_seconds, now_seconds)?;
        if self.entries.len() >= MAX_CACHE_ENTRIES && !self.entries.contains_key(&key) {
            self.entries.clear();
        }
        self.entries.insert(
            key,
            CacheEntry {
                samples,
                stored_at: Instant::now(),
                source,
            },
        );
        Ok(())
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

pub fn preferred_source(end_seconds: i64, now_seconds: i64) -> Result<WeatherSource, WeatherError> {
    let end_day = utc_day(end_seconds)?;
    let today = utc_day(now_seconds)?;
    if (today - end_day).whole_days() <= 7 {
        return Ok(WeatherSource::Forecast);
    }
    let historical_start = OffsetDateTime::from_unix_timestamp(1_640_995_200)
        .map_err(|_| WeatherError::InvalidInput)?;
    if end_day >= historical_start {
        Ok(WeatherSource::HistoricalForecast)
    } else {
        Ok(WeatherSource::Archive)
    }
}

pub fn cache_key(
    latitude: f64,
    longitude: f64,
    start_seconds: i64,
    end_seconds: i64,
    now_seconds: i64,
) -> Result<String, WeatherError> {
    validate_request(latitude, longitude, start_seconds, end_seconds)?;
    let source = preferred_source(end_seconds, now_seconds)?;
    let start = date_string(utc_day(start_seconds)?);
    let end = date_string(utc_day(end_seconds)?);
    let grid_lat = (latitude / CACHE_GRID_DEGREES).round() * CACHE_GRID_DEGREES;
    let grid_lon = (longitude / CACHE_GRID_DEGREES).round() * CACHE_GRID_DEGREES;
    Ok(format!(
        "{}|{grid_lat:.1},{grid_lon:.1}@{start}_{end}",
        source_name(source)
    ))
}

fn fixed_weather_url(raw: &str, host: &str) -> Result<Url, WeatherError> {
    let url = Url::parse(raw).map_err(|_| WeatherError::ClientBuild)?;
    (url.scheme() == "https"
        && url.host_str() == Some(host)
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none())
    .then_some(url)
    .ok_or(WeatherError::ClientBuild)
}

fn validate_request(
    latitude: f64,
    longitude: f64,
    start_seconds: i64,
    end_seconds: i64,
) -> Result<(), WeatherError> {
    (latitude.is_finite()
        && longitude.is_finite()
        && (-90.0..=90.0).contains(&latitude)
        && (-180.0..=180.0).contains(&longitude)
        && start_seconds <= end_seconds
        && OffsetDateTime::from_unix_timestamp(start_seconds).is_ok()
        && OffsetDateTime::from_unix_timestamp(end_seconds).is_ok())
    .then_some(())
    .ok_or(WeatherError::InvalidInput)
}

async fn read_body_limited(
    response: &mut Response,
    cancellation: &WeatherCancellation,
) -> Result<Vec<u8>, WeatherError> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
    {
        return Err(WeatherError::ResponseTooLarge);
    }
    let mut body = Vec::with_capacity(
        response
            .content_length()
            .unwrap_or_default()
            .min(MAX_RESPONSE_BYTES as u64) as usize,
    );
    loop {
        let chunk = cancellation
            .run(response.chunk())
            .await?
            .map_err(|_| WeatherError::Transport)?;
        let Some(chunk) = chunk else { break };
        if body.len().saturating_add(chunk.len()) > MAX_RESPONSE_BYTES {
            return Err(WeatherError::ResponseTooLarge);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn decode_hourly(body: &[u8]) -> Result<Vec<WeatherSample>, WeatherError> {
    let hourly = serde_json::from_slice::<HourlyResponse>(body)
        .map_err(|_| WeatherError::InvalidResponse)?
        .hourly
        .ok_or(WeatherError::InvalidResponse)?;
    let temperatures = hourly.temperature_2m.ok_or(WeatherError::InvalidResponse)?;
    if hourly.time.len() != temperatures.len() {
        return Err(WeatherError::InvalidResponse);
    }
    let mut samples = Vec::with_capacity(hourly.time.len());
    for (index, raw_time) in hourly.time.iter().enumerate() {
        let (Some(time_seconds), Some(temperature_c)) =
            (parse_hourly_time(raw_time), temperatures[index])
        else {
            continue;
        };
        samples.push(WeatherSample {
            time_seconds,
            temperature_c,
            relative_humidity_percent: at(&hourly.relative_humidity_2m, index).unwrap_or(50.0),
            pressure_msl_hpa: at(&hourly.pressure_msl, index).unwrap_or(1013.25),
            wind_speed_mps: at(&hourly.wind_speed_10m, index).unwrap_or(0.0),
            wind_from_degrees: at(&hourly.wind_direction_10m, index).unwrap_or(0.0),
        });
    }
    Ok(samples)
}

fn at(values: &Option<Vec<Option<f64>>>, index: usize) -> Option<f64> {
    values
        .as_ref()
        .and_then(|values| values.get(index))
        .and_then(|value| *value)
}

fn parse_hourly_time(raw: &str) -> Option<i64> {
    let raw = raw.strip_suffix('Z').unwrap_or(raw);
    let raw = if raw.len() == 16 {
        format!("{raw}:00Z")
    } else {
        format!("{raw}Z")
    };
    OffsetDateTime::parse(&raw, &Rfc3339)
        .ok()
        .map(|time| time.unix_timestamp())
}

fn utc_day(seconds: i64) -> Result<OffsetDateTime, WeatherError> {
    let time =
        OffsetDateTime::from_unix_timestamp(seconds).map_err(|_| WeatherError::InvalidInput)?;
    Ok(time.replace_time(time::Time::MIDNIGHT))
}

fn date_string(day: OffsetDateTime) -> String {
    format!(
        "{:04}-{:02}-{:02}",
        day.year(),
        day.month() as u8,
        day.day()
    )
}

fn cache_ttl(source: WeatherSource) -> Duration {
    match source {
        WeatherSource::Forecast => FORECAST_CACHE_TTL,
        WeatherSource::HistoricalForecast | WeatherSource::Archive => HISTORICAL_CACHE_TTL,
    }
}

fn source_name(source: WeatherSource) -> &'static str {
    match source {
        WeatherSource::Forecast => "forecast",
        WeatherSource::HistoricalForecast => "historicalForecast",
        WeatherSource::Archive => "archive",
    }
}

#[derive(Deserialize)]
struct HourlyResponse {
    hourly: Option<Hourly>,
}

#[derive(Deserialize)]
struct Hourly {
    time: Vec<String>,
    temperature_2m: Option<Vec<Option<f64>>>,
    relative_humidity_2m: Option<Vec<Option<f64>>>,
    pressure_msl: Option<Vec<Option<f64>>>,
    wind_speed_10m: Option<Vec<Option<f64>>>,
    wind_direction_10m: Option<Vec<Option<f64>>>,
}

#[cfg(test)]
mod tests {
    use super::{
        OpenMeteoWeatherCache, OpenMeteoWeatherClient, WeatherCancellation, WeatherError,
        WeatherSample, WeatherSource, cache_key, decode_hourly, fixed_weather_url,
        preferred_source,
    };

    const NOW: i64 = 1_754_611_200; // 2025-08-08T00:00:00Z

    #[test]
    fn source_selection_matches_swift_boundaries() {
        assert_eq!(preferred_source(NOW, NOW), Ok(WeatherSource::Forecast));
        assert_eq!(
            preferred_source(NOW - 7 * 86_400, NOW),
            Ok(WeatherSource::Forecast)
        );
        assert_eq!(
            preferred_source(NOW - 8 * 86_400, NOW),
            Ok(WeatherSource::HistoricalForecast)
        );
        assert_eq!(
            preferred_source(1_640_908_800, NOW), // 2021-12-31
            Ok(WeatherSource::Archive)
        );
    }

    #[test]
    fn fixed_urls_and_query_parameters_are_safe_and_complete() {
        assert!(
            fixed_weather_url(
                "https://api.open-meteo.com/v1/forecast",
                "api.open-meteo.com"
            )
            .is_ok()
        );
        assert!(
            fixed_weather_url(
                "http://api.open-meteo.com/v1/forecast",
                "api.open-meteo.com"
            )
            .is_err()
        );
        assert!(
            fixed_weather_url(
                "https://api.open-meteo.com.example/v1/forecast",
                "api.open-meteo.com"
            )
            .is_err()
        );
        let client = OpenMeteoWeatherClient::new().unwrap();
        let url = client
            .make_url(
                WeatherSource::Forecast,
                31.3,
                120.6,
                NOW - 2 * 86_400,
                NOW - 2 * 86_400,
                NOW,
            )
            .unwrap();
        let pairs: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(url.host_str(), Some("api.open-meteo.com"));
        assert_eq!(pairs.get("past_days"), Some(&"2".to_owned()));
        assert_eq!(pairs.get("forecast_days"), Some(&"1".to_owned()));
        assert!(!pairs.contains_key("start_date"));
    }

    #[test]
    fn cache_uses_grid_dates_and_source_and_can_be_cleared() {
        let recent = NOW - 2 * 86_400;
        let same_grid = cache_key(31.20, 121.50, recent, recent, NOW).unwrap();
        assert_eq!(
            same_grid,
            cache_key(31.24, 121.54, recent, recent, NOW).unwrap()
        );
        assert_ne!(
            same_grid,
            cache_key(31.20, 121.50, recent - 86_400, recent - 86_400, NOW).unwrap()
        );
        let mut cache = OpenMeteoWeatherCache::default();
        let sample = WeatherSample {
            time_seconds: recent,
            temperature_c: 20.0,
            relative_humidity_percent: 50.0,
            pressure_msl_hpa: 1013.0,
            wind_speed_mps: 3.0,
            wind_from_degrees: 90.0,
        };
        cache
            .insert(31.20, 121.50, recent, recent, NOW, vec![sample.clone()])
            .unwrap();
        assert_eq!(
            cache.get(31.21, 121.51, recent, recent, NOW).unwrap(),
            Some(vec![sample])
        );
        cache.clear();
        assert_eq!(cache.len(), 0);
    }

    #[test]
    fn decodes_defaults_and_rejects_invalid_shape() {
        let samples =
            decode_hourly(br#"{"hourly":{"time":["2025-08-06T00:00"],"temperature_2m":[20]}}"#)
                .unwrap();
        assert_eq!(samples[0].time_seconds, NOW - 2 * 86_400);
        assert_eq!(samples[0].pressure_msl_hpa, 1013.25);
        assert_eq!(
            decode_hourly(br#"{"hourly":{"time":[],"temperature_2m":[20]}}"#),
            Err(WeatherError::InvalidResponse)
        );
    }

    #[tokio::test]
    async fn cancellation_is_terminal() {
        let cancellation = WeatherCancellation::new();
        cancellation.cancel();
        let result = cancellation.run(std::future::pending::<()>()).await;
        assert_eq!(result, Err(WeatherError::Cancelled));
    }
}
