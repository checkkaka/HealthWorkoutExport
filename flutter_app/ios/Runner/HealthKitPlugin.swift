import Flutter
import Foundation
import HealthKit
import UIKit

/// Flutter 的 HealthKit 只读边界；返回训练摘要与完整原始明细，FIT 编码留在 Rust 层。
final class HealthKitPlugin: NSObject, FlutterPlugin {
  private static let channelName = "health_workout_export/healthkit"
  static let detailConcurrencyLimit = 3
  private let store = HKHealthStore()

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
    .swimmingStrokeCount,
  ]

  private static var readTypes: Set<HKObjectType> {
    var types: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
    for identifier in quantityIdentifiers {
      if let type = HKObjectType.quantityType(forIdentifier: identifier) {
        types.insert(type)
      }
    }
    return types
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = HealthKitPlugin()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      plugin.handle(call, result: result)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      finish(result, with: HKHealthStore.isHealthDataAvailable())
    case "requestAuthorization":
      requestAuthorization(result: result)
    case "openSettings":
      openSettings(result: result)
    case "currentTimeZoneIdentifier":
      finish(result, with: TimeZone.current.identifier)
    case "listWorkouts":
      listWorkouts(arguments: call.arguments, result: result)
    case "fetchWorkoutBundles":
      fetchWorkoutBundles(arguments: call.arguments, result: result)
    default:
      finish(result, with: FlutterMethodNotImplemented)
    }
  }

  private func requestAuthorization(result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      finish(result, errorCode: "healthkit_unavailable", message: "此设备不支持 HealthKit")
      return
    }

    store.requestAuthorization(toShare: [], read: Self.readTypes) { [weak self] success, error in
      guard let self else { return }
      if let error {
        self.finish(result, errorCode: "authorization_failed", message: error.localizedDescription)
      } else if success {
        self.finish(result, with: nil)
      } else {
        self.finish(result, errorCode: "authorization_failed", message: "未获得健康数据读取权限")
      }
    }
  }

  private func openSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      finish(result, errorCode: "settings_unavailable", message: "无法打开系统设置")
      return
    }
    UIApplication.shared.open(url) { [weak self] opened in
      guard let self else { return }
      if opened {
        self.finish(result, with: nil)
      } else {
        self.finish(result, errorCode: "settings_unavailable", message: "无法打开系统设置")
      }
    }
  }

  private func listWorkouts(arguments: Any?, result: @escaping FlutterResult) {
    let interval: (start: Date, end: Date)
    do {
      interval = try Self.parseInterval(arguments: arguments)
    } catch {
      finish(result, errorCode: "invalid_arguments", message: error.localizedDescription)
      return
    }
    guard HKHealthStore.isHealthDataAvailable() else {
      finish(result, errorCode: "healthkit_unavailable", message: "此设备不支持 HealthKit")
      return
    }

    let predicate = HKQuery.predicateForSamples(
      withStart: interval.start,
      end: interval.end,
      options: .strictStartDate
    )
    let query = HKSampleQuery(
      sampleType: .workoutType(),
      predicate: predicate,
      limit: HKObjectQueryNoLimit,
      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
    ) { [weak self] _, samples, error in
      guard let self else { return }
      if let error {
        self.finish(result, errorCode: "query_failed", message: error.localizedDescription)
        return
      }
      let summaries = (samples as? [HKWorkout] ?? [])
        .filter { $0.startDate >= interval.start && $0.startDate < interval.end }
        .map(Self.summary(from:))
      self.finish(result, with: summaries)
    }
    store.execute(query)
  }

  /// 一次按 UUID 集合回查训练，再返回各训练的 quantity、路线、事件与 metadata。
  private func fetchWorkoutBundles(arguments: Any?, result: @escaping FlutterResult) {
    let uuids: [UUID]
    do {
      uuids = try Self.parseWorkoutUUIDs(arguments: arguments)
    } catch {
      finish(result, errorCode: "invalid_arguments", message: error.localizedDescription)
      return
    }
    guard HKHealthStore.isHealthDataAvailable() else {
      finish(result, errorCode: "healthkit_unavailable", message: "此设备不支持 HealthKit")
      return
    }

    Task { [weak self] in
      guard let self else { return }
      do {
        let workouts = try await self.fetchWorkouts(uuids: uuids)
        let byUUID = Dictionary(uniqueKeysWithValues: workouts.map { ($0.uuid, $0) })
        let ordered = try uuids.map { uuid in
          guard let workout = byUUID[uuid] else { throw HealthKitPluginError.workoutNotFound }
          return workout
        }

        let payloads = try await Self.boundedConcurrentMap(
          ordered,
          limit: Self.detailConcurrencyLimit
        ) { workout in
          try await self.fetchBundle(for: workout)
        }
        self.finish(result, with: payloads)
      } catch {
        self.finish(result, errorCode: "query_failed", message: error.localizedDescription)
      }
    }
  }

  static func parseInterval(arguments: Any?) throws -> (start: Date, end: Date) {
    guard
      let arguments = arguments as? [String: Any],
      let startMs = milliseconds(arguments["startMs"]),
      let endMs = milliseconds(arguments["endMs"]),
      startMs.isFinite,
      endMs.isFinite,
      startMs < endMs
    else {
      throw HealthKitPluginError.invalidInterval
    }
    return (
      Date(timeIntervalSince1970: startMs / 1_000),
      Date(timeIntervalSince1970: endMs / 1_000)
    )
  }

  static func parseWorkoutUUIDs(arguments: Any?) throws -> [UUID] {
    guard
      let arguments = arguments as? [String: Any],
      let strings = arguments["uuids"] as? [String],
      !strings.isEmpty
    else {
      throw HealthKitPluginError.invalidUUIDs
    }

    var seen = Set<UUID>()
    return try strings.map { value in
      guard let uuid = UUID(uuidString: value), seen.insert(uuid).inserted else {
        throw HealthKitPluginError.invalidUUIDs
      }
      return uuid
    }
  }

  static func summary(from workout: HKWorkout) -> [String: Any] {
    [
      "uuid": workout.uuid.uuidString,
      "startMs": millisecondsSinceEpoch(workout.startDate),
      "endMs": millisecondsSinceEpoch(workout.endDate),
      "durationSeconds": workout.duration,
      "activityType": Int(workout.workoutActivityType.rawValue),
      "activityName": workout.workoutActivityType.localizedChineseName,
      "sourceName": workout.sourceRevision.source.name,
      "sourceBundleId": workout.sourceRevision.source.bundleIdentifier,
      "totalEnergyKcal": workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? NSNull(),
      "totalDistanceMeters": workout.totalDistance?.doubleValue(for: .meter()) ?? NSNull(),
    ]
  }

  static func millisecondsSinceEpoch(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1_000)
  }

  static func quantityPayload(date: Date, value: Double, unit: String) -> [String: Any] {
    ["dateMs": millisecondsSinceEpoch(date), "value": value, "unit": unit]
  }

  static func eventPayload(type: HKWorkoutEventType, date: Date) -> [String: Any] {
    ["type": eventTypeName(type), "dateMs": millisecondsSinceEpoch(date)]
  }

  static func routePayload(
    latitude: Double,
    longitude: Double,
    altitude: Double?,
    timestamp: Date?,
    speed: Double?
  ) -> [String: Any] {
    var payload: [String: Any] = ["latitude": latitude, "longitude": longitude]
    if let altitude { payload["altitudeMeters"] = altitude }
    if let timestamp { payload["timestampMs"] = millisecondsSinceEpoch(timestamp) }
    if let speed { payload["speedMetersPerSecond"] = speed }
    return payload
  }

  static func bundlePayload(
    summary: [String: Any],
    metadata: [String: String],
    events: [[String: Any]],
    series: [String: [[String: Any]]],
    route: [[String: Any]]
  ) -> [String: Any] {
    var payload = summary
    payload["metadata"] = metadata
    payload["events"] = events
    payload["series"] = series
    payload["route"] = route
    return payload
  }

  /// 仅维持 limit 个在途任务；完成结果按输入索引回填，任一错误直接终止整批。
  static func boundedConcurrentMap<Input, Output>(
    _ inputs: [Input],
    limit: Int,
    transform: @escaping (Input) async throws -> Output
  ) async throws -> [Output] {
    precondition(limit > 0)
    guard !inputs.isEmpty else { return [] }

    return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
      let initialCount = min(limit, inputs.count)
      for index in 0..<initialCount {
        group.addTask { (index, try await transform(inputs[index])) }
      }

      var nextIndex = initialCount
      var results = [Output?](repeating: nil, count: inputs.count)
      while let (index, output) = try await group.next() {
        results[index] = output
        if nextIndex < inputs.count {
          let index = nextIndex
          nextIndex += 1
          group.addTask { (index, try await transform(inputs[index])) }
        }
      }
      return results.map { $0! }
    }
  }

  static func preferredUnit(for identifier: HKQuantityTypeIdentifier) -> HKUnit {
    switch identifier {
    case .heartRate, .cyclingCadence:
      return HKUnit.count().unitDivided(by: .minute())
    case .activeEnergyBurned, .basalEnergyBurned:
      return .kilocalorie()
    case .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
      .runningStrideLength, .runningVerticalOscillation:
      return .meter()
    case .runningSpeed, .cyclingSpeed:
      return HKUnit.meter().unitDivided(by: .second())
    case .runningPower:
      return .watt()
    case .runningGroundContactTime:
      return .secondUnit(with: .milli)
    case .stepCount, .swimmingStrokeCount:
      return .count()
    default:
      return .count()
    }
  }

  private static func milliseconds(_ value: Any?) -> Double? {
    guard !(value is Bool) else { return nil }
    return (value as? NSNumber)?.doubleValue
  }

  private func fetchWorkouts(uuids: [UUID]) async throws -> [HKWorkout] {
    try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(
        sampleType: .workoutType(),
        predicate: HKQuery.predicateForObjects(with: Set(uuids)),
        limit: HKObjectQueryNoLimit,
        sortDescriptors: nil
      ) { _, samples, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: samples as? [HKWorkout] ?? [])
        }
      }
      store.execute(query)
    }
  }

  private func fetchBundle(for workout: HKWorkout) async throws -> [String: Any] {
    async let series = fetchAllSeries(for: workout)
    async let route = fetchRoute(for: workout)
    return try await Self.bundlePayload(
      summary: Self.summary(from: workout),
      metadata: Self.metadataPayload(from: workout.metadata),
      events: (workout.workoutEvents ?? []).map {
        Self.eventPayload(type: $0.type, date: $0.dateInterval.start)
      },
      series: series,
      route: route
    )
  }

  private func fetchAllSeries(for workout: HKWorkout) async -> [String: [[String: Any]]] {
    var result: [String: [[String: Any]]] = [:]
    for identifier in Self.quantityIdentifiers {
      guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { continue }
      do {
        let samples = try await fetchQuantitySeries(
          type: type,
          identifier: identifier,
          workout: workout
        )
        if !samples.isEmpty { result[identifier.rawValue] = samples }
      } catch {
        // 单个可选类型读取失败不应丢弃其余训练明细，也不记录健康数据。
        continue
      }
    }
    return result
  }

  private func fetchQuantitySeries(
    type: HKQuantityType,
    identifier: HKQuantityTypeIdentifier,
    workout: HKWorkout
  ) async throws -> [[String: Any]] {
    let datePredicate = HKQuery.predicateForSamples(
      withStart: workout.startDate,
      end: workout.endDate,
      options: .strictStartDate
    )
    let associatedPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      datePredicate,
      HKQuery.predicateForObjects(from: workout),
    ])
    let unit = Self.preferredUnit(for: identifier)

    let associated: [[String: Any]]
    do {
      associated = try await withCheckedThrowingContinuation { continuation in
        var collected: [[String: Any]] = []
        var finished = false
        let query = HKQuantitySeriesSampleQuery(quantityType: type, predicate: associatedPredicate)
        {
          _, quantity, interval, _, done, error in
          guard !finished else { return }
          if let error {
            finished = true
            continuation.resume(throwing: error)
            return
          }
          if let quantity, let interval {
            collected.append(
              Self.quantityPayload(
                date: interval.start,
                value: quantity.doubleValue(for: unit),
                unit: unit.unitString
              ))
          }
          if done {
            finished = true
            continuation.resume(returning: collected)
          }
        }
        store.execute(query)
      }
    } catch {
      associated = try await fetchQuantitySamples(
        type: type,
        predicate: associatedPredicate,
        unit: unit
      )
    }
    if !associated.isEmpty { return associated }

    // 第三方可能只写同源时间序列而未关联 workout；限训练时间和来源回退，避免混入其它训练。
    let sourcePredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      datePredicate,
      HKQuery.predicateForObjects(from: workout.sourceRevision.source),
    ])
    return try await fetchQuantitySamples(type: type, predicate: sourcePredicate, unit: unit)
  }

  private func fetchQuantitySamples(
    type: HKQuantityType,
    predicate: NSPredicate,
    unit: HKUnit
  ) async throws -> [[String: Any]] {
    try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(
        sampleType: type,
        predicate: predicate,
        limit: HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
      ) { _, samples, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        continuation.resume(
          returning: (samples as? [HKQuantitySample] ?? []).map {
            Self.quantityPayload(
              date: $0.startDate,
              value: $0.quantity.doubleValue(for: unit),
              unit: unit.unitString
            )
          })
      }
      store.execute(query)
    }
  }

  private func fetchRoute(for workout: HKWorkout) async throws -> [[String: Any]] {
    let routes = try await fetchWorkoutRoutes(for: workout)
    var result: [[String: Any]] = []
    for route in routes {
      result.append(contentsOf: try await fetchLocations(from: route))
    }
    return result
  }

  private func fetchWorkoutRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
    try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(
        sampleType: HKSeriesType.workoutRoute(),
        predicate: HKQuery.predicateForObjects(from: workout),
        limit: HKObjectQueryNoLimit,
        sortDescriptors: nil
      ) { _, samples, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: samples as? [HKWorkoutRoute] ?? [])
        }
      }
      store.execute(query)
    }
  }

  private func fetchLocations(from route: HKWorkoutRoute) async throws -> [[String: Any]] {
    try await withCheckedThrowingContinuation { continuation in
      var collected: [[String: Any]] = []
      var finished = false
      let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
        guard !finished else { return }
        if let error {
          finished = true
          continuation.resume(throwing: error)
          return
        }
        collected.append(
          contentsOf: (locations ?? []).map {
            Self.routePayload(
              latitude: $0.coordinate.latitude,
              longitude: $0.coordinate.longitude,
              altitude: $0.altitude,
              timestamp: $0.timestamp,
              speed: $0.speed >= 0 ? $0.speed : nil
            )
          })
        if done {
          finished = true
          continuation.resume(returning: collected)
        }
      }
      store.execute(query)
    }
  }

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

  static func metadataPayload(from metadata: [String: Any]?) -> [String: String] {
    guard let metadata else { return [:] }
    return metadata.mapValues { String(describing: $0) }
  }

  private func finish(_ result: @escaping FlutterResult, with value: Any?) {
    Self.finishOnMain(result, value)
  }

  private func finish(_ result: @escaping FlutterResult, errorCode: String, message: String) {
    Self.finishOnMain(result, FlutterError(code: errorCode, message: message, details: nil))
  }

  private static func finishOnMain(_ result: @escaping FlutterResult, _ value: Any?) {
    if Thread.isMainThread {
      result(value)
    } else {
      DispatchQueue.main.async { result(value) }
    }
  }
}

private enum HealthKitPluginError: LocalizedError {
  case invalidInterval
  case invalidUUIDs
  case workoutNotFound

  var errorDescription: String? {
    switch self {
    case .invalidInterval:
      return "startMs/endMs 必须是有限数字，且 startMs 小于 endMs"
    case .invalidUUIDs:
      return "uuids 必须是非空、无重复的 UUID 字符串数组"
    case .workoutNotFound:
      return "未找到部分训练"
    }
  }
}

extension HKWorkoutActivityType {
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
}
