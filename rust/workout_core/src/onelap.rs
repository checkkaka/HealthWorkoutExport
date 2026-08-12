//! 顽鹿网页登录。凭据仅用于一次请求，错误文本不会包含账号、密码、签名或令牌。

use md5::{Digest, Md5};
use rand::{Rng, distributions::Alphanumeric};
use reqwest::{
    Client, Response, StatusCode, Url,
    header::{CONTENT_TYPE, HeaderValue, ORIGIN, USER_AGENT},
    redirect::Policy,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fmt,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const LOGIN_URL: &str = "https://www.onelap.cn/api/login";
const ORIGIN_VALUE: &str = "https://www.onelap.cn";
const USER_AGENT_VALUE: &str = "Mozilla/5.0";
const SIGNING_SECRET: &str = "fe9f8382418fcdeb136461cac6acae7b";
const MAX_ACCOUNT_BYTES: usize = 256;
const MAX_PASSWORD_BYTES: usize = 1024;
const MAX_RESPONSE_BYTES: usize = 64 * 1024;
const MAX_TOKEN_BYTES: usize = 4096;
const MAX_UID_BYTES: usize = 256;

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
            Self::HttpStatus(_) => "顽鹿登录失败",
            Self::ResponseTooLarge => "顽鹿登录响应过大",
            Self::InvalidResponse => "顽鹿登录响应无效",
        };
        f.write_str(message)
    }
}

impl std::error::Error for OnelapLoginError {}

/// 可由 Flutter 安全保存的短期顽鹿会话标识。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OnelapSession {
    pub token: String,
    pub uid: String,
}

#[derive(Clone)]
pub struct OnelapLoginClient {
    client: Client,
    endpoint: Url,
}

#[derive(Serialize)]
struct LoginPayload<'a> {
    account: &'a str,
    password: String,
}

#[derive(Deserialize)]
struct LoginResponse {
    data: Vec<LoginData>,
}

#[derive(Deserialize)]
struct LoginData {
    token: String,
    userinfo: LoginUserInfo,
}

#[derive(Deserialize)]
struct LoginUserInfo {
    uid: Value,
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
        Ok(Self { client, endpoint })
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
}

/// 只接受官方根域或其子域的 HTTPS URL；`onelap.cn.example` 不属于可信域。
pub fn is_trusted_onelap_https_url(url: &Url) -> bool {
    matches!(url.scheme(), "https")
        && url.host_str().is_some_and(|host| {
            let host = host.to_ascii_lowercase();
            host == "onelap.cn" || host.ends_with(".onelap.cn")
        })
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

fn parse_login_response(body: &[u8]) -> Result<OnelapSession, OnelapLoginError> {
    let response: LoginResponse =
        serde_json::from_slice(body).map_err(|_| OnelapLoginError::InvalidResponse)?;
    let Some(first) = response.data.into_iter().next() else {
        return Err(OnelapLoginError::Unauthorized);
    };
    let token = sanitize_session_value(first.token, MAX_TOKEN_BYTES)?;
    let uid = match first.userinfo.uid {
        Value::String(value) => value,
        Value::Number(value) if value.is_i64() || value.is_u64() => value.to_string(),
        _ => return Err(OnelapLoginError::InvalidResponse),
    };
    Ok(OnelapSession {
        token,
        uid: sanitize_session_value(uid, MAX_UID_BYTES)?,
    })
}

fn sanitize_session_value(value: String, max_bytes: usize) -> Result<String, OnelapLoginError> {
    if value.is_empty()
        || value.len() > max_bytes
        || value
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte == b' ')
    {
        return Err(OnelapLoginError::InvalidResponse);
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::{
        MAX_ACCOUNT_BYTES, MAX_PASSWORD_BYTES, OnelapLoginError, is_trusted_onelap_https_url,
        md5_hex, parse_login_response, signed_login_request, validate_input,
    };
    use reqwest::Url;

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
}
