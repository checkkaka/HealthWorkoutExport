import Flutter
import Foundation

/// 复用旧应用 Application Support 文件布局，并为 Flutter/Rust 状态层提供受保护的原子文件 I/O。
final class SyncFilesPlugin: NSObject, FlutterPlugin {
  static let channelName = "health_workout_export/sync_files"

  enum FileKind {
    case state
    case syncedFIT(String)
    case recovery(String)
  }

  enum StorageError: Error, Equatable {
    case invalidArguments
    case invalidJSON
    case missing
    case corrupt
    case protected
    case tooLarge
    case io(String)

    var code: String {
      switch self {
      case .invalidArguments: "invalid_arguments"
      case .invalidJSON: "invalid_json"
      case .missing: "sync_file_missing"
      case .corrupt: "sync_file_corrupt"
      case .protected: "sync_file_protected"
      case .tooLarge: "sync_file_too_large"
      case .io: "sync_file_io"
      }
    }
  }

  private let storage: Storage

  init(storage: Storage = Storage()) {
    self.storage = storage
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger,
      codec: FlutterStandardMethodCodec.sharedInstance(),
      taskQueue: messenger.makeBackgroundTaskQueue?()
    )
    let instance = SyncFilesPlugin()
    channel.setMethodCallHandler(instance.handle)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      let arguments = call.arguments as? [String: Any]
      switch call.method {
      case "readState":
        result(FlutterStandardTypedData(bytes: try storage.read(.state)))
      case "writeState":
        try storage.write(try Self.data(from: arguments), kind: .state)
        result(nil)
      case "deleteState":
        try storage.delete(.state)
        result(nil)
      case "readSyncedFit":
        result(
          FlutterStandardTypedData(
            bytes: try storage.read(.syncedFIT(try Self.fingerprint(from: arguments)))))
      case "writeSyncedFit":
        try storage.write(
          try Self.data(from: arguments),
          kind: .syncedFIT(try Self.fingerprint(from: arguments))
        )
        result(nil)
      case "deleteSyncedFit":
        try storage.delete(.syncedFIT(try Self.fingerprint(from: arguments)))
        result(nil)
      case "readRecovery":
        result(
          FlutterStandardTypedData(
            bytes: try storage.read(.recovery(try Self.fingerprint(from: arguments)))))
      case "writeRecovery":
        try storage.write(
          try Self.data(from: arguments),
          kind: .recovery(try Self.fingerprint(from: arguments))
        )
        result(nil)
      case "deleteRecovery":
        try storage.delete(.recovery(try Self.fingerprint(from: arguments)))
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch let error as StorageError {
      result(FlutterError(code: error.code, message: error.message, details: nil))
    } catch {
      result(FlutterError(code: "sync_file_io", message: "同步文件操作失败", details: nil))
    }
  }

  static func isValidFingerprint(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }
  }

  private static func fingerprint(from arguments: [String: Any]?) throws -> String {
    guard let value = arguments?["fingerprint"] as? String, isValidFingerprint(value) else {
      throw StorageError.invalidArguments
    }
    return value
  }

  private static func data(from arguments: [String: Any]?) throws -> Data {
    guard let typedData = arguments?["bytes"] as? FlutterStandardTypedData else {
      throw StorageError.invalidArguments
    }
    return typedData.data
  }

  struct Storage {
    private let rootURL: URL?
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
      // 不回退临时目录：拿不到 Application Support 时由每次操作返回稳定 I/O 错误。
      rootURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      self.fileManager = fileManager
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
      self.rootURL = rootURL
      self.fileManager = fileManager
    }

    func read(_ kind: FileKind) throws -> Data {
      let url = try url(for: kind)
      guard fileManager.fileExists(atPath: url.path) else { throw StorageError.missing }
      do {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
          size.uint64Value <= UInt64(kind.maximumBytes)
        else { throw StorageError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if kind.isJSON {
          guard Self.isJSONObject(data) else {
            try quarantineCorruptFile(at: url)
            throw StorageError.corrupt
          }
        }
        return data
      } catch let error as StorageError {
        throw error
      } catch {
        throw classify(error)
      }
    }

    func write(_ data: Data, kind: FileKind) throws {
      guard !data.isEmpty, data.count <= kind.maximumBytes else {
        throw data.isEmpty ? StorageError.invalidArguments : StorageError.tooLarge
      }
      if kind.isJSON, !Self.isJSONObject(data) {
        throw StorageError.invalidJSON
      }
      let url = try url(for: kind)
      do {
        try prepareDirectory(
          url.deletingLastPathComponent(), protected: kind.usesDedicatedDirectory)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes(
          [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        try excludeFromBackup(url)
      } catch {
        throw classify(error)
      }
    }

    func delete(_ kind: FileKind) throws {
      let url = try url(for: kind)
      guard fileManager.fileExists(atPath: url.path) else { return }
      do {
        try fileManager.removeItem(at: url)
      } catch {
        throw classify(error)
      }
    }

    func url(for kind: FileKind) throws -> URL {
      guard let rootURL else { throw StorageError.io("application_support_unavailable") }
      switch kind {
      case .state:
        return rootURL.appendingPathComponent("sync_state.json", isDirectory: false)
      case .syncedFIT(let fingerprint):
        guard SyncFilesPlugin.isValidFingerprint(fingerprint) else {
          throw StorageError.invalidArguments
        }
        return rootURL.appendingPathComponent("synced_fits", isDirectory: true)
          .appendingPathComponent("\(fingerprint).fit", isDirectory: false)
      case .recovery(let fingerprint):
        guard SyncFilesPlugin.isValidFingerprint(fingerprint) else {
          throw StorageError.invalidArguments
        }
        return rootURL.appendingPathComponent("pending_resync", isDirectory: true)
          .appendingPathComponent("\(fingerprint).json", isDirectory: false)
      }
    }

    private func prepareDirectory(_ url: URL, protected: Bool) throws {
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
      if protected {
        try fileManager.setAttributes(
          [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
      }
      // 先排除父目录，确保原子写临时文件也不会进入设备备份。
      try excludeFromBackup(url)
    }

    private func excludeFromBackup(_ url: URL) throws {
      var mutableURL = url
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try mutableURL.setResourceValues(values)
    }

    private func quarantineCorruptFile(at url: URL) throws {
      let suffix = String(Int(Date().timeIntervalSince1970 * 1_000))
      let quarantine = url.deletingPathExtension()
        .appendingPathExtension("corrupt-\(suffix)-\(UUID().uuidString)")
      do {
        try fileManager.moveItem(at: url, to: quarantine)
        try fileManager.setAttributes(
          [.protectionKey: FileProtectionType.complete],
          ofItemAtPath: quarantine.path
        )
        try excludeFromBackup(quarantine)
      } catch {
        throw classify(error)
      }
    }

    private static func isJSONObject(_ data: Data) -> Bool {
      (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    private func classify(_ error: Error) -> StorageError {
      let nsError = error as NSError
      if nsError.domain == NSCocoaErrorDomain {
        switch nsError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
          return .missing
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
          return .protected
        default:
          break
        }
      }
      if nsError.domain == NSPOSIXErrorDomain,
        nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
      {
        return .protected
      }
      return .io("\(nsError.domain):\(nsError.code)")
    }
  }
}

extension SyncFilesPlugin.FileKind {
  fileprivate var isJSON: Bool {
    switch self {
    case .state, .recovery: true
    case .syncedFIT: false
    }
  }

  fileprivate var maximumBytes: Int {
    switch self {
    case .state: 16 * 1_024 * 1_024
    case .syncedFIT: 64 * 1_024 * 1_024
    case .recovery: 90 * 1_024 * 1_024
    }
  }

  fileprivate var usesDedicatedDirectory: Bool {
    switch self {
    case .state: false
    case .syncedFIT, .recovery: true
    }
  }
}

extension SyncFilesPlugin.StorageError {
  fileprivate var message: String {
    switch self {
    case .invalidArguments: "同步文件参数无效"
    case .invalidJSON: "写入的同步文件不是 JSON 对象"
    case .missing: "同步文件不存在"
    case .corrupt: "同步文件已损坏并隔离"
    case .protected: "设备锁定，受保护的同步文件暂不可访问"
    case .tooLarge: "同步文件超过大小限制"
    case .io: "同步文件操作失败"
    }
  }
}
