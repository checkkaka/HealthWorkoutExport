import XCTest
@testable import HealthWorkoutExport

final class SyncFingerprintTests: XCTestCase {
    func testStableAndChangesWithSupplements() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let a = SyncFingerprint.make(
            primarySourceId: "healthkit",
            primaryActivityId: "abc",
            startDate: start,
            supplementSourceIds: ["xingzhe", "onelap"]
        )
        let b = SyncFingerprint.make(
            primarySourceId: "healthkit",
            primaryActivityId: "abc",
            startDate: start,
            supplementSourceIds: ["onelap", "xingzhe"]
        )
        let c = SyncFingerprint.make(
            primarySourceId: "healthkit",
            primaryActivityId: "abc",
            startDate: start,
            supplementSourceIds: ["xingzhe"]
        )
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, 64)
    }

    func testStoreIdempotentUploaded() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync_state_test_\(UUID().uuidString).json")
        let store = SyncStateStore(fileURL: url)
        let fp = "deadbeef"
        let before = await store.isUploaded(fp)
        XCTAssertFalse(before)
        await store.markPending(fingerprint: fp, primarySourceId: "h", primaryActivityId: "1")
        await store.markUploaded(fingerprint: fp, remoteId: "99")
        let after = await store.isUploaded(fp)
        XCTAssertTrue(after)
        try? FileManager.default.removeItem(at: url)
    }

    func testStableDedupeMatchesNearStartAndDistance() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(SyncStableDedupe.matches(
            startA: start,
            distanceA: 10_890,
            startB: start.addingTimeInterval(3 * 60),
            distanceB: 11_430
        ))
        XCTAssertFalse(SyncStableDedupe.matches(
            startA: start,
            distanceA: 3_000,
            startB: start.addingTimeInterval(3 * 60),
            distanceB: 11_000
        ))
        // 宽窗：开始差 20 分钟，距离接近但无时长 → 不命中（防相邻短途误伤）。
        XCTAssertFalse(SyncStableDedupe.matches(
            startA: start,
            distanceA: 12_040,
            startB: start.addingTimeInterval(20 * 60),
            distanceB: 11_800
        ))
        // 宽窗 + 时长接近 → 命中（多设备同场）。
        XCTAssertTrue(SyncStableDedupe.matches(
            startA: start,
            distanceA: 12_040,
            startB: start.addingTimeInterval(20 * 60),
            distanceB: 11_800,
            durationA: 24 * 60 + 2,
            durationB: 24 * 60 + 12
        ))
    }

    func testStoreStableDedupeAcrossPrimary() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync_state_stable_\(UUID().uuidString).json")
        let store = SyncStateStore(fileURL: url)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        await store.markPending(
            fingerprint: "fp-health",
            primarySourceId: "healthkit",
            primaryActivityId: "1",
            startDate: start,
            distanceMeters: 10_900,
            durationSeconds: 30 * 60
        )
        await store.markUploaded(
            fingerprint: "fp-health",
            remoteId: "123",
            distanceMeters: 10_900,
            durationSeconds: 30 * 60
        )
        let hit = await store.hasUploadedStable(
            startDate: start.addingTimeInterval(120),
            distanceMeters: 11_200,
            durationSeconds: 30 * 60
        )
        XCTAssertTrue(hit)
        try? FileManager.default.removeItem(at: url)
    }

    func testRemoteIdBackfillWithinTwoMinutes() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let locals = [
            (fingerprint: "a", startDate: t0),
            (fingerprint: "b", startDate: t0.addingTimeInterval(10 * 60))
        ]
        let remotes = [
            SyncRemoteIdBackfill.RemoteCandidate(id: "100", startDate: t0.addingTimeInterval(90)),
            SyncRemoteIdBackfill.RemoteCandidate(id: "101", startDate: t0.addingTimeInterval(10 * 60 + 30)),
            SyncRemoteIdBackfill.RemoteCandidate(id: "102", startDate: t0.addingTimeInterval(150))
        ]
        let pairs = SyncRemoteIdBackfill.assignments(
            locals: locals,
            remotes: remotes,
            occupiedRemoteIds: []
        )
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs.first { $0.fingerprint == "a" }?.remoteId, "100")
        XCTAssertEqual(pairs.first { $0.fingerprint == "b" }?.remoteId, "101")
    }

    func testRemoteIdBackfillRejectsTwoMinutesOrMore() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let pairs = SyncRemoteIdBackfill.assignments(
            locals: [(fingerprint: "a", startDate: t0)],
            remotes: [.init(id: "100", startDate: t0.addingTimeInterval(120))],
            occupiedRemoteIds: []
        )
        XCTAssertTrue(pairs.isEmpty)
    }

    func testRemoteIdBackfillSkipsOccupied() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let pairs = SyncRemoteIdBackfill.assignments(
            locals: [(fingerprint: "a", startDate: t0)],
            remotes: [.init(id: "100", startDate: t0)],
            occupiedRemoteIds: ["100"]
        )
        XCTAssertTrue(pairs.isEmpty)
    }

    func testMarkUploadedStoresChannel() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync_state_channel_\(UUID().uuidString).json")
        let store = SyncStateStore(fileURL: url)
        await store.markPending(fingerprint: "fp", primarySourceId: "xingzhe", primaryActivityId: "1")
        await store.markUploaded(fingerprint: "fp", remoteId: "9", uploadChannel: .web)
        let record = await store.record(for: "fp")
        XCTAssertEqual(record?.uploadChannel, .web)
        try? FileManager.default.removeItem(at: url)
    }

    /// 列表远端 ID 以本地记录为准，即使记录仍是 pending 也要展示。
    func testLocalRemoteIdsIncludeNonUploadedRecord() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync_state_remote_map_\(UUID().uuidString).json")
        let store = SyncStateStore(fileURL: url)
        await store.markPending(fingerprint: "fp", primarySourceId: "healthkit", primaryActivityId: "activity-1")
        await store.setRemoteId(fingerprint: "fp", remoteId: "19651682943")
        let ids = await store.localRemoteIdsByPrimaryKey()
        XCTAssertEqual(ids[SyncStateStore.primaryKey(sourceId: "healthkit", activityId: "activity-1")], "19651682943")
        try? FileManager.default.removeItem(at: url)
    }

    /// 后台 poll 硬错误须能把已 uploaded 打回 failed，否则本地跳过永不再传。
    func testMarkFailedAfterUploadedAllowsRetry() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync_state_fail_\(UUID().uuidString).json")
        let store = SyncStateStore(fileURL: url)
        await store.markPending(fingerprint: "fp", primarySourceId: "xingzhe", primaryActivityId: "1")
        await store.markUploaded(fingerprint: "fp", remoteId: nil, uploadChannel: .api)
        await store.markFailed(fingerprint: "fp", message: "processing error")
        let record = await store.record(for: "fp")
        let uploaded = await store.isUploaded("fp")
        XCTAssertEqual(record?.status, .failed)
        XCTAssertEqual(record?.message, "processing error")
        XCTAssertFalse(uploaded)
        try? FileManager.default.removeItem(at: url)
    }

    /// 后台才发现的 duplicate：markDeduped 应补 ID 并打去重标。
    func testMarkDedupedAfterUploaded() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync_state_dedupe_\(UUID().uuidString).json")
        let store = SyncStateStore(fileURL: url)
        await store.markPending(fingerprint: "fp", primarySourceId: "xingzhe", primaryActivityId: "1")
        await store.markUploaded(fingerprint: "fp", remoteId: nil, uploadChannel: .api)
        await store.markDeduped(fingerprint: "fp", reason: "后台处理判定 duplicate", remoteId: "196")
        let record = await store.record(for: "fp")
        XCTAssertEqual(record?.status, .uploaded)
        XCTAssertEqual(record?.isDuplicate, true)
        XCTAssertEqual(record?.remoteId, "196")
        XCTAssertEqual(record?.message, "后台处理判定 duplicate")
        try? FileManager.default.removeItem(at: url)
    }

    func testResyncRecoveryStoreRoundTripsAndRemovesPreparedUpload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("resync_recovery_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResyncRecoveryStore(directoryURL: directory)
        let fingerprint = String(repeating: "a", count: 64)
        let upload = PendingResyncUpload(
            primarySourceId: "healthkit",
            primaryActivityId: "activity-1",
            title: "恢复测试",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            supplementSourceIds: ["xingzhe"],
            distanceMeters: 20_000,
            durationSeconds: 3_600,
            uploadData: Data([0x01, 0x02, 0x03]),
            uploadMessage: "已转换坐标",
            filename: "healthkit-activity-1.fit",
            commute: false
        )

        try store.save(upload, fingerprint: fingerprint)
        XCTAssertEqual(try store.load(fingerprint: fingerprint), upload)
        store.remove(fingerprint: fingerprint)
        XCTAssertNil(try store.load(fingerprint: fingerprint))
    }
}
