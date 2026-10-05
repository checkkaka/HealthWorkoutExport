import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_export/keep_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('health_workout_export/third_party_vault');
  const vault = KeepVaultChannel();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'keepStatus' => {'hasAccount': true, 'hasToken': true},
        'keepLease' => {
          'account': 'synthetic-account',
          'token': 'synthetic-token',
        },
        _ => null,
      };
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Keep status reports only presence and requires both fields', () async {
    expect((await vault.status()).isConfigured, isTrue);
    expect(
      KeepVaultStatus.fromObject({
        'hasAccount': true,
        'hasToken': false,
      }).isConfigured,
      isFalse,
    );
    expect(
      () =>
          KeepVaultStatus.fromObject({'hasAccount': 'true', 'hasToken': true}),
      throwsFormatException,
    );
    expect(calls.single.method, 'keepStatus');
  });

  test(
    'Keep lease requires account and token and redacts credentials',
    () async {
      final lease = await vault.lease();
      expect(lease.account, 'synthetic-account');
      expect(lease.token, 'synthetic-token');
      expect(lease.toString(), isNot(contains('synthetic')));
      expect(
        () => KeepVaultLease.fromObject({'account': 'account', 'token': ' '}),
        throwsFormatException,
      );
      expect(
        () => KeepVaultLease.fromObject({'account': 'account'}),
        throwsFormatException,
      );
    },
  );

  test(
    'Keep write sends only account and token through fixed method',
    () async {
      await vault.commitAuthorization(
        account: 'synthetic-account',
        token: 'synthetic-token',
      );
      expect(calls.single.method, 'writeKeepAuthorization');
      expect(calls.single.arguments, {
        'account': 'synthetic-account',
        'token': 'synthetic-token',
      });
      await vault.clearAuthorization();
      expect(calls.last.method, 'clearKeepAuthorization');
      expect(calls.last.arguments, isNull);
    },
  );

  test(
    'Keep reset uses a fixed no-argument method and propagates failures',
    () async {
      await vault.resetAuthorization();
      expect(calls.single.method, 'resetKeepAuthorization');
      expect(calls.single.arguments, isNull);
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'credential_store_error');
      });
      await expectLater(
        vault.resetAuthorization(),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'invalid Keep credentials never cross the method channel or leak in errors',
    () async {
      for (final token in ['', '  ', 'bad\u0000token']) {
        await expectLater(
          vault.commitAuthorization(account: 'account', token: token),
          throwsArgumentError,
        );
      }
      await expectLater(
        vault.commitAuthorization(account: ' ', token: 'synthetic-token'),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    },
  );
}
