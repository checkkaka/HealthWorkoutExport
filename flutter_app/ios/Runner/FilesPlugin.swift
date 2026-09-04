import Flutter
import UniformTypeIdentifiers
import UIKit

/// 系统文件选择；只把用户挑中的 FIT 复制到临时目录后返回路径。
final class FilesPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private static let channelName = "health_workout_export/files"
  private var pending: FlutterResult?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let plugin = FilesPlugin()
    channel.setMethodCallHandler(plugin.handle)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "pickFits" else {
      result(FlutterMethodNotImplemented)
      return
    }
    DispatchQueue.main.async { self.presentPicker(result: result) }
  }

  private func presentPicker(result: @escaping FlutterResult) {
    guard pending == nil else {
      result(
        FlutterError(code: "files_in_progress", message: "已有文件选择正在进行", details: nil)
      )
      return
    }
    guard
      let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }),
      var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        ?? scene.windows.first(where: { !$0.isHidden })?.rootViewController
    else {
      result(FlutterError(code: "files_unavailable", message: "无法显示文件选择", details: nil))
      return
    }
    while let presented = top.presentedViewController { top = presented }
    pending = result
    let types = [UTType(filenameExtension: "fit") ?? .data]
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
    picker.allowsMultipleSelection = true
    picker.delegate = self
    top.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish([])
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("picked-fits-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var paths: [String] = []
      for url in urls where url.pathExtension.lowercased() == "fit" {
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
          try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        paths.append(destination.path)
      }
      finish(paths)
    } catch {
      finish(error: FlutterError(code: "files_copy_failed", message: "无法读取所选 FIT", details: nil))
    }
  }

  private func finish(_ paths: [String]) {
    let result = pending
    pending = nil
    result?(paths)
  }

  private func finish(error: FlutterError) {
    let result = pending
    pending = nil
    result?(error)
  }
}
