import 'package:flutter/services.dart';

enum StravaLeasePurpose { refresh, upload }

/// 一次 Strava 原生凭据租约；不得写入日志、UI 或长期状态。
final class StravaLease {
  const StravaLease._({
    required this.purpose,
    required this.clientId,
    required this.clientSecret,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAtSeconds,
  });

  factory StravaLease.fromObject(StravaLeasePurpose purpose, Object? value) {
    final map = _objectMap(value, 'Strava 凭据租约');
    final expiresAt = _requiredFiniteDouble(map, 'expiresAtSeconds');
    return switch (purpose) {
      StravaLeasePurpose.refresh => StravaLease._(
        purpose: purpose,
        clientId: _requiredText(map, 'clientId'),
        clientSecret: _requiredText(map, 'clientSecret'),
        accessToken: null,
        refreshToken: _requiredText(map, 'refreshToken'),
        expiresAtSeconds: expiresAt,
      ),
      StravaLeasePurpose.upload => StravaLease._(
        purpose: purpose,
        clientId: null,
        clientSecret: null,
        accessToken: _requiredText(map, 'accessToken'),
        refreshToken: null,
        expiresAtSeconds: expiresAt,
      ),
    };
  }

  final StravaLeasePurpose purpose;
  final String? clientId;
  final String? clientSecret;
  final String? accessToken;
  final String? refreshToken;
  final double expiresAtSeconds;

  @override
  String toString() =>
      'StravaLease(purpose: ${purpose.name}, expiresAtSeconds: $expiresAtSeconds, credentials: <redacted>)';
}

final class StravaVaultStatus {
  const StravaVaultStatus({
    required this.clientId,
    required this.hasClientSecret,
    required this.hasAccessToken,
    required this.hasRefreshToken,
    required this.expiresAtSeconds,
  });

  factory StravaVaultStatus.fromObject(Object? value) {
    final map = _objectMap(value, 'Strava 凭据状态');
    final clientId = map['clientId'];
    if (clientId is! String) {
      throw const FormatException('Strava clientId 状态无效');
    }
    return StravaVaultStatus(
      clientId: clientId,
      hasClientSecret: _requiredBool(map, 'hasClientSecret'),
      hasAccessToken: _requiredBool(map, 'hasAccessToken'),
      hasRefreshToken: _requiredBool(map, 'hasRefreshToken'),
      expiresAtSeconds: _requiredFiniteDouble(map, 'expiresAtSeconds'),
    );
  }

  final String clientId;
  final bool hasClientSecret;
  final bool hasAccessToken;
  final bool hasRefreshToken;
  final double expiresAtSeconds;
}

/// 固定用途的 Strava Keychain vault；不提供任意 account 读写能力。
final class StravaVaultChannel {
  const StravaVaultChannel()
    : _channel = const MethodChannel('health_workout_export/keychain');

  final MethodChannel _channel;

  Future<StravaVaultStatus> status() async {
    final value = await _channel.invokeMethod<Object?>('stravaStatus');
    return StravaVaultStatus.fromObject(value);
  }

  Future<StravaLease> lease(StravaLeasePurpose purpose) async {
    final value = await _channel.invokeMethod<Object?>('stravaLease', {
      'purpose': purpose.name,
    });
    return StravaLease.fromObject(purpose, value);
  }

  Future<void> commitAuthorization({
    required String clientId,
    required String clientSecret,
    required String accessToken,
    required String refreshToken,
    required double expiresAtSeconds,
  }) async {
    _requireText(clientId, 'clientId');
    _requireSecret(clientSecret, 'clientSecret');
    _requireSecret(accessToken, 'accessToken');
    _requireSecret(refreshToken, 'refreshToken');
    if (!expiresAtSeconds.isFinite || expiresAtSeconds <= 0) {
      throw ArgumentError.value(
        expiresAtSeconds,
        'expiresAtSeconds',
        '必须是正的有限数值',
      );
    }
    await _channel.invokeMethod<Object?>('writeStravaAuthorization', {
      'clientId': clientId,
      'clientSecret': clientSecret,
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'expiresAtSeconds': expiresAtSeconds,
    });
  }

  Future<void> clearAuthorization() async {
    await _channel.invokeMethod<Object?>('clearStravaAuthorization');
  }
}

/// 复用旧应用 UserDefaults 键的最小 Flutter 通道。
final class PreferencesChannel {
  const PreferencesChannel()
    : _channel = const MethodChannel('health_workout_export/preferences');

  final MethodChannel _channel;

  Future<Object?> read(String key) {
    _requirePreferenceKey(key);
    return _channel.invokeMethod<Object?>('read', {'key': key});
  }

  Future<void> write(String key, Object value) async {
    _requirePreferenceKey(key);
    if (value is! String &&
        value is! bool &&
        value is! int &&
        value is! double) {
      throw ArgumentError.value(value, 'value', '必须是 UserDefaults 标量');
    }
    if (value is double && !value.isFinite) {
      throw ArgumentError.value(value, 'value', '必须是有限数值');
    }
    await _channel.invokeMethod<Object?>('write', {'key': key, 'value': value});
  }

  Future<void> delete(String key) async {
    _requirePreferenceKey(key);
    await _channel.invokeMethod<Object?>('delete', {'key': key});
  }
}

enum StravaUploadMode { api, web }

/// 旧 SwiftUI 与 Flutter 共用的 Strava 设置快照。
final class StravaSettingsSnapshot {
  const StravaSettingsSnapshot({
    required this.mode,
    required this.clientId,
    required this.hasClientSecret,
    required this.hasAccessToken,
    required this.hasRefreshToken,
    required this.expiresAtSeconds,
    required this.hasWebCookie,
    required this.gcjCorrectionEnabled,
  });

  final StravaUploadMode mode;
  final String clientId;
  final bool hasClientSecret;
  final bool hasAccessToken;
  final bool hasRefreshToken;
  final double expiresAtSeconds;
  final bool hasWebCookie;
  final bool gcjCorrectionEnabled;

  bool get isApiReady =>
      clientId.isNotEmpty &&
      hasClientSecret &&
      hasAccessToken &&
      hasRefreshToken;

  bool get isWebReady => hasWebCookie;
}

/// 通过专用 vault 读取 Strava 安全状态，并用旧 UserDefaults 键保留非敏感设置。
final class StravaSettingsStore {
  const StravaSettingsStore({
    this.vault = const StravaVaultChannel(),
    this.preferences = const PreferencesChannel(),
    this.web = const StravaWebChannel(),
  });

  final StravaVaultChannel vault;
  final PreferencesChannel preferences;
  final StravaWebChannel web;

  Future<StravaSettingsSnapshot> load() async {
    final vaultStatus = await vault.status();
    final hasWebCookie = await web.hasCookie();
    final modeValue = await preferences.read(_modeKey);
    final correctionValue = await preferences.read(_gcjCorrectionKey);

    final mode = switch (modeValue) {
      'web' => StravaUploadMode.web,
      _ => StravaUploadMode.api,
    };
    if (correctionValue != null && correctionValue is! bool) {
      throw const FormatException('Strava 坐标纠偏设置无效');
    }
    return StravaSettingsSnapshot(
      mode: mode,
      clientId: vaultStatus.clientId,
      hasClientSecret: vaultStatus.hasClientSecret,
      hasAccessToken: vaultStatus.hasAccessToken,
      hasRefreshToken: vaultStatus.hasRefreshToken,
      expiresAtSeconds: vaultStatus.expiresAtSeconds,
      hasWebCookie: hasWebCookie,
      gcjCorrectionEnabled: correctionValue as bool? ?? false,
    );
  }

  Future<void> saveAuthorization({
    required String clientId,
    required String clientSecret,
    required String accessToken,
    required String refreshToken,
    required double expiresAtSeconds,
  }) async {
    final normalizedId = clientId.trim();
    final normalizedSecret = clientSecret.trim();
    _requireText(normalizedId, 'clientId');
    _requireSecret(normalizedSecret, 'clientSecret');
    _requireSecret(accessToken, 'accessToken');
    _requireSecret(refreshToken, 'refreshToken');
    if (!expiresAtSeconds.isFinite || expiresAtSeconds <= 0) {
      throw ArgumentError.value(
        expiresAtSeconds,
        'expiresAtSeconds',
        '必须是正的有限数值',
      );
    }
    await vault.commitAuthorization(
      clientId: normalizedId,
      clientSecret: normalizedSecret,
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAtSeconds: expiresAtSeconds,
    );
  }

  Future<void> setMode(StravaUploadMode mode) =>
      preferences.write(_modeKey, mode.name);

  Future<void> setGcjCorrectionEnabled(bool enabled) =>
      preferences.write(_gcjCorrectionKey, enabled);

  Future<void> clearAuthorization() => vault.clearAuthorization();

  static const _modeKey = 'strava.uploadMode';
  static const _gcjCorrectionKey = 'strava.gcjCorrectionEnabled';
}

const _allowedPreferenceKeys = <String>{
  'strava.uploadMode',
  'strava.gcjCorrectionEnabled',
  'virtualPower.enabled',
  'virtualPower.includeInertia',
  'virtualPower.riderMassKg',
  'virtualPower.bikeMassKg',
  'virtualPower.cda',
};

void _requirePreferenceKey(String key) {
  if (!_allowedPreferenceKeys.contains(key)) {
    throw ArgumentError.value(key, 'key', '不是允许的应用设置键');
  }
}

/// iOS 系统浏览器中的 Strava OAuth 授权边界；token 交换由 Rust 负责。
final class StravaOAuthChannel {
  const StravaOAuthChannel()
    : _channel = const MethodChannel('health_workout_export/strava_oauth');

  final MethodChannel _channel;

  static Uri authorizationUri(String clientId) {
    final normalizedId = clientId.trim();
    _requireText(normalizedId, 'clientId');
    return Uri.https('www.strava.com', '/oauth/mobile/authorize', {
      'client_id': normalizedId,
      'redirect_uri': 'healthworkoutexport://localhost/callback',
      'response_type': 'code',
      'approval_prompt': 'auto',
      'scope': 'activity:read_all,activity:write,read',
    });
  }

  Future<String> authorize(Uri authorizationUrl) async {
    if (authorizationUrl.scheme != 'https' ||
        authorizationUrl.host != 'www.strava.com' ||
        authorizationUrl.path != '/oauth/mobile/authorize') {
      throw ArgumentError.value(
        authorizationUrl,
        'authorizationUrl',
        '必须是 Strava 授权地址',
      );
    }
    final code = await _channel.invokeMethod<String>('authorize', {
      'authorizationUrl': authorizationUrl.toString(),
      'callbackScheme': 'healthworkoutexport',
    });
    if (code == null || code.isEmpty) {
      throw const FormatException('Strava OAuth 未返回授权码');
    }
    return code;
  }
}

/// Strava 网页登录与系统 Cookie 清理边界；界面只使用 readiness，不展示凭据。
final class StravaWebChannel {
  const StravaWebChannel()
    : _channel = const MethodChannel('health_workout_export/strava_web');

  final MethodChannel _channel;

  Future<bool> login() async {
    final ready = await _channel.invokeMethod<bool>('login');
    if (ready == null) {
      throw const FormatException('Strava 网页登录未返回状态');
    }
    return ready;
  }

  Future<bool> hasCookie() async {
    final ready = await _channel.invokeMethod<bool>('hasCookie');
    if (ready == null) {
      throw const FormatException('Strava 网页登录状态为空');
    }
    return ready;
  }

  Future<void> clearCookies() async {
    await _channel.invokeMethod<Object?>('clearCookies');
  }
}

/// iOS HealthKit 的可用性、授权与轻量训练摘要通道。
final class HealthKitChannel {
  const HealthKitChannel()
    : _channel = const MethodChannel('health_workout_export/healthkit');

  final MethodChannel _channel;

  Future<bool> isAvailable() async {
    final available = await _channel.invokeMethod<bool>('isAvailable');
    if (available == null) {
      throw const FormatException('HealthKit 可用性返回为空');
    }
    return available;
  }

  Future<void> requestAuthorization() async {
    await _channel.invokeMethod<Object?>('requestAuthorization');
  }

  Future<void> openSettings() async {
    await _channel.invokeMethod<Object?>('openSettings');
  }

  /// 返回 iOS 系统当前 IANA 时区标识，供导出保持旧 Swift JSON 契约。
  Future<String> currentTimeZoneIdentifier() async {
    final identifier = await _channel.invokeMethod<String>(
      'currentTimeZoneIdentifier',
    );
    if (identifier == null || identifier.trim().isEmpty) {
      throw const FormatException('系统时区标识为空');
    }
    return identifier;
  }

  /// 查询半开区间 [start, endExclusive) 内开始的训练。
  Future<List<HealthWorkoutSummary>> listWorkouts({
    required DateTime start,
    required DateTime endExclusive,
  }) async {
    if (!start.isBefore(endExclusive)) {
      throw ArgumentError.value(endExclusive, 'endExclusive', '必须晚于 start');
    }
    final result = await _channel.invokeMethod<List<Object?>>('listWorkouts', {
      'startMs': start.millisecondsSinceEpoch,
      'endMs': endExclusive.millisecondsSinceEpoch,
    });
    if (result == null) {
      throw const FormatException('HealthKit 训练列表返回为空');
    }
    return result.map(HealthWorkoutSummary.fromObject).toList(growable: false);
  }

  /// 一次批量读取完整训练明细，返回顺序必须与 UUID 输入一致。
  Future<List<HealthWorkoutBundle>> fetchWorkoutBundles(
    List<String> uuids,
  ) async {
    if (uuids.isEmpty) throw ArgumentError.value(uuids, 'uuids', '不能为空');
    final normalized = <String>{};
    for (final uuid in uuids) {
      if (!_uuidPattern.hasMatch(uuid) || !normalized.add(uuid.toLowerCase())) {
        throw ArgumentError.value(uuids, 'uuids', '必须是无重复的 UUID');
      }
    }
    final result = await _channel.invokeMethod<List<Object?>>(
      'fetchWorkoutBundles',
      {'uuids': uuids},
    );
    if (result == null || result.length != uuids.length) {
      throw const FormatException('HealthKit 完整训练数量与请求不一致');
    }
    final bundles = result
        .map(HealthWorkoutBundle.fromObject)
        .toList(growable: false);
    for (var index = 0; index < bundles.length; index++) {
      if (bundles[index].summary.uuid.toLowerCase() !=
          uuids[index].toLowerCase()) {
        throw const FormatException('HealthKit 完整训练顺序与请求不一致');
      }
    }
    return bundles;
  }
}

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

/// HealthKit 完整训练包；FIT 编码直接消费这一批量模型。
final class HealthWorkoutBundle {
  const HealthWorkoutBundle({
    required this.summary,
    required this.metadata,
    required this.events,
    required this.series,
    required this.route,
  });

  factory HealthWorkoutBundle.fromObject(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('HealthKit 完整训练必须是对象');
    }
    final metadata = _requiredMap(value, 'metadata').map((key, item) {
      if (key is! String || item is! String) {
        throw const FormatException('metadata 必须是字符串对象');
      }
      return MapEntry(key, item);
    });
    final events = _requiredList(
      value,
      'events',
    ).map(HealthWorkoutEvent.fromObject).toList(growable: false);
    final series = _requiredMap(value, 'series').map((key, item) {
      if (key is! String || item is! List<Object?>) {
        throw const FormatException('series 必须是样本数组对象');
      }
      return MapEntry(
        key,
        item.map(HealthQuantitySample.fromObject).toList(growable: false),
      );
    });
    final route = _requiredList(
      value,
      'route',
    ).map(HealthRoutePoint.fromObject).toList(growable: false);
    return HealthWorkoutBundle(
      summary: HealthWorkoutSummary.fromObject(value),
      metadata: Map.unmodifiable(metadata),
      events: List.unmodifiable(events),
      series: Map.unmodifiable(series),
      route: List.unmodifiable(route),
    );
  }

  final HealthWorkoutSummary summary;
  final Map<String, String> metadata;
  final List<HealthWorkoutEvent> events;
  final Map<String, List<HealthQuantitySample>> series;
  final List<HealthRoutePoint> route;
}

final class HealthWorkoutEvent {
  const HealthWorkoutEvent({required this.type, required this.dateMs});

  factory HealthWorkoutEvent.fromObject(Object? value) {
    final map = _objectMap(value, 'HealthKit 训练事件');
    return HealthWorkoutEvent(
      type: _requiredText(map, 'type'),
      dateMs: _requiredInt(map, 'dateMs'),
    );
  }

  final String type;
  final int dateMs;

  @override
  bool operator ==(Object other) =>
      other is HealthWorkoutEvent &&
      other.type == type &&
      other.dateMs == dateMs;

  @override
  int get hashCode => Object.hash(type, dateMs);
}

final class HealthQuantitySample {
  const HealthQuantitySample({
    required this.dateMs,
    required this.value,
    required this.unit,
  });

  factory HealthQuantitySample.fromObject(Object? value) {
    final map = _objectMap(value, 'HealthKit quantity 样本');
    return HealthQuantitySample(
      dateMs: _requiredInt(map, 'dateMs'),
      value: _requiredFiniteDouble(map, 'value'),
      unit: _requiredText(map, 'unit'),
    );
  }

  final int dateMs;
  final double value;
  final String unit;

  @override
  bool operator ==(Object other) =>
      other is HealthQuantitySample &&
      other.dateMs == dateMs &&
      other.value == value &&
      other.unit == unit;

  @override
  int get hashCode => Object.hash(dateMs, value, unit);
}

final class HealthRoutePoint {
  const HealthRoutePoint({
    required this.latitude,
    required this.longitude,
    required this.altitudeMeters,
    required this.timestampMs,
    required this.speedMetersPerSecond,
  });

  factory HealthRoutePoint.fromObject(Object? value) {
    final map = _objectMap(value, 'HealthKit 路线点');
    final latitude = _requiredFiniteDouble(map, 'latitude');
    final longitude = _requiredFiniteDouble(map, 'longitude');
    final speed = _optionalFiniteDouble(map, 'speedMetersPerSecond');
    if (latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180 ||
        (speed != null && speed < 0)) {
      throw const FormatException('HealthKit 路线点坐标或速度无效');
    }
    return HealthRoutePoint(
      latitude: latitude,
      longitude: longitude,
      altitudeMeters: _optionalFiniteDouble(map, 'altitudeMeters'),
      timestampMs: _optionalInt(map, 'timestampMs'),
      speedMetersPerSecond: speed,
    );
  }

  final double latitude;
  final double longitude;
  final double? altitudeMeters;
  final int? timestampMs;
  final double? speedMetersPerSecond;

  @override
  bool operator ==(Object other) =>
      other is HealthRoutePoint &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.altitudeMeters == altitudeMeters &&
      other.timestampMs == timestampMs &&
      other.speedMetersPerSecond == speedMetersPerSecond;

  @override
  int get hashCode => Object.hash(
    latitude,
    longitude,
    altitudeMeters,
    timestampMs,
    speedMetersPerSecond,
  );
}

/// HealthKit 列表所需的轻量训练摘要。
final class HealthWorkoutSummary {
  const HealthWorkoutSummary({
    required this.uuid,
    required this.startMs,
    required this.endMs,
    required this.durationSeconds,
    required this.activityType,
    required this.activityName,
    required this.sourceName,
    required this.sourceBundleId,
    required this.totalEnergyKcal,
    required this.totalDistanceMeters,
  });

  factory HealthWorkoutSummary.fromObject(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('HealthKit 训练摘要必须是对象');
    }
    return HealthWorkoutSummary(
      uuid: _requiredText(value, 'uuid'),
      startMs: _requiredInt(value, 'startMs'),
      endMs: _requiredInt(value, 'endMs'),
      durationSeconds: _requiredDouble(value, 'durationSeconds'),
      activityType: _requiredInt(value, 'activityType'),
      activityName: _requiredText(value, 'activityName'),
      sourceName: _optionalText(value, 'sourceName'),
      sourceBundleId: _optionalText(value, 'sourceBundleId'),
      totalEnergyKcal: _optionalDouble(value, 'totalEnergyKcal'),
      totalDistanceMeters: _optionalDouble(value, 'totalDistanceMeters'),
    );
  }

  final String uuid;
  final int startMs;
  final int endMs;
  final double durationSeconds;
  final int activityType;
  final String activityName;
  final String? sourceName;
  final String? sourceBundleId;
  final double? totalEnergyKcal;
  final double? totalDistanceMeters;

  @override
  bool operator ==(Object other) =>
      other is HealthWorkoutSummary &&
      other.uuid == uuid &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.durationSeconds == durationSeconds &&
      other.activityType == activityType &&
      other.activityName == activityName &&
      other.sourceName == sourceName &&
      other.sourceBundleId == sourceBundleId &&
      other.totalEnergyKcal == totalEnergyKcal &&
      other.totalDistanceMeters == totalDistanceMeters;

  @override
  int get hashCode => Object.hash(
    uuid,
    startMs,
    endMs,
    durationSeconds,
    activityType,
    activityName,
    sourceName,
    sourceBundleId,
    totalEnergyKcal,
    totalDistanceMeters,
  );
}

void _requireText(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, '不能为空');
  }
}

void _requireSecret(String value, String name) {
  if (value.trim().isEmpty) throw ArgumentError('不能为空', name);
}

String _requiredText(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key 必须是非空字符串');
  }
  return value;
}

String? _optionalText(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key 必须是字符串或空值');
  return value;
}

int _requiredInt(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! int) throw FormatException('$key 必须是整数');
  return value;
}

double _requiredDouble(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! num) throw FormatException('$key 必须是数字');
  return value.toDouble();
}

bool _requiredBool(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! bool) throw FormatException('$key 必须是布尔值');
  return value;
}

double? _optionalDouble(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! num) throw FormatException('$key 必须是数字或空值');
  return value.toDouble();
}

Map<Object?, Object?> _objectMap(Object? value, String name) {
  if (value is! Map<Object?, Object?>) throw FormatException('$name 必须是对象');
  return value;
}

Map<Object?, Object?> _requiredMap(Map<Object?, Object?> map, String key) =>
    _objectMap(map[key], key);

List<Object?> _requiredList(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! List<Object?>) throw FormatException('$key 必须是数组');
  return value;
}

int? _optionalInt(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! int) throw FormatException('$key 必须是整数或空值');
  return value;
}

double _requiredFiniteDouble(Map<Object?, Object?> map, String key) {
  final value = _requiredDouble(map, key);
  if (!value.isFinite) throw FormatException('$key 必须是有限数字');
  return value;
}

double? _optionalFiniteDouble(Map<Object?, Object?> map, String key) {
  final value = _optionalDouble(map, key);
  if (value != null && !value.isFinite) {
    throw FormatException('$key 必须是有限数字或空值');
  }
  return value;
}
