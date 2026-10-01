package com.checkkaka.health_workout_export

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test

class NativeChannelsTest {
    @Test
    fun legacyPreviewAndHealthWritePreferenceKeysAreAllowed() {
        assertTrue("sync_preview_policy" in NativeChannels.ALLOWED_PREFERENCE_KEYS)
        assertTrue("write_to_apple_health" in NativeChannels.ALLOWED_PREFERENCE_KEYS)
        assertFalse("arbitrary_key" in NativeChannels.ALLOWED_PREFERENCE_KEYS)
    }

    @Test
    fun stableUuidIsDeterministicAndNotAHealthKitForgery() {
        val first = NativeChannels.stableUuid("exercise-session-1")
        val second = NativeChannels.stableUuid("exercise-session-1")
        val other = NativeChannels.stableUuid("exercise-session-2")
        assertEquals(first, second)
        assertNotEquals(first, other)
        assertEquals(36, first.length)
    }
}
