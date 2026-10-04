//! Cancellable experimental Keep calls. The caller stores only the returned token securely.

#[derive(Clone)]
pub struct KeepLoginResult {
    pub token: String,
}

#[derive(Clone, Debug)]
pub struct KeepWorkoutResult {
    pub id: String,
    pub title: String,
    pub start_time_seconds: f64,
    pub end_time_seconds: f64,
    pub duration_seconds: f64,
    pub distance_meters: Option<f64>,
    pub indoor: bool,
}

pub struct KeepOperationReservation {
    pub handle: String,
}

#[flutter_rust_bridge::frb(sync)]
pub fn keep_reserve_operation(operation_id: String) -> Result<KeepOperationReservation, String> {
    super::simple::strava_reserve_upload(operation_id)
        .map(|reservation| KeepOperationReservation {
            handle: reservation.handle,
        })
        .map_err(|_| "KeepOperationUnavailable".to_owned())
}
#[flutter_rust_bridge::frb(sync)]
pub fn keep_cancel_operation(operation_handle: String) -> bool {
    super::simple::strava_cancel_upload(operation_handle)
}
#[flutter_rust_bridge::frb(sync)]
pub fn keep_release_operation(operation_handle: String) -> bool {
    super::simple::strava_release_upload(operation_handle)
}
pub async fn keep_login(
    operation_handle: String,
    account: String,
    password: String,
) -> Result<KeepLoginResult, String> {
    let operation =
        super::simple::UploadOperation::begin(operation_handle).map_err(operation_error)?;
    let client = crate::keep::KeepClient::new().map_err(|error| error.to_string())?;
    client
        .login(&account, &password, &operation.cancellation)
        .await
        .map(|token| KeepLoginResult { token })
        .map_err(|error| error.to_string())
}
pub async fn keep_list_workouts(
    operation_handle: String,
    token: String,
    from_seconds: i64,
    to_seconds: i64,
) -> Result<Vec<KeepWorkoutResult>, String> {
    let operation =
        super::simple::UploadOperation::begin(operation_handle).map_err(operation_error)?;
    let client = crate::keep::KeepClient::new().map_err(|error| error.to_string())?;
    client
        .list_workouts(&token, from_seconds, to_seconds, &operation.cancellation)
        .await
        .map(|workouts| {
            workouts
                .into_iter()
                .map(|run| KeepWorkoutResult {
                    id: run.id,
                    title: run.title,
                    start_time_seconds: run.start_time_seconds,
                    end_time_seconds: run.end_time_seconds,
                    duration_seconds: run.duration_seconds,
                    distance_meters: run.distance_meters,
                    indoor: run.indoor,
                })
                .collect()
        })
        .map_err(|error| error.to_string())
}
pub async fn keep_download_fit(
    operation_handle: String,
    token: String,
    workout_id: String,
) -> Result<Vec<u8>, String> {
    let operation =
        super::simple::UploadOperation::begin(operation_handle).map_err(operation_error)?;
    let client = crate::keep::KeepClient::new().map_err(|error| error.to_string())?;
    client
        .download_fit(&token, &workout_id, &operation.cancellation)
        .await
        .map_err(|error| error.to_string())
}
fn operation_error(error: super::simple::UploadOperationError) -> String {
    match error {
        super::simple::UploadOperationError::Invalid => "KeepInvalidOperation",
        super::simple::UploadOperationError::InUse => "KeepOperationInUse",
        super::simple::UploadOperationError::Exhausted => "KeepOperationUnavailable",
    }
    .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn precancelled_login_finishes_and_releases_its_generation() {
        let first = keep_reserve_operation("keep-login-synthetic".to_owned()).unwrap();
        assert!(keep_cancel_operation(first.handle.clone()));
        let error = keep_login(
            first.handle.clone(),
            "synthetic".to_owned(),
            "password".to_owned(),
        )
        .await
        .err()
        .unwrap();
        assert_eq!(error, "KeepCancelled");
        assert!(!keep_release_operation(first.handle.clone()));
        let second = keep_reserve_operation("keep-login-synthetic".to_owned()).unwrap();
        assert_ne!(first.handle, second.handle);
        assert!(!keep_cancel_operation(first.handle));
        assert!(keep_release_operation(second.handle));
    }

    #[tokio::test]
    async fn precancelled_list_and_download_never_contact_network() {
        let list = keep_reserve_operation("keep-list-synthetic".to_owned()).unwrap();
        assert!(keep_cancel_operation(list.handle.clone()));
        assert_eq!(
            keep_list_workouts(list.handle, "synthetic-token".to_owned(), 1, 2)
                .await
                .unwrap_err(),
            "KeepCancelled"
        );
        let download = keep_reserve_operation("keep-download-synthetic".to_owned()).unwrap();
        assert!(keep_cancel_operation(download.handle.clone()));
        assert_eq!(
            keep_download_fit(
                download.handle,
                "synthetic-token".to_owned(),
                "synthetic-run".to_owned()
            )
            .await
            .unwrap_err(),
            "KeepCancelled"
        );
    }
}
