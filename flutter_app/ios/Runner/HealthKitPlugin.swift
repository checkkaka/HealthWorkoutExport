import Flutter
import Foundation
import HealthKit
import UIKit

/// Flutter 的最小 HealthKit 边界；FIT 编码、同步和网络逻辑留在 Dart/Rust 层。
final class HealthKitPlugin: NSObject, FlutterPlugin {
  private static let channelName = "health_workout_export/healthkit"
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
    case "listWorkouts":
      listWorkouts(arguments: call.arguments, result: result)
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

  private static func milliseconds(_ value: Any?) -> Double? {
    guard !(value is Bool) else { return nil }
    return (value as? NSNumber)?.doubleValue
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

  var errorDescription: String? {
    "startMs/endMs 必须是有限数字，且 startMs 小于 endMs"
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
