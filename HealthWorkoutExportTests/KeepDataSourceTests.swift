import XCTest
import FITSwiftSDK
@testable import HealthWorkoutExport

final class KeepDataSourceTests: XCTestCase {
    func client(_ handler: @escaping (URLRequest) throws -> (Int, [String: Any])) -> KeepClient {
        KeepFixtureProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KeepFixtureProtocol.self]
        return KeepClient(session: URLSession(configuration: config))
    }
    func testLoginUsesSingleFormAndNeverRetriesRejectedPassword() async throws {
        var requests = 0
        let client = client { request in
            requests += 1
            XCTAssertEqual(request.url?.host, "api.gotokeep.com")
            XCTAssertEqual(request.url?.path, "/v1.1/users/login")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            return (403, ["ok": false])
        }
        do { _ = try await client.login(.init(account: "synthetic", password: "p&=+")); XCTFail("应拒绝登录") }
        catch { XCTAssertTrue(error is KeepFailure) }
        XCTAssertEqual(requests, 1)
    }
    func testPaginationDedupesAndFiltersHalfOpenRange() async throws {
        let run = fixture()
        var calls = 0
        let client = client { request in
            calls += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
            if request.url!.path.contains("stats/detail") {
                return (200, ["ok": true, "data": ["records": [["logs": [
                    ["stats": ["id": run["id"]!, "startTime": run["startTime"]!]],
                    ["stats": ["id": run["id"]!, "startTime": run["startTime"]!]],
                    ["stats": ["id": "excluded", "startTime": 1_700_000_061_000.0]]
                ]]], "lastTimestamp": 0]])
            }
            return (200, ["ok": true, "data": run])
        }
        let activities = try await client.list(token: "synthetic-token", from: Date(timeIntervalSince1970: 1_700_000_000), to: Date(timeIntervalSince1970: 1_700_000_061))
        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(calls, 2)
    }
    func testDetailIdentityAndRepeatedCursorAreRejected() async throws {
        let client = client { request in
            if request.url!.path.contains("stats/detail") {
                return (200, ["data": ["records": [], "lastTimestamp": 1_700_000_000_000.0]])
            }
            return (200, ["data": ["id": "different"]])
        }
        do { _ = try await client.detail(token: "token", id: "expected"); XCTFail("应拒绝活动 ID 不一致") } catch {}
        do { _ = try await client.list(token: "token", from: Date(timeIntervalSince1970: 1_600_000_000), to: Date(timeIntervalSince1970: 1_800_000_000)); XCTFail("应拒绝循环分页") } catch {}
    }

    func fixture(indoor: Bool = false) -> [String: Any] {
        ["id": "0123456789abcdef01234567", "dataType": indoor ? "indoorRunning" : "outdoorRunning",
         "startTime": 1_700_000_000_000.0, "endTime": 1_700_000_060_000.0,
         "duration": 50, "distance": 200]
    }
    func testTimestampFallsBackFromOutOfRangeUnixTime() throws {
        let activity = try KeepCodec.activity(fixture())
        let sample: [String: Any] = ["unixTimestamp": 1_700_431_240_632.0, "timestamp": 17_000_000_010.0]
        XCTAssertEqual(try KeepCodec.timestamp(sample, activity: activity).timeIntervalSince1970, 1_700_000_001)
        XCTAssertThrowsError(try KeepCodec.timestamp(["unixTimestamp": 1_700_431_240_632.0], activity: activity))
    }
    func testSummaryAndIndoorFIT() throws {
        let data = fixture(indoor: true)
        let activity = try KeepCodec.activity(data)
        XCTAssertEqual(activity.id, "0123456789abcdef01234567")
        XCTAssertEqual(activity.duration, 50)
        let fit = try KeepCodec.fit(data)
        let messages = try FitMerger.decode(fit, name: "keep")
        XCTAssertEqual(messages.sessionMesgs.first?.getSport(), .running)
        XCTAssertEqual(messages.sessionMesgs.first?.getSubSport(), .treadmill)
        XCTAssertEqual(messages.sessionMesgs.first?.getTotalTimerTime(), 50)
        XCTAssertTrue(messages.recordMesgs.allSatisfy { $0.getPositionLat() == nil })
    }
    func testHistoricalDurationIsIndependentOfWallClock() throws {
        var data = fixture()
        data["endTime"] = 1_700_000_641_471.0
        data["duration"] = 645
        XCTAssertEqual(try KeepCodec.activity(data).duration, 645)
        data["endTime"] = 1_700_000_899_485.0
        data["duration"] = 906
        XCTAssertEqual(try KeepCodec.activity(data).duration, 906)
        let messages = try FitMerger.decode(KeepCodec.fit(data), name: "keep")
        XCTAssertEqual(messages.sessionMesgs.first?.getTotalTimerTime(), 906)
        XCTAssertEqual(messages.sessionMesgs.first?.getTotalElapsedTime(), 906)
        data["duration"] = 360_001
        XCTAssertThrowsError(try KeepCodec.activity(data))
    }
    func testMalformedAndUnsupportedDetailsRejected() throws {
        var data = fixture()
        data["dataType"] = "cycling"
        XCTAssertThrowsError(try KeepCodec.activity(data))
        data = fixture(); data["geoPoints"] = "not-base64"
        XCTAssertThrowsError(try KeepCodec.fit(data))
        data = fixture(); data["duration"] = 360_001
        XCTAssertThrowsError(try KeepCodec.activity(data))
    }
    func testEncryptedRouteAndHeartRateMatchRustFixture() throws {
        var data = fixture()
        data["geoPoints"] = "ZMkcnWvLvuibuuBifdNcf46NfNNalMwPCHBhAyVx2bEuHp9zn6kdWGNBBSVXll6yeyl6/3ClyyRi/nxO0qhw7gAcQXDhcYNSW2yftI57nbijCaQRHzMJtdGP4zfckYa+e9tk9uj8YQJqqmVQAdfMGw=="
        data["heartRate"] = ["heartRates": "H4sIAAAAAAACA4uuVirJzE0tLknMLVCyMjTQUUpKTSwpDkgt8s3MKy1JBYqZGNTqoKgywqrKtDYWAAT8juJNAAAA"]
        let messages = try FitMerger.decode(KeepCodec.fit(data), name: "keep")
        XCTAssertEqual(messages.recordMesgs.count, 2)
        XCTAssertTrue(messages.recordMesgs.contains { $0.getHeartRate() != nil })
        let expected = Gcj02ToWgs84.convert(latitude: 39.9042, longitude: 116.4074)
        let latitude = Double(try XCTUnwrap(messages.recordMesgs.first?.getPositionLat())) * 180 / 2_147_483_648
        XCTAssertEqual(latitude, expected.0, accuracy: 0.00001)
    }
}

private final class KeepFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
