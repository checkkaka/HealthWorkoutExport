# Keep Running Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add an experimental Keep account source and upload outdoor/indoor running records to Strava without cycling regressions.

**Architecture:** A bounded Rust Keep adapter normalizes source data to running FIT. Flutter adds secure login/source UI and sport/datum-aware sync metadata. Existing Strava upload, recovery, and dedup infrastructure is extended rather than duplicated.

**Tech Stack:** Flutter 3.47.5, Rust 1.98.1, flutter_rust_bridge 2.12.0, existing native secure stores

**Spec:** `docs/superpowers/specs/2026-10-04-keep-running-design.md`

## Global Constraints
- No real credentials, real health uploads, paid services, merge, push, or deployment
- No Android Health Connect writing, analytics calls, or security-control weakening
- Preserve cycling and saved offline data
- Regenerate bindings with audited offline adapter only

## Review Focus
- Keep HTTP200 login/list failures must not masquerade as valid empty success
- Legacy and new timestamp forms must normalize within the source session window
- Indoor/noGPS runs must upload honestly with preserved duration/distance
- Unknown or conflicting sport must not attach a wrong duplicate ID or supplement
- Cancellation/restart must preserve completed remote effects and final FIT bytes

### Task 1: Keep Rust adapter
**Files:** new `rust/workout_core/src/keep.rs`, `src/api/keep.rs`; extend `api/mod.rs`, `lib.rs`, `Cargo.toml`, `Cargo.lock`, and minimally `health_fit.rs`
**Interfaces:** `keepLogin(operationHandle, account, password)` returns token; `keepListWorkouts(operationHandle, token, fromSeconds, toSeconds)` returns string ID/title, start/end seconds, duration/distance, indoor; `keepDownloadFit(operationHandle, token, workoutId)` returns WGS84 running FIT. Reserve/cancel/release return opaque generation handles.
- [x] Write synthetic protocol/decode/FIT tests, run failing tests
- [x] Implement bounded endpoint/protocol/decoder logic and registry wrapper
- [x] Verify all new fixtures plus Rust suite; retain source attribution

### Task 2: Keep secure login and source UI
**Files:** new `keep_vault.dart`, `keep_source_page.dart`, tests; native third-party vault handlers/tests for Apple, Android and Windows
**Interfaces:** `keepStatus`, `keepLease`, `writeKeepAuthorization`, `clearKeepAuthorization` on existing third-party vault channel; only account/token are stored. `KeepSourcePage` uses common WorkoutSource/AutoSyncPage.
- [x] Write vault atomicity/validation, expiry/cancel/logout/widget tests and run failing tests
- [x] Add platform storage methods and Keep source page
- [x] Verify new UI/native contracts without widening health access

### Task 3: Run-safe shared sync
**Files:** `workout_source.dart`, `main.dart`, `auto_sync_controller.dart`, `auto_sync_checkpoint.dart`, `auto_sync_session.dart`, `sync_state_store.dart`, `sync_recovery_runner.dart`, `sync_history_logic.dart`, `activity_sync_status.dart`, matching tests
**Interfaces:** `WorkoutActivity.sportType` optional Strava sport, `coordinatesWgs84` and `indoor`; preserved in state/checkpoints. Keep is explicit Run/WGS84. Safe normalized compatibility is required for approximate matches.
- [x] Test Keep registration and metadata; 3km Run commute=false; Ride/Run separation; WGS84 immunity to global GCJ option; legacy checkpoint/recovery compatibility
- [x] Implement source registry/tab and metadata flow, filter matches, suppress cycling processing on runs
- [x] Run targeted tests then full Flutter suite

### Task 4: Strava/FIT contracts and bridge
**Files:** Rust `strava.rs`, `fit_merge.rs`, `api/simple.rs`; generated FRB outputs; relevant tests/docs
**Interfaces:** existing FIT upload signatures remain; derive Run/treadmill from FIT session. Remote list result carries optional sport type.
- [x] Test Run/trainer multipart, no running commute, >=1s polling, auth/cancel/errors, remote sport and incompatible FIT supplement handling
- [x] Implement contract extensions; regenerate through audited offline adapter
- [x] Verify generated hashes, Rust tests/clippy, Flutter analyze/full tests and native contract tests
- [x] Independent whole-diff review; fix safety/correctness issues with regression tests
