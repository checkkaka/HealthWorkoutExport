use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fmt;

pub const APPLE_REFERENCE_UNIX_SECONDS: f64 = 978_307_200.0;
pub const MAX_RECOVERY_FIT_BYTES: usize = 64 * 1024 * 1024;
const MAX_STATE_JSON_BYTES: usize = 16 * 1024 * 1024;
const MAX_COMMAND_JSON_BYTES: usize = 1024 * 1024;
// Base64 FIT plus bounded metadata, checked before parsing unknown fields too.
const MAX_RECOVERY_JSON_BYTES: usize =
    MAX_RECOVERY_FIT_BYTES.div_ceil(3) * 4 + MAX_COMMAND_JSON_BYTES;

pub type SyncStateMap = BTreeMap<String, SyncStateRecord>;

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum SyncRecordStatus {
    Pending,
    Uploaded,
    Failed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UploadChannel {
    Api,
    Web,
    Unknown(String),
}

impl Serialize for UploadChannel {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match self {
            Self::Api => serializer.serialize_str("api"),
            Self::Web => serializer.serialize_str("web"),
            Self::Unknown(value) => serializer.serialize_str(value),
        }
    }
}

impl<'de> Deserialize<'de> for UploadChannel {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Ok(match String::deserialize(deserializer)? {
            value if value == "api" => Self::Api,
            value if value == "web" => Self::Web,
            value => Self::Unknown(value),
        })
    }
}

/// 与 Swift `SyncStateRecord` 的 Codable JSON 兼容；日期保存为 2001-01-01 起秒数。
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncStateRecord {
    pub fingerprint: String,
    pub status: SyncRecordStatus,
    pub primary_source_id: String,
    pub primary_activity_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    pub updated_at: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_date: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub supplement_source_ids: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_duplicate: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub distance_meters: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub batch_at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upload_channel: Option<UploadChannel>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_virtual_power: Option<bool>,
    /// Actual saved FIT datum provenance. None means unknown, including legacy records.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coordinates_wgs84: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recovery_batch_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upload_external_id: Option<String>,
    #[serde(
        default,
        rename = "appleHealthUUID",
        skip_serializing_if = "Option::is_none"
    )]
    pub apple_health_uuid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub apple_health_skipped: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub apple_health_error: Option<String>,
    /// 保留未来版本写入的字段，避免旧版本读写后静默丢失。
    #[serde(flatten)]
    pub unknown_fields: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UploadedStateUpdate {
    pub fingerprint: String,
    pub updated_at: f64,
    pub remote_id: Option<String>,
    pub is_duplicate: bool,
    pub distance_meters: Option<f64>,
    pub duration_seconds: Option<f64>,
    pub message: Option<String>,
    pub upload_channel: Option<UploadChannel>,
    pub has_virtual_power: Option<bool>,
    #[serde(default)]
    pub coordinates_wgs84: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recovery_batch_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upload_external_id: Option<String>,
}

/// 与 Swift `PendingResyncUpload` 的 Codable JSON 兼容；`Data` 使用标准 Base64。
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingResyncUpload {
    pub primary_source_id: String,
    pub primary_activity_id: String,
    pub title: String,
    pub start_date: f64,
    pub end_date: f64,
    pub supplement_source_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub distance_meters: Option<f64>,
    pub duration_seconds: f64,
    #[serde(with = "bounded_base64")]
    pub upload_data: Vec<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upload_message: Option<String>,
    pub filename: String,
    pub commute: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub activity_description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<RecoveryPhase>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fit_sha256: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_id_to_replace: Option<String>,
    #[serde(flatten)]
    pub unknown_fields: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecoveryPhase {
    Prepared,
    RemoteDeleted,
    Uploading,
    Unknown(String),
}

impl Serialize for RecoveryPhase {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(match self {
            Self::Prepared => "prepared",
            Self::RemoteDeleted => "remoteDeleted",
            Self::Uploading => "uploading",
            Self::Unknown(value) => value,
        })
    }
}

impl<'de> Deserialize<'de> for RecoveryPhase {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Ok(match String::deserialize(deserializer)? {
            value if value == "prepared" => Self::Prepared,
            value if value == "remoteDeleted" => Self::RemoteDeleted,
            value if value == "uploading" => Self::Uploading,
            value => Self::Unknown(value),
        })
    }
}

impl PendingResyncUpload {
    pub fn decode(bytes: &[u8]) -> Result<Self, SyncStateError> {
        if bytes.len() > MAX_RECOVERY_JSON_BYTES {
            return Err(SyncStateError::InvalidJson("恢复上传包过大".into()));
        }
        let upload: Self = serde_json::from_slice(bytes).map_err(safe_json_error)?;
        for (field, value) in [
            ("startDate", upload.start_date),
            ("endDate", upload.end_date),
        ] {
            validate_date("pending-resync", field, value)?;
        }
        if !upload.duration_seconds.is_finite()
            || upload
                .distance_meters
                .is_some_and(|value| !value.is_finite())
        {
            return Err(SyncStateError::InvalidJson("恢复上传包包含无效数值".into()));
        }
        upload.validate_transaction()?;
        Ok(upload)
    }

    pub fn encode(&self) -> Result<Vec<u8>, SyncStateError> {
        if self.upload_data.len() > MAX_RECOVERY_FIT_BYTES {
            return Err(SyncStateError::InvalidJson(
                "恢复上传 FIT 超过 64MiB".into(),
            ));
        }
        for (field, value) in [("startDate", self.start_date), ("endDate", self.end_date)] {
            validate_date("pending-resync", field, value)?;
        }
        if !self.duration_seconds.is_finite()
            || self.distance_meters.is_some_and(|value| !value.is_finite())
        {
            return Err(SyncStateError::InvalidJson("恢复上传包包含无效数值".into()));
        }
        self.validate_transaction()?;
        let bytes = serde_json::to_vec(self).map_err(safe_json_error)?;
        if bytes.len() > MAX_RECOVERY_JSON_BYTES {
            return Err(SyncStateError::InvalidJson("恢复上传包过大".into()));
        }
        Ok(bytes)
    }

    fn validate_transaction(&self) -> Result<(), SyncStateError> {
        if self.phase.is_some() && (self.external_id.is_none() || self.fit_sha256.is_none()) {
            return Err(SyncStateError::InvalidJson("恢复事务元数据不完整".into()));
        }
        if self.filename.trim().is_empty()
            || self.filename.len() > 255
            || matches!(self.filename.as_str(), "." | "..")
            || self.filename.contains(['/', '\\'])
            || self.filename.chars().any(char::is_control)
        {
            return Err(SyncStateError::InvalidJson("恢复文件名无效".into()));
        }
        if let Some(value) = &self.external_id {
            validate_bounded_text(value, 8 * 1024, "恢复 externalId 无效")?;
        }
        if let Some(value) = &self.remote_id_to_replace {
            validate_remote_id(value)?;
        }
        if let Some(expected) = &self.fit_sha256
            && (!is_valid_fingerprint(expected) || sha256_hex(&self.upload_data) != *expected)
        {
            return Err(SyncStateError::InvalidJson("恢复 FIT 哈希不匹配".into()));
        }
        // A recovery transaction can lead to remote deletion. Reject invalid bytes before
        // promoting legacy data to a prepared transaction or resuming any active phase.
        if self.phase.is_some() && !crate::fit::is_valid_fit(&self.upload_data) {
            return Err(SyncStateError::InvalidJson("恢复 FIT 文件无效".into()));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncStateError {
    InvalidJson(String),
    InvalidFingerprint,
    FingerprintMismatch,
    InvalidDate { field: &'static str },
    MissingRecord,
}

impl fmt::Display for SyncStateError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidJson(message) => write!(formatter, "同步状态 JSON 损坏：{message}"),
            Self::InvalidFingerprint => formatter.write_str("同步指纹格式无效"),
            Self::FingerprintMismatch => formatter.write_str("同步状态键与记录指纹不一致"),
            Self::InvalidDate { field } => write!(formatter, "同步记录日期字段 {field} 无效"),
            Self::MissingRecord => formatter.write_str("同步记录不存在"),
        }
    }
}

impl std::error::Error for SyncStateError {}

/// 解码旧 Swift 直接写出的顶层 map。失败时返回错误，调用方不得用空 map 覆盖原文件。
pub fn decode(bytes: &[u8]) -> Result<SyncStateMap, SyncStateError> {
    if bytes.len() > MAX_STATE_JSON_BYTES {
        return Err(SyncStateError::InvalidJson("同步状态超过 16MiB".into()));
    }
    let records: SyncStateMap = serde_json::from_slice(bytes).map_err(safe_json_error)?;
    validate(&records)?;
    Ok(records)
}

pub fn encode(records: &SyncStateMap) -> Result<Vec<u8>, SyncStateError> {
    validate(records)?;
    let bytes = serde_json::to_vec(records).map_err(safe_json_error)?;
    if bytes.len() > MAX_STATE_JSON_BYTES {
        return Err(SyncStateError::InvalidJson("同步状态超过 16MiB".into()));
    }
    Ok(bytes)
}

#[derive(Deserialize)]
#[serde(
    tag = "operation",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum SyncStateCommand {
    Validate,
    MarkPending {
        record: SyncStateRecord,
    },
    MarkUploaded {
        update: UploadedStateUpdate,
    },
    MarkDeduped {
        fingerprint: String,
        updated_at: f64,
        reason: String,
        remote_id: Option<String>,
    },
    MarkFailed {
        fingerprint: String,
        updated_at: f64,
        message: String,
    },
    SetRemoteId {
        fingerprint: String,
        remote_id: String,
        updated_at: f64,
    },
    MarkAppleHealthWritten {
        fingerprint: String,
        uuid: String,
        updated_at: f64,
    },
    MarkAppleHealthSkipped {
        fingerprint: String,
        updated_at: f64,
    },
    MarkAppleHealthFailed {
        fingerprint: String,
        message: String,
        updated_at: f64,
    },
    Remove {
        fingerprint: String,
    },
    Clear,
}

#[derive(Deserialize)]
#[serde(
    tag = "operation",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum RecoveryCommand {
    Validate,
    Prepare {
        external_id: String,
        remote_id_to_replace: Option<String>,
    },
    MarkRemoteDeleted,
    MarkUploading,
    RenewExternalId {
        expected_external_id: String,
        next_external_id: String,
    },
}

/// 单次完成解码、校验、状态转换和重编码；任一步失败都不产生可写回的字节。
pub fn apply(state_json: &[u8], command_json: &[u8]) -> Result<Vec<u8>, SyncStateError> {
    if command_json.len() > MAX_COMMAND_JSON_BYTES {
        return Err(SyncStateError::InvalidJson("同步命令超过 1MiB".into()));
    }
    let mut records = decode(state_json)?;
    let command: SyncStateCommand =
        serde_json::from_slice(command_json).map_err(safe_json_error)?;
    match command {
        SyncStateCommand::Validate => {}
        SyncStateCommand::MarkPending { record } => mark_pending(&mut records, record)?,
        SyncStateCommand::MarkUploaded { update } => mark_uploaded(&mut records, update)?,
        SyncStateCommand::MarkDeduped {
            fingerprint,
            updated_at,
            reason,
            remote_id,
        } => mark_deduped(&mut records, &fingerprint, updated_at, reason, remote_id)?,
        SyncStateCommand::MarkFailed {
            fingerprint,
            updated_at,
            message,
        } => mark_failed(&mut records, &fingerprint, updated_at, message)?,
        SyncStateCommand::SetRemoteId {
            fingerprint,
            remote_id,
            updated_at,
        } => {
            set_remote_id(&mut records, &fingerprint, &remote_id, updated_at)?;
        }
        SyncStateCommand::MarkAppleHealthWritten {
            fingerprint,
            uuid,
            updated_at,
        } => {
            if !valid_health_uuid(&uuid) {
                return Err(SyncStateError::InvalidJson("Apple Health UUID 无效".into()));
            }
            let record = health_record(&mut records, &fingerprint, updated_at)?;
            record.apple_health_uuid = Some(uuid);
            record.apple_health_skipped = None;
            record.apple_health_error = None;
        }
        SyncStateCommand::MarkAppleHealthSkipped {
            fingerprint,
            updated_at,
        } => {
            let record = health_record(&mut records, &fingerprint, updated_at)?;
            record.apple_health_skipped = Some(true);
            record.apple_health_error = None;
        }
        SyncStateCommand::MarkAppleHealthFailed {
            fingerprint,
            message,
            updated_at,
        } => {
            if message.len() > 8 * 1024
                || message
                    .chars()
                    .any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t'))
            {
                return Err(SyncStateError::InvalidJson(
                    "Apple Health 错误消息无效".into(),
                ));
            }
            let record = health_record(&mut records, &fingerprint, updated_at)?;
            record.apple_health_error = Some(message);
        }
        SyncStateCommand::Remove { fingerprint } => {
            validate_fingerprint(&fingerprint)?;
            records.remove(&fingerprint);
        }
        SyncStateCommand::Clear => records.clear(),
    }
    encode(&records)
}

/// 原子执行恢复事务迁移；旧 JSON 首次 prepare 后才获得稳定事务元数据。
pub fn apply_recovery(
    recovery_json: &[u8],
    command_json: &[u8],
) -> Result<Vec<u8>, SyncStateError> {
    if command_json.len() > MAX_COMMAND_JSON_BYTES {
        return Err(SyncStateError::InvalidJson("恢复命令超过 1MiB".into()));
    }
    let mut recovery = PendingResyncUpload::decode(recovery_json)?;
    let command: RecoveryCommand = serde_json::from_slice(command_json).map_err(safe_json_error)?;
    match command {
        RecoveryCommand::Validate => {}
        RecoveryCommand::Prepare {
            external_id,
            remote_id_to_replace,
        } => match recovery.phase {
            None => {
                validate_bounded_text(&external_id, 8 * 1024, "恢复 externalId 无效")?;
                if let Some(value) = &remote_id_to_replace {
                    validate_remote_id(value)?;
                }
                recovery.phase = Some(RecoveryPhase::Prepared);
                recovery.external_id = Some(external_id);
                recovery.fit_sha256 = Some(sha256_hex(&recovery.upload_data));
                recovery.remote_id_to_replace = remote_id_to_replace;
            }
            Some(
                RecoveryPhase::Prepared | RecoveryPhase::RemoteDeleted | RecoveryPhase::Uploading,
            ) => require_complete_transaction(&recovery)?,
            Some(RecoveryPhase::Unknown(_)) => {
                return Err(SyncStateError::InvalidJson("未知恢复事务阶段".into()));
            }
        },
        RecoveryCommand::MarkRemoteDeleted => {
            require_complete_transaction(&recovery)?;
            recovery.phase = match recovery.phase {
                Some(RecoveryPhase::Prepared | RecoveryPhase::RemoteDeleted) => {
                    Some(RecoveryPhase::RemoteDeleted)
                }
                Some(RecoveryPhase::Uploading) => Some(RecoveryPhase::Uploading),
                _ => return Err(SyncStateError::InvalidJson("恢复事务尚未准备".into())),
            };
        }
        RecoveryCommand::MarkUploading => {
            require_complete_transaction(&recovery)?;
            recovery.phase = match recovery.phase {
                Some(RecoveryPhase::Prepared) if recovery.remote_id_to_replace.is_none() => {
                    Some(RecoveryPhase::Uploading)
                }
                Some(RecoveryPhase::RemoteDeleted | RecoveryPhase::Uploading) => {
                    Some(RecoveryPhase::Uploading)
                }
                Some(RecoveryPhase::Prepared) => {
                    return Err(SyncStateError::InvalidJson("远端删除尚未持久化".into()));
                }
                _ => return Err(SyncStateError::InvalidJson("恢复事务尚未准备".into())),
            };
        }
        RecoveryCommand::RenewExternalId {
            expected_external_id,
            next_external_id,
        } => {
            require_complete_transaction(&recovery)?;
            if recovery.phase != Some(RecoveryPhase::Uploading)
                || recovery.remote_id_to_replace.is_none()
            {
                return Err(SyncStateError::InvalidJson(
                    "仅可更新上传中的远端替换事务".into(),
                ));
            }
            if recovery.external_id.as_deref() != Some(expected_external_id.as_str()) {
                return Err(SyncStateError::InvalidJson("恢复 externalId 已变化".into()));
            }
            validate_bounded_text(&next_external_id, 8 * 1024, "恢复 externalId 无效")?;
            if next_external_id.chars().any(char::is_control) {
                return Err(SyncStateError::InvalidJson("恢复 externalId 无效".into()));
            }
            // The upload client trims external IDs. Whitespace cannot produce a new
            // server key, and the persisted ID must equal the one sent on retry.
            let next_external_id = next_external_id.trim();
            if recovery.external_id.as_deref().map(str::trim) == Some(next_external_id) {
                return Err(SyncStateError::InvalidJson(
                    "恢复 externalId 必须更新".into(),
                ));
            }
            recovery.external_id = Some(next_external_id.to_owned());
        }
    }
    recovery.encode()
}

/// 只有完整解码和校验成功才替换内存状态，损坏文件不会把已有记录变成空库。
pub fn replace_from_bytes(records: &mut SyncStateMap, bytes: &[u8]) -> Result<(), SyncStateError> {
    let decoded = decode(bytes)?;
    *records = decoded;
    Ok(())
}

pub fn is_valid_fingerprint(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub fn apple_reference_seconds_from_unix(unix_seconds: f64) -> Option<f64> {
    unix_seconds
        .is_finite()
        .then_some(unix_seconds - APPLE_REFERENCE_UNIX_SECONDS)
}

pub fn unix_seconds_from_apple_reference(reference_seconds: f64) -> Option<f64> {
    reference_seconds
        .is_finite()
        .then_some(reference_seconds + APPLE_REFERENCE_UNIX_SECONDS)
}

pub fn mark_pending(
    records: &mut SyncStateMap,
    mut record: SyncStateRecord,
) -> Result<(), SyncStateError> {
    // A Strava retry must not erase the independent, already-completed Health import.
    if let Some(previous) = records.get(&record.fingerprint) {
        record.coordinates_wgs84 = record.coordinates_wgs84.or(previous.coordinates_wgs84);
        record.apple_health_uuid = record
            .apple_health_uuid
            .or_else(|| previous.apple_health_uuid.clone());
        record.apple_health_skipped = record
            .apple_health_skipped
            .or(previous.apple_health_skipped);
        record.apple_health_error = record
            .apple_health_error
            .or_else(|| previous.apple_health_error.clone());
    }
    if let Some(previous) = records.get(&record.fingerprint) {
        record.recovery_batch_id = record
            .recovery_batch_id
            .or_else(|| previous.recovery_batch_id.clone());
        record.upload_external_id = record
            .upload_external_id
            .or_else(|| previous.upload_external_id.clone());
    }
    record.status = SyncRecordStatus::Pending;
    record.remote_id = None;
    record.message = None;
    record.is_duplicate = None;
    // The caller supplies the newly prepared upload's channel and power provenance.
    // Preserve them across crashes; only remote outcome fields are reset.
    validate_record(&record.fingerprint, &record)?;
    records.insert(record.fingerprint.clone(), record);
    Ok(())
}

pub fn mark_uploaded(
    records: &mut SyncStateMap,
    update: UploadedStateUpdate,
) -> Result<(), SyncStateError> {
    let fingerprint = &update.fingerprint;
    validate_fingerprint(fingerprint)?;
    validate_date(fingerprint, "updatedAt", update.updated_at)?;
    if update
        .distance_meters
        .is_some_and(|value| !value.is_finite())
    {
        return Err(SyncStateError::InvalidJson("distanceMeters 无效".into()));
    }
    if update
        .duration_seconds
        .is_some_and(|value| !value.is_finite())
    {
        return Err(SyncStateError::InvalidJson("durationSeconds 无效".into()));
    }
    if update.recovery_batch_id.is_some() != update.upload_external_id.is_some() {
        return Err(SyncStateError::InvalidJson(
            "上传恢复证明必须完整提供".into(),
        ));
    }
    if let Some(batch) = &update.recovery_batch_id {
        validate_fingerprint(batch)?;
    }
    if let Some(external) = &update.upload_external_id {
        validate_bounded_text(external, 8 * 1024, "上传恢复 externalId 无效")?;
    }
    let record = records
        .get_mut(fingerprint)
        .ok_or(SyncStateError::MissingRecord)?;
    record.status = SyncRecordStatus::Uploaded;
    record.updated_at = update.updated_at;
    record.remote_id = update.remote_id;
    record.is_duplicate = Some(update.is_duplicate);
    record.message = update
        .message
        .or_else(|| update.is_duplicate.then(|| "去重跳过".to_owned()));
    if let Some(value) = update.distance_meters {
        record.distance_meters = Some(value);
    }
    if let Some(value) = update.duration_seconds {
        record.duration_seconds = Some(value);
    }
    if let Some(value) = update.upload_channel {
        record.upload_channel = Some(value);
    }
    if let Some(value) = update.has_virtual_power {
        record.has_virtual_power = Some(value);
    }
    if let Some(value) = update.coordinates_wgs84 {
        record.coordinates_wgs84 = Some(value);
    }
    if let Some(batch) = update.recovery_batch_id {
        record.recovery_batch_id = Some(batch);
    }
    if let Some(external) = update.upload_external_id {
        record.upload_external_id = Some(external);
    }
    Ok(())
}

pub fn mark_deduped(
    records: &mut SyncStateMap,
    fingerprint: &str,
    updated_at: f64,
    reason: String,
    remote_id: Option<String>,
) -> Result<(), SyncStateError> {
    validate_fingerprint(fingerprint)?;
    validate_date(fingerprint, "updatedAt", updated_at)?;
    let record = records
        .get_mut(fingerprint)
        .ok_or(SyncStateError::MissingRecord)?;
    record.status = SyncRecordStatus::Uploaded;
    record.updated_at = updated_at;
    record.is_duplicate = Some(true);
    record.message = Some(reason);
    if let Some(value) = remote_id {
        record.remote_id = Some(value);
    }
    Ok(())
}

pub fn mark_failed(
    records: &mut SyncStateMap,
    fingerprint: &str,
    updated_at: f64,
    message: String,
) -> Result<(), SyncStateError> {
    validate_fingerprint(fingerprint)?;
    validate_date(fingerprint, "updatedAt", updated_at)?;
    let record = records
        .get_mut(fingerprint)
        .ok_or(SyncStateError::MissingRecord)?;
    record.status = SyncRecordStatus::Failed;
    record.updated_at = updated_at;
    record.message = Some(message);
    Ok(())
}

/// Backfill one missing ID atomically without changing the upload result or provenance.
pub fn set_remote_id(
    records: &mut SyncStateMap,
    fingerprint: &str,
    remote_id: &str,
    updated_at: f64,
) -> Result<(), SyncStateError> {
    validate_fingerprint(fingerprint)?;
    validate_remote_id(remote_id)?;
    validate_date(fingerprint, "updatedAt", updated_at)?;
    let target = records
        .get(fingerprint)
        .ok_or(SyncStateError::MissingRecord)?;
    if target
        .remote_id
        .as_deref()
        .is_some_and(|existing| validate_remote_id(existing).is_ok() && existing != remote_id)
    {
        return Err(SyncStateError::InvalidJson("记录已有不同远端 ID".into()));
    }
    if records
        .iter()
        .any(|(key, record)| key != fingerprint && record.remote_id.as_deref() == Some(remote_id))
    {
        return Err(SyncStateError::InvalidJson("远端 ID 已用于另一记录".into()));
    }
    let target = records
        .get_mut(fingerprint)
        .ok_or(SyncStateError::MissingRecord)?;
    target.remote_id = Some(remote_id.to_owned());
    target.updated_at = updated_at;
    Ok(())
}

fn health_record<'a>(
    records: &'a mut SyncStateMap,
    fingerprint: &str,
    updated_at: f64,
) -> Result<&'a mut SyncStateRecord, SyncStateError> {
    validate_fingerprint(fingerprint)?;
    validate_date(fingerprint, "updatedAt", updated_at)?;
    let record = records
        .get_mut(fingerprint)
        .ok_or(SyncStateError::MissingRecord)?;
    record.updated_at = updated_at;
    Ok(record)
}

fn valid_health_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, b)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

fn validate(records: &SyncStateMap) -> Result<(), SyncStateError> {
    for (fingerprint, record) in records {
        validate_record(fingerprint, record)?;
    }
    Ok(())
}

fn validate_record(key: &str, record: &SyncStateRecord) -> Result<(), SyncStateError> {
    validate_fingerprint(key)?;
    validate_fingerprint(&record.fingerprint)?;
    if key != record.fingerprint {
        return Err(SyncStateError::FingerprintMismatch);
    }
    validate_date(key, "updatedAt", record.updated_at)?;
    if let Some(batch) = &record.recovery_batch_id {
        validate_fingerprint(batch)?;
    }
    if let Some(external) = &record.upload_external_id {
        validate_bounded_text(external, 8 * 1024, "上传恢复 externalId 无效")?;
    }

    for (field, value) in [
        ("startDate", record.start_date),
        ("batchAt", record.batch_at),
    ] {
        if let Some(value) = value {
            validate_date(key, field, value)?;
        }
    }
    if [record.distance_meters, record.duration_seconds]
        .into_iter()
        .flatten()
        .any(|value| !value.is_finite())
    {
        return Err(SyncStateError::InvalidJson("同步记录包含无效数值".into()));
    }
    Ok(())
}

fn validate_fingerprint(value: &str) -> Result<(), SyncStateError> {
    is_valid_fingerprint(value)
        .then_some(())
        .ok_or(SyncStateError::InvalidFingerprint)
}

fn validate_date(
    _fingerprint: &str,
    field: &'static str,
    value: f64,
) -> Result<(), SyncStateError> {
    value
        .is_finite()
        .then_some(())
        .ok_or(SyncStateError::InvalidDate { field })
}

/// serde data errors may include the rejected value, including private workout metadata.
fn safe_json_error(error: serde_json::Error) -> SyncStateError {
    SyncStateError::InvalidJson(format!(
        "格式错误（行 {}，列 {}）",
        error.line(),
        error.column()
    ))
}

fn validate_remote_id(value: &str) -> Result<(), SyncStateError> {
    if value.is_empty() || value.len() > 32 || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(SyncStateError::InvalidJson("恢复远端 ID 无效".into()));
    }
    Ok(())
}

fn require_complete_transaction(recovery: &PendingResyncUpload) -> Result<(), SyncStateError> {
    if recovery.external_id.is_none() || recovery.fit_sha256.is_none() {
        return Err(SyncStateError::InvalidJson("恢复事务元数据不完整".into()));
    }
    recovery.validate_transaction()
}

fn validate_bounded_text(
    value: &str,
    max_bytes: usize,
    message: &'static str,
) -> Result<(), SyncStateError> {
    if value.trim().is_empty()
        || value.len() > max_bytes
        || value.bytes().any(|byte| byte.is_ascii_control())
    {
        return Err(SyncStateError::InvalidJson(message.into()));
    }
    Ok(())
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut value = String::with_capacity(64);
    for byte in Sha256::digest(bytes) {
        use std::fmt::Write as _;
        write!(&mut value, "{byte:02x}").expect("writing to String cannot fail");
    }
    value
}

mod bounded_base64 {
    use super::MAX_RECOVERY_FIT_BYTES;
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    use serde::{Deserialize, Deserializer, Serializer, de::Error as _};

    pub fn serialize<S>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        if bytes.len() > MAX_RECOVERY_FIT_BYTES {
            return Err(serde::ser::Error::custom("恢复上传 FIT 超过 64MiB"));
        }
        serializer.serialize_str(&STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let encoded = String::deserialize(deserializer)?;
        if !encoded_len_is_within_limit(encoded.len()) {
            return Err(D::Error::custom("恢复上传 FIT 超过 64MiB"));
        }
        let bytes = STANDARD.decode(encoded).map_err(D::Error::custom)?;
        if bytes.len() > MAX_RECOVERY_FIT_BYTES {
            return Err(D::Error::custom("恢复上传 FIT 超过 64MiB"));
        }
        Ok(bytes)
    }

    pub(super) fn encoded_len_is_within_limit(len: usize) -> bool {
        len <= MAX_RECOVERY_FIT_BYTES.div_ceil(3) * 4
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fingerprint(byte: char) -> String {
        std::iter::repeat_n(byte, 64).collect()
    }

    fn record(fingerprint: String) -> SyncStateRecord {
        SyncStateRecord {
            fingerprint,
            status: SyncRecordStatus::Pending,
            primary_source_id: "healthkit".into(),
            primary_activity_id: "activity-1".into(),
            remote_id: None,
            message: None,
            updated_at: 721_692_800.0,
            start_date: None,
            title: None,
            supplement_source_ids: None,
            is_duplicate: None,
            distance_meters: None,
            duration_seconds: None,
            batch_at: None,
            upload_channel: None,
            has_virtual_power: None,
            coordinates_wgs84: None,
            recovery_batch_id: None,
            upload_external_id: None,
            apple_health_uuid: None,
            apple_health_skipped: None,
            apple_health_error: None,
            unknown_fields: BTreeMap::new(),
        }
    }

    #[test]
    fn uploaded_recovery_proof_is_atomic_and_pending_cannot_masquerade_as_complete() {
        let key = fingerprint('a');
        let pending = encode(&SyncStateMap::from([(key.clone(), record(key.clone()))])).unwrap();
        let update = json!({"operation":"markUploaded","update":{
            "fingerprint":key,"updatedAt":123.0,"isDuplicate":false,"remoteId":"456",
            "recoveryBatchId":fingerprint('b'),"uploadExternalId":"saved-external-id"
        }});
        let uploaded = apply(&pending, &serde_json::to_vec(&update).unwrap()).unwrap();
        let decoded: Value = serde_json::from_slice(&uploaded).unwrap();
        assert_eq!(decoded[&key]["recoveryBatchId"], fingerprint('b'));
        assert_eq!(decoded[&key]["uploadExternalId"], "saved-external-id");
        assert_eq!(decoded[&key]["status"], "uploaded");
        assert_eq!(decoded[&key]["remoteId"], "456");
        let next = apply(
            &uploaded,
            &serde_json::to_vec(&json!({"operation":"markPending","record":record(key.clone())}))
                .unwrap(),
        )
        .unwrap();
        let next: Value = serde_json::from_slice(&next).unwrap();
        assert_eq!(next[&key]["status"], "pending");
        assert_eq!(next[&key]["recoveryBatchId"], fingerprint('b'));
        assert_eq!(next[&key]["uploadExternalId"], "saved-external-id");
    }

    #[test]
    fn uploaded_proof_rejects_partial_invalid_or_control_character_values() {
        let key = fingerprint('a');
        let pending = encode(&SyncStateMap::from([(key.clone(), record(key.clone()))])).unwrap();
        for (batch, external) in [
            (Some(fingerprint('b')), None),
            (None, Some("id".to_owned())),
            (Some("invalid".to_owned()), Some("id".to_owned())),
            (Some(fingerprint('b')), Some("bad\nid".to_owned())),
            (Some(fingerprint('b')), Some(" ".to_owned())),
            (Some(fingerprint('b')), Some("x".repeat(8193))),
        ] {
            let update = json!({"operation":"markUploaded","update":{
                "fingerprint":key,"updatedAt":123.0,"isDuplicate":false,
                "recoveryBatchId":batch,"uploadExternalId":external
            }});
            assert!(apply(&pending, &serde_json::to_vec(&update).unwrap()).is_err());
        }
    }

    #[test]
    fn uploaded_coordinate_provenance_updates_only_when_explicitly_supplied() {
        let key = fingerprint('a');
        let mut bytes = encode(&SyncStateMap::from([(key.clone(), record(key.clone()))])).unwrap();
        let mut update = json!({"operation":"markUploaded","update":{
            "fingerprint":key,"updatedAt":123.0,"isDuplicate":false,"coordinatesWgs84":true
        }});
        bytes = apply(&bytes, &serde_json::to_vec(&update).unwrap()).unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&bytes).unwrap()[&key]["coordinatesWgs84"],
            true
        );
        update["update"]
            .as_object_mut()
            .unwrap()
            .remove("coordinatesWgs84");
        bytes = apply(&bytes, &serde_json::to_vec(&update).unwrap()).unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&bytes).unwrap()[&key]["coordinatesWgs84"],
            true
        );
        update["update"]["coordinatesWgs84"] = json!(false);
        bytes = apply(&bytes, &serde_json::to_vec(&update).unwrap()).unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&bytes).unwrap()[&key]["coordinatesWgs84"],
            false
        );
    }

    #[test]
    fn pending_retry_preserves_coordinate_provenance_and_legacy_absence() {
        let key = fingerprint('a');
        let legacy = encode(&SyncStateMap::from([(key.clone(), record(key.clone()))])).unwrap();
        let roundtrip = encode(&decode(&legacy).unwrap()).unwrap();
        assert!(
            serde_json::from_slice::<Value>(&roundtrip).unwrap()[&key]
                .get("coordinatesWgs84")
                .is_none()
        );
        let mut confirmed: Value = serde_json::from_slice(&legacy).unwrap();
        confirmed[&key]["coordinatesWgs84"] = json!(true);
        let mut records = decode(&serde_json::to_vec(&confirmed).unwrap()).unwrap();
        mark_pending(&mut records, record(key.clone())).unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&encode(&records).unwrap()).unwrap()[&key]["coordinatesWgs84"],
            true
        );
    }

    #[test]
    fn health_outcomes_preserve_strava_status_and_follow_swift_field_semantics() {
        let key = fingerprint('a');
        let mut item = record(key.clone());
        item.status = SyncRecordStatus::Uploaded;
        item.remote_id = Some("123".into());
        item.message = Some("existing Strava outcome".into());
        let mut bytes = encode(&SyncStateMap::from([(key.clone(), item.clone())])).unwrap();
        let mut command = |operation: &str, extra: Value| {
            let mut value = json!({"operation":operation,"fingerprint":key,"updatedAt":123.0});
            value
                .as_object_mut()
                .unwrap()
                .extend(extra.as_object().unwrap().clone());
            bytes = apply(&bytes, &serde_json::to_vec(&value).unwrap()).unwrap();
            decode(&bytes).unwrap()[&key].clone()
        };
        let failed = command(
            "markAppleHealthFailed",
            json!({"message":"permission denied"}),
        );
        assert_eq!(
            failed.apple_health_error.as_deref(),
            Some("permission denied")
        );
        assert_eq!(failed.status, item.status);
        assert_eq!(failed.message, item.message);
        assert_eq!(failed.remote_id, item.remote_id);
        let skipped = command("markAppleHealthSkipped", json!({}));
        assert_eq!(skipped.apple_health_skipped, Some(true));
        assert!(skipped.apple_health_error.is_none());
        let uuid = "12345678-1234-1234-ABCD-123456789ABC";
        let written = command("markAppleHealthWritten", json!({"uuid":uuid}));
        assert_eq!(written.apple_health_uuid.as_deref(), Some(uuid));
        assert!(written.apple_health_skipped.is_none());
        assert!(written.apple_health_error.is_none());
        assert_eq!(written.status, item.status);
        assert_eq!(written.remote_id, item.remote_id);
        assert_eq!(written.message, item.message);
        assert_eq!(written.updated_at, 123.0);
        let json: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(json[&key]["appleHealthUUID"], uuid);
        assert!(json[&key].get("appleHealthUuid").is_none());
    }

    #[test]
    fn strava_retry_preserves_existing_health_outcome() {
        let key = fingerprint('a');
        let mut item = record(key.clone());
        item.apple_health_uuid = Some("12345678-1234-1234-ABCD-123456789ABC".into());
        item.apple_health_skipped = Some(false);
        item.apple_health_error = Some("route unavailable".into());
        let mut records = SyncStateMap::from([(key.clone(), item.clone())]);
        mark_pending(&mut records, record(key.clone())).unwrap();
        assert_eq!(records[&key].apple_health_uuid, item.apple_health_uuid);
        assert_eq!(
            records[&key].apple_health_skipped,
            item.apple_health_skipped
        );
        assert_eq!(records[&key].apple_health_error, item.apple_health_error);
    }

    #[test]
    fn health_commands_reject_invalid_uuid_missing_record_and_oversize_error_atomically() {
        let key = fingerprint('a');
        let bytes = encode(&SyncStateMap::from([(key.clone(), record(key.clone()))])).unwrap();
        for command in [
            json!({"operation":"markAppleHealthWritten","fingerprint":key,"uuid":"not-a-uuid","updatedAt":1}),
            json!({"operation":"markAppleHealthSkipped","fingerprint":fingerprint('b'),"updatedAt":1}),
            json!({"operation":"markAppleHealthFailed","fingerprint":key,"message":"x".repeat(8193),"updatedAt":1}),
            json!({"operation":"markAppleHealthFailed","fingerprint":key,"message":"bad\u{0}error","updatedAt":1}),
        ] {
            assert!(apply(&bytes, &serde_json::to_vec(&command).unwrap()).is_err());
        }
        assert_eq!(decode(&bytes).unwrap()[&key].updated_at, 721_692_800.0);
    }

    #[test]
    fn swift_map_round_trip_keeps_reference_dates_optional_and_unknown_fields() {
        let key = fingerprint('a');
        let bytes = serde_json::to_vec(&json!({
            key.clone(): {
                "fingerprint": key,
                "status": "uploaded",
                "primarySourceId": "healthkit",
                "primaryActivityId": "activity-1",
                "updatedAt": 721692800.0,
                "startDate": 721692700.5,
                "uploadChannel": "future-channel",
                "hasVirtualPower": true,
                "futureField": {"kept": true}
            }
        }))
        .unwrap();

        let decoded = decode(&bytes).unwrap();
        let item = decoded.values().next().unwrap();
        assert_eq!(item.remote_id, None);
        assert_eq!(
            item.upload_channel,
            Some(UploadChannel::Unknown("future-channel".into()))
        );
        assert_eq!(item.unknown_fields["futureField"], json!({"kept": true}));
        assert_eq!(decode(&encode(&decoded).unwrap()).unwrap(), decoded);
        assert_eq!(
            unix_seconds_from_apple_reference(item.updated_at),
            Some(1_700_000_000.0)
        );
        assert_eq!(
            apple_reference_seconds_from_unix(1_700_000_000.0),
            Some(721_692_800.0)
        );
    }

    #[test]
    fn corrupt_or_invalid_state_never_replaces_existing_records() {
        let key = fingerprint('b');
        let mut records = SyncStateMap::from([(key.clone(), record(key))]);
        assert!(replace_from_bytes(&mut records, br#"{"broken"#).is_err());
        assert_eq!(records.len(), 1);

        for invalid in ["deadbeef".to_owned(), fingerprint('A'), fingerprint('g')] {
            let mut value = record(invalid.clone());
            value.fingerprint = invalid.clone();
            assert!(matches!(
                mark_pending(&mut records, value),
                Err(SyncStateError::InvalidFingerprint)
            ));
        }
        assert_eq!(records.len(), 1);
    }

    #[test]
    fn state_transitions_require_an_existing_valid_record() {
        let key = fingerprint('c');
        let mut records = SyncStateMap::new();
        let mut item = record(key.clone());
        item.status = SyncRecordStatus::Failed;
        item.remote_id = Some("old".into());
        item.message = Some("old".into());
        item.is_duplicate = Some(true);
        item.upload_channel = Some(UploadChannel::Web);
        item.has_virtual_power = Some(true);
        mark_pending(&mut records, item).unwrap();
        assert_eq!(records[&key].status, SyncRecordStatus::Pending);
        assert_eq!(records[&key].remote_id, None);
        assert_eq!(records[&key].message, None);
        assert_eq!(records[&key].is_duplicate, None);
        assert_eq!(records[&key].upload_channel, Some(UploadChannel::Web));
        assert_eq!(records[&key].has_virtual_power, Some(true));

        mark_uploaded(
            &mut records,
            UploadedStateUpdate {
                fingerprint: key.clone(),
                updated_at: 721_692_801.0,
                remote_id: Some("123".into()),
                is_duplicate: true,
                distance_meters: Some(10_000.0),
                duration_seconds: Some(3_600.0),
                message: None,
                upload_channel: Some(UploadChannel::Api),
                has_virtual_power: Some(true),
                coordinates_wgs84: None,
                recovery_batch_id: None,
                upload_external_id: None,
            },
        )
        .unwrap();
        assert_eq!(records[&key].status, SyncRecordStatus::Uploaded);
        assert_eq!(records[&key].message.as_deref(), Some("去重跳过"));
        assert_eq!(records[&key].upload_channel, Some(UploadChannel::Api));
        assert_eq!(records[&key].has_virtual_power, Some(true));

        mark_deduped(
            &mut records,
            &key,
            721_692_801.5,
            "后台 duplicate".into(),
            Some("456".into()),
        )
        .unwrap();
        assert_eq!(records[&key].remote_id.as_deref(), Some("456"));
        assert_eq!(records[&key].message.as_deref(), Some("后台 duplicate"));

        mark_failed(&mut records, &key, 721_692_802.0, "失败".into()).unwrap();
        assert_eq!(records[&key].status, SyncRecordStatus::Failed);
        let missing = fingerprint('d');
        assert!(matches!(
            mark_failed(&mut records, &missing, 0.0, "失败".into()),
            Err(SyncStateError::MissingRecord)
        ));
        assert!(!records.contains_key(&missing));
    }

    #[test]
    fn pending_resync_matches_swift_base64_and_enforces_fit_limit() {
        let bytes = r#"{
            "primarySourceId":"healthkit",
            "primaryActivityId":"activity-1",
            "title":"恢复",
            "startDate":721692800,
            "endDate":721696400,
            "supplementSourceIds":["xingzhe"],
            "durationSeconds":3600,
            "uploadData":"AQID",
            "filename":"activity.fit",
            "commute":false,
            "futureRecoveryField":42
        }"#;
        let upload = PendingResyncUpload::decode(bytes.as_bytes()).unwrap();
        assert_eq!(upload.upload_data, [1, 2, 3]);
        assert_eq!(upload.activity_description, None);
        assert_eq!(upload.unknown_fields["futureRecoveryField"], json!(42));
        let encoded = String::from_utf8(upload.encode().unwrap()).unwrap();
        assert!(encoded.contains(r#""uploadData":"AQID""#));
        assert!(PendingResyncUpload::decode(encoded.as_bytes()).is_ok());

        assert!(bounded_base64::encoded_len_is_within_limit(
            MAX_RECOVERY_FIT_BYTES.div_ceil(3) * 4
        ));
        assert!(!bounded_base64::encoded_len_is_within_limit(
            MAX_RECOVERY_FIT_BYTES.div_ceil(3) * 4 + 1
        ));
        let mut oversized = upload;
        oversized.upload_data = vec![0; MAX_RECOVERY_FIT_BYTES + 1];
        assert!(oversized.encode().is_err());
    }

    #[test]
    fn atomic_apply_transitions_and_redacts_invalid_fingerprints() {
        let key = fingerprint('e');
        let pending = json!({
            "operation": "markPending",
            "record": {
                "fingerprint": key,
                "status": "failed",
                "primarySourceId": "healthkit",
                "primaryActivityId": "activity-1",
                "updatedAt": 721692800.0,
                "remoteId": "must-clear",
                "message": "must-clear",
                "isDuplicate": true,
                "uploadChannel": "web",
                "hasVirtualPower": true
            }
        });
        let state = apply(b"{}", &serde_json::to_vec(&pending).unwrap()).unwrap();
        let decoded = decode(&state).unwrap();
        assert_eq!(decoded[&key].status, SyncRecordStatus::Pending);
        assert_eq!(decoded[&key].remote_id, None);

        let failed = json!({
            "operation": "markFailed",
            "fingerprint": key,
            "updatedAt": 721692801.0,
            "message": "network"
        });
        let state = apply(&state, &serde_json::to_vec(&failed).unwrap()).unwrap();
        assert_eq!(
            decode(&state).unwrap()[&key].status,
            SyncRecordStatus::Failed
        );

        let secret = "illegal-fingerprint-must-not-leak";
        let invalid = json!({
            "operation": "remove",
            "fingerprint": secret
        });
        let error = apply(&state, &serde_json::to_vec(&invalid).unwrap()).unwrap_err();
        assert_eq!(error.to_string(), "同步指纹格式无效");
        assert!(!format!("{error:?}").contains(secret));
    }

    #[test]
    fn recovery_transaction_is_monotonic_idempotent_and_keeps_external_id() {
        let legacy = br#"{
          "primarySourceId":"healthkit","primaryActivityId":"activity-1","title":"recovery",
          "startDate":721692800,"endDate":721696400,"supplementSourceIds":[],
          "durationSeconds":3600,"uploadData":"AQID","filename":"activity.fit","commute":false,
          "futureField":"kept"
        }"#;
        let mut legacy: Value = serde_json::from_slice(legacy).unwrap();
        legacy["uploadData"] = Value::String(base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            valid_recovery_fit(),
        ));
        let legacy = serde_json::to_vec(&legacy).unwrap();
        let prepare = br#"{"operation":"prepare","externalId":"stable-external-id","remoteIdToReplace":"123"}"#;
        let prepared = apply_recovery(&legacy, prepare).unwrap();
        let prepared_again = apply_recovery(&prepared, prepare).unwrap();
        assert_eq!(prepared_again, prepared);
        let value: Value = serde_json::from_slice(&prepared).unwrap();
        assert_eq!(value["phase"], "prepared");
        assert_eq!(value["externalId"], "stable-external-id");
        assert_eq!(value["fitSha256"].as_str().unwrap().len(), 64);
        assert_eq!(value["futureField"], "kept");
        assert!(apply_recovery(&prepared, br#"{"operation":"markUploading"}"#).is_err());

        let deleted = apply_recovery(&prepared, br#"{"operation":"markRemoteDeleted"}"#).unwrap();
        let uploading = apply_recovery(&deleted, br#"{"operation":"markUploading"}"#).unwrap();
        let uploading_again =
            apply_recovery(&uploading, br#"{"operation":"markUploading"}"#).unwrap();
        assert_eq!(uploading_again, uploading);
        let value: Value = serde_json::from_slice(&uploading).unwrap();
        assert_eq!(value["phase"], "uploading");
        assert_eq!(value["externalId"], "stable-external-id");

        let mut tampered: Value = serde_json::from_slice(&uploading).unwrap();
        tampered["uploadData"] = Value::String("BAUG".into());
        assert!(
            apply_recovery(
                &serde_json::to_vec(&tampered).unwrap(),
                br#"{"operation":"validate"}"#
            )
            .is_err()
        );
    }
    #[test]
    fn state_cannot_encode_a_file_its_decoder_would_reject_as_oversized() {
        let key = fingerprint('f');
        let mut item = record(key.clone());
        item.unknown_fields.insert(
            "largeMetadata".into(),
            Value::String("x".repeat(MAX_STATE_JSON_BYTES)),
        );
        let records = SyncStateMap::from([(key, item)]);
        assert!(encode(&records).is_err());
    }

    #[test]
    fn invalid_json_diagnostics_never_echo_private_values() {
        let secret = "private-health-or-token-value";
        let key = fingerprint('a');
        let mut value = serde_json::to_value(record(key.clone())).unwrap();
        value["status"] = Value::String(secret.into());
        let state = serde_json::to_vec(&json!({key: value})).unwrap();
        let error = decode(&state).unwrap_err();
        assert!(!format!("{error:?} {error}").contains(secret));
        let command = serde_json::to_vec(&json!({"operation":secret})).unwrap();
        let error = apply(b"{}", &command).unwrap_err();
        assert!(!format!("{error:?} {error}").contains(secret));
    }

    #[test]
    fn recovery_requires_complete_transaction_and_safe_filename_and_remote_id() {
        let legacy = json!({
            "primarySourceId":"healthkit","primaryActivityId":"activity-1","title":"recovery",
            "startDate":721692800,"endDate":721696400,"supplementSourceIds":[],
            "durationSeconds":3600,"uploadData":"AQID","filename":"activity.fit","commute":false
        });
        for phase in ["prepared", "remoteDeleted", "uploading"] {
            let mut value = legacy.clone();
            value["phase"] = Value::String(phase.into());
            assert!(PendingResyncUpload::decode(&serde_json::to_vec(&value).unwrap()).is_err());
        }
        for filename in ["../secret.fit", "folder/file.fit", "..", "name\n.fit"] {
            let mut value = legacy.clone();
            value["filename"] = Value::String(filename.into());
            assert!(PendingResyncUpload::decode(&serde_json::to_vec(&value).unwrap()).is_err());
        }
        for remote_id in ["../42", "private-token-value", "", "42/streams"] {
            let command = serde_json::to_vec(&json!({
                "operation":"prepare", "externalId":"external", "remoteIdToReplace":remote_id
            }))
            .unwrap();
            let error =
                apply_recovery(&serde_json::to_vec(&legacy).unwrap(), &command).unwrap_err();
            if !remote_id.is_empty() {
                assert!(!format!("{error:?} {error}").contains(remote_id));
            }
        }
    }
    fn valid_recovery_fit() -> Vec<u8> {
        crate::fit::encode_health_workout_bundle_json(
            br#"{
            "uuid":"synthetic-recovery","startMs":1704067200000,"endMs":1704070800000,
            "durationSeconds":3600,"activityType":13,"events":[],"series":{},"route":[]
        }"#,
            0,
        )
        .unwrap()
    }

    fn uploading_replacement_recovery() -> Vec<u8> {
        let data = valid_recovery_fit();
        serde_json::to_vec(&json!({
            "primarySourceId":"onelap","primaryActivityId":"activity-1","title":"recovery",
            "startDate":721692800,"endDate":721696400,"supplementSourceIds":["xingzhe"],
            "durationSeconds":3600,"uploadData":base64::Engine::encode(&base64::engine::general_purpose::STANDARD,&data),
            "filename":"activity.fit","commute":true,"activityDescription":"note",
            "phase":"uploading","externalId":"old-external","remoteIdToReplace":"123",
            "fitSha256":sha256_hex(&data),"futureField":{"keep":true},"name":"title"
        })).unwrap()
    }

    #[test]
    fn recovery_renew_external_id_changes_only_id_after_matching_uploading_replacement() {
        let original = uploading_replacement_recovery();
        let renewed = apply_recovery(&original, br#"{"operation":"renewExternalId","expectedExternalId":"old-external","nextExternalId":"new-external"}"#).unwrap();
        let mut expected = PendingResyncUpload::decode(&original).unwrap();
        expected.external_id = Some("new-external".into());
        assert_eq!(PendingResyncUpload::decode(&renewed).unwrap(), expected);
        assert!(apply_recovery(&renewed, br#"{"operation":"renewExternalId","expectedExternalId":"old-external","nextExternalId":"newer-external"}"#).is_err());
        let again = apply_recovery(&renewed, br#"{"operation":"renewExternalId","expectedExternalId":"new-external","nextExternalId":"newer-external"}"#).unwrap();
        expected.external_id = Some("newer-external".into());
        assert_eq!(PendingResyncUpload::decode(&again).unwrap(), expected);
    }

    #[test]
    fn recovery_renewal_requires_uploading_phase_and_deleted_remote_identity() {
        let original = uploading_replacement_recovery();
        let command = br#"{"operation":"renewExternalId","expectedExternalId":"old-external","nextExternalId":"new-external"}"#;
        for phase in [
            None,
            Some("prepared"),
            Some("remoteDeleted"),
            Some("future"),
        ] {
            let mut value: Value = serde_json::from_slice(&original).unwrap();
            if let Some(phase) = phase {
                value["phase"] = json!(phase);
            } else {
                value.as_object_mut().unwrap().remove("phase");
            }
            assert!(apply_recovery(&serde_json::to_vec(&value).unwrap(), command).is_err());
        }
        let mut value: Value = serde_json::from_slice(&original).unwrap();
        value.as_object_mut().unwrap().remove("remoteIdToReplace");
        assert!(apply_recovery(&serde_json::to_vec(&value).unwrap(), command).is_err());
    }

    #[test]
    fn recovery_renewal_rejects_unchanged_empty_control_and_oversized_ids() {
        let original = uploading_replacement_recovery();
        for next in [
            "old-external".to_owned(),
            " old-external ".into(),
            String::new(),
            " ".into(),
            "bad\nvalue".into(),
            "unicode\u{0085}control".into(),
            "x".repeat(8193),
        ] {
            let command = serde_json::to_vec(&json!({"operation":"renewExternalId","expectedExternalId":"old-external","nextExternalId":next})).unwrap();
            assert!(apply_recovery(&original, &command).is_err());
        }
        assert_eq!(
            PendingResyncUpload::decode(&original)
                .unwrap()
                .external_id
                .as_deref(),
            Some("old-external")
        );
    }

    #[test]
    fn invalid_fit_cannot_be_prepared_or_resume_destructive_recovery() {
        let legacy = br#"{
            "primarySourceId":"healthkit","primaryActivityId":"activity-1","title":"recovery",
            "startDate":721692800,"endDate":721696400,"supplementSourceIds":[],
            "durationSeconds":3600,"uploadData":"AQID","filename":"activity.fit","commute":false
        }"#;
        // Legacy codec remains lossless; entering a transaction must validate the actual FIT.
        assert!(PendingResyncUpload::decode(legacy).is_ok());
        let prepare =
            br#"{"operation":"prepare","externalId":"external","remoteIdToReplace":"123"}"#;
        assert!(apply_recovery(legacy, prepare).is_err());
        let mut tampered: Value = serde_json::from_slice(legacy).unwrap();
        tampered["phase"] = Value::String("remoteDeleted".into());
        tampered["externalId"] = Value::String("external".into());
        tampered["fitSha256"] = Value::String(sha256_hex(&[1, 2, 3]));
        assert!(
            apply_recovery(
                &serde_json::to_vec(&tampered).unwrap(),
                br#"{"operation":"markUploading"}"#
            )
            .is_err()
        );
    }
    #[test]
    fn remote_id_backfill_is_atomic_unique_and_preserves_all_other_metadata() {
        let first = fingerprint('a');
        let second = fingerprint('b');
        let mut item = record(first.clone());
        item.status = SyncRecordStatus::Uploaded;
        item.upload_channel = Some(UploadChannel::Web);
        item.has_virtual_power = Some(true);
        item.is_duplicate = Some(true);
        item.unknown_fields.insert("custom".into(), json!(42));
        let mut state = SyncStateMap::from([
            (first.clone(), item.clone()),
            (second.clone(), record(second.clone())),
        ]);
        let command = serde_json::to_vec(
            &json!({"operation":"setRemoteId","fingerprint":first,"remoteId":"123","updatedAt":10}),
        )
        .unwrap();
        state = decode(&apply(&encode(&state).unwrap(), &command).unwrap()).unwrap();
        item.remote_id = Some("123".into());
        item.updated_at = 10.0;
        assert_eq!(state[&first], item);
        let before = state.clone();
        assert!(set_remote_id(&mut state, &second, "123", 11.0).is_err());
        assert!(set_remote_id(&mut state, &first, "456", 11.0).is_err());
        assert!(set_remote_id(&mut state, &second, "../123", 11.0).is_err());
        assert_eq!(state, before);
        set_remote_id(&mut state, &first, "123", 12.0).unwrap();
        assert_eq!(state[&first].updated_at, 12.0);
    }
}
