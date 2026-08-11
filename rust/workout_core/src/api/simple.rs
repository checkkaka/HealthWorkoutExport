/// Flutter 调用的最小同步入口，直接复用已测试的核心规则。
#[flutter_rust_bridge::frb(sync)]
pub fn is_commute(distance_meters: Option<f64>, duration_seconds: f64) -> bool {
    crate::is_commute(distance_meters, duration_seconds)
}

#[derive(Clone, Copy, Debug)]
pub struct FitProbeSummary {
    pub gps_point_count: u32,
    pub heart_rate_point_count: u32,
    pub quality_score: u32,
}

/// 严格校验 FIT 并返回轨迹/心率内容质量摘要。
#[flutter_rust_bridge::frb(sync)]
pub fn fit_content_summary(data: Vec<u8>) -> Result<FitProbeSummary, String> {
    let summary = crate::fit::decode_fit(&data).map_err(|error| format!("{error:?}"))?;
    Ok(FitProbeSummary {
        gps_point_count: u32::try_from(summary.gps_point_count).map_err(|_| "FitTooLarge")?,
        heart_rate_point_count: u32::try_from(summary.heart_rate_point_count)
            .map_err(|_| "FitTooLarge")?,
        quality_score: u32::try_from(summary.quality_score()).map_err(|_| "FitTooLarge")?,
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn is_valid_fit(data: Vec<u8>) -> bool {
    crate::fit::is_valid_fit(&data)
}

/// 严格校验后原样返回 FIT；当前接口没有编辑参数。
#[flutter_rust_bridge::frb(sync)]
pub fn reencode_fit(data: Vec<u8>) -> Result<Vec<u8>, String> {
    crate::fit::reencode_fit(&data).map_err(|error| format!("{error:?}"))
}

#[derive(Clone)]
pub struct StravaTokenResult {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_at: f64,
}

pub async fn strava_exchange_code(
    client_id: String,
    client_secret: String,
    code: String,
) -> Result<StravaTokenResult, String> {
    let client = crate::strava::StravaTokenClient::new().map_err(|error| error.to_string())?;
    let token = client
        .exchange_code(&client_id, &client_secret, &code)
        .await
        .map_err(|error| error.to_string())?;
    Ok(token_result(token))
}

pub async fn strava_refresh_token(
    client_id: String,
    client_secret: String,
    refresh_token: String,
) -> Result<StravaTokenResult, String> {
    let client = crate::strava::StravaTokenClient::new().map_err(|error| error.to_string())?;
    let token = client
        .refresh(&client_id, &client_secret, &refresh_token)
        .await
        .map_err(|error| error.to_string())?;
    Ok(token_result(token))
}

fn token_result(token: crate::strava::StravaToken) -> StravaTokenResult {
    StravaTokenResult {
        access_token: token.access_token().to_owned(),
        refresh_token: token.refresh_token().to_owned(),
        expires_at: token.expires_at(),
    }
}
