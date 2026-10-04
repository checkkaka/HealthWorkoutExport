package com.checkkaka.health_workout_export

import android.content.SharedPreferences
import java.util.ArrayDeque
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec
import org.junit.Assert.*
import org.junit.Test

/** Exercises production validation and transactions without a device or accounts. */
class KeepVaultTest {
    private val prefs = MemoryPreferences()
    private val cipher = TestCipher()
    private val store = SecretStore(prefs, cipher)
    private fun authorization(account: String = "synthetic-account", token: String = "synthetic-token") =
        mapOf("account" to account, "token" to token)

    private fun expectFailure(code: String, action: () -> Unit) {
        try { action(); fail("Expected $code") }
        catch (failure: SecretStore.KeepFailure) { assertEquals(code, failure.code) }
    }

    @Test fun emptyStatusHasOnlyNonsecretFlagsAndCannotBeLeased() {
        assertEquals(mapOf("hasAccount" to false, "hasToken" to false), store.keepStatus())
        expectFailure("keep_not_configured") { store.keepLease() }
    }

    @Test fun oneEncryptedCommitStoresOnlyAccountAndToken() {
        store.writeKeepAuthorization(authorization())
        assertEquals(1, prefs.commits)
        assertEquals(0, prefs.applies)
        assertEquals(1, prefs.values.size)
        assertEquals(prefs.values, prefs.disk)
        assertFalse(prefs.values.toString().contains("synthetic-account"))
        assertFalse(prefs.values.toString().contains("synthetic-token"))
        assertEquals(authorization(), store.keepLease())
        assertEquals(mapOf("hasAccount" to true, "hasToken" to true), store.keepStatus())
    }

    @Test fun passwordAndUnknownKeysAreRejectedBeforeEncryptionOrMutation() {
        store.writeKeepAuthorization(authorization())
        val saved = prefs.values.toMap()
        for (key in listOf("password", "refreshToken", "sessionId", "other", "keep.token")) {
            expectFailure("invalid_arguments") { store.writeKeepAuthorization(authorization() + (key to "never-save")) }
        }
        assertEquals(saved, prefs.values)
        assertEquals(1, prefs.commits)
        assertEquals(1, cipher.encryptions)
    }

    @Test fun malformedArgumentsCannotOverwriteAuthorization() {
        store.writeKeepAuthorization(authorization())
        val malformed = listOf(null, "text", emptyMap<String, String>(), mapOf("account" to "a"),
            mapOf("account" to 42, "token" to "t"), mapOf("account" to "a", "token" to null),
            authorization("", "t"), authorization("a", " \t\n"), authorization("a\u0000b", "t"),
            authorization("a", "x".repeat(2561)), authorization("\uD800", "t"))
        for (value in malformed) expectFailure("invalid_arguments") { store.writeKeepAuthorization(value) }
        assertEquals(authorization(), store.keepLease())
        assertEquals(1, prefs.commits)
    }

    @Test fun validUnicodeAndCredentialWhitespaceRoundTrip() {
        val value = authorization(" 训练😀 ", " token ")
        store.writeKeepAuthorization(value)
        assertEquals(value, store.keepLease())
    }

    @Test fun accountSwitchReplacesTheCompleteAuthorization() {
        store.writeKeepAuthorization(authorization())
        store.writeKeepAuthorization(authorization("new-account", "new-token"))
        assertEquals(authorization("new-account", "new-token"), store.keepLease())
        assertEquals(2, prefs.commits)
    }

    @Test fun encryptionFailureDoesNotBeginAMutation() {
        store.writeKeepAuthorization(authorization())
        cipher.failEncryption = true
        expectFailure("credential_store_error") { store.writeKeepAuthorization(authorization("new", "new-token")) }
        assertEquals(1, prefs.commits)
        assertEquals(authorization(), store.keepLease())
    }

    @Test fun failedCommitRollsBackBothMemoryAndDisk() {
        store.writeKeepAuthorization(authorization())
        val saved = prefs.disk.toMap()
        prefs.results.addAll(listOf(false, true))
        expectFailure("credential_store_error") { store.writeKeepAuthorization(authorization("new", "new-token")) }
        assertEquals(3, prefs.commits)
        assertEquals(saved, prefs.disk)
        assertEquals(saved, prefs.values)
        assertEquals(authorization(), SecretStore(prefs, cipher).keepLease())
    }

    @Test fun firstWriteFailureDoesNotLeaveAuthorization() {
        prefs.results.addAll(listOf(false, true))
        expectFailure("credential_store_error") { store.writeKeepAuthorization(authorization()) }
        assertTrue(prefs.values.isEmpty())
        assertTrue(prefs.disk.isEmpty())
        expectFailure("keep_not_configured") { store.keepLease() }
    }

    @Test fun failedRollbackBlocksAllInstancesUntilConfirmedClear() {
        store.writeKeepAuthorization(authorization())
        prefs.results.addAll(listOf(false, false))
        expectFailure("credential_store_error") { store.writeKeepAuthorization(authorization("new", "new-token")) }
        val replacement = SecretStore(prefs, cipher)
        expectFailure("credential_store_error") { store.keepLease() }
        expectFailure("credential_store_error") { replacement.keepStatus() }
        replacement.clearKeepAuthorization()
        assertEquals(mapOf("hasAccount" to false, "hasToken" to false), store.keepStatus())
        expectFailure("keep_not_configured") { replacement.keepLease() }
    }

    @Test fun confirmedReauthorizationRecoversAfterFailedRollback() {
        store.writeKeepAuthorization(authorization())
        prefs.results.addAll(listOf(false, false))
        expectFailure("credential_store_error") { store.clearKeepAuthorization() }
        store.writeKeepAuthorization(authorization("new", "new-token"))
        assertEquals(authorization("new", "new-token"), SecretStore(prefs, cipher).keepLease())
    }

    @Test fun failedClearRestoresAuthorizationAndReportsFailure() {
        store.writeKeepAuthorization(authorization())
        prefs.results.addAll(listOf(false, true))
        expectFailure("credential_store_error") { store.clearKeepAuthorization() }
        assertEquals(authorization(), store.keepLease())
    }

    @Test fun clearingIsIdempotentAndPreservesOtherProviders() {
        store.set("onelap.token", "other-provider-token")
        val other = prefs.values["onelap.token"]
        store.writeKeepAuthorization(authorization())
        store.clearKeepAuthorization()
        store.clearKeepAuthorization()
        assertEquals(mapOf("onelap.token" to other), prefs.values)
        assertEquals("other-provider-token", store.get("onelap.token"))
        expectFailure("keep_not_configured") { store.keepLease() }
    }

    @Test fun corruptCiphertextFailsClosedWithoutSecretErrorMessages() {
        store.writeKeepAuthorization(authorization())
        val key = prefs.values.keys.single()
        prefs.values[key] = "corrupt-synthetic-secret"
        expectFailure("credential_store_corrupt") { store.keepLease() }
        expectFailure("credential_store_corrupt") { store.keepStatus() }
        store.clearKeepAuthorization()
        assertTrue(prefs.values.isEmpty())
    }

    @Test fun encryptedPartialOrExtraRecordsCannotBeLeased() {
        store.writeKeepAuthorization(authorization())
        val key = prefs.values.keys.single()
        for (record in listOf("{\"account\":\"a\"}", "{\"token\":\"t\"}",
            "{\"account\":\"a\",\"token\":\"t\",\"password\":\"never-save\"}",
            "{\"account\":\"a\",\"token\":42}")) {
            prefs.values[key] = cipher.encrypt(record)
            expectFailure("credential_store_corrupt") { store.keepLease() }
        }
    }

    /** Real JVM AES-GCM, substituting only Android Keystore key provisioning. */
    private class TestCipher : SecretCipher {
        private val key = KeyGenerator.getInstance("AES").apply { init(128) }.generateKey()
        var failEncryption = false
        var encryptions = 0
        override fun encrypt(value: String): String {
            ++encryptions
            if (failEncryption) error("synthetic encryption failure")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            return Base64.getEncoder().encodeToString(cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8)))
        }
        override fun decrypt(packed: String): String {
            val bytes = Base64.getDecoder().decode(packed)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            return String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8)
        }
    }

    /** Models Android commit(): the memory map changes even when disk saving fails. */
    private class MemoryPreferences : SharedPreferences {
        val values = mutableMapOf<String, String>()
        val disk = mutableMapOf<String, String>()
        val results = ArrayDeque<Boolean>()
        var commits = 0
        var applies = 0
        override fun getAll(): Map<String, *> = values.toMap()
        override fun getString(key: String?, default: String?): String? = values[key] ?: default
        override fun contains(key: String?): Boolean = values.containsKey(key)
        override fun edit(): SharedPreferences.Editor = Editor()
        override fun getStringSet(key: String?, default: MutableSet<String>?): MutableSet<String>? = error("unused")
        override fun getInt(key: String?, default: Int): Int = error("unused")
        override fun getLong(key: String?, default: Long): Long = error("unused")
        override fun getFloat(key: String?, default: Float): Float = error("unused")
        override fun getBoolean(key: String?, default: Boolean): Boolean = error("unused")
        override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        private inner class Editor : SharedPreferences.Editor {
            private val changes = mutableMapOf<String, String?>()
            override fun putString(key: String?, value: String?): SharedPreferences.Editor = apply { changes[key!!] = value }
            override fun remove(key: String?): SharedPreferences.Editor = apply { changes[key!!] = null }
            override fun clear(): SharedPreferences.Editor = apply { values.keys.forEach { changes[it] = null } }
            override fun commit(): Boolean {
                ++commits
                changes.forEach { (key, value) -> if (value == null) values.remove(key) else values[key] = value }
                val success = if (results.isEmpty()) true else results.removeFirst()
                if (success) { disk.clear(); disk.putAll(values) }
                return success
            }
            override fun apply() { ++applies; changes.forEach { (key, value) -> if (value == null) values.remove(key) else values[key] = value }; disk.clear(); disk.putAll(values) }
            override fun putStringSet(key: String?, value: MutableSet<String>?): SharedPreferences.Editor = error("unused")
            override fun putInt(key: String?, value: Int): SharedPreferences.Editor = error("unused")
            override fun putLong(key: String?, value: Long): SharedPreferences.Editor = error("unused")
            override fun putFloat(key: String?, value: Float): SharedPreferences.Editor = error("unused")
            override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor = error("unused")
        }
    }
}
