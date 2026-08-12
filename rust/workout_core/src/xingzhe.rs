//! 行者网页登录。此模块不保存账号、密码或 sessionid，也不会把它们放进错误文本。

use base64::{Engine, engine::general_purpose::STANDARD};
use rand::rngs::OsRng;
use reqwest::{
    Client, Response, StatusCode,
    header::{CONTENT_TYPE, HeaderMap, HeaderValue, ORIGIN, REFERER, SET_COOKIE, USER_AGENT},
    redirect::Policy,
};
use rsa::{Pkcs1v15Encrypt, RsaPublicKey, pkcs8::DecodePublicKey};
use serde::Serialize;
use std::{fmt, time::Duration};

const LOGIN_URL: &str = "https://www.imxingzhe.com/api/v1/user/login/";
const ORIGIN_VALUE: &str = "https://www.imxingzhe.com";
const REFERER_VALUE: &str = "https://www.imxingzhe.com/user/login";
const USER_AGENT_VALUE: &str =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15";
const PUBLIC_KEY_PEM: &str = "-----BEGIN PUBLIC KEY-----\nMIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDmuQkBbijudDAJgfffDeeIButq\nWHZvUwcRuvWdg89393FSdz3IJUHc0rgI/S3WuU8N0VePJLmVAZtCOK4qe4FY/eKm\nWpJmn7JfXB4HTMWjPVoyRZmSYjW4L8GrWmh51Qj7DwpTADadF3aq04o+s1b8LXJa\n8r6+TIqqL5WUHtRqmQIDAQAB\n-----END PUBLIC KEY-----";
const MAX_ACCOUNT_BYTES: usize = 256;
const MAX_PASSWORD_BYTES: usize = 117; // 1024-bit RSA PKCS#1 v1.5 的明文上限。
const MAX_RESPONSE_BYTES: usize = 64 * 1024;

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
        MAX_ACCOUNT_BYTES, MAX_PASSWORD_BYTES, XingzheLoginError, encrypt_password,
        extract_session_id, validate_input,
    };
    use reqwest::header::{HeaderMap, HeaderValue, SET_COOKIE};

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
}
