import FITSwiftSDK
import XCTest
@testable import HealthWorkoutExport

final class FITInspectionTests: XCTestCase {
    func testInvalidFITAndMissingTimestampAreBlockingErrors() throws {
        let invalid = FITInspector.inspect(Data("not-fit".utf8))
        XCTAssertTrue(invalid.issues.contains { $0.id == "invalid-fit" && $0.severity == .error })

        let data = try makeFIT(recordCount: 1, includeTimestamps: false)
        let inspection = FITInspector.inspect(data)
        XCTAssertTrue(inspection.issues.contains { $0.id == "no-timestamp" && $0.severity == .error })
    }

    func testPreparedInvalidFITRemainsPreviewableButBlocked() async throws {
        let raw = Data("not-fit".utf8)

        let prepared = try await PreparedFITBuilder.build(
            primaryData: raw,
            primaryName: "损坏文件",
            supplements: [],
            gcjEnabled: true
        )

        XCTAssertEqual(prepared.data, raw)
        XCTAssertTrue(prepared.hasErrors)
        XCTAssertEqual(prepared.report.convertedCoordinateCount, 0)
    }

    func testInspectorRejectsInvalidLapOrSessionCoordinates() throws {
        let inspection = FITInspector.inspect(try makeFIT(recordCount: 8, invalidSessionLatitude: true))

        XCTAssertTrue(inspection.issues.contains { $0.id == "invalid-coordinate" && $0.severity == .error })
    }

    func testInspectorReportsFewGPSAndSpeedWarnings() throws {
        let inspection = FITInspector.inspect(try makeFIT(recordCount: 4, speedMPS: 30))

        XCTAssertTrue(inspection.issues.contains { $0.id == "few-gps-points" && $0.severity == .warning })
        XCTAssertTrue(inspection.issues.contains { $0.id == "speed-over-80" && $0.severity == .warning })
        XCTAssertGreaterThan(inspection.summary.maximumGPSSpeedKPH, 120)
        XCTAssertTrue(inspection.issues.contains { $0.id == "gps-speed-over-120" })
    }

    func testInspectorPrefersSessionRideSummaryMetrics() throws {
        let inspection = FITInspector.inspect(try makeFIT(
            recordCount: 4,
            speedMPS: 5,
            includePower: true,
            sessionAverageSpeedMPS: 6,
            sessionMaximumSpeedMPS: 12,
            sessionAverageHeartRate: 150,
            sessionMaximumHeartRate: 180,
            sessionAverageCadence: 92,
            sessionAveragePower: 230,
            sessionMaximumPower: 550,
            sessionTotalAscent: 43,
            sessionTotalDescent: 39,
            sessionTotalCalories: 680
        ))

        XCTAssertEqual(inspection.summary.averageSpeedKPH, 21.6)
        XCTAssertEqual(inspection.summary.maximumSpeedKPH, 43.2)
        XCTAssertEqual(inspection.summary.averageHeartRateBPM, 150)
        XCTAssertEqual(inspection.summary.maximumHeartRateBPM, 180)
        XCTAssertEqual(inspection.summary.averageCadenceRPM, 92)
        XCTAssertEqual(inspection.summary.averagePowerWatts, 230)
        XCTAssertEqual(inspection.summary.maximumPowerWatts, 550)
        XCTAssertEqual(inspection.summary.totalAscentMeters, 43)
        XCTAssertEqual(inspection.summary.totalDescentMeters, 39)
        XCTAssertEqual(inspection.summary.totalCalories, 680)
    }

    func testInspectorFallsBackToFinalRecordMetricsWhenSessionSummariesAreMissing() throws {
        let inspection = FITInspector.inspect(try makeFIT(recordCount: 4, speedMPS: 5, includePower: true))

        XCTAssertEqual(inspection.summary.averageSpeedKPH, 18)
        XCTAssertEqual(inspection.summary.averageHeartRateBPM, 121.5)
        XCTAssertEqual(inspection.summary.maximumHeartRateBPM, 123)
        XCTAssertEqual(inspection.summary.averageCadenceRPM, 81.5)
        XCTAssertEqual(inspection.summary.averagePowerWatts, 201.5)
        XCTAssertEqual(inspection.summary.maximumPowerWatts, 203)
        XCTAssertNil(inspection.summary.totalAscentMeters)
        XCTAssertNil(inspection.summary.totalDescentMeters)
        XCTAssertNil(inspection.summary.totalCalories)
    }

    func testInspectorUsesElapsedTimeForRecordFallbackAverages() throws {
        let inspection = FITInspector.inspect(try makeFIT(
            recordCount: 3,
            includePower: true,
            recordTimeOffsets: [0, 9, 10]
        ))

        XCTAssertEqual(inspection.summary.averageSpeedKPH ?? 0, 3.6, accuracy: 0.001)
        XCTAssertEqual(inspection.summary.averageHeartRateBPM ?? 0, 120.6, accuracy: 0.001)
        XCTAssertEqual(inspection.summary.averageCadenceRPM ?? 0, 80.6, accuracy: 0.001)
        XCTAssertEqual(inspection.summary.averagePowerWatts ?? 0, 200.6, accuracy: 0.001)
    }

    func testRideSummaryMetricPreferencesPersistOrderAndRestoreDefaultsForEmptySelection() {
        let suiteName = "RideSummaryMetricPreferencesTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        RideSummaryMetricPreferences.save([.averagePower, .distance, .averageHeartRate], defaults: defaults)
        XCTAssertEqual(
            RideSummaryMetricPreferences.load(defaults: defaults),
            [.averagePower, .distance, .averageHeartRate]
        )

        RideSummaryMetricPreferences.save([], defaults: defaults)
        XCTAssertEqual(RideSummaryMetricPreferences.load(defaults: defaults), RideSummaryMetric.defaultOrder)
    }

    func testAverageAndMaximumHeartRateAndSpeedUseDistinctSymbols() {
        XCTAssertNotEqual(RideSummaryMetric.averageHeartRate.symbol, RideSummaryMetric.maximumHeartRate.symbol)
        XCTAssertNotEqual(RideSummaryMetric.averageSpeed.symbol, RideSummaryMetric.maximumSpeed.symbol)
    }

    func testRideSummaryMetricPreferencesPublishesChanges() {
        let suiteName = "RideSummaryMetricPreferencesNotificationTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notification = expectation(description: "偏好变化通知")
        let observer = NotificationCenter.default.addObserver(
            forName: RideSummaryMetricPreferences.didChangeNotification,
            object: defaults,
            queue: nil
        ) { _ in
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        RideSummaryMetricPreferences.save([.distance], defaults: defaults)

        wait(for: [notification], timeout: 1)
    }

    func testRideSummaryDistinguishesMissingMetricsFromRecordedZeroDistance() throws {
        let missing = FITInspectionSummary()
        XCTAssertEqual(RideSummaryMetric.distance.display(in: missing).value, "—")
        XCTAssertEqual(RideSummaryMetric.duration.display(in: missing).value, "—")

        let recorded = FITInspector.inspect(try makeFIT(recordCount: 1)).summary
        XCTAssertEqual(RideSummaryMetric.distance.display(in: recorded).value, "0.00")
        XCTAssertEqual(RideSummaryMetric.duration.display(in: recorded).value, "0:01")
    }

    func testPreparedFITPreservesEveryCoordinateWhenGCJDisabled() async throws {
        let raw = try makeFIT(recordCount: 8, speedMPS: 50)
        let original = FITInspector.inspect(raw)

        let prepared = try await PreparedFITBuilder.build(
            primaryData: raw,
            primaryName: "码表",
            supplements: [],
            gcjEnabled: false
        )

        XCTAssertEqual(prepared.originalData, raw)
        XCTAssertEqual(prepared.finalInspection.coordinates, original.coordinates)
        XCTAssertGreaterThan(prepared.report.repairedSpeedCount, 0)
        XCTAssertFalse(prepared.processingIssues.contains { $0.id == "coordinate-changed-while-disabled" })
    }

    func testPreparedFITGCJConversionOnlyChangesUploadCopyAndKeepsShape() async throws {
        let raw = try makeFIT(recordCount: 8, speedMPS: 5)
        let before = FITInspector.inspect(raw)

        let prepared = try await PreparedFITBuilder.build(
            primaryData: raw,
            primaryName: "顽鹿",
            supplements: [],
            gcjEnabled: true
        )

        XCTAssertEqual(FITInspector.inspect(raw).coordinates, before.coordinates, "原始 Data 不得被改写")
        XCTAssertTrue(before.coordinates.hasSameShape(as: prepared.finalInspection.coordinates))
        XCTAssertNotEqual(before.coordinates, prepared.finalInspection.coordinates)
        XCTAssertGreaterThan(prepared.report.convertedCoordinateCount, 0)
        XCTAssertGreaterThan(prepared.report.averageCoordinateDisplacementMeters, 10)
    }

    func testDisplaySamplingDoesNotChangeFullAuditCounts() throws {
        let inspection = FITInspector.inspect(try makeFIT(recordCount: 2_501, speedMPS: 5, gpsStep: 0.00001))

        XCTAssertEqual(inspection.summary.recordCount, 2_501)
        XCTAssertEqual(inspection.summary.gpsCount, 2_501)
        XCTAssertEqual(inspection.track.count, 2_501)
        XCTAssertEqual(inspection.displayTrack().count, 2_000)
        XCTAssertEqual(inspection.displayTrack().first?.index, 0)
        XCTAssertEqual(inspection.displayTrack().last?.index, 2_500)
    }

    func testDistanceChangeAndEmptySupplementProduceWarnings() throws {
        let original = FITInspector.inspect(try makeFIT(recordCount: 8, speedMPS: 5))
        var final = original
        final.summary.distanceMeters += 500
        let issues = FITInspector.processingIssues(
            original: original,
            final: final,
            gcjEnabled: false,
            mergeReports: [.init(name: "补源", offsetSeconds: 0, filledCounts: [:])],
            repairedSpeedCount: 0,
            convertedCoordinateCount: 0,
            averageCoordinateDisplacementMeters: 0,
            virtualPowerCount: 0
        )

        XCTAssertTrue(issues.contains { $0.id == "distance-changed" && $0.severity == .warning })
        XCTAssertTrue(issues.contains { $0.id == "supplement-empty-补源" && $0.severity == .warning })
    }

    func testSupplementAlignmentFailureKeepsPrimaryDataUsable() async throws {
        let raw = try makeFIT(recordCount: 8, speedMPS: 5)
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let activity = SourceActivity(
            id: "supplement",
            sourceId: "test",
            title: "无时间补源",
            startDate: base,
            endDate: base.addingTimeInterval(60),
            duration: 60
        )
        let supplement = PreparedSupplement(
            sourceId: "test",
            sourceName: "补源",
            candidate: ActivityMatchCandidate(
                activity: activity,
                score: 1,
                confidence: .high,
                reason: "测试",
                isEligible: true
            ),
            data: try makeFIT(recordCount: 1, includeTimestamps: false)
        )

        let prepared = try await PreparedFITBuilder.build(
            primaryData: raw,
            primaryName: "主源",
            supplements: [supplement],
            gcjEnabled: false
        )

        XCTAssertEqual(prepared.finalInspection.coordinates, prepared.originalInspection.coordinates)
        XCTAssertEqual(prepared.report.mergeReports.first?.totalFilledCount, 0)
        XCTAssertTrue(prepared.processingIssues.contains { $0.id.hasPrefix("supplement-empty-") })
    }

    func testPreparedFITUsesSupplementDisplayNameForFilledField() async throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let activity = SourceActivity(
            id: "supplement",
            sourceId: "test",
            title: "补源骑行",
            startDate: base,
            endDate: base.addingTimeInterval(7),
            duration: 7
        )
        let supplement = PreparedSupplement(
            sourceId: "test",
            sourceName: "真实补源名称",
            candidate: ActivityMatchCandidate(
                activity: activity,
                score: 1,
                confidence: .high,
                reason: "测试",
                isEligible: true
            ),
            data: try makeFIT(recordCount: 8)
        )

        let prepared = try await PreparedFITBuilder.build(
            primaryData: try makeFIT(recordCount: 8, includeHeartRate: false),
            primaryName: "主源",
            supplements: [supplement],
            gcjEnabled: false
        )

        XCTAssertEqual(prepared.fieldSources[.heartRate], "真实补源名称")
        XCTAssertEqual(prepared.report.mergeReports.first?.name, "真实补源名称")
    }

    @MainActor
    func testPreviewBytesAreUploadedAfterRecoveryAndDelete() async throws {
        let raw = try makeFIT(recordCount: 8, speedMPS: 5)
        let source = FakeFITSource(data: raw)
        let activities = try await source.listActivities(from: .distantPast, to: .distantFuture)
        let activity = try XCTUnwrap(activities.first)
        let prepared = try await PreparedFITBuilder.build(
            primaryData: try await source.fetchFitData(for: activity),
            primaryName: source.displayName,
            supplements: [],
            gcjEnabled: true
        )
        let uploader = RecordingFITUploader()
        var events: [String] = []

        _ = try await SafeOverwriteSequence.execute(
            saveRecovery: { events.append("save") },
            deleteRemote: { events.append("delete") },
            upload: {
                events.append("upload")
                return try await uploader.uploadFit(
                    prepared.data,
                    externalId: "preview",
                    filename: "preview.fit",
                    name: nil,
                    commute: false,
                    description: nil
                )
            }
        )

        XCTAssertEqual(events, ["save", "delete", "upload"])
        XCTAssertEqual(uploader.uploadedData, prepared.data)
    }

    @MainActor
    func testSafeOverwriteStopsBeforeDeleteWhenRecoveryFails() async {
        var events: [String] = []

        do {
            _ = try await SafeOverwriteSequence.execute(
                saveRecovery: {
                    events.append("save")
                    throw CocoaError(.fileWriteUnknown)
                },
                deleteRemote: { events.append("delete") },
                upload: { events.append("upload") }
            )
            XCTFail("恢复文件失败时不应继续")
        } catch {
            XCTAssertEqual(events, ["save"])
        }
    }

    @MainActor
    func testCleanRebuildStillForcesAnotherPreview() {
        XCTAssertFalse(AutoSyncEngine.shouldPresentPreview(
            policy: .issuesOnly,
            hasErrors: false,
            hasWarnings: false,
            hasAmbiguity: false,
            force: false
        ))
        XCTAssertTrue(AutoSyncEngine.shouldPresentPreview(
            policy: .issuesOnly,
            hasErrors: false,
            hasWarnings: false,
            hasAmbiguity: false,
            force: true
        ))
    }

    func testRecoveryCleanupOnlyAfterUploadedState() {
        XCTAssertTrue(SafeOverwriteSequence.shouldClearRecovery(after: .uploaded))
        XCTAssertFalse(SafeOverwriteSequence.shouldClearRecovery(after: .failed))
        XCTAssertFalse(SafeOverwriteSequence.shouldClearRecovery(after: .pending))
        XCTAssertFalse(SafeOverwriteSequence.shouldClearRecovery(after: nil))
    }

    private func makeFIT(
        recordCount: Int,
        includeTimestamps: Bool = true,
        speedMPS: Double = 5,
        gpsStep: Double = 0.05,
        invalidSessionLatitude: Bool = false,
        includeHeartRate: Bool = true,
        includePower: Bool = false,
        recordTimeOffsets: [TimeInterval]? = nil,
        sessionAverageSpeedMPS: Double? = nil,
        sessionMaximumSpeedMPS: Double? = nil,
        sessionAverageHeartRate: UInt8? = nil,
        sessionMaximumHeartRate: UInt8? = nil,
        sessionAverageCadence: UInt8? = nil,
        sessionAveragePower: UInt16? = nil,
        sessionMaximumPower: UInt16? = nil,
        sessionTotalAscent: UInt16? = nil,
        sessionTotalDescent: UInt16? = nil,
        sessionTotalCalories: UInt16? = nil
    ) throws -> Data {
        let encoder = Encoder()
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let scale = 2_147_483_648.0 / 180.0
        let fileId = FileIdMesg()
        try fileId.setType(.activity)
        try fileId.setManufacturer(.development)
        try fileId.setProduct(1)
        try fileId.setTimeCreated(DateTime(date: base))
        encoder.write(mesg: fileId)

        for index in 0..<recordCount {
            let record = RecordMesg()
            if includeTimestamps {
                let offset = recordTimeOffsets?[index] ?? TimeInterval(index)
                try record.setTimestamp(DateTime(date: base.addingTimeInterval(offset)))
            }
            try record.setPositionLat(Int32(((31.30 + Double(index) * gpsStep) * scale).rounded()))
            try record.setPositionLong(Int32(((120.60 + Double(index) * gpsStep) * scale).rounded()))
            try record.setDistance(Double(index) * 5)
            try record.setSpeed(speedMPS)
            if includeHeartRate {
                try record.setHeartRate(UInt8(120 + index % 20))
            }
            try record.setCadence(UInt8(80 + index % 10))
            if includePower {
                try record.setPower(UInt16(200 + index))
            }
            encoder.write(mesg: record)
        }

        if includeTimestamps {
            let duration = recordTimeOffsets?.last ?? TimeInterval(max(1, recordCount - 1))
            let end = base.addingTimeInterval(duration)
            let lap = LapMesg()
            try lap.setStartTime(DateTime(date: base))
            try lap.setTimestamp(DateTime(date: end))
            try lap.setStartPositionLat(Int32((31.30 * scale).rounded()))
            try lap.setStartPositionLong(Int32((120.60 * scale).rounded()))
            try lap.setEndPositionLat(Int32(((31.30 + Double(max(0, recordCount - 1)) * gpsStep) * scale).rounded()))
            try lap.setEndPositionLong(Int32(((120.60 + Double(max(0, recordCount - 1)) * gpsStep) * scale).rounded()))
            encoder.write(mesg: lap)

            let session = SessionMesg()
            try session.setStartTime(DateTime(date: base))
            try session.setTimestamp(DateTime(date: end))
            try session.setSport(.cycling)
            try session.setTotalDistance(Double(max(0, recordCount - 1)) * 5)
            try session.setTotalTimerTime(duration)
            if let sessionAverageSpeedMPS { try session.setAvgSpeed(sessionAverageSpeedMPS) }
            if let sessionMaximumSpeedMPS { try session.setMaxSpeed(sessionMaximumSpeedMPS) }
            if let sessionAverageHeartRate { try session.setAvgHeartRate(sessionAverageHeartRate) }
            if let sessionMaximumHeartRate { try session.setMaxHeartRate(sessionMaximumHeartRate) }
            if let sessionAverageCadence { try session.setAvgCadence(sessionAverageCadence) }
            if let sessionAveragePower { try session.setAvgPower(sessionAveragePower) }
            if let sessionMaximumPower { try session.setMaxPower(sessionMaximumPower) }
            if let sessionTotalAscent { try session.setTotalAscent(sessionTotalAscent) }
            if let sessionTotalDescent { try session.setTotalDescent(sessionTotalDescent) }
            if let sessionTotalCalories { try session.setTotalCalories(sessionTotalCalories) }
            try session.setStartPositionLat(invalidSessionLatitude ? .max : Int32((31.30 * scale).rounded()))
            try session.setStartPositionLong(Int32((120.60 * scale).rounded()))
            try session.setEndPositionLat(Int32(((31.30 + Double(max(0, recordCount - 1)) * gpsStep) * scale).rounded()))
            try session.setEndPositionLong(Int32(((120.60 + Double(max(0, recordCount - 1)) * gpsStep) * scale).rounded()))
            encoder.write(mesg: session)
        }
        return encoder.close()
    }
}

private final class FakeFITSource: WorkoutDataSource {
    let id = "fake"
    let displayName = "伪数据源"
    let requiresLogin = false
    private let data: Data
    private let activity = SourceActivity(
        id: "activity",
        sourceId: "fake",
        title: "测试骑行",
        startDate: Date(timeIntervalSince1970: 1_720_000_000),
        endDate: Date(timeIntervalSince1970: 1_720_000_007),
        duration: 7
    )

    init(data: Data) { self.data = data }
    func isAuthenticated() async -> Bool { true }
    func login(credentials: SourceCredentials) async throws {}
    func logout() async {}
    func listActivities(from: Date, to: Date) async throws -> [SourceActivity] { [activity] }
    func fetchFitData(for activity: SourceActivity) async throws -> Data { data }
}

private final class RecordingFITUploader: StravaUploading {
    let mode = StravaUploadMode.api
    private(set) var uploadedData: Data?

    func isReady() async -> Bool { true }
    func uploadFit(
        _ data: Data,
        externalId: String,
        filename: String,
        name: String?,
        commute: Bool,
        description: String?
    ) async throws -> StravaUploadResult {
        uploadedData = data
        return StravaUploadResult(remoteId: "1", isDuplicate: false)
    }
}
