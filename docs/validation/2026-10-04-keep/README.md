# Keep running validation — 2026-10-04

Migration baseline: `codex/flutter-rust-migration` at `76a62ab`.

- Rust: **207 tests pass**, strict clippy and formatting clean
- Flutter: **310 tests pass**, analyzer clean, including actual generated Rust FFI calls
- Device-local timestamp regression: passes with **TZ=Asia/Shanghai**, retained in CI
- Android vault: **17 synthetic JVM tests**, **3 source-contract checks**
- Windows: **277 portable assertions**, new Keep production-dispatch test and source contract pass
- Repository validation scripts: **35 tests pass**
- Independent reviews: seven issues fixed with regression tests across two review rounds; no remaining actionable findings

Bindings were generated in an isolated snapshot with the repository's audited offline FRB adapter. The generator and children used literal verified executable hashes; no original upstream generator, analytics, account login or health upload was run. The staged crate passed a full Cargo check and eight relevant Flutter tests before six generated outputs were adopted. `generated-bindings.json` records their hashes and common content hash.

`verification.json` records final commands, outcomes and log digests. Full native Apple/Android/Windows application and OS-store runtime verification remains outstanding, as does real-account Keep/Strava acceptance. Linux tests do not establish those outcomes.

## Review fixes

1. Original detail maps preserve explicit WGS84 provenance
2. HealthKit detail navigation preserves known sport metadata
3. Keep UTC records display in the device's local day/time
4. Legacy Run recovery uses final-FIT classification for a consistent non-commute flag, with a cancellation recheck before starting upload

All network-facing tests use synthetic data and local mock responses. No production credentials or personal workout files are included.

## Follow-up review fixes

5. Reconstructing legacy cycling recovery without sport metadata preserves the commute candidate; the final-FIT Run guard still suppresses running commute
6. Unreadable Keep credentials expose retry and confirmed local reset. The native reset bypasses old-value parsing, deletes only fixed Keep records, and fails explicitly if deletion fails. Apple removes the journal first to prevent credential resurrection
7. Non-null malformed GPS/heart-rate payload types fail closed; absent/null/empty sample fields remain valid

Eight real-FFI regressions cover legacy Ride/Run recovery and replacement for both `healthkit` and old bundle-ID sources. Credential recovery has UI, Windows production-dispatch, Android JVM, and Apple source-boundary coverage. New Apple XCTest cases still require macOS/Xcode execution.

Flutter validation explicitly uses `BOT=true CI=true DASH__SUPPRESS_ANALYTICS=true FLUTTER_SUPPRESS_ANALYTICS=true` and `--suppress-analytics`. The official SDK's explicit bot environment short-circuits its unnecessary cloud metadata detector; no SDK or security/network settings were modified. All six generated binding hashes remain unchanged by these fixes.
