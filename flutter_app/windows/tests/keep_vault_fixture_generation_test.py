#!/usr/bin/env python3
"""Regression checks for toolchain-independent Keep fixture generation."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "tests/keep_vault_dispatch_test.py"


class KeepVaultFixtureGenerationTest(unittest.TestCase):
    def emit(self, generator, output):
        env = os.environ.copy()
        # Generation must work outside any C++ developer/toolchain environment.
        env.update(CXX="hwe-nonexistent-compiler", PYTHONUTF8="0",
                   PYTHONCOERCECLOCALE="0", LC_ALL="C")
        result = subprocess.run(
            [sys.executable, str(generator), "--emit-cpp", str(output)],
            env=env, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return output.read_bytes()

    def test_emits_deterministic_fixture_without_invoking_compiler(self):
        with tempfile.TemporaryDirectory(prefix="hwe-keep-fixture-") as directory:
            first = self.emit(GENERATOR, Path(directory) / "first.cpp")
            second = self.emit(GENERATOR, Path(directory) / "second.cpp")
        self.assertEqual(first, second)
        source = first.decode("utf-8")
        self.assertIn("void HandleVault(", source)
        self.assertIn("int main()", source)
        self.assertIn("Keep production dispatch tests passed", source)

    def test_reads_and_writes_utf8_independent_of_system_locale(self):
        with tempfile.TemporaryDirectory(prefix="hwe-keep-fixture-utf8-") as directory:
            root = Path(directory)
            (root / "tests").mkdir()
            (root / "runner").mkdir()
            generator = root / "tests/keep_vault_dispatch_test.py"
            shutil.copyfile(GENERATOR, generator)
            source = (ROOT / "runner/native_channels.cpp").read_text(encoding="utf-8")
            # Use the actual production extraction boundary with a Unicode comment.
            marker = "// Keep fixture: \u4fdd\u6301\u6388\u6743\n"
            source = source.replace("bool EncodePreference(", marker + "bool EncodePreference(", 1)
            (root / "runner/native_channels.cpp").write_text(source, encoding="utf-8")
            emitted = self.emit(generator, root / "fixture.cpp")
        self.assertIn(marker, emitted.decode("utf-8"))


if __name__ == "__main__":
    unittest.main()
