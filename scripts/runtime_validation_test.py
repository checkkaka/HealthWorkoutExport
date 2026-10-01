"""Runtime CI guardrails and deterministic orchestration tests (no emulator needed)."""
from pathlib import Path
import importlib.util
import json
import os
import plistlib
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
    def test_android_builds_every_phase_before_starting_software_guest(self):
        runtime = module()
        with tempfile.TemporaryDirectory() as temporary:
            runtime.APP = Path(temporary) / "app"
            runner = runtime.Runner("android", Path(temporary) / "evidence")
            phases = []
            def command(args, log, **kwargs):
                self.assertEqual(args[:4], ["flutter", "--suppress-analytics", "build", "apk"])
                for flag in ("--debug", "--no-pub", "--target-platform=android-x64"):
                    self.assertIn(flag, args)
                phase = next(a.split("=", 2)[2] for a in args if a.startswith("--dart-define=HWE_RUNTIME_PHASE="))
                phases.append(phase)
                apk = runtime.APP / "build/app/outputs/flutter-apk/app-debug.apk"
                apk.parent.mkdir(parents=True, exist_ok=True)
                apk.write_bytes(b"synthetic-apk-" + phase.encode())
                return ""
            runner.command = command
            runner.build_android_phases()
            self.assertEqual(phases, list(runtime.PHASES))
            for phase in runtime.PHASES:
                self.assertEqual(Path(runner.android_binaries[phase]).read_bytes(), b"synthetic-apk-" + phase.encode())
            source = SCRIPT.read_text()
            self.assertLess(source.index("self.build_android_phases()"), source.index("self.emulator = subprocess.Popen"))
            self.assertNotIn(str(runner.output), runner.android_binaries["seed"])

    def test_android_boot_requires_package_service_not_only_stale_property(self):
        runtime = module()
        self.assertFalse(runtime.android_ready("1", "Can't find service: package"))
        self.assertFalse(runtime.android_ready("0", "package:/system/framework/framework-res.apk"))
        self.assertTrue(runtime.android_ready("1", "package:/system/framework/framework-res.apk"))

    def test_android_timeout_is_bounded_and_reported(self):
        entry = (ROOT / "flutter_app/integration_test/runtime_test.dart").read_text(encoding="utf-8")
        self.assertIn("final phaseBudget = Duration(minutes: Platform.isAndroid ? 12 : 4);", entry)
        self.assertIn("'phaseBudgetSeconds': phaseBudget.inSeconds", entry)
        self.assertIn("timeout: Timeout(phaseBudget)", entry)
        driver = (ROOT / "flutter_app/test_driver/runtime_driver.dart").read_text(encoding="utf-8")
        self.assertIn("timeout: const Duration(minutes: 15)", driver)

    def test_driver_enforces_process_deadline_not_only_sdk_warning(self):
        driver = (ROOT / "flutter_app/test_driver/runtime_driver.dart").read_text(encoding="utf-8")
        self.assertIn("startRuntimeWatchdog()", driver)
        watchdog = ROOT / "flutter_app/test_driver/runtime_watchdog.dart"
        self.assertTrue(watchdog.is_file(), "The deadline must terminate a stalled driver")
        source = watchdog.read_text(encoding="utf-8")
        self.assertIn("exit(1)", source)
        self.assertIn("Duration(minutes: 15)", source)

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
            payload = {"phase": "seed", "phaseCompleted": True, "pid": 123, "checks": ["bundled-rust-ffi-encode-and-preview", "native-health-capability-probe-no-authorization", "production-root-tabs-navigation-and-back", "native-preferences-roundtrip", "automatic-alignment-rejects-underconstrained-fixture", "synthetic-file-selection-cancel-real-fit-import-rust-merge-export", "real-detail-preview-export-cancel-and-return", "durable-recovery-seed-before-host-process-termination"], "screenshots": ["durable-seed.png"]}
            (folder / "results.json").write_text(json.dumps(payload))
            with self.assertRaisesRegex(RuntimeError, "screenshot"):
                runtime.validate_report(folder, "seed")
            (folder / "durable-seed.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"evidence")
            self.assertEqual(runtime.validate_report(folder, "seed")["pid"], 123)
            with self.assertRaisesRegex(RuntimeError, "phase"):
                runtime.validate_report(folder, "verify")
            payload["checks"] = ["unrelated-check"]
            (folder / "results.json").write_text(json.dumps(payload))
            with self.assertRaisesRegex(RuntimeError, "checks"):
                runtime.validate_report(folder, "seed")

    def test_driver_success_text_cannot_mask_framework_failure(self):
        runtime = module()
        for log in ("I/flutter (3520): runtime startup [E]\nAll tests passed.",
                    "I/flutter (3520): TimeoutException: Test timed out after 4 minutes.\nAll tests passed.",
                    "I/flutter (3520): 04:11 +0 -1: (tearDownAll)\nAll tests passed."):
            with self.assertRaisesRegex(RuntimeError, "framework failure"):
                runtime.validate_test_log(log)
        runtime.validate_test_log("00:01 +1: test passed\nAll tests passed.")

    def test_complete_checklist_cannot_mask_late_timeout(self):
        runtime = module()
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            payload = {"phase": "startup", "pid": 123,
                "checks": ["bundled-rust-ffi-encode-and-preview", "native-health-capability-probe-no-authorization", "production-root-tabs-navigation-and-back", "native-preferences-roundtrip"],
                "screenshots": ["root-startup.png"]}
            (folder / "root-startup.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"evidence")
            for completed in (None, False, "true"):
                payload["phaseCompleted"] = completed
                (folder / "results.json").write_text(json.dumps(payload))
                with self.assertRaisesRegex(RuntimeError, "completion"):
                    runtime.validate_report(folder, "startup")
            payload["phaseCompleted"] = True
            (folder / "results.json").write_text(json.dumps(payload))
            self.assertTrue(runtime.validate_report(folder, "startup")["phaseCompleted"])

    def test_report_rejects_paths_outside_phase_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder / "results.json").write_text(json.dumps({"phase": "seed", "phaseCompleted": True, "pid": 123, "checks": ["bundled-rust-ffi-encode-and-preview", "native-health-capability-probe-no-authorization", "production-root-tabs-navigation-and-back", "native-preferences-roundtrip", "automatic-alignment-rejects-underconstrained-fixture", "synthetic-file-selection-cancel-real-fit-import-rust-merge-export", "real-detail-preview-export-cancel-and-return", "durable-recovery-seed-before-host-process-termination"], "screenshots": ["../secret.png"]}))
            with self.assertRaisesRegex(RuntimeError, "screenshot"):
                module().validate_report(folder, "seed")

    def test_synthetic_health_config_only_reduces_debug_test_entitlement(self):
        original = {"com.apple.developer.healthkit": True, "com.apple.security.app-sandbox": True,
                    "com.apple.security.cs.allow-jit": True, "com.apple.security.network.server": True}
        reduced = module().synthetic_health_entitlements(original, "Debug")
        self.assertEqual(reduced, {k: v for k, v in original.items() if k != "com.apple.developer.healthkit"})
        self.assertTrue(original["com.apple.developer.healthkit"])
        for mode in ("Release", "Profile", "debug", ""):
            with self.assertRaisesRegex(ValueError, "Debug"):
                module().synthetic_health_entitlements(original, mode)
        with self.assertRaisesRegex(ValueError, "sandbox"):
            module().synthetic_health_entitlements({"com.apple.developer.healthkit": True}, "Debug")

    def test_macos_test_build_keeps_production_sources_and_rejects_release(self):
        runtime = module()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            runtime.APP = base / "app"
            source = runtime.APP / "macos/Runner"
            source.mkdir(parents=True)
            original = {"com.apple.developer.healthkit": True, "com.apple.security.app-sandbox": True,
                        "com.apple.security.cs.allow-jit": True, "com.apple.security.network.server": True}
            original_bytes = plistlib.dumps(original)
            for name in ("DebugProfile.entitlements", "Release.entitlements"):
                (source / name).write_bytes(original_bytes)
            runner = runtime.Runner("macos", base / "evidence")
            calls = []
            def command(args, log, **kwargs):
                calls.append(args)
                if args[0] == "xcodebuild":
                    self.assertEqual(args[args.index("-configuration") + 1], "Debug")
                    config = Path(args[args.index("-xcconfig") + 1]).read_text()
                    self.assertTrue(all("[config=Debug]" in line for line in config.splitlines()))
                    entitlement_setting = config.splitlines()[0].split(" = ", 1)[1]
                    self.assertTrue(Path(entitlement_setting).is_file(), "xcconfig paths must not contain literal quotes")
                    bundle = runtime.APP / "build/macos/Build/Products/Debug/health_workout_export.app/Contents"
                    bundle.mkdir(parents=True)
                    (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.checkkaka.HealthWorkoutExport.SyntheticHealthRuntime"}))
                if args[:2] == ["codesign", "--display"]:
                    return plistlib.dumps(runtime.synthetic_health_entitlements(original, "Debug")).decode()
                return ""
            runner.command = command
            binary = runner.build_macos_synthetic("seed")
            self.assertEqual(Path(binary).parts[-2:], ("Debug", "health_workout_export.app"))
            self.assertTrue(any("--config-only" in args and "--debug" in args for args in calls))
            self.assertTrue(any(args[:2] == ["codesign", "--verify"] for args in calls))
            for name in ("DebugProfile.entitlements", "Release.entitlements"):
                self.assertEqual((source / name).read_bytes(), original_bytes)

    def test_macos_failure_diagnostics_are_read_only_and_app_scoped(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner = module().Runner("macos", Path(temporary))
            commands = []
            runner.command = lambda args, log, **kwargs: commands.append((args, log)) or ""
            runner.collect_apple_diagnostics()
            self.assertTrue(any(args[:2] == ["codesign", "--display"] for args, _ in commands))
            self.assertTrue(any(args[:2] == ["otool", "-L"] for args, _ in commands))
            self.assertTrue(any(args[:2] == ["codesign", "--verify"] for args, _ in commands))
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
