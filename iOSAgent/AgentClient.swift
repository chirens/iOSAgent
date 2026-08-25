import Foundation
import UIKit

enum AgentError: Error, LocalizedError {
    case missingAPIKey
    case invalidResponse
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "请在设置中填写 API Key"
        case .invalidResponse: return "API 返回异常"
        case .http(let code, let msg): return "HTTP \(code): \(msg)"
        }
    }
}

/// 云端 API 客户端：支持**工具调用循环**（agent 核心）。
/// 与 OpenMinis 用 iSH+CLI 让 LLM 调系统能力不同，这里直接在 Swift 里实现：
/// LLM 决定调用工具 → app 用 EventKit/HealthKit/通知执行 → 结果喂回 LLM → 生成自然语言回复。
@MainActor
final class AgentClient {
    static let shared = AgentClient()
    private let session = URLSession.shared
    private init() {}

    /// 运行 agent 循环：传入完整消息历史，返回更新后的历史 + 最终文本。
    /// image 仅由 ChatView 在新增的 user 消息上携带，此处不再重写历史。
    func run(messages: [StoredMessage], image: UIImage?, tools: [ToolSpec]) async throws
        -> (messages: [StoredMessage], finalText: String) {

        let settings = SettingsStore.shared
        let base = settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = settings.apiKey
        let model = settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !key.isEmpty else { throw AgentError.missingAPIKey }
        guard let url = URL(string: base.trimmingCharacters(in: ["/"]) + "/chat/completions") else {
            throw AgentError.invalidResponse
        }

        var out = messages
        if let image, let jpeg = image.jpegData(compressionQuality: 0.8),
           let lastUserIdx = out.indices.last(where: { out[$0].role == "user" }) {
            out[lastUserIdx].imageBase64 = jpeg.base64EncodedString()
        }

        let toolSchemas = tools.map { $0.schema }
        var finalText = ""

        for _ in 0..<8 {
            let reqMessages = buildAPIMessages(out, includeSystem: !out.contains { $0.role == "system" })
            var body: [String: Any] = [
                "model": model,
                "messages": reqMessages,
                "max_tokens": 2000,
                "temperature": 0.5
            ]
            if !toolSchemas.isEmpty {
                body["tools"] = toolSchemas
                body["tool_choice"] = "auto"
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw AgentError.http(http.statusCode, msg)
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let msg = first["message"] as? [String: Any] else {
                throw AgentError.invalidResponse
            }

            var asst = StoredMessage(role: "assistant", content: msg["content"] as? String ?? "")
            var toolCalls: [StoredToolCall] = []
            if let tcs = msg["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    let id = tc["id"] as? String ?? UUID().uuidString
                    let fn = tc["function"] as? [String: Any]
                    toolCalls.append(StoredToolCall(
                        id: id,
                        name: fn?["name"] as? String ?? "",
                        arguments: fn?["arguments"] as? String ?? "{}"))
                }
            }
            if !toolCalls.isEmpty { asst.toolCalls = toolCalls }
            out.append(asst)

            if toolCalls.isEmpty {
                finalText = asst.content
                break
            }

            // 执行每个工具，并把结果追加为 tool 消息
            for tc in toolCalls {
                let args = parseArgs(tc.arguments)
                let result = await SystemTools.execute(tool: tc.name, call: args)
                let content = toolResultString(result)
                out.append(StoredMessage(role: "tool", content: content,
                                         toolCallId: tc.id, toolName: tc.name))
            }
        }

        if finalText.isEmpty, let last = out.last, last.role == "assistant" {
            finalText = last.content
        }
        return (out, finalText)
    }

    /// 单轮问答（供 App Intents 使用，不挂工具）
    func ask(_ text: String, image: UIImage? = nil) async throws -> String {
        let (_, final) = try await run(messages: [StoredMessage(role: "user", content: text)],
                                       image: image, tools: [])
        return final
    }

    // MARK: - 消息序列化

    private func buildAPIMessages(_ msgs: [StoredMessage], includeSystem: Bool) -> [[String: Any]] {
        var arr: [[String: Any]] = []
        if includeSystem {
            arr.append(["role": "system", "content": systemPrompt()])
        }
        for m in msgs {
            if m.role == "user", let b64 = m.imageBase64 {
                arr.append(["role": "user", "content": [
                    ["type": "text", "text": m.content],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]]
                ]])
            } else if m.role == "assistant", let tcs = m.toolCalls {
                let tca = tcs.map { [
                    "id": $0.id, "type": "function",
                    "function": ["name": $0.name, "arguments": $0.arguments]
                ]}
                var item: [String: Any] = ["role": "assistant", "content": m.content, "tool_calls": tca]
                arr.append(item)
            } else if m.role == "tool" {
                arr.append(["role": "tool", "tool_call_id": m.toolCallId ?? "", "content": m.content])
            } else {
                arr.append(["role": m.role, "content": m.content])
            }
        }
        return arr
    }

    private func parseArgs(_ json: String) -> [String: AnyCodable] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else { return [:] }
        return dict
    }

    private func toolResultString(_ result: ToolResult) -> String {
        var base = result.success ? "[执行成功]" : "[执行失败]"
        base += " \(result.message)"
        if let data = result.data, let dataJson = try? JSONSerialization.data(withJSONObject: data.mapValues { $0.value }, options: .fragmentsAllowed),
           let s = String(data: dataJson, encoding: .utf8) {
            base += "\n数据：\(s)"
        }
        return base
    }

    // MARK: - 系统提示词

    private func systemPrompt() -> String {
        let now = Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss EEEE"
        let nowStr = fmt.string(from: now)

        var enabled: [String] = []
        if SettingsStore.shared.isEnabled("reminders") { enabled.append("提醒事项") }
        if SettingsStore.shared.isEnabled("calendar") { enabled.append("日历") }
        if SettingsStore.shared.isEnabled("health") { enabled.append("健康数据") }
        if SettingsStore.shared.isEnabled("contacts") { enabled.append("通讯录") }
        if SettingsStore.shared.isEnabled("location") { enabled.append("当前位置") }
        if SettingsStore.shared.isEnabled("clipboard") { enabled.append("剪贴板") }
        if SettingsStore.shared.isEnabled("photos") { enabled.append("相册") }
        if SettingsStore.shared.isEnabled("notifications") { enabled.append("闹钟/计时器/本地通知") }
        if SettingsStore.shared.isEnabled("device") { enabled.append("设备信息") }

        let capabilities = enabled.isEmpty ? "（当前未开启任何系统能力，请在设置中开启）" : enabled.joined(separator: "、")

        let custom = SettingsStore.shared.systemPrompt
        let customBlock = custom.isEmpty ? "" : "\n\n用户自定义补充：\(custom)"

        return """
        你是 iOSAgent，一个运行在 iPhone 上的本地 AI 助手。你可以调用系统工具帮用户完成操作。

        当前时间：\(nowStr)
        已开启的系统能力：\(capabilities)

        重要规则：
        1. 当用户请求设置闹钟、提醒、日程、倒计时等时间相关操作时，必须使用对应的工具函数，不要只回答文字。
        2. 对于"5分钟后叫我"这类相对时间，使用 fire_in_minutes/duration_minutes/due_in_minutes；对于"明早9点"这类绝对时间，使用 fire_at/due_at/start_at（ISO8601 格式，如 2026-08-26T09:00:00+08:00）。
        3. "闹钟"和"计时器"使用 set_alarm / set_timer；"提醒事项"App 里的提醒用 create_reminder；"日历"App 里的日程用 create_calendar_event。
        4. 如果用户没有指定标题，根据内容推断一个合适的标题。
        5. 工具执行后，根据结果用一句话向用户确认，不要暴露内部 ID 或 JSON。
        6. 如果某个能力未开启，引导用户到设置页开启，不要重复尝试调用失败工具。

        示例：
        用户：5分钟后提醒我喝水
        → 调用 create_reminder(title="喝水", due_in_minutes=5)

        用户：帮我设个明早7点的闹钟
        → 调用 set_alarm(title="起床闹钟", fire_at="\(formatISODate(now.addingTimeInterval(86400), hour: 7))")

        \(customBlock)
        """
    }

    private func formatISODate(_ date: Date, hour: Int) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        comps.hour = hour
        comps.minute = 0
        return fmt.string(from: Calendar.current.date(from: comps) ?? date)
    }
}

// MARK: - ToolSpec schema 转 OpenAI 可用字典

extension ToolSpec {
    var schema: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}
