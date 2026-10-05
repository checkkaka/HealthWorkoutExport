import Foundation
#if os(iOS)
  import Flutter
  import UIKit
#else
  import AppKit
  import FlutterMacOS
#endif
import HealthKit
import CoreLocation

/// Flutter 的 HealthKit 只读边界；返回训练摘要与完整原始明细，FIT 编码留在 Rust 层。
final class HealthKitPlugin: NSObject, FlutterPlugin {
  private static let channelName = "health_workout_export/healthkit"
  static let detailConcurrencyLimit = 3
  private let store = HKHealthStore()
  private var isWritingWorkout = false

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
    .cyclingPower,
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
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      plugin.handle(call, result: result)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "canWriteWorkouts":
      finish(result, with: HKHealthStore.isHealthDataAvailable())
    case "requestWriteAuthorization":
      requestWriteAuthorization(result: result)
    case "findNearbyWorkouts":
      findNearbyWorkouts(arguments: call.arguments, result: result)
    case "writeWorkout":
      DispatchQueue.main.async { self.writeWorkout(arguments: call.arguments, result: result) }
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
    #if os(iOS)
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
    #else
      guard
        let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Health")
      else {
        finish(result, errorCode: "settings_unavailable", message: "无法打开系统设置")
        return
      }
      if NSWorkspace.shared.open(url) {
        finish(result, with: nil)
      } else {
        finish(result, errorCode: "settings_unavailable", message: "无法打开系统设置")
      }
    #endif
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
    case .runningPower, .cyclingPower:
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

/// Validated wire draft from Rust. Never decodes a file path or accepts arbitrary HealthKit metadata.
struct HealthWorkoutWriteDraft: Decodable {
  static let maximumBytes = 64 * 1_024 * 1_024
  static let maximumPoints = 1_000_000

  struct Quantity: Decodable {
    let dateMs: Int64
    let value: Double
    let unit: String
    var date: Date { Date(timeIntervalSince1970: Double(dateMs) / 1_000) }
  }
  struct Location: Decodable {
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double?
    let timestampMs: Int64
    var date: Date { Date(timeIntervalSince1970: Double(timestampMs) / 1_000) }
  }
  struct Event: Decodable {
    let type: String
    let dateMs: Int64
    var date: Date { Date(timeIntervalSince1970: Double(dateMs) / 1_000) }
  }
  let fingerprint: String
  let activityType: UInt
  let startMs: Int64
  let endMs: Int64
  let durationSeconds: Double
  let distanceMeters: Double?
  let energyKilocalories: Double?
  let locations: [Location]
  let heartRate: [Quantity]
  let cadence: [Quantity]
  let power: [Quantity]
  let speed: [Quantity]
  let events: [Event]
  var start: Date { Date(timeIntervalSince1970: Double(startMs) / 1_000) }
  var end: Date { Date(timeIntervalSince1970: Double(endMs) / 1_000) }
  private var sampleTimes: [Int64] {
    heartRate.map(\.dateMs) + cadence.map(\.dateMs) + power.map(\.dateMs)
      + speed.map(\.dateMs) + locations.map(\.timestampMs) + events.map(\.dateMs)
  }
  var collectionStartMs: Int64 { min(startMs, sampleTimes.min() ?? startMs) }
  var collectionEndMs: Int64 { max(startMs + 1_000, max(endMs, (sampleTimes.max() ?? (endMs - 1_000)) + 1_000)) }
  private static let supportedTypes: [HKWorkoutActivityType] = [
    .running, .cycling, .walking, .hiking, .swimming, .traditionalStrengthTraining,
    .rowing, .elliptical, .soccer, .basketball, .tennis, .golf, .downhillSkiing,
    .snowboarding, .climbing, .other,
  ]
  var workoutType: HKWorkoutActivityType { Self.supportedTypes.first { $0.rawValue == activityType }! }

  static func parse(_ data: Data) throws -> HealthWorkoutWriteDraft {
    guard !data.isEmpty, data.count <= maximumBytes else { throw HealthWorkoutWriteError.invalidDraft }
    let draft = try JSONDecoder().decode(Self.self, from: data)
    guard draft.fingerprint.utf8.count == 64,
      draft.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      supportedTypes.contains(where: { $0.rawValue == draft.activityType }),
      draft.startMs >= -2_208_988_800_000, draft.endMs <= 7_258_118_400_000,
      draft.startMs <= draft.endMs, draft.endMs - draft.startMs <= 366 * 86_400_000,
      draft.durationSeconds.isFinite, draft.durationSeconds >= 0,
      draft.locations.count + draft.heartRate.count + draft.cadence.count + draft.power.count
        + draft.speed.count + draft.events.count <= maximumPoints
    else { throw HealthWorkoutWriteError.invalidDraft }
    if let distance = draft.distanceMeters, !distance.isFinite || !(0...1_000_000_000).contains(distance) {
      throw HealthWorkoutWriteError.invalidDraft
    }
    if let energy = draft.energyKilocalories, !energy.isFinite || !(0...10_000_000).contains(energy) {
      throw HealthWorkoutWriteError.invalidDraft
    }
    func validateTimes(_ times: [Int64]) throws {
      guard times.allSatisfy({ $0 >= -2_208_988_800_000 && $0 <= 7_258_118_399_000 }),
        zip(times, times.dropFirst()).allSatisfy({ $0.0 <= $0.1 })
      else { throw HealthWorkoutWriteError.invalidDraft }
    }
    for (points, unit, maximum) in [
      (draft.heartRate, "count/min", 1_000.0), (draft.cadence, "rpm", 10_000.0),
      (draft.power, "W", 100_000.0), (draft.speed, "m/s", 1_000.0),
    ] {
      try validateTimes(points.map(\.dateMs))
      guard points.allSatisfy({ $0.unit == unit && $0.value.isFinite && (0...maximum).contains($0.value) })
      else { throw HealthWorkoutWriteError.invalidDraft }
    }
    try validateTimes(draft.locations.map(\.timestampMs))
    guard draft.locations.allSatisfy({ point in
      point.latitude.isFinite && point.longitude.isFinite
        && (-90...90).contains(point.latitude) && (-180...180).contains(point.longitude)
        && (point.altitudeMeters.map { $0.isFinite && (-12_000...100_000).contains($0) } ?? true)
    }) else { throw HealthWorkoutWriteError.invalidDraft }
    try validateTimes(draft.events.map(\.dateMs))
    guard draft.events.allSatisfy({ $0.type == "pause" || $0.type == "resume" }) else {
      throw HealthWorkoutWriteError.invalidDraft
    }
    guard draft.collectionEndMs <= 7_258_118_400_000,
      draft.collectionEndMs - draft.collectionStartMs <= 366 * 86_400_000,
      draft.durationSeconds <= Double(draft.collectionEndMs - draft.collectionStartMs) / 1_000 + 1
    else { throw HealthWorkoutWriteError.invalidDraft }
    return draft
  }
}

private enum HealthWorkoutWriteError: Error {
  case invalidDraft
  case unauthorized
  case unavailableType
  case queryTooLarge
  case failed
  case partial(UUID, String)
}

extension HealthKitPlugin {
  private static var writeTypes: Set<HKSampleType> {
    var types: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
    for identifier in [
      HKQuantityTypeIdentifier.heartRate, .activeEnergyBurned, .distanceWalkingRunning,
      .distanceCycling, .distanceSwimming, .runningSpeed, .cyclingSpeed,
      .cyclingCadence, .runningPower, .cyclingPower,
    ] {
      if let type = HKQuantityType.quantityType(forIdentifier: identifier) { types.insert(type) }
    }
    return types
  }

  private func requestWriteAuthorization(result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      finish(result, errorCode: "healthkit_unavailable", message: "此设备不支持写入健康训练")
      return
    }
    store.requestAuthorization(toShare: Self.writeTypes, read: Self.readTypes) { _, error in
      if error != nil || self.store.authorizationStatus(for: HKObjectType.workoutType()) != .sharingAuthorized {
        self.finish(result, errorCode: "authorization_failed", message: "未获得健康训练写入权限")
      } else { self.finish(result, with: nil) }
    }
  }

  private func findNearbyWorkouts(arguments: Any?, result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      finish(result, errorCode: "healthkit_unavailable", message: "此设备不支持 HealthKit")
      return
    }
    let interval: (start: Date, end: Date)
    do { interval = try Self.parseInterval(arguments: arguments) }
    catch { finish(result, errorCode: "invalid_arguments", message: "训练查重日期区间无效"); return }
    let query = HKSampleQuery(
      sampleType: .workoutType(),
      predicate: HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate),
      limit: 10_001,
      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
    ) { _, samples, error in
      let workouts = (samples as? [HKWorkout]) ?? []
      guard error == nil, workouts.count <= 10_000 else {
        self.finish(result, errorCode: "query_failed", message: "无法读取健康训练查重列表，请缩小日期范围后重试")
        return
      }
      self.finish(result, with: workouts.filter { $0.startDate >= interval.start && $0.startDate < interval.end }.map { workout in
        [
          "uuid": workout.uuid.uuidString,
          "startMs": Self.millisecondsSinceEpoch(workout.startDate),
          "endMs": Self.millisecondsSinceEpoch(workout.endDate),
          "durationSeconds": workout.duration,
          "distanceMeters": workout.totalDistance?.doubleValue(for: .meter()) as Any? ?? NSNull(),
          "sourceName": workout.sourceRevision.source.name,
          "syncIdentifier": workout.metadata?[HKMetadataKeySyncIdentifier] as? String as Any? ?? NSNull(),
        ] as [String: Any]
      })
    }
    store.execute(query)
  }

  private func writeWorkout(arguments: Any?, result: @escaping FlutterResult) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !isWritingWorkout else {
      finish(result, errorCode: "healthkit_write_in_progress", message: "已有训练写入正在进行")
      return
    }
    let draft: HealthWorkoutWriteDraft
    do {
      guard let args = arguments as? [String: Any], let bytes = args["draftJson"] as? FlutterStandardTypedData else {
        throw HealthWorkoutWriteError.invalidDraft
      }
      draft = try HealthWorkoutWriteDraft.parse(bytes.data)
    } catch { finish(result, errorCode: "invalid_arguments", message: "健康训练草稿字段、时间或样本无效"); return }
    guard HKHealthStore.isHealthDataAvailable() else {
      finish(result, errorCode: "healthkit_unavailable", message: "此设备不支持写入健康训练")
      return
    }
    isWritingWorkout = true
    Task {
      let response: Any
      do { response = try await saveValidatedDraft(draft).uuidString }
      catch HealthWorkoutWriteError.unauthorized {
        response = FlutterError(code: "authorization_failed", message: "部分健康数据写入权限未授予，请重新授权", details: nil)
      } catch HealthWorkoutWriteError.partial(let uuid, let fingerprint) {
        response = FlutterError(code: "healthkit_write_partial", message: "训练已写入，但路线保存失败，请检查健康记录后重试路线", details: [
          "uuid": uuid.uuidString, "fingerprint": fingerprint, "routeWritten": false, "workoutWritten": true,
        ])
      } catch {
        response = FlutterError(code: "healthkit_write_failed", message: "健康训练写入未完成，请检查权限后重试", details: nil)
      }
      await MainActor.run { self.isWritingWorkout = false; result(response) }
    }
  }

  private static func distanceWriteIdentifier(_ type: HKWorkoutActivityType) -> HKQuantityTypeIdentifier {
    switch type {
    case .cycling: return .distanceCycling
    case .swimming: return .distanceSwimming
    default: return .distanceWalkingRunning
    }
  }

  private func requireWritePermission(_ type: HKSampleType) throws {
    guard store.authorizationStatus(for: type) == .sharingAuthorized else { throw HealthWorkoutWriteError.unauthorized }
  }

  private func existingWorkout(fingerprint: String) async throws -> HKWorkout? {
    try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(
        sampleType: .workoutType(),
        predicate: HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [fingerprint]),
        limit: 1, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
      ) { _, samples, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: samples?.first as? HKWorkout) }
      }
      store.execute(query)
    }
  }

  private func saveValidatedDraft(_ draft: HealthWorkoutWriteDraft) async throws -> UUID {
    let existing = try await existingWorkout(fingerprint: draft.fingerprint)
    if let existing { return existing.uuid }
    try requireWritePermission(.workoutType())
    var quantities: [(HKQuantityTypeIdentifier, HKUnit, [HealthWorkoutWriteDraft.Quantity], Double)] = [
      (.heartRate, HKUnit.count().unitDivided(by: .minute()), draft.heartRate, 1),
      (draft.workoutType == .cycling ? .cyclingPower : .runningPower, .watt(), draft.power, 1),
      (draft.workoutType == .cycling ? .cyclingSpeed : .runningSpeed,
        HKUnit.meter().unitDivided(by: .second()), draft.speed, 1),
    ]
    if draft.workoutType == .cycling {
      quantities.append((.cyclingCadence, HKUnit.count().unitDivided(by: .second()), draft.cadence, 1.0 / 60))
    }
    for (identifier, _, points, _) in quantities where !points.isEmpty {
      guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { throw HealthWorkoutWriteError.unavailableType }
      try requireWritePermission(type)
    }
    if draft.locations.count >= 2 { try requireWritePermission(HKSeriesType.workoutRoute()) }
    for (identifier, value) in [(Self.distanceWriteIdentifier(draft.workoutType), draft.distanceMeters), (.activeEnergyBurned, draft.energyKilocalories)] {
      if let value, value > 0 {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { throw HealthWorkoutWriteError.unavailableType }
        try requireWritePermission(type)
      }
    }
    let configuration = HKWorkoutConfiguration()
    configuration.activityType = draft.workoutType
    configuration.locationType = draft.locations.count >= 2 ? .outdoor : .indoor
    let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
    var finished = false
    defer { if !finished { builder.discardWorkout() } }
    let start = Date(timeIntervalSince1970: Double(draft.collectionStartMs) / 1_000)
    let end = Date(timeIntervalSince1970: Double(draft.collectionEndMs) / 1_000)
    try await builder.beginCollection(at: start)
    try await builder.addMetadata([
      HKMetadataKeySyncIdentifier: draft.fingerprint,
      HKMetadataKeySyncVersion: NSNumber(value: 1),
      "HealthWorkoutExport.OriginalDurationSeconds": draft.durationSeconds,
      "HealthWorkoutExport.OmittedNonCyclingCadenceCount": draft.workoutType == .cycling ? 0 : draft.cadence.count,
    ])
    for (identifier, unit, points, scale) in quantities where !points.isEmpty {
      guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { throw HealthWorkoutWriteError.unavailableType }
      for offset in stride(from: 0, to: points.count, by: 1_000) {
        let samples = points[offset..<min(offset + 1_000, points.count)].map { point in
          HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: point.value * scale), start: point.date, end: point.date)
        }
        try await builder.addSamples(samples)
      }
    }
    var totals: [HKSample] = []
    for (identifier, unit, value) in [
      (Self.distanceWriteIdentifier(draft.workoutType), HKUnit.meter(), draft.distanceMeters),
      (.activeEnergyBurned, HKUnit.kilocalorie(), draft.energyKilocalories),
    ] {
      if let value, value > 0, let type = HKQuantityType.quantityType(forIdentifier: identifier) {
        totals.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value), start: start, end: end))
      }
    }
    if !totals.isEmpty { try await builder.addSamples(totals) }
    if !draft.events.isEmpty {
      try await builder.addWorkoutEvents(draft.events.map { event in
        HKWorkoutEvent(type: event.type == "pause" ? .pause : .resume, dateInterval: DateInterval(start: event.date, duration: 1), metadata: nil)
      })
    }
    try await builder.endCollection(at: end)
    guard let workout = try await builder.finishWorkout() else { throw HealthWorkoutWriteError.failed }
    finished = true
    if draft.locations.count >= 2 {
      do { try await saveDraftRoute(draft, workout: workout) }
      catch { throw HealthWorkoutWriteError.partial(workout.uuid, draft.fingerprint) }
    }
    return workout.uuid
  }

  private func saveDraftRoute(_ draft: HealthWorkoutWriteDraft, workout: HKWorkout) async throws {
    try requireWritePermission(HKSeriesType.workoutRoute())
    let builder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
    for offset in stride(from: 0, to: draft.locations.count, by: 100) {
      let locations = draft.locations[offset..<min(offset + 100, draft.locations.count)].map { point in
        CLLocation(
          coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
          altitude: point.altitudeMeters ?? 0, horizontalAccuracy: 5,
          verticalAccuracy: point.altitudeMeters == nil ? -1 : 3, timestamp: point.date
        )
      }
      try await builder.insertRouteData(locations)
    }
    _ = try await builder.finishRoute(with: workout, metadata: nil)
  }
}
