# Native Android validation

This independent Android library compiles the **production** adapters and their native tests. It does not run Flutter, Dart, flutter_rust_bridge generation, Rust hooks, or an NDK build.

Requirements: JDK 17, Gradle 9.1, Android SDK platform 36, a Flutter SDK checkout matching `.fvmrc`, and access to the official Google/Maven Central/Flutter repositories. AGP 9.0.1 supplies built-in Kotlin support. The Flutter embedding dependency is pinned to that checkout's `bin/internal/engine.version`.

```sh
export ANDROID_HOME=/path/to/android-sdk
export FLUTTER_ROOT=/path/to/flutter
# Keep existing SDK licenses and TLS checks; never bypass a certificate failure.
gradle -p flutter_app/android/native_validation \
  -PflutterSdk="$FLUTTER_ROOT" testDebugUnitTest assembleDebug
```

Test results: `flutter_app/android/native_validation/build/test-results/testDebugUnitTest/`.

This checks compilation and deterministic conversion/transport tests. It does not validate real Health Connect providers, permission revocation, per-route consent, OEM lifecycle behavior, real account authentication, or production uploads/deletions. Those require device acceptance tests with user-controlled data and permissions. The release owner must also ensure the in-app Health Connect rationale matches the privacy policy declared in Play Console.

## Keep vault checks without an Android SDK

`KeepVaultTest.kt` is included in the normal native unit test task. It covers
strict account/token-only input, nonsecret status, encrypted single-record
replacement, failed-commit rollback, fail-closed recovery, clear, and isolation
from other providers. Every test uses synthetic credentials and real JVM AES-GCM;
Android Keystore provisioning and SharedPreferences disk I/O are substituted.

For environments without the Android toolchain, the same tests can run against
the production `SecretStore` classes extracted from `MainActivity.kt`:

```sh
python3 flutter_app/android/native_validation/test_keep_vault_contract.py
python3 flutter_app/android/native_validation/run_keep_vault_jvm_tests.py --jars /path/to/kotlin-test-jars
```

The jar directory needs Kotlin compiler-embeddable 2.2.0 and its published runtime
dependencies, JetBrains annotations, JUnit 4.13.2, Hamcrest 1.3, and an Android API
stub jar. Use official Maven Central artifacts. The helper does not download or
install anything. It substitutes only Keystore type signatures for compilation
and does not validate the complete native adapter, device Keystore, or real
SharedPreferences failure/crash behavior. Run the Gradle task and device tests
before claiming native-platform acceptance.
