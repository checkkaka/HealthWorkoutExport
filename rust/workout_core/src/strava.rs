use reqwest::{
    Client, Response, StatusCode, Url,
    multipart::{Form, Part},
    redirect::Policy,
};
use serde::Deserialize;
use std::{
    collections::HashSet,
    fmt,
    future::Future,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use tokio::sync::Notify;

const TOKEN_ENDPOINT: &str = "https://www.strava.com/oauth/token";
const UPLOAD_ENDPOINT: &str = "https://www.strava.com/api/v3/uploads";
const ACTIVITIES_ENDPOINT: &str = "https://www.strava.com/api/v3/athlete/activities";
const ACTIVITY_DETAIL_ENDPOINT: &str = "https://www.strava.com/api/v3/activities/";
const MAX_INPUT_BYTES: usize = 8 * 1024;
const MAX_RESPONSE_BYTES: usize = 64 * 1024;
/// 列表页最多 200 条；上限足够容纳完整官方响应，同时避免错误页无限占用内存。
const MAX_ACTIVITY_RESPONSE_BYTES: usize = 2 * 1024 * 1024;
const MAX_ACTIVITY_PAGES: u32 = 20;
const ACTIVITY_PAGE_SIZE: u32 = 200;
const MAX_FIT_BYTES: usize = 64 * 1024 * 1024;
const UPLOAD_POLL_DELAYS_SECONDS: [u64; 7] = [0, 1, 2, 4, 8, 16, 32];
const UPLOAD_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const POLL_REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
const ACTIVITY_REQUEST_TIMEOUT: Duration = Duration::from_secs(20);

/// OAuth token endpoint client. It never logs or embeds credential values in errors.
#[derive(Clone)]
pub struct StravaTokenClient {
    client: Client,
    endpoint: String,
}

impl StravaTokenClient {
    pub fn new() -> Result<Self, StravaTokenError> {
        Self::with_endpoint(TOKEN_ENDPOINT.to_owned())
    }

    fn with_endpoint(endpoint: String) -> Result<Self, StravaTokenError> {
        let client = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(Policy::none())
            .user_agent("HealthWorkoutExport/1")
            .build()
            .map_err(|_| StravaTokenError::ClientBuild)?;
        Ok(Self { client, endpoint })
    }

    #[cfg(test)]
    fn for_test(endpoint: String) -> Result<Self, StravaTokenError> {
        Self::with_endpoint(endpoint)
    }

    pub async fn exchange_code(
        &self,
        client_id: &str,
        client_secret: &str,
        code: &str,
    ) -> Result<StravaToken, StravaTokenError> {
        let client_id = valid_input("client_id", client_id)?;
        let client_secret = valid_input("client_secret", client_secret)?;
        let code = valid_input("code", code)?;
        self.request(&[
            ("client_id", client_id),
            ("client_secret", client_secret),
            ("code", code),
            ("grant_type", "authorization_code"),
        ])
        .await
    }

    pub async fn refresh(
        &self,
        client_id: &str,
        client_secret: &str,
        refresh_token: &str,
    ) -> Result<StravaToken, StravaTokenError> {
        let client_id = valid_input("client_id", client_id)?;
        let client_secret = valid_input("client_secret", client_secret)?;
        let refresh_token = valid_input("refresh_token", refresh_token)?;
        self.request(&[
            ("client_id", client_id),
            ("client_secret", client_secret),
            ("refresh_token", refresh_token),
            ("grant_type", "refresh_token"),
        ])
        .await
    }

    async fn request(&self, form: &[(&str, &str)]) -> Result<StravaToken, StravaTokenError> {
        let mut response = self
            .client
            .post(&self.endpoint)
            .form(form)
            .send()
            .await
            .map_err(|_| StravaTokenError::Transport)?;
        match response.status() {
            StatusCode::OK => {}
            StatusCode::BAD_REQUEST | StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
                return Err(StravaTokenError::Unauthorized);
            }
            status => return Err(StravaTokenError::HttpStatus(status.as_u16())),
        }

        if response
            .content_length()
            .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
        {
            return Err(StravaTokenError::ResponseTooLarge);
        }
        let mut body = Vec::with_capacity(
            response
                .content_length()
                .unwrap_or_default()
                .min(MAX_RESPONSE_BYTES as u64) as usize,
        );
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| StravaTokenError::Transport)?
        {
            if body.len().saturating_add(chunk.len()) > MAX_RESPONSE_BYTES {
                return Err(StravaTokenError::ResponseTooLarge);
            }
            body.extend_from_slice(&chunk);
        }
        StravaToken::parse(&body)
    }
}

/// 可跨 FFI 调用取消上传或轮询；取消后正在等待的网络/计时 Future 会被立即丢弃。
#[derive(Clone, Default)]
pub struct StravaCancellation {
    cancelled: Arc<AtomicBool>,
    notify: Arc<Notify>,
}

impl StravaCancellation {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        if !self.cancelled.swap(true, Ordering::AcqRel) {
            self.notify.notify_one();
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

    async fn run<F: Future>(&self, future: F) -> Result<F::Output, StravaUploadError> {
        tokio::select! {
            biased;
            _ = self.cancelled() => Err(StravaUploadError::Cancelled),
            output = future => Ok(output),
        }
    }
}

/// 远端活动列表条目；时间为 Unix 秒，距离缺失时为 `None`。
/// 仅保留上传预检所需字段，避免把未经验证的远端 JSON 直接暴露给 Flutter。
#[derive(Clone, Debug, PartialEq)]
pub struct StravaRemoteActivity {
    pub id: String,
    pub start_time_seconds: f64,
    pub end_time_seconds: f64,
    pub distance_meters: Option<f64>,
}

/// 单条活动的速度摘要。峰值只基于官方摘要和 best_efforts，不读取速度流毛刺。
#[derive(Clone, Debug, PartialEq)]
pub struct StravaActivitySpeedInfo {
    pub id: String,
    pub name: String,
    pub start_time_seconds: Option<f64>,
    pub sport_type: String,
    pub listed_max_speed_mps: f64,
    pub best_effort_peak_mps: f64,
    pub max_speed_mps: f64,
    pub average_speed_mps: f64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StravaActivityError {
    InvalidInput(&'static str),
    ClientBuild,
    Transport,
    Unauthorized,
    RateLimited,
    NotFound,
    ResponseTooLarge,
    InvalidResponse,
    HttpStatus(u16),
    Cancelled,
}

impl fmt::Display for StravaActivityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidInput(_) => "Strava 活动请求参数无效",
            Self::ClientBuild => "Strava 活动客户端初始化失败",
            Self::Transport => "Strava 活动网络请求失败",
            Self::Unauthorized => "Strava 授权已失效",
            Self::RateLimited => "Strava 请求频率受限，请稍后重试",
            Self::NotFound => "Strava 活动不存在",
            Self::ResponseTooLarge => "Strava 活动响应过大",
            Self::InvalidResponse => "Strava 活动响应无效",
            Self::HttpStatus(status) => {
                return write!(formatter, "Strava 活动请求失败 (HTTP {status})");
            }
            Self::Cancelled => "Strava 活动请求已取消",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for StravaActivityError {}

/// 固定读取官方 HTTPS API 的客户端。它没有可配置 endpoint，防止 access token 被导向任意主机。
#[derive(Clone)]
pub struct StravaActivityClient {
    client: Client,
    activities_endpoint: Url,
    activity_detail_endpoint: Url,
}

impl StravaActivityClient {
    pub fn new() -> Result<Self, StravaActivityError> {
        let client = Client::builder()
            .timeout(ACTIVITY_REQUEST_TIMEOUT)
            .redirect(Policy::none())
            .user_agent("HealthWorkoutExport/1")
            .build()
            .map_err(|_| StravaActivityError::ClientBuild)?;
        Ok(Self {
            client,
            activities_endpoint: fixed_strava_url(ACTIVITIES_ENDPOINT)?,
            activity_detail_endpoint: fixed_strava_url(ACTIVITY_DETAIL_ENDPOINT)?,
        })
    }

    /// 按旧 Swift 契约拉取本人活动：after/before、每页 200 条、最多 20 页。
    pub async fn list_activities(
        &self,
        access_token: &str,
        after_seconds: i64,
        before_seconds: i64,
        cancellation: &StravaCancellation,
    ) -> Result<Vec<StravaRemoteActivity>, StravaActivityError> {
        let access_token = valid_upload_input("access_token", access_token)
            .map_err(|_| StravaActivityError::InvalidInput("access_token"))?;
        valid_activity_window(after_seconds, before_seconds)?;

        let mut result = Vec::new();
        let mut ids = HashSet::new();
        for page in 1..=MAX_ACTIVITY_PAGES {
            if cancellation.is_cancelled() {
                return Err(StravaActivityError::Cancelled);
            }
            let mut url = self.activities_endpoint.clone();
            url.query_pairs_mut()
                .append_pair("after", &after_seconds.to_string())
                .append_pair("before", &before_seconds.to_string())
                .append_pair("per_page", &ACTIVITY_PAGE_SIZE.to_string())
                .append_pair("page", &page.to_string());
            let mut response = cancellation
                .run(self.client.get(url).bearer_auth(access_token).send())
                .await
                .map_err(|_| StravaActivityError::Cancelled)?
                .map_err(|_| StravaActivityError::Transport)?;
            activity_status(response.status(), false)?;
            let body = read_activity_body(&mut response, cancellation).await?;
            let entries = serde_json::from_slice::<Vec<serde_json::Value>>(&body)
                .map_err(|_| StravaActivityError::InvalidResponse)?;
            let entry_count = entries.len();
            if entry_count == 0 {
                break;
            }
            for entry in entries {
                let Some(activity) = parse_remote_activity(&entry) else {
                    continue;
                };
                if ids.insert(activity.id.clone()) {
                    result.push(activity);
                }
            }
            if entry_count < ACTIVITY_PAGE_SIZE as usize {
                break;
            }
        }
        Ok(result)
    }

    /// 拉取单条活动的速度摘要；404 表示活动已删除或当前账号无权查看，返回 `None`。
    pub async fn activity_speed(
        &self,
        access_token: &str,
        activity_id: &str,
        cancellation: &StravaCancellation,
    ) -> Result<Option<StravaActivitySpeedInfo>, StravaActivityError> {
        let access_token = valid_upload_input("access_token", access_token)
            .map_err(|_| StravaActivityError::InvalidInput("access_token"))?;
        let activity_id = valid_remote_activity_id(activity_id)?;
        if cancellation.is_cancelled() {
            return Err(StravaActivityError::Cancelled);
        }
        let mut url = self.activity_detail_endpoint.clone();
        url.path_segments_mut()
            .map_err(|_| StravaActivityError::ClientBuild)?
            .push(activity_id);
        let mut response = cancellation
            .run(self.client.get(url).bearer_auth(access_token).send())
            .await
            .map_err(|_| StravaActivityError::Cancelled)?
            .map_err(|_| StravaActivityError::Transport)?;
        if !activity_status(response.status(), true)? {
            return Ok(None);
        }
        let body = read_activity_body(&mut response, cancellation).await?;
        let value = serde_json::from_slice::<serde_json::Value>(&body)
            .map_err(|_| StravaActivityError::InvalidResponse)?;
        parse_activity_speed(activity_id, &value)
            .map(Some)
            .ok_or(StravaActivityError::InvalidResponse)
    }
}

fn fixed_strava_url(value: &str) -> Result<Url, StravaActivityError> {
    let url = Url::parse(value).map_err(|_| StravaActivityError::ClientBuild)?;
    if url.scheme() != "https" || url.host_str() != Some("www.strava.com") || url.port().is_some() {
        return Err(StravaActivityError::ClientBuild);
    }
    Ok(url)
}

fn valid_activity_window(
    after_seconds: i64,
    before_seconds: i64,
) -> Result<(), StravaActivityError> {
    (after_seconds >= 0 && before_seconds > after_seconds)
        .then_some(())
        .ok_or(StravaActivityError::InvalidInput("activity_window"))
}

fn valid_remote_activity_id(value: &str) -> Result<&str, StravaActivityError> {
    let value = value.trim();
    (!value.is_empty() && value.len() <= 32 && value.bytes().all(|byte| byte.is_ascii_digit()))
        .then_some(value)
        .ok_or(StravaActivityError::InvalidInput("activity_id"))
}

fn activity_status(status: StatusCode, detail_request: bool) -> Result<bool, StravaActivityError> {
    if status.is_success() {
        return Ok(true);
    }
    match status {
        StatusCode::NOT_FOUND if detail_request => Ok(false),
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => Err(StravaActivityError::Unauthorized),
        StatusCode::TOO_MANY_REQUESTS => Err(StravaActivityError::RateLimited),
        status => Err(StravaActivityError::HttpStatus(status.as_u16())),
    }
}

async fn read_activity_body(
    response: &mut Response,
    cancellation: &StravaCancellation,
) -> Result<Vec<u8>, StravaActivityError> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_ACTIVITY_RESPONSE_BYTES as u64)
    {
        return Err(StravaActivityError::ResponseTooLarge);
    }
    let mut body = Vec::with_capacity(
        response
            .content_length()
            .unwrap_or_default()
            .min(MAX_ACTIVITY_RESPONSE_BYTES as u64) as usize,
    );
    loop {
        let chunk = cancellation
            .run(response.chunk())
            .await
            .map_err(|_| StravaActivityError::Cancelled)?
            .map_err(|_| StravaActivityError::Transport)?;
        let Some(chunk) = chunk else { break };
        if body.len().saturating_add(chunk.len()) > MAX_ACTIVITY_RESPONSE_BYTES {
            return Err(StravaActivityError::ResponseTooLarge);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn parse_remote_activity(value: &serde_json::Value) -> Option<StravaRemoteActivity> {
    let id = json_numeric_id(value.get("id"))?;
    let id = valid_remote_activity_id(&id).ok()?.to_owned();
    let start_time_seconds = parse_strava_time(value.get("start_date"))
        .or_else(|| parse_strava_time(value.get("start_date_local")))?;
    let elapsed = json_positive_number(value.get("elapsed_time"))?;
    let end_time_seconds = start_time_seconds + elapsed;
    end_time_seconds
        .is_finite()
        .then_some(StravaRemoteActivity {
            id,
            start_time_seconds,
            end_time_seconds,
            distance_meters: json_positive_number(value.get("distance")),
        })
}

fn parse_activity_speed(id: &str, value: &serde_json::Value) -> Option<StravaActivitySpeedInfo> {
    let object = value.as_object()?;
    let fallback_name = format!("活动 {id}");
    let listed_max_speed_mps = json_non_negative_number(object.get("max_speed")).unwrap_or(0.0);
    let average_speed_mps = json_non_negative_number(object.get("average_speed")).unwrap_or(0.0);
    let best_effort_peak_mps = object
        .get("best_efforts")
        .and_then(serde_json::Value::as_array)
        .map(|efforts| {
            efforts.iter().fold(0.0_f64, |peak, effort| {
                let distance = json_non_negative_number(effort.get("distance")).unwrap_or(0.0);
                let elapsed = json_positive_number(effort.get("elapsed_time"))
                    .or_else(|| json_positive_number(effort.get("moving_time")))
                    .unwrap_or(0.0);
                if distance >= 200.0 && elapsed > 0.0 {
                    peak.max(distance / elapsed)
                } else {
                    peak
                }
            })
        })
        .unwrap_or(0.0);
    Some(StravaActivitySpeedInfo {
        id: id.to_owned(),
        name: safe_activity_text(
            object.get("name").and_then(serde_json::Value::as_str),
            &fallback_name,
            256,
        ),
        start_time_seconds: parse_strava_time(object.get("start_date"))
            .or_else(|| parse_strava_time(object.get("start_date_local"))),
        sport_type: safe_activity_text(
            object
                .get("sport_type")
                .or_else(|| object.get("type"))
                .or_else(|| object.get("activity_type"))
                .or_else(|| object.get("activityType"))
                .and_then(serde_json::Value::as_str),
            "",
            128,
        ),
        listed_max_speed_mps,
        best_effort_peak_mps,
        max_speed_mps: listed_max_speed_mps.max(best_effort_peak_mps),
        average_speed_mps,
    })
}

fn parse_strava_time(value: Option<&serde_json::Value>) -> Option<f64> {
    let text = value?.as_str()?;
    let timestamp_nanos = OffsetDateTime::parse(text, &Rfc3339)
        .ok()?
        .unix_timestamp_nanos();
    let seconds = timestamp_nanos as f64 / 1_000_000_000.0;
    seconds.is_finite().then_some(seconds)
}

fn json_non_negative_number(value: Option<&serde_json::Value>) -> Option<f64> {
    let number = match value? {
        serde_json::Value::Number(number) => number.as_f64(),
        serde_json::Value::String(text) => text.trim().parse::<f64>().ok(),
        _ => None,
    }?;
    (number.is_finite() && number >= 0.0).then_some(number)
}

fn json_positive_number(value: Option<&serde_json::Value>) -> Option<f64> {
    json_non_negative_number(value).filter(|number| *number > 0.0)
}

fn safe_activity_text(value: Option<&str>, fallback: &str, max_bytes: usize) -> String {
    let value = value.unwrap_or(fallback).trim();
    if value.is_empty() || value.len() > max_bytes || value.chars().any(char::is_control) {
        return fallback.to_owned();
    }
    value.to_owned()
}

/// Strava Uploads API 客户端。凭证只进入 Authorization header，不进入错误或日志。
#[derive(Clone)]
pub struct StravaUploadClient {
    client: Client,
    uploads_endpoint: Url,
    poll_delays: [Duration; UPLOAD_POLL_DELAYS_SECONDS.len()],
    max_fit_bytes: usize,
}

impl StravaUploadClient {
    pub fn new() -> Result<Self, StravaUploadError> {
        Self::with_endpoint(UPLOAD_ENDPOINT, MAX_FIT_BYTES)
    }

    fn with_endpoint(endpoint: &str, max_fit_bytes: usize) -> Result<Self, StravaUploadError> {
        let client = Client::builder()
            .redirect(Policy::none())
            .user_agent("HealthWorkoutExport/1")
            .build()
            .map_err(|_| StravaUploadError::ClientBuild)?;
        let uploads_endpoint = Url::parse(endpoint).map_err(|_| StravaUploadError::ClientBuild)?;
        Ok(Self {
            client,
            uploads_endpoint,
            poll_delays: UPLOAD_POLL_DELAYS_SECONDS.map(Duration::from_secs),
            max_fit_bytes,
        })
    }

    #[cfg(test)]
    fn for_test(endpoint: String, max_fit_bytes: usize) -> Result<Self, StravaUploadError> {
        let mut client = Self::with_endpoint(&endpoint, max_fit_bytes)?;
        client.poll_delays = [Duration::ZERO; UPLOAD_POLL_DELAYS_SECONDS.len()];
        Ok(client)
    }

    pub async fn upload_fit(
        &self,
        access_token: &str,
        fit: Vec<u8>,
        external_id: &str,
        filename: &str,
        commute: bool,
        description: Option<&str>,
    ) -> Result<StravaUploadResult, StravaUploadError> {
        self.upload_fit_cancellable(
            access_token,
            fit,
            external_id,
            filename,
            commute,
            description,
            &StravaCancellation::new(),
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn upload_fit_cancellable(
        &self,
        access_token: &str,
        fit: Vec<u8>,
        external_id: &str,
        filename: &str,
        commute: bool,
        description: Option<&str>,
        cancellation: &StravaCancellation,
    ) -> Result<StravaUploadResult, StravaUploadError> {
        self.send_upload(
            access_token,
            fit,
            external_id,
            filename,
            commute,
            description,
            cancellation,
            false,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn retry_upload_after_refresh(
        &self,
        access_token: &str,
        fit: Vec<u8>,
        external_id: &str,
        filename: &str,
        commute: bool,
        description: Option<&str>,
        cancellation: &StravaCancellation,
    ) -> Result<StravaUploadResult, StravaUploadError> {
        self.send_upload(
            access_token,
            fit,
            external_id,
            filename,
            commute,
            description,
            cancellation,
            true,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    async fn send_upload(
        &self,
        access_token: &str,
        fit: Vec<u8>,
        external_id: &str,
        filename: &str,
        commute: bool,
        description: Option<&str>,
        cancellation: &StravaCancellation,
        auth_retry_used: bool,
    ) -> Result<StravaUploadResult, StravaUploadError> {
        let access_token = valid_upload_input("access_token", access_token)?;
        let external_id = valid_upload_input("external_id", external_id)?;
        if fit.is_empty() || fit.len() > self.max_fit_bytes {
            return Err(StravaUploadError::InvalidInput("fit"));
        }
        if filename.trim().is_empty()
            || filename.len() > 255
            || filename.contains(['/', '\\'])
            || filename
                .chars()
                .any(|character| character.is_ascii_control())
        {
            return Err(StravaUploadError::InvalidInput("filename"));
        }
        if description.is_some_and(|value| {
            value.len() > MAX_INPUT_BYTES
                || value.chars().any(|character| character.is_ascii_control())
        }) {
            return Err(StravaUploadError::InvalidInput("description"));
        }

        let file = Part::bytes(fit)
            .file_name(filename.to_owned())
            .mime_str("application/octet-stream")
            .map_err(|_| StravaUploadError::InvalidInput("filename"))?;
        let mut form = Form::new()
            .text("data_type", "fit")
            .text("external_id", external_id.to_owned());
        if commute {
            form = form.text("commute", "1");
        }
        if let Some(description) = description.filter(|value| !value.is_empty()) {
            form = form.text("description", description.to_owned());
        }
        form = form.part("file", file);

        let request = self
            .client
            .post(self.uploads_endpoint.clone())
            .timeout(UPLOAD_TIMEOUT)
            .bearer_auth(access_token)
            .multipart(form)
            .send();
        let mut response = cancellation
            .run(request)
            .await?
            .map_err(|_| StravaUploadError::Transport)?;
        match response.status() {
            StatusCode::TOO_MANY_REQUESTS => return Err(StravaUploadError::RateLimited),
            StatusCode::UNAUTHORIZED if auth_retry_used => {
                return Err(StravaUploadError::UnauthorizedAfterRefresh);
            }
            StatusCode::UNAUTHORIZED => {
                return Err(StravaUploadError::Unauthorized(
                    StravaUnauthorizedStage::Upload,
                ));
            }
            _ => {}
        }
        let status = response.status();
        let body = read_bounded_body(&mut response, cancellation).await?;
        let text = String::from_utf8_lossy(&body);
        if is_duplicate_upload_response(&text) {
            let json = serde_json::from_slice::<serde_json::Value>(&body).ok();
            let remote_id = json
                .as_ref()
                .and_then(|value| json_numeric_id(value.get("activity_id")))
                .or_else(|| parse_duplicate_activity_id(&text));
            return Ok(StravaUploadResult::duplicate(remote_id));
        }
        if !status.is_success() {
            let mut redacted = text.replace(access_token, "<redacted>");
            for value in [external_id, filename].into_iter().chain(description) {
                if !value.is_empty() {
                    redacted = redacted.replace(value, "<redacted>");
                }
            }
            let detail = truncate_chars(&cleaned_upload_message(&redacted), 200);
            return Err(StravaUploadError::UploadFailed(format!(
                "上传失败 HTTP {}: {detail}",
                status.as_u16()
            )));
        }
        let json: serde_json::Value = serde_json::from_slice(&body)
            .map_err(|_| StravaUploadError::UploadFailed("Strava 未返回上传 ID".to_owned()))?;
        if let Some(activity_id) = json_numeric_id(json.get("activity_id")) {
            return Ok(StravaUploadResult::success(activity_id));
        }
        let upload_id = json_upload_id(json.get("id"))
            .ok_or_else(|| StravaUploadError::UploadFailed("Strava 未返回上传 ID".to_owned()))?;
        self.poll_upload(
            access_token,
            upload_id,
            0,
            false,
            cancellation,
            auth_retry_used,
        )
        .await
    }

    pub async fn resume_poll_after_refresh(
        &self,
        access_token: &str,
        resume: StravaPollResume,
        cancellation: &StravaCancellation,
    ) -> Result<StravaUploadResult, StravaUploadError> {
        let access_token = valid_upload_input("access_token", access_token)?;
        if resume.upload_id.trim().is_empty() || resume.upload_id.len() > MAX_RESPONSE_BYTES {
            return Err(StravaUploadError::InvalidInput("upload_id"));
        }
        if resume.attempt_index >= self.poll_delays.len() {
            return Err(StravaUploadError::InvalidInput("poll_attempt"));
        }
        self.poll_upload(
            access_token,
            resume.upload_id,
            resume.attempt_index,
            true,
            cancellation,
            true,
        )
        .await
    }

    async fn poll_upload(
        &self,
        access_token: &str,
        upload_id: String,
        start_attempt: usize,
        skip_first_delay: bool,
        cancellation: &StravaCancellation,
        auth_retry_used: bool,
    ) -> Result<StravaUploadResult, StravaUploadError> {
        let mut url = self.uploads_endpoint.clone();
        url.path_segments_mut()
            .map_err(|_| StravaUploadError::InvalidResponse)?
            .pop_if_empty()
            .push(&upload_id);
        for attempt_index in start_attempt..self.poll_delays.len() {
            let delay = self.poll_delays[attempt_index];
            if !(skip_first_delay && attempt_index == start_attempt) && !delay.is_zero() {
                cancellation.run(tokio::time::sleep(delay)).await?;
            }
            let request = self
                .client
                .get(url.clone())
                .timeout(POLL_REQUEST_TIMEOUT)
                .bearer_auth(access_token)
                .send();
            let response = cancellation.run(request).await?;
            let Ok(mut response) = response else { continue };
            match response.status() {
                StatusCode::TOO_MANY_REQUESTS => return Err(StravaUploadError::RateLimited),
                StatusCode::UNAUTHORIZED if auth_retry_used => {
                    return Err(StravaUploadError::UnauthorizedAfterRefresh);
                }
                StatusCode::UNAUTHORIZED => {
                    return Err(StravaUploadError::Unauthorized(
                        StravaUnauthorizedStage::Poll(StravaPollResume::new(
                            upload_id,
                            attempt_index,
                        )),
                    ));
                }
                StatusCode::OK => {}
                _ => continue,
            }
            let Ok(body) = read_bounded_body(&mut response, cancellation).await else {
                if cancellation.is_cancelled() {
                    return Err(StravaUploadError::Cancelled);
                }
                continue;
            };
            let Ok(json) = serde_json::from_slice::<serde_json::Value>(&body) else {
                continue;
            };
            if let Some(error) = json.get("error").and_then(serde_json::Value::as_str)
                && !error.is_empty()
            {
                if is_duplicate_upload_response(error) {
                    let remote_id = json_numeric_id(json.get("activity_id"))
                        .or_else(|| parse_duplicate_activity_id(error));
                    return Ok(StravaUploadResult::duplicate(remote_id));
                }
                let redacted = error
                    .replace(access_token, "<redacted>")
                    .replace(&upload_id, "<redacted>");
                let detail = truncate_chars(&cleaned_upload_message(&redacted), 200);
                return Err(StravaUploadError::UploadFailed(detail));
            }
            if let Some(activity_id) = json_numeric_id(json.get("activity_id")) {
                return Ok(StravaUploadResult::success(activity_id));
            }
        }
        Err(StravaUploadError::UploadFailed(
            "Strava 处理超时，尚未确认活动是否创建，请稍后重试".to_owned(),
        ))
    }
}

async fn read_bounded_body(
    response: &mut Response,
    cancellation: &StravaCancellation,
) -> Result<Vec<u8>, StravaUploadError> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
    {
        return Err(StravaUploadError::ResponseTooLarge);
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
            .map_err(|_| StravaUploadError::Transport)?;
        let Some(chunk) = chunk else { break };
        if body.len().saturating_add(chunk.len()) > MAX_RESPONSE_BYTES {
            return Err(StravaUploadError::ResponseTooLarge);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn valid_upload_input<'a>(
    name: &'static str,
    value: &'a str,
) -> Result<&'a str, StravaUploadError> {
    let value = value.trim();
    if value.is_empty() || value.len() > MAX_INPUT_BYTES || value.contains(['\0', '\r', '\n']) {
        return Err(StravaUploadError::InvalidInput(name));
    }
    Ok(value)
}

fn json_numeric_id(value: Option<&serde_json::Value>) -> Option<String> {
    let text = match value? {
        serde_json::Value::String(value) => value.trim().to_owned(),
        serde_json::Value::Number(value) => value.to_string(),
        _ => return None,
    };
    (!text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit())).then_some(text)
}

fn json_upload_id(value: Option<&serde_json::Value>) -> Option<String> {
    let text = match value? {
        serde_json::Value::String(value) => value.trim().to_owned(),
        serde_json::Value::Number(value) if value.is_i64() || value.is_u64() => value.to_string(),
        _ => return None,
    };
    (!text.is_empty()).then_some(text)
}

fn is_duplicate_upload_response(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    parse_duplicate_activity_id(text).is_some()
        || lower.contains("duplicate of activity")
        || lower.find("duplicate of").is_some_and(|index| {
            lower[index + "duplicate of".len()..]
                .trim_start()
                .starts_with("<a")
        })
}

pub fn parse_duplicate_activity_id(text: &str) -> Option<String> {
    let lower = text.to_ascii_lowercase();
    if let Some(index) = lower.find("duplicate of activity") {
        let id: String = text[index + "duplicate of activity".len()..]
            .trim_start()
            .chars()
            .take_while(char::is_ascii_digit)
            .collect();
        if !id.is_empty() {
            return Some(id);
        }
    }
    if !lower.contains("duplicate") {
        return None;
    }
    let index = lower.find("/activities/")? + "/activities/".len();
    let id: String = text[index..]
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    (!id.is_empty()).then_some(id)
}

pub fn cleaned_upload_message(raw: &str) -> String {
    if raw.to_ascii_lowercase().contains("the file is empty") {
        return "上传文件为空，Strava 无法处理".to_owned();
    }
    let mut cleaned = String::with_capacity(raw.len());
    let mut in_tag = false;
    for character in raw.replace("&nbsp;", " ").chars() {
        match character {
            '<' => in_tag = true,
            '>' if in_tag => in_tag = false,
            _ if !in_tag => cleaned.push(character),
            _ => {}
        }
    }
    cleaned.trim().to_owned()
}

fn truncate_chars(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StravaUploadResult {
    remote_id: Option<String>,
    is_duplicate: bool,
}

impl StravaUploadResult {
    fn success(remote_id: String) -> Self {
        Self {
            remote_id: Some(remote_id),
            is_duplicate: false,
        }
    }

    fn duplicate(remote_id: Option<String>) -> Self {
        Self {
            remote_id,
            is_duplicate: true,
        }
    }

    pub fn remote_id(&self) -> Option<&str> {
        self.remote_id.as_deref()
    }

    pub const fn is_duplicate(&self) -> bool {
        self.is_duplicate
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StravaPollResume {
    upload_id: String,
    attempt_index: usize,
}

impl StravaPollResume {
    pub fn new(upload_id: String, attempt_index: usize) -> Self {
        Self {
            upload_id,
            attempt_index,
        }
    }

    pub fn upload_id(&self) -> &str {
        &self.upload_id
    }

    pub const fn attempt_index(&self) -> usize {
        self.attempt_index
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StravaUnauthorizedStage {
    Upload,
    Poll(StravaPollResume),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StravaUploadError {
    InvalidInput(&'static str),
    ClientBuild,
    Transport,
    Unauthorized(StravaUnauthorizedStage),
    UnauthorizedAfterRefresh,
    RateLimited,
    ResponseTooLarge,
    InvalidResponse,
    UploadFailed(String),
    Cancelled,
}

impl fmt::Display for StravaUploadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidInput(name) => write!(formatter, "invalid {name}"),
            Self::ClientBuild => formatter.write_str("failed to create HTTPS client"),
            Self::Transport => formatter.write_str("Strava request failed"),
            Self::Unauthorized(_) => formatter.write_str("Strava 未授权，需要强制刷新"),
            Self::UnauthorizedAfterRefresh => formatter.write_str("Strava 强制刷新后仍未授权"),
            Self::RateLimited => formatter.write_str("Strava 限速，请稍后重试"),
            Self::ResponseTooLarge => formatter.write_str("Strava response too large"),
            Self::InvalidResponse => formatter.write_str("invalid Strava upload response"),
            Self::UploadFailed(message) => formatter.write_str(message),
            Self::Cancelled => formatter.write_str("Strava 上传已取消"),
        }
    }
}

impl std::error::Error for StravaUploadError {}

fn valid_input<'a>(name: &'static str, value: &'a str) -> Result<&'a str, StravaTokenError> {
    let value = value.trim();
    if value.is_empty() || value.len() > MAX_INPUT_BYTES {
        return Err(StravaTokenError::InvalidInput(name));
    }
    Ok(value)
}

#[derive(Clone, PartialEq)]
pub struct StravaToken {
    access_token: String,
    refresh_token: String,
    expires_at: f64,
}

impl StravaToken {
    fn parse(body: &[u8]) -> Result<Self, StravaTokenError> {
        let raw: TokenResponse =
            serde_json::from_slice(body).map_err(|_| StravaTokenError::InvalidResponse)?;
        if !raw.token_type.eq_ignore_ascii_case("bearer")
            || valid_response_value(&raw.access_token).is_none()
            || valid_response_value(&raw.refresh_token).is_none()
            || raw.expires_at <= 0.0
            || raw.expires_in.is_some_and(|seconds| seconds <= 0.0)
        {
            return Err(StravaTokenError::InvalidResponse);
        }
        Ok(Self {
            access_token: raw.access_token,
            refresh_token: raw.refresh_token,
            expires_at: raw.expires_at,
        })
    }

    pub fn access_token(&self) -> &str {
        &self.access_token
    }

    pub fn refresh_token(&self) -> &str {
        &self.refresh_token
    }

    pub const fn expires_at(&self) -> f64 {
        self.expires_at
    }
}

impl fmt::Debug for StravaToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("StravaToken")
            .field("access_token", &"<redacted>")
            .field("refresh_token", &"<redacted>")
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

fn valid_response_value(value: &str) -> Option<&str> {
    (!value.trim().is_empty() && value.len() <= MAX_INPUT_BYTES).then_some(value)
}

#[derive(Deserialize)]
struct TokenResponse {
    token_type: String,
    expires_at: f64,
    #[serde(default)]
    expires_in: Option<f64>,
    refresh_token: String,
    access_token: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StravaTokenError {
    InvalidInput(&'static str),
    ClientBuild,
    Transport,
    Unauthorized,
    HttpStatus(u16),
    ResponseTooLarge,
    InvalidResponse,
}

impl fmt::Display for StravaTokenError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidInput(name) => write!(formatter, "invalid {name}"),
            Self::ClientBuild => formatter.write_str("failed to create HTTPS client"),
            Self::Transport => formatter.write_str("token request failed"),
            Self::Unauthorized => formatter.write_str("Strava authorization failed"),
            Self::HttpStatus(status) => write!(formatter, "Strava token HTTP {status}"),
            Self::ResponseTooLarge => formatter.write_str("Strava token response too large"),
            Self::InvalidResponse => formatter.write_str("invalid Strava token response"),
        }
    }
}

impl std::error::Error for StravaTokenError {}

#[cfg(test)]
mod tests {
    use super::{
        StravaActivityError, StravaCancellation, StravaPollResume, StravaTokenClient,
        StravaTokenError, StravaUnauthorizedStage, StravaUploadClient, StravaUploadError,
        UPLOAD_POLL_DELAYS_SECONDS, activity_status, cleaned_upload_message, fixed_strava_url,
        parse_activity_speed, parse_duplicate_activity_id, parse_remote_activity,
    };
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::{
            Arc,
            atomic::{AtomicBool, AtomicUsize, Ordering},
        },
        thread,
        time::Duration,
    };

    fn mock_token_server(
        status: u16,
        response_body: String,
    ) -> (String, thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = Vec::new();
            let mut buffer = [0_u8; 1024];
            let header_end = loop {
                let read = stream.read(&mut buffer).unwrap();
                assert_ne!(read, 0, "请求头不完整");
                request.extend_from_slice(&buffer[..read]);
                if let Some(index) = request.windows(4).position(|window| window == b"\r\n\r\n") {
                    break index + 4;
                }
            };
            let headers = String::from_utf8_lossy(&request[..header_end]);
            let content_length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().unwrap())
                })
                .unwrap();
            while request.len() < header_end + content_length {
                let read = stream.read(&mut buffer).unwrap();
                assert_ne!(read, 0, "请求体不完整");
                request.extend_from_slice(&buffer[..read]);
            }
            let _ = write!(
                stream,
                "HTTP/1.1 {status} Mock\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response_body}",
                response_body.len()
            );
            String::from_utf8(request).unwrap()
        });
        (format!("http://{address}/oauth/token"), handle)
    }

    struct CapturedRequest {
        head: String,
        body: Vec<u8>,
    }

    fn mock_upload_server(
        responses: Vec<(u16, &'static str)>,
    ) -> (String, thread::JoinHandle<Vec<CapturedRequest>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            responses
                .into_iter()
                .map(|(status, response_body)| {
                    let (mut stream, _) = listener.accept().unwrap();
                    let mut request = Vec::new();
                    let mut buffer = [0_u8; 4096];
                    let header_end = loop {
                        let read = stream.read(&mut buffer).unwrap();
                        assert_ne!(read, 0, "请求头不完整");
                        request.extend_from_slice(&buffer[..read]);
                        if let Some(index) =
                            request.windows(4).position(|window| window == b"\r\n\r\n")
                        {
                            break index + 4;
                        }
                    };
                    let head = String::from_utf8(request[..header_end].to_vec()).unwrap();
                    let content_length = head
                        .lines()
                        .find_map(|line| {
                            let (name, value) = line.split_once(':')?;
                            name.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    while request.len() < header_end + content_length {
                        let read = stream.read(&mut buffer).unwrap();
                        assert_ne!(read, 0, "请求体不完整");
                        request.extend_from_slice(&buffer[..read]);
                    }
                    let _ = write!(
                        stream,
                        "HTTP/1.1 {status} Mock\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response_body}",
                        response_body.len()
                    );
                    CapturedRequest {
                        head,
                        body: request[header_end..header_end + content_length].to_vec(),
                    }
                })
                .collect()
        });
        (format!("http://{address}/api/v3/uploads"), handle)
    }

    fn read_request(stream: &mut std::net::TcpStream) -> CapturedRequest {
        let mut request = Vec::new();
        let mut buffer = [0_u8; 4096];
        let header_end = loop {
            let read = stream.read(&mut buffer).unwrap();
            assert_ne!(read, 0, "请求头不完整");
            request.extend_from_slice(&buffer[..read]);
            if let Some(index) = request.windows(4).position(|window| window == b"\r\n\r\n") {
                break index + 4;
            }
        };
        let head = String::from_utf8(request[..header_end].to_vec()).unwrap();
        let content_length = head
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().unwrap())
            })
            .unwrap_or(0);
        while request.len() < header_end + content_length {
            let read = stream.read(&mut buffer).unwrap();
            assert_ne!(read, 0, "请求体不完整");
            request.extend_from_slice(&buffer[..read]);
        }
        CapturedRequest {
            head,
            body: request[header_end..header_end + content_length].to_vec(),
        }
    }

    fn mock_counting_upload_server() -> (
        String,
        Arc<AtomicUsize>,
        Arc<AtomicBool>,
        thread::JoinHandle<()>,
    ) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        let request_count = Arc::new(AtomicUsize::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let thread_count = Arc::clone(&request_count);
        let thread_stop = Arc::clone(&stop);
        let handle = thread::spawn(move || {
            while !thread_stop.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        let _ = read_request(&mut stream);
                        let index = thread_count.fetch_add(1, Ordering::AcqRel);
                        let body = if index == 0 {
                            r#"{"id":"cancel-job"}"#
                        } else {
                            r#"{"activity_id":null}"#
                        };
                        let _ = write!(
                            stream,
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        );
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2));
                    }
                    Err(error) => panic!("监听失败: {error}"),
                }
            }
        });
        (
            format!("http://{address}/api/v3/uploads"),
            request_count,
            stop,
            handle,
        )
    }

    #[tokio::test]
    async fn exchanges_code_with_encoded_form_and_strict_token_response() {
        let body = r#"{"token_type":"Bearer","expires_at":2000000000.5,"expires_in":21600,"refresh_token":"refresh-value","access_token":"access-value","athlete":{"id":1}}"#.to_owned();
        let (endpoint, server) = mock_token_server(200, body);
        let client = StravaTokenClient::for_test(endpoint).unwrap();

        let token = client
            .exchange_code("id with space", "secret&=+%", "code/?&")
            .await
            .unwrap();

        assert_eq!(token.access_token(), "access-value");
        assert_eq!(token.refresh_token(), "refresh-value");
        assert_eq!(token.expires_at(), 2_000_000_000.5);
        let request = server.join().unwrap();
        assert!(request.starts_with("POST /oauth/token HTTP/1.1\r\n"));
        assert!(request.contains("content-type: application/x-www-form-urlencoded"));
        assert!(request.contains("client_id=id+with+space"));
        assert!(request.contains("client_secret=secret%26%3D%2B%25"));
        assert!(request.contains("code=code%2F%3F%26"));
        assert!(request.contains("grant_type=authorization_code"));
    }

    #[tokio::test]
    async fn refreshes_rotated_token_over_local_mock_http() {
        let body = r#"{"token_type":"bearer","expires_at":2000000001,"refresh_token":"rotated-refresh","access_token":"rotated-access"}"#.to_owned();
        let (endpoint, server) = mock_token_server(200, body);
        let client = StravaTokenClient::for_test(endpoint).unwrap();

        let token = client
            .refresh("123", "client-secret", "old-refresh")
            .await
            .unwrap();

        assert_eq!(token.refresh_token(), "rotated-refresh");
        let request = server.join().unwrap();
        assert!(request.contains("refresh_token=old-refresh"));
        assert!(request.contains("grant_type=refresh_token"));
    }

    #[tokio::test]
    async fn rejects_invalid_status_and_malformed_or_oversized_responses() {
        for (status, body, expected) in [
            (401, "{}".to_owned(), StravaTokenError::Unauthorized),
            (
                200,
                r#"{"token_type":"Bearer","expires_at":-1.0,"refresh_token":"r","access_token":"a"}"#.to_owned(),
                StravaTokenError::InvalidResponse,
            ),
            (
                200,
                r#"{"token_type":"Bearer","expires_at":1,"refresh_token":"","access_token":"a"}"#.to_owned(),
                StravaTokenError::InvalidResponse,
            ),
            (200, "x".repeat(65_537), StravaTokenError::ResponseTooLarge),
        ] {
            let (endpoint, server) = mock_token_server(status, body);
            let client = StravaTokenClient::for_test(endpoint).unwrap();
            assert_eq!(
                client
                    .refresh("id", "secret", "refresh")
                    .await
                    .unwrap_err(),
                expected
            );
            server.join().unwrap();
        }
    }

    #[tokio::test]
    async fn rejects_empty_inputs_and_redacts_token_debug_output() {
        let client = StravaTokenClient::new().unwrap();
        assert_eq!(
            client
                .exchange_code("", "secret", "code")
                .await
                .unwrap_err(),
            StravaTokenError::InvalidInput("client_id")
        );

        let body = r#"{"token_type":"Bearer","expires_at":2000000000,"refresh_token":"refresh-secret","access_token":"access-secret"}"#.to_owned();
        let (endpoint, server) = mock_token_server(200, body);
        let token = StravaTokenClient::for_test(endpoint)
            .unwrap()
            .refresh("id", "client-secret", "refresh")
            .await
            .unwrap();
        server.join().unwrap();
        let debug = format!("{token:?}");
        assert!(!debug.contains("access-secret"));
        assert!(!debug.contains("refresh-secret"));
    }

    #[tokio::test]
    async fn uploads_safe_multipart_then_polls_until_duplicate() {
        let (endpoint, server) = mock_upload_server(vec![
            (201, r#"{"id":77}"#),
            (200, r#"{"activity_id":"<null>"}"#),
            (503, "temporary"),
            (
                200,
                r#"{"activity_id":999,"error":"Ride.fit duplicate of <a href='/activities/12345'>same</a>"}"#,
            ),
        ]);
        let client = StravaUploadClient::for_test(endpoint, 1024).unwrap();

        let result = client
            .upload_fit(
                "test-access",
                vec![0x0E, 0x2E, 0x46, 0x49, 0x54],
                "external-id",
                "source-activity\".fit",
                true,
                Some("virtual power"),
            )
            .await
            .unwrap();

        assert!(result.is_duplicate());
        assert_eq!(result.remote_id(), Some("999"));
        let requests = server.join().unwrap();
        assert_eq!(requests.len(), 4);
        assert!(
            requests[0]
                .head
                .starts_with("POST /api/v3/uploads HTTP/1.1\r\n")
        );
        assert!(
            requests[0]
                .head
                .contains("authorization: Bearer test-access\r\n")
        );
        assert!(
            requests[0]
                .head
                .contains("content-type: multipart/form-data; boundary=")
        );
        let body = String::from_utf8_lossy(&requests[0].body);
        assert!(body.contains("name=\"data_type\"\r\n\r\nfit"));
        assert!(body.contains("name=\"external_id\"\r\n\r\nexternal-id"));
        assert!(body.contains("name=\"commute\"\r\n\r\n1"));
        assert!(body.contains("name=\"description\"\r\n\r\nvirtual power"));
        assert!(body.contains("filename=\"source-activity\\\".fit\""));
        assert!(!body.contains("\r\nX-Evil:"));
        assert!(
            requests[0]
                .body
                .windows(5)
                .any(|window| window == [0x0E, 0x2E, 0x46, 0x49, 0x54])
        );
        assert!(
            requests[1]
                .head
                .starts_with("GET /api/v3/uploads/77 HTTP/1.1\r\n")
        );
        assert!(
            requests[3]
                .head
                .starts_with("GET /api/v3/uploads/77 HTTP/1.1\r\n")
        );
    }

    #[tokio::test]
    async fn maps_immediate_success_duplicate_and_hard_upload_failures() {
        let cases = [
            (200, r#"{"activity_id":456}"#, Ok((Some("456"), false))),
            (409, "duplicate of activity 789", Ok((Some("789"), true))),
            (
                409,
                r#"{"activity_id":999,"error":"duplicate of activity 789"}"#,
                Ok((Some("999"), true)),
            ),
            (
                400,
                "Malformed <strong>FIT</strong>&nbsp; access-secret",
                Err(StravaUploadError::UploadFailed(
                    "上传失败 HTTP 400: Malformed FIT".to_owned(),
                )),
            ),
            (429, "limited", Err(StravaUploadError::RateLimited)),
            (
                401,
                "expired",
                Err(StravaUploadError::Unauthorized(
                    StravaUnauthorizedStage::Upload,
                )),
            ),
        ];
        for (status, body, expected) in cases {
            let (endpoint, server) = mock_upload_server(vec![(status, body)]);
            let client = StravaUploadClient::for_test(endpoint, 1024).unwrap();
            let actual = client
                .upload_fit(
                    "access-secret",
                    vec![1],
                    "external",
                    "ride.fit",
                    false,
                    None,
                )
                .await;
            match expected {
                Ok((remote_id, duplicate)) => {
                    let result = actual.unwrap();
                    assert_eq!(result.remote_id(), remote_id);
                    assert_eq!(result.is_duplicate(), duplicate);
                }
                Err(error) => assert_eq!(actual.unwrap_err(), error),
            }
            server.join().unwrap();
        }
    }

    #[tokio::test]
    async fn polls_exact_budget_then_times_out_without_using_upload_id_as_activity_id() {
        let mut responses = vec![(201, r#"{"id":"88"}"#)];
        responses.extend([
            (200, r#"{"activity_id":null}"#),
            (200, r#"{"activity_id":"null"}"#),
            (200, r#"{"activity_id":"<null>"}"#),
            (200, r#"{"activity_id":""}"#),
            (200, r#"{"activity_id":"unknown"}"#),
            (200, "not-json"),
            (500, "temporary"),
        ]);
        let (endpoint, server) = mock_upload_server(responses);
        let client = StravaUploadClient::for_test(endpoint, 1024).unwrap();

        assert_eq!(
            client
                .upload_fit("token", vec![1], "external", "ride.fit", false, None)
                .await
                .unwrap_err(),
            StravaUploadError::UploadFailed(
                "Strava 处理超时，尚未确认活动是否创建，请稍后重试".to_owned()
            )
        );
        let requests = server.join().unwrap();
        assert_eq!(requests.len(), 1 + UPLOAD_POLL_DELAYS_SECONDS.len());
        assert!(requests[1..].iter().all(|request| {
            request
                .head
                .starts_with("GET /api/v3/uploads/88 HTTP/1.1\r\n")
        }));
    }

    #[tokio::test]
    async fn maps_poll_hard_error_rate_limit_and_unauthorized() {
        for (status, body, expected) in [
            (
                200,
                r#"{"error":"Malformed <strong>FIT</strong> file"}"#,
                StravaUploadError::UploadFailed("Malformed FIT file".to_owned()),
            ),
            (429, "{}", StravaUploadError::RateLimited),
            (
                401,
                "{}",
                StravaUploadError::Unauthorized(StravaUnauthorizedStage::Poll(
                    StravaPollResume::new("88".to_owned(), 0),
                )),
            ),
        ] {
            let (endpoint, server) =
                mock_upload_server(vec![(201, r#"{"id":88}"#), (status, body)]);
            let client = StravaUploadClient::for_test(endpoint, 1024).unwrap();
            assert_eq!(
                client
                    .upload_fit("token", vec![1], "external", "ride.fit", false, None)
                    .await
                    .unwrap_err(),
                expected
            );
            assert_eq!(server.join().unwrap().len(), 2);
        }
    }

    #[tokio::test]
    async fn validates_upload_boundary_and_matches_cleaning_contract() {
        assert_eq!(UPLOAD_POLL_DELAYS_SECONDS, [0, 1, 2, 4, 8, 16, 32]);
        assert_eq!(
            cleaned_upload_message("The FILE is EMPTY <b>secret</b>"),
            "上传文件为空，Strava 无法处理"
        );
        assert_eq!(
            cleaned_upload_message("Malformed <b>FIT</b>&nbsp; file"),
            "Malformed FIT  file"
        );
        assert_eq!(
            parse_duplicate_activity_id("DUPLICATE OF ACTIVITY 42"),
            Some("42".to_owned())
        );
        assert_eq!(
            parse_duplicate_activity_id("duplicate of <a href=\"/activities/99\">x</a>"),
            Some("99".to_owned())
        );
        assert_eq!(
            parse_duplicate_activity_id("duplicate result: /activities/100"),
            Some("100".to_owned())
        );

        let client = StravaUploadClient::new().unwrap();
        for (fit, token, external_id, filename, expected) in [
            (vec![], "token", "external", "ride.fit", "fit"),
            (vec![1], "", "external", "ride.fit", "access_token"),
            (vec![1], "token", "", "ride.fit", "external_id"),
            (vec![1], "token", "external", "../ride.fit", "filename"),
        ] {
            assert_eq!(
                client
                    .upload_fit(token, fit, external_id, filename, false, None)
                    .await
                    .unwrap_err(),
                StravaUploadError::InvalidInput(expected)
            );
        }
        let (endpoint, server) = mock_upload_server(vec![]);
        let client = StravaUploadClient::for_test(endpoint, 1).unwrap();
        assert_eq!(
            client
                .upload_fit("token", vec![1, 2], "external", "ride.fit", false, None)
                .await
                .unwrap_err(),
            StravaUploadError::InvalidInput("fit")
        );
        assert!(server.join().unwrap().is_empty());
    }

    #[tokio::test]
    async fn accepts_non_numeric_upload_id_and_encodes_it_as_one_path_segment() {
        let (endpoint, server) = mock_upload_server(vec![
            (201, r#"{"id":"job/with space?"}"#),
            (200, r#"{"activity_id":321}"#),
        ]);
        let client = StravaUploadClient::for_test(endpoint, 1024).unwrap();

        let result = client
            .upload_fit("token", vec![1], "external", "ride.fit", false, None)
            .await
            .unwrap();

        assert_eq!(result.remote_id(), Some("321"));
        let requests = server.join().unwrap();
        assert!(
            requests[1]
                .head
                .starts_with("GET /api/v3/uploads/job%2Fwith%20space%3F HTTP/1.1\r\n")
        );
    }

    #[tokio::test]
    async fn exposes_typed_post_and_poll_refresh_stages_and_stops_after_second_401() {
        let (endpoint, server) = mock_upload_server(vec![(401, "{}")]);
        let client = StravaUploadClient::for_test(endpoint, 1024).unwrap();
        assert_eq!(
            client
                .upload_fit("old", vec![1], "external", "ride.fit", false, None)
                .await
                .unwrap_err(),
            StravaUploadError::Unauthorized(StravaUnauthorizedStage::Upload)
        );
        server.join().unwrap();

        let (endpoint, server) = mock_upload_server(vec![(401, "{}")]);
        let client = StravaUploadClient::for_test(endpoint, 1024).unwrap();
        assert_eq!(
            client
                .retry_upload_after_refresh(
                    "new",
                    vec![1],
                    "external",
                    "ride.fit",
                    false,
                    None,
                    &StravaCancellation::new(),
                )
                .await
                .unwrap_err(),
            StravaUploadError::UnauthorizedAfterRefresh
        );
        server.join().unwrap();

        let (endpoint, server) =
            mock_upload_server(vec![(201, r#"{"id":"job"}"#), (401, "{}"), (401, "{}")]);
        let client = StravaUploadClient::for_test(endpoint, 1024).unwrap();
        let error = client
            .upload_fit("old", vec![1], "external", "ride.fit", false, None)
            .await
            .unwrap_err();
        let StravaUploadError::Unauthorized(StravaUnauthorizedStage::Poll(resume)) = error else {
            panic!("应返回 poll 恢复点")
        };
        assert_eq!(resume, StravaPollResume::new("job".to_owned(), 0));
        assert_eq!(
            client
                .resume_poll_after_refresh("new", resume, &StravaCancellation::new())
                .await
                .unwrap_err(),
            StravaUploadError::UnauthorizedAfterRefresh
        );
        assert_eq!(server.join().unwrap().len(), 3);
    }

    #[tokio::test]
    async fn omits_optional_multipart_fields_and_rejects_ascii_controls() {
        let (endpoint, server) = mock_upload_server(vec![(200, r#"{"activity_id":1}"#)]);
        let client = StravaUploadClient::for_test(endpoint, 1024).unwrap();
        client
            .upload_fit("token", vec![1], "external", "ride.fit", false, None)
            .await
            .unwrap();
        let request = server.join().unwrap().remove(0);
        let body = String::from_utf8_lossy(&request.body);
        assert!(!body.contains("name=\"commute\""));
        assert!(!body.contains("name=\"description\""));

        let client = StravaUploadClient::new().unwrap();
        for control in (0_u8..=31).chain(std::iter::once(127)) {
            let filename = format!("ride{}.fit", char::from(control));
            assert_eq!(
                client
                    .upload_fit("token", vec![1], "external", &filename, false, None)
                    .await
                    .unwrap_err(),
                StravaUploadError::InvalidInput("filename")
            );
            let description = format!("virtual{}power", char::from(control));
            assert_eq!(
                client
                    .upload_fit(
                        "token",
                        vec![1],
                        "external",
                        "ride.fit",
                        false,
                        Some(&description),
                    )
                    .await
                    .unwrap_err(),
                StravaUploadError::InvalidInput("description")
            );
        }
    }

    #[tokio::test]
    async fn cancellation_during_poll_wait_stops_future_requests() {
        let (endpoint, request_count, stop, server) = mock_counting_upload_server();
        let mut client = StravaUploadClient::for_test(endpoint, 1024).unwrap();
        client.poll_delays = [
            Duration::ZERO,
            Duration::from_secs(5),
            Duration::from_secs(5),
            Duration::from_secs(5),
            Duration::from_secs(5),
            Duration::from_secs(5),
            Duration::from_secs(5),
        ];
        let cancellation = StravaCancellation::new();
        let task_cancellation = cancellation.clone();
        let task = tokio::spawn(async move {
            client
                .upload_fit_cancellable(
                    "token",
                    vec![1],
                    "external",
                    "ride.fit",
                    false,
                    None,
                    &task_cancellation,
                )
                .await
        });
        for _ in 0..100 {
            if request_count.load(Ordering::Acquire) >= 2 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert_eq!(request_count.load(Ordering::Acquire), 2);
        cancellation.cancel();
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), task)
                .await
                .unwrap()
                .unwrap()
                .unwrap_err(),
            StravaUploadError::Cancelled
        );
        let count_after_cancel = request_count.load(Ordering::Acquire);
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(request_count.load(Ordering::Acquire), count_after_cancel);
        stop.store(true, Ordering::Release);
        server.join().unwrap();
    }

    #[tokio::test]
    async fn rejects_chunked_upload_response_larger_than_boundary() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let _ = read_request(&mut stream);
            let oversized = vec![b'x'; super::MAX_RESPONSE_BYTES + 1];
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:X}\r\n",
                oversized.len()
            )
            .unwrap();
            stream.write_all(&oversized).unwrap();
            stream.write_all(b"\r\n0\r\n\r\n").unwrap();
        });
        let client =
            StravaUploadClient::for_test(format!("http://{address}/api/v3/uploads"), 1024).unwrap();

        assert_eq!(
            client
                .upload_fit("token", vec![1], "external", "ride.fit", false, None)
                .await
                .unwrap_err(),
            StravaUploadError::ResponseTooLarge
        );
        server.join().unwrap();
    }

    #[tokio::test]
    async fn truncates_cleaned_poll_error_to_200_characters() {
        let body: &'static str =
            Box::leak(format!(r#"{{"error":"<b>{}</b>"}}"#, "x".repeat(220)).into_boxed_str());
        let (endpoint, server) = mock_upload_server(vec![(201, r#"{"id":1}"#), (200, body)]);
        let client = StravaUploadClient::for_test(endpoint, 1024).unwrap();

        assert_eq!(
            client
                .upload_fit("token", vec![1], "external", "ride.fit", false, None)
                .await
                .unwrap_err(),
            StravaUploadError::UploadFailed("x".repeat(200))
        );
        server.join().unwrap();
    }

    #[test]
    fn remote_list_parser_keeps_swift_interval_and_distance_contract() {
        let activity = parse_remote_activity(&serde_json::json!({
            "id": 19643161379_u64,
            "start_date": "2024-02-03T04:05:06.500Z",
            "elapsed_time": 5400,
            "distance": "12040.5"
        }))
        .unwrap();
        assert_eq!(activity.id, "19643161379");
        assert_eq!(activity.start_time_seconds, 1_706_933_106.5);
        assert_eq!(activity.end_time_seconds, 1_706_938_506.5);
        assert_eq!(activity.distance_meters, Some(12_040.5));

        // 缺时长无法做区间重叠，沿用 Swift 的“宁可漏判，不误判”策略。
        assert!(
            parse_remote_activity(&serde_json::json!({
                "id": "9", "start_date": "2024-02-03T04:05:06Z", "elapsed_time": 0
            }))
            .is_none()
        );
        // 路径参数只接受数字 ID，避免把任意片段带入 URL。
        assert!(
            parse_remote_activity(&serde_json::json!({
                "id": "9/streams", "start_date": "2024-02-03T04:05:06Z", "elapsed_time": 1
            }))
            .is_none()
        );
    }

    #[test]
    fn remote_speed_parser_matches_summary_and_best_effort_semantics() {
        let info = parse_activity_speed(
            "42",
            &serde_json::json!({
                "name": "晨骑",
                "start_date": "2024-02-03T04:05:06Z",
                "sport_type": "Ride",
                "max_speed": 18.0,
                "average_speed": "7.5",
                "best_efforts": [
                    {"distance": 100, "elapsed_time": 1},
                    {"distance": 400, "elapsed_time": 20},
                    {"distance": 1000, "moving_time": 100}
                ]
            }),
        )
        .unwrap();
        assert_eq!(info.name, "晨骑");
        assert_eq!(info.sport_type, "Ride");
        assert_eq!(info.listed_max_speed_mps, 18.0);
        assert_eq!(info.best_effort_peak_mps, 20.0);
        assert_eq!(info.max_speed_mps, 20.0);
        assert_eq!(info.average_speed_mps, 7.5);

        let fallback =
            parse_activity_speed("42", &serde_json::json!({"name": "bad\nname"})).unwrap();
        assert_eq!(fallback.name, "活动 42");
    }

    #[test]
    fn remote_read_status_and_fixed_host_are_safely_constrained() {
        assert_eq!(activity_status(reqwest::StatusCode::OK, false), Ok(true));
        assert_eq!(
            activity_status(reqwest::StatusCode::CREATED, false),
            Ok(true)
        );
        assert_eq!(
            activity_status(reqwest::StatusCode::NOT_FOUND, true),
            Ok(false)
        );
        assert_eq!(
            activity_status(reqwest::StatusCode::TOO_MANY_REQUESTS, false),
            Err(StravaActivityError::RateLimited)
        );
        assert_eq!(
            activity_status(reqwest::StatusCode::UNAUTHORIZED, false),
            Err(StravaActivityError::Unauthorized)
        );
        assert!(fixed_strava_url("https://www.strava.com/api/v3/activities/").is_ok());
        assert!(fixed_strava_url("http://www.strava.com/api/v3/activities/").is_err());
        assert!(fixed_strava_url("https://example.com/api/v3/activities/").is_err());
    }
}
