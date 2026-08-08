import XCTest
@testable import HealthWorkoutExport

final class StravaActivityLookupTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func remote(_ id: String, startOffset: TimeInterval, minutes: Double) -> StravaActivityLookup.RemoteActivity {
        let start = base.addingTimeInterval(startOffset)
        return .init(id: id, startDate: start, endDate: start.addingTimeInterval(minutes * 60))
    }

    func testParseDuplicateActivityId() {
        let text = "Test_Walk.gpx duplicate of activity 21234316"
        XCTAssertEqual(StravaActivityLookup.parseDuplicateActivityId(text), "21234316")
    }

    func testParseDuplicateCaseInsensitive() {
        XCTAssertEqual(StravaActivityLookup.parseDuplicateActivityId("file.fit Duplicate Of Activity 99"), "99")
    }

    func testParseDuplicateNilWhenMissing() {
        XCTAssertNil(StravaActivityLookup.parseDuplicateActivityId("processing error"))
    }

    /// 网页 HTML：duplicate of <a href='/activities/123'>????</a>
    func testParseDuplicateFromHtmlAnchor() {
        let text = "46a62033.fit duplicate of <a href='/activities/19636549590' target='_blank'>????</a>"
        XCTAssertEqual(StravaActivityLookup.parseDuplicateActivityId(text), "19636549590")
        XCTAssertTrue(StravaActivityLookup.isDuplicateUploadResponse(text))
    }

    /// JSON null / "<null>" 不得当成远端 ID，否则轮询提前结束。
    func testJsonActivityIdIgnoresNull() {
        XCTAssertNil(StravaActivityLookup.jsonActivityId(nil))
        XCTAssertNil(StravaActivityLookup.jsonActivityId(NSNull()))
        XCTAssertNil(StravaActivityLookup.jsonActivityId("<null>"))
        XCTAssertNil(StravaActivityLookup.jsonActivityId("null"))
        XCTAssertEqual(StravaActivityLookup.jsonActivityId(19_643_161_379 as NSNumber), "19643161379")
        XCTAssertEqual(StravaActivityLookup.jsonActivityId("19643161379"), "19643161379")
        XCTAssertFalse(StravaSpeedAnomaly.isOpenableRemoteId("<null>"))
    }

    /// 同一次骑行被两台设备记录：区间几乎完全重合，应判为重复。
    func testMatchesHighlyOverlappingActivity() {
        let match = StravaActivityLookup.match(
            startDate: base,
            endDate: base.addingTimeInterval(90 * 60),
            in: [remote("1", startOffset: 2 * 60, minutes: 88)]
        )
        XCTAssertEqual(match?.id, "1")
    }

    /// 热身在前、主骑在后：开始时间只差 13 分钟但区间不重叠，不算重复。
    func testDoesNotMatchAdjacentWarmup() {
        let warmup = remote("warmup", startOffset: -13 * 60, minutes: 12)
        let match = StravaActivityLookup.match(
            startDate: base,
            endDate: base.addingTimeInterval(120 * 60),
            in: [warmup]
        )
        XCTAssertNil(match)
    }

    /// 同场多设备：开始差约 40 分钟、时长接近，IoU 不足仍应判重复。
    func testMatchesSimilarStartAndDuration() {
        let other = remote("clock-skew", startOffset: 39 * 60, minutes: 48)
        let match = StravaActivityLookup.match(
            startDate: base,
            endDate: base.addingTimeInterval(50 * 60),
            in: [other]
        )
        XCTAssertEqual(match?.id, "clock-skew")
    }

    /// 开始紧邻但时长差 >20%：时长路径落空，靠距离紧窗判重复。
    func testMatchesSimilarStartAndDistance() {
        let other = StravaActivityLookup.RemoteActivity(
            id: "near-dup",
            startDate: base.addingTimeInterval(2 * 60),
            endDate: base.addingTimeInterval(2 * 60 + 30 * 60),
            distanceMeters: 11_800
        )
        let match = StravaActivityLookup.match(
            startDate: base,
            endDate: base.addingTimeInterval(24 * 60),
            distanceMeters: 12_040,
            in: [other]
        )
        XCTAssertEqual(match?.id, "near-dup")
    }

    /// 开始接近但时长差很大：不算重复（避免误伤相邻不同活动）。
    func testDoesNotMatchSimilarStartDifferentDuration() {
        let other = remote("other", startOffset: 10 * 60, minutes: 10)
        let match = StravaActivityLookup.match(
            startDate: base,
            endDate: base.addingTimeInterval(90 * 60),
            in: [other]
        )
        XCTAssertNil(match)
    }

    /// 短活动完全落在长活动内部：重叠比例仅 10%，不算重复。
    func testDoesNotMatchShortActivityInsideLongOne() {
        let short = remote("short", startOffset: 5 * 60, minutes: 12)
        let match = StravaActivityLookup.match(
            startDate: base,
            endDate: base.addingTimeInterval(120 * 60),
            in: [short]
        )
        XCTAssertNil(match)
    }

    /// 多条候选时取重叠比例最高的一条。
    func testPicksBestOverlap() {
        let partial = remote("partial", startOffset: 0, minutes: 60)
        let nearlyIdentical = remote("same", startOffset: 60, minutes: 119)
        let match = StravaActivityLookup.match(
            startDate: base,
            endDate: base.addingTimeInterval(120 * 60),
            in: [partial, nearlyIdentical]
        )
        XCTAssertEqual(match?.id, "same")
    }

    func testNoMatchWhenListEmpty() {
        XCTAssertNil(StravaActivityLookup.match(startDate: base, endDate: base.addingTimeInterval(3600), in: []))
    }

    /// 异常规则：摘要最高速 / 最佳成绩单独 ≥80；或峰值≥80 且均速≥40。
    func testSpeedAnomalyRules() {
        let peak80 = StravaSpeedAnomaly.maxSpeedKmh / 3.6
        let avg40 = StravaSpeedAnomaly.averageSpeedKmh / 3.6
        XCTAssertTrue(StravaSpeedAnomaly.isAnomalous(
            listedMaxSpeedMps: peak80, bestEffortPeakMps: 0, peakSpeedMps: peak80, averageSpeedMps: 0
        ))
        XCTAssertTrue(StravaSpeedAnomaly.isAnomalous(
            listedMaxSpeedMps: 5, bestEffortPeakMps: peak80, peakSpeedMps: peak80, averageSpeedMps: 1
        ))
        XCTAssertTrue(StravaSpeedAnomaly.isAnomalous(
            listedMaxSpeedMps: 5, bestEffortPeakMps: 0, peakSpeedMps: peak80, averageSpeedMps: avg40
        ))
        XCTAssertFalse(StravaSpeedAnomaly.isAnomalous(
            listedMaxSpeedMps: 5, bestEffortPeakMps: 0, peakSpeedMps: peak80, averageSpeedMps: avg40 - 0.1
        ))
        XCTAssertTrue(StravaSpeedAnomaly.isOpenableRemoteId("12345"))
        XCTAssertFalse(StravaSpeedAnomaly.isOpenableRemoteId("unknown"))
        XCTAssertTrue(StravaSpeedAnomaly.isCyclingSport("Ride"))
        XCTAssertTrue(StravaSpeedAnomaly.isCyclingSport("VirtualRide"))
        XCTAssertTrue(StravaSpeedAnomaly.isCyclingSport("GravelRide"))
        XCTAssertFalse(StravaSpeedAnomaly.isCyclingSport("Walk"))
        XCTAssertFalse(StravaSpeedAnomaly.isCyclingSport("健走"))
        XCTAssertFalse(StravaSpeedAnomaly.isCyclingSport("Run"))
    }

    /// 5 英里 / 1 秒这类最佳成绩应单独抬峰值并判异常（不依赖均速）。
    func testPeakSpeedUsesBestEfforts() {
        let effortPeak = StravaSpeedAnomaly.bestEffortPeakMps(
            bestEfforts: [["name": "5 mile", "distance": 8046.72, "elapsed_time": 1]]
        )
        XCTAssertGreaterThan(effortPeak, 8000)
        XCTAssertTrue(StravaSpeedAnomaly.isAnomalous(
            listedMaxSpeedMps: 5, bestEffortPeakMps: effortPeak, peakSpeedMps: effortPeak, averageSpeedMps: 1
        ))
        XCTAssertEqual(
            StravaSpeedAnomaly.peakSpeedMps(maxSpeedMps: 10, bestEfforts: []),
            10
        )
    }

    func testUploadPollImmediateFirstAttempt() {
        XCTAssertEqual(StravaUploadPoll.delaySeconds(beforeAttempt: 0), 0)
        XCTAssertEqual(StravaUploadPoll.delaySeconds(beforeAttempt: 1), 1, accuracy: 0.001)
        XCTAssertEqual(StravaUploadPoll.delaySeconds(beforeAttempt: 2), 2, accuracy: 0.001)
        XCTAssertEqual(StravaUploadPoll.delaySeconds(beforeAttempt: 3), 4, accuracy: 0.001)
        XCTAssertEqual(StravaUploadPoll.delaySeconds(beforeAttempt: 6), 32, accuracy: 0.001)
        XCTAssertEqual(StravaUploadPoll.delaySeconds(beforeAttempt: 40), 32, accuracy: 0.001)
    }

    func testUploadPollBudgetUnderAbout70Seconds() {
        var total = 0.0
        for attempt in 0..<StravaUploadPoll.maxAttempts {
            total += StravaUploadPoll.delaySeconds(beforeAttempt: attempt)
        }
        XCTAssertLessThan(total, 70)
        XCTAssertGreaterThan(total, 50)
    }

    func testUploadErrorMessageRemovesHtml() {
        let raw = #"The file is empty, <a href="https://support.strava.com/empty">More Information</a>."#
        XCTAssertEqual(StravaUploadError.cleanedMessage(raw), "上传文件为空，Strava 无法处理")
        XCTAssertEqual(
            StravaUploadError.cleanedMessage("Malformed <strong>FIT</strong> file"),
            "Malformed FIT file"
        )
    }

    func testParsesStravaRateLimitHeaders() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://www.strava.com/api/v3/athlete")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "X-RateLimit-Limit": "200,2000",
                "X-RateLimit-Usage": "7,81",
                "X-ReadRateLimit-Limit": "100,1000",
                "X-ReadRateLimit-Usage": "5,60"
            ]
        ))
        let usage = try XCTUnwrap(StravaAPIUploader.parseRateLimitUsage(from: response))
        XCTAssertEqual(usage.overall, .init(
            fifteenMinutesUsed: 7,
            fifteenMinutesLimit: 200,
            dailyUsed: 81,
            dailyLimit: 2000
        ))
        XCTAssertEqual(usage.read, .init(
            fifteenMinutesUsed: 5,
            fifteenMinutesLimit: 100,
            dailyUsed: 60,
            dailyLimit: 1000
        ))
    }

    func testParsesStravaRateLimitHeadersOn429Response() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://www.strava.com/api/v3/athlete")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: [
                "X-RateLimit-Limit": "200,2000",
                "X-RateLimit-Usage": "200,801"
            ]
        ))
        let usage = try XCTUnwrap(StravaAPIUploader.parseRateLimitUsage(from: response))
        XCTAssertEqual(usage.overall.fifteenMinutesUsed, usage.overall.fifteenMinutesLimit)
        XCTAssertNil(usage.read)
    }

    /// local- 占位必须以 fingerprint 区分同秒开骑；匹配仍靠 hasPrefix("local-")。
    func testLocalPlaceholderPrefixStillRecognized() {
        let fp = "abc123fingerprint"
        let placeholder = "local-\(fp)"
        XCTAssertTrue(placeholder.hasPrefix("local-"))
        XCTAssertNotEqual(placeholder, "local-\(Int(Date().timeIntervalSince1970))")
    }
}
