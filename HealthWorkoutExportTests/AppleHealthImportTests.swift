import XCTest
import HealthKit
import FITSwiftSDK
@testable import HealthWorkoutExport

final class AppleHealthImportTests: XCTestCase {
    func testFitDraftKeepsCyclingRouteHeartRateAndCadence() throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let bundle = WorkoutBundle(
            summary: WorkoutSummary(
                id: UUID(),
                uuid: UUID(),
                activityType: .cycling,
                activityName: "骑车",
                startDate: start,
                endDate: start.addingTimeInterval(60),
                duration: 60,
                totalDistanceMeters: 400,
                totalEnergyKilocalories: 12,
                sourceName: "行者"
            ),
            metadata: [:],
            events: [
                WorkoutEventDTO(type: "pause", date: start.addingTimeInterval(20)),
                WorkoutEventDTO(type: "resume", date: start.addingTimeInterval(25))
            ],
            series: [
                HKQuantityTypeIdentifier.heartRate.rawValue: [
                    TimedSample(date: start, value: 140, unit: "count/min"),
                    TimedSample(date: start.addingTimeInterval(1), value: 142, unit: "count/min")
                ],
                HKQuantityTypeIdentifier.cyclingCadence.rawValue: [
                    TimedSample(date: start, value: 80, unit: "count/min")
                ]
            ],
            route: [
                RoutePoint(latitude: 31.23, longitude: 121.47, altitude: 8, timestamp: start, speed: 6),
                RoutePoint(latitude: 31.231, longitude: 121.471, altitude: 9, timestamp: start.addingTimeInterval(1), speed: 6.2)
            ]
        )
        let data = try FitActivityEncoder.encode(bundle, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        let draft = try HealthWorkoutDraft.fromFIT(data, fingerprint: "abc123")

        XCTAssertEqual(draft.fingerprint, "abc123")
        XCTAssertEqual(draft.activityType, .cycling)
        XCTAssertEqual(draft.start.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(draft.end.timeIntervalSince1970, start.addingTimeInterval(60).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(draft.distanceMeters ?? 0, 400, accuracy: 1)
        XCTAssertEqual(draft.energyKilocalories ?? 0, 12, accuracy: 1)
        XCTAssertGreaterThanOrEqual(draft.heartRate.count, 2)
        XCTAssertEqual(draft.heartRate[0].value, 140, accuracy: 0.1)
        XCTAssertFalse(draft.cadence.isEmpty)
        XCTAssertEqual(draft.cadence[0].value, 80, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(draft.locations.count, 2)
        XCTAssertEqual(draft.locations[0].latitude, 31.23, accuracy: 0.001)
        XCTAssertTrue(draft.events.contains { $0.type == "pause" })
        XCTAssertTrue(draft.events.contains { $0.type == "resume" })
    }

    func testFitDraftKeepsStopDisablePauseForActiveDuration() throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let elapsed: TimeInterval = 32 * 60 + 32
        let active: TimeInterval = 26 * 60 + 1
        let bundle = WorkoutBundle(
            summary: WorkoutSummary(
                id: UUID(), uuid: UUID(), activityType: .cycling, activityName: "骑车",
                startDate: start, endDate: start.addingTimeInterval(elapsed), duration: elapsed,
                totalDistanceMeters: nil, totalEnergyKilocalories: nil, sourceName: "行者"
            ),
            metadata: [:],
            events: [
                WorkoutEventDTO(type: "pause", date: start.addingTimeInterval(900)),
                WorkoutEventDTO(type: "resume", date: start.addingTimeInterval(1_291))
            ],
            series: [:], route: []
        )
        var messages = try FitMerger.decode(try FitActivityEncoder.encode(bundle))
        let pause = try XCTUnwrap(messages.eventMesgs.first {
            $0.getEventType() == .stopAll && $0.getTimestamp()?.date == start.addingTimeInterval(900)
        })
        try pause.setEventType(.stopDisableAll)
        try XCTUnwrap(messages.sessionMesgs.first).setTotalTimerTime(active)

        let draft = try HealthWorkoutDraft.fromFIT(try FitMessagesReencoder.encode(messages), fingerprint: "active-duration")

        XCTAssertEqual(draft.duration, active, accuracy: 1)
        XCTAssertEqual(draft.end.timeIntervalSince(start), elapsed, accuracy: 1)
        XCTAssertTrue(draft.events.contains { $0.type == "pause" && $0.date == start.addingTimeInterval(900) })
        XCTAssertTrue(draft.events.contains { $0.type == "resume" && $0.date == start.addingTimeInterval(1_291) })
    }

    func testNearbyOverlapUsesActivityMatcherWindow() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let activity = SourceActivity(
            id: "xz-1",
            sourceId: "xingzhe",
            title: "晨骑",
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            duration: 3600,
            distanceMeters: 20_000
        )
        let watch = HealthNearbyWorkout(
            uuid: UUID(),
            startDate: start.addingTimeInterval(300),
            endDate: start.addingTimeInterval(3500),
            duration: 3200,
            distanceMeters: 19_000,
            sourceName: "Apple Watch",
            syncIdentifier: nil
        )
        let far = HealthNearbyWorkout(
            uuid: UUID(),
            startDate: start.addingTimeInterval(100_000),
            endDate: start.addingTimeInterval(103_600),
            duration: 3600,
            distanceMeters: 20_000,
            sourceName: "Apple Watch",
            syncIdentifier: nil
        )
        let hits = HealthProximity.overlapping(activity, in: [watch, far])
        XCTAssertEqual(hits.map(\.uuid), [watch.uuid])
    }

    func testOwnSyncIdentifierCountsAsAlreadyImported() {
        let fingerprint = "deadbeef"
        let ours = HealthNearbyWorkout(
            uuid: UUID(),
            startDate: Date(),
            endDate: Date().addingTimeInterval(60),
            duration: 60,
            distanceMeters: 1000,
            sourceName: "运动导出",
            syncIdentifier: fingerprint
        )
        XCTAssertEqual(HealthProximity.alreadyImported(fingerprint: fingerprint, in: [ours])?.uuid, ours.uuid)
        XCTAssertNil(HealthProximity.alreadyImported(fingerprint: fingerprint, in: [
            HealthNearbyWorkout(
                uuid: UUID(),
                startDate: ours.startDate,
                endDate: ours.endDate,
                duration: 60,
                distanceMeters: 1000,
                sourceName: "Apple Watch",
                syncIdentifier: nil
            )
        ]))
    }

    func testOldSyncStateJSONStillDecodesWithoutHealthFields() throws {
        let original = SyncStateRecord(
            fingerprint: "fp",
            status: .uploaded,
            primarySourceId: "xingzhe",
            primaryActivityId: "1",
            remoteId: "99",
            message: "ok",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            title: "骑行",
            supplementSourceIds: ["onelap"],
            isDuplicate: false,
            distanceMeters: 10_000,
            durationSeconds: 3600,
            batchAt: nil,
            uploadChannel: .api,
            hasVirtualPower: false
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "appleHealthUUID")
        object.removeValue(forKey: "appleHealthSkipped")
        object.removeValue(forKey: "appleHealthError")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SyncStateRecord.self, from: stripped)
        XCTAssertEqual(decoded.remoteId, "99")
        XCTAssertEqual(decoded.status, .uploaded)
        XCTAssertNil(decoded.appleHealthUUID)
        XCTAssertNil(decoded.appleHealthSkipped)
        XCTAssertNil(decoded.appleHealthError)
    }

    func testSyncJobDefaultsDoNotEnableHealthWrite() {
        let job = SyncJobConfig(
            primarySourceId: "xingzhe",
            supplementSourceIds: ["onelap"],
            mode: .today,
            historyRange: .days7,
            customStart: Date(),
            customEnd: Date(),
            skipIfHistoryExists: true
        )
        XCTAssertTrue(job.uploadToStrava)
        XCTAssertFalse(job.writeToAppleHealth)
    }

    func testAppleHealthMarkDoesNotChangeStravaStatus() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync_state_health_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SyncStateStore(fileURL: url)
        await store.markPending(fingerprint: "fp", primarySourceId: "xingzhe", primaryActivityId: "1")
        await store.markUploaded(fingerprint: "fp", remoteId: "99")
        await store.markAppleHealthWritten(fingerprint: "fp", uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        let record = await store.record(for: "fp")
        XCTAssertEqual(record?.status, .uploaded)
        XCTAssertEqual(record?.remoteId, "99")
        XCTAssertEqual(record?.appleHealthUUID, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    }

    func testNearbyCancelAndDismissDoNotPersistSkip() {
        XCTAssertTrue(AppleHealthNearbyDecision.skip.shouldPersistSkip)
        XCTAssertTrue(AppleHealthNearbyDecision.skipRestOfBatch.shouldPersistSkip)
        XCTAssertFalse(AppleHealthNearbyDecision.cancelBatch.shouldPersistSkip)
        XCTAssertFalse(AppleHealthNearbyDecision.skipOnce.shouldPersistSkip)
        XCTAssertFalse(AppleHealthNearbyDecision.write.shouldPersistSkip)
    }

    func testHealthAuthorizationErrorIsNotReadOnlyWording() {
        XCTAssertEqual(
            HealthKitServiceError.unauthorized.localizedDescription,
            "未获得健康数据权限"
        )
    }

    func testAppleHealthSkipDoesNotChangeStravaStatus() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync_state_health_skip_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SyncStateStore(fileURL: url)
        await store.markPending(fingerprint: "fp", primarySourceId: "xingzhe", primaryActivityId: "1")
        await store.markUploaded(fingerprint: "fp", remoteId: "99")
        await store.markAppleHealthSkipped(fingerprint: "fp")
        let record = await store.record(for: "fp")
        XCTAssertEqual(record?.status, .uploaded)
        XCTAssertEqual(record?.remoteId, "99")
        XCTAssertEqual(record?.appleHealthSkipped, true)
        XCTAssertNil(record?.appleHealthUUID)
    }
}
