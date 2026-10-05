import 'package:flutter/services.dart';

/// A short-lived Keep authorization lease. Never log or persist this object.
final class KeepVaultLease {
  const KeepVaultLease({required this.account, required this.token});

  factory KeepVaultLease.fromObject(Object? value) {
    final map = _map(value);
    return KeepVaultLease(
      account: _requiredText(map, 'account'),
      token: _requiredText(map, 'token'),
    );
  }

  final String account;
  final String token;

  @override
  String toString() => 'KeepVaultLease(credentials: <redacted>)';
}

final class KeepVaultStatus {
  const KeepVaultStatus({required this.hasAccount, required this.hasToken});

  factory KeepVaultStatus.fromObject(Object? value) {
    final map = _map(value);
    final account = map['hasAccount'];
    final token = map['hasToken'];
    if (account is! bool || token is! bool) {
      throw const FormatException('Keep 登录状态无效');
    }
    return KeepVaultStatus(hasAccount: account, hasToken: token);
  }

  final bool hasAccount;
  final bool hasToken;
  bool get isConfigured => hasAccount && hasToken;
}

/// Fixed-purpose OS secure storage. Keep passwords are never accepted here.
final class KeepVaultChannel {
  const KeepVaultChannel();
  static const _channel = MethodChannel(
    'health_workout_export/third_party_vault',
  );

  Future<KeepVaultStatus> status() async => KeepVaultStatus.fromObject(
    await _channel.invokeMethod<Object?>('keepStatus'),
  );

  Future<KeepVaultLease> lease() async => KeepVaultLease.fromObject(
    await _channel.invokeMethod<Object?>('keepLease'),
  );

  Future<void> commitAuthorization({
    required String account,
    required String token,
  }) async {
    if (!_validText(account) || !_validText(token)) {
      // Never attach the rejected value to an error (it may be a credential).
      throw ArgumentError('Keep 账号和登录凭据必须非空且不包含空字符');
    }
    await _channel.invokeMethod<Object?>('writeKeepAuthorization', {
      'account': account,
      'token': token,
    });
  }

  Future<void> clearAuthorization() =>
      _channel.invokeMethod<void>('clearKeepAuthorization');

  /// Destructive recovery only after explicit confirmation. No old data is read.
  Future<void> resetAuthorization() =>
      _channel.invokeMethod<void>('resetKeepAuthorization');
}

Map<Object?, Object?> _map(Object? value) {
  if (value is! Map) throw const FormatException('Keep 凭据数据无效');
  return Map<Object?, Object?>.from(value);
}

String _requiredText(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! String || !_validText(value)) {
    throw const FormatException('Keep 凭据数据无效');
  }
  return value;
}

bool _validText(String value) =>
    value.trim().isNotEmpty && !value.contains('\u0000');
