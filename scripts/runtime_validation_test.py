"""Runtime CI guardrails and deterministic orchestration tests (no emulator needed)."""
from pathlib import Path
import importlib.util
import json
import os
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/runtime_validation.py"
WORKFLOW = ROOT / ".github/workflows/runtime-validation.yml"


def module():
    if not SCRIPT.is_file():
        raise AssertionError("Runtime orchestrator is missing")
    spec = importlib.util.spec_from_file_location("runtime_validation", SCRIPT)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class RuntimeValidationTests(unittest.TestCase):
    def test_software_emulation_never_requires_kvm_permissions(self):
        self.assertEqual(module().android_acceleration(True), ("on", 300))
        self.assertEqual(module().android_acceleration(False), ("off", 1200))

    def test_safe_environment_overrides_opt_in_for_every_subprocess(self):
        env = module().safe_environment({"CI": "false", "BOT": "false", "KEEP": "yes"})
        for key in ("CI", "BOT", "DASH__SUPPRESS_ANALYTICS", "FLUTTER_SUPPRESS_ANALYTICS", "COCOAPODS_DISABLE_STATS"):
            self.assertEqual(env[key], "true")
        self.assertEqual(env["CARGOKIT_RUST_TOOLCHAIN"], "1.98.1")
        self.assertEqual(env["KEEP"], "yes")

    def test_ios_selection_uses_only_installed_available_iphone(self):
        inventory = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
                {"name": "iPhone 16", "udid": "old", "isAvailable": True},
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-19-0": [
                {"name": "iPhone 17", "udid": "missing", "isAvailable": False},
                {"name": "iPad", "udid": "tablet", "isAvailable": True},
                {"name": "iPhone 17", "udid": "ready", "isAvailable": True},
            ],
            "com.apple.CoreSimulator.SimRuntime.tvOS-19-0": [
                {"name": "iPhone bogus", "udid": "wrong-os", "isAvailable": True},
            ],
        }}
        self.assertEqual(module().select_ios_device(inventory)["udid"], "ready")
        with self.assertRaisesRegex(RuntimeError, "installed.*iPhone"):
            module().select_ios_device({"devices": {}})

    def test_drive_command_launches_real_device_no_pub_and_one_phase(self):
        for platform, device in (("android", "emulator-5554"), ("ios", "sim-uuid"), ("macos", "macos"), ("windows", "windows")):
            for phase in ("startup", "seed", "verify"):
                args = module().drive_command(device, phase)
                self.assertEqual(args[:3], ["flutter", "--suppress-analytics", "drive"])
                for required in ("--no-pub", "--debug", "--keep-app-running", "--target=integration_test/runtime_test.dart", "--driver=test_driver/runtime_driver.dart", f"--dart-define=HWE_RUNTIME_PHASE={phase}"):
                    self.assertIn(required, args)
                self.assertIn(device, args)
                self.assertNotIn("test", args)
        with self.assertRaises(ValueError):
            module().drive_command("macos", "typo")

    def test_validate_report_requires_checks_phase_pid_and_real_png(self):
        runtime = module()
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            payload = {"phase": "seed", "pid": 123, "checks": ["bundled-rust-ffi-encode-and-preview", "native-health-capability-probe-no-authorization", "production-root-tabs-navigation-and-back", "native-preferences-roundtrip", "synthetic-file-selection-cancel-real-fit-import-rust-merge-export", "real-detail-preview-export-cancel-and-return", "durable-recovery-seed-before-host-process-termination"], "screenshots": ["screen.png"]}
            (folder / "results.json").write_text(json.dumps(payload))
            with self.assertRaisesRegex(RuntimeError, "screenshot"):
                runtime.validate_report(folder, "seed")
            (folder / "screen.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"evidence")
            self.assertEqual(runtime.validate_report(folder, "seed")["pid"], 123)
            with self.assertRaisesRegex(RuntimeError, "phase"):
                runtime.validate_report(folder, "verify")
            payload["checks"] = ["unrelated-check"]
            (folder / "results.json").write_text(json.dumps(payload))
            with self.assertRaisesRegex(RuntimeError, "checks"):
                runtime.validate_report(folder, "seed")

    def test_report_rejects_paths_outside_phase_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder / "results.json").write_text(json.dumps({"phase": "seed", "pid": 123, "checks": ["bundled-rust-ffi-encode-and-preview", "native-health-capability-probe-no-authorization", "production-root-tabs-navigation-and-back", "native-preferences-roundtrip", "synthetic-file-selection-cancel-real-fit-import-rust-merge-export", "real-detail-preview-export-cancel-and-return", "durable-recovery-seed-before-host-process-termination"], "screenshots": ["../secret.png"]}))
            with self.assertRaisesRegex(RuntimeError, "screenshot"):
                module().validate_report(folder, "seed")

    def test_macos_failure_diagnostics_are_read_only_and_app_scoped(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner = module().Runner("macos", Path(temporary))
            commands = []
            runner.command = lambda args, log, **kwargs: commands.append((args, log)) or ""
            runner.collect_apple_diagnostics()
            self.assertTrue(any(args[:2] == ["codesign", "--display"] for args, _ in commands))
            self.assertTrue(any(args[:2] == ["otool", "-L"] for args, _ in commands))
            self.assertFalse(any("--sign" in args or "--force" in args for args, _ in commands))
            logs = [args for args, _ in commands if args[:2] == ["log", "show"]]
            self.assertEqual(len(logs), 1)
            self.assertIn("com.checkkaka.HealthWorkoutExport", logs[0][-1])

    def test_child_process_environment_exit_and_closed_input_are_real(self):
        with tempfile.TemporaryDirectory() as temporary:
            runtime = module()
            folder = Path(temporary)
            runner = runtime.Runner("macos", folder)
            output = runner.command([sys.executable, "-c", "import os,sys; print(os.environ['FLUTTER_SUPPRESS_ANALYTICS']); print(repr(sys.stdin.read()))"], "env.log")
            self.assertIn("true\n''", output)
            with self.assertRaisesRegex(RuntimeError, "exit 7"):
                runner.command([sys.executable, "-c", "raise SystemExit(7)"], "failure.log")
            self.assertTrue((folder / "failure.log").is_file())


class RuntimeWorkflowGuards(unittest.TestCase):
    def sources(self):
        self.assertTrue(WORKFLOW.is_file(), "Runtime workflow is missing")
        self.assertTrue(SCRIPT.is_file(), "Runtime orchestrator is missing")
        return WORKFLOW.read_text(), SCRIPT.read_text()

    def test_standard_four_platform_matrix_and_short_retention(self):
        workflow, _ = self.sources()
        for platform in ("android", "ios", "macos", "windows"):
            self.assertIn(f"platform: {platform}", workflow)
        for runner in ("ubuntu-24.04", "macos-latest", "windows-latest"):
            self.assertIn(runner, workflow)
        for required in ("fail-fast: false", "contents: read", "persist-credentials: false", "./.github/actions/setup-flutter-rust", "retention-days: 7", "if: always()", "runtime_validation_test.py", "pub get --enforce-lockfile"):
            self.assertIn(required, workflow)
        self.assertNotIn("continue-on-error", workflow)

    def test_no_credentials_generators_security_changes_or_terms_acceptance(self):
        workflow, script = self.sources()
        text = workflow + script
        for forbidden in ("secrets.", "contents: write", "id-token: write", "pull_request_target:", "flutter_rust_bridge_codegen", "frb_codegen", "cargo expand", "--licenses", "yes |", "setup-android@", "chmod", "-downloadPlatform", "-allowProvisioningUpdates", "security import", "signtool", "build ipa", "fastlane", "adb root", "pm clear", "uninstall", "--no-keep-app-running"):
            self.assertNotIn(forbidden, text)
        for key in ("CI", "BOT", "DASH__SUPPRESS_ANALYTICS", "FLUTTER_SUPPRESS_ANALYTICS", "COCOAPODS_DISABLE_STATS"):
            self.assertIn(f'{key}: "true"', workflow)
        self.assertIn("stdin=subprocess.DEVNULL", script)

    def test_real_emulator_and_restart_evidence_no_fallback(self):
        workflow, script = self.sources()
        for required in ("system-images;android-35;default;x86_64", "platforms;android-36", "build-tools;36.0.0", "ndk;28.2.13676358", "-no-metrics", "/dev/kvm", "simctl", "bootstatus", "force-stop", "Get-Process", "stop_application", "startup", "seed", "verify", "process-restart.json"):
            self.assertIn(required, script)
        self.assertIn("android.googlesource.com", script)
        self.assertIn("flutter --suppress-analytics pub get --enforce-lockfile", workflow)
        self.assertIn("git diff --exit-code", workflow)

    def test_only_official_emulator_runtime_dependency_install_is_elevated(self):
        workflow, script = self.sources()
        commands = [line.strip() for line in workflow.splitlines() if line.strip().startswith("sudo ")]
        self.assertEqual(commands, ["sudo apt-get update", "sudo apt-get install --yes --no-install-recommends libpulse0"])
        self.assertNotIn("sudo ", script)

    def test_host_driver_retains_partial_failure_evidence(self):
        driver = ROOT / "flutter_app/test_driver/runtime_driver.dart"
        self.assertTrue(driver.is_file(), "Runtime host driver is missing")
        text = driver.read_text()
        for expected in ("integrationDriver", "writeResponseOnFailure: true", "pngBase64", "HWE_RUNTIME_OUTPUT", "results.json", "base64Decode"):
            self.assertIn(expected, text)


if __name__ == "__main__":
    unittest.main()
