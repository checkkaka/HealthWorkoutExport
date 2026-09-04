import Foundation
#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// 直接读写旧应用 UserDefaults 键，迁移后继续使用原有非敏感设置。
final class PreferencesPlugin: NSObject, FlutterPlugin {
  private static let channelName = "health_workout_export/preferences"
  private static let allowedKeys: Set<String> = [
    "strava.uploadMode",
    "strava.gcjCorrectionEnabled",
    "virtualPower.enabled",
    "virtualPower.includeInertia",
    "virtualPower.riderMassKg",
    "virtualPower.bikeMassKg",
    "virtualPower.cda",
  ]
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    let instance = PreferencesPlugin()
    channel.setMethodCallHandler(instance.handle)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let key = arguments["key"] as? String,
      Self.allowedKeys.contains(key)
    else {
      result(invalidArguments())
      return
    }

    switch call.method {
    case "read":
      guard let value = defaults.object(forKey: key) else {
        result(nil)
        return
      }
      guard value is String || value is NSNumber else {
        result(
          FlutterError(
            code: "preferences_invalid_data",
            message: "UserDefaults value has an unsupported type",
            details: ["key": key]
          )
        )
        return
      }
      result(value)
    case "write":
      guard let value = arguments["value"], value is String || value is NSNumber else {
        result(invalidArguments())
        return
      }
      defaults.set(value, forKey: key)
      result(nil)
    case "delete":
      defaults.removeObject(forKey: key)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func invalidArguments() -> FlutterError {
    FlutterError(
      code: "invalid_arguments",
      message: "A non-empty key and a supported value are expected",
      details: nil
    )
  }
}
