import SwiftUI

/// Strava 双模式设置：默认 API，可切网页。
struct StravaSettingsView: View {
    @State private var mode = StravaSettings.mode
    @State private var clientId = StravaSettings.clientId
    @State private var clientSecret = StravaSettings.clientSecret
    @State private var isBusy = false
    @State private var message: String?
    @State private var showWebLogin = false
    @State private var apiReady = false
    @State private var webReady = false

    private let apiUploader = StravaAPIUploader()

    var body: some View {
        Form {
            Section {
                Picker("上传模式", selection: $mode) {
                    ForEach(StravaUploadMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, newValue in
                    StravaSettings.mode = newValue
                }
            } footer: {
                Text("默认 API。日常上传/预检走当前模式；网页模式也会用 Cookie 拉训练列表做远端预检。「覆盖」删远端只用网页 Cookie。通勤标记仅 API 模式生效。")
            }

            Section {
                Toggle("上传前 GCJ-02 → WGS-84", isOn: Binding(
                    get: { StravaSettings.gcjCorrectionEnabled },
                    set: { StravaSettings.gcjCorrectionEnabled = $0 }
                ))
            } footer: {
                Text("默认关闭。顽鹿等国内轨迹在 Strava 偏移时再打开。行者 / 健康一般已是 WGS、通常不必开；开关打开后对所有主源都会转换。")
            }

            if mode == .api {
                Section {
                    TextField("Client ID", text: $clientId)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numberPad)
                    SecureField("Client Secret", text: $clientSecret)
                    Button("保存并授权 Strava") {
                        Task { await authorizeAPI() }
                    }
                    .disabled(isBusy || clientId.isEmpty || clientSecret.isEmpty)
                    Label(apiReady ? "已授权" : "未授权", systemImage: apiReady ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(apiReady ? .green : .secondary)
                } header: {
                    Text("API 凭证")
                } footer: {
                    Text("在 https://www.strava.com/settings/api ：授权回调域填 localhost；网站可填 http://localhost。本 App 回调 healthworkoutexport://localhost/callback。")
                }
            } else {
                Section("网页登录") {
                    Label(webReady ? "已有 Cookie" : "未登录", systemImage: webReady ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(webReady ? .green : .secondary)
                    Button("打开 Strava 登录") { showWebLogin = true }
                    if webReady {
                        Button("清除 Cookie", role: .destructive) {
                            StravaSettings.webCookieHeader = ""
                            webReady = false
                        }
                    }
                }
            }

            if let message {
                Section { Text(message).font(.footnote) }
            }
        }
        .navigationTitle("Strava 设置")
        .task { await refreshReady() }
        .sheet(isPresented: $showWebLogin) {
            StravaWebLoginView {
                showWebLogin = false
                Task { await refreshReady() }
            }
        }
    }

    private func authorizeAPI() async {
        isBusy = true
        message = nil
        defer { isBusy = false }
        StravaSettings.clientId = clientId.trimmingCharacters(in: .whitespaces)
        StravaSettings.clientSecret = clientSecret.trimmingCharacters(in: .whitespaces)
        do {
            // 调用 authorize：Strava OAuth 写入 token。
            try await apiUploader.authorize()
            message = "Strava API 授权成功"
            await refreshReady()
        } catch {
            message = error.localizedDescription
        }
    }

    private func refreshReady() async {
        apiReady = await apiUploader.isReady()
        webReady = await StravaWebUploader().isReady()
    }
}
