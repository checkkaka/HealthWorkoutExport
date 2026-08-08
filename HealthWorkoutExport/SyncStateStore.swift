import Foundation

enum SyncRecordStatus: String, Codable {
    case pending
    case uploaded
    case failed
}

struct SyncStateRecord: Codable, Equatable, Identifiable {
    var fingerprint: String
    var status: SyncRecordStatus
    var primarySourceId: String
    var primaryActivityId: String
    var remoteId: String?
    var message: String?
    var updatedAt: Date
    /// 展示用：主活动开始时间。
    var startDate: Date?
    /// 展示用：主活动标题。
    var title: String?
    /// 展示用：本次同步勾选的补源 ID。
    var supplementSourceIds: [String]?
    /// 是否因 Strava duplicate / 远端已存在而记为已上传。
    var isDuplicate: Bool?
    /// 稳定去重用：主活动距离（米）；旧记录可能为空。
    var distanceMeters: Double?
    /// 稳定去重宽窗用：主活动时长（秒）；旧记录可能为空。
    var durationSeconds: TimeInterval?
    /// 本次自动同步批次开始时间；同一次 run 内各条共享，供「按批次」归纳。
    var batchAt: Date?
    /// 实际上传通道（API / 网页）；旧记录可能为空。
    var uploadChannel: StravaUploadMode?

    var id: String { fingerprint }

    /// 有可打开的数字远端活动 ID。
    var hasOpenableRemoteId: Bool {
        guard let remoteId else { return false }
        return StravaSpeedAnomaly.isOpenableRemoteId(remoteId)
    }
}

/// 手动补全远端 ID：开始时间差 &lt; 2 分钟即对上，不看距离。
enum SyncRemoteIdBackfill {
    /// 开始时间匹配上限（秒）：严格小于 2 分钟。
    static let maxStartDelta: TimeInterval = 120

    struct RemoteCandidate: Equatable {
        var id: String
        var startDate: Date
    }

    /// 为缺远端 ID 的本地记录配对远端；一对多取 Δt 最小；远端 ID 不重复分配。
    static func assignments(
        locals: [(fingerprint: String, startDate: Date)],
        remotes: [RemoteCandidate],
        occupiedRemoteIds: Set<String>
    ) -> [(fingerprint: String, remoteId: String)] {
        var used = occupiedRemoteIds
        var available = remotes.filter { StravaSpeedAnomaly.isOpenableRemoteId($0.id) && !used.contains($0.id) }
        var result: [(fingerprint: String, remoteId: String)] = []
        let ordered = locals.sorted { $0.startDate < $1.startDate }
        for local in ordered {
            var best: (index: Int, delta: TimeInterval)?
            for (idx, remote) in available.enumerated() {
                let delta = abs(remote.startDate.timeIntervalSince(local.startDate))
                guard delta < maxStartDelta else { continue }
                if best == nil || delta < best!.delta {
                    best = (idx, delta)
                }
            }
            guard let best else { continue }
            let remote = available.remove(at: best.index)
            used.insert(remote.id)
            result.append((local.fingerprint, remote.id))
        }
        return result
    }
}

/// 远端覆盖后的可恢复上传包：删除前落盘，上传成功后清理。
struct PendingResyncUpload: Codable, Equatable {
    var primarySourceId: String
    var primaryActivityId: String
    var title: String
    var startDate: Date
    var endDate: Date
    var supplementSourceIds: [String]
    var distanceMeters: Double?
    var durationSeconds: TimeInterval
    var uploadData: Data
    var uploadMessage: String?
    var filename: String
    var commute: Bool
}

/// 勾选覆盖的本地恢复文件；一条指纹一个受文件保护的原子 JSON 文件。
struct ResyncRecoveryStore {
    private let directoryURL: URL

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directoryURL = base.appendingPathComponent("pending_resync", isDirectory: true)
        }
    }

    func save(_ upload: PendingResyncUpload, fingerprint: String) throws {
        let url = try fileURL(for: fingerprint)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(upload).write(to: url, options: [.atomic, .completeFileProtection])
    }

    func load(fingerprint: String) throws -> PendingResyncUpload? {
        let url = try fileURL(for: fingerprint)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PendingResyncUpload.self, from: Data(contentsOf: url))
    }

    func remove(fingerprint: String) {
        guard let url = try? fileURL(for: fingerprint) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func fileURL(for fingerprint: String) throws -> URL {
        guard !fingerprint.isEmpty, fingerprint.allSatisfy(\.isHexDigit) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return directoryURL.appendingPathComponent("\(fingerprint).json")
    }
}

/// 本地同步状态：保证当天/历史同步幂等，防重复上传。
actor SyncStateStore {
    static let shared = SyncStateStore()

    private var records: [String: SyncStateRecord] = [:]
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("sync_state.json")
        }
        // 启动时加载已有状态。
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([String: SyncStateRecord].self, from: data) {
            records = decoded
        }
    }

    func status(for fingerprint: String) -> SyncRecordStatus? {
        records[fingerprint]?.status
    }

    func isUploaded(_ fingerprint: String) -> Bool {
        records[fingerprint]?.status == .uploaded
    }

    /// 列表徽标 / 跳过历史：`"sourceId|activityId"`，任一 uploaded 即算已同步。
    static func primaryKey(sourceId: String, activityId: String) -> String {
        "\(sourceId)|\(activityId)"
    }

    func uploadedPrimaryKeys() -> Set<String> {
        var keys = Set<String>()
        for record in records.values where record.status == .uploaded {
            guard !record.primarySourceId.isEmpty, !record.primaryActivityId.isEmpty else { continue }
            keys.insert(Self.primaryKey(sourceId: record.primarySourceId, activityId: record.primaryActivityId))
        }
        return keys
    }

    /// 每个本地主活动最近写入的数字远端 ID；不限制状态，列表以本地记录为准展示。
    func localRemoteIdsByPrimaryKey() -> [String: String] {
        var result: [String: String] = [:]
        for record in records.values.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let key = Self.primaryKey(sourceId: record.primarySourceId, activityId: record.primaryActivityId)
            guard result[key] == nil,
                  let remoteId = record.remoteId,
                  StravaSpeedAnomaly.isOpenableRemoteId(remoteId) else { continue }
            result[key] = remoteId
        }
        return result
    }

    func hasUploadedHistory(primarySourceId: String, primaryActivityId: String) -> Bool {
        let key = Self.primaryKey(sourceId: primarySourceId, activityId: primaryActivityId)
        return uploadedPrimaryKeys().contains(key)
    }

    /// 该主活动已上传记录上的数字远端 ID（去重），供异常速度复查。
    func uploadedRemoteIds(primarySourceId: String, primaryActivityId: String) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for record in records.values where record.status == .uploaded
            && record.primarySourceId == primarySourceId
            && record.primaryActivityId == primaryActivityId {
            guard let remote = record.remoteId,
                  StravaSpeedAnomaly.isOpenableRemoteId(remote),
                  seen.insert(remote).inserted else { continue }
            ids.append(remote)
        }
        return ids
    }

    /// 单条指纹对应的数字远端 ID（无则 nil）。
    func uploadedRemoteId(for fingerprint: String) -> String? {
        guard let remote = records[fingerprint]?.remoteId,
              StravaSpeedAnomaly.isOpenableRemoteId(remote) else { return nil }
        return remote
    }

    /// 按更新时间倒序返回全部同步记录，供同步记录页展示。
    func allRecords() -> [SyncStateRecord] {
        records.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 单条记录；勾选重传 / 补全用。
    func record(for fingerprint: String) -> SyncStateRecord? {
        records[fingerprint]
    }

    /// 只写回远端 ID（不改 status）；补全按钮用。
    func setRemoteId(fingerprint: String, remoteId: String) {
        guard var record = records[fingerprint] else { return }
        record.remoteId = remoteId
        record.updatedAt = Date()
        records[fingerprint] = record
        save()
    }

    /// 对本主源缺远端 ID 的记录按开始时间补全；返回成功条数。
    func backfillRemoteIds(
        primarySourceId: String,
        remotes: [SyncRemoteIdBackfill.RemoteCandidate]
    ) -> Int {
        var occupied = Set<String>()
        var locals: [(fingerprint: String, startDate: Date)] = []
        for record in records.values where record.primarySourceId == primarySourceId {
            if record.hasOpenableRemoteId, let id = record.remoteId {
                occupied.insert(id)
                continue
            }
            guard let start = record.startDate else { continue }
            locals.append((record.fingerprint, start))
        }
        let pairs = SyncRemoteIdBackfill.assignments(
            locals: locals,
            remotes: remotes,
            occupiedRemoteIds: occupied
        )
        for pair in pairs {
            setRemoteId(fingerprint: pair.fingerprint, remoteId: pair.remoteId)
        }
        return pairs.count
    }

    /// 删除单条本地幂等记录（不删 Strava 远端）。
    func remove(fingerprint: String) {
        records.removeValue(forKey: fingerprint)
        save()
    }

    /// 清空指定主源的本地幂等记录（不删 Strava 远端、不动其他主源）。
    func removeAll(primarySourceId: String) {
        let keys = records.values
            .filter { $0.primarySourceId == primarySourceId }
            .map(\.fingerprint)
        for key in keys {
            records.removeValue(forKey: key)
        }
        save()
    }

    /// 清空全部本地幂等记录（不删 Strava 远端）。
    func clearAll() {
        records.removeAll()
        save()
    }

    func markPending(
        fingerprint: String,
        primarySourceId: String,
        primaryActivityId: String,
        title: String? = nil,
        startDate: Date? = nil,
        supplementSourceIds: [String]? = nil,
        distanceMeters: Double? = nil,
        durationSeconds: TimeInterval? = nil,
        batchAt: Date? = nil
    ) {
        records[fingerprint] = SyncStateRecord(
            fingerprint: fingerprint,
            status: .pending,
            primarySourceId: primarySourceId,
            primaryActivityId: primaryActivityId,
            remoteId: nil,
            message: nil,
            updatedAt: Date(),
            startDate: startDate,
            title: title,
            supplementSourceIds: supplementSourceIds,
            isDuplicate: nil,
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            batchAt: batchAt,
            uploadChannel: nil
        )
        save()
    }

    func markUploaded(
        fingerprint: String,
        remoteId: String?,
        isDuplicate: Bool = false,
        distanceMeters: Double? = nil,
        durationSeconds: TimeInterval? = nil,
        message: String? = nil,
        uploadChannel: StravaUploadMode? = nil
    ) {
        guard var record = records[fingerprint] else { return }
        record.status = .uploaded
        record.remoteId = remoteId
        record.isDuplicate = isDuplicate
        if isDuplicate {
            record.message = message ?? "去重跳过"
        } else {
            record.message = message
        }
        if let distanceMeters { record.distanceMeters = distanceMeters }
        if let durationSeconds { record.durationSeconds = durationSeconds }
        if let uploadChannel { record.uploadChannel = uploadChannel }
        record.updatedAt = Date()
        records[fingerprint] = record
        save()
    }

    /// 已有 uploaded 记录再次命中去重时：打上去重标与原因（不改远端 ID，除非传入）。
    func markDeduped(
        fingerprint: String,
        reason: String,
        remoteId: String? = nil
    ) {
        guard var record = records[fingerprint] else { return }
        record.status = .uploaded
        record.isDuplicate = true
        record.message = reason
        if let remoteId { record.remoteId = remoteId }
        record.updatedAt = Date()
        records[fingerprint] = record
        save()
    }

    /// 跨主源：已有 uploaded 记录与本次开始+距离近似，则视为同场已传。
    func hasUploadedStable(
        startDate: Date,
        distanceMeters: Double,
        durationSeconds: TimeInterval? = nil
    ) -> Bool {
        uploadedStableMatch(
            startDate: startDate,
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds
        ) != nil
    }

    /// 稳定去重命中时返回那条记录（供复查远端 ID）。
    func uploadedStableMatch(
        startDate: Date,
        distanceMeters: Double,
        durationSeconds: TimeInterval? = nil
    ) -> SyncStateRecord? {
        guard distanceMeters > 0 else { return nil }
        for record in records.values where record.status == .uploaded {
            guard let otherStart = record.startDate,
                  let otherDistance = record.distanceMeters,
                  SyncStableDedupe.matches(
                    startA: startDate,
                    distanceA: distanceMeters,
                    startB: otherStart,
                    distanceB: otherDistance,
                    durationA: durationSeconds,
                    durationB: record.durationSeconds
                  ) else { continue }
            return record
        }
        return nil
    }

    func markFailed(fingerprint: String, message: String) {
        guard var record = records[fingerprint] else {
            records[fingerprint] = SyncStateRecord(
                fingerprint: fingerprint,
                status: .failed,
                primarySourceId: "",
                primaryActivityId: "",
                remoteId: nil,
                message: message,
                updatedAt: Date(),
                startDate: nil,
                title: nil,
                supplementSourceIds: nil,
                isDuplicate: nil,
                distanceMeters: nil,
                durationSeconds: nil,
                batchAt: nil,
                uploadChannel: nil
            )
            save()
            return
        }
        record.status = .failed
        record.message = message
        record.updatedAt = Date()
        records[fingerprint] = record
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
