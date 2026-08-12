import 'dart:convert';
import 'dart:typed_data';

import 'native_channels.dart';
import 'src/rust/api/simple.dart' as raw;

export 'src/rust/api/simple.dart'
    show
        StravaUploadFfiError,
        StravaUploadFfiErrorCode,
        StravaUploadFfiResponse,
        StravaUploadFfiStatus,
        StravaUploadRetry,
        StravaUploadRetryStage;

/// 业务层唯一允许使用的 Strava API 上传入口。
///
/// `src/rust/api/simple.dart` 是生成的 raw FFI，只供本门面调用；业务代码不得直接
/// import raw 文件绕过序列化前的信任边界检查。
final class StravaUploadApi {
  static const _maxFitBytes = 64 * 1024 * 1024;
  static const _maxTextBytes = 8 * 1024;
  static const _maxFilenameBytes = 255;
  static const _maxUploadIdBytes = 1024;
  static const _maxOperationIdBytes = 256;

  const StravaUploadApi();

  /// 必须先 reserve，再把返回的不可重用 handle 传给 upload/retry/resume/cancel。
  StravaUploadHandle reserve(String logicalOperationId) {
    _validateText(
      logicalOperationId,
      'logicalOperationId',
      _maxOperationIdBytes,
    );
    return StravaUploadHandle._(
      raw.stravaReserveUpload(operationId: logicalOperationId).handle,
    );
  }

  Future<raw.StravaUploadFfiResponse> upload({
    required StravaUploadHandle handle,
    required String accessToken,
    required Uint8List fit,
    required String externalId,
    required String filename,
    required bool commute,
    String? description,
  }) {
    try {
      _validateUpload(accessToken, fit, externalId, filename, description);
    } catch (_) {
      release(handle);
      rethrow;
    }
    return raw.stravaUploadFit(
      operationHandle: handle._value,
      accessToken: accessToken,
      fit: fit,
      externalId: externalId,
      filename: filename,
      commute: commute,
      description: description,
    );
  }

  /// POST 401 强刷后的唯一一次重放；二次 401 必须直接结束。
  Future<raw.StravaUploadFfiResponse> retryUploadAfterRefresh({
    required StravaUploadHandle handle,
    required String accessToken,
    required Uint8List fit,
    required String externalId,
    required String filename,
    required bool commute,
    String? description,
  }) {
    try {
      _validateUpload(accessToken, fit, externalId, filename, description);
    } catch (_) {
      release(handle);
      rethrow;
    }
    return raw.stravaRetryUploadAfterRefresh(
      operationHandle: handle._value,
      accessToken: accessToken,
      fit: fit,
      externalId: externalId,
      filename: filename,
      commute: commute,
      description: description,
    );
  }

  /// poll 401 强刷后从 typed retry 携带的同一 uploadId/attempt 续跑。
  Future<raw.StravaUploadFfiResponse> resumePollAfterRefresh({
    required StravaUploadHandle handle,
    required String accessToken,
    required String uploadId,
    required int pollAttempt,
  }) {
    try {
      _validateText(accessToken, 'accessToken', _maxTextBytes);
      _validateText(uploadId, 'uploadId', _maxUploadIdBytes);
      if (pollAttempt < 0 || pollAttempt > 6) {
        throw ArgumentError.value(pollAttempt, 'pollAttempt', '必须在 0..6');
      }
    } catch (_) {
      release(handle);
      rethrow;
    }
    return raw.stravaResumeUploadPollAfterRefresh(
      operationHandle: handle._value,
      accessToken: accessToken,
      uploadId: uploadId,
      pollAttempt: pollAttempt,
    );
  }

  /// 可在启动前或异步 Future 运行期间调用；只取消这一代精确 handle。
  bool cancel(StravaUploadHandle handle) =>
      raw.stravaCancelUpload(operationHandle: handle._value);

  /// 放弃尚未启动的 reservation；已启动的操作会在 Future 结束时自动释放。
  bool release(StravaUploadHandle handle) =>
      raw.stravaReleaseUpload(operationHandle: handle._value);

  static void _validateUpload(
    String accessToken,
    Uint8List fit,
    String externalId,
    String filename,
    String? description,
  ) {
    _validateText(accessToken, 'accessToken', _maxTextBytes);
    _validateText(externalId, 'externalId', _maxTextBytes);
    _validateText(filename, 'filename', _maxFilenameBytes);
    if (filename.contains('/') || filename.contains('\\')) {
      throw ArgumentError('filename 不得包含路径分隔符');
    }
    if (description != null && description.isNotEmpty) {
      _validateText(description, 'description', _maxTextBytes);
    }
    if (fit.isEmpty || fit.lengthInBytes > _maxFitBytes) {
      throw ArgumentError.value(fit.lengthInBytes, 'fit', '必须为 1..64MiB');
    }
  }

  static void _validateText(String value, String name, int maxBytes) {
    if (value.trim().isEmpty || utf8.encode(value).length > maxBytes) {
      throw ArgumentError('$name 为空或超过 $maxBytes UTF-8 字节');
    }
    if (value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f)) {
      throw ArgumentError('$name 不得包含 ASCII 控制字符');
    }
  }
}

/// Rust reserve 返回的 opaque generation handle；业务代码不能自行构造。
final class StravaUploadHandle {
  const StravaUploadHandle._(this._value);

  final String _value;
}

typedef StravaTokenRefresh =
    Future<raw.StravaTokenResult> Function({
      required String clientId,
      required String clientSecret,
      required String refreshToken,
    });

/// 生产上传会话：只短暂租用凭据，401 时强刷一次并续传同一上传。
final class StravaUploadSession {
  StravaUploadSession({
    this.vault = const StravaVaultChannel(),
    this.api = const StravaUploadApi(),
    this.refreshToken = raw.stravaRefreshToken,
  });

  final StravaVaultChannel vault;
  final StravaUploadApi api;
  final StravaTokenRefresh refreshToken;
  Future<String>? _refreshInFlight;

  StravaUploadTask start({
    required String logicalOperationId,
    required Uint8List fit,
    required String externalId,
    required String filename,
    required bool commute,
    String? description,
  }) {
    final handle = api.reserve(logicalOperationId);
    return StravaUploadTask._(
      api,
      handle,
      _run(
        handle: handle,
        fit: fit,
        externalId: externalId,
        filename: filename,
        commute: commute,
        description: description,
      ),
    );
  }

  Future<raw.StravaUploadFfiResponse> _run({
    required StravaUploadHandle handle,
    required Uint8List fit,
    required String externalId,
    required String filename,
    required bool commute,
    String? description,
  }) async {
    try {
      final token = await accessToken();
      final first = await api.upload(
        handle: handle,
        accessToken: token,
        fit: fit,
        externalId: externalId,
        filename: filename,
        commute: commute,
        description: description,
      );
      if (first.status != raw.StravaUploadFfiStatus.needsRefresh) return first;

      final retry = first.retry;
      if (retry == null) throw const FormatException('Strava 刷新请求缺少续传信息');
      final refreshedAccessToken = await _refreshAccessToken();
      return switch (retry.stage) {
        raw.StravaUploadRetryStage.upload => api.retryUploadAfterRefresh(
          handle: handle,
          accessToken: refreshedAccessToken,
          fit: fit,
          externalId: externalId,
          filename: filename,
          commute: commute,
          description: description,
        ),
        raw.StravaUploadRetryStage.poll => api.resumePollAfterRefresh(
          handle: handle,
          accessToken: refreshedAccessToken,
          uploadId:
              retry.uploadId ??
              (throw const FormatException('Strava 轮询续传缺少 uploadId')),
          pollAttempt:
              retry.pollAttempt ??
              (throw const FormatException('Strava 轮询续传缺少 attempt')),
        ),
      };
    } finally {
      // 未进入 Rust、刷新失败或续传信息损坏时释放；终态已由 Rust 自动释放。
      api.release(handle);
    }
  }

  /// 仅供同一受控同步链路租用短期 token，调用方不得缓存或写入日志。
  Future<String> accessToken() async {
    final lease = await vault.lease(StravaLeasePurpose.upload);
    if (lease.expiresAtSeconds >
        DateTime.now().millisecondsSinceEpoch / 1000 + 60) {
      return lease.accessToken!;
    }
    return _refreshAccessToken();
  }

  Future<String> _refreshAccessToken() async {
    final running = _refreshInFlight;
    if (running != null) return running;
    final refresh = _refreshAndCommit();
    _refreshInFlight = refresh;
    try {
      return await refresh;
    } finally {
      if (identical(_refreshInFlight, refresh)) _refreshInFlight = null;
    }
  }

  Future<String> _refreshAndCommit() async {
    final lease = await vault.lease(StravaLeasePurpose.refresh);
    final token = await refreshToken(
      clientId: lease.clientId!,
      clientSecret: lease.clientSecret!,
      refreshToken: lease.refreshToken!,
    );
    await vault.commitAuthorization(
      clientId: lease.clientId!,
      clientSecret: lease.clientSecret!,
      accessToken: token.accessToken,
      refreshToken: token.refreshToken,
      expiresAtSeconds: token.expiresAt,
    );
    return token.accessToken;
  }
}

/// App 级单例，保证并发上传共用一次 token refresh。
final stravaUploadSession = StravaUploadSession();

final class StravaUploadTask {
  const StravaUploadTask._(this._api, this._handle, this.result);

  final StravaUploadApi _api;
  final StravaUploadHandle _handle;
  final Future<raw.StravaUploadFfiResponse> result;

  bool cancel() => _api.cancel(_handle);
}
