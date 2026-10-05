//! 顽鹿网页登录。凭据仅用于一次请求，错误文本不会包含账号、密码、签名或令牌。

use md5::{Digest, Md5};
use rand::{Rng, distributions::Alphanumeric};
use reqwest::{
    Client, Response, StatusCode, Url,
    header::{CONTENT_TYPE, HeaderValue, ORIGIN, USER_AGENT},
    redirect::Policy,
};
use serde::Serialize;
use serde_json::Value;
use std::{
    fmt,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use time::{PrimitiveDateTime, UtcOffset, format_description};

const LOGIN_URL: &str = "https://www.onelap.cn/api/login";
const REFRESH_URL: &str = "https://otm.onelap.cn/api/token";
const ORIGIN_VALUE: &str = "https://www.onelap.cn";
const USER_AGENT_VALUE: &str = "Mozilla/5.0";
const SIGNING_SECRET: &str = "fe9f8382418fcdeb136461cac6acae7b";
const MAX_ACCOUNT_BYTES: usize = 256;
const MAX_PASSWORD_BYTES: usize = 1024;
const MAX_RESPONSE_BYTES: usize = 64 * 1024;
const MAX_TOKEN_BYTES: usize = 4096;
const MAX_UID_BYTES: usize = 256;
const RIDE_BASE_URL: &str = "https://otm.onelap.cn/api/otm/ride_record/";
const MAX_ACTIVITY_RESPONSE_BYTES: usize = 2 * 1024 * 1024;
const LIST_PAGE_SIZE: u32 = 20;
const MAX_LIST_PAGES: u32 = 500;

/// 不含敏感字段的顽鹿登录失败分类。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OnelapLoginError {
    InvalidInput,
    Clock,
    ClientBuild,
    UntrustedEndpoint,
    Transport,
    RedirectBlocked,
    Unauthorized,
    SessionExpired,
    HttpStatus(u16),
    ResponseTooLarge,
    InvalidResponse,
}

impl fmt::Display for OnelapLoginError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidInput => "顽鹿登录参数无效",
            Self::Clock => "顽鹿登录时间不可用",
            Self::ClientBuild => "顽鹿网络客户端初始化失败",
            Self::UntrustedEndpoint | Self::RedirectBlocked => "顽鹿登录端点不受信任",
            Self::Transport => "顽鹿登录网络请求失败",
            Self::Unauthorized => "顽鹿账号或密码错误",
            Self::SessionExpired => "顽鹿登录已失效",
            Self::HttpStatus(_) => "顽鹿登录失败",
            Self::ResponseTooLarge => "顽鹿登录响应过大",
            Self::InvalidResponse => "顽鹿登录响应无效",
        };
        f.write_str(message)
    }
}

impl std::error::Error for OnelapLoginError {}

/// 顽鹿活动/FIT 读取失败分类；不会回显 token、uid、下载 URL 或远端响应。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OnelapActivityError {
    InvalidInput,
    ClientBuild,
    Transport,
    RedirectBlocked,
    Unauthorized,
    HttpStatus(u16),
    ResponseTooLarge,
    InvalidResponse,
    FitMissing,
    InvalidFit,
}

impl fmt::Display for OnelapActivityError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidInput => "顽鹿活动请求参数无效",
            Self::ClientBuild => "顽鹿活动客户端初始化失败",
            Self::Transport => "顽鹿活动网络请求失败",
            Self::RedirectBlocked => "顽鹿活动重定向不受信任",
            Self::Unauthorized => "顽鹿登录已失效",
            Self::HttpStatus(_) => "顽鹿活动请求失败",
            Self::ResponseTooLarge => "顽鹿活动响应过大",
            Self::InvalidResponse => "顽鹿活动响应无效",
            Self::FitMissing => "该顽鹿活动没有 FIT 文件",
            Self::InvalidFit => "顽鹿未返回有效 FIT 文件",
        };
        f.write_str(message)
    }
}

impl std::error::Error for OnelapActivityError {}

/// 顽鹿骑行列表的最小跨端传输模型；时间均为 Unix 秒。
#[derive(Clone, Debug, PartialEq)]
pub struct OnelapRide {
    pub id: String,
    /// Original validated server wall time, for platform historical timezone resolution.
    pub start_time_local: String,
    pub start_time_seconds: f64,
    pub end_time_seconds: f64,
    pub duration_seconds: f64,
    pub distance_meters: Option<f64>,
}

/// 固定顽鹿业务端点的只读客户端。token 只会发送到 `*.onelap.cn` HTTPS 主机。
#[derive(Clone)]
pub struct OnelapActivityClient {
    client: Client,
    ride_base: Url,
}

impl OnelapActivityClient {
    pub fn new() -> Result<Self, OnelapActivityError> {
        let client = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(Policy::none())
            .user_agent(USER_AGENT_VALUE)
            .build()
            .map_err(|_| OnelapActivityError::ClientBuild)?;
        let ride_base = Url::parse(RIDE_BASE_URL).map_err(|_| OnelapActivityError::ClientBuild)?;
        if !is_trusted_onelap_https_url(&ride_base) {
            return Err(OnelapActivityError::ClientBuild);
        }
        Ok(Self { client, ride_base })
    }

    /// 与旧 Swift 相同：每页 20 条、最多 500 页，按传入时区解析列表中的无时区时间。
    pub async fn list_rides(
        &self,
        token: &str,
        uid: &str,
        from_seconds: i64,
        to_seconds: i64,
        timezone_offset_seconds: i32,
    ) -> Result<Vec<OnelapRide>, OnelapActivityError> {
        validate_activity_input(
            token,
            uid,
            from_seconds,
            to_seconds,
            timezone_offset_seconds,
        )?;
        let mut rides = Vec::new();
        for page in 1..=MAX_LIST_PAGES {
            let root = self
                .post_json(
                    token,
                    uid,
                    "list",
                    serde_json::json!({"page": page, "limit": LIST_PAGE_SIZE}),
                )
                .await?;
            let data = checked_data(&root)?;
            let (mut page_rides, older_than_start, count) =
                parse_ride_page(data, from_seconds, to_seconds, timezone_offset_seconds);
            rides.append(&mut page_rides);
            let has_more = data
                .get("pagination")
                .and_then(|pagination| pagination.get("has_more"))
                .and_then(Value::as_bool)
                .unwrap_or(false);
            if older_than_start || !has_more || count == 0 {
                break;
            }
        }
        rides.sort_by(|left, right| right.start_time_seconds.total_cmp(&left.start_time_seconds));
        Ok(rides)
    }

    /// 读取详情中的候选地址，逐一在禁用重定向和受限响应下拉取，返回内容质量最佳的 FIT。
    pub async fn download_best_fit(
        &self,
        token: &str,
        uid: &str,
        activity_id: &str,
    ) -> Result<Vec<u8>, OnelapActivityError> {
        validate_fit_input(token, uid, activity_id)?;
        let detail_path = format!("analysis/{activity_id}");
        let detail = self.get_json(token, uid, &detail_path).await?;
        let record = checked_data(&detail)?
            .get("ridingRecord")
            .and_then(Value::as_object)
            .ok_or(OnelapActivityError::InvalidResponse)?;
        let candidates = self.fit_candidates(activity_id, record);
        if candidates.is_empty() {
            return Err(OnelapActivityError::FitMissing);
        }
        let mut best = None;
        let mut best_score = 0;
        let mut last_error = OnelapActivityError::InvalidFit;
        for candidate in candidates {
            let data = match self.fetch_fit_candidate(token, uid, &candidate).await {
                Ok(data) => data,
                Err(error) => {
                    last_error = error;
                    continue;
                }
            };
            let Ok(summary) = crate::fit::decode_fit(&data) else {
                continue;
            };
            let score = summary.quality_score();
            if best.is_none() || score > best_score {
                best_score = score;
                best = Some(data);
            }
            if summary.gps_point_count >= 30 && summary.heart_rate_point_count >= 10 {
                break;
            }
        }
        best.ok_or(last_error)
    }

    fn fit_candidates(
        &self,
        activity_id: &str,
        record: &serde_json::Map<String, Value>,
    ) -> Vec<Url> {
        let mut candidates = Vec::new();
        for key in ["durl", "fit_url", "fitUrl", "fileKey"] {
            let Some(raw) = record.get(key).and_then(json_string) else {
                continue;
            };
            let Ok(url) = Url::parse(raw) else { continue };
            // 保留 Swift 的 CDN 直链能力，但仅接受无凭证的 HTTPS 绝对 URL；向外域永不发送会话。
            if is_safe_public_fit_url(&url) && !candidates.contains(&url) {
                candidates.push(url);
            }
        }
        if let Ok(url) = self.ride_url(&format!("analysis/fit_content/{activity_id}")) {
            candidates.push(url);
        }
        if let Some(file_key) = record.get("fileKey").and_then(json_string)
            && !file_key.is_empty()
        {
            let encoded =
                base64::Engine::encode(&base64::engine::general_purpose::STANDARD, file_key);
            if let Ok(mut url) = self.ride_url("analysis/fit_content") {
                if let Ok(mut path) = url.path_segments_mut() {
                    path.pop_if_empty().push(&encoded);
                }
                candidates.push(url);
            }
        }
        candidates
    }

    async fn fetch_fit_candidate(
        &self,
        token: &str,
        uid: &str,
        url: &Url,
    ) -> Result<Vec<u8>, OnelapActivityError> {
        let mut response = self
            .client
            .get(url.clone())
            .send()
            .await
            .map_err(|_| OnelapActivityError::Transport)?;
        if response.status().is_redirection() {
            return Err(OnelapActivityError::RedirectBlocked);
        }
        if response.status().is_success() {
            return read_activity_limited(&mut response, crate::fit::MAX_FIT_BYTES).await;
        }
        if !is_trusted_onelap_https_url(url) {
            return Err(OnelapActivityError::HttpStatus(response.status().as_u16()));
        }
        response = self
            .authorized(token, uid, self.client.get(url.clone()))?
            .send()
            .await
            .map_err(|_| OnelapActivityError::Transport)?;
        if response.status().is_redirection() {
            return Err(OnelapActivityError::RedirectBlocked);
        }
        if response.status() == StatusCode::UNAUTHORIZED
            || response.status() == StatusCode::FORBIDDEN
        {
            return Err(OnelapActivityError::Unauthorized);
        }
        if !response.status().is_success() {
            return Err(OnelapActivityError::HttpStatus(response.status().as_u16()));
        }
        read_activity_limited(&mut response, crate::fit::MAX_FIT_BYTES).await
    }

    async fn post_json(
        &self,
        token: &str,
        uid: &str,
        path: &str,
        body: Value,
    ) -> Result<Value, OnelapActivityError> {
        let url = self.ride_url(path)?;
        let body = serde_json::to_vec(&body).map_err(|_| OnelapActivityError::InvalidInput)?;
        let request = self
            .authorized(token, uid, self.client.post(url))?
            .header(CONTENT_TYPE, HeaderValue::from_static("application/json"))
            .body(body);
        self.read_json(request).await
    }

    async fn get_json(
        &self,
        token: &str,
        uid: &str,
        path: &str,
    ) -> Result<Value, OnelapActivityError> {
        self.read_json(self.authorized(token, uid, self.client.get(self.ride_url(path)?))?)
            .await
    }

    async fn read_json(
        &self,
        request: reqwest::RequestBuilder,
    ) -> Result<Value, OnelapActivityError> {
        let mut response = request
            .send()
            .await
            .map_err(|_| OnelapActivityError::Transport)?;
        if response.status().is_redirection() {
            return Err(OnelapActivityError::RedirectBlocked);
        }
        if response.status() == StatusCode::UNAUTHORIZED
            || response.status() == StatusCode::FORBIDDEN
        {
            return Err(OnelapActivityError::Unauthorized);
        }
        if !response.status().is_success() {
            return Err(OnelapActivityError::HttpStatus(response.status().as_u16()));
        }
        serde_json::from_slice(
            &read_activity_limited(&mut response, MAX_ACTIVITY_RESPONSE_BYTES).await?,
        )
        .map_err(|_| OnelapActivityError::InvalidResponse)
    }

    fn authorized(
        &self,
        token: &str,
        uid: &str,
        request: reqwest::RequestBuilder,
    ) -> Result<reqwest::RequestBuilder, OnelapActivityError> {
        let token = HeaderValue::from_str(token).map_err(|_| OnelapActivityError::InvalidInput)?;
        Ok(request
            .header("Authorization", token)
            .header("Cookie", format!("ouid={uid}")))
    }

    fn ride_url(&self, path: &str) -> Result<Url, OnelapActivityError> {
        if path.is_empty()
            || path
                .split('/')
                .any(|part| part.is_empty() || part == "." || part == "..")
        {
            return Err(OnelapActivityError::InvalidInput);
        }
        self.ride_base
            .join(path)
            .map_err(|_| OnelapActivityError::InvalidInput)
    }
}

/// 可由 Flutter 安全保存的短期顽鹿会话标识。
#[derive(Clone, PartialEq, Eq)]
pub struct OnelapSession {
    pub token: String,
    pub uid: String,
    pub refresh_token: Option<String>,
}

impl fmt::Debug for OnelapSession {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("OnelapSession")
            .field("token", &"<redacted>")
            .field("uid", &"<redacted>")
            .field("refresh_token", &"<redacted>")
            .finish()
    }
}

#[derive(Clone)]
pub struct OnelapLoginClient {
    client: Client,
    endpoint: Url,
    refresh_endpoint: Url,
}

#[derive(Serialize)]
struct LoginPayload<'a> {
    account: &'a str,
    password: String,
}

struct SignedLoginRequest {
    nonce: String,
    timestamp: String,
    sign: String,
    body: Vec<u8>,
}

impl OnelapLoginClient {
    /// 仅使用固定的官方 HTTPS 登录端点；所有重定向都被拒绝。
    pub fn new() -> Result<Self, OnelapLoginError> {
        Self::with_endpoint(LOGIN_URL)
    }

    fn with_endpoint(endpoint: &str) -> Result<Self, OnelapLoginError> {
        let endpoint = Url::parse(endpoint).map_err(|_| OnelapLoginError::UntrustedEndpoint)?;
        if !is_trusted_onelap_https_url(&endpoint) {
            return Err(OnelapLoginError::UntrustedEndpoint);
        }
        let client = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(Policy::none())
            .build()
            .map_err(|_| OnelapLoginError::ClientBuild)?;
        let refresh_endpoint =
            Url::parse(REFRESH_URL).map_err(|_| OnelapLoginError::ClientBuild)?;
        Ok(Self {
            client,
            endpoint,
            refresh_endpoint,
        })
    }

    pub async fn login(
        &self,
        account: &str,
        password: &str,
    ) -> Result<OnelapSession, OnelapLoginError> {
        let request = signed_login_request(account, password, random_nonce(), unix_timestamp()?)?;
        let mut response = self
            .client
            .post(self.endpoint.clone())
            .header(
                CONTENT_TYPE,
                HeaderValue::from_static("application/json;charset=utf-8"),
            )
            .header(USER_AGENT, HeaderValue::from_static(USER_AGENT_VALUE))
            .header(ORIGIN, HeaderValue::from_static(ORIGIN_VALUE))
            .header("nonce", request.nonce)
            .header("timestamp", request.timestamp)
            .header("sign", request.sign)
            .body(request.body)
            .send()
            .await
            .map_err(|_| OnelapLoginError::Transport)?;

        if response.status().is_redirection() {
            return Err(OnelapLoginError::RedirectBlocked);
        }
        match response.status() {
            StatusCode::OK => {}
            StatusCode::BAD_REQUEST | StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
                return Err(OnelapLoginError::Unauthorized);
            }
            status => return Err(OnelapLoginError::HttpStatus(status.as_u16())),
        }
        parse_login_response(&read_limited(&mut response).await?)
    }

    /// Swift-compatible refresh. Only the fixed official HTTPS token endpoint receives the
    /// refresh token; the caller atomically stores the returned rotated session in its vault.
    pub async fn refresh(
        &self,
        refresh_token: &str,
        uid: &str,
    ) -> Result<OnelapSession, OnelapLoginError> {
        if !is_safe_header_value(refresh_token, MAX_TOKEN_BYTES)
            || !is_safe_cookie_value(uid, MAX_UID_BYTES)
        {
            return Err(OnelapLoginError::InvalidInput);
        }
        let body = serde_json::to_vec(&serde_json::json!({
            "token": refresh_token, "from": "web", "to": "web",
        }))
        .map_err(|_| OnelapLoginError::InvalidInput)?;
        let mut response = self
            .client
            .post(self.refresh_endpoint.clone())
            .header(CONTENT_TYPE, HeaderValue::from_static("application/json"))
            .header(USER_AGENT, HeaderValue::from_static(USER_AGENT_VALUE))
            .body(body)
            .send()
            .await
            .map_err(|_| OnelapLoginError::Transport)?;
        if response.status().is_redirection() {
            return Err(OnelapLoginError::RedirectBlocked);
        }
        if matches!(
            response.status(),
            StatusCode::BAD_REQUEST | StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN
        ) {
            return Err(OnelapLoginError::SessionExpired);
        }
        if response.status() != StatusCode::OK {
            return Err(OnelapLoginError::HttpStatus(response.status().as_u16()));
        }
        parse_refreshed_session(&read_limited(&mut response).await?, uid, refresh_token)
    }
}

/// 只接受官方根域或其子域的 HTTPS URL；`onelap.cn.example` 不属于可信域。
pub fn is_trusted_onelap_https_url(url: &Url) -> bool {
    matches!(url.scheme(), "https")
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none()
        && url.host_str().is_some_and(|host| {
            let host = host.to_ascii_lowercase();
            host == "onelap.cn" || host.ends_with(".onelap.cn")
        })
}

/// CDN 直链不携带任何顽鹿凭证：仅允许无用户信息、默认端口的 HTTPS 绝对 URL。
fn is_safe_public_fit_url(url: &Url) -> bool {
    url.scheme() == "https"
        && url.host_str().is_some_and(is_public_fit_host)
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none()
}

/// CDN URLs are server supplied. Reject explicit local addresses and local-only names
/// before making even an unauthenticated request. Redirects remain disabled.
fn is_public_fit_host(host: &str) -> bool {
    use std::net::IpAddr;
    let host = host.trim_matches(['[', ']']).trim_end_matches('.');
    if let Ok(address) = host.parse::<IpAddr>() {
        let public_v4 = |address: std::net::Ipv4Addr| {
            let [a, b, _, _] = address.octets();
            !address.is_private()
                && !address.is_loopback()
                && !address.is_link_local()
                && !address.is_broadcast()
                && !address.is_documentation()
                && !address.is_multicast()
                && a != 0
                && a < 240
                && !(a == 100 && (64..=127).contains(&b))
                && !(a == 198 && (18..=19).contains(&b))
        };
        return match address {
            IpAddr::V4(address) => public_v4(address),
            IpAddr::V6(address) => {
                if let Some(mapped) = address.to_ipv4() {
                    return public_v4(mapped);
                }
                !address.is_loopback()
                    && !address.is_unspecified()
                    && !address.is_unique_local()
                    && !address.is_unicast_link_local()
                    && !address.is_multicast()
            }
        };
    }
    let host = host.to_ascii_lowercase();
    host.contains('.')
        && host != "localhost"
        && !host.ends_with(".localhost")
        && !host.ends_with(".local")
        && !host.ends_with(".internal")
}

fn validate_activity_input(
    token: &str,
    uid: &str,
    from_seconds: i64,
    to_seconds: i64,
    timezone_offset_seconds: i32,
) -> Result<(), OnelapActivityError> {
    (is_safe_header_value(token, MAX_TOKEN_BYTES)
        && is_safe_cookie_value(uid, MAX_UID_BYTES)
        && from_seconds >= 0
        && to_seconds > from_seconds
        && (-86_399..=86_399).contains(&timezone_offset_seconds)
        && UtcOffset::from_whole_seconds(timezone_offset_seconds).is_ok())
    .then_some(())
    .ok_or(OnelapActivityError::InvalidInput)
}

fn validate_fit_input(
    token: &str,
    uid: &str,
    activity_id: &str,
) -> Result<(), OnelapActivityError> {
    (is_safe_header_value(token, MAX_TOKEN_BYTES)
        && is_safe_cookie_value(uid, MAX_UID_BYTES)
        && !activity_id.is_empty()
        && !matches!(activity_id, "." | "..")
        && activity_id.len() <= 256
        && activity_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.')))
    .then_some(())
    .ok_or(OnelapActivityError::InvalidInput)
}

fn is_safe_header_value(value: &str, max_bytes: usize) -> bool {
    !value.is_empty()
        && value.len() <= max_bytes
        && value
            .bytes()
            .all(|byte| byte.is_ascii_graphic() && !matches!(byte, b'\r' | b'\n'))
}

fn is_safe_cookie_value(value: &str, max_bytes: usize) -> bool {
    !value.is_empty()
        && value.len() <= max_bytes
        && value
            .bytes()
            .all(|byte| byte.is_ascii_graphic() && !matches!(byte, b'"' | b',' | b';' | b'\\'))
}

fn checked_data(root: &Value) -> Result<&serde_json::Map<String, Value>, OnelapActivityError> {
    let code = root.get("code").and_then(json_i64);
    let message = root
        .get("msg")
        .or_else(|| root.get("message"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    if is_expired_session(code, message) {
        return Err(OnelapActivityError::Unauthorized);
    }
    if code != Some(200) {
        return Err(OnelapActivityError::InvalidResponse);
    }
    root.get("data")
        .and_then(Value::as_object)
        .ok_or(OnelapActivityError::InvalidResponse)
}

/// 与 Swift OnelapAuth 一致，HTTP 200 也可能承载失效会话。
fn is_expired_session(code: Option<i64>, message: &str) -> bool {
    if matches!(code, Some(401 | 403)) {
        return true;
    }
    let message = message.to_ascii_lowercase();
    [
        "未登录",
        "登录过期",
        "登录失效",
        "请重新登录",
        "重新登录",
        "token过期",
        "token失效",
        "token expired",
        "invalid token",
        "token invalid",
        "unauthorized",
    ]
    .iter()
    .any(|hint| message.contains(hint))
}

fn parse_ride_page(
    data: &serde_json::Map<String, Value>,
    from_seconds: i64,
    to_seconds: i64,
    timezone_offset_seconds: i32,
) -> (Vec<OnelapRide>, bool, usize) {
    let items = data.get("list").and_then(Value::as_array);
    let Some(items) = items else {
        return (Vec::new(), true, 0);
    };
    let offset = match UtcOffset::from_whole_seconds(timezone_offset_seconds) {
        Ok(offset) => offset,
        Err(_) => return (Vec::new(), true, items.len()),
    };
    let mut rides = Vec::new();
    let mut older_than_start = false;
    for item in items {
        let Some(id) = item
            .get("id")
            .or_else(|| item.get("activity_id"))
            .and_then(json_id)
        else {
            continue;
        };
        let Some(start_time_local) = item
            .get("start_riding_time")
            .or_else(|| item.get("startTime"))
            .and_then(json_string)
        else {
            continue;
        };
        let Some(start) = parse_onelap_local_time(start_time_local, offset) else {
            continue;
        };
        if start < from_seconds {
            older_than_start = true;
            break;
        }
        if start >= to_seconds {
            continue;
        }
        let duration_seconds = item
            .get("time_seconds")
            .or_else(|| item.get("time"))
            .and_then(json_f64)
            .filter(|value| value.is_finite() && *value >= 0.0)
            .unwrap_or(0.0);
        let distance_meters = item
            .get("distance_km")
            .and_then(json_f64)
            .map(|kilometers| kilometers * 1_000.0)
            .or_else(|| item.get("totalDistance").and_then(json_f64))
            .filter(|value| value.is_finite() && *value >= 0.0);
        rides.push(OnelapRide {
            id,
            start_time_local: start_time_local.to_owned(),
            start_time_seconds: start as f64,
            end_time_seconds: start as f64 + duration_seconds.max(1.0),
            duration_seconds,
            distance_meters,
        });
    }
    (rides, older_than_start, items.len())
}

fn parse_onelap_local_time(value: &str, offset: UtcOffset) -> Option<i64> {
    if value.len() != 19 {
        return None;
    }
    let format =
        format_description::parse_borrowed::<3>("[year]-[month]-[day] [hour]:[minute]:[second]")
            .ok()?;
    Some(
        PrimitiveDateTime::parse(value, &format)
            .ok()?
            .assume_offset(offset)
            .unix_timestamp(),
    )
}

fn json_id(value: &Value) -> Option<String> {
    match value {
        Value::String(value) if !value.is_empty() && value.len() <= 256 => Some(value.to_owned()),
        Value::Number(value) => Some(value.to_string()),
        _ => None,
    }
}

fn json_string(value: &Value) -> Option<&str> {
    value
        .as_str()
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn json_f64(value: &Value) -> Option<f64> {
    match value {
        Value::Number(value) => value.as_f64(),
        Value::String(value) => value.parse().ok(),
        _ => None,
    }
}

fn json_i64(value: &Value) -> Option<i64> {
    match value {
        Value::Number(value) => value.as_i64(),
        Value::String(value) => value.parse().ok(),
        _ => None,
    }
}

async fn read_activity_limited(
    response: &mut Response,
    max_bytes: usize,
) -> Result<Vec<u8>, OnelapActivityError> {
    if response
        .content_length()
        .is_some_and(|length| length > max_bytes as u64)
    {
        return Err(OnelapActivityError::ResponseTooLarge);
    }
    let mut body = Vec::with_capacity(
        response
            .content_length()
            .unwrap_or_default()
            .min(max_bytes as u64) as usize,
    );
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| OnelapActivityError::Transport)?
    {
        if body.len().saturating_add(chunk.len()) > max_bytes {
            return Err(OnelapActivityError::ResponseTooLarge);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn signed_login_request(
    account: &str,
    password: &str,
    nonce: String,
    timestamp: String,
) -> Result<SignedLoginRequest, OnelapLoginError> {
    validate_input(account, password)?;
    let password_md5 = md5_hex(password);
    let sign = md5_hex(&format!(
        "account={account}&nonce={nonce}&password={password_md5}&timestamp={timestamp}&key={SIGNING_SECRET}"
    ));
    let body = serde_json::to_vec(&LoginPayload {
        account,
        password: password_md5,
    })
    .map_err(|_| OnelapLoginError::InvalidInput)?;
    Ok(SignedLoginRequest {
        nonce,
        timestamp,
        sign,
        body,
    })
}

fn validate_input(account: &str, password: &str) -> Result<(), OnelapLoginError> {
    if account.trim().is_empty()
        || account.len() > MAX_ACCOUNT_BYTES
        || account.bytes().any(|byte| byte.is_ascii_control())
        || password.is_empty()
        || password.len() > MAX_PASSWORD_BYTES
    {
        return Err(OnelapLoginError::InvalidInput);
    }
    Ok(())
}

fn md5_hex(value: &str) -> String {
    let digest = Md5::digest(value.as_bytes());
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn random_nonce() -> String {
    rand::thread_rng()
        .sample_iter(Alphanumeric)
        .take(16)
        .map(char::from)
        .collect()
}

fn unix_timestamp() -> Result<String, OnelapLoginError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs().to_string())
        .map_err(|_| OnelapLoginError::Clock)
}

async fn read_limited(response: &mut Response) -> Result<Vec<u8>, OnelapLoginError> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
    {
        return Err(OnelapLoginError::ResponseTooLarge);
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
        .map_err(|_| OnelapLoginError::Transport)?
    {
        if body.len().saturating_add(chunk.len()) > MAX_RESPONSE_BYTES {
            return Err(OnelapLoginError::ResponseTooLarge);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn session_item(root: &Value) -> &Value {
    match root.get("data") {
        Some(Value::Array(items)) => items.first().unwrap_or(&Value::Null),
        Some(Value::Object(_)) => &root["data"],
        _ => root,
    }
}

fn session_tokens(root: &Value) -> Result<(String, Option<String>), OnelapLoginError> {
    let item = session_item(root);
    let token = item
        .get("token")
        .and_then(json_string)
        .ok_or(OnelapLoginError::InvalidResponse)?;
    let token = sanitize_session_value(token.to_owned(), MAX_TOKEN_BYTES)?;
    let refresh_token = item
        .get("refresh_token")
        .and_then(json_string)
        .map(|value| sanitize_session_value(value.to_owned(), MAX_TOKEN_BYTES))
        .transpose()?;
    Ok((token, refresh_token))
}

fn response_session_expired(root: &Value) -> bool {
    is_expired_session(
        root.get("code").and_then(json_i64),
        root.get("msg")
            .or_else(|| root.get("message"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
    )
}

fn parse_login_response(body: &[u8]) -> Result<OnelapSession, OnelapLoginError> {
    let root: Value =
        serde_json::from_slice(body).map_err(|_| OnelapLoginError::InvalidResponse)?;
    if response_session_expired(&root) {
        return Err(OnelapLoginError::Unauthorized);
    }
    if root
        .get("data")
        .and_then(Value::as_array)
        .is_some_and(Vec::is_empty)
    {
        return Err(OnelapLoginError::Unauthorized);
    }
    let (token, refresh_token) = session_tokens(&root)?;
    let uid = session_item(&root)
        .get("userinfo")
        .and_then(|user| user.get("uid"))
        .and_then(json_id)
        .ok_or(OnelapLoginError::InvalidResponse)?;
    if !is_safe_cookie_value(&uid, MAX_UID_BYTES) {
        return Err(OnelapLoginError::InvalidResponse);
    }
    Ok(OnelapSession {
        token,
        uid,
        refresh_token,
    })
}

fn parse_refreshed_session(
    body: &[u8],
    uid: &str,
    previous_refresh: &str,
) -> Result<OnelapSession, OnelapLoginError> {
    let root: Value =
        serde_json::from_slice(body).map_err(|_| OnelapLoginError::InvalidResponse)?;
    if response_session_expired(&root) {
        return Err(OnelapLoginError::SessionExpired);
    }
    let (token, refresh_token) = session_tokens(&root)?;
    Ok(OnelapSession {
        token,
        uid: uid.to_owned(),
        refresh_token: Some(refresh_token.unwrap_or_else(|| previous_refresh.to_owned())),
    })
}

fn sanitize_session_value(value: String, max_bytes: usize) -> Result<String, OnelapLoginError> {
    if !is_safe_header_value(&value, max_bytes) {
        return Err(OnelapLoginError::InvalidResponse);
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::{
        MAX_ACCOUNT_BYTES, MAX_PASSWORD_BYTES, OnelapActivityError, OnelapLoginError,
        is_safe_public_fit_url, is_trusted_onelap_https_url, md5_hex, parse_login_response,
        parse_ride_page, signed_login_request, validate_activity_input, validate_fit_input,
        validate_input,
    };
    use reqwest::Url;
    use serde_json::json;

    #[test]
    fn matches_the_swift_md5_login_contract() {
        let request = signed_login_request(
            "rider@example.com",
            "secret",
            "Abc123XyZ789QweR".to_owned(),
            "1700000000".to_owned(),
        )
        .unwrap();
        assert_eq!(md5_hex("secret"), "5ebe2294ecd0e0f08eab7690d2a6ee69");
        assert_eq!(request.sign, "751eff7a6dbf68de9a3b6300b2ce90fd");
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&request.body).unwrap()["password"],
            "5ebe2294ecd0e0f08eab7690d2a6ee69"
        );
    }

    #[test]
    fn only_trusts_https_onelap_hosts() {
        for raw in [
            "https://onelap.cn/api/login",
            "https://www.onelap.cn/api/login",
            "https://otm.onelap.cn/api/login",
        ] {
            assert!(
                is_trusted_onelap_https_url(&Url::parse(raw).unwrap()),
                "{raw}"
            );
        }
        for raw in [
            "http://www.onelap.cn/api/login",
            "https://onelap.cn.example/api/login",
            "https://notonelap.cn/api/login",
        ] {
            assert!(
                !is_trusted_onelap_https_url(&Url::parse(raw).unwrap()),
                "{raw}"
            );
        }
    }

    #[test]
    fn accepts_the_legacy_token_and_numeric_or_string_uid() {
        let numeric =
            parse_login_response(br#"{"data":[{"token":"token_123","userinfo":{"uid":42}}]}"#)
                .unwrap();
        assert_eq!(numeric.uid, "42");
        let string = parse_login_response(
            br#"{"data":[{"token":"token_123","userinfo":{"uid":"user-7"}}]}"#,
        )
        .unwrap();
        assert_eq!(string.uid, "user-7");
        assert_eq!(string.token, "token_123");
    }

    #[test]
    fn rejects_invalid_input_and_untrusted_response_fields() {
        assert_eq!(
            validate_input("", "password"),
            Err(OnelapLoginError::InvalidInput)
        );
        assert_eq!(
            validate_input(&"a".repeat(MAX_ACCOUNT_BYTES + 1), "password"),
            Err(OnelapLoginError::InvalidInput)
        );
        assert_eq!(
            validate_input("account", &"p".repeat(MAX_PASSWORD_BYTES + 1)),
            Err(OnelapLoginError::InvalidInput)
        );
        assert_eq!(
            parse_login_response(br#"{"data":[{"token":"bad token","userinfo":{"uid":1}}]}"#),
            Err(OnelapLoginError::InvalidResponse)
        );
    }

    #[test]
    fn list_parses_swift_local_time_contract_and_half_open_window() {
        let page = json!({
            "list": [
                {"id": 12, "start_riding_time": "2024-01-01 08:00:00", "time_seconds": 60, "distance_km": 1.25},
                {"activity_id": "end", "startTime": "2024-01-01 09:00:00", "time": "120", "totalDistance": 2000},
                {"id": "old", "start_riding_time": "2023-12-31 23:59:59"}
            ]
        });
        let (rides, older, count) = parse_ride_page(
            page.as_object().unwrap(),
            1_704_067_200,
            1_704_070_800,
            8 * 3600,
        );
        assert_eq!(count, 3);
        assert!(older);
        assert_eq!(rides.len(), 1);
        assert_eq!(rides[0].id, "12");
        assert_eq!(rides[0].start_time_seconds, 1_704_067_200.0);
        assert_eq!(rides[0].duration_seconds, 60.0);
        assert_eq!(rides[0].distance_meters, Some(1_250.0));
    }

    #[test]
    fn fit_urls_are_https_without_credentials_and_never_expand_auth_scope() {
        assert!(is_safe_public_fit_url(
            &Url::parse("https://cdn.example.com/ride.fit").unwrap()
        ));
        for raw in [
            "http://cdn.example.com/ride.fit",
            "https://token@cdn.example.com/ride.fit",
            "https://cdn.example.com:8443/ride.fit",
        ] {
            assert!(!is_safe_public_fit_url(&Url::parse(raw).unwrap()), "{raw}");
        }
        assert!(!is_trusted_onelap_https_url(
            &Url::parse("https://token@otm.onelap.cn/api").unwrap()
        ));
    }

    #[test]
    fn activity_credentials_and_path_inputs_are_bounded() {
        assert!(validate_activity_input("token", "uid", 1, 2, 0).is_ok());
        assert_eq!(
            validate_activity_input("token\r\nX: injected", "uid", 1, 2, 0),
            Err(OnelapActivityError::InvalidInput)
        );
        assert_eq!(
            validate_fit_input("token", "uid; injected", "ride-1"),
            Err(OnelapActivityError::InvalidInput)
        );
        assert_eq!(
            validate_fit_input("token", "uid", "../ride"),
            Err(OnelapActivityError::InvalidInput)
        );
    }
    #[test]
    fn expired_business_responses_require_reauthentication_without_echoing_secrets() {
        for response in [
            json!({"code": 401, "msg": "private token value"}),
            json!({"code": "403", "data": {}}),
            json!({"code": 200, "message": "Token Expired: private token value"}),
            json!({"code": 200, "msg": "请重新登录"}),
        ] {
            let error = super::checked_data(&response).unwrap_err();
            assert_eq!(error, OnelapActivityError::Unauthorized);
            assert!(!format!("{error:?} {error}").contains("private token value"));
        }
    }

    #[test]
    fn session_debug_and_cookie_validation_do_not_expose_credentials() {
        let session = parse_login_response(
            br#"{"data":[{"token":"private_token","userinfo":{"uid":"private_uid"}}]}"#,
        )
        .unwrap();
        let debug = format!("{session:?}");
        assert!(!debug.contains("private_token"));
        assert!(!debug.contains("private_uid"));
        for uid in ["user;other=cookie", "user,other", "user\\other"] {
            let value = json!({"data":[{"token":"token","userinfo":{"uid":uid}}]});
            assert!(parse_login_response(&serde_json::to_vec(&value).unwrap()).is_err());
        }
    }

    #[test]
    fn fit_candidate_keeps_base64_file_key_as_one_segment() {
        let client = super::OnelapActivityClient::new().unwrap();
        let record = json!({"fileKey": "???"});
        let candidates = client.fit_candidates("123", record.as_object().unwrap());
        assert!(
            candidates
                .iter()
                .any(|url| url.as_str().ends_with("/Pz8%2F"))
        );
        assert!(validate_fit_input("token", "42", "..").is_err());
        assert!(validate_activity_input("token", "42", 0, 1, 86_400).is_err());
    }
    #[test]
    fn fit_candidates_reject_explicit_local_network_destinations() {
        for raw in [
            "https://127.0.0.1/track.fit",
            "https://10.0.0.1/track.fit",
            "https://192.168.1.1/track.fit",
            "https://169.254.169.254/track.fit",
            "https://[::1]/track.fit",
            "https://[::ffff:127.0.0.1]/track.fit",
            "https://[fd00::1]/track.fit",
            "https://localhost/track.fit",
            "https://router.local/track.fit",
            "https://metadata.internal/track.fit",
        ] {
            assert!(!is_safe_public_fit_url(&Url::parse(raw).unwrap()), "{raw}");
        }
        assert!(is_safe_public_fit_url(
            &Url::parse("https://cdn.example.com/track.fit").unwrap()
        ));
    }
    #[test]
    fn login_and_refresh_preserve_and_rotate_refresh_tokens_like_swift() {
        let login = parse_login_response(br#"{"data":[{"token":"access","refresh_token":"private_refresh","userinfo":{"uid":42}}]}"#).unwrap();
        assert_eq!(login.refresh_token.as_deref(), Some("private_refresh"));
        assert!(!format!("{login:?}").contains("private_refresh"));
        for response in [
            br#"{"data":{"token":"new_access","refresh_token":"rotated"}}"#.as_slice(),
            br#"{"data":[{"token":"new_access","refresh_token":"rotated"}]}"#.as_slice(),
            br#"{"token":"new_access","refresh_token":"rotated"}"#.as_slice(),
        ] {
            let session = super::parse_refreshed_session(response, "42", "old_refresh").unwrap();
            assert_eq!(session.token, "new_access");
            assert_eq!(session.uid, "42");
            assert_eq!(session.refresh_token.as_deref(), Some("rotated"));
        }
        let session = super::parse_refreshed_session(
            br#"{"data":{"token":"new_access"}}"#,
            "42",
            "old_refresh",
        )
        .unwrap();
        assert_eq!(session.refresh_token.as_deref(), Some("old_refresh"));
        assert_eq!(
            super::parse_refreshed_session(
                br#"{"code":401,"msg":"private_refresh"}"#,
                "42",
                "old_refresh"
            ),
            Err(OnelapLoginError::SessionExpired)
        );
    }

    #[tokio::test]
    async fn refresh_uses_swift_json_contract_without_sending_an_authorization_header() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = Url::parse(&format!(
            "http://{}/api/token",
            listener.local_addr().unwrap()
        ))
        .unwrap();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                .unwrap();
            let mut request = Vec::new();
            let mut buffer = [0; 4096];
            loop {
                let n = socket.read(&mut buffer).unwrap();
                assert!(n > 0);
                request.extend_from_slice(&buffer[..n]);
                if let Some(index) = request.windows(4).position(|part| part == b"\r\n\r\n") {
                    let header = String::from_utf8_lossy(&request[..index]);
                    let length: usize = header
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length: ")
                                .map(str::to_owned)
                        })
                        .unwrap()
                        .parse()
                        .unwrap();
                    if request.len() >= index + 4 + length {
                        break;
                    }
                }
            }
            let body = r#"{"data":{"token":"new_access","refresh_token":"rotated"}}"#;
            write!(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
            request
        });
        let client = super::OnelapLoginClient {
            client: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .unwrap(),
            endpoint: url.clone(),
            refresh_endpoint: url,
        };
        let session = client.refresh("old_refresh", "42").await.unwrap();
        assert_eq!(session.refresh_token.as_deref(), Some("rotated"));
        let bytes = server.join().unwrap();
        let request = String::from_utf8(bytes).unwrap();
        assert!(request.starts_with("POST /api/token HTTP/1.1\r\n"));
        assert!(!request.to_ascii_lowercase().contains("authorization:"));
        let body: serde_json::Value =
            serde_json::from_str(request.split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert_eq!(body, json!({"token":"old_refresh","from":"web","to":"web"}));
    }
    #[test]
    fn keeps_validated_wall_times_for_historical_dst_resolution_on_platform() {
        let data = json!({"list":[
            {"id":1, "start_riding_time":"2024-01-15 12:00:00", "time_seconds":3600},
            {"id":2, "start_riding_time":"2024-07-15 12:00:00", "time_seconds":3600},
            {"id":3, "start_riding_time":"2024-07-15 12:00:00Z", "time_seconds":3600},
            {"id":4, "start_riding_time":"2024-02-31 12:00:00", "time_seconds":3600}
        ]});
        let (rides, _, _) = parse_ride_page(data.as_object().unwrap(), 0, i64::MAX, -7 * 3600);
        assert_eq!(rides.len(), 2);
        assert_eq!(rides[0].start_time_local, "2024-01-15 12:00:00");
        assert_eq!(rides[1].start_time_local, "2024-07-15 12:00:00");
    }
}
