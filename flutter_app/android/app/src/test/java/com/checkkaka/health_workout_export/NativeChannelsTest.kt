package com.checkkaka.health_workout_export

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class NativeChannelsTest {
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
