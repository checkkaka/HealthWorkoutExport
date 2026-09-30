#!/usr/bin/env bash
# Independent Dart/UI contracts only. This deliberately does not validate FFI.
set -euo pipefail
export BOT=true CI=true DASH__SUPPRESS_ANALYTICS=true
cd "$(dirname "$0")/../flutter_app"
flutter_bin="${FLUTTER_BIN:-flutter}"
excluded=(
  auto_sync_controller_test.dart
  fit_merge_page_test.dart
  rust_bridge_test.dart
  strava_settings_page_test.dart
  third_party_source_page_test.dart
  widget_test.dart
  workout_source_test.dart
)
tests=()
while IFS= read -r test; do
  skip=false
  for blocked in "${excluded[@]}"; do
    if [[ "$test" == "test/$blocked" ]]; then skip=true; break; fi
  done
  if [[ "$skip" == false ]]; then tests+=("$test"); fi
done < <(find test -name '*_test.dart' -type f | sort)
if [[ ${#tests[@]} -eq 0 ]]; then echo 'No contract tests found' >&2; exit 1; fi
printf 'Excluded stale-binding test: %s\n' "${excluded[@]}"
printf 'Running %s independent test files; full application check remains separate.\n' "${#tests[@]}"
"$flutter_bin" --suppress-analytics test --no-pub --reporter expanded "${tests[@]}"
