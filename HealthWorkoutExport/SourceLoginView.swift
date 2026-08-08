import SwiftUI

struct SourceLoginView: View {
    let sourceName: String
    let onLogin: (SourceCredentials) async throws -> Void

    @State private var account = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("账号", text: $account)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
            } footer: {
                Text("凭证仅保存在本机 Keychain，不会上传到任何远程服务器。")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await login() }
                } label: {
                    if isBusy {
                        ProgressView()
                    } else {
                        Text("登录\(sourceName)")
                    }
                }
                .disabled(isBusy || account.isEmpty || password.isEmpty)
            }
        }
        .navigationTitle("登录\(sourceName)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func login() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await onLogin(SourceCredentials(account: account, password: password))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
