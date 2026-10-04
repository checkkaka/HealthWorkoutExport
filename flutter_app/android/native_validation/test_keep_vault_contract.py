#!/usr/bin/env python3
"""Source boundary checks; JVM behavior tests live in KeepVaultTest.kt."""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[1] /
          "app/src/main/kotlin/com/checkkaka/health_workout_export/MainActivity.kt")


class KeepVaultContractTest(unittest.TestCase):
    def test_keep_channel_methods_exist(self):
        source = SOURCE.read_text()
        for method in ("keepStatus", "keepLease", "writeKeepAuthorization", "clearKeepAuthorization", "resetKeepAuthorization"):
            self.assertTrue(f'"{method}"' in source, f"Keep method missing: {method}")

    def test_secret_store_record_codec_has_no_android_runtime_dependencies(self):
        source = SOURCE.read_text().split("class SecretStore", 1)[1].split("private class AndroidKeyStoreCipher", 1)[0]
        self.assertNotIn("JSONObject(", source)
        self.assertNotIn("JSONTokener(", source)

    def test_keep_is_not_a_normal_preference(self):
        source = SOURCE.read_text()
        preferences = source.split("val ALLOWED_PREFERENCE_KEYS = setOf(", 1)[1].split(")", 1)[0]
        self.assertNotIn("keep", preferences)


if __name__ == "__main__":
    unittest.main()
