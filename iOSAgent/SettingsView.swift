import SwiftUI

/// 设置页：配置云端 API（OpenAI 兼容）。后续可加「端侧模型」开关。
struct SettingsView: View {
    @AppStorage("baseURL") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("model") private var model = "gpt-4o-mini"
    @State private var testResult: String?

    var body: some View {
        Form {
            Section("API 配置（云端模式）") {
                TextField("Base URL", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $apiKey)
                TextField("模型名称", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("连接测试") {
                Button("测试连接") { Task { await testConnection() } }
                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("说明") {
                Text("当前为云端 API 模式，便于快速验证功能。后续可切换为端侧模型（iOS 19 Foundation Models / Core AI）或改为付费模式。API Key 暂存于 AppStorage，正式版请迁移到 Keychain。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
    }

    func testConnection() async {
        do {
            let r = try await AgentClient.shared.ask("ping，请只回复 ok")
            testResult = "成功：\(String(r.prefix(60)))"
        } catch {
            testResult = "失败：\(error.localizedDescription)"
        }
    }
}
