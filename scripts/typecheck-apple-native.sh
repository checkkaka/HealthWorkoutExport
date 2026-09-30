#!/usr/bin/env bash
# Typecheck real Apple adapters and XCTest sources, without any Flutter/Dart/FRB build phase.
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Apple native typechecking requires macOS with Xcode" >&2
  exit 2
fi
: "${FLUTTER_ROOT:?Set FLUTTER_ROOT to the pinned Flutter SDK checkout}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$(tr -d '\r\n' < "$FLUTTER_ROOT/bin/internal/engine.version")"
if [[ ! "$engine" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Invalid pinned Flutter engine revision" >&2
  exit 2
fi
if [[ -s "$FLUTTER_ROOT/bin/internal/engine.realm" ]]; then
  echo "Only official stable-engine artifact paths are supported" >&2
  exit 2
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/health-native-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT
base="https://storage.googleapis.com/flutter_infra_release/flutter/$engine"
mkdir -p "$work/ios" "$work/macos" "$work/modules/ios" "$work/modules/macos" "$work/module-cache"
for platform in ios macos; do
  if [[ "$platform" == ios ]]; then artifact="ios/artifacts.zip"; else artifact="darwin-x64/framework.zip"; fi
  echo "Downloading official $platform framework for engine $engine"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --max-time 600 \
    "$base/$artifact" -o "$work/$platform.zip"
  shasum -a 256 "$work/$platform.zip"
  ditto -xk "$work/$platform.zip" "$work/$platform"
done

# Select the real framework slice through XCFramework metadata rather than assuming archive layout.
select_framework() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import pathlib, plistlib, sys
root, platform, variant, architecture = pathlib.Path(sys.argv[1]), *sys.argv[2:]
name = "Flutter" if platform == "ios" else "FlutterMacOS"
for bundle in root.rglob(name + ".xcframework"):
    with (bundle / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    for item in info.get("AvailableLibraries", []):
        if (item.get("SupportedPlatform") == platform
                and item.get("SupportedPlatformVariant", "") == variant
                and architecture in item.get("SupportedArchitectures", [])):
            framework = bundle / item["LibraryIdentifier"] / item["LibraryPath"]
            if framework.is_dir():
                print(framework.parent)
                sys.exit(0)
if platform == "macos":
    for framework in root.rglob("FlutterMacOS.framework"):
        if ".xcframework" not in str(framework):
            print(framework.parent)
            sys.exit(0)
sys.exit("No matching official Flutter framework slice")
PY
}

arch="$(uname -m)"
[[ "$arch" == arm64 || "$arch" == x86_64 ]] || { echo "Unsupported Mac architecture: $arch" >&2; exit 2; }
ios_framework="$(select_framework "$work/ios" ios simulator "$arch")"
mac_framework="$(select_framework "$work/macos" macos '' "$arch")"

check_platform() {
  local platform="$1" sdk="$2" target="$3" framework="$4" module="$5"
  local sdk_path platform_path
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  platform_path="$(xcrun --sdk "$sdk" --show-sdk-platform-path)"
  local sources=("$repo_root/flutter_app/$platform/Runner/"*Plugin.swift)
  local common=(-swift-version 5 -parse-as-library -sdk "$sdk_path" -target "$target"
    -F "$framework" -module-cache-path "$work/module-cache/$platform")
  echo "Typechecking $platform production plugins against $sdk"
  xcrun --sdk "$sdk" swiftc "${common[@]}" -emit-module -enable-testing \
    -module-name "$module" -emit-module-path "$work/modules/$platform/$module.swiftmodule" \
    "${sources[@]}"
  echo "Typechecking $platform XCTest sources (not executing device tests)"
  xcrun --sdk "$sdk" swiftc "${common[@]}" -typecheck \
    -I "$work/modules/$platform" \
    -F "$platform_path/Developer/Library/Frameworks" \
    -I "$platform_path/Developer/usr/lib" \
    "$repo_root/flutter_app/$platform/RunnerTests/RunnerTests.swift"
}
check_platform ios iphonesimulator "$arch-apple-ios17.0-simulator" "$ios_framework" Runner
check_platform macos macosx "$arch-apple-macos14.0" "$mac_framework" health_workout_export
echo "Apple production plugin and XCTest source typechecking passed; no app/device tests were run"
