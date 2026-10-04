#!/usr/bin/env python3
"""Portable source-boundary checks; Apple reset behavior is covered by XCTest.

These checks do not execute Swift or the real Keychain. They ensure the tested
fixed-key purge stays wired before the production read/recovery path.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class KeepVaultRecoveryContractTest(unittest.TestCase):
    def test_apple_reset_bypasses_every_read_and_uses_fixed_delete_targets(self):
        for platform in ("ios", "macos"):
            with self.subTest(platform=platform):
                source = (ROOT / f"flutter_app/{platform}/Runner/ThirdPartyVaultPlugin.swift").read_text()
                dispatch = source.split("DispatchQueue.main.async {", 1)[1].split("switch operation {", 1)[0]
                self.assertIn("if operation == .resetKeepAuthorization", dispatch)
                self.assertLess(dispatch.index("Self.resetKeepAuthorization(remove: self.remove)"), dispatch.index("self.recoverJournalIfNeeded"))
                self.assertIn("return", dispatch.split("Self.resetKeepAuthorization(remove: self.remove)", 1)[1].split("self.recoverJournalIfNeeded", 1)[0])
                purge = source.split("static func resetKeepAuthorization(", 1)[1].split("private func purgeUnrecoverableVault", 1)[0]
                self.assertIn("remove(Vault.keep.journalAccount)", purge)
                self.assertIn("Vault.keep.accounts", purge)
                self.assertLess(purge.index("remove(Vault.keep.journalAccount)"), purge.index("Vault.keep.accounts"))
                for forbidden in ("storedValue", "loadState", "recoverJournal", "write(", "store("):
                    self.assertNotIn(forbidden, purge)

    def test_apple_corrupt_keep_journal_requires_explicit_reset(self):
        for platform in ("ios", "macos"):
            with self.subTest(platform=platform):
                source = (ROOT / f"flutter_app/{platform}/Runner/ThirdPartyVaultPlugin.swift").read_text()
                recovery = source.split("private func recoverJournalIfNeeded", 1)[1].split("private func purgeUnrecoverableVault", 1)[0]
                self.assertIn('if vault == .keep {', recovery)
                self.assertIn('vaultError("keep_vault_corrupt"', recovery)
                self.assertLess(recovery.index('vaultError("keep_vault_corrupt"'), recovery.index("purgeUnrecoverableVault(vault)"))


if __name__ == "__main__":
    unittest.main()
