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
