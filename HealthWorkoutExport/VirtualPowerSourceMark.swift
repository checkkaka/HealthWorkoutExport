import Foundation
import FITSwiftSDK

/// 虚拟功率来源标记：FIT developer 字段，语义等同 `record.extensions["powerSource"] = "virtual"`。
enum VirtualPowerSourceMark {
    /// developer 字段名，便于解码方按名称识别。
    static let fieldName = "powerSource"
    /// 估算功率的取值。
    static let virtualValue = "virtual"
    /// 本 App 稳定 Application Id（16 字节），跨文件复用便于识别。
    private static let applicationId: [UInt8] = [
        0x48, 0x57, 0x45, 0x56, // HWEV
        0x50, 0x57, 0x52, 0x53, // PWRS
        0x56, 0x49, 0x52, 0x54, // VIRT
        0x50, 0x57, 0x52, 0x01  // PWR + rev
    ]
    /// developer_data_index：本文件内开发者数据槽位。
    private static let developerDataIndex: UInt8 = 0
    /// field_definition_number：powerSource 字段号。
    private static let fieldDefinitionNumber: UInt8 = 0

    struct Bundle {
        var developerDataId: DeveloperDataIdMesg
        var fieldDescription: FieldDescriptionMesg
        var deviceInfo: DeviceInfoMesg
    }

    /// 构造写入 FIT 所需的 DeveloperDataId / FieldDescription / DeviceInfo。
    static func makeBundle(timestamp: DateTime) throws -> Bundle {
        let developerId = DeveloperDataIdMesg()
        try developerId.setDeveloperDataIndex(developerDataIndex)
        try developerId.setApplicationVersion(1)
        for (index, byte) in applicationId.enumerated() {
            try developerId.setApplicationId(index: index, value: byte)
        }

        let fieldDesc = FieldDescriptionMesg()
        try fieldDesc.setDeveloperDataIndex(developerDataIndex)
        try fieldDesc.setFieldDefinitionNumber(fieldDefinitionNumber)
        try fieldDesc.setFitBaseTypeId(.string)
        try fieldDesc.setFieldName(index: 0, value: fieldName)
        try fieldDesc.setUnits(index: 0, value: "enum")
        try fieldDesc.setNativeMesgNum(.record)

        // DeviceInfo：码表侧可见的来源产品名（最多约 20 字符）。
        let deviceInfo = DeviceInfoMesg()
        try deviceInfo.setTimestamp(timestamp)
        try deviceInfo.setDeviceIndex(1)
        try deviceInfo.setManufacturer(Manufacturer.development)
        try deviceInfo.setProduct(2)
        try deviceInfo.setProductName("VirtPower Est")
        try deviceInfo.setSoftwareVersion(1.0)

        return Bundle(
            developerDataId: developerId,
            fieldDescription: fieldDesc,
            deviceInfo: deviceInfo
        )
    }

    /// 给单条 Record 打上 powerSource=virtual（仅用于本次估算写入的秒）。
    static func markRecord(_ record: RecordMesg, bundle: Bundle) throws {
        let field = DeveloperField(
            fieldDescription: bundle.fieldDescription,
            developerDataIdMesg: bundle.developerDataId
        )
        try field.setValue(index: 0, value: virtualValue)
        record.setDeveloperField(field)
    }
}
