import 'package:flutter/services.dart';

/// iOS Keychain 的最小 Flutter 通道。
final class KeychainChannel {
  const KeychainChannel()
    : _channel = const MethodChannel('health_workout_export/keychain');

  final MethodChannel _channel;

  Future<String?> read(String account) {
    _requireText(account, 'account');
    return _channel.invokeMethod<String>('read', {'account': account});
  }

  Future<void> write(String account, String value) async {
    _requireText(account, 'account');
    _requireText(value, 'value');
    await _channel.invokeMethod<Object?>('write', {
      'account': account,
      'value': value,
    });
  }

  Future<void> delete(String account) async {
    _requireText(account, 'account');
    await _channel.invokeMethod<Object?>('delete', {'account': account});
  }
}

/// iOS 系统浏览器中的 Strava OAuth 授权边界；token 交换由 Rust 负责。
final class StravaOAuthChannel {
  const StravaOAuthChannel()
    : _channel = const MethodChannel('health_workout_export/strava_oauth');

  final MethodChannel _channel;

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

double? _optionalDouble(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! num) throw FormatException('$key 必须是数字或空值');
  return value.toDouble();
}
