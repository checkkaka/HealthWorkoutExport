import Cocoa
import FlutterMacOS
import XCTest

@testable import health_workout_export

class RunnerTests: XCTestCase {
  func testPreferencesAllowlistRejectsUnknownKeys() {
    let plugin = PreferencesPlugin()
    let recorder = PluginResultRecorder()
    plugin.handle(
      FlutterMethodCall(methodName: "read", arguments: ["key": "not.allowed"]),
      result: recorder.callback
    )
    XCTAssertEqual(recorder.errorCode, "invalid_arguments")
  }

  func testFilesPluginChannelNameIsSharedWithDart() {
    XCTAssertTrue(StravaWebPlugin.isSafeUploadFilename("ride.fit"))
    XCTAssertFalse(StravaWebPlugin.isSafeUploadFilename("../ride.fit"))
    XCTAssertEqual(
      StravaWebPlugin.extractCSRFToken(from: #"<meta name="csrf-token" content="abc">"#),
      "abc"
    )
  }
}

private final class PluginResultRecorder {
  var errorCode: String?
  var callback: FlutterResult {
    { [weak self] value in
      self?.errorCode = (value as? FlutterError)?.code
    }
  }
}
