import Foundation

struct PreparedSupplement: Sendable {
    var sourceId: String
    var sourceName: String
    var candidate: ActivityMatchCandidate
    var data: Data
}

struct PreparedVirtualPowerResult: Sendable {
    var data: Data
    var filledCount: Int
    var activityDescription: String?
    var notes: [String] = []
}

struct FITProcessingReport: Sendable {
    var mergeReports: [FitSupplementReport]
    var repairedSpeedCount: Int
    var convertedCoordinateCount: Int
    var averageCoordinateDisplacementMeters: Double
    var virtualPowerCount: Int
    var notes: [String]
}

struct FITReuploadMetadata: Sendable {
    var fingerprint: String?
    var remoteId: String?
    var filename: String
}

struct PreparedFIT: Sendable {
    var data: Data
    var originalData: Data
    var originalInspection: FITInspection
    var finalInspection: FITInspection
    var supplementInspections: [(name: String, inspection: FITInspection)]
    var selectedSupplements: [PreparedSupplement]
    var fieldSources: [FITSeriesKind: String]
    var report: FITProcessingReport
    var processingIssues: [FITQualityIssue]
    var activityDescription: String?
    var reuploadMetadata: FITReuploadMetadata?

    var qualityIssues: [FITQualityIssue] {
        originalInspection.issues.filter { $0.severity == .error }
            + finalInspection.issues
            + processingIssues
    }

    var hasErrors: Bool { qualityIssues.contains { $0.severity == .error } }
    var hasWarnings: Bool { qualityIssues.contains { $0.severity == .warning } }
}

enum PreparedFITBuilder {
    typealias VirtualPowerProcessor = @Sendable (Data) async throws -> PreparedVirtualPowerResult

    /// 构建最终上传字节。原始数据只读，所有修改仅发生在重新编码后的上传副本。
    static func build(
        primaryData: Data,
        primaryName: String,
        supplements: [PreparedSupplement],
        gcjEnabled: Bool,
        reuploadMetadata: FITReuploadMetadata? = nil,
        virtualPowerProcessor: VirtualPowerProcessor? = nil
    ) async throws -> PreparedFIT {
        let originalInspection = FITInspector.inspect(primaryData, name: primaryName)
        let supplementInspections = supplements.map {
            (name: $0.sourceName, inspection: FITInspector.inspect($0.data, name: $0.sourceName))
        }
        if originalInspection.hasErrors {
            return PreparedFIT(
                data: primaryData,
                originalData: primaryData,
                originalInspection: originalInspection,
                finalInspection: originalInspection,
                supplementInspections: supplementInspections,
                selectedSupplements: supplements,
                fieldSources: [:],
                report: FITProcessingReport(
                    mergeReports: [],
                    repairedSpeedCount: 0,
                    convertedCoordinateCount: 0,
                    averageCoordinateDisplacementMeters: 0,
                    virtualPowerCount: 0,
                    notes: ["原始 FIT 体检失败，未执行任何改写。"]
                ),
                processingIssues: [],
                activityDescription: nil,
                reuploadMetadata: reuploadMetadata
            )
        }
        var notes: [String] = []
        var mergeResult: FitMergeResult
        if supplements.isEmpty {
            mergeResult = FitMergeResult(data: primaryData, supplements: [])
        } else {
            let inputs = supplements.map { (data: $0.data, name: $0.sourceName) }
            do {
                mergeResult = try FitMerger.mergeWithReport(
                    primary: primaryData,
                    primaryName: primaryName,
                    others: inputs,
                    timeAlign: .automatic,
                    supplementMode: .sensorsOnly
                )
            } catch let automaticError {
                do {
                    let primaryMessages = try FitMerger.decode(primaryData, name: primaryName)
                    let offsets = try inputs.map { input -> Int in
                        let secondary = try FitMerger.decode(input.data, name: input.name)
                        guard let offset = FitMerger.estimateStartOffset(
                            primaryMessages: primaryMessages,
                            secondaryMessages: secondary
                        ) else {
                            throw FitMergeError.alignFailed("无法读取补源起点时间：\(input.name)")
                        }
                        return offset
                    }
                    mergeResult = try FitMerger.mergeWithReport(
                        primary: primaryData,
                        primaryName: primaryName,
                        others: inputs,
                        timeAlign: .perFile(offsets: offsets),
                        supplementMode: .sensorsOnly
                    )
                    notes.append("速度对齐失败，已按活动起点偏移补入传感器。")
                } catch {
                    mergeResult = FitMergeResult(
                        data: primaryData,
                        supplements: inputs.map {
                            FitSupplementReport(name: $0.name, offsetSeconds: 0, filledCounts: [:])
                        }
                    )
                    notes.append("补源对齐失败，已保留原始主源：\(automaticError.localizedDescription)")
                }
            }
        }

        let speedResult = try FitSpeedSpikeFixer.fix(mergeResult.data)
        var finalData = speedResult.data
        var convertedCoordinateCount = 0
        if gcjEnabled {
            let conversion = try FitGcjCoordinateRewriter.rewrite(finalData)
            finalData = conversion.data
            convertedCoordinateCount = conversion.rewrittenCount
        }

        var virtualPowerCount = 0
        var activityDescription: String?
        if let virtualPowerProcessor {
            let result = try await virtualPowerProcessor(finalData)
            finalData = result.data
            virtualPowerCount = result.filledCount
            activityDescription = result.activityDescription
            notes.append(contentsOf: result.notes)
        }

        let finalInspection = FITInspector.inspect(finalData, name: "最终上传 FIT")
        let displacement = averageDisplacementMeters(
            from: originalInspection.coordinates,
            to: finalInspection.coordinates
        )
        let processingIssues = FITInspector.processingIssues(
            original: originalInspection,
            final: finalInspection,
            gcjEnabled: gcjEnabled,
            mergeReports: mergeResult.supplements,
            repairedSpeedCount: speedResult.fixedCount,
            convertedCoordinateCount: convertedCoordinateCount,
            averageCoordinateDisplacementMeters: displacement,
            virtualPowerCount: virtualPowerCount
        )
        let fieldSources = makeFieldSources(
            primaryName: primaryName,
            original: originalInspection,
            final: finalInspection,
            mergeReports: mergeResult.supplements,
            virtualPowerCount: virtualPowerCount
        )

        return PreparedFIT(
            data: finalData,
            originalData: primaryData,
            originalInspection: originalInspection,
            finalInspection: finalInspection,
            supplementInspections: supplementInspections,
            selectedSupplements: supplements,
            fieldSources: fieldSources,
            report: FITProcessingReport(
                mergeReports: mergeResult.supplements,
                repairedSpeedCount: speedResult.fixedCount,
                convertedCoordinateCount: convertedCoordinateCount,
                averageCoordinateDisplacementMeters: displacement,
                virtualPowerCount: virtualPowerCount,
                notes: notes
            ),
            processingIssues: processingIssues,
            activityDescription: activityDescription,
            reuploadMetadata: reuploadMetadata
        )
    }

    private static func makeFieldSources(
        primaryName: String,
        original: FITInspection,
        final: FITInspection,
        mergeReports: [FitSupplementReport],
        virtualPowerCount: Int
    ) -> [FITSeriesKind: String] {
        var result: [FITSeriesKind: String] = [
            .speed: primaryName,
            .altitude: primaryName
        ]
        for (kind, originalCount, field) in [
            (FITSeriesKind.heartRate, original.summary.heartRateCount, FitSensorField.heartRate),
            (.cadence, original.summary.cadenceCount, .cadence),
            (.power, original.summary.powerCount, .power)
        ] {
            if kind == .power, virtualPowerCount > 0 {
                result[kind] = "虚拟功率"
            } else if originalCount > 0 {
                result[kind] = primaryName
            } else if let report = mergeReports.first(where: { $0.filledCounts[field, default: 0] > 0 }) {
                result[kind] = report.name
            } else if !(final.series[kind] ?? []).isEmpty {
                result[kind] = "最终 FIT"
            }
        }
        return result
    }

    private static func averageDisplacementMeters(
        from original: FITCoordinateSnapshot,
        to final: FITCoordinateSnapshot
    ) -> Double {
        guard original.hasSameShape(as: final) else { return 0 }
        var total = 0.0
        var count = 0
        let scale = 2_147_483_648.0 / 180.0
        for (lhs, rhs) in zip(original.values, final.values) {
            guard let lat1 = lhs.latitude, let lon1 = lhs.longitude,
                  let lat2 = rhs.latitude, let lon2 = rhs.longitude,
                  lat1 != lat2 || lon1 != lon2 else { continue }
            let y = (Double(lat2 - lat1) / scale) * 111_320
            let meanLatitude = (Double(lat1) + Double(lat2)) / 2 / scale * .pi / 180
            let x = (Double(lon2 - lon1) / scale) * 111_320 * cos(meanLatitude)
            total += hypot(x, y)
            count += 1
        }
        return count == 0 ? 0 : total / Double(count)
    }
}
