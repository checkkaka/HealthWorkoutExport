"""Launch real Flutter applications on disposable standard hosted CI runners.

No device mocks, permission changes, license prompts, or release signing.
Screenshots are Flutter rendered surfaces, not native permission dialogs.
"""
from pathlib import Path
import argparse
import json
import os
import platform as host_platform
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "flutter_app"
BUNDLE = "com.checkkaka.HealthWorkoutExport"
ANDROID_PACKAGE = "com.checkkaka.health_workout_export"
PHASES = ("startup", "seed", "verify")
ANDROID_IMAGE = "system-images;android-35;default;x86_64"
SAFE_ENV = {
    "CI": "true", "BOT": "true", "DASH__SUPPRESS_ANALYTICS": "true",
    "FLUTTER_SUPPRESS_ANALYTICS": "true", "COCOAPODS_DISABLE_STATS": "true",
    "CARGOKIT_RUST_TOOLCHAIN": "1.98.1",
}
# Official emulator source verified 2026-09-30: no_metrics selects no writer;
# MetricsReporter.cpp then resets the reporter so no metrics are collected.
# https://android.googlesource.com/platform/external/qemu/+/refs/heads/emu-36-1-release/android/emu/cmdline/include/android/cmdline-options.h
# https://android.googlesource.com/platform/external/qemu/+/refs/heads/emu-36-1-release/android/emu/metrics/src/android/metrics/MetricsReporter.cpp


def safe_environment(base=None):
    return {**(os.environ if base is None else base), **SAFE_ENV}


def select_ios_device(inventory):
    candidates = []
    for runtime, devices in inventory.get("devices", {}).items():
        if ".iOS-" not in runtime:
            continue
        version = tuple(int(part) for part in runtime.split(".iOS-")[1].split("-"))
        for device in devices:
            if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
                candidates.append((version, device["name"], device))
    if not candidates:
        raise RuntimeError("No installed available iPhone simulator; no runtime will be downloaded")
    return sorted(candidates, key=lambda item: item[:2], reverse=True)[0][2]


def drive_command(device, phase):
    if phase not in PHASES:
        raise ValueError(f"Unknown runtime phase: {phase}")
    # Flutter 3.47.5 default drive cleanup removes the mobile app and its data.
    # Keep it installed; stop_application supplies the verified process boundary.
    return [
        "flutter", "--suppress-analytics", "drive", "--no-pub", "--debug",
        "--keep-app-running", "-d", device,
        "--target=integration_test/runtime_test.dart",
        "--driver=test_driver/runtime_driver.dart",
        f"--dart-define=HWE_RUNTIME_PHASE={phase}",
    ]


def validate_report(folder, phase):
    file = folder / "results.json"
    if not file.is_file():
        raise RuntimeError(f"Missing {phase} results; app launch/test did not complete")
    report = json.loads(file.read_text(encoding="utf-8"))
    if report.get("phase") != phase:
        raise RuntimeError(f"Unexpected report phase: {report.get('phase')}")
    if not isinstance(report.get("pid"), int) or report["pid"] <= 0:
        raise RuntimeError("Missing target app process identity")
    expected_checks = {
        "bundled-rust-ffi-encode-and-preview",
        "native-health-capability-probe-no-authorization",
        "production-root-tabs-navigation-and-back",
    }
    if phase in ("startup", "seed"):
        expected_checks.add("native-preferences-roundtrip")
    if phase == "seed":
        expected_checks.update({
            "synthetic-file-selection-cancel-real-fit-import-rust-merge-export",
            "real-detail-preview-export-cancel-and-return",
            "durable-recovery-seed-before-host-process-termination",
        })
    if phase == "verify":
        expected_checks.add("new-process-native-files-preferences-and-production-session-restoration")
    checks = report.get("checks")
    if not isinstance(checks, list) or not all(isinstance(item, str) for item in checks):
        raise RuntimeError("Invalid runtime checks report")
    missing = expected_checks - set(checks)
    if missing:
        raise RuntimeError("Missing runtime checks: " + ", ".join(sorted(missing)))
    screenshots = report.get("screenshots", [])
    if not screenshots:
        raise RuntimeError("No rendered-surface screenshot was captured")
    for name in screenshots:
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_-]+\.png", name):
            raise RuntimeError("Invalid screenshot filename")
        image = folder / name
        if not image.is_file() or not image.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
            raise RuntimeError(f"Missing or invalid screenshot: {name}")
    return report


class Runner:
    def __init__(self, platform, output):
        self.platform = platform
        self.output = output
        self.output.mkdir(parents=True, exist_ok=True)
        self.env = safe_environment()
        self.device = platform
        self.emulator = None
        self.emulator_log = None
        self.adb = None
        self.simulator_booted = False
        self.summary = {"platform": platform, "status": "running", "phases": []}

    def command(self, args, log, *, timeout=300, check=True, cwd=ROOT):
        print("+ " + " ".join(str(arg) for arg in args), flush=True)
        args = [str(arg) for arg in args]
        executable = shutil.which(args[0], path=self.env.get("PATH"))
        if executable:
            args[0] = executable
        if os.name == "nt" and Path(args[0]).suffix.lower() in (".bat", ".cmd"):
            args = [self.env.get("COMSPEC", "cmd.exe"), "/d", "/s", "/c", subprocess.list2cmdline(args)]
        destination = self.output / log
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("wb") as stream:
            try:
                result = subprocess.run(
                    args, cwd=cwd, env=self.env, stdin=subprocess.DEVNULL,
                    stdout=stream, stderr=subprocess.STDOUT, timeout=timeout,
                )
            except subprocess.TimeoutExpired as error:
                raise RuntimeError(f"Timed out after {timeout}s: {log}; runtime status is unverified") from error
        text = destination.read_text(encoding="utf-8", errors="replace")
        if check and result.returncode != 0:
            print(text[-12000:], flush=True)
            raise RuntimeError(f"Command exit {result.returncode}; see {log}")
        return text

    def write_summary(self):
        (self.output / "summary.json").write_text(json.dumps(self.summary, indent=2) + "\n", encoding="utf-8")

    def prepare(self):
        expected = {"android": "Linux", "ios": "Darwin", "macos": "Darwin", "windows": "Windows"}
        if host_platform.system() != expected[self.platform]:
            raise RuntimeError(f"{self.platform} needs a {expected[self.platform]} host; no mock fallback")
        machine = host_platform.machine().lower()
        target = {
            "android": "x86_64-linux-android",
            "ios": "aarch64-apple-ios-sim" if machine in ("arm64", "aarch64") else "x86_64-apple-ios",
            "macos": "aarch64-apple-darwin" if machine in ("arm64", "aarch64") else "x86_64-apple-darwin",
            "windows": "x86_64-pc-windows-msvc",
        }[self.platform]
        if self.platform == "android":
            self.prepare_android()
        elif self.platform == "ios":
            self.prepare_ios()
        elif self.platform == "macos":
            self.command(["xcodebuild", "-version"], "xcode-version.log")
            # Read-only GUI-session preflight. No screen-capture or accessibility permission requests.
            session = self.command(["stat", "-f", "%Su", "/dev/console"], "desktop-session.log").strip()
            if not session or session in ("root", "loginwindow"):
                raise RuntimeError("No macOS GUI session on this hosted runner; cannot claim a desktop launch")
        else:
            desktop = self.command(["pwsh", "-NoProfile", "-Command", "[Environment]::UserInteractive; (Get-Process -Id $PID).SessionId"], "desktop-session.log")
            values = desktop.strip().splitlines()
            if len(values) < 2 or values[0].strip().lower() != "true" or int(values[1]) == 0:
                raise RuntimeError("No interactive Windows desktop session; refusing a headless/mock replacement")
        self.command(["rustup", "target", "add", "--toolchain", "1.98.1", target], "rust-target.log", timeout=600)
        self.command(["cargo", "fetch", "--manifest-path", "rust/workout_core/Cargo.toml", "--locked"], "cargo-fetch.log", timeout=600)
        self.command(["flutter", "--suppress-analytics", "devices", "--machine"], "flutter-devices.json")

    def prepare_android(self):
        kvm = Path("/dev/kvm")
        if not kvm.exists() or not os.access(kvm, os.R_OK | os.W_OK):
            raise RuntimeError("Hosted runner has no accessible /dev/kvm; security permissions were not changed")
        sdk_root = self.env.get("ANDROID_HOME") or self.env.get("ANDROID_SDK_ROOT")
        if not sdk_root:
            raise RuntimeError("Hosted Android SDK is missing")
        sdk = Path(sdk_root)
        sdkmanager = sdk / "cmdline-tools/latest/bin/sdkmanager"
        avdmanager = sdk / "cmdline-tools/latest/bin/avdmanager"
        emulator = sdk / "emulator/emulator"
        self.adb = str(sdk / "platform-tools/adb")
        self.command([sdkmanager, "platform-tools", "emulator", "platforms;android-36", "build-tools;36.0.0", "ndk;28.2.13676358", ANDROID_IMAGE], "android-sdk.log", timeout=900)
        required = ["platforms/android-36/android.jar", "build-tools/36.0.0/apksigner", "ndk/28.2.13676358/package.xml", "system-images/android-35/default/x86_64/system.img", "emulator/emulator", "platform-tools/adb"]
        for item in required:
            if not (sdk / item).is_file():
                raise RuntimeError(f"Required Android component unavailable: {item}; check android-sdk.log for license/install blocker")
        avd_home = Path(self.env.get("RUNNER_TEMP", str(self.output))) / "hwe-runtime-avd"
        avd_home.mkdir(parents=True, exist_ok=True)
        self.env["ANDROID_AVD_HOME"] = str(avd_home)
        # No prompt is answered: an unavailable/pre-unaccepted component fails.
        self.command([avdmanager, "create", "avd", "--name", "hwe-runtime", "--package", ANDROID_IMAGE, "--device", "pixel_6"], "android-avd.log")
        help_text = self.command([emulator, "-no-metrics", "-help-all"], "android-emulator-options.log")
        if "no-metrics" not in help_text:
            raise RuntimeError("Installed emulator does not advertise the required metrics-disable switch")
        self.command([emulator, "-no-metrics", "-version"], "android-emulator-version.log")
        self.emulator_log = (self.output / "android-emulator.log").open("wb")
        self.emulator = subprocess.Popen(
            [str(emulator), "-avd", "hwe-runtime", "-port", "5554", "-accel", "on",
             "-no-metrics", "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot",
             "-gpu", "swiftshader", "-camera-back", "none", "-camera-front", "none"],
            env=self.env, stdin=subprocess.DEVNULL, stdout=self.emulator_log,
            stderr=subprocess.STDOUT,
        )
        self.device = "emulator-5554"
        self.command([self.adb, "-s", self.device, "wait-for-device"], "android-wait.log", timeout=180)
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            if self.emulator.poll() is not None:
                raise RuntimeError("Android emulator exited before boot; see android-emulator.log")
            boot = self.command([self.adb, "-s", self.device, "shell", "getprop", "sys.boot_completed"], "android-boot.log", timeout=30)
            if boot.strip() == "1":
                return
            time.sleep(3)
        raise RuntimeError("Android boot did not finish; no runtime test was substituted")

    def prepare_ios(self):
        self.command(["xcodebuild", "-version"], "xcode-version.log")
        self.command(["xcrun", "simctl", "list", "runtimes", "--json"], "ios-runtimes.json")
        inventory = json.loads(self.command(["xcrun", "simctl", "list", "devices", "available", "--json"], "ios-devices.json"))
        chosen = select_ios_device(inventory)
        self.device = chosen["udid"]
        (self.output / "ios-selected-device.json").write_text(json.dumps(chosen, indent=2), encoding="utf-8")
        if chosen.get("state") != "Booted":
            self.command(["xcrun", "simctl", "boot", self.device], "ios-boot.log")
        self.simulator_booted = True
        self.command(["xcrun", "simctl", "bootstatus", self.device, "-b"], "ios-bootstatus.log", timeout=300)

    def stop_application(self, phase):
        """Prove a native process boundary without removing persistent app data."""
        if self.platform == "android":
            self.command([self.adb, "-s", self.device, "shell", "am", "force-stop", ANDROID_PACKAGE], f"{phase}/stop.log")
            active = self.command([self.adb, "-s", self.device, "shell", "pidof", ANDROID_PACKAGE], f"{phase}/processes-after-stop.log", check=False).strip()
            if active:
                raise RuntimeError("Android app process remains after stop")
        elif self.platform == "ios":
            self.command(["xcrun", "simctl", "terminate", self.device, BUNDLE], f"{phase}/stop.log", check=False)
            active = self.command(["xcrun", "simctl", "spawn", self.device, "launchctl", "list"], f"{phase}/processes-after-stop.log")
            if any(BUNDLE in line and line.split()[0].isdigit() for line in active.splitlines()):
                raise RuntimeError("iOS app process remains after stop")
        elif self.platform == "macos":
            processes = self.command(["ps", "-axo", "pid=,comm="], f"{phase}/processes-before-stop.log")
            suffix = "/health_workout_export.app/Contents/MacOS/health_workout_export"
            for line in processes.splitlines():
                if line.strip().endswith(suffix):
                    os.kill(int(line.split()[0]), signal.SIGTERM)
            time.sleep(1)
            after = self.command(["ps", "-axo", "pid=,comm="], f"{phase}/processes-after-stop.log")
            if any(line.strip().endswith(suffix) for line in after.splitlines()):
                raise RuntimeError("macOS app process remains after stop")
        else:
            self.command(["pwsh", "-NoProfile", "-Command", "$ErrorActionPreference='Stop'; Get-Process -Name health_workout_export -ErrorAction SilentlyContinue | Stop-Process; Start-Sleep -Seconds 1; if (Get-Process -Name health_workout_export -ErrorAction SilentlyContinue) { throw 'App process remains after stop' }"], f"{phase}/stop.log")

    def run(self):
        self.write_summary()
        try:
            self.prepare()
            reports = {}
            for phase in PHASES:
                phase_folder = self.output / phase
                phase_folder.mkdir(parents=True, exist_ok=True)
                if (phase_folder / "results.json").exists():
                    raise RuntimeError(f"Existing {phase} results would make evidence stale; use a fresh output directory")
                self.env["HWE_RUNTIME_OUTPUT"] = str(phase_folder.resolve())
                self.env["HWE_RUNTIME_PHASE"] = phase
                self.command(drive_command(self.device, phase), f"{phase}/flutter-drive.log", timeout=1800, cwd=APP)
                reports[phase] = validate_report(phase_folder, phase)
                self.stop_application(phase)
                self.summary["phases"].append({"phase": phase, "status": "passed", "pid": reports[phase]["pid"]})
                self.write_summary()
                print(f"RUNTIME_PHASE_PASSED platform={self.platform} phase={phase}", flush=True)
                if phase == "seed":
                    (self.output / "process-restart.json").write_text(json.dumps({"seedPid": reports[phase]["pid"], "nativeStopVerified": True, "verifyPending": True}, indent=2), encoding="utf-8")
            if reports["seed"]["pid"] == reports["verify"]["pid"]:
                raise RuntimeError("Seed and verify reported the same PID; independent process restart is unproven")
            (self.output / "process-restart.json").write_text(json.dumps({"seedPid": reports["seed"]["pid"], "verifyPid": reports["verify"]["pid"], "nativeStopVerified": True, "persistentStateVerifiedByIntegrationTest": True}, indent=2), encoding="utf-8")
            self.summary["status"] = "passed"
        except Exception as error:
            self.summary.update(status="failed", error=str(error))
            raise
        finally:
            self.write_summary()
            if self.emulator is not None:
                if self.adb:
                    try:
                        self.command([self.adb, "-s", self.device, "logcat", "-d", "-t", "2000"], "android-logcat.log", timeout=30, check=False)
                    except (OSError, RuntimeError) as error:
                        print(f"Diagnostic log collection failed: {error}", file=sys.stderr)
                self.emulator.terminate()
                try:
                    self.emulator.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    self.emulator.kill()
                    self.emulator.wait(timeout=10)
                self.emulator_log.close()
            if self.simulator_booted:
                self.command(["xcrun", "simctl", "shutdown", self.device], "ios-shutdown.log", timeout=60, check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=("android", "ios", "macos", "windows"))
    args = parser.parse_args()
    output = APP / "build/runtime-evidence" / args.platform
    try:
        Runner(args.platform, output).run()
    except Exception as error:
        print(f"Runtime validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
