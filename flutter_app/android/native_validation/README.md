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
