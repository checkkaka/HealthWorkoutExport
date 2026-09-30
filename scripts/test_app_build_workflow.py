"""Static guardrails for unsigned app CI; does not build or generate bindings."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/app-builds.yml"


class AppBuildWorkflowTests(unittest.TestCase):
    def workflow(self):
        self.assertTrue(WORKFLOW.is_file(), "Unsigned app workflow is missing")
        return WORKFLOW.read_text()

    def job(self, name):
        text = self.workflow()
        match = re.search(rf"(?ms)^  {name}:\n(.*?)(?=^  [a-z][a-z-]*:|\Z)", text)
        self.assertIsNotNone(match, f"Missing {name} build job")
        return match.group(1)

    def test_all_four_real_app_jobs_use_pinned_shared_setup(self):
        for name in ("android-app", "ios-app", "macos-app", "windows-app"):
            with self.subTest(job=name):
                job = self.job(name)
                self.assertIn("uses: ./.github/actions/setup-flutter-rust", job)
                self.assertIn("persist-credentials: false", job)
                self.assertIn("pub get --enforce-lockfile", job)
                self.assertRegex(job, r"timeout-minutes: [1-9][0-9]?")
        setup = (ROOT / ".github/actions/setup-flutter-rust/action.yml").read_text()
        self.assertIn("toolchain: 1.98.1", setup)
        self.assertIn("flutter-version: '3.47.5'", setup)
        # A version-file input makes flutter-action install yq on Windows.
        self.assertNotIn("flutter-version-file:", setup)

    def test_safe_triggers_permissions_and_analytics(self):
        text = self.workflow()
        self.assertIn("contents: read", text)
        self.assertNotIn("pull_request_target:", text)
        self.assertNotIn("push:", text)
        for variable in ("BOT", "CI", "DASH__SUPPRESS_ANALYTICS", "FLUTTER_SUPPRESS_ANALYTICS", "COCOAPODS_DISABLE_STATS"):
            self.assertRegex(text, rf'(?m)^  {variable}: "true"$')
        # Includes all direct Flutter calls; nested tools inherit root flags.
        for line in text.splitlines():
            if re.search(r"(?:^\s+|run: )flutter ", line):
                self.assertIn("flutter --suppress-analytics ", line)

    def test_no_generation_credentials_release_or_license_acceptance(self):
        text = self.workflow()
        for forbidden in (
            "secrets.", "write-all", "contents: write", "id-token: write",
            "flutter_rust_bridge_codegen", "frb_codegen", "cargo expand",
            "--licenses", "yes |", "setup-android@", "accept-android-sdk-licenses",
            "import-codesign-certs", "install-provision-profile", "-allowProvisioningUpdates",
            "security import", "signtool", "build ipa", "gh release", "fastlane",
        ):
            self.assertNotIn(forbidden, text)
        self.assertNotRegex(text, r"(?m)^\s*(?:env|printenv|set)\s*$")

    def test_android_is_explicitly_unsigned_and_sdk_is_bounded(self):
        job = self.job("android-app")
        for value in ("java-version: '17'", "overwrite-settings: false", "'platforms;android-36'", "'build-tools;36.0.0'", "'ndk;28.2.13676358'", "</dev/null", 'HWE_UNSIGNED_BUILD: "true"', "build apk --release --no-pub", "apksigner", "librust_lib_health_workout_export.so"):
            self.assertIn(value, job)
        gradle = (ROOT / "flutter_app/android/app/build.gradle.kts").read_text()
        self.assertIn('System.getenv("HWE_UNSIGNED_BUILD") == "true"', gradle)
        self.assertRegex(gradle, r'if \(unsignedBuild\) \{\s+null\s+\} else if \(!uploadKeystorePath.isNullOrBlank\(\)\)')
        self.assertIn('signingConfigs.getByName("release")', gradle)
        self.assertIn('signingConfigs.getByName("debug")', gradle)

    def test_apple_builds_disable_signing_without_provisioning_changes(self):
        self.assertIn("build ios --release --no-pub --no-codesign", self.job("ios-app"))
        macos = self.job("macos-app")
        for value in ("build macos --release --no-pub --config-only", "xcodebuild", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", 'CODE_SIGN_IDENTITY=""', "-hideShellScriptEnvironment"):
            self.assertIn(value, macos)
        self.assertNotIn("CODE_SIGN_ENTITLEMENTS=", macos)
        self.assertNotIn("DEVELOPMENT_TEAM=", macos)

    def test_cargokit_uses_pinned_toolchain_in_actual_builds(self):
        self.assertRegex(self.workflow(), r'(?m)^  CARGOKIT_RUST_TOOLCHAIN: "1.98.1"$')
        source = ROOT / "flutter_app/rust_builder/cargokit/build_tool/lib/src"
        builder = (source / "builder.dart").read_text()
        self.assertIn("String get _toolchain => selectRustToolchain(", builder)
        self.assertIn("Platform.environment", builder)
        self.assertIn(".where(isStandardRustToolchain)", (source / "rustup.dart").read_text())
        self.assertIn("toolchain_selection_test.dart", self.job("android-app"))

    def test_windows_build_checks_rust_bundle_without_extra_installer(self):
        job = self.job("windows-app")
        self.assertIn("build windows --release --no-pub", job)
        self.assertIn("rust_lib_health_workout_export.dll", job)
        self.assertNotRegex(job, r"(?i)choco|winget|Invoke-WebRequest|Start-Process")


if __name__ == "__main__":
    unittest.main()
