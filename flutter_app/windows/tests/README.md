# Windows native adapter checks

## Independent Windows CI (no Dart build or FRB generation)

With Visual Studio C++/Windows SDK and an official Flutter **3.47.5 source
checkout**, run from the application repository root:

```powershell
cmake -S flutter_app/windows/tests -B build/windows-native -A x64 -DHWE_FLUTTER_SOURCE_DIR="C:/path/to/flutter" -DHWE_COMPILE_WINDOWS_ADAPTERS=ON
cmake --build build/windows-native --config Release
ctest --test-dir build/windows-native -C Release --output-on-failure
python flutter_app/windows/tests/check_native_contract.py
```

The target uses only Flutter C++ client-wrapper headers. It does not invoke the
Flutter executable, resolve Dart packages, generate FFI bindings, or build the
Dart app. It compiles every production Windows adapter with MSVC `/W4 /WX`,
links the WebView2/OAuth adapters, runs invalid-input dispatch checks without
network or credentials, tests OS ICU time-zone mapping, and runs the portable
security/protocol suites.

CMake downloads the pinned official Microsoft.Web.WebView2 **1.0.2903.40** SDK
from NuGet over verified TLS. To use an already-extracted official SDK, pass
`-DHWE_WEBVIEW2_SDK_DIR=C:/path/to/package`. Windows x64/ARM64/x86 loader selection
follows the compiler target architecture. No browser runtime is bundled or
installed by the app; interactive login requires the official Microsoft Edge
WebView2 Evergreen Runtime.

## Portable checks

```sh
cmake -S flutter_app/windows/tests -B /tmp/hwe-windows-validation
cmake --build /tmp/hwe-windows-validation
ctest --test-dir /tmp/hwe-windows-validation --output-on-failure
```

Without CMake:

```sh
for test in native_channel_validation strava_web oauth_validation; do
  g++ -std=c++17 -Wall -Wextra -Werror -pedantic -O2 \
    flutter_app/windows/tests/${test}_test.cpp -o /tmp/hwe-${test}
  /tmp/hwe-${test}
done
python3 flutter_app/windows/tests/check_native_contract.py
```

All credentials, cookies, HTTP responses and FIT bytes in tests are synthetic.
The portable suites use an in-memory HTTP transport and never contact Strava.

## Production boundaries

- Eight registered native channels, with asynchronous owning result lifetimes
  for OAuth/WebView2 and engine teardown before result disposal
- Atomic Credential Manager records for Strava, Xingzhe and Onelap; 2560-byte OS
  record bound, no fallback to plaintext. `onelap.refresh` retains its legacy
  name; an explicit token replaces it, omission/null clears it to avoid mixing
  accounts, logout deletes the record. Rust owns refresh-rotation fallback
- Current-user/SYSTEM protected `%LOCALAPPDATA%\HealthWorkoutExport` storage:
  16 MiB state, 64 MiB FIT, 90 MiB recovery, 4 MiB `auto-sync-batch.json`, and
  allowlisted typed preferences. Reparse/hard-link rejection, JSON quarantine,
  same-directory atomic replacement and flush-before-replace
- Isolated protected WebView2 profile, native cookie handling, disabled password
  saving/autofill/host objects/web messaging, denied permissions and downloads,
  constrained HTTPS login navigation. Login success requires a verified activity
  listing response; anonymous cookies alone are never reported authenticated
- Native fixed-origin HTTPS CSRF uploads, one-shot deletion, bounded paginated
  listing, and activity HTML/optional speed streams. Automatic redirects, shared
  cookies and authentication are disabled; no certificate checks are bypassed.
  An uncertain upload/delete reports possible remote effects and is not replayed
- System-browser OAuth uses exclusive ephemeral IPv4 loopback, random state,
  strict request/callback/scope checks, cancellation and a five-minute deadline.
  The established Dart authorization input is validated before replacing its
  redirect with Strava's documented allowlisted loopback. No persistent URI
  protocol registration or third-party account action occurs during tests
- Full OS ICU/CLDR Windows-to-IANA mapping (System32 ICU, Windows 10 1703+), with
  explicit failure for unknown mappings. No guessed or partial timezone table
- HealthKit is explicitly unavailable on Windows; native FIT import remains
  available. Numeric Strava activity IDs open only the fixed Strava URL

LocalAppData/DACLs do not promise exclusion from arbitrary third-party backup
software. HTTP operations use a worker with total/OS timeouts; cancellation
prevents subsequent work, while an already-running synchronous OS call finishes
within its timeout and cannot report stale success.

## Still required for platform acceptance

- Full Flutter debug/release build after generated bindings are available
- Credential Manager save/lease/restart/logout and failed-write behavior
- DACL inspection, locked/inaccessible storage, reparse/hard-link attacks,
  corrupt JSON quarantine, interrupted replacement, durable batch recovery
- Real-account OAuth grant/denial/cancel and WebView2 login/restart/logout,
  provider/2FA challenges, authenticated FIT upload, duplicate handling,
  exact-target overwrite deletion and history speed inspection
- Picker cancellation/reopen, long/Unicode filenames, oversized files
- Window lifecycle, high DPI, keyboard and Narrator

Portable and native CI results must be reported separately from these interactive
acceptance checks. Passing compilation does not prove real-account parity.

References: Microsoft WebView2 Win32 CookieManager/Settings4 documentation,
Microsoft Windows ICU documentation, and https://developers.strava.com/docs/authentication/
