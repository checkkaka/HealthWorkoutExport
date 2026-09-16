import Foundation
import HealthKit
import CoreLocation

enum HealthKitServiceError: LocalizedError {
    case unavailable
    case unauthorized
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "此设备不支持 HealthKit"
        case .unauthorized: return "未获得健康数据权限"
        case .queryFailed(let message): return message
        }
    }
}

/// HealthKit 读写封装：授权、列表查询、单次训练明细（路线 + 时间序列）。
final class HealthKitService: @unchecked Sendable {
    /// 导出明细时的最大并发训练数，避免压垮 HealthKit / 内存。
    static let detailConcurrencyLimit = 3

    private let store = HKHealthStore()
    /// 列表查询后缓存 HKWorkout，导出时复用，避免逐条按 UUID 重查（N+1）。
    private let workoutCacheLock = NSLock()
    private var workoutCache: [UUID: HKWorkout] = [:]

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// 需要读取的类型集合（训练 + 常见运动相关 quantity + 路线）。
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]
        for id in Self.quantityIdentifiers {
            if let t = HKObjectType.quantityType(forIdentifier: id) {
                types.insert(t)
            }
        }
        return types
    }

    /// 业务上关心的 quantity 标识列表。
    private static let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
        .heartRate,
        .activeEnergyBurned,
        .basalEnergyBurned,
        .distanceWalkingRunning,
        .distanceCycling,
        .distanceSwimming,
        .runningSpeed,
        .cyclingSpeed,
        .stepCount,
        .runningPower,
        .runningStrideLength,
        .runningVerticalOscillation,
        .runningGroundContactTime,
        .cyclingCadence,
        .swimmingStrokeCount
    ]

    private var writeTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]
        for id in [
            HKQuantityTypeIdentifier.heartRate,
            .activeEnergyBurned,
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming,
            .runningSpeed,
            .cyclingSpeed,
            .cyclingCadence,
            .runningPower,
            .cyclingPower
        ] {
            if let t = HKObjectType.quantityType(forIdentifier: id) {
                types.insert(t)
            }
        }
        return types
    }

    /// 请求健康数据授权。默认只读；写入训练时再要 share 类型，避免改到日常健康页授权。
    func requestAuthorization(writeWorkouts: Bool = false) async throws {
        guard isHealthDataAvailable else { throw HealthKitServiceError.unavailable }
        let share: Set<HKSampleType> = writeWorkouts ? writeTypes : []
        try await store.requestAuthorization(toShare: share, read: readTypes)
    }

    /// 时间窗内已有训练，供写入前做接近确认。
    func nearbyWorkouts(from start: Date, to end: Date) async throws -> [HealthNearbyWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: HealthKitServiceError.queryFailed(error.localizedDescription))
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
        return workouts.map { workout in
            HealthNearbyWorkout(
                uuid: workout.uuid,
                startDate: workout.startDate,
                endDate: workout.endDate,
                duration: workout.duration,
                distanceMeters: workout.totalDistance?.doubleValue(for: .meter()),
                sourceName: workout.sourceRevision.source.name,
                syncIdentifier: workout.metadata?[HKMetadataKeySyncIdentifier] as? String
            )
        }
    }

    /// 把 FIT 草稿写成一条本 App 来源的健康训练（摘要 + 序列 + 路线）。
    func save(_ draft: HealthWorkoutDraft) async throws -> UUID {
        guard isHealthDataAvailable else { throw HealthKitServiceError.unavailable }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = draft.activityType
        configuration.locationType = draft.locations.count >= 2 ? .outdoor : .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        var start = draft.start
        var end = max(draft.end, draft.start.addingTimeInterval(1))
        let sampleDates = draft.heartRate.map(\.date)
            + draft.cadence.map(\.date)
            + draft.power.map(\.date)
            + draft.speed.map(\.date)
            + draft.locations.compactMap(\.timestamp)
            + draft.events.map(\.date)
        if let earliest = sampleDates.min() { start = min(start, earliest) }
        if let latest = sampleDates.max() { end = max(end, latest.addingTimeInterval(1)) }

        try await builder.beginCollection(at: start)
        try await builder.addMetadata([
            HKMetadataKeySyncIdentifier: draft.fingerprint,
            HKMetadataKeySyncVersion: NSNumber(value: 1)
        ])

        var samples: [HKSample] = []
        samples.append(contentsOf: quantitySamples(
            identifier: .heartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            points: draft.heartRate
        ))
        if draft.activityType == .cycling {
            samples.append(contentsOf: quantitySamples(
                identifier: .cyclingCadence,
                unit: HKUnit.count().unitDivided(by: .second()),
                points: draft.cadence,
                transform: { $0 / 60 }
            ))
            samples.append(contentsOf: quantitySamples(
                identifier: .cyclingPower,
                unit: .watt(),
                points: draft.power
            ))
            samples.append(contentsOf: quantitySamples(
                identifier: .cyclingSpeed,
                unit: HKUnit.meter().unitDivided(by: .second()),
                points: draft.speed
            ))
        } else {
            samples.append(contentsOf: quantitySamples(
                identifier: .runningPower,
                unit: .watt(),
                points: draft.power
            ))
            samples.append(contentsOf: quantitySamples(
                identifier: .runningSpeed,
                unit: HKUnit.meter().unitDivided(by: .second()),
                points: draft.speed
            ))
        }
        if let meters = draft.distanceMeters, meters > 0,
           let distanceType = distanceIdentifier(for: draft.activityType),
           let quantityType = HKQuantityType.quantityType(forIdentifier: distanceType) {
            samples.append(HKQuantitySample(
                type: quantityType,
                quantity: HKQuantity(unit: .meter(), doubleValue: meters),
                start: start,
                end: end
            ))
        }
        if let kcal = draft.energyKilocalories, kcal > 0,
           let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            samples.append(HKQuantitySample(
                type: energyType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                start: start,
                end: end
            ))
        }
        if !samples.isEmpty {
            try await builder.addSamples(samples)
        }
        let events: [HKWorkoutEvent] = draft.events.compactMap { event in
            let type: HKWorkoutEventType
            switch event.type {
            case "pause", "motionPaused": type = .pause
            case "resume", "motionResumed": type = .resume
            default: return nil
            }
            return HKWorkoutEvent(
                type: type,
                dateInterval: DateInterval(start: event.date, duration: 1),
                metadata: nil
            )
        }
        if !events.isEmpty {
            try await builder.addWorkoutEvents(events)
        }
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else {
            throw HealthKitServiceError.queryFailed("写入健康失败")
        }
        let locations = draft.locations.compactMap { point -> CLLocation? in
            let timestamp = point.timestamp ?? start
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                altitude: point.altitude ?? 0,
                horizontalAccuracy: 5,
                verticalAccuracy: point.altitude == nil ? -1 : 3,
                timestamp: timestamp
            )
        }
        if locations.count >= 2 {
            do {
                let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
                for chunk in stride(from: 0, to: locations.count, by: 100) {
                    let endIndex = min(chunk + 100, locations.count)
                    try await routeBuilder.insertRouteData(Array(locations[chunk..<endIndex]))
                }
                _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
            } catch {
                // ponytail: 路线失败时训练已落盘（带 sync id）。再抛会让上层记失败，下次 alreadyImported 跳过，GPS 再也补不上。
            }
        }
        return workout.uuid
    }

    private func distanceIdentifier(for type: HKWorkoutActivityType) -> HKQuantityTypeIdentifier? {
        switch type {
        case .cycling: return .distanceCycling
        case .swimming: return .distanceSwimming
        default: return .distanceWalkingRunning
        }
    }

    private func quantitySamples(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        points: [TimedSample],
        transform: (Double) -> Double = { $0 }
    ) -> [HKQuantitySample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [] }
        return points.map { point in
            HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: transform(point.value)),
                start: point.date,
                end: point.date
            )
        }
    }

    /// 按时间范围查询训练摘要列表（不含样本明细）。
    func fetchWorkoutSummaries(from start: Date, to end: Date) async throws -> [WorkoutSummary] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: HealthKitServiceError.queryFailed(error.localizedDescription))
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }

        // 缓存本批 HKWorkout：导出明细时直接复用，省掉每条一次的 UUID 查询。
        workoutCacheLock.lock()
        workoutCache = Dictionary(uniqueKeysWithValues: workouts.map { ($0.uuid, $0) })
        workoutCacheLock.unlock()

        return workouts.map(Self.makeSummary(from:))
    }

    /// 拉取单次训练完整包：摘要 + 事件 + 各 quantity 序列 + GPS 路线。
    func fetchWorkoutBundle(for summary: WorkoutSummary) async throws -> WorkoutBundle {
        // 优先用列表查询时缓存的对象，缓存未命中（如 App 长驻后缓存被刷新）再按 UUID 查。
        workoutCacheLock.lock()
        let cached = workoutCache[summary.uuid]
        workoutCacheLock.unlock()

        let resolved: HKWorkout?
        if let cached {
            resolved = cached
        } else {
            resolved = try await fetchWorkout(uuid: summary.uuid)
        }
        guard let workout = resolved else {
            throw HealthKitServiceError.queryFailed("找不到训练 \(summary.uuid)")
        }

        async let seriesTask = fetchAllSeries(for: workout)
        async let routeTask = fetchRoute(for: workout)

        let series = await seriesTask
        let route = try await routeTask
        let events = (workout.workoutEvents ?? []).map { event in
            WorkoutEventDTO(type: Self.eventTypeName(event.type), date: event.date)
        }
        let metadata = Self.stringMetadata(from: workout.metadata)

        return WorkoutBundle(
            summary: Self.makeSummary(from: workout),
            metadata: metadata,
            events: events,
            series: series,
            route: route
        )
    }

    // MARK: - Private

    private func fetchWorkout(uuid: UUID) async throws -> HKWorkout? {
        let predicate = HKQuery.predicateForObject(with: uuid)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: HealthKitServiceError.queryFailed(error.localizedDescription))
                    return
                }
                continuation.resume(returning: samples?.first as? HKWorkout)
            }
            store.execute(query)
        }
    }

    private func fetchAllSeries(for workout: HKWorkout) async -> [String: [TimedSample]] {
        var result: [String: [TimedSample]] = [:]
        // 用户要求尽量完整：全量类型逐一查询，空结果自然跳过（空查询开销小于漏数据的代价）。
        for identifier in Self.quantityIdentifiers {
            guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            // 单类型失败只跳过该序列，不中断整次导出。
            do {
                let samples = try await fetchQuantitySeries(type: quantityType, workout: workout)
                if !samples.isEmpty {
                    result[identifier.rawValue] = samples
                }
            } catch {
                // ponytail: 自用工具，失败类型静默跳过；需要排查时在此打日志即可。
                continue
            }
        }
        return result
    }

    /// 优先系列查询拿高分辨率点，失败则回退普通 SampleQuery。
    private func fetchQuantitySeries(type: HKQuantityType, workout: HKWorkout) async throws -> [TimedSample] {
        let datePredicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: .strictStartDate
        )
        // 优先取明确关联到 workout 的样本，避免重叠训练互相污染。
        let associatedPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            datePredicate,
            HKQuery.predicateForObjects(from: workout)
        ])
        let unit = preferredUnit(for: type)

        let associated: [TimedSample]
        do {
            associated = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[TimedSample], Error>) in
                var collected: [TimedSample] = []
                var finished = false
                let query = HKQuantitySeriesSampleQuery(quantityType: type, predicate: associatedPredicate) {
                    _, quantity, dateInterval, _, done, error in
                    if finished { return }
                    if let error {
                        finished = true
                        continuation.resume(throwing: error)
                        return
                    }
                    if let quantity, let dateInterval {
                        collected.append(
                            TimedSample(
                                date: dateInterval.start,
                                value: quantity.doubleValue(for: unit),
                                unit: unit.unitString
                            )
                        )
                    }
                    if done {
                        finished = true
                        continuation.resume(returning: collected)
                    }
                }
                store.execute(query)
            }
        } catch {
            associated = try await fetchQuantitySamplesFallback(
                type: type,
                predicate: associatedPredicate,
                unit: unit
            )
        }
        if !associated.isEmpty { return associated }

        // 部分第三方训练只写入同源时间序列，没有把样本显式加入 workout。
        // 关联查询为空时限定到训练写入源回退，兼顾完整性并避免混入其它来源。
        let sourceScopedPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            datePredicate,
            HKQuery.predicateForObjects(from: workout.sourceRevision.source)
        ])
        return try await fetchQuantitySamplesFallback(
            type: type,
            predicate: sourceScopedPredicate,
            unit: unit
        )
    }

    private func fetchQuantitySamplesFallback(
        type: HKQuantityType,
        predicate: NSPredicate,
        unit: HKUnit
    ) async throws -> [TimedSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: HealthKitServiceError.queryFailed(error.localizedDescription))
                    return
                }
                let mapped = (samples as? [HKQuantitySample] ?? []).map {
                    TimedSample(date: $0.startDate, value: $0.quantity.doubleValue(for: unit), unit: unit.unitString)
                }
                continuation.resume(returning: mapped)
            }
            store.execute(query)
        }
    }

    private func fetchRoute(for workout: HKWorkout) async throws -> [RoutePoint] {
        let routes = try await fetchWorkoutRoutes(for: workout)
        guard !routes.isEmpty else { return [] }

        var allPoints: [RoutePoint] = []
        for route in routes {
            let points = try await fetchLocations(from: route)
            allPoints.append(contentsOf: points)
        }
        return allPoints
    }

    private func fetchWorkoutRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        let predicate = HKQuery.predicateForObjects(from: workout)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: HealthKitServiceError.queryFailed(error.localizedDescription))
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }
    }

    private func fetchLocations(from route: HKWorkoutRoute) async throws -> [RoutePoint] {
        try await withCheckedThrowingContinuation { continuation in
            var collected: [RoutePoint] = []
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    continuation.resume(throwing: HealthKitServiceError.queryFailed(error.localizedDescription))
                    return
                }
                if let locations {
                    for location in locations {
                        collected.append(
                            RoutePoint(
                                latitude: location.coordinate.latitude,
                                longitude: location.coordinate.longitude,
                                altitude: location.altitude,
                                timestamp: location.timestamp,
                                speed: location.speed >= 0 ? location.speed : nil
                            )
                        )
                    }
                }
                if done {
                    continuation.resume(returning: collected)
                }
            }
            store.execute(query)
        }
    }

    private func preferredUnit(for type: HKQuantityType) -> HKUnit {
        switch type.identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:
            return .kilocalorie()
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
             HKQuantityTypeIdentifier.distanceCycling.rawValue,
             HKQuantityTypeIdentifier.distanceSwimming.rawValue,
             HKQuantityTypeIdentifier.runningStrideLength.rawValue,
             HKQuantityTypeIdentifier.runningVerticalOscillation.rawValue:
            return .meter()
        case HKQuantityTypeIdentifier.runningSpeed.rawValue,
             HKQuantityTypeIdentifier.cyclingSpeed.rawValue:
            return HKUnit.meter().unitDivided(by: .second())
        case HKQuantityTypeIdentifier.runningPower.rawValue:
            return .watt()
        case HKQuantityTypeIdentifier.runningGroundContactTime.rawValue:
            return .secondUnit(with: .milli)
        case HKQuantityTypeIdentifier.stepCount.rawValue,
             HKQuantityTypeIdentifier.swimmingStrokeCount.rawValue:
            return .count()
        case HKQuantityTypeIdentifier.cyclingCadence.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        default:
            return .count()
        }
    }

    private static func makeSummary(from workout: HKWorkout) -> WorkoutSummary {
        let distance = workout.totalDistance?.doubleValue(for: .meter())
        let energy = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
        return WorkoutSummary(
            id: workout.uuid,
            uuid: workout.uuid,
            activityType: workout.workoutActivityType,
            activityName: workout.workoutActivityType.localizedChineseName,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            totalDistanceMeters: distance,
            totalEnergyKilocalories: energy,
            sourceName: workout.sourceRevision.source.name
        )
    }

    /// HKWorkoutEventType 是 C 枚举，String(describing:) 反射不出 case 名，须显式映射稳定字符串。
    private static func eventTypeName(_ type: HKWorkoutEventType) -> String {
        switch type {
        case .pause: return "pause"
        case .resume: return "resume"
        case .lap: return "lap"
        case .marker: return "marker"
        case .motionPaused: return "motionPaused"
        case .motionResumed: return "motionResumed"
        case .segment: return "segment"
        case .pauseOrResumeRequest: return "pauseOrResumeRequest"
        @unknown default: return "unknown(\(type.rawValue))"
        }
    }

    private static func stringMetadata(from metadata: [String: Any]?) -> [String: String] {
        guard let metadata else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in metadata {
            result[key] = String(describing: value)
        }
        return result
    }
}

extension HKWorkoutActivityType {
    /// 训练类型中文名（贴近健康 App 展示）。
    var localizedChineseName: String {
        switch self {
        case .running: return "跑步"
        case .cycling: return "骑车"
        case .walking: return "步行"
        case .hiking: return "徒步"
        case .swimming: return "游泳"
        case .traditionalStrengthTraining: return "力量训练"
        case .functionalStrengthTraining: return "功能性力量"
        case .highIntensityIntervalTraining: return "高强度间歇"
        case .yoga: return "瑜伽"
        case .dance: return "舞蹈"
        case .elliptical: return "椭圆机"
        case .rowing: return "划船"
        case .stairClimbing: return "爬楼梯"
        case .cooldown: return "整理放松"
        case .coreTraining: return "核心训练"
        case .flexibility: return "柔韧训练"
        case .martialArts: return "武术"
        case .pilates: return "普拉提"
        case .soccer: return "足球"
        case .basketball: return "篮球"
        case .tennis: return "网球"
        case .badminton: return "羽毛球"
        case .tableTennis: return "乒乓球"
        case .golf: return "高尔夫"
        case .downhillSkiing: return "滑雪"
        case .snowboarding: return "单板滑雪"
        case .skatingSports: return "滑冰"
        case .paddleSports: return "桨类运动"
        case .climbing: return "攀岩"
        case .jumpRope: return "跳绳"
        case .mixedCardio: return "混合有氧"
        case .other: return "其他"
        default: return "训练"
        }
    }

    /// 列表用 SF Symbol。
    var systemImageName: String {
        switch self {
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        case .walking, .hiking: return "figure.walk"
        case .swimming: return "figure.pool.swim"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "dumbbell.fill"
        case .yoga, .pilates, .flexibility: return "figure.yoga"
        case .highIntensityIntervalTraining: return "flame.fill"
        case .elliptical: return "figure.elliptical"
        case .rowing: return "figure.rower"
        default: return "figure.mixed.cardio"
        }
    }
}
