package com.checkkaka.health_workout_export

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.HealthConnectFeatures
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.contracts.ExerciseRouteRequestContract
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.*
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.metadata.DataOrigin
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.Instant
import java.time.Duration
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.reflect.KClass

/** Read-only adapter. The wire names are shared with iOS; every bundle identifies Health Connect. */
class HealthConnectPlugin(private val activity: Activity) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val pending = linkedMapOf<Long, MethodChannel.Result>()
    private var nextOperation = 0L
    private var permissionsResult: CompletableDeferred<Set<String>>? = null
    private var routeResult: CompletableDeferred<ExerciseRoute?>? = null
    private val permissionContract = PermissionController.createRequestPermissionResultContract()
    private val routeContract = ExerciseRouteRequestContract()
    private val recordIndex = activity.getSharedPreferences("health_connect_record_index", Context.MODE_PRIVATE)
    private val cache = linkedMapOf<String, ExerciseSessionRecord>()
    private var foreground = false

    fun setForeground(value: Boolean) { foreground = value }

    fun detach() {
        val results = pending.values.toList()
        pending.clear()
        permissionsResult?.cancel()
        permissionsResult = null
        routeResult?.cancel()
        routeResult = null
        scope.cancel()
        cache.clear()
        results.forEach { it.error("healthkit_interrupted", "健康数据读取已中断，请重试", null) }
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        when (requestCode) {
            PERMISSION_REQUEST -> {
                val deferred = permissionsResult
                permissionsResult = null
                try { deferred?.complete(permissionContract.parseResult(resultCode, data)) }
                catch (error: Exception) { deferred?.completeExceptionally(error) }
                return true
            }
            ROUTE_REQUEST -> {
                val deferred = routeResult
                routeResult = null
                try { deferred?.complete(routeContract.parseResult(resultCode, data)) }
                catch (error: Exception) { deferred?.completeExceptionally(error) }
                return true
            }
        }
        return false
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(availability() == HealthConnectClient.SDK_AVAILABLE)
            "currentTimeZoneIdentifier" -> result.success(java.util.TimeZone.getDefault().id)
            "openSettings" -> {
                try {
                    activity.startActivity(Intent(HealthConnectClient.ACTION_HEALTH_CONNECT_SETTINGS))
                    result.success(null)
                } catch (_: Exception) { result.error("settings_unavailable", "无法打开 Health Connect 设置", null) }
            }
            "requestAuthorization" -> launch(result) { authorize(); null }
            "listWorkouts" -> launch(result) {
                val start = integer(call, "startMs")
                val end = integer(call, "endMs")
                require(HealthWorkoutMapper.validInterval(start, end))
                val client = client()
                val granted = requireExercisePermission(client)
                requireHistoryAccess(client, granted, start)
                val workouts = readAll(client, ExerciseSessionRecord::class, Instant.ofEpochMilli(start), Instant.ofEpochMilli(end))
                    .filter { HealthWorkoutMapper.inHalfOpenRange(it.startTime.toEpochMilli(), start, end) }
                    .sortedWith(compareByDescending<ExerciseSessionRecord> { it.startTime }.thenBy { it.metadata.id })
                cache.clear()
                val editor = recordIndex.edit()
                for (workout in workouts) {
                    val uuid = HealthWorkoutMapper.workoutUuid(workout.metadata.id)
                    cache[uuid] = workout
                    // Only an ID lookup index is persisted, never workout/sample/route data.
                    if (uuid != workout.metadata.id) editor.putString(uuid, workout.metadata.id)
                }
                check(editor.commit()) { "Unable to persist workout identifiers" }
                workouts.map { summary(it, null, null) }
            }
            "fetchWorkoutBundles" -> launch(result) {
                val values = call.argument<List<*>>("uuids") ?: throw IllegalArgumentException()
                require(values.isNotEmpty() && values.size <= HealthWorkoutMapper.MAX_BATCH)
                val uuids = values.map { value ->
                    val uuid = value as? String ?: throw IllegalArgumentException()
                    require(HealthWorkoutMapper.validUuid(uuid))
                    uuid.lowercase(Locale.ROOT)
                }
                require(uuids.toSet().size == uuids.size)
                val client = client()
                val granted = requireExercisePermission(client)
                // Sequential batches keep route consent dialogs and memory use bounded; input order is retained.
                var batchPoints = 0L
                uuids.map { uuid ->
                    val recordId = recordIndex.getString(uuid, null) ?: uuid
                    // Re-read to enforce current permissions and detect deleted/changed workouts.
                    val workout = client.readRecord(ExerciseSessionRecord::class, recordId).record
                    require(HealthWorkoutMapper.workoutUuid(workout.metadata.id) == uuid)
                    requireHistoryAccess(client, granted, workout.startTime.toEpochMilli())
                    bundle(client, workout, granted).also { bundle ->
                        val series = bundle["series"] as? Map<*, *> ?: emptyMap<Any, Any>()
                        batchPoints += series.values.sumOf { (it as? List<*>)?.size?.toLong() ?: 0L }
                        batchPoints += (bundle["route"] as? List<*>)?.size ?: 0
                        if (batchPoints > HealthWorkoutMapper.MAX_SAMPLES) throw HealthFailure("healthkit_data_too_large", "本批训练样本过多，请减少选择数量")
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun launch(result: MethodChannel.Result, block: suspend () -> Any?) {
        if (pending.size >= 3) {
            result.error("healthkit_operation_in_progress", "健康数据读取正在进行，请稍后重试", null)
            return
        }
        val id = ++nextOperation
        pending[id] = result
        scope.launch {
            try {
                val response = block()
                pending.remove(id)?.success(response)
            } catch (_: CancellationException) {
                pending.remove(id)?.error("healthkit_interrupted", "健康数据读取已中断，请重试", null)
            } catch (error: HealthFailure) {
                pending.remove(id)?.error(error.code, error.message, mapOf("missing" to true))
            } catch (_: SecurityException) {
                cache.clear()
                pending.remove(id)?.error("authorization_failed", "健康数据读取权限已撤销或不足，请重新授权", null)
            } catch (_: IllegalArgumentException) {
                pending.remove(id)?.error("invalid_arguments", "健康数据请求或返回的数据无效", null)
            } catch (_: Exception) {
                pending.remove(id)?.error("query_failed", "无法读取 Health Connect 数据，请稍后重试", null)
            }
        }
    }

    private fun availability(): Int = try {
        if (Build.VERSION.SDK_INT < 28) HealthConnectClient.SDK_UNAVAILABLE else HealthConnectClient.getSdkStatus(activity)
    } catch (_: Exception) { HealthConnectClient.SDK_UNAVAILABLE }

    private fun client(): HealthConnectClient {
        val status = availability()
        if (status != HealthConnectClient.SDK_AVAILABLE) throw HealthFailure(
            "healthkit_unavailable",
            if (status == HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED) "请安装或更新 Health Connect" else "此设备不支持 Health Connect，请使用 FIT 导入",
        )
        return HealthConnectClient.getOrCreate(activity)
    }

    private suspend fun authorize() {
        val client = client()
        if (!foreground || activity.isFinishing || activity.isDestroyed) throw HealthFailure("authorization_failed", "请在应用前台授权健康数据读取")
        if (permissionsResult != null || routeResult != null) throw HealthFailure("authorization_in_progress", "已有健康数据授权正在进行")
        val permissions = RECORD_TYPES.map { HealthPermission.getReadPermission(it) }.toMutableSet()
        if (historySupported(client)) permissions += HealthPermission.PERMISSION_READ_HEALTH_DATA_HISTORY
        if (!client.permissionController.getGrantedPermissions().containsAll(permissions)) {
            val deferred = CompletableDeferred<Set<String>>()
            permissionsResult = deferred
            try {
                activity.startActivityForResult(permissionContract.createIntent(activity, permissions), PERMISSION_REQUEST)
                deferred.await()
            } finally { if (permissionsResult === deferred) permissionsResult = null }
        }
        requireExercisePermission(client)
        if (!recordIndex.contains(FIRST_GRANT)) recordIndex.edit().putLong(FIRST_GRANT, System.currentTimeMillis()).commit()
    }

    private suspend fun requireExercisePermission(client: HealthConnectClient): Set<String> {
        val granted = client.permissionController.getGrantedPermissions()
        if (HealthPermission.getReadPermission(ExerciseSessionRecord::class) !in granted) {
            throw HealthFailure("authorization_failed", "尚未获得训练读取权限，请先授权 Health Connect")
        }
        return granted
    }

    private fun historySupported(client: HealthConnectClient): Boolean =
        client.features.getFeatureStatus(HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_HISTORY) == HealthConnectFeatures.FEATURE_STATUS_AVAILABLE

    private fun requireHistoryAccess(client: HealthConnectClient, granted: Set<String>, startMs: Long) {
        if (HealthPermission.PERMISSION_READ_HEALTH_DATA_HISTORY in granted) return
        val firstGrant = recordIndex.getLong(FIRST_GRANT, System.currentTimeMillis())
        if (startMs < firstGrant - Duration.ofDays(30).toMillis()) throw HealthFailure(
            "healthkit_history_permission_required",
            if (historySupported(client)) "读取更早训练需要 Health Connect 历史记录权限，请重新授权或缩小日期区间"
            else "此 Health Connect 版本限制历史记录读取，请缩小日期区间或导入 FIT",
        )
    }

    private suspend fun <T : Record> readAll(
        client: HealthConnectClient, type: KClass<T>, start: Instant, end: Instant,
        origin: DataOrigin? = null,
    ): List<T> = withContext(Dispatchers.IO) {
        withTimeout(120_000) {
            val records = arrayListOf<T>()
            val tokens = hashSetOf<String>()
            var token: String? = null
            var points = 0L
            do {
                val response = client.readRecords(ReadRecordsRequest(
                    recordType = type, timeRangeFilter = TimeRangeFilter.between(start, end),
                    dataOriginFilter = origin?.let { setOf(it) } ?: emptySet(),
                    ascendingOrder = true, pageSize = 500, pageToken = token,
                ))
                points += response.records.sumOf { record ->
                    when (record) {
                        is HeartRateRecord -> record.samples.size.toLong()
                        is SpeedRecord -> record.samples.size.toLong()
                        is PowerRecord -> record.samples.size.toLong()
                        is CyclingPedalingCadenceRecord -> record.samples.size.toLong()
                        is ExerciseSessionRecord -> ((record.exerciseRouteResult as? ExerciseRouteResult.Data)?.exerciseRoute?.route?.size ?: 0).toLong() + record.segments.size + record.laps.size
                        else -> 1L
                    }
                }
                if (points > HealthWorkoutMapper.MAX_SAMPLES) throw HealthFailure("healthkit_data_too_large", "健康样本过多，请缩小日期区间")
                records.addAll(response.records)
                if (records.size > HealthWorkoutMapper.MAX_RECORDS) throw HealthFailure("healthkit_data_too_large", "健康数据过多，请缩小日期区间")
                token = response.pageToken
                if (token != null && !tokens.add(token)) throw HealthFailure("query_failed", "健康数据分页未前进，请重试")
            } while (token != null)
            records
        }
    }

    private suspend fun <T : Record> optionalRecords(
        client: HealthConnectClient, workout: ExerciseSessionRecord, type: KClass<T>,
        granted: Set<String>, metadata: MutableMap<String, String>,
    ): List<T> {
        val name = type.simpleName ?: "unknown"
        if (HealthPermission.getReadPermission(type) !in granted) {
            metadata["healthConnect.missing.$name"] = "permission_denied"
            return emptyList()
        }
        return try {
            readAll(client, type, workout.startTime, workout.endTime, workout.metadata.dataOrigin).also {
                if (it.isEmpty()) metadata["healthConnect.missing.$name"] = "no_data_from_workout_source"
            }
        } catch (error: CancellationException) { throw error
        } catch (error: HealthFailure) { throw error
        } catch (_: SecurityException) {
            // Re-check exercise access before retaining any partial bundle after revocation.
            requireExercisePermission(client)
            metadata["healthConnect.missing.$name"] = "permission_revoked"
            emptyList()
        } catch (_: Exception) {
            metadata["healthConnect.missing.$name"] = "query_failed"
            emptyList()
        }
    }

    private fun pauses(workout: ExerciseSessionRecord): List<LongArray> = workout.segments
        .filter { it.segmentType == ExerciseSegment.EXERCISE_SEGMENT_TYPE_PAUSE }
        .map { longArrayOf(it.startTime.toEpochMilli(), it.endTime.toEpochMilli()) }

    private fun summary(workout: ExerciseSessionRecord, energy: Double?, distance: Double?): Map<String, Any?> =
        HealthWorkoutMapper.summary(workout.metadata.id, workout.startTime.toEpochMilli(), workout.endTime.toEpochMilli(),
            workout.exerciseType, workout.metadata.dataOrigin.packageName, pauses(workout), energy, distance)

    private suspend fun bundle(client: HealthConnectClient, workout: ExerciseSessionRecord, granted: Set<String>): Map<String, Any?> {
        val start = workout.startTime.toEpochMilli()
        val end = workout.endTime.toEpochMilli()
        val metadata = linkedMapOf(
            "dataPlatform" to "HealthConnect",
            "healthConnect.recordId" to workout.metadata.id,
            "healthConnect.exerciseType" to workout.exerciseType.toString(),
            "healthConnect.sourcePackage" to workout.metadata.dataOrigin.packageName,
            "healthConnect.sampleAssociation" to "same_source_and_session_time_range",
            "healthConnect.unmappedFields" to "basalEnergyBurned,runningStrideLength,runningVerticalOscillation,runningGroundContactTime,swimmingStrokeCount",
            "healthConnect.intervalSampleTimestamp" to "interval_start",
        )
        if (HealthWorkoutMapper.isIndoor(workout.exerciseType)) metadata["HKIndoorWorkout"] = "true"
        workout.title?.let { metadata["healthConnect.title"] = it }
        workout.startZoneOffset?.let { metadata["healthConnect.startZoneOffset"] = it.toString() }
        val series = linkedMapOf<String, List<Map<String, Any>>>()
        var pointCount = 0
        fun add(key: String, samples: List<Map<String, Any>>) {
            pointCount += samples.size
            if (pointCount > HealthWorkoutMapper.MAX_SAMPLES) throw HealthFailure("healthkit_data_too_large", "训练样本过多，请单独导出")
            if (samples.isNotEmpty()) series[key] = samples.sortedBy { (it["dateMs"] as Number).toLong() }
        }
        fun inRange(time: Instant) = HealthWorkoutMapper.inHalfOpenRange(time.toEpochMilli(), start, end)
        fun contained(first: Instant, last: Instant) = HealthWorkoutMapper.containedInterval(first.toEpochMilli(), last.toEpochMilli(), start, end)

        val heartRate = optionalRecords(client, workout, HeartRateRecord::class, granted, metadata)
        add("HKQuantityTypeIdentifierHeartRate", heartRate.flatMap { record -> record.samples.filter { inRange(it.time) }
            .map { HealthWorkoutMapper.quantity(it.time.toEpochMilli(), it.beatsPerMinute.toDouble(), "count/min") } })
        val speed = optionalRecords(client, workout, SpeedRecord::class, granted, metadata)
        add(HealthWorkoutMapper.speedKey(workout.exerciseType), speed.flatMap { record -> record.samples.filter { inRange(it.time) }
            .map { HealthWorkoutMapper.quantity(it.time.toEpochMilli(), it.speed.inMetersPerSecond, "m/s") } })
        val power = optionalRecords(client, workout, PowerRecord::class, granted, metadata)
        add("HKQuantityTypeIdentifierRunningPower", power.flatMap { record -> record.samples.filter { inRange(it.time) }
            .map { HealthWorkoutMapper.quantity(it.time.toEpochMilli(), it.power.inWatts, "W") } })
        val cadence = optionalRecords(client, workout, CyclingPedalingCadenceRecord::class, granted, metadata)
        add("HKQuantityTypeIdentifierCyclingCadence", cadence.flatMap { record -> record.samples.filter { inRange(it.time) }
            .map { HealthWorkoutMapper.quantity(it.time.toEpochMilli(), it.revolutionsPerMinute, "count/min") } })

        val distances = optionalRecords(client, workout, DistanceRecord::class, granted, metadata)
        val containedDistances = distances.filter { contained(it.startTime, it.endTime) }
        if (containedDistances.size != distances.size) metadata["healthConnect.missing.distancePartialIntervals"] = "not_prorated"
        add(HealthWorkoutMapper.distanceKey(workout.exerciseType), containedDistances.map {
            HealthWorkoutMapper.quantity(it.startTime.toEpochMilli(), it.distance.inMeters, "m")
        })
        val energy = optionalRecords(client, workout, ActiveCaloriesBurnedRecord::class, granted, metadata)
        val containedEnergy = energy.filter { contained(it.startTime, it.endTime) }
        if (containedEnergy.size != energy.size) metadata["healthConnect.missing.energyPartialIntervals"] = "not_prorated"
        add("HKQuantityTypeIdentifierActiveEnergyBurned", containedEnergy.map {
            HealthWorkoutMapper.quantity(it.startTime.toEpochMilli(), it.energy.inKilocalories, "kcal")
        })
        val steps = optionalRecords(client, workout, StepsRecord::class, granted, metadata)
        add("HKQuantityTypeIdentifierStepCount", steps.filter { contained(it.startTime, it.endTime) }.map {
            HealthWorkoutMapper.quantity(it.startTime.toEpochMilli(), it.count.toDouble(), "count")
        })
        val route = readRoute(workout, metadata)
        pointCount += route.size
        if (pointCount > HealthWorkoutMapper.MAX_SAMPLES) throw HealthFailure("healthkit_data_too_large", "训练样本过多，请单独导出")
        requireExercisePermission(client)
        return summary(workout,
            containedEnergy.takeIf { it.isNotEmpty() }?.sumOf { it.energy.inKilocalories },
            containedDistances.takeIf { it.isNotEmpty() }?.sumOf { it.distance.inMeters },
        ) + mapOf(
            "metadata" to metadata,
            "events" to HealthWorkoutMapper.events(start, end, pauses(workout), workout.laps.map { it.endTime.toEpochMilli() }),
            "series" to series,
            "route" to route,
        )
    }

    private suspend fun readRoute(workout: ExerciseSessionRecord, metadata: MutableMap<String, String>): List<Map<String, Any>> {
        val route = when (val route = workout.exerciseRouteResult) {
            is ExerciseRouteResult.Data -> { metadata["healthConnect.routeStatus"] = "available"; route.exerciseRoute }
            is ExerciseRouteResult.NoData -> { metadata["healthConnect.routeStatus"] = "no_data"; null }
            is ExerciseRouteResult.ConsentRequired -> {
                if (!foreground || activity.isFinishing || activity.isDestroyed) {
                    metadata["healthConnect.routeStatus"] = "foreground_consent_required"
                    null
                } else if (routeResult != null || permissionsResult != null) {
                    throw HealthFailure("authorization_in_progress", "已有健康路线授权正在进行，请重试")
                } else {
                    val deferred = CompletableDeferred<ExerciseRoute?>()
                    routeResult = deferred
                    try {
                        activity.startActivityForResult(routeContract.createIntent(activity, workout.metadata.id), ROUTE_REQUEST)
                        deferred.await().also { metadata["healthConnect.routeStatus"] = if (it == null) "consent_denied_or_no_data" else "available" }
                    } finally { if (routeResult === deferred) routeResult = null }
                }
            }
            else -> { metadata["healthConnect.routeStatus"] = "unsupported_route_state"; null }
        }
        val points = route?.route ?: return emptyList()
        if (points.size > HealthWorkoutMapper.MAX_SAMPLES) throw HealthFailure("healthkit_data_too_large", "训练路线过长，请单独导出")
        return points.filter { it.time >= workout.startTime && it.time < workout.endTime }.sortedBy { it.time }.map {
            HealthWorkoutMapper.route(it.time.toEpochMilli(), it.latitude, it.longitude, it.altitude?.inMeters)
        }
    }

    private fun integer(call: MethodCall, name: String): Long = when (val value = call.argument<Any>(name)) {
        is Int -> value.toLong()
        is Long -> value
        else -> throw IllegalArgumentException()
    }

    private class HealthFailure(val code: String, override val message: String) : Exception(message)

    companion object {
        private const val PERMISSION_REQUEST = 901
        private const val ROUTE_REQUEST = 902
        private const val FIRST_GRANT = "first_read_grant_ms"
        private val RECORD_TYPES: List<KClass<out Record>> = listOf(
            ExerciseSessionRecord::class, HeartRateRecord::class, SpeedRecord::class, PowerRecord::class,
            CyclingPedalingCadenceRecord::class, DistanceRecord::class, ActiveCaloriesBurnedRecord::class, StepsRecord::class,
        )
    }
}
