package com.checkkaka.health_workout_export;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/** Pure conversion to the existing Flutter workout schema; no Android or health store access. */
public final class HealthWorkoutMapper {
    private HealthWorkoutMapper() {}
    public static final int MAX_RECORDS = 100_000;
    public static final int MAX_SAMPLES = 1_000_000;
    public static final int MAX_BATCH = 100;

    public static boolean validInterval(long startMs, long endMs) {
        return startMs >= -2_208_988_800_000L && endMs <= 7_258_118_400_000L && startMs < endMs;
    }

    public static boolean validUuid(String value) {
        return value != null && value.matches("(?i)[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}");
    }

    public static String workoutUuid(String recordId) {
        if (recordId == null || recordId.isEmpty() || recordId.length() > 1024) throw new IllegalArgumentException("Invalid record ID");
        if (validUuid(recordId)) return recordId.toLowerCase(Locale.ROOT);
        return UUID.nameUUIDFromBytes(("health-connect:" + recordId).getBytes(StandardCharsets.UTF_8)).toString();
    }

    public static boolean inHalfOpenRange(long value, long startMs, long endMs) {
        return value >= startMs && value < endMs;
    }

    public static boolean containedInterval(long startMs, long endMs, long sessionStartMs, long sessionEndMs) {
        return startMs >= sessionStartMs && endMs <= sessionEndMs && startMs < endMs;
    }

    /** Health Connect 1.1.0 exercise constants -> shared legacy HK workout enum, never a data claim. */
    public static int activityType(int exerciseType) {
        switch (exerciseType) {
            case 8: case 9: return 13; // biking / stationary biking
            case 56: case 57: return 37; // running / treadmill
            case 79: return 52;
            case 37: return 24;
            case 73: case 74: return 46;
            case 53: case 54: return 35;
            case 25: return 16;
            case 70: case 81: return 50;
            case 83: return 57;
            case 48: return 66;
            case 36: return 63;
            case 68: case 69: return 44;
            case 16: return 14;
            case 2: return 4;
            case 4: return 5;
            case 5: return 6;
            case 11: return 8;
            case 32: return 21;
            case 64: return 41;
            case 76: return 48;
            case 78: return 51;
            case 75: return 47;
            case 51: return 9;
            case 62: return 67;
            case 63: return 40;
            case 58: return 38;
            case 72: return 45;
            case 46: return 31;
            case 71: return 62;
            default: return 3000;
        }
    }

    public static String activityName(int exerciseType) {
        switch (activityType(exerciseType)) {
            case 13: return "骑车";
            case 37: return "跑步";
            case 52: return "步行";
            case 24: return "徒步";
            case 46: return "游泳";
            case 35: return "划船";
            case 16: return "椭圆机";
            case 50: return "力量训练";
            case 57: return "瑜伽";
            case 66: return "普拉提";
            case 63: return "高强度间歇训练";
            case 44: return "爬楼梯";
            default: return "训练";
        }
    }

    public static boolean isIndoor(int exerciseType) {
        return exerciseType == 9 || exerciseType == 25 || exerciseType == 54 || exerciseType == 57 || exerciseType == 69;
    }

    public static String distanceKey(int exerciseType) {
        switch (activityType(exerciseType)) {
            case 13: return "HKQuantityTypeIdentifierDistanceCycling";
            case 46: return "HKQuantityTypeIdentifierDistanceSwimming";
            default: return "HKQuantityTypeIdentifierDistanceWalkingRunning";
        }
    }

    public static String speedKey(int exerciseType) {
        return activityType(exerciseType) == 13 ? "HKQuantityTypeIdentifierCyclingSpeed" : "HKQuantityTypeIdentifierRunningSpeed";
    }

    public static List<long[]> normalizedPauses(long startMs, long endMs, List<long[]> pauses) {
        if (!validInterval(startMs, endMs)) throw new IllegalArgumentException("Invalid workout interval");
        List<long[]> sorted = new ArrayList<>();
        for (long[] pause : pauses) {
            if (pause == null || pause.length != 2) throw new IllegalArgumentException("Invalid pause");
            long start = Math.max(startMs, pause[0]);
            long end = Math.min(endMs, pause[1]);
            if (start < end) sorted.add(new long[] {start, end});
        }
        sorted.sort(Comparator.comparingLong(value -> value[0]));
        List<long[]> result = new ArrayList<>();
        for (long[] pause : sorted) {
            if (result.isEmpty() || result.get(result.size() - 1)[1] < pause[0]) result.add(pause);
            else result.get(result.size() - 1)[1] = Math.max(result.get(result.size() - 1)[1], pause[1]);
        }
        return result;
    }

    public static Map<String, Object> summary(String recordId, long startMs, long endMs, int exerciseType,
        String sourcePackage, List<long[]> pauses, Double energyKcal, Double distanceMeters) {
        if (!validInterval(startMs, endMs)) throw new IllegalArgumentException("Invalid workout interval");
        long pausedMs = 0;
        for (long[] pause : normalizedPauses(startMs, endMs, pauses)) pausedMs += pause[1] - pause[0];
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("uuid", workoutUuid(recordId));
        value.put("startMs", startMs);
        value.put("endMs", endMs);
        value.put("durationSeconds", (endMs - startMs - pausedMs) / 1000.0);
        value.put("activityType", activityType(exerciseType));
        value.put("activityName", activityName(exerciseType));
        value.put("sourceName", sourcePackage == null || sourcePackage.isEmpty() ? "Health Connect" : sourcePackage);
        value.put("sourceBundleId", sourcePackage);
        value.put("totalEnergyKcal", optionalNonNegative(energyKcal));
        value.put("totalDistanceMeters", optionalNonNegative(distanceMeters));
        return value;
    }

    public static Map<String, Object> quantity(long timeMs, double value, String unit) {
        if (!Double.isFinite(value) || value < 0 || unit == null || unit.isEmpty()) throw new IllegalArgumentException("Invalid sample");
        Map<String, Object> sample = new LinkedHashMap<>();
        sample.put("dateMs", timeMs); sample.put("value", value); sample.put("unit", unit);
        return sample;
    }

    public static Map<String, Object> route(long timeMs, double latitude, double longitude, Double altitude) {
        if (!Double.isFinite(latitude) || !Double.isFinite(longitude) || Math.abs(latitude) > 90 || Math.abs(longitude) > 180
            || altitude != null && !Double.isFinite(altitude)) throw new IllegalArgumentException("Invalid route point");
        Map<String, Object> point = new LinkedHashMap<>();
        point.put("latitude", latitude); point.put("longitude", longitude); point.put("timestampMs", timeMs);
        if (altitude != null) point.put("altitudeMeters", altitude);
        // Health Connect route locations have no speed field. Do not synthesize one.
        return point;
    }

    public static List<Map<String, Object>> events(long startMs, long endMs, List<long[]> pauses, List<Long> lapEnds) {
        List<Map<String, Object>> result = new ArrayList<>();
        for (long[] pause : normalizedPauses(startMs, endMs, pauses)) {
            result.add(event("pause", pause[0]));
            if (pause[1] < endMs) result.add(event("resume", pause[1]));
        }
        for (long time : lapEnds) if (time > startMs && time <= endMs) result.add(event("lap", time));
        result.sort(Comparator.comparingLong(value -> (Long) value.get("dateMs")));
        return result;
    }

    private static Map<String, Object> event(String type, long timeMs) {
        Map<String, Object> result = new LinkedHashMap<>(); result.put("type", type); result.put("dateMs", timeMs); return result;
    }
    private static Double optionalNonNegative(Double value) {
        if (value != null && (!Double.isFinite(value) || value < 0)) throw new IllegalArgumentException("Invalid total");
        return value;
    }
}
