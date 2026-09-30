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

extension RunnerTests {
  func testWebNetworkSessionHasNoAmbientCookiesCredentialsOrRedirects() throws {
    let session = StravaWebPlugin.makeIsolatedSession()
    defer { session.invalidateAndCancel() }
    XCTAssertNil(session.configuration.httpCookieStorage)
    XCTAssertNil(session.configuration.urlCredentialStorage)
    XCTAssertNil(session.configuration.urlCache)
    XCTAssertFalse(session.configuration.httpShouldSetCookies)
    XCTAssertEqual(session.configuration.timeoutIntervalForResource, 120)
    let url = URL(string: "https://www.strava.com/upload/files")!
    let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil))
    let task = session.dataTask(with: URLRequest(url: url))
    let delegate = try XCTUnwrap(session.delegate as? URLSessionTaskDelegate)
    var called = false
    delegate.urlSession?(
      session, task: task, willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: URL(string: "https://attacker.example/upload")!)
    ) { request in
      called = true
      XCTAssertNil(request)
    }
    XCTAssertTrue(called)
  }

  func testWebUploadRejectsUntrustedEndpointsAndErrorPages() throws {
    let url = URL(string: "https://www.strava.com/upload/files")!
    let body = Data(#"duplicate of <a href='/activities/42'>ride</a>"#.utf8)
    let duplicate = try StravaWebPlugin.uploadResponse(statusCode: 422, finalURL: url, body: body)
    XCTAssertEqual(duplicate["remoteId"] as? String, "42")
    XCTAssertEqual(duplicate["isDuplicate"] as? Bool, true)
    let missingId = try StravaWebPlugin.uploadResponse(
      statusCode: 200, finalURL: url, body: Data("duplicate of activity".utf8)
    )
    XCTAssertNil(missingId["remoteId"])
    for status in [302, 307, 401, 403, 429, 500] {
      XCTAssertThrowsError(try StravaWebPlugin.uploadResponse(statusCode: status, finalURL: url, body: body))
    }
    for raw in [
      "https://evilstrava.com/upload/files", "https://www.strava.com/login",
      "http://www.strava.com/upload/files", "https://www.strava.com:444/upload/files",
      "https://user@www.strava.com/upload/files",
    ] {
      XCTAssertThrowsError(try StravaWebPlugin.uploadResponse(
        statusCode: 200, finalURL: URL(string: raw), body: body
      ))
    }
    XCTAssertThrowsError(try StravaWebPlugin.uploadResponse(
      statusCode: 400, finalURL: url, body: Data("duplicate field name".utf8)
    ))
    XCTAssertThrowsError(try StravaWebPlugin.uploadResponse(
      statusCode: 200, finalURL: url, body: Data(count: StravaWebPlugin.maximumResponseBytes + 1)
    ))
  }

  func testWebTokensCookiesAndActivityLinksAreStrictlyBounded() {
    XCTAssertEqual(StravaWebPlugin.extractCSRFToken(
      from: #"<meta content='abc-_+/=' name='csrf-token'>"#
    ), "abc-_+/=")
    XCTAssertEqual(StravaWebPlugin.extractCSRFToken(
      from: #"<input value='form-token' name='authenticity_token'>"#
    ), "form-token")
    XCTAssertNil(StravaWebPlugin.extractCSRFToken(
      from: "<meta name='csrf-token' content='abc\r\nInjected: yes'>"
    ))
    XCTAssertNil(StravaWebPlugin.extractCSRFToken(
      from: "<meta name='csrf-token' content='\(String(repeating: "x", count: 4_097))'>"
    ))
    XCTAssertEqual(StravaWebPlugin.normalizedStoredCookieHeader("Cookie: session=abc=="), "session=abc==")
    XCTAssertNil(StravaWebPlugin.normalizedStoredCookieHeader("session=a;\r\nother=b"))
    XCTAssertNil(StravaWebPlugin.normalizedStoredCookieHeader("session=a\r\nInjected: yes"))
    XCTAssertNil(StravaWebPlugin.normalizedStoredCookieHeader("session=a;"))
    XCTAssertEqual(StravaWebPlugin.activityURL(remoteId: "123")?.absoluteString, "https://www.strava.com/activities/123")
    for value in ["", "../123", "https://evil.test", "123?x=y", "１２３", String(repeating: "1", count: 33)] {
      XCTAssertNil(StravaWebPlugin.activityURL(remoteId: value))
    }
    for raw in ["https://evilfacebook.com", "https://facebook.com.evil.test", "https://www.strava.com:444", "https://user@www.strava.com"] {
      XCTAssertFalse(StravaWebPlugin.isAllowedLoginNavigation(URL(string: raw)!))
    }
  }

  func testRootCookiePersistenceDoesNotReusePathScopedCookies() throws {
    func cookie(_ name: String, _ value: String, _ domain: String, _ path: String) throws -> HTTPCookie {
      try XCTUnwrap(HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: path]))
    }
    let cookies = try [
      cookie("session", "root", ".strava.com", "/"),
      cookie("session", "athlete", ".strava.com", "/athlete"),
      cookie("api", "private", "api.strava.com", "/"),
      cookie("attacker", "bad", "evilstrava.com", "/"),
    ]
    XCTAssertEqual(StravaWebPlugin.cookieHeader(from: cookies, requestPath: "/"), "session=root")
    XCTAssertEqual(StravaWebPlugin.cookieHeader(from: cookies), "session=athlete")
  }
}


extension RunnerTests {
  func testWebDeletionOnlyTrustsExpectedResponsesAndRedirectTargets() {
    let url = URL(string: "https://www.strava.com/activities/42")!
    for location in ["/athlete/training", "https://www.strava.com/dashboard"] {
      XCTAssertTrue(StravaWebPlugin.isSuccessfulDeletion(
        statusCode: 302, finalURL: url, remoteId: "42", location: location, body: Data()
      ))
    }
    for location in ["/login", "https://evil.test/dashboard", "//evil.test/athlete/training", "/activities/42", "https://www.strava.com:444/dashboard"] {
      XCTAssertFalse(StravaWebPlugin.isSuccessfulDeletion(
        statusCode: 302, finalURL: url, remoteId: "42", location: location, body: Data()
      ))
    }
    XCTAssertTrue(StravaWebPlugin.isSuccessfulDeletion(
      statusCode: 404, finalURL: url, remoteId: "42", location: nil, body: Data()
    ))
    XCTAssertFalse(StravaWebPlugin.isSuccessfulDeletion(
      statusCode: 403, finalURL: url, remoteId: "42", location: nil, body: Data("not found".utf8)
    ))
    XCTAssertFalse(StravaWebPlugin.isSuccessfulDeletion(
      statusCode: 200, finalURL: url, remoteId: "42", location: nil, body: Data("please log in".utf8)
    ))
    XCTAssertFalse(StravaWebPlugin.isSuccessfulDeletion(
      statusCode: 404, finalURL: URL(string: "https://evil.test/activities/42"),
      remoteId: "42", location: nil, body: Data()
    ))
    let csrf = StravaWebPlugin.extractCSRFPair(
      from: #"<meta name='csrf-param' content='csrf_param'><meta name='csrf-token' content='a+/='>"#
    )
    XCTAssertEqual(csrf?.param, "csrf_param")
    XCTAssertEqual(csrf?.token, "a+/=")
    XCTAssertNil(StravaWebPlugin.extractCSRFPair(
      from: #"<meta name='csrf-param' content='_method'><meta name='csrf-token' content='delete'>"#
    ))
  }

  func testWebActivityPageBoundsAndUtcDates() throws {
    let start = Int64(ISO8601DateFormatter().date(from: "2026-09-30T00:00:00Z")!.timeIntervalSince1970 * 1_000)
    let end = start + 86_400_000
    let url = try XCTUnwrap(StravaWebPlugin.activityPageURL(page: 2, afterMs: start, beforeMs: end))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
    XCTAssertEqual(items["start_date"], "09/29/2026")
    XCTAssertEqual(items["end_date"], "10/02/2026")
    XCTAssertEqual(items["page"], "2")
    XCTAssertEqual(components.host, "www.strava.com")
    XCTAssertEqual(components.path, "/athlete/training_activities")
    XCTAssertNil(StravaWebPlugin.activityPageURL(page: 0, afterMs: start, beforeMs: end))
    XCTAssertNil(StravaWebPlugin.activityPageURL(page: 201, afterMs: start, beforeMs: end))
    XCTAssertNil(StravaWebPlugin.activityPageURL(page: 1, afterMs: end, beforeMs: start))
    XCTAssertNil(StravaWebPlugin.activityPageURL(page: 1, afterMs: .min, beforeMs: .max))
  }
}


extension RunnerTests {
  func testOAuthRejectsUserinfoPortsFragmentsAndAmbiguousCallbacks() {
    for value in [
      "https://user@www.strava.com/oauth/mobile/authorize",
      "https://www.strava.com:444/oauth/mobile/authorize",
      "https://www.strava.com/oauth/mobile/authorize#fragment",
      "https://www.strava.com/oauth/mobile/%61uthorize",
    ] {
      XCTAssertThrowsError(try StravaOAuthSecurity.authorizationURL(from: value, state: "state"))
    }
    for value in [
      "healthworkoutexport://user@localhost/callback?state=state&code=code",
      "healthworkoutexport://localhost:443/callback?state=state&code=code",
      "healthworkoutexport://localhost/callback?state=state&code=code#fragment",
      "healthworkoutexport://localhost/callback?state=state&state=state&code=code",
    ] {
      XCTAssertFalse(StravaOAuthSecurity.isValidCallback(
        URL(string: value)!, callbackScheme: "healthworkoutexport", expectedState: "state"
      ))
    }
  }

  func testBatchSessionHasFixedPathBoundedJsonAndAtomicRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchSessionTests.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = SyncFilesPlugin.Storage(rootURL: root)
    XCTAssertEqual(try storage.url(for: .batchSession).lastPathComponent, "auto-sync-batch.json")
    let data = Data(#"{"version":1,"phase":"uploading"}"#.utf8)
    try storage.write(data, kind: .batchSession)
    XCTAssertEqual(try storage.read(.batchSession), data)
    XCTAssertThrowsError(try storage.write(Data("[]".utf8), kind: .batchSession))
    XCTAssertThrowsError(try storage.write(Data(count: 4 * 1_024 * 1_024 + 1), kind: .batchSession))
    XCTAssertEqual(try storage.read(.batchSession), data)
    try storage.delete(.batchSession)
    try storage.delete(.batchSession)
    XCTAssertThrowsError(try storage.read(.batchSession))
  }
}


extension RunnerTests {
  private func healthWriteDraftData(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    var payload: [String: Any] = [
      "fingerprint": String(repeating: "a", count: 64),
      "activityType": 13, "startMs": 1_000, "endMs": 4_000, "durationSeconds": 3.0,
      "distanceMeters": NSNull(), "energyKilocalories": NSNull(),
      "locations": [["latitude": 31.5, "longitude": 120.5, "timestampMs": 1_500]],
      "heartRate": [["dateMs": 1_500, "value": 140.0, "unit": "count/min"]],
      "cadence": [["dateMs": 1_500, "value": 90.0, "unit": "rpm"]],
      "power": [["dateMs": 1_500, "value": 180.0, "unit": "W"]],
      "speed": [["dateMs": 1_500, "value": 7.0, "unit": "m/s"]],
      "events": [["type": "pause", "dateMs": 2_000], ["type": "resume", "dateMs": 3_000]],
    ]
    edit(&payload)
    return try JSONSerialization.data(withJSONObject: payload)
  }

  func testHealthWriteDraftPreservesSparseValuesAndUnits() throws {
    let draft = try HealthWorkoutWriteDraft.parse(healthWriteDraftData())
    XCTAssertEqual(draft.workoutType, .cycling)
    XCTAssertEqual(draft.fingerprint, String(repeating: "a", count: 64))
    XCTAssertNil(draft.distanceMeters)
    XCTAssertNil(draft.energyKilocalories)
    XCTAssertNil(draft.locations.first?.altitudeMeters)
    XCTAssertEqual(draft.locations.first?.timestampMs, 1_500)
    XCTAssertEqual(draft.cadence.first?.unit, "rpm")
    XCTAssertEqual(draft.heartRate.first?.value, 140)
    XCTAssertEqual(draft.events.count, 2)
  }

  func testHealthWriteDraftRejectsMalformedBoundariesAndUnrecognizedUnits() throws {
    let mutations: [(inout [String: Any]) -> Void] = [
      { $0["fingerprint"] = "../unsafe" },
      { $0["activityType"] = 999_999 },
      { $0["startMs"] = true },
      { $0["startMs"] = 5_000 },
      { $0["durationSeconds"] = 10_000 },
      { $0["distanceMeters"] = -1 },
      { $0["heartRate"] = [["dateMs": -9_000_000_000_000_000, "value": 140, "unit": "count/min"]] },
      { $0["speed"] = [["dateMs": 1_500, "value": 7, "unit": "km/h"]] },
      { $0["power"] = [["dateMs": 1_500, "value": -10, "unit": "W"]] },
      { $0["locations"] = [["latitude": 91, "longitude": 120, "timestampMs": 1_500]] },
      { $0["events"] = [["type": "delete", "dateMs": 2_000]] },
      { $0["events"] = [["type": "pause", "dateMs": 3_000], ["type": "resume", "dateMs": 2_000]] },
    ]
    for mutation in mutations {
      XCTAssertThrowsError(try HealthWorkoutWriteDraft.parse(healthWriteDraftData(mutation)))
    }
    XCTAssertThrowsError(try HealthWorkoutWriteDraft.parse(Data()))
    XCTAssertThrowsError(try HealthWorkoutWriteDraft.parse(Data(count: HealthWorkoutWriteDraft.maximumBytes + 1)))
  }
}


extension RunnerTests {
  func testHealthWriteCollectionCoversRealSamplesOutsideSummary() throws {
    let data = try healthWriteDraftData {
      $0["heartRate"] = [["dateMs": 500, "value": 140, "unit": "count/min"]]
      $0["speed"] = [["dateMs": 5_000, "value": 7, "unit": "m/s"]]
    }
    let draft = try HealthWorkoutWriteDraft.parse(data)
    XCTAssertEqual(draft.startMs, 1_000)
    XCTAssertEqual(draft.endMs, 4_000)
    XCTAssertEqual(draft.collectionStartMs, 500)
    XCTAssertEqual(draft.collectionEndMs, 6_000)
  }
}


extension RunnerTests {
  func testHealthWriteEqualSummaryTimesRetainOneSecondCollection() throws {
    let data = try healthWriteDraftData {
      $0["startMs"] = 1_000
      $0["endMs"] = 1_000
      $0["durationSeconds"] = 0
      $0["locations"] = []
      $0["heartRate"] = [["dateMs": 1_000, "value": 140, "unit": "count/min"]]
      $0["cadence"] = []
      $0["power"] = []
      $0["speed"] = []
      $0["events"] = []
    }
    let draft = try HealthWorkoutWriteDraft.parse(data)
    XCTAssertEqual(draft.startMs, draft.endMs)
    XCTAssertGreaterThanOrEqual(draft.collectionEndMs, draft.collectionStartMs + 1_000)
  }

  func testHealthWriteEqualSummaryWithoutSamplesStillHasPositiveCollection() throws {
    let data = try healthWriteDraftData {
      $0["startMs"] = 1_000
      $0["endMs"] = 1_000
      $0["durationSeconds"] = 0
      for key in ["locations", "heartRate", "cadence", "power", "speed", "events"] { $0[key] = [] }
    }
    let draft = try HealthWorkoutWriteDraft.parse(data)
    XCTAssertEqual(draft.collectionEndMs, 2_000)
  }
}


extension RunnerTests {
  func testPreferencesPreserveLegacyPreviewAndHealthWriteKeys() throws {
    let suite = "PreferencesMigrationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("issuesOnly", forKey: "sync_preview_policy")
    defaults.set(true, forKey: "write_to_apple_health")
    let plugin = PreferencesPlugin(defaults: defaults)
    var value: Any?
    plugin.handle(FlutterMethodCall(methodName: "read", arguments: ["key": "sync_preview_policy"])) { value = $0 }
    XCTAssertEqual(value as? String, "issuesOnly")
    plugin.handle(FlutterMethodCall(methodName: "read", arguments: ["key": "write_to_apple_health"])) { value = $0 }
    XCTAssertEqual(value as? Bool, true)
    plugin.handle(FlutterMethodCall(methodName: "write", arguments: ["key": "sync_preview_policy", "value": "everyActivity"])) { value = $0 }
    XCTAssertNil(value)
    XCTAssertEqual(defaults.string(forKey: "sync_preview_policy"), "everyActivity")
    plugin.handle(FlutterMethodCall(methodName: "write", arguments: ["key": "write_to_apple_health", "value": false])) { value = $0 }
    XCTAssertNil(value)
    XCTAssertFalse(defaults.bool(forKey: "write_to_apple_health"))
  }
}


extension RunnerTests {
  func testHealthPreparedChannelKeepsUploadedArchiveSeparate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HealthPreparedTests.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = SyncFilesPlugin.Storage(rootURL: root)
    let fingerprint = String(repeating: "a", count: 64)
    let uploaded = Data([1, 2, 3])
    let health = Data([8, 9])
    try storage.write(uploaded, kind: .syncedFIT(fingerprint))
    let plugin = SyncFilesPlugin(storage: storage)
    func invoke(_ method: String, bytes: Data? = nil) -> Any? {
      var arguments: [String: Any] = ["fingerprint": fingerprint]
      if let bytes { arguments["bytes"] = FlutterStandardTypedData(bytes: bytes) }
      var response: Any?
      plugin.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { response = $0 }
      return response
    }
    XCTAssertNil(invoke("writeHealthPreparedFit", bytes: health))
    XCTAssertEqual(try XCTUnwrap(invoke("readHealthPreparedFit") as? FlutterStandardTypedData).data, health)
    XCTAssertEqual(try storage.read(.syncedFIT(fingerprint)), uploaded)
    XCTAssertNil(invoke("deleteHealthPreparedFit"))
    XCTAssertTrue(invoke("readHealthPreparedFit") is FlutterError)
    XCTAssertEqual(try storage.read(.syncedFIT(fingerprint)), uploaded)
  }
  #if os(macOS)
  func testSyncFitUsesOwnerOnlyPermissions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncPermissions.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = SyncFilesPlugin.Storage(rootURL: root)
    let kind = SyncFilesPlugin.FileKind.syncedFIT(String(repeating: "a", count: 64))
    try storage.write(Data([1]), kind: kind)
    let file = try storage.url(for: kind)
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
    let directoryPermissions = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(directoryPermissions?.intValue, 0o700)
  }
  #endif
}
