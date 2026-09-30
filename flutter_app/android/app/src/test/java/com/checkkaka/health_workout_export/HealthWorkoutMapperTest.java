package com.checkkaka.health_workout_export;

import static org.junit.Assert.*;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import org.junit.Test;

public class HealthWorkoutMapperTest {
    @Test public void identifiersAreStableValidAndNamespaced() {
        String uuid = HealthWorkoutMapper.workoutUuid("provider-record-1");
        assertTrue(HealthWorkoutMapper.validUuid(uuid));
        assertEquals(uuid, HealthWorkoutMapper.workoutUuid("provider-record-1"));
        assertNotEquals(uuid, HealthWorkoutMapper.workoutUuid("provider-record-2"));
        assertEquals("a4b64e8c-0012-4a0b-993e-140fc6b721c0", HealthWorkoutMapper.workoutUuid("A4B64E8C-0012-4A0B-993E-140FC6B721C0"));
        assertThrows(IllegalArgumentException.class, () -> HealthWorkoutMapper.workoutUuid(""));
        assertFalse(HealthWorkoutMapper.validUuid("../provider"));
    }

    @Test public void queriesUseStrictHalfOpenStartsAndBoundedIntervals() {
        assertTrue(HealthWorkoutMapper.validInterval(1000, 2000));
        assertFalse(HealthWorkoutMapper.validInterval(2000, 1000));
        assertFalse(HealthWorkoutMapper.validInterval(1000, 1000));
        assertFalse(HealthWorkoutMapper.validInterval(Long.MIN_VALUE, Long.MAX_VALUE));
        assertTrue(HealthWorkoutMapper.inHalfOpenRange(1000, 1000, 2000));
        assertFalse(HealthWorkoutMapper.inHalfOpenRange(2000, 1000, 2000));
        assertFalse(HealthWorkoutMapper.containedInterval(500, 1500, 1000, 2000));
        assertTrue(HealthWorkoutMapper.containedInterval(1000, 2000, 1000, 2000));
    }

    @Test public void exerciseTypesMapToExistingWireSchemaWithoutLosingUnknownKinds() {
        assertEquals(13, HealthWorkoutMapper.activityType(8));
        assertEquals(13, HealthWorkoutMapper.activityType(9));
        assertEquals(37, HealthWorkoutMapper.activityType(56));
        assertEquals(46, HealthWorkoutMapper.activityType(73));
        assertEquals(52, HealthWorkoutMapper.activityType(79));
        assertEquals(3000, HealthWorkoutMapper.activityType(9999));
        assertTrue(HealthWorkoutMapper.isIndoor(9));
        assertFalse(HealthWorkoutMapper.isIndoor(8));
        assertEquals("HKQuantityTypeIdentifierDistanceCycling", HealthWorkoutMapper.distanceKey(8));
        assertEquals("HKQuantityTypeIdentifierRunningSpeed", HealthWorkoutMapper.speedKey(56));
    }

    @Test public void summaryPreservesNullTotalsAndExcludesMergedPauses() {
        List<long[]> pauses = Arrays.asList(new long[]{2000, 4000}, new long[]{3000, 5000}, new long[]{8000, 9000});
        Map<String, Object> summary = HealthWorkoutMapper.summary("session", 1000, 11000, 8, "example.tracker", pauses, null, null);
        assertEquals(6.0, (Double) summary.get("durationSeconds"), 0.0);
        assertNull(summary.get("totalEnergyKcal"));
        assertNull(summary.get("totalDistanceMeters"));
        assertEquals("example.tracker", summary.get("sourceBundleId"));
        assertEquals("骑车", summary.get("activityName"));
        assertEquals(1000L, summary.get("startMs"));
        assertEquals(11000L, summary.get("endMs"));
        assertThrows(IllegalArgumentException.class, () -> HealthWorkoutMapper.summary("session", 1000, 11000, 8, "source", pauses, Double.NaN, null));
    }

    @Test public void eventsAreBoundedSortedAndDoNotResumeAfterWorkoutEnd() {
        List<Map<String, Object>> events = HealthWorkoutMapper.events(1000, 10000,
            Arrays.asList(new long[]{-10, 2000}, new long[]{8000, 12000}), Arrays.asList(500L, 5000L, 10000L, 11000L));
        assertEquals(5, events.size());
        assertEquals("pause", events.get(0).get("type"));
        assertEquals(1000L, events.get(0).get("dateMs"));
        assertEquals("resume", events.get(1).get("type"));
        assertEquals("lap", events.get(2).get("type"));
        assertEquals("pause", events.get(3).get("type"));
        assertEquals("lap", events.get(4).get("type"));
    }

    @Test public void samplesRequireFiniteNonNegativeValuesAndExplicitUnits() {
        Map<String, Object> heartRate = HealthWorkoutMapper.quantity(1000, 142, "count/min");
        assertEquals(142.0, heartRate.get("value"));
        assertEquals("count/min", heartRate.get("unit"));
        assertThrows(IllegalArgumentException.class, () -> HealthWorkoutMapper.quantity(1000, Double.NaN, "W"));
        assertThrows(IllegalArgumentException.class, () -> HealthWorkoutMapper.quantity(1000, -1, "m"));
        assertThrows(IllegalArgumentException.class, () -> HealthWorkoutMapper.quantity(1000, 1, ""));
    }

    @Test public void routesPreserveOptionalAltitudeAndNeverInventSpeed() {
        Map<String, Object> point = HealthWorkoutMapper.route(1000, 31.5, 120.5, null);
        assertEquals(31.5, point.get("latitude"));
        assertFalse(point.containsKey("altitudeMeters"));
        assertFalse(point.containsKey("speedMetersPerSecond"));
        assertEquals(-3.0, HealthWorkoutMapper.route(1000, 31.5, 120.5, -3.0).get("altitudeMeters"));
        assertThrows(IllegalArgumentException.class, () -> HealthWorkoutMapper.route(1000, 91, 120, null));
        assertThrows(IllegalArgumentException.class, () -> HealthWorkoutMapper.route(1000, 31, Double.NaN, null));
    }
}
