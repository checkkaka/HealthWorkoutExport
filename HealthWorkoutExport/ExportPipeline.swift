import Foundation
import zlib

/// 导出文件格式：JSON 与 FIT 二选一。
enum ExportFormat: String, CaseIterable, Identifiable {
    case json
    case fit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .json: return "JSON"
        case .fit: return "FIT"
        }
    }
}

/// FIT 导出内容：源侧原始文件，或 App 当时实际上传到 Strava 的最终文件。
enum FITExportSource: String, CaseIterable, Identifiable {
    case original
    case strava

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "原始文件"
        case .strava: return "Strava 同步版"
        }
    }
}

/// 导出进度回调。
struct ExportProgress: Sendable {
    let completed: Int
    let total: Int
    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

enum ExportPipelineError: LocalizedError {
    case nothingSelected
    case missingSyncedFIT(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .nothingSelected: return "请先选择要导出的训练"
        case .missingSyncedFIT(let title): return "“\(title)”没有保存 Strava 同步版 FIT，请重新同步一次后再导出"
        case .writeFailed(let message): return message
        }
    }
}

/// 批量拉取明细、写 JSON/FIT、多文件打包 zip。
final class ExportPipeline: Sendable {
    private let healthKit: HealthKitService

    init(healthKit: HealthKitService) {
        self.healthKit = healthKit
    }

    /// 本工具在临时目录下的固定前缀，用于识别并清理历史导出残留。
    private static let tempDirPrefix = "HealthWorkoutExport-"

    /// 导出选中训练到临时目录，返回可分享的文件 URL（单文件或 zip）。
    func export(
        summaries: [WorkoutSummary],
        format: ExportFormat,
        timeZone: TimeZone,
        syncedFITURLs: [String: URL] = [:],
        progress: @MainActor @escaping (ExportProgress) -> Void
    ) async throws -> URL {
        guard !summaries.isEmpty else { throw ExportPipelineError.nothingSelected }

        // 调用 cleanupOldExports：删除上次导出的残留目录，避免临时空间无限累积。
        Self.cleanupOldExports()

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.tempDirPrefix + UUID().uuidString, isDirectory: true)
        // 调用 FileManager：创建本次导出的临时目录。
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let total = summaries.count
        var completed = 0

        await progress(ExportProgress(completed: 0, total: total))

        // 有限并发拉取明细，避免 HealthKit 过载。
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = summaries.makeIterator()
            let limit = HealthKitService.detailConcurrencyLimit

            func enqueueNext() {
                guard let summary = iterator.next() else { return }
                group.addTask { [healthKit] in
                    if format == .fit, let sourceURL = syncedFITURLs[summary.id.uuidString] {
                        let destination = workDir.appendingPathComponent(
                            Self.fileBaseName(summary: summary, timeZone: timeZone) + ".fit"
                        )
                        try FileManager.default.copyItem(at: sourceURL, to: destination)
                        return
                    }
                    // 调用 fetchWorkoutBundle：拉取该次训练的完整样本与路线。
                    let bundle = try await healthKit.fetchWorkoutBundle(for: summary)
                    // 调用 writeBundle：按所选格式落盘。
                    try Self.writeBundle(bundle, to: workDir, format: format, timeZone: timeZone)
                }
            }

            for _ in 0..<min(limit, summaries.count) {
                enqueueNext()
            }

            for try await _ in group {
                completed += 1
                await progress(ExportProgress(completed: completed, total: total))
                enqueueNext()
            }
        }

        // 调用 collectExportURL：单文件直接分享，多文件打 zip。
        return try Self.collectExportURL(workDir: workDir, format: format)
    }

    /// 导出行者/顽鹿等源活动：FIT 拉原始文件；JSON 写活动摘要（无 Health 明细序列）。
    func export(
        activities: [SourceActivity],
        source: any WorkoutDataSource,
        format: ExportFormat,
        timeZone: TimeZone,
        syncedFITURLs: [String: URL] = [:],
        progress: @MainActor @escaping (ExportProgress) -> Void
    ) async throws -> URL {
        guard !activities.isEmpty else { throw ExportPipelineError.nothingSelected }

        // 调用 cleanupOldExports：清理历史临时导出目录。
        Self.cleanupOldExports()

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.tempDirPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let total = activities.count
        var completed = 0
        await progress(ExportProgress(completed: 0, total: total))

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = activities.makeIterator()
            let limit = HealthKitService.detailConcurrencyLimit

            func enqueueNext() {
                guard let activity = iterator.next() else { return }
                group.addTask {
                    switch format {
                    case .fit:
                        let name = Self.fileBaseName(activity: activity, timeZone: timeZone) + ".fit"
                        let destination = workDir.appendingPathComponent(name)
                        if let sourceURL = syncedFITURLs[activity.id] {
                            try FileManager.default.copyItem(at: sourceURL, to: destination)
                        } else {
                            // 调用 fetchFitData：下载源侧原始 FIT。
                            let data = try await source.fetchFitData(for: activity)
                            try data.write(to: destination, options: .atomic)
                        }
                    case .json:
                        // 第三方源无 Health 明细，JSON 仅导出活动摘要。
                        try Self.writeSourceActivityJSON(
                            activity,
                            to: workDir,
                            timeZone: timeZone
                        )
                    }
                }
            }

            for _ in 0..<min(limit, activities.count) {
                enqueueNext()
            }
            for try await _ in group {
                completed += 1
                await progress(ExportProgress(completed: completed, total: total))
                enqueueNext()
            }
        }

        return try Self.collectExportURL(workDir: workDir, format: format)
    }

    private static func collectExportURL(workDir: URL, format: ExportFormat) throws -> URL {
        let allFiles = try FileManager.default.contentsOfDirectory(
            at: workDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == format.rawValue }

        if allFiles.count == 1 {
            return allFiles[0]
        }

        let zipURL = workDir.appendingPathComponent("workouts_export.zip")
        // 调用 zipFiles：多文件打成 zip 便于系统分享。
        try ZipWriter.zip(files: allFiles, to: zipURL)
        return zipURL
    }

    private static func fileBaseName(activity: SourceActivity, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let stamp = formatter.string(from: activity.startDate)
        let typeToken = activity.title
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let idToken = String(activity.id.prefix(8))
        return "\(stamp)_\(typeToken)_\(idToken)"
    }

    private static func fileBaseName(summary: WorkoutSummary, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let stamp = formatter.string(from: summary.startDate)
        let typeToken = summary.activityName.replacingOccurrences(of: " ", with: "_")
        return "\(stamp)_\(typeToken)_\(summary.uuid.uuidString.prefix(8))"
    }

    private static func writeSourceActivityJSON(
        _ activity: SourceActivity,
        to directory: URL,
        timeZone: TimeZone
    ) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = timeZone
        let object: [String: Any] = [
            "id": activity.id,
            "sourceId": activity.sourceId,
            "title": activity.title,
            "startDate": iso.string(from: activity.startDate),
            "endDate": iso.string(from: activity.endDate),
            "durationSeconds": activity.duration,
            "totalDistanceMeters": activity.distanceMeters as Any,
            "metadata": activity.metadata,
            "note": "第三方源 JSON 仅为活动摘要；完整轨迹请导出 FIT。"
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let url = directory.appendingPathComponent(fileBaseName(activity: activity, timeZone: timeZone) + ".json")
        try data.write(to: url, options: .atomic)
    }

    private static func writeBundle(_ bundle: WorkoutBundle, to directory: URL, format: ExportFormat, timeZone: TimeZone) throws {
        let base = fileBaseName(summary: bundle.summary, timeZone: timeZone)

        switch format {
        case .json:
            let jsonURL = directory.appendingPathComponent("\(base).json")
            let jsonObject = bundle.jsonObject(timeZone: timeZone)
            let jsonData = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: jsonURL, options: .atomic)
        case .fit:
            // 调用 FitActivityEncoder：生成 Garmin FIT（本地时间戳按所选时区）。
            let fitData = try FitActivityEncoder.encode(bundle, timeZone: timeZone)
            let fitURL = directory.appendingPathComponent("\(base).fit")
            try fitData.write(to: fitURL, options: .atomic)
        }
    }

    /// 删除历史导出留下的临时目录。
    /// 跳过合并面板的产物目录（HealthWorkoutExport-Merge-*），
    /// 避免导出时误删用户尚未分享的合并结果。
    private static func cleanupOldExports() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(tempDirPrefix)
            && !entry.lastPathComponent.hasPrefix("\(tempDirPrefix)Merge-") {
            try? fm.removeItem(at: entry)
        }
    }
}

/// 极简 zip 写入（Stored，无压缩），足够分享多文件。
enum ZipWriter {
    static func zip(files: [URL], to destination: URL) throws {
        var centralDirectory: Data = Data()
        var localFiles: Data = Data()
        var offset: UInt32 = 0
        var entries: UInt16 = 0

        let (dosTime, dosDate) = dosDateTime(from: Date())

        for file in files {
            let name = file.lastPathComponent
            let nameData = Data(name.utf8)
            let fileData = try Data(contentsOf: file)
            let crc = crc32(0, fileData)
            let size = UInt32(fileData.count)

            var local = Data()
            local.append(contentsOf: UInt32(0x04034b50).leBytes)
            local.append(contentsOf: UInt16(20).leBytes) // version
            local.append(contentsOf: UInt16(0).leBytes) // flags
            local.append(contentsOf: UInt16(0).leBytes) // method store
            local.append(contentsOf: dosTime.leBytes)
            local.append(contentsOf: dosDate.leBytes)
            local.append(contentsOf: crc.leBytes)
            local.append(contentsOf: size.leBytes)
            local.append(contentsOf: size.leBytes)
            local.append(contentsOf: UInt16(nameData.count).leBytes)
            local.append(contentsOf: UInt16(0).leBytes) // extra
            local.append(nameData)
            local.append(fileData)

            var central = Data()
            central.append(contentsOf: UInt32(0x02014b50).leBytes)
            central.append(contentsOf: UInt16(20).leBytes)
            central.append(contentsOf: UInt16(20).leBytes)
            central.append(contentsOf: UInt16(0).leBytes)
            central.append(contentsOf: UInt16(0).leBytes)
            central.append(contentsOf: dosTime.leBytes)
            central.append(contentsOf: dosDate.leBytes)
            central.append(contentsOf: crc.leBytes)
            central.append(contentsOf: size.leBytes)
            central.append(contentsOf: size.leBytes)
            central.append(contentsOf: UInt16(nameData.count).leBytes)
            central.append(contentsOf: UInt16(0).leBytes)
            central.append(contentsOf: UInt16(0).leBytes)
            central.append(contentsOf: UInt16(0).leBytes)
            central.append(contentsOf: UInt16(0).leBytes)
            central.append(contentsOf: UInt32(0).leBytes)
            central.append(contentsOf: offset.leBytes)
            central.append(nameData)

            offset += UInt32(local.count)
            localFiles.append(local)
            centralDirectory.append(central)
            entries += 1
        }

        var end = Data()
        end.append(contentsOf: UInt32(0x06054b50).leBytes)
        end.append(contentsOf: UInt16(0).leBytes)
        end.append(contentsOf: UInt16(0).leBytes)
        end.append(contentsOf: entries.leBytes)
        end.append(contentsOf: entries.leBytes)
        end.append(contentsOf: UInt32(centralDirectory.count).leBytes)
        end.append(contentsOf: UInt32(localFiles.count).leBytes)
        end.append(contentsOf: UInt16(0).leBytes)

        var zip = Data()
        zip.append(localFiles)
        zip.append(centralDirectory)
        zip.append(end)
        try zip.write(to: destination, options: .atomic)
    }

    /// 转 MS-DOS 时间/日期格式（zip 条目时间戳，2 秒精度）。
    private static func dosDateTime(from date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max((c.year ?? 1980) - 1980, 0)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let dosDate = UInt16(year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, dosDate)
    }

    private static func crc32(_ seed: UInt32, _ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            let ptr = buffer.bindMemory(to: UInt8.self).baseAddress
            return UInt32(zlib.crc32(uLong(seed), ptr, uInt(data.count)))
        }
    }
}

private extension FixedWidthInteger {
    var leBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian, Array.init)
    }
}
