use reqwest::{Client, StatusCode, redirect::Policy};
use serde::Deserialize;
use std::{fmt, time::Duration};

const TOKEN_ENDPOINT: &str = "https://www.strava.com/oauth/token";
const MAX_INPUT_BYTES: usize = 8 * 1024;
const MAX_RESPONSE_BYTES: usize = 64 * 1024;

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
    use super::{StravaTokenClient, StravaTokenError};
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
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
}
