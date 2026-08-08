import SwiftUI

/// 自定义范围：点按弹出中文年月日滚轮（取消 / 确定）。
struct ChineseWheelDateField: View {
    let title: String
    @Binding var date: Date
    var enabled: Bool = true

    @State private var showPicker = false

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    var body: some View {
        Button {
            guard enabled else { return }
            showPicker = true
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(Self.displayFormatter.string(from: date))
                    .foregroundStyle(enabled ? Color.accentColor : .secondary)
            }
        }
        .disabled(!enabled)
        .sheet(isPresented: $showPicker) {
            ChineseWheelDatePickerSheet(date: $date)
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.hidden)
        }
    }
}

/// 选择日期：年 / 月 / 日滚轮 + 取消 / 确定。
struct ChineseWheelDatePickerSheet: View {
    @Binding var date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Date

    init(date: Binding<Date>) {
        _date = date
        _draft = State(initialValue: date.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("选择日期")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 8)

            DatePicker(
                "",
                selection: $draft,
                displayedComponents: .date
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)

            Divider()
            HStack(spacing: 0) {
                Button("取消") { dismiss() }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.primary)
                    .padding(.vertical, 14)
                Divider().frame(height: 44)
                Button("确定") {
                    date = draft
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(.orange)
                .fontWeight(.semibold)
                .padding(.vertical, 14)
            }
        }
        .background(Color(.systemBackground))
    }
}

struct DateRangePickerView: View {
    @Binding var preset: DateRangePreset
    @Binding var customStart: Date
    @Binding var customEnd: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("时间范围", selection: $preset) {
                ForEach(DateRangePreset.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if preset == .custom {
                ChineseWheelDateField(title: "开始", date: $customStart)
                ChineseWheelDateField(title: "结束", date: $customEnd)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ExportSheetView: View {
    @Bindable var viewModel: ExportViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("格式", selection: $viewModel.exportFormat) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("时区", selection: $viewModel.exportTimeZone) {
                        ForEach(viewModel.timeZoneOptions, id: \.identifier) { zone in
                            Text(ExportTimeZone.displayName(for: zone)).tag(zone)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("选择 JSON 或 FIT 其一导出。时区影响文件名、JSON 日期与 FIT 本地时间。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("进度") {
                    if viewModel.isExporting {
                        ProgressView(value: viewModel.exportProgress.fraction) {
                            Text("正在导出 \(viewModel.exportProgress.completed)/\(viewModel.exportProgress.total)")
                        }
                    } else if viewModel.shareURL != nil {
                        Label("导出完成", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("将导出 \(viewModel.selectedWorkouts.count) 条训练")
                            .foregroundStyle(.secondary)
                    }
                }

                if let shareURL = viewModel.shareURL {
                    Section {
                        ShareLink(item: shareURL) {
                            Label("分享文件", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            // 调用 deleteExportedFile：删掉临时导出文件。
                            viewModel.deleteExportedFile()
                        } label: {
                            Label("删除文件", systemImage: "trash")
                        }
                        .disabled(viewModel.isExporting)
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(viewModel.isExporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.shareURL == nil ? "开始" : "再导出") {
                        Task {
                            // 调用 runExport：执行批量导出并更新进度。
                            await viewModel.runExport()
                        }
                    }
                    .disabled(viewModel.isExporting || viewModel.selectedWorkouts.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(viewModel.isExporting)
    }
}
