import XCTest
@testable import HealthWorkoutExport

final class ActivityMatcherTests: XCTestCase {
    @MainActor
    func testKeepIsRegisteredInNativeApp() {
        XCTAssertNotNil(DataSourceRegistry.shared.source(id: "keep"))
    }

    func testKeepDoesNotMatchCyclingSupplement() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let run = SourceActivity(id: "run", sourceId: "keep", title: "Keep 跑步", startDate: start,
            endDate: start.addingTimeInterval(1200), duration: 1200, distanceMeters: 4000)
        let ride = SourceActivity(id: "ride", sourceId: "onelap", title: "骑行", startDate: start,
            endDate: start.addingTimeInterval(1200), duration: 1200, distanceMeters: 4000)
        XCTAssertNil(ActivityMatcher.score(primary: run, candidate: ride))
        XCTAssertTrue(ActivityMatcher.rankedCandidates(primary: run, candidates: [ride]).isEmpty)
    }

    func testActivitySortBreaksTiesByDateAndKeepsMissingMetricsLast() {
        let items: [(id: String, metric: Double?, date: Date)] = [
            ("old", 10, Date(timeIntervalSince1970: 1)),
            ("missingOld", nil, Date(timeIntervalSince1970: 1)),
            ("new", 10, Date(timeIntervalSince1970: 2)),
            ("larger", 20, Date(timeIntervalSince1970: 0)),
            ("missingNew", nil, Date(timeIntervalSince1970: 3))
        ]
        for key in [ActivitySortKey.distance, .averageSpeed] {
            for ascending in [false, true] {
                let sorted = ActivitySortOrder(key: key, ascending: ascending).sorted(
                    items, metric: { $0.metric }, date: { $0.date }
                )
                XCTAssertEqual(sorted.map { $0.id }, ascending
                    ? ["old", "new", "larger", "missingOld", "missingNew"]
                    : ["larger", "new", "old", "missingNew", "missingOld"])
            }
        }
    }

    @MainActor
    func testHideFailurePreservesUploadedActivity() async {
        for error in [StravaUploadError.rateLimited, .unauthorized, .uploadFailed("HTTP 500")] {
            var requestedID: String?
            let result = await StravaAPIUploader.finishUpload(
                StravaUploadResult(remoteId: "123", isDuplicate: false),
                hideFromHome: true
            ) { id in
                requestedID = id
                throw error
            }
            XCTAssertEqual(requestedID, "123")
            XCTAssertEqual(result.remoteId, "123")
            XCTAssertFalse(result.isDuplicate)
            XCTAssertTrue(result.warning?.contains(error.localizedDescription) == true)
        }
    }

    @MainActor
    func testHideSkipsDuplicateDisabledAndMissingID() async {
        for (input, enabled) in [
            (StravaUploadResult(remoteId: "123", isDuplicate: true), true),
            (StravaUploadResult(remoteId: "123", isDuplicate: false), false),
            (StravaUploadResult(remoteId: nil, isDuplicate: false), true)
        ] {
            let result = await StravaAPIUploader.finishUpload(input, hideFromHome: enabled) { _ in
                XCTFail("不应发出隐藏请求")
            }
            XCTAssertEqual(result.remoteId, input.remoteId)
            XCTAssertEqual(result.isDuplicate, input.isDuplicate)
            XCTAssertNil(result.warning)
        }
    }

    @MainActor
    func testHideSuccessPreservesUploadedActivity() async {
        var requestedIDs: [String] = []
        let result = await StravaAPIUploader.finishUpload(
            StravaUploadResult(remoteId: "123", isDuplicate: false),
            hideFromHome: true
        ) { requestedIDs.append($0) }
        XCTAssertEqual(requestedIDs, ["123"])
        XCTAssertEqual(result.remoteId, "123")
        XCTAssertFalse(result.isDuplicate)
        XCTAssertNil(result.warning)
    }

    func testActivityListFilterCombinesInclusiveDistanceAndAverageSpeed() {
        let filter = ActivityListFilter(minimumDistanceText: "20", minimumAverageSpeedText: "20")
        XCTAssertTrue(filter.matches(distanceMeters: 20_000, duration: 3_600))
        XCTAssertFalse(filter.matches(distanceMeters: 19_999, duration: 3_600))
        XCTAssertFalse(filter.matches(distanceMeters: 20_000, duration: 3_601))
        XCTAssertTrue(ActivityListFilter(minimumDistanceText: "20").matches(distanceMeters: 20_000, duration: 0))
        XCTAssertFalse(ActivityListFilter(minimumDistanceText: "20").matches(distanceMeters: 19_999, duration: 0))
        XCTAssertTrue(ActivityListFilter(minimumAverageSpeedText: "20").matches(distanceMeters: 20_000, duration: 3_600))
        XCTAssertFalse(ActivityListFilter(minimumAverageSpeedText: "20").matches(distanceMeters: 20_000, duration: 3_601))
        XCTAssertFalse(filter.matches(distanceMeters: nil, duration: 3_600))
        XCTAssertFalse(filter.matches(distanceMeters: 20_000, duration: 0))
        XCTAssertTrue(ActivityListFilter().matches(distanceMeters: nil, duration: 0))
        // 非法/零值输入等价于未启用筛选。
        XCTAssertTrue(ActivityListFilter(minimumDistanceText: "abc").matches(distanceMeters: nil, duration: 0))
        XCTAssertTrue(ActivityListFilter(minimumDistanceText: "0").matches(distanceMeters: 1, duration: 1))
        XCTAssertTrue(filter.isEnabled)
        XCTAssertFalse(ActivityListFilter().isEnabled)
    }

    func testOnelapCredentialsOnlyUseTrustedHTTPSHosts() {
        XCTAssertTrue(OnelapClient.isTrustedAuthenticatedURL(URL(string: "https://otm.onelap.cn/api")!))
        XCTAssertFalse(OnelapClient.isTrustedAuthenticatedURL(URL(string: "http://otm.onelap.cn/api")!))
        XCTAssertFalse(OnelapClient.isTrustedAuthenticatedURL(URL(string: "https://onelap.cn.example.com/api")!))
    }

    func testOnelapAuthDetectsExpiredSession() {
        XCTAssertTrue(OnelapAuth.isExpired(httpStatus: 401))
        XCTAssertTrue(OnelapAuth.isExpired(httpStatus: 403))
        XCTAssertTrue(OnelapAuth.isExpired(httpStatus: 200, code: 401, message: "ok"))
        XCTAssertTrue(OnelapAuth.isExpired(httpStatus: 200, code: 200, message: "token过期"))
        XCTAssertTrue(OnelapAuth.isExpired(httpStatus: 200, code: 400, message: "token invalid"))
        XCTAssertTrue(OnelapAuth.isExpired(httpStatus: 200, code: 500, message: "请重新登录"))
        XCTAssertFalse(OnelapAuth.isExpired(httpStatus: 200, code: 200, message: "ok"))
        XCTAssertFalse(OnelapAuth.isExpired(httpStatus: 200, code: 500, message: "服务器错误"))
    }

    func testOnelapAuthParsesLoginAndRefreshTokens() {
        let login = ["data": [["token": "acc", "refresh_token": "ref"]]] as [String: Any]
        let loginTokens = OnelapAuth.sessionTokens(from: login)
        XCTAssertEqual(loginTokens?.token, "acc")
        XCTAssertEqual(loginTokens?.refreshToken, "ref")

        let refresh = ["data": ["token": "acc2"]] as [String: Any]
        let refreshed = OnelapAuth.sessionTokens(from: refresh)
        XCTAssertEqual(refreshed?.token, "acc2")
        XCTAssertNil(refreshed?.refreshToken)

        XCTAssertNil(OnelapAuth.sessionTokens(from: ["data": [:]]))
    }

    func testOverlapMatch() {
        let primary = SourceActivity(
            id: "p1", sourceId: "healthkit", title: "主",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            duration: 3600, distanceMeters: 20_000
        )
        let good = SourceActivity(
            id: "s1", sourceId: "xingzhe", title: "补",
            startDate: Date(timeIntervalSince1970: 1_700_000_300),
            endDate: Date(timeIntervalSince1970: 1_700_003_500),
            duration: 3200, distanceMeters: 19_000
        )
        let far = SourceActivity(
            id: "s2", sourceId: "xingzhe", title: "远",
            startDate: Date(timeIntervalSince1970: 1_700_100_000),
            endDate: Date(timeIntervalSince1970: 1_700_103_600),
            duration: 3600, distanceMeters: 20_000
        )
        let match = ActivityMatcher.bestMatch(primary: primary, candidates: [far, good])
        XCTAssertEqual(match?.id, "s1")
    }

    func testNoMatchWhenTooFar() {
        let primary = SourceActivity(
            id: "p1", sourceId: "healthkit", title: "主",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            duration: 3600, distanceMeters: 20_000
        )
        let far = SourceActivity(
            id: "s2", sourceId: "onelap", title: "远",
            startDate: Date(timeIntervalSince1970: 1_700_100_000),
            endDate: Date(timeIntervalSince1970: 1_700_103_600),
            duration: 3600, distanceMeters: 20_000
        )
        XCTAssertNil(ActivityMatcher.bestMatch(primary: primary, candidates: [far]))
    }

    func testNoMatchWhenOverlapIsTiny() {
        let primary = SourceActivity(
            id: "p1", sourceId: "healthkit", title: "主",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            duration: 3600, distanceMeters: 20_000
        )
        let barelyOverlapping = SourceActivity(
            id: "s1", sourceId: "xingzhe", title: "擦边",
            startDate: Date(timeIntervalSince1970: 1_700_003_599),
            endDate: Date(timeIntervalSince1970: 1_700_010_799),
            duration: 7200, distanceMeters: 40_000
        )
        XCTAssertNil(ActivityMatcher.bestMatch(primary: primary, candidates: [barelyOverlapping]))
    }

    func testLowOverlapFallsBackToStartAndDurationTolerance() {
        let primary = SourceActivity(
            id: "p1", sourceId: "healthkit", title: "主",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            duration: 3600, distanceMeters: 20_000
        )
        let withinTolerance = SourceActivity(
            id: "s1", sourceId: "xingzhe", title: "补",
            startDate: Date(timeIntervalSince1970: 1_699_999_100),
            endDate: Date(timeIntervalSince1970: 1_700_001_980),
            duration: 2880, distanceMeters: 19_000
        )
        XCTAssertEqual(
            ActivityMatcher.bestMatch(primary: primary, candidates: [withinTolerance])?.id,
            "s1"
        )
    }

    func testRankedCandidatesExplainAndSortMatches() {
        let primary = activity(id: "p", start: 0, duration: 3_600)
        let weaker = activity(id: "weak", start: 500, duration: 3_300)
        let stronger = activity(id: "strong", start: 30, duration: 3_590)

        let ranked = ActivityMatcher.rankedCandidates(primary: primary, candidates: [weaker, stronger])

        XCTAssertEqual(ranked.map(\.activity.id), ["strong", "weak"])
        XCTAssertTrue(ranked[0].reason.contains("时间重叠"))
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
    }

    func testCloseTopCandidatesRequireManualConfirmation() {
        let primary = activity(id: "p", start: 0, duration: 3_600)
        let first = activity(id: "a", start: 30, duration: 3_570)
        let second = activity(id: "b", start: 80, duration: 3_520)
        let ranked = ActivityMatcher.rankedCandidates(primary: primary, candidates: [second, first])

        XCTAssertTrue(ActivityMatcher.requiresConfirmation(ranked))
    }

    func testNearbyButIneligibleCandidateRemainsAvailableForManualSelection() {
        let primary = activity(id: "p", start: 0, duration: 3_600)
        let manual = activity(id: "manual", start: 1_800, duration: 2_700)
        let ranked = ActivityMatcher.rankedCandidates(primary: primary, candidates: [manual])

        XCTAssertEqual(ranked.first?.activity.id, "manual")
        XCTAssertFalse(ranked.first?.isEligible ?? true)
        XCTAssertTrue(ActivityMatcher.requiresConfirmation(ranked))
        XCTAssertNil(ActivityMatcher.bestMatch(primary: primary, candidates: [manual]))
    }

    private func activity(id: String, start: TimeInterval, duration: TimeInterval) -> SourceActivity {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return SourceActivity(
            id: id,
            sourceId: "test",
            title: id,
            startDate: base.addingTimeInterval(start),
            endDate: base.addingTimeInterval(start + duration),
            duration: duration
        )
    }
}
