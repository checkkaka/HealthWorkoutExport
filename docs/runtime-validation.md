# Synthetic runtime acceptance

This extends the compile/test evidence with applications launched on real target
runtimes: an Android AVD, an installed iOS Simulator, and native macOS/Windows
desktop processes on standard hosted runners. Run only in disposable test
accounts/devices. It is not a physical-device or production-account acceptance.

## Three phases per platform

1. `startup`: initialize the bundled Rust library, encode and inspect a synthetic
   FIT through FFI, probe native health availability without authorization, round
   trip native preferences, render the production app and navigate its tabs and
   merge page. Capture the rendered app surface.
2. `seed`: repeat startup checks; cancel a synthetic file selection, suppress a
   repeated click while selection is pending, import two real local fixture files,
   assert the real automatic-alignment rejection for a two-sample fixture, select
   explicit absolute-time alignment for its known shared clock, use production
   Rust merge, write/read a real exported FIT, view production
   detail/quality charts, and cancel deletion. Persist a pending record and FIT
   using the native sync-files plugin and a production recovery checkpoint.
3. `verify`: after the host terminates the seed process without clearing app data,
   a separately launched process verifies the exact FIT, preferences, pending
   record and checkpoint; `AutoSyncSession.restore()` must recover the queue
   without starting any network operation. Remove only reserved synthetic records.

The host records target PIDs, native termination checks and different seed/verify
PIDs. Each phase must complete its assertions and provide valid PNG screenshots.
Failed launches, absent interactive sessions, missing simulator runtimes and
unavailable components fail honestly. Android uses documented software emulation
when KVM is inaccessible, records the mode, and fails if boot does not complete
within its explicit 20-minute software-mode limit. Host permissions are unchanged.

## Real and synthetic boundaries

Real: Flutter engine/application widgets, bundled Rust dynamic library and FFI,
FIT bytes/merge/inspection, local file reads/writes, native preferences and sync
storage, production checkpoint decoding and session restoration, app process
termination/relaunch. No manual generated binding changes are required.

Synthetic: fixture workout data; health availability response used by the UI
(after a separate real native capability probe); file-picker selection; sharing
callback. The generated export is read and validated, but OS file-picker/share
windows are not automated. No HealthKit/Health Connect grant/read/write, OAuth,
third-party credentials, activity upload/delete, weather service or map tiles.
Android Health Connect remains read/export/Strava only.

Screenshots capture the application's Flutter-rendered surface using a real
render boundary. They do not prove native permission dialogs or desktop chrome.
Health provider availability in an AOSP image is not Health Connect permission or
record access coverage. Simulator capabilities do not prove sensor, background,
performance or physical-device behavior.

## Safety and evidence

- Existing pinned Flutter/Rust setup; committed bindings; no code generation
- Flutter analytics suppressed in every subprocess and validation uses `--no-pub`
- Official Android emulator has explicit `-no-metrics`; no bulk SDK license
  acceptance, KVM permission changes or extra agreements
- iOS uses only available installed runtimes; no provisioning/signing account
- Standard hosted runner labels; no deployments/releases/paid device farms
- Results, rendered screenshots, bounded logs and restart proof retained as
  Actions artifacts for seven days, containing synthetic data only
- `flutter drive --keep-app-running` avoids its default app removal; the host
  stops the native process without clearing the persistent test data

The workflow is `.github/workflows/runtime-validation.yml`; orchestrator and
host driver are `scripts/runtime_validation.py` and
`flutter_app/test_driver/runtime_driver.dart`. Tests live in
`flutter_app/integration_test/runtime_test.dart`.

Runtime acceptance status is the workflow result for the exact PR head. Adding
these tests does not itself establish a pass; refer to the run and its per-phase
reports. Existing compile/static/unit-test checks continue separately.

## macOS synthetic-health Debug artifact

The original ad-hoc build was blocked at launch by AMFI: its code signature was
valid on disk, but the app requested a restricted entitlement without a matching
provisioning identity. No OS enforcement is disabled to work around that result.

For the approved synthetic boundary, macOS runtime validation creates an explicitly
identified `com.checkkaka.HealthWorkoutExport.SyntheticHealthRuntime` Debug test
artifact. Its generated xcconfig is Debug-only; it removes only the HealthKit
entitlement from a copy of the production Debug entitlements and omits HealthKit
plugin registration under an explicit test compilation condition. Sandbox and
all other original entitlements are retained. Release/Profile are rejected by
the generator. Both production entitlement source hashes must remain unchanged,
and the built artifact's identity, signature and actual entitlements are checked
before it is launched. Flutter drives this exact prebuilt artifact.

This artifact tests UI/Rust/files/recovery, not the production HealthKit-enabled
launch or native HealthKit capability. The report and screenshots label this
scope. Production signed HealthKit launch requires a legitimate signing environment.
All platforms use an integration entry that initializes real Rust and renders the
production root widgets; this is not the unmodified end-user `startApp()` entry.

Android builds all three x86_64 Debug test APKs before starting the software AVD,
then installs the exact prebuilt artifact for each phase. This avoids heavy
Rust/Gradle compilation competing with the unaccelerated Android system server.
Both boot completion and a responding package service are required; losing the
service fails the run rather than pretending the app was tested. APK hashes are
recorded, but the APKs are not uploaded/distributed with the evidence artifacts.

Android's on-device phase budget is 12 minutes (other platforms: 4), reported in
each result. The driver remains bounded at 15 minutes and the host command at
30 minutes. All required checks still must finish. Software-emulated frame timing
is infrastructure evidence, not a claim about physical-device app performance.

Acceptance requires an explicit final phase-completion marker written only after
all awaited screenshots/cleanup and Flutter exception checks. Partial reports are
retained for diagnosis but cannot pass, even if their mutable checklist is full.
The host also rejects Flutter framework failure/timeout output when the official
integration driver incorrectly reports success. Verify requires cleanup, and
each phase requires its final screenshot.
