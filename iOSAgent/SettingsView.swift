import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        List {
            Section {
                NavigationLink { APISettingsView() } label: {
                    SettingRow(icon: "key.fill", color: .blue, title: "API 设置", subtitle: "Base URL · 模型 · 连接测试")
                }
                NavigationLink { PermissionsView() } label: {
                    SettingRow(icon: "lock.shield.fill", color: .orange, title: "系统权限", subtitle: "健康 / 提醒 / 日历 / 相册…")
                }
                NavigationLink { CustomPromptView() } label: {
                    SettingRow(icon: "text.quote", color: .purple, title: "自定义系统提示", subtitle: "塑造助手语气与偏好")
                }
            } header: {
                Text("设置")
            }

            Section {
                NavigationLink { AboutView() } label: {
                    SettingRow(icon: "info.circle.fill", color: .gray, title: "关于 iOSAgent", subtitle: "版本与链接")
                }
            }
        }
        .navigationTitle("设置")
        .listStyle(.insetGrouped)
        .scrollContentBackground(.visible)
        .background(Color(.systemGroupedBackground))
    }
}

struct SettingRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - API 设置

struct APISettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
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
            }

            Section {
                if isTesting {
                    HStack { ProgressView(); Spacer() }
                } else if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(testResult.contains("成功") || testResult.contains("OK") ? .green : .red)
                }
                Button("测试连接") { testConnection() }
                    .disabled(isTesting || settings.apiKey.isEmpty)
            } footer: {
                Text("兼容 OpenAI / DeepSeek 等任意 OpenAI 格式接口。")
            }
        }
        .navigationTitle("API 设置")
        .scrollContentBackground(.visible)
        .background(Color(.systemGroupedBackground))
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

// MARK: - 系统权限

struct PermissionsView: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        List {
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

                Button("刷新授权状态") { settings.refreshAuthStatuses() }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("关于健康数据读取", systemImage: "heart.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.pink)
                    Text("健康读取需要 App 以“包含 HealthKit 能力的描述文件”重新签名。免费 Apple ID 的侧载签名通常无法开启 HealthKit 能力，会导致授权失败。若需使用健康数据，请用付费开发者账号（$99/年）签名的描述文件重签本 IPA。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("说明")
            }
        }
        .navigationTitle("系统权限")
        .listStyle(.insetGrouped)
        .scrollContentBackground(.visible)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - 自定义系统提示

struct CustomPromptView: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        VStack(spacing: 0) {
            Text("自定义系统提示会追加在默认提示之后，用于塑造助手的角色、语气与回答偏好。例如：\n“你是一个简洁的中文助手，回答不超过三句话，多用分点。”")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal)
                .padding(.top)

            TextEditor(text: $settings.systemPrompt)
                .font(.body)
                .frame(minHeight: 200)
                .padding(12)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding()
            Spacer(minLength: 0)
        }
        .navigationTitle("自定义系统提示")
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - 关于

struct AboutView: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
                Link(destination: URL(string: "https://chen.cm")!) {
                    HStack {
                        Text("网站")
                        Spacer()
                        Text("https://chen.cm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
                Link(destination: URL(string: "https://github.com/chirens/iOSAgent")!) {
                    HStack {
                        Text("仓库")
                        Spacer()
                        Text("https://github.com/chirens/iOSAgent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
            } header: {
                Text("关于")
            }

            Section {
                Text("iOSAgent · 运行在 iPhone 上的本地 AI 助手")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于")
        .listStyle(.insetGrouped)
        .scrollContentBackground(.visible)
        .background(Color(.systemGroupedBackground))
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "6.0"
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
