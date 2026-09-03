import Foundation
import FITSwiftSDK

/// 虚拟功率来源标记：FIT developer 字段，语义等同 `record.extensions["powerSource"]`。
enum VirtualPowerSourceMark {
    /// developer 字段名。
    static let fieldName = "powerSource"
    /// 估算成功写入功率。
    static let virtualValue = "virtual"
    /// 该秒估算环节失败（仍可能已用扩大邻域均值写入功率）。
    static let failedValue = "failed"
    /// 本 App 稳定 Application Id（16 字节）。
    private static let applicationId: [UInt8] = [
        0x48, 0x57, 0x45, 0x56,
        0x50, 0x57, 0x52, 0x53,
        0x56, 0x49, 0x52, 0x54,
        0x50, 0x57, 0x52, 0x01
    ]
    /// field_definition_number：powerSource。
    private static let fieldDefinitionNumber: UInt8 = 0

    struct Bundle {
        var developerDataId: DeveloperDataIdMesg
        var fieldDescription: FieldDescriptionMesg
    }

    /// 选用未占用的 developer_data_index，避免覆盖 Connect IQ 等已有数据。
    static func makeBundle(messages: FitMessages) throws -> Bundle {
        let developerIndex = nextFreeDeveloperDataIndex(in: messages)

        let developerId = DeveloperDataIdMesg()
        try developerId.setDeveloperDataIndex(developerIndex)
        try developerId.setApplicationVersion(1)
        for (index, byte) in applicationId.enumerated() {
            try developerId.setApplicationId(index: index, value: byte)
        }

        let fieldDesc = FieldDescriptionMesg()
        try fieldDesc.setDeveloperDataIndex(developerIndex)
        try fieldDesc.setFieldDefinitionNumber(fieldDefinitionNumber)
        try fieldDesc.setFitBaseTypeId(.string)
        try fieldDesc.setFieldName(index: 0, value: fieldName)
        try fieldDesc.setUnits(index: 0, value: "enum")
        try fieldDesc.setNativeMesgNum(.record)

        return Bundle(
            developerDataId: developerId,
            fieldDescription: fieldDesc
        )
    }

    /// 给 Record 写入 powerSource（virtual / failed）。
    static func markRecord(_ record: RecordMesg, bundle: Bundle, value: String) throws {
        let field = DeveloperField(
            fieldDescription: bundle.fieldDescription,
            developerDataIdMesg: bundle.developerDataId
        )
        try field.setValue(index: 0, value: value)
        record.setDeveloperField(field)
    }

    /// 读取 Record 上的 powerSource developer 字段；无则 nil。
    static func powerSource(of record: RecordMesg) -> String? {
        record.developerFields
            .first { $0.getName() == fieldName }
            .flatMap { $0.getValue(index: 0) as? String }
    }

    /// FIT 中是否存在至少一秒 `powerSource=virtual`。
    static func containsVirtualMarkedRecord(in messages: FitMessages) -> Bool {
        messages.recordMesgs.contains { powerSource(of: $0) == virtualValue }
    }

    private static func nextFreeDeveloperDataIndex(in messages: FitMessages) -> UInt8 {
        let used = Set(messages.developerDataIdMesgs.compactMap { $0.getDeveloperDataIndex() })
        var index: UInt8 = 0
        while used.contains(index), index < .max {
            index += 1
        }
        return index
    }
}
