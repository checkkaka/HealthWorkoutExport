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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StravaUploadFfiStatus {
    Completed,
    NeedsRefresh,
    Failed,
    Cancelled,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StravaUploadRetryStage {
    Upload,
    Poll,
}

#[derive(Clone, Debug)]
pub struct StravaUploadRetry {
    pub stage: StravaUploadRetryStage,
    pub upload_id: Option<String>,
    pub poll_attempt: Option<u32>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StravaUploadFfiErrorCode {
    InvalidInput,
    OperationInUse,
    ClientBuild,
    Transport,
    Unauthorized,
    RateLimited,
    ResponseTooLarge,
    InvalidResponse,
    UploadFailed,
    Cancelled,
}

#[derive(Clone, Debug)]
pub struct StravaUploadFfiError {
    pub code: StravaUploadFfiErrorCode,
    pub message: String,
}

#[derive(Clone, Debug)]
pub struct StravaUploadFfiResponse {
    pub status: StravaUploadFfiStatus,
    pub remote_id: Option<String>,
    pub is_duplicate: bool,
    pub retry: Option<StravaUploadRetry>,
    pub error: Option<StravaUploadFfiError>,
}

/// 首次上传。若返回 NeedsRefresh/Upload，调用方强制刷新并只调用一次
/// `strava_retry_upload_after_refresh`，不得再次调用本入口形成无限重试。
/// 仅供手写 Dart 安全门面调用；业务代码不得直接绕过门面的输入预检。
#[allow(clippy::too_many_arguments)]
pub async fn strava_upload_fit(
    operation_handle: String,
    access_token: String,
    fit: Vec<u8>,
    external_id: String,
    filename: String,
    commute: bool,
    description: Option<String>,
) -> StravaUploadFfiResponse {
    let mut operation = match UploadOperation::begin(operation_handle) {
        Ok(operation) => operation,
        Err(error) => return operation_error_response(error),
    };
    let result = match crate::strava::StravaUploadClient::new() {
        Ok(client) => {
            client
                .upload_fit_cancellable(
                    &access_token,
                    fit,
                    &external_id,
                    &filename,
                    commute,
                    description.as_deref(),
                    &operation.cancellation,
                )
                .await
        }
        Err(error) => Err(error),
    };
    if matches!(
        result,
        Err(crate::strava::StravaUploadError::Unauthorized(_))
    ) {
        operation.reserve_for_refresh();
    }
    upload_ffi_response(result)
}

/// POST 401 后的唯一一次重放；本调用再次遇到 401 会直接返回 Unauthorized 硬失败。
/// 仅供手写 Dart 安全门面调用。
#[allow(clippy::too_many_arguments)]
pub async fn strava_retry_upload_after_refresh(
    operation_handle: String,
    access_token: String,
    fit: Vec<u8>,
    external_id: String,
    filename: String,
    commute: bool,
    description: Option<String>,
) -> StravaUploadFfiResponse {
    let operation = match UploadOperation::begin(operation_handle) {
        Ok(operation) => operation,
        Err(error) => return operation_error_response(error),
    };
    let result = match crate::strava::StravaUploadClient::new() {
        Ok(client) => {
            client
                .retry_upload_after_refresh(
                    &access_token,
                    fit,
                    &external_id,
                    &filename,
                    commute,
                    description.as_deref(),
                    &operation.cancellation,
                )
                .await
        }
        Err(error) => Err(error),
    };
    upload_ffi_response(result)
}

/// poll 401 后以新 token 从同一 uploadId、同一 attempt 立即续跑；再次 401 直接失败。
/// 仅供手写 Dart 安全门面调用。
pub async fn strava_resume_upload_poll_after_refresh(
    operation_handle: String,
    access_token: String,
    upload_id: String,
    poll_attempt: u32,
) -> StravaUploadFfiResponse {
    let operation = match UploadOperation::begin(operation_handle) {
        Ok(operation) => operation,
        Err(error) => return operation_error_response(error),
    };
    let result = match usize::try_from(poll_attempt) {
        Ok(attempt) => match crate::strava::StravaUploadClient::new() {
            Ok(client) => {
                client
                    .resume_poll_after_refresh(
                        &access_token,
                        crate::strava::StravaPollResume::new(upload_id, attempt),
                        &operation.cancellation,
                    )
                    .await
            }
            Err(error) => Err(error),
        },
        Err(_) => Err(crate::strava::StravaUploadError::InvalidInput(
            "poll_attempt",
        )),
    };
    upload_ffi_response(result)
}

#[derive(Clone, Debug)]
pub struct StravaUploadReservation {
    pub handle: String,
}

/// 同步预留一个不可重用 handle；Dart 必须先 reserve，再启动异步上传或轮询。
#[flutter_rust_bridge::frb(sync)]
pub fn strava_reserve_upload(operation_id: String) -> Result<StravaUploadReservation, String> {
    UploadOperation::reserve(operation_id)
        .map(|handle| StravaUploadReservation { handle })
        .map_err(|error| match error {
            UploadOperationError::Invalid => "invalid operation_id".to_owned(),
            UploadOperationError::InUse => "operation_id 已在运行或等待启动".to_owned(),
            UploadOperationError::Exhausted => "operation handle exhausted".to_owned(),
        })
}

/// 精确取消同 generation handle。旧 handle 永远不能取消新一代同 logical ID 操作。
#[flutter_rust_bridge::frb(sync)]
pub fn strava_cancel_upload(operation_handle: String) -> bool {
    let cancellation = upload_operations()
        .lock()
        .expect("upload operation mutex poisoned")
        .operations
        .get(&operation_handle)
        .map(|entry| entry.cancellation.clone());
    if let Some(cancellation) = cancellation {
        cancellation.cancel();
        true
    } else {
        false
    }
}

/// 释放尚未启动的预留 handle；运行中的操作由 RAII 在 Future 结束时释放。
#[flutter_rust_bridge::frb(sync)]
pub fn strava_release_upload(operation_handle: String) -> bool {
    let mut registry = upload_operations()
        .lock()
        .expect("upload operation mutex poisoned");
    let Some(entry) = registry.operations.get(&operation_handle) else {
        return false;
    };
    if entry.state != UploadOperationState::Reserved {
        return false;
    }
    let logical_id = entry.logical_id.clone();
    registry.operations.remove(&operation_handle);
    if registry.active_by_logical.get(&logical_id) == Some(&operation_handle) {
        registry.active_by_logical.remove(&logical_id);
    }
    true
}

fn upload_ffi_response(
    result: Result<crate::strava::StravaUploadResult, crate::strava::StravaUploadError>,
) -> StravaUploadFfiResponse {
    match result {
        Ok(result) => StravaUploadFfiResponse {
            status: StravaUploadFfiStatus::Completed,
            remote_id: result.remote_id().map(str::to_owned),
            is_duplicate: result.is_duplicate(),
            retry: None,
            error: None,
        },
        Err(crate::strava::StravaUploadError::Unauthorized(stage)) => {
            let retry = match stage {
                crate::strava::StravaUnauthorizedStage::Upload => StravaUploadRetry {
                    stage: StravaUploadRetryStage::Upload,
                    upload_id: None,
                    poll_attempt: None,
                },
                crate::strava::StravaUnauthorizedStage::Poll(resume) => StravaUploadRetry {
                    stage: StravaUploadRetryStage::Poll,
                    upload_id: Some(resume.upload_id().to_owned()),
                    poll_attempt: u32::try_from(resume.attempt_index()).ok(),
                },
            };
            StravaUploadFfiResponse {
                status: StravaUploadFfiStatus::NeedsRefresh,
                remote_id: None,
                is_duplicate: false,
                retry: Some(retry),
                error: None,
            }
        }
        Err(error) => {
            let (code, status) = match &error {
                crate::strava::StravaUploadError::InvalidInput(_) => (
                    StravaUploadFfiErrorCode::InvalidInput,
                    StravaUploadFfiStatus::Failed,
                ),
                crate::strava::StravaUploadError::ClientBuild => (
                    StravaUploadFfiErrorCode::ClientBuild,
                    StravaUploadFfiStatus::Failed,
                ),
                crate::strava::StravaUploadError::Transport => (
                    StravaUploadFfiErrorCode::Transport,
                    StravaUploadFfiStatus::Failed,
                ),
                crate::strava::StravaUploadError::UnauthorizedAfterRefresh => (
                    StravaUploadFfiErrorCode::Unauthorized,
                    StravaUploadFfiStatus::Failed,
                ),
                crate::strava::StravaUploadError::RateLimited => (
                    StravaUploadFfiErrorCode::RateLimited,
                    StravaUploadFfiStatus::Failed,
                ),
                crate::strava::StravaUploadError::ResponseTooLarge => (
                    StravaUploadFfiErrorCode::ResponseTooLarge,
                    StravaUploadFfiStatus::Failed,
                ),
                crate::strava::StravaUploadError::InvalidResponse => (
                    StravaUploadFfiErrorCode::InvalidResponse,
                    StravaUploadFfiStatus::Failed,
                ),
                crate::strava::StravaUploadError::UploadFailed(_) => (
                    StravaUploadFfiErrorCode::UploadFailed,
                    StravaUploadFfiStatus::Failed,
                ),
                crate::strava::StravaUploadError::Cancelled => (
                    StravaUploadFfiErrorCode::Cancelled,
                    StravaUploadFfiStatus::Cancelled,
                ),
                crate::strava::StravaUploadError::Unauthorized(_) => unreachable!(),
            };
            StravaUploadFfiResponse {
                status,
                remote_id: None,
                is_duplicate: false,
                retry: None,
                error: Some(StravaUploadFfiError {
                    code,
                    message: error.to_string(),
                }),
            }
        }
    }
}

fn operation_error_response(error: UploadOperationError) -> StravaUploadFfiResponse {
    let (code, message) = match error {
        UploadOperationError::Invalid => (
            StravaUploadFfiErrorCode::InvalidInput,
            "invalid operation_handle",
        ),
        UploadOperationError::InUse => (
            StravaUploadFfiErrorCode::OperationInUse,
            "operation_handle 已在运行",
        ),
        UploadOperationError::Exhausted => (
            StravaUploadFfiErrorCode::InvalidResponse,
            "operation handle exhausted",
        ),
    };
    StravaUploadFfiResponse {
        status: StravaUploadFfiStatus::Failed,
        remote_id: None,
        is_duplicate: false,
        retry: None,
        error: Some(StravaUploadFfiError {
            code,
            message: message.to_owned(),
        }),
    }
}

fn upload_operations() -> &'static std::sync::Mutex<UploadOperationRegistry> {
    static OPERATIONS: std::sync::OnceLock<std::sync::Mutex<UploadOperationRegistry>> =
        std::sync::OnceLock::new();
    OPERATIONS.get_or_init(|| {
        std::sync::Mutex::new(UploadOperationRegistry {
            operations: std::collections::HashMap::new(),
            active_by_logical: std::collections::HashMap::new(),
        })
    })
}

struct UploadOperationRegistry {
    operations: std::collections::HashMap<String, UploadOperationEntry>,
    active_by_logical: std::collections::HashMap<String, String>,
}

struct UploadOperationEntry {
    logical_id: String,
    cancellation: crate::strava::StravaCancellation,
    state: UploadOperationState,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum UploadOperationState {
    Reserved,
    Running,
}

struct UploadOperation {
    handle: String,
    cancellation: crate::strava::StravaCancellation,
    keep_reserved: bool,
}

#[derive(Debug)]
enum UploadOperationError {
    Invalid,
    InUse,
    Exhausted,
}

impl UploadOperation {
    fn reserve(operation_id: String) -> Result<String, UploadOperationError> {
        const MAX_OPERATIONS: usize = 128;
        if operation_id.trim().is_empty()
            || operation_id.len() > 256
            || operation_id
                .chars()
                .any(|character| character.is_ascii_control())
        {
            return Err(UploadOperationError::Invalid);
        }
        static NEXT_HANDLE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let mut registry = upload_operations()
            .lock()
            .expect("upload operation mutex poisoned");
        if registry.active_by_logical.contains_key(&operation_id) {
            return Err(UploadOperationError::InUse);
        }
        if registry.operations.len() >= MAX_OPERATIONS {
            return Err(UploadOperationError::Exhausted);
        }
        let generation = NEXT_HANDLE
            .fetch_update(
                std::sync::atomic::Ordering::Relaxed,
                std::sync::atomic::Ordering::Relaxed,
                |value| value.checked_add(1),
            )
            .map_err(|_| UploadOperationError::Exhausted)?;
        let handle = format!("strava-upload-{generation:016x}");
        let cancellation = crate::strava::StravaCancellation::new();
        registry
            .active_by_logical
            .insert(operation_id.clone(), handle.clone());
        registry.operations.insert(
            handle.clone(),
            UploadOperationEntry {
                logical_id: operation_id,
                cancellation,
                state: UploadOperationState::Reserved,
            },
        );
        Ok(handle)
    }

    fn begin(handle: String) -> Result<Self, UploadOperationError> {
        let mut registry = upload_operations()
            .lock()
            .expect("upload operation mutex poisoned");
        let Some(entry) = registry.operations.get_mut(&handle) else {
            return Err(UploadOperationError::Invalid);
        };
        if entry.state != UploadOperationState::Reserved {
            return Err(UploadOperationError::InUse);
        }
        entry.state = UploadOperationState::Running;
        Ok(Self {
            handle,
            cancellation: entry.cancellation.clone(),
            keep_reserved: false,
        })
    }

    /// 首次 401 后保留同一代 handle，供强制刷新后的唯一一次 retry/resume 使用。
    fn reserve_for_refresh(&mut self) {
        let mut registry = upload_operations()
            .lock()
            .expect("upload operation mutex poisoned");
        if let Some(entry) = registry.operations.get_mut(&self.handle) {
            entry.state = UploadOperationState::Reserved;
            self.keep_reserved = true;
        }
    }
}

impl Drop for UploadOperation {
    fn drop(&mut self) {
        if self.keep_reserved {
            return;
        }
        let mut registry = upload_operations()
            .lock()
            .expect("upload operation mutex poisoned");
        let Some(entry) = registry.operations.remove(&self.handle) else {
            return;
        };
        if registry.active_by_logical.get(&entry.logical_id) == Some(&self.handle) {
            registry.active_by_logical.remove(&entry.logical_id);
        }
    }
}

#[cfg(test)]
mod upload_ffi_tests {
    use super::{
        StravaUploadFfiErrorCode, StravaUploadFfiStatus, UploadOperation, strava_cancel_upload,
        strava_release_upload, strava_reserve_upload, strava_upload_fit,
    };

    #[tokio::test]
    async fn maps_invalid_upload_without_network_and_releases_operation_id() {
        let response = strava_upload_fit(
            "ffi-invalid".to_owned(),
            "token".to_owned(),
            Vec::new(),
            "external".to_owned(),
            "ride.fit".to_owned(),
            false,
            None,
        )
        .await;
        assert_eq!(response.status, StravaUploadFfiStatus::Failed);
        assert_eq!(
            response.error.unwrap().code,
            StravaUploadFfiErrorCode::InvalidInput
        );
        assert!(!strava_cancel_upload("ffi-invalid".to_owned()));
    }

    #[test]
    fn cancel_handle_targets_only_live_operation_id() {
        let handle = UploadOperation::reserve("ffi-cancel".to_owned()).unwrap();
        let operation = UploadOperation::begin(handle.clone()).unwrap();
        assert!(strava_cancel_upload(handle));
        assert!(operation.cancellation.is_cancelled());
        assert!(!strava_cancel_upload("missing".to_owned()));
    }

    #[test]
    fn cancel_before_start_and_same_logical_id_generations_are_isolated() {
        let first = strava_reserve_upload("same-logical-id".to_owned()).unwrap();
        assert!(strava_cancel_upload(first.handle.clone()));
        let operation = UploadOperation::begin(first.handle.clone()).unwrap();
        assert!(operation.cancellation.is_cancelled());
        drop(operation);

        let second = strava_reserve_upload("same-logical-id".to_owned()).unwrap();
        assert_ne!(first.handle, second.handle);
        assert!(!strava_cancel_upload(first.handle));
        assert!(strava_cancel_upload(second.handle.clone()));
        assert!(strava_release_upload(second.handle));
    }

    #[test]
    fn refresh_retry_reuses_the_same_generation_once() {
        let handle = UploadOperation::reserve("ffi-refresh".to_owned()).unwrap();
        let mut first = UploadOperation::begin(handle.clone()).unwrap();
        first.reserve_for_refresh();
        drop(first);

        let retry = UploadOperation::begin(handle.clone()).unwrap();
        assert!(!retry.cancellation.is_cancelled());
        drop(retry);
        assert!(!strava_cancel_upload(handle));
    }
}
