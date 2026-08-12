//! 行者网页登录。此模块不保存账号、密码或 sessionid，也不会把它们放进错误文本。

use base64::{Engine, engine::general_purpose::STANDARD};
use rand::rngs::OsRng;
use reqwest::{
    Client, Response, StatusCode, Url,
    header::{CONTENT_TYPE, HeaderMap, HeaderValue, ORIGIN, REFERER, SET_COOKIE, USER_AGENT},
    redirect::Policy,
};
use rsa::{Pkcs1v15Encrypt, RsaPublicKey, pkcs8::DecodePublicKey};
use serde::Serialize;
use std::{
    fmt,
    future::Future,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::sync::Notify;

const LOGIN_URL: &str = "https://www.imxingzhe.com/api/v1/user/login/";
const LIST_URL: &str = "https://www.imxingzhe.com/api/v1/pgworkout/";
const ORIGIN_VALUE: &str = "https://www.imxingzhe.com";
const REFERER_VALUE: &str = "https://www.imxingzhe.com/user/login";
const USER_AGENT_VALUE: &str =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15";
const PUBLIC_KEY_PEM: &str = "-----BEGIN PUBLIC KEY-----\nMIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDmuQkBbijudDAJgfffDeeIButq\nWHZvUwcRuvWdg89393FSdz3IJUHc0rgI/S3WuU8N0VePJLmVAZtCOK4qe4FY/eKm\nWpJmn7JfXB4HTMWjPVoyRZmSYjW4L8GrWmh51Qj7DwpTADadF3aq04o+s1b8LXJa\n8r6+TIqqL5WUHtRqmQIDAQAB\n-----END PUBLIC KEY-----";
const MAX_ACCOUNT_BYTES: usize = 256;
const MAX_PASSWORD_BYTES: usize = 117; // 1024-bit RSA PKCS#1 v1.5 的明文上限。
const MAX_RESPONSE_BYTES: usize = 64 * 1024;
const MAX_LIST_RESPONSE_BYTES: usize = 2 * 1024 * 1024;
const MAX_SESSION_ID_BYTES: usize = 4 * 1024;
const LIST_PAGE_SIZE: u32 = 24;
const MAX_LIST_OFFSET: u32 = 5_000;
const MAX_LIST_PAGES: u32 = MAX_LIST_OFFSET.div_ceil(LIST_PAGE_SIZE);
const MAX_REQUEST_ATTEMPTS: u32 = 8;
const PAGE_INTERVAL: Duration = Duration::from_millis(1_200);
const RATE_LIMIT_PADDING: Duration = Duration::from_millis(350);

/// 不含敏感字段的登录失败分类。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum XingzheLoginError {
    InvalidInput,
    PublicKey,
    Encryption,
    ClientBuild,
    Transport,
    RedirectBlocked,
    Unauthorized,
    HttpStatus(u16),
    ResponseTooLarge,
    InvalidResponse,
    SessionMissing,
}

impl fmt::Display for XingzheLoginError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidInput => "行者登录参数无效",
            Self::PublicKey | Self::Encryption => "行者密码加密失败",
            Self::ClientBuild => "行者网络客户端初始化失败",
            Self::Transport => "行者网络请求失败",
            Self::RedirectBlocked => "行者登录重定向不受信任",
            Self::Unauthorized => "行者账号或密码错误",
            Self::HttpStatus(_) => "行者登录失败",
            Self::ResponseTooLarge => "行者登录响应过大",
            Self::InvalidResponse => "行者登录响应无效",
            Self::SessionMissing => "行者未返回 sessionid",
        };
        f.write_str(message)
    }
}

impl std::error::Error for XingzheLoginError {}

/// 只读活动列表失败分类；永远不包含 `sessionid` 或服务器原始响应。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum XingzheActivityError {
    InvalidInput,
    ClientBuild,
    Transport,
    RedirectBlocked,
    Unauthorized,
    HttpStatus(u16),
    ResponseTooLarge,
    InvalidResponse,
    RateLimited,
    Cancelled,
}

impl fmt::Display for XingzheActivityError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidInput => "行者活动请求参数无效",
            Self::ClientBuild => "行者活动客户端初始化失败",
            Self::Transport => "行者活动网络请求失败",
            Self::RedirectBlocked => "行者活动重定向不受信任",
            Self::Unauthorized => "行者登录已失效",
            Self::HttpStatus(_) => "行者活动请求失败",
            Self::ResponseTooLarge => "行者活动响应过大",
            Self::InvalidResponse => "行者活动响应无效",
            Self::RateLimited => "行者请求限流，请稍后再试",
            Self::Cancelled => "行者活动请求已取消",
        };
        f.write_str(message)
    }
}

impl std::error::Error for XingzheActivityError {}

/// 由 FFI 操作句柄持有的取消信号；网络、读流、限流等待与分页间隔都可立即退出。
#[derive(Clone, Default)]
pub struct XingzheCancellation {
    cancelled: Arc<AtomicBool>,
    notify: Arc<Notify>,
}

impl XingzheCancellation {
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

    async fn run<F: Future>(&self, future: F) -> Result<F::Output, XingzheActivityError> {
        tokio::select! {
            biased;
            _ = self.cancelled() => Err(XingzheActivityError::Cancelled),
            output = future => Ok(output),
        }
    }

    async fn sleep(&self, duration: Duration) -> Result<(), XingzheActivityError> {
        self.run(tokio::time::sleep(duration)).await
    }
}

/// 行者活动列表的最小跨端传输模型；时间均为 Unix 秒。
#[derive(Clone, Debug, PartialEq)]
pub struct XingzheWorkout {
    pub id: String,
    pub title: String,
    pub start_time_seconds: f64,
    pub end_time_seconds: f64,
    pub duration_seconds: f64,
    pub distance_meters: Option<f64>,
}

/// 固定 HTTPS 网页会话活动端点。`sessionid` 只用于此处构造的请求，且所有重定向都被拒绝。
#[derive(Clone)]
pub struct XingzheActivityClient {
    client: Client,
    list_endpoint: Url,
}

impl XingzheActivityClient {
    pub fn new() -> Result<Self, XingzheActivityError> {
        let client = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(Policy::none())
            .user_agent("HealthWorkoutExport/1")
            .build()
            .map_err(|_| XingzheActivityError::ClientBuild)?;
        Ok(Self {
            client,
            list_endpoint: fixed_list_url()?,
        })
    }

    /// 与旧 Swift 相同：按 offset 每页 24 条，半开时间区间 `[from, to)` 过滤。
    pub async fn list_workouts(
        &self,
        session_id: &str,
        from_seconds: i64,
        to_seconds: i64,
        cancellation: &XingzheCancellation,
    ) -> Result<Vec<XingzheWorkout>, XingzheActivityError> {
        validate_list_input(session_id, from_seconds, to_seconds)?;
        let mut results = Vec::new();

        for page in 0..MAX_LIST_PAGES {
            if cancellation.is_cancelled() {
                return Err(XingzheActivityError::Cancelled);
            }
            if page > 0 {
                cancellation.sleep(PAGE_INTERVAL).await?;
            }
            let offset = page * LIST_PAGE_SIZE;
            let root = self.get_page(session_id, offset, cancellation).await?;
            let (mut entries, all_older, entry_count) =
                parse_workout_page(&root, from_seconds, to_seconds);
            results.append(&mut entries);
            // 列表按新到旧；整页都早于起点或不足一页时，后续不可能再命中。
            if all_older || entry_count < LIST_PAGE_SIZE as usize {
                break;
            }
        }
        results.sort_by(|left, right| right.start_time_seconds.total_cmp(&left.start_time_seconds));
        Ok(results)
    }

    async fn get_page(
        &self,
        session_id: &str,
        offset: u32,
        cancellation: &XingzheCancellation,
    ) -> Result<serde_json::Value, XingzheActivityError> {
        for attempt in 0..MAX_REQUEST_ATTEMPTS {
            let mut url = self.list_endpoint.clone();
            url.query_pairs_mut()
                .append_pair("offset", &offset.to_string())
                .append_pair("limit", &LIST_PAGE_SIZE.to_string());
            let cookie = format!("sessionid={session_id}; _XingzheWeb_Token=true");
            let mut response = match cancellation
                .run(
                    self.client
                        .get(url)
                        .header("Cookie", cookie)
                        .header("Accept", "application/json")
                        .send(),
                )
                .await
            {
                Ok(Ok(response)) => response,
                Ok(Err(_)) if attempt + 1 < MAX_REQUEST_ATTEMPTS => {
                    cancellation.sleep(PAGE_INTERVAL).await?;
                    continue;
                }
                Ok(Err(_)) => return Err(XingzheActivityError::Transport),
                Err(error) => return Err(error),
            };
            if response.status().is_redirection() {
                return Err(XingzheActivityError::RedirectBlocked);
            }
            match response.status() {
                StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
                    return Err(XingzheActivityError::Unauthorized);
                }
                _ => {}
            }
            let body = read_list_limited(&mut response, cancellation).await?;
            let body_text = std::str::from_utf8(&body).unwrap_or_default();
            if let Some(wait) = rate_limit_wait(response.status(), body_text) {
                if attempt + 1 == MAX_REQUEST_ATTEMPTS {
                    return Err(XingzheActivityError::RateLimited);
                }
                cancellation.sleep(wait + RATE_LIMIT_PADDING).await?;
                continue;
            }
            if !response.status().is_success() {
                return Err(XingzheActivityError::HttpStatus(response.status().as_u16()));
            }
            let root = serde_json::from_slice::<serde_json::Value>(&body)
                .map_err(|_| XingzheActivityError::InvalidResponse)?;
            if let Some(code) = root.get("code").and_then(serde_json::Value::as_i64)
                && code != 0
                && code != 200
            {
                let message = root
                    .get("msg")
                    .or_else(|| root.get("message"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or(body_text);
                if let Some(wait) = rate_limit_wait(
                    StatusCode::from_u16(code as u16).unwrap_or(StatusCode::OK),
                    message,
                ) {
                    if attempt + 1 == MAX_REQUEST_ATTEMPTS {
                        return Err(XingzheActivityError::RateLimited);
                    }
                    cancellation.sleep(wait + RATE_LIMIT_PADDING).await?;
                    continue;
                }
                if data_is_empty(&root) {
                    return Err(XingzheActivityError::InvalidResponse);
                }
            }
            return Ok(root);
        }
        Err(XingzheActivityError::RateLimited)
    }
}

fn fixed_list_url() -> Result<Url, XingzheActivityError> {
    let url = Url::parse(LIST_URL).map_err(|_| XingzheActivityError::ClientBuild)?;
    (url.scheme() == "https"
        && url.host_str() == Some("www.imxingzhe.com")
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none())
    .then_some(url)
    .ok_or(XingzheActivityError::ClientBuild)
}

fn validate_list_input(
    session_id: &str,
    from_seconds: i64,
    to_seconds: i64,
) -> Result<(), XingzheActivityError> {
    (session_id.len() <= MAX_SESSION_ID_BYTES
        && is_safe_cookie_value(session_id)
        && from_seconds >= 0
        && to_seconds > from_seconds)
        .then_some(())
        .ok_or(XingzheActivityError::InvalidInput)
}

async fn read_list_limited(
    response: &mut Response,
    cancellation: &XingzheCancellation,
) -> Result<Vec<u8>, XingzheActivityError> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_LIST_RESPONSE_BYTES as u64)
    {
        return Err(XingzheActivityError::ResponseTooLarge);
    }
    let mut body = Vec::with_capacity(
        response
            .content_length()
            .unwrap_or_default()
            .min(MAX_LIST_RESPONSE_BYTES as u64) as usize,
    );
    loop {
        let chunk = cancellation
            .run(response.chunk())
            .await
            .map_err(|_| XingzheActivityError::Cancelled)?
            .map_err(|_| XingzheActivityError::Transport)?;
        let Some(chunk) = chunk else { break };
        if body.len().saturating_add(chunk.len()) > MAX_LIST_RESPONSE_BYTES {
            return Err(XingzheActivityError::ResponseTooLarge);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn rate_limit_wait(status: StatusCode, body: &str) -> Option<Duration> {
    let lower = body.to_ascii_lowercase();
    let limited = status == StatusCode::BAD_REQUEST
        || lower.contains("request limit")
        || lower.contains("limit exceeded");
    if !limited || !lower.contains("limit") {
        return None;
    }
    let seconds = lower
        .split("available in")
        .nth(1)
        .and_then(|tail| tail.split_whitespace().next())
        .and_then(|value| value.parse::<f64>().ok())
        .filter(|value| value.is_finite() && *value >= 0.0)
        .map(|value| value.max(1.0))
        .unwrap_or(1.5);
    Duration::try_from_secs_f64(seconds).ok()
}

fn data_is_empty(root: &serde_json::Value) -> bool {
    root.get("data").is_none_or(|data| match data {
        serde_json::Value::Array(values) => values.is_empty(),
        serde_json::Value::Object(values) => values.is_empty(),
        serde_json::Value::Null => true,
        _ => false,
    })
}

fn parse_workout_page(
    root: &serde_json::Value,
    from_seconds: i64,
    to_seconds: i64,
) -> (Vec<XingzheWorkout>, bool, usize) {
    let items = root
        .get("data")
        .and_then(|data| data.get("data").or(Some(data)))
        .and_then(serde_json::Value::as_array);
    let Some(items) = items else {
        return (Vec::new(), true, 0);
    };
    let mut workouts = Vec::new();
    let mut all_older = true;
    for item in items {
        let Some(id) = json_id(item.get("id")) else {
            continue;
        };
        let Some(start_milliseconds) = json_number(item.get("start_time")) else {
            continue;
        };
        let start_time_seconds = start_milliseconds / 1_000.0;
        if !start_time_seconds.is_finite() || start_time_seconds <= 0.0 {
            continue;
        }
        if start_time_seconds >= from_seconds as f64 {
            all_older = false;
        }
        if start_time_seconds < from_seconds as f64 || start_time_seconds >= to_seconds as f64 {
            continue;
        }
        let duration_seconds = json_number(item.get("duration"))
            .filter(|value| value.is_finite())
            .unwrap_or(0.0)
            .max(1.0);
        let distance_meters =
            json_number(item.get("distance")).filter(|value| value.is_finite() && *value > 0.0);
        let title = item
            .get("title")
            .and_then(serde_json::Value::as_str)
            .filter(|title| !title.is_empty())
            .unwrap_or("行者运动")
            .to_owned();
        workouts.push(XingzheWorkout {
            id,
            title,
            start_time_seconds,
            end_time_seconds: start_time_seconds + duration_seconds,
            duration_seconds,
            distance_meters,
        });
    }
    (workouts, all_older, items.len())
}

fn json_id(value: Option<&serde_json::Value>) -> Option<String> {
    match value? {
        serde_json::Value::String(value) if !value.is_empty() => Some(value.clone()),
        serde_json::Value::Number(value) => Some(value.to_string()),
        _ => None,
    }
}

fn json_number(value: Option<&serde_json::Value>) -> Option<f64> {
    match value? {
        serde_json::Value::Number(value) => value.as_f64(),
        serde_json::Value::String(value) => value.parse().ok(),
        _ => None,
    }
}

#[derive(Clone)]
pub struct XingzheLoginClient {
    client: Client,
    endpoint: String,
}

#[derive(Serialize)]
struct LoginPayload<'a> {
    account: &'a str,
    password: String,
}

impl XingzheLoginClient {
    /// 使用固定 HTTPS 端点，且完全禁用重定向，避免凭据被带往其他域。
    pub fn new() -> Result<Self, XingzheLoginError> {
        Self::with_endpoint(LOGIN_URL.to_owned())
    }

    fn with_endpoint(endpoint: String) -> Result<Self, XingzheLoginError> {
        let client = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(Policy::none())
            .build()
            .map_err(|_| XingzheLoginError::ClientBuild)?;
        Ok(Self { client, endpoint })
    }

    pub async fn login(&self, account: &str, password: &str) -> Result<String, XingzheLoginError> {
        validate_input(account, password)?;
        let password = encrypt_password(password)?;
        let payload = serde_json::to_vec(&LoginPayload { account, password })
            .map_err(|_| XingzheLoginError::InvalidInput)?;
        let mut response = self
            .client
            .post(&self.endpoint)
            .header(CONTENT_TYPE, HeaderValue::from_static("application/json"))
            .header(USER_AGENT, HeaderValue::from_static(USER_AGENT_VALUE))
            .header(ORIGIN, HeaderValue::from_static(ORIGIN_VALUE))
            .header(REFERER, HeaderValue::from_static(REFERER_VALUE))
            .body(payload)
            .send()
            .await
            .map_err(|_| XingzheLoginError::Transport)?;

        if response.status().is_redirection() {
            return Err(XingzheLoginError::RedirectBlocked);
        }
        match response.status() {
            StatusCode::OK => {}
            StatusCode::BAD_REQUEST | StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
                return Err(XingzheLoginError::Unauthorized);
            }
            status => return Err(XingzheLoginError::HttpStatus(status.as_u16())),
        }

        let session_id =
            extract_session_id(response.headers()).ok_or(XingzheLoginError::SessionMissing)?;
        let body = read_limited(&mut response).await?;
        let json: serde_json::Value =
            serde_json::from_slice(&body).map_err(|_| XingzheLoginError::InvalidResponse)?;
        if json.get("data").is_none() {
            return Err(XingzheLoginError::Unauthorized);
        }
        Ok(session_id)
    }
}

fn validate_input(account: &str, password: &str) -> Result<(), XingzheLoginError> {
    if account.trim().is_empty()
        || account.len() > MAX_ACCOUNT_BYTES
        || password.is_empty()
        || password.len() > MAX_PASSWORD_BYTES
    {
        return Err(XingzheLoginError::InvalidInput);
    }
    Ok(())
}

fn encrypt_password(password: &str) -> Result<String, XingzheLoginError> {
    let public_key = RsaPublicKey::from_public_key_pem(PUBLIC_KEY_PEM)
        .map_err(|_| XingzheLoginError::PublicKey)?;
    let mut rng = OsRng;
    let encrypted = public_key
        .encrypt(&mut rng, Pkcs1v15Encrypt, password.as_bytes())
        .map_err(|_| XingzheLoginError::Encryption)?;
    Ok(STANDARD.encode(encrypted))
}

/// 只接受单个 `Set-Cookie` 中首项严格名为 `sessionid` 的可安全转发 Cookie 值。
fn extract_session_id(headers: &HeaderMap) -> Option<String> {
    headers.get_all(SET_COOKIE).iter().find_map(|header| {
        let raw = header.to_str().ok()?;
        let (name, value) = raw.split(';').next()?.trim().split_once('=')?;
        (name == "sessionid" && is_safe_cookie_value(value)).then(|| value.to_owned())
    })
}

fn is_safe_cookie_value(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_graphic() && !matches!(byte, b'"' | b',' | b';' | b'\\'))
}

async fn read_limited(response: &mut Response) -> Result<Vec<u8>, XingzheLoginError> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
    {
        return Err(XingzheLoginError::ResponseTooLarge);
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
        .map_err(|_| XingzheLoginError::Transport)?
    {
        if body.len().saturating_add(chunk.len()) > MAX_RESPONSE_BYTES {
            return Err(XingzheLoginError::ResponseTooLarge);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::{
        MAX_ACCOUNT_BYTES, MAX_PASSWORD_BYTES, XingzheActivityError, XingzheCancellation,
        XingzheLoginError, encrypt_password, extract_session_id, fixed_list_url,
        parse_workout_page, rate_limit_wait, validate_input, validate_list_input,
    };
    use reqwest::StatusCode;
    use reqwest::header::{HeaderMap, HeaderValue, SET_COOKIE};
    use std::time::Duration;

    #[test]
    fn rsa_pkcs1v15_ciphertext_is_base64_and_never_plaintext() {
        let password = "not-a-logged-secret";
        let ciphertext = encrypt_password(password).unwrap();
        let bytes = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &ciphertext)
            .unwrap();
        assert_eq!(bytes.len(), 128);
        assert_ne!(bytes, password.as_bytes());
    }

    #[test]
    fn only_accepts_a_strict_sessionid_cookie() {
        let mut headers = HeaderMap::new();
        headers.append(SET_COOKIE, HeaderValue::from_static("csrf=ok; Path=/"));
        headers.append(
            SET_COOKIE,
            HeaderValue::from_static("sessionid=abc_123=; HttpOnly; Secure"),
        );
        assert_eq!(extract_session_id(&headers), Some("abc_123=".to_owned()));

        for value in [
            "sessionid = abc; Path=/",
            "Sessionid=abc; Path=/",
            "sessionid=abc, csrf=ok; Path=/",
        ] {
            let mut malformed = HeaderMap::new();
            malformed.append(SET_COOKIE, HeaderValue::from_str(value).unwrap());
            assert_eq!(extract_session_id(&malformed), None, "{value}");
        }
    }

    #[test]
    fn credential_limits_are_fixed() {
        assert_eq!(
            validate_input("", "password"),
            Err(XingzheLoginError::InvalidInput)
        );
        assert_eq!(
            validate_input(&"a".repeat(MAX_ACCOUNT_BYTES + 1), "password"),
            Err(XingzheLoginError::InvalidInput)
        );
        assert_eq!(
            validate_input("account", &"p".repeat(MAX_PASSWORD_BYTES + 1)),
            Err(XingzheLoginError::InvalidInput)
        );
    }

    #[test]
    fn list_input_only_accepts_safe_session_and_half_open_window() {
        assert!(validate_list_input("safe_session=123", 1, 2).is_ok());
        assert_eq!(
            validate_list_input("safe; injected", 1, 2),
            Err(XingzheActivityError::InvalidInput)
        );
        assert_eq!(
            validate_list_input("safe", 2, 2),
            Err(XingzheActivityError::InvalidInput)
        );
        let url = fixed_list_url().unwrap();
        assert_eq!(url.scheme(), "https");
        assert_eq!(url.host_str(), Some("www.imxingzhe.com"));
        assert!(url.port().is_none());
    }

    #[test]
    fn list_page_uses_half_open_dates_and_swift_defaults() {
        let root = serde_json::json!({
            "data": {"data": [
                {"id": 1, "title": "命中", "start_time": 2_000, "duration": 0, "distance": 0},
                {"id": "start", "start_time": 1_000, "duration": 10, "distance": 120},
                {"id": "end", "start_time": 3_000, "duration": 10, "distance": 120}
            ]}
        });
        let (workouts, all_older, count) = parse_workout_page(&root, 2, 3);
        assert_eq!(count, 3);
        assert!(!all_older);
        assert_eq!(workouts.len(), 1);
        assert_eq!(workouts[0].id, "1");
        assert_eq!(workouts[0].duration_seconds, 1.0);
        assert_eq!(workouts[0].distance_meters, None);
    }

    #[test]
    fn rate_limit_uses_server_seconds_or_swift_fallback() {
        assert_eq!(
            rate_limit_wait(
                StatusCode::BAD_REQUEST,
                "request limit exceeded, available in 3 seconds"
            ),
            Some(Duration::from_secs(3))
        );
        assert_eq!(
            rate_limit_wait(
                StatusCode::TOO_MANY_REQUESTS,
                "request limit exceeded, available in 2 seconds"
            ),
            Some(Duration::from_secs(2))
        );
        assert_eq!(
            rate_limit_wait(StatusCode::BAD_REQUEST, "limit exceeded"),
            Some(Duration::from_millis(1_500))
        );
        assert_eq!(
            rate_limit_wait(StatusCode::INTERNAL_SERVER_ERROR, "error"),
            None
        );
    }

    #[tokio::test]
    async fn cancellation_interrupts_waiting_immediately() {
        let cancellation = XingzheCancellation::new();
        cancellation.cancel();
        assert_eq!(
            cancellation.sleep(Duration::from_secs(60)).await,
            Err(XingzheActivityError::Cancelled)
        );
    }
}
