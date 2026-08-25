import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var testResult: String?

    var body: some View {
        Form {
            Section("API 配置（云端模式）") {
                TextField("Base URL", text: $settings.baseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API Key", text: $settings.apiKey)
                TextField("模型名称", text: $settings.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("默认 deepseek-chat，需使用支持 function calling 的模型。").font(.caption).foregroundStyle(.secondary)
            }

            Section("连接测试") {
                Button("测试连接") { Task { await testConnection() } }
                if let testResult {
                    Text(testResult).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("系统能力（按需开启）") {
                capabilityRow(title: "提醒事项", desc: "创建 / 列出系统提醒", on: $settings.enableReminders, status: settings.authReminders) {
                    settings.requestReminders()
                }
                capabilityRow(title: "日历", desc: "创建系统日历事件", on: $settings.enableCalendar, status: settings.authCalendar) {
                    settings.requestCalendar()
                }
                capabilityRow(title: "健康数据", desc: "读取步数/心率/睡眠等", on: $settings.enableHealth, status: settings.authHealth) {
                    settings.requestHealth()
                }
                capabilityRow(title: "闹钟 / 本地提醒", desc: "到点弹出通知提醒", on: $settings.enableAlarm, status: settings.authAlarm) {
                    settings.requestAlarm()
                }
                capabilityRow(title: "通讯录", desc: "预留（后续版本）", on: $settings.enableContacts, status: "unused") {
                    // 通讯录暂未接入工具，仅占位
                }
            }

            Section("说明") {
                Text(
"""
iOSAgent 是对标 OpenMinis 的手机端 Agent。Minis 在 App 内跑一个 Alpine Linux(iSH) 并用命令行桥接原生框架；本 App 直接在 Swift 里调用 EventKit / HealthKit / 通知中心，效果一致且更轻。

开启上方开关后，你可以在对话里直接说：
• "明早 8 点提醒我开会" → 写入「提醒事项」
• "周五下午 3 点加个日历会议" → 写入「日历」
• "30 分钟后叫我喝水" → 设置本地提醒
• "我最近一周走了多少步 / 平均心率多少" → 读取健康数据

⚠️ 限制：iOS 第三方 App 无法写入系统「时钟」App 的闹钟，本 App 的"闹钟"以本地通知形式提醒。也**无法**读取其他 App 界面或系统截图，这是 iOS 沙盒的硬墙。
""")
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
    }

    private func capabilityRow(title: String, desc: String, on: Binding<Bool>, status: String, onEnable: @escaping () -> Void) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading) {
                Text(title)
                Text(desc).font(.caption).foregroundStyle(.secondary)
                if status == "granted" {
                    Text("已授权").font(.caption2).foregroundStyle(.green)
                } else if status == "denied" {
                    Text("已拒绝，请在系统设置中允许").font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .onChange(of: on.wrappedValue) { _, nv in if nv { onEnable() } }
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
