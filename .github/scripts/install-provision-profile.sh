#!/usr/bin/env bash
# 安装 .mobileprovision / .provisionprofile，并把 Name/UUID/Team 写到 GITHUB_OUTPUT。
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <provision-profile>" >&2
  exit 1
fi

profile=$1
if [[ ! -f "$profile" ]]; then
  echo "provision profile not found: $profile" >&2
  exit 1
fi

plist=$(mktemp)
trap 'rm -f "$plist"' EXIT
security cms -D -i "$profile" >"$plist"

uuid=$(/usr/libexec/PlistBuddy -c 'Print UUID' "$plist")
name=$(/usr/libexec/PlistBuddy -c 'Print Name' "$plist")
team=$(/usr/libexec/PlistBuddy -c 'Print TeamIdentifier:0' "$plist")

legacy="$HOME/Library/MobileDevice/Provisioning Profiles"
modern="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$legacy" "$modern"
cp "$profile" "$legacy/$uuid.mobileprovision"
cp "$profile" "$modern/$uuid.mobileprovision"

{
  echo "uuid=$uuid"
  echo "name=$name"
  echo "team=$team"
} >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
