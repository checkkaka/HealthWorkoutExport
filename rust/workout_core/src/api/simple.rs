/// Flutter 调用的最小同步入口，直接复用已测试的核心规则。
#[flutter_rust_bridge::frb(sync)]
pub fn is_commute(distance_meters: Option<f64>, duration_seconds: f64) -> bool {
    crate::is_commute(distance_meters, duration_seconds)
}

/// Flutter 可传输的活动时间区间，供跨来源匹配使用。
#[derive(Clone, Copy, Debug)]
pub struct ActivityIntervalInput {
    pub start_seconds: f64,
    pub end_seconds: f64,
    pub duration_seconds: f64,
}

impl From<ActivityIntervalInput> for crate::ActivityInterval {
    fn from(value: ActivityIntervalInput) -> Self {
        Self::new(
            value.start_seconds,
            value.end_seconds,
            value.duration_seconds,
        )
    }
}

/// 计算与 Swift 兼容的同步幂等指纹；非法时间戳不会产生可持久化指纹。
#[flutter_rust_bridge::frb(sync)]
pub fn sync_fingerprint(
    primary_source_id: String,
    primary_activity_id: String,
    start_date_unix_seconds: f64,
    supplement_source_ids: Vec<String>,
    destination: String,
) -> Result<String, String> {
    let supplements = supplement_source_ids
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>();
    crate::sync_fingerprint(
        &primary_source_id,
        &primary_activity_id,
        start_date_unix_seconds,
        &supplements,
        &destination,
    )
    .ok_or_else(|| "无效同步开始时间".to_owned())
}

/// 返回两个活动的匹配分数；不满足时间重叠或兜底容差时为 `null`。
#[flutter_rust_bridge::frb(sync)]
pub fn activity_match_score(
    primary: ActivityIntervalInput,
    candidate: ActivityIntervalInput,
) -> Option<f64> {
    crate::activity_match_score(primary.into(), candidate.into())
}

/// 返回候选活动中分数最高的原始下标；并列时保留最先出现者。
#[flutter_rust_bridge::frb(sync)]
pub fn best_activity_match_index(
    primary: ActivityIntervalInput,
    candidates: Vec<ActivityIntervalInput>,
) -> Option<u32> {
    let candidates = candidates.into_iter().map(Into::into).collect::<Vec<_>>();
    crate::best_activity_match_index(primary.into(), &candidates)
        .and_then(|index| u32::try_from(index).ok())
}

/// 按已有 Swift 容差判断两个跨来源活动是否稳定去重。
#[flutter_rust_bridge::frb(sync)]
pub fn stable_dedupe_matches(
    start_a_seconds: f64,
    distance_a_meters: f64,
    start_b_seconds: f64,
    distance_b_meters: f64,
    duration_a_seconds: Option<f64>,
    duration_b_seconds: Option<f64>,
) -> bool {
    crate::stable_dedupe_matches(
        start_a_seconds,
        distance_a_meters,
        start_b_seconds,
        distance_b_meters,
        duration_a_seconds,
        duration_b_seconds,
    )
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

/// 将一个完整的 HealthKit 训练包直接编码为标准 Activity FIT。
pub fn encode_health_workout_fit(
    bundle_json: Vec<u8>,
    timezone_offset_seconds: i32,
) -> Result<Vec<u8>, String> {
    crate::fit::encode_health_workout_bundle_json(&bundle_json, timezone_offset_seconds)
        .map_err(|error| error.to_string())
}

/// 使用行者网页登录契约换取短期 sessionid；凭据只用于本次请求，调用方负责安全保存返回值。
pub async fn xingzhe_login(account: String, password: String) -> Result<String, String> {
    let client = crate::xingzhe::XingzheLoginClient::new().map_err(|error| error.to_string())?;
    client
        .login(&account, &password)
        .await
        .map_err(|error| error.to_string())
}

/// 使用旧 Swift 的顽鹿 MD5 登录契约换取 token 和 uid；调用方负责安全保存返回值。
pub async fn onelap_login(account: String, password: String) -> Result<OnelapLoginResult, String> {
    let client = crate::onelap::OnelapLoginClient::new().map_err(|error| error.to_string())?;
    let session = client
        .login(&account, &password)
        .await
        .map_err(|error| error.to_string())?;
    Ok(OnelapLoginResult {
        token: session.token,
        uid: session.uid,
    })
}

#[derive(Clone)]
pub struct OnelapLoginResult {
    pub token: String,
    pub uid: String,
}

/// Flutter 侧展示顽鹿活动列表所需字段；列表时间按调用方传入的 UTC 偏移解析。
#[derive(Clone, Debug)]
pub struct OnelapWorkoutResult {
    pub id: String,
    pub title: String,
    pub start_time_seconds: f64,
    pub end_time_seconds: f64,
    pub duration_seconds: f64,
    pub distance_meters: Option<f64>,
}

/// 按旧 Swift 的 20 条分页、半开区间读取顽鹿骑行；会话只用于本次 Rust 请求。
pub async fn onelap_list_workouts(
    token: String,
    uid: String,
    from_seconds: i64,
    to_seconds: i64,
    timezone_offset_seconds: i32,
) -> Result<Vec<OnelapWorkoutResult>, String> {
    let client = crate::onelap::OnelapActivityClient::new().map_err(|error| error.to_string())?;
    client
        .list_rides(
            &token,
            &uid,
            from_seconds,
            to_seconds,
            timezone_offset_seconds,
        )
        .await
        .map(|rides| {
            rides
                .into_iter()
                .map(|ride| OnelapWorkoutResult {
                    id: ride.id,
                    title: "顽鹿骑行".to_owned(),
                    start_time_seconds: ride.start_time_seconds,
                    end_time_seconds: ride.end_time_seconds,
                    duration_seconds: ride.duration_seconds,
                    distance_meters: ride.distance_meters,
                })
                .collect()
        })
        .map_err(|error| error.to_string())
}

/// 读取顽鹿详情的 FIT 候选并仅返回严格校验后、内容质量最佳的一份 FIT。
pub async fn onelap_download_fit(
    token: String,
    uid: String,
    activity_id: String,
) -> Result<Vec<u8>, String> {
    let client = crate::onelap::OnelapActivityClient::new().map_err(|error| error.to_string())?;
    client
        .download_best_fit(&token, &uid, &activity_id)
        .await
        .map_err(|error| error.to_string())
}

/// 读取行者 stream 并编码为标准 Activity FIT。必须先预留列表句柄以便取消。
pub async fn xingzhe_download_fit(
    operation_handle: String,
    session_id: String,
    workout_id: String,
    title: String,
    start_time_seconds: f64,
    duration_seconds: f64,
    distance_meters: Option<f64>,
    timezone_offset_seconds: i32,
) -> Result<Vec<u8>, String> {
    let operation =
        XingzheListOperation::begin(operation_handle).map_err(xingzhe_list_operation_error)?;
    let client = crate::xingzhe::XingzheActivityClient::new().map_err(|error| error.to_string())?;
    client
        .download_fit(
            &session_id,
            &workout_id,
            &title,
            start_time_seconds,
            duration_seconds,
            distance_meters,
            timezone_offset_seconds,
            &operation.cancellation,
        )
        .await
        .map_err(|error| error.to_string())
}

const VIRTUAL_POWER_DESCRIPTION: &str =
    "功率计还在许愿清单里，本场瓦特是风、坡和速度一起算的，看看就好～（出自 HealthWorkoutExport）";

#[derive(Clone, Debug)]
pub struct VirtualPowerFillInput {
    pub include_inertia: bool,
    pub rider_mass_kg: f64,
    pub bike_mass_kg: f64,
    pub cda: f64,
}

#[derive(Clone, Debug)]
pub struct PreparedFitResult {
    pub data: Vec<u8>,
    pub repaired_speed_count: u32,
    pub rewritten_coordinate_count: u32,
    pub virtual_power_filled_count: u32,
    pub power_source_virtual: bool,
    pub activity_description: Option<String>,
}

/// 主源优先补传感器。`alignment` 为 `absolute` / `auto` / `manual`。
#[flutter_rust_bridge::frb(sync)]
pub fn merge_fit_files(
    primary: Vec<u8>,
    supplements: Vec<Vec<u8>>,
    sensors_only: bool,
    alignment: String,
    manual_offset_seconds: i32,
) -> Result<Vec<u8>, String> {
    let refs: Vec<&[u8]> = supplements.iter().map(Vec::as_slice).collect();
    if alignment == "auto" && sensors_only {
        return crate::fit::merge_fit_for_sync(&primary, &refs)
            .map_err(|error| format!("{error:?}"));
    }
    let alignment = match alignment.as_str() {
        "absolute" => crate::fit_alignment::FitStaticAlignment::Absolute,
        "manual" => crate::fit_alignment::FitStaticAlignment::Manual(manual_offset_seconds),
        "auto" => {
            return crate::fit::merge_fit_for_sync(&primary, &refs)
                .map_err(|error| format!("{error:?}"));
        }
        _ => return Err("未知 FIT 对齐模式".to_owned()),
    };
    crate::fit::merge_fit(
        &primary,
        &refs,
        &crate::fit::FitMergeOptions {
            supplement_mode: if sensors_only {
                crate::fit::FitSupplementMode::SensorsOnly
            } else {
                crate::fit::FitSupplementMode::FillRecords
            },
            alignment,
        },
    )
    .map_err(|error| format!("{error:?}"))
}

/// 修复已证明的 GPS 速度尖峰。
#[flutter_rust_bridge::frb(sync)]
pub fn fix_fit_speed_spikes(data: Vec<u8>) -> Result<Vec<u8>, String> {
    crate::fit::fix_fit_speed_spikes(&data)
        .map(|result| result.data)
        .map_err(|error| format!("{error:?}"))
}

/// 把中国境内 GCJ-02 坐标改写为 WGS-84。
#[flutter_rust_bridge::frb(sync)]
pub fn rewrite_fit_gcj_coordinates(data: Vec<u8>) -> Result<Vec<u8>, String> {
    crate::fit::rewrite_fit_gcj_coordinates(&data)
        .map(|result| result.data)
        .map_err(|error| format!("{error:?}"))
}

/// 上传前固定顺序：补源合并 → 尖峰 → GCJ → 虚拟功率。
pub async fn prepare_fit_for_upload(
    primary: Vec<u8>,
    supplements: Vec<Vec<u8>>,
    gcj_enabled: bool,
    virtual_power: Option<VirtualPowerFillInput>,
) -> Result<PreparedFitResult, String> {
    let refs: Vec<&[u8]> = supplements.iter().map(Vec::as_slice).collect();
    let merged = if refs.is_empty() {
        primary
    } else {
        crate::fit::merge_fit_for_sync(&primary, &refs).map_err(|error| format!("{error:?}"))?
    };
    let spike = crate::fit::fix_fit_speed_spikes(&merged).map_err(|error| format!("{error:?}"))?;
    let repaired_speed_count = u32::try_from(spike.fixed_count).unwrap_or(u32::MAX);
    let mut data = spike.data;
    let mut rewritten_coordinate_count = 0;
    if gcj_enabled {
        let rewritten =
            crate::fit::rewrite_fit_gcj_coordinates(&data).map_err(|error| format!("{error:?}"))?;
        rewritten_coordinate_count = u32::try_from(rewritten.rewritten_count).unwrap_or(u32::MAX);
        data = rewritten.data;
    }
    let mut virtual_power_filled_count = 0;
    let mut power_source_virtual = false;
    let mut activity_description = None;
    if let Some(input) = virtual_power {
        if input.rider_mass_kg > 0.0 && input.bike_mass_kg > 0.0 && input.cda > 0.0 {
            let air_density = weather_air_density(&data).await.unwrap_or(1.225);
            let filled = crate::fit::fill_fit_virtual_power(
                &data,
                crate::fit::FitVirtualPowerFillOptions {
                    params: crate::VirtualPowerParams {
                        total_mass_kg: input.rider_mass_kg + input.bike_mass_kg,
                        cda: input.cda,
                        crr: 0.005,
                        drivetrain_loss_percent: 2.0,
                        air_density,
                    },
                    include_inertia: input.include_inertia,
                    mode: crate::fit::FitVirtualPowerFillMode::Overwrite,
                },
            )
            .map_err(|error| format!("{error:?}"))?;
            virtual_power_filled_count = u32::try_from(filled.filled_count).unwrap_or(u32::MAX);
            power_source_virtual = filled.power_source_virtual && !filled.activity_rejected;
            if power_source_virtual {
                activity_description = Some(VIRTUAL_POWER_DESCRIPTION.to_owned());
            }
            if !filled.activity_rejected {
                data = filled.data;
            }
        }
    }
    Ok(PreparedFitResult {
        data,
        repaired_speed_count,
        rewritten_coordinate_count,
        virtual_power_filled_count,
        power_source_virtual,
        activity_description,
    })
}

async fn weather_air_density(data: &[u8]) -> Result<f64, String> {
    let Some((latitude, longitude)) =
        crate::fit::first_fit_coordinate(data).map_err(|error| format!("{error:?}"))?
    else {
        return Ok(1.225);
    };
    let Some((start, end)) =
        crate::fit::fit_time_range_unix_seconds(data).map_err(|error| format!("{error:?}"))?
    else {
        return Ok(1.225);
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(end);
    let client =
        crate::weather::OpenMeteoWeatherClient::new().map_err(|error| error.to_string())?;
    let samples = client
        .fetch_hourly(
            latitude,
            longitude,
            start,
            end.max(start + 1),
            now,
            &crate::weather::WeatherCancellation::new(),
        )
        .await
        .map_err(|error| error.to_string())?;
    let Some(sample) = samples.first() else {
        return Ok(1.225);
    };
    Ok(crate::air_density(
        sample.temperature_c,
        sample.pressure_msl_hpa,
        sample.relative_humidity_percent,
    ))
}

#[derive(Clone, Debug)]
pub struct XingzheListReservation {
    pub handle: String,
}

/// Flutter 侧展示行者活动列表所需字段；时间为 Unix 秒，区间按 `[from, to)` 过滤。
#[derive(Clone, Debug)]
pub struct XingzheWorkoutResult {
    pub id: String,
    pub title: String,
    pub start_time_seconds: f64,
    pub end_time_seconds: f64,
    pub duration_seconds: f64,
    pub distance_meters: Option<f64>,
}

/// 预留一个不可复用的行者列表读取句柄。调用方可在请求期间精确取消此代操作。
#[flutter_rust_bridge::frb(sync)]
pub fn xingzhe_reserve_list(operation_id: String) -> Result<XingzheListReservation, String> {
    XingzheListOperation::reserve(operation_id)
        .map(|handle| XingzheListReservation { handle })
        .map_err(xingzhe_list_operation_error)
}

/// 按现有 `sessionid` 读取行者活动。必须先预留句柄，Future 结束时自动释放。
pub async fn xingzhe_list_workouts(
    operation_handle: String,
    session_id: String,
    from_seconds: i64,
    to_seconds: i64,
) -> Result<Vec<XingzheWorkoutResult>, String> {
    let operation =
        XingzheListOperation::begin(operation_handle).map_err(xingzhe_list_operation_error)?;
    let client = crate::xingzhe::XingzheActivityClient::new().map_err(|error| error.to_string())?;
    client
        .list_workouts(
            &session_id,
            from_seconds,
            to_seconds,
            &operation.cancellation,
        )
        .await
        .map(|workouts| {
            workouts
                .into_iter()
                .map(|workout| XingzheWorkoutResult {
                    id: workout.id,
                    title: workout.title,
                    start_time_seconds: workout.start_time_seconds,
                    end_time_seconds: workout.end_time_seconds,
                    duration_seconds: workout.duration_seconds,
                    distance_meters: workout.distance_meters,
                })
                .collect()
        })
        .map_err(|error| error.to_string())
}

/// 取消特定代际的行者列表读取；旧句柄不会影响后续相同逻辑 ID 的新操作。
#[flutter_rust_bridge::frb(sync)]
pub fn xingzhe_cancel_list(operation_handle: String) -> bool {
    let cancellation = xingzhe_list_operations()
        .lock()
        .expect("xingzhe list operation mutex poisoned")
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

/// 释放尚未启动的行者列表读取预留句柄；运行中的操作由 Future 结束时自动释放。
#[flutter_rust_bridge::frb(sync)]
pub fn xingzhe_release_list(operation_handle: String) -> bool {
    let mut registry = xingzhe_list_operations()
        .lock()
        .expect("xingzhe list operation mutex poisoned");
    let Some(entry) = registry.operations.get(&operation_handle) else {
        return false;
    };
    if entry.state != XingzheListOperationState::Reserved {
        return false;
    }
    let logical_id = entry.logical_id.clone();
    registry.operations.remove(&operation_handle);
    if registry.active_by_logical.get(&logical_id) == Some(&operation_handle) {
        registry.active_by_logical.remove(&logical_id);
    }
    true
}

fn xingzhe_list_operations() -> &'static std::sync::Mutex<XingzheListOperationRegistry> {
    static OPERATIONS: std::sync::OnceLock<std::sync::Mutex<XingzheListOperationRegistry>> =
        std::sync::OnceLock::new();
    OPERATIONS.get_or_init(|| {
        std::sync::Mutex::new(XingzheListOperationRegistry {
            operations: std::collections::HashMap::new(),
            active_by_logical: std::collections::HashMap::new(),
        })
    })
}

struct XingzheListOperationRegistry {
    operations: std::collections::HashMap<String, XingzheListOperationEntry>,
    active_by_logical: std::collections::HashMap<String, String>,
}

struct XingzheListOperationEntry {
    logical_id: String,
    cancellation: crate::xingzhe::XingzheCancellation,
    state: XingzheListOperationState,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum XingzheListOperationState {
    Reserved,
    Running,
}

struct XingzheListOperation {
    handle: String,
    cancellation: crate::xingzhe::XingzheCancellation,
}

#[derive(Debug)]
enum XingzheListOperationError {
    Invalid,
    InUse,
    Exhausted,
}

impl XingzheListOperation {
    fn reserve(operation_id: String) -> Result<String, XingzheListOperationError> {
        const MAX_OPERATIONS: usize = 128;
        if operation_id.trim().is_empty()
            || operation_id.len() > 256
            || operation_id
                .chars()
                .any(|character| character.is_ascii_control())
        {
            return Err(XingzheListOperationError::Invalid);
        }
        static NEXT_HANDLE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let mut registry = xingzhe_list_operations()
            .lock()
            .expect("xingzhe list operation mutex poisoned");
        if registry.active_by_logical.contains_key(&operation_id) {
            return Err(XingzheListOperationError::InUse);
        }
        if registry.operations.len() >= MAX_OPERATIONS {
            return Err(XingzheListOperationError::Exhausted);
        }
        let generation = NEXT_HANDLE
            .fetch_update(
                std::sync::atomic::Ordering::Relaxed,
                std::sync::atomic::Ordering::Relaxed,
                |value| value.checked_add(1),
            )
            .map_err(|_| XingzheListOperationError::Exhausted)?;
        let handle = format!("xingzhe-list-{generation:016x}");
        registry
            .active_by_logical
            .insert(operation_id.clone(), handle.clone());
        registry.operations.insert(
            handle.clone(),
            XingzheListOperationEntry {
                logical_id: operation_id,
                cancellation: crate::xingzhe::XingzheCancellation::new(),
                state: XingzheListOperationState::Reserved,
            },
        );
        Ok(handle)
    }

    fn begin(handle: String) -> Result<Self, XingzheListOperationError> {
        let mut registry = xingzhe_list_operations()
            .lock()
            .expect("xingzhe list operation mutex poisoned");
        let Some(entry) = registry.operations.get_mut(&handle) else {
            return Err(XingzheListOperationError::Invalid);
        };
        if entry.state != XingzheListOperationState::Reserved {
            return Err(XingzheListOperationError::InUse);
        }
        entry.state = XingzheListOperationState::Running;
        Ok(Self {
            handle,
            cancellation: entry.cancellation.clone(),
        })
    }
}

impl Drop for XingzheListOperation {
    fn drop(&mut self) {
        let mut registry = xingzhe_list_operations()
            .lock()
            .expect("xingzhe list operation mutex poisoned");
        let Some(entry) = registry.operations.remove(&self.handle) else {
            return;
        };
        if registry.active_by_logical.get(&entry.logical_id) == Some(&self.handle) {
            registry.active_by_logical.remove(&entry.logical_id);
        }
    }
}

fn xingzhe_list_operation_error(error: XingzheListOperationError) -> String {
    match error {
        XingzheListOperationError::Invalid => "行者活动读取操作无效或已结束".to_owned(),
        XingzheListOperationError::InUse => "行者活动读取操作已在运行".to_owned(),
        XingzheListOperationError::Exhausted => "行者活动读取操作已达上限".to_owned(),
    }
}

#[cfg(test)]
mod xingzhe_list_ffi_tests {
    use super::{
        XingzheListOperation, xingzhe_cancel_list, xingzhe_release_list, xingzhe_reserve_list,
    };

    #[test]
    fn cancellation_is_generation_scoped_and_cleanup_allows_a_new_read() {
        let first = xingzhe_reserve_list("xingzhe-list-test".to_owned()).unwrap();
        assert!(xingzhe_cancel_list(first.handle.clone()));
        let operation = XingzheListOperation::begin(first.handle.clone()).unwrap();
        assert!(operation.cancellation.is_cancelled());
        drop(operation);

        let second = xingzhe_reserve_list("xingzhe-list-test".to_owned()).unwrap();
        assert_ne!(first.handle, second.handle);
        assert!(!xingzhe_cancel_list(first.handle));
        assert!(xingzhe_release_list(second.handle));
    }
}

#[cfg(test)]
mod prepare_fit_ffi_tests {
    use super::prepare_fit_for_upload;

    #[tokio::test]
    async fn prepare_without_supplements_keeps_valid_fit() {
        let json = br#"{
            "uuid":"prep","startMs":1700000000000,"endMs":1700000060000,
            "durationSeconds":60.0,"activityType":13,"events":[],"series":{},
            "route":[{"latitude":39.9,"longitude":116.4,"timestampMs":1700000000000}]
        }"#;
        let primary = crate::fit::encode_health_workout_bundle_json(json, 0).unwrap();
        let prepared = prepare_fit_for_upload(primary.clone(), Vec::new(), false, None)
            .await
            .unwrap();
        assert!(crate::fit::is_valid_fit(&prepared.data));
        assert_eq!(prepared.virtual_power_filled_count, 0);
        assert!(!prepared.power_source_virtual);
    }
}

/// 原子执行同步状态校验/转换；返回值只有在完整成功后才可写回原生文件。
#[flutter_rust_bridge::frb(sync)]
pub fn sync_state_apply(state_json: Vec<u8>, command_json: Vec<u8>) -> Result<Vec<u8>, String> {
    crate::sync_state::apply(&state_json, &command_json).map_err(|error| error.to_string())
}

/// 校验旧 Swift 恢复包并按同一 JSON/Base64 协议规范化返回。
#[flutter_rust_bridge::frb(sync)]
pub fn sync_recovery_reencode(recovery_json: Vec<u8>) -> Result<Vec<u8>, String> {
    crate::sync_state::PendingResyncUpload::decode(&recovery_json)
        .and_then(|upload| upload.encode())
        .map_err(|error| error.to_string())
}

/// 原子推进崩溃恢复事务；阶段转换和 FIT 哈希验证失败时不产生可写回字节。
#[flutter_rust_bridge::frb(sync)]
pub fn sync_recovery_apply(
    recovery_json: Vec<u8>,
    command_json: Vec<u8>,
) -> Result<Vec<u8>, String> {
    crate::sync_state::apply_recovery(&recovery_json, &command_json)
        .map_err(|error| error.to_string())
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

/// Flutter 侧用于上传前远端预检的活动区间；字段语义与旧 Swift `RemoteActivity` 一致。
#[derive(Clone, Debug)]
pub struct StravaRemoteActivityResult {
    pub id: String,
    pub start_time_seconds: f64,
    pub end_time_seconds: f64,
    pub distance_meters: Option<f64>,
}

/// Flutter 侧用于异常速度复查的官方活动摘要。
#[derive(Clone, Debug)]
pub struct StravaActivitySpeedResult {
    pub id: String,
    pub name: String,
    pub start_time_seconds: Option<f64>,
    pub sport_type: String,
    pub listed_max_speed_mps: f64,
    pub best_effort_peak_mps: f64,
    pub max_speed_mps: f64,
    pub average_speed_mps: f64,
}

/// 拉取 Strava 远端活动列表。调用前先用 `strava_reserve_remote_read` 获取 handle，
/// 运行中可通过 `strava_cancel_remote_read` 取消；handle 在 Future 结束后自动释放。
pub async fn strava_list_remote_activities(
    operation_handle: String,
    access_token: String,
    after_seconds: i64,
    before_seconds: i64,
) -> Result<Vec<StravaRemoteActivityResult>, String> {
    let operation = UploadOperation::begin(operation_handle).map_err(remote_operation_error)?;
    let client = crate::strava::StravaActivityClient::new().map_err(remote_activity_error)?;
    client
        .list_activities(
            &access_token,
            after_seconds,
            before_seconds,
            &operation.cancellation,
        )
        .await
        .map(|activities| activities.into_iter().map(remote_activity_result).collect())
        .map_err(remote_activity_error)
}

/// 拉取单条 Strava 活动的摘要最高速与 best_efforts 峰值；404 返回 `null`。
/// 调用约束与 `strava_list_remote_activities` 相同，避免读取任务无法中止。
pub async fn strava_fetch_remote_activity_speed(
    operation_handle: String,
    access_token: String,
    activity_id: String,
) -> Result<Option<StravaActivitySpeedResult>, String> {
    let operation = UploadOperation::begin(operation_handle).map_err(remote_operation_error)?;
    let client = crate::strava::StravaActivityClient::new().map_err(remote_activity_error)?;
    client
        .activity_speed(&access_token, &activity_id, &operation.cancellation)
        .await
        .map(|activity| activity.map(remote_activity_speed_result))
        .map_err(remote_activity_error)
}

fn remote_activity_result(
    activity: crate::strava::StravaRemoteActivity,
) -> StravaRemoteActivityResult {
    StravaRemoteActivityResult {
        id: activity.id,
        start_time_seconds: activity.start_time_seconds,
        end_time_seconds: activity.end_time_seconds,
        distance_meters: activity.distance_meters,
    }
}

fn remote_activity_speed_result(
    activity: crate::strava::StravaActivitySpeedInfo,
) -> StravaActivitySpeedResult {
    StravaActivitySpeedResult {
        id: activity.id,
        name: activity.name,
        start_time_seconds: activity.start_time_seconds,
        sport_type: activity.sport_type,
        listed_max_speed_mps: activity.listed_max_speed_mps,
        best_effort_peak_mps: activity.best_effort_peak_mps,
        max_speed_mps: activity.max_speed_mps,
        average_speed_mps: activity.average_speed_mps,
    }
}

fn remote_operation_error(error: UploadOperationError) -> String {
    match error {
        UploadOperationError::Invalid => "Strava 远端读取操作无效或已结束".to_owned(),
        UploadOperationError::InUse => "Strava 远端读取操作已在运行".to_owned(),
        UploadOperationError::Exhausted => "Strava 远端读取操作已达上限".to_owned(),
    }
}

fn remote_activity_error(error: crate::strava::StravaActivityError) -> String {
    error.to_string()
}

/// 同步预留一个远端读取 handle。底层复用上传操作注册表，使取消代际隔离规则完全一致。
#[flutter_rust_bridge::frb(sync)]
pub fn strava_reserve_remote_read(operation_id: String) -> Result<StravaUploadReservation, String> {
    UploadOperation::reserve(operation_id)
        .map(|handle| StravaUploadReservation { handle })
        .map_err(remote_operation_error)
}

/// 取消特定代际的远端读取，不会影响之后为同一 logical ID 新建的读取。
#[flutter_rust_bridge::frb(sync)]
pub fn strava_cancel_remote_read(operation_handle: String) -> bool {
    strava_cancel_upload(operation_handle)
}

/// 释放尚未启动的远端读取预留 handle；已启动任务由 RAII 自动释放。
#[flutter_rust_bridge::frb(sync)]
pub fn strava_release_remote_read(operation_handle: String) -> bool {
    strava_release_upload(operation_handle)
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
