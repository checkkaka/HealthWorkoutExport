import AppKit
import FlutterMacOS
import UniformTypeIdentifiers

/// macOS 文件选择；NSOpenPanel 只返回用户选中的 FIT 路径。
final class FilesPlugin: NSObject, FlutterPlugin {
  private static let channelName = "health_workout_export/files"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger
    )
    channel.setMethodCallHandler(FilesPlugin().handle)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "pickFits" else {
      result(FlutterMethodNotImplemented)
      return
    }
    DispatchQueue.main.async {
      let panel = NSOpenPanel()
      panel.allowsMultipleSelection = true
      panel.canChooseDirectories = false
      panel.allowedContentTypes = [UTType(filenameExtension: "fit") ?? .data]
      guard panel.runModal() == .OK else {
        result([] as [String])
        return
      }
      result(
        panel.urls
          .filter { $0.pathExtension.lowercased() == "fit" }
          .map(\.path)
      )
    }
  }
}
