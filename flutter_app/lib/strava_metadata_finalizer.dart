import 'src/rust/api/simple.dart' as rust;

Future<rust.StravaUploadFfiResponse> finalizeUploadedMetadata(
  rust.StravaUploadFfiResponse response, {
  required Future<void> Function(bool forceRefresh) update,
  bool Function()? cancelled,
}) async {
  if (response.status != rust.StravaUploadFfiStatus.completed ||
      response.isDuplicate ||
      response.remoteId == null ||
      !RegExp(r'^[0-9]{1,32}$').hasMatch(response.remoteId!)) {
    return response;
  }
  rust.StravaUploadFfiResponse warning(String message) =>
      rust.StravaUploadFfiResponse(
        status: response.status,
        remoteId: response.remoteId,
        isDuplicate: response.isDuplicate,
        error: rust.StravaUploadFfiError(
          code: rust.StravaUploadFfiErrorCode.transport,
          message: message,
        ),
      );
  if (cancelled?.call() == true) return warning('上传已完成，已停止后续标题/描述更新');
  try {
    try {
      await update(false);
    } catch (error) {
      if (cancelled?.call() == true ||
          !error.toString().contains('Strava 授权已失效')) {
        rethrow;
      }
      await update(true);
    }
    return response;
  } catch (_) {
    return warning('上传已完成，标题/描述更新失败，可在 Strava 修改');
  }
}
