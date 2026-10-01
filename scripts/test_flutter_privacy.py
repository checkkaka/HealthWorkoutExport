"""Static regression: nested Flutter tools must inherit the official NoOp flag.

This does not execute Flutter and is not permission to run any code generator.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FlutterPrivacyTests(unittest.TestCase):
    def test_workflows_suppress_nested_flutter_analytics(self):
        for filename in ("ci.yml", "native-platforms.yml", "app-builds.yml", "release.yml"):
            with self.subTest(workflow=filename):
                text = (ROOT / ".github/workflows" / filename).read_text()
                root_env = re.search(r"(?m)^env:\n((?:[ \t].*\n|\n)*)", text)
                self.assertIsNotNone(root_env)
                self.assertRegex(
                    root_env.group(1),
                    r'(?m)^  FLUTTER_SUPPRESS_ANALYTICS: "true"$',
                )

    def test_local_contract_runner_suppresses_nested_flutter_analytics(self):
        script = (ROOT / "scripts/verify-flutter-contracts.sh").read_text()
        self.assertIn("FLUTTER_SUPPRESS_ANALYTICS=true", script)
        self.assertIn('"$flutter_bin" --suppress-analytics', script)

    def test_native_pod_builder_does_not_dump_environment(self):
        script = (ROOT / "flutter_app/rust_builder/cargokit/build_pod.sh").read_text()
        self.assertNotRegex(script, r"(?m)^\s*(?:env|printenv|set)\s*$")

    def test_full_validation_does_not_resolve_packages_implicitly(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("flutter --suppress-analytics analyze --no-pub", workflow)
        self.assertIn("flutter --suppress-analytics test --no-pub", workflow)


if __name__ == "__main__":
    unittest.main()
