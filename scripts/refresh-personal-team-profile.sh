#!/usr/bin/env bash
# ponytail: Personal Team profiles last 7 days; Xcode reuses unexpired ones.
# Run this, then Run in Xcode, to mint a new 7-day window. Paid TTL>7 left alone.
set -euo pipefail

team="${DEVELOPMENT_TEAM:-}"
bundle="${PRODUCT_BUNDLE_IDENTIFIER:-com.checkkaka.HealthWorkoutExport}"
src="${SRCROOT:-${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}}"

if [[ -z "$team" && -n "$src" && -f "$src/Signing.local.xcconfig" ]]; then
  team=$(sed -n 's/^LOCAL_DEVELOPMENT_TEAM *= *//p' "$src/Signing.local.xcconfig" | tr -d '[:space:]')
fi

if [[ -z "$team" ]]; then
  echo "note: skip profile refresh (no DEVELOPMENT_TEAM)"
  exit 0
fi

appid="${team}.${bundle}"
deleted=0
shopt -s nullglob
for dir in \
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
  "$HOME/Library/MobileDevice/Provisioning Profiles"
do
  [[ -d "$dir" ]] || continue
  for f in "$dir"/*.mobileprovision "$dir"/*.provisionprofile; do
    [[ -f "$f" ]] || continue
    plist=$(mktemp)
    if ! security cms -D -i "$f" >"$plist" 2>/dev/null; then
      rm -f "$plist"
      continue
    fi
    app=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$plist" 2>/dev/null || true)
    ttl=$(/usr/libexec/PlistBuddy -c 'Print TimeToLive' "$plist" 2>/dev/null || echo 999)
    rm -f "$plist"
    [[ "$app" == "$appid" ]] || continue
    if [[ "$ttl" =~ ^[0-9]+$ ]] && (( ttl > 7 )); then
      continue
    fi
    rm -f "$f"
    deleted=$((deleted + 1))
  done
done

# XCBuild caches the old .mobileprovision path as a build input. Drop that
# graph so this Run can mint a replacement instead of failing on a missing file.
if (( deleted > 0 )); then
  if [[ -n "${OBJROOT:-}" ]]; then
    rm -rf "${OBJROOT}/XCBuildData"
  fi
  shopt -s nullglob
  for xc in "${HOME}/Library/Developer/Xcode/DerivedData"/HealthWorkoutExport-*/Build/Intermediates.noindex/XCBuildData; do
    rm -rf "$xc"
  done
fi

echo "note: dropped ${deleted} 7-day profile(s) for ${appid}; Xcode will mint a new one"
