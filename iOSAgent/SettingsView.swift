import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            Form {
                apiSection
                capabilitiesSection
                customPromptSection
                aboutSection
            }
            .navigationTitle("设置")
            .scrollContentBackground(.visible)
            .background(Color(.systemGroupedBackground))
        }
    }

    private var apiSection: some View {
        Section("API 配置") {
            TextField("Base URL", text: $settings.apiBaseURL)
                .autocapitalization(.none)
                .keyboardType(.URL)
            SecureField("API Key", text: $settings.apiKey)
                .autocapitalization(.none)
            TextField("模型名", text: $settings.modelName)
                .autocapitalization(.none)
            TextField("语音模型（默认 whisper-1）", text: $settings.sttModelName)
                .autocapitalization(.none)

            HStack {
                Spacer()
                if isTesting {
                    ProgressView()
                } else if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(testResult.contains("成功") || testResult.contains("OK") ? .green : .red)
                }
                Button("测试连接") {
                    testConnection()
                }
                .disabled(isTesting || settings.apiKey.isEmpty)
            }
        }
    }

    private var capabilitiesSection: some View {
        Section(header: Text("系统能力"), footer: Text("开启后可在对话中说“5分钟后叫我”“帮我设个明天9点的提醒”等。每项首次开启时会请求系统授权。")) {
            CapabilityToggleRow(key: "notifications", icon: "alarm.fill", color: .orange, title: "闹钟 / 计时器", subtitle: "本地通知，到点响铃")
            CapabilityToggleRow(key: "reminders", icon: "checkmark.square.fill", color: .blue, title: "提醒事项", subtitle: "读写系统提醒事项")
            CapabilityToggleRow(key: "calendar", icon: "calendar.badge.plus", color: .red, title: "日历", subtitle: "读写系统日历")
            CapabilityToggleRow(key: "health", icon: "heart.fill", color: .pink, title: "健康", subtitle: "读取步数/心率/睡眠等")
            CapabilityToggleRow(key: "contacts", icon: "person.2.fill", color: .green, title: "通讯录", subtitle: "搜索联系人")
            CapabilityToggleRow(key: "location", icon: "location.fill", color: .indigo, title: "位置", subtitle: "获取当前位置")
            CapabilityToggleRow(key: "clipboard", icon: "doc.on.clipboard", color: .yellow, title: "剪贴板", subtitle: "读取/写入剪贴板")
            CapabilityToggleRow(key: "photos", icon: "photo.fill", color: .purple, title: "相册", subtitle: "枚举最近照片")
            CapabilityToggleRow(key: "device", icon: "iphone", color: .gray, title: "设备信息", subtitle: "型号/电量/系统版本")

            Button("刷新授权状态") {
                settings.refreshAuthStatuses()
            }
        }
    }

    private var customPromptSection: some View {
        Section(header: Text("自定义系统提示"), footer: Text("会追加在默认系统提示之后。")) {
            TextEditor(text: $settings.systemPrompt)
                .frame(minHeight: 80)
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text("5.0")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("仓库")
                Spacer()
                Text("github.com/chirens/iOSAgent")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        Task {
            do {
                _ = try await AgentClient.shared.ask("hello")
                testResult = "连接成功 / OK"
            } catch {
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}

struct CapabilityToggleRow: View {
    @EnvironmentObject var settings: SettingsStore
    let key: String
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle + " · " + settings.status(key).rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { settings.isEnabled(key) },
                set: { newValue in
                    settings.setEnabled(key, newValue)
                    if newValue {
                        Task {
                            let status = await settings.requestAuth(for: key)
                            if status != .authorized && status != .limited {
                                settings.setEnabled(key, false)
                            }
                        }
                    }
                }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}
