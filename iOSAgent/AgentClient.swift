import Foundation
import UIKit

/// 云端 API 客户端：支持**工具调用循环**（agent 核心）。
/// 与 OpenMinis 用 iSH+CLI 让 LLM 调系统能力不同，这里直接在 Swift 里实现：
/// LLM 决定调用工具 → app 用 EventKit/HealthKit/通知执行 → 结果喂回 LLM → 生成自然语言回复。
final class AgentClient {
    static let shared = AgentClient()
    private let session = URLSession.shared
    private init() {}

    /// 运行 agent 循环：传入完整消息历史，返回更新后的历史 + 最终文本。
    /// image 仅由 ChatView 在新增的 user 消息上携带（见 ChatView），此处不再重写历史。
    func run(messages: [StoredMessage], image: UIImage?, tools: [ToolSpec]) async throws
        -> (messages: [StoredMessage], finalText: String) {
        let d = UserDefaults.standard
        let base = (d.string(forKey: "baseURL") ?? "https://api.openai.com/v1").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = d.string(forKey: "apiKey") ?? ""
        let model = (d.string(forKey: "model") ?? "deepseek-chat").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AgentError.missingAPIKey }
        guard let url = URL(string: base.trimmingCharacters(in: ["/"]) + "/chat/completions") else {
            throw AgentError.invalidResponse
        }

        // 仅在本轮新增的 user 消息上附加截图（不污染历史）
        var out = messages
        if let image, let jpeg = image.jpegData(compressionQuality: 0.8),
           let lastUserIdx = out.indices.last(where: { out[$0].role == "user" }) {
            out[lastUserIdx].imageBase64 = jpeg.base64EncodedString()
        }

        let toolSchemas = tools.map { $0.schema }
        var finalText = ""

        for _ in 0..<6 {
            let reqMessages = buildAPIMessages(out, includeSystem: !out.contains { $0.role == "system" })
            var body: [String: Any] = [
                "model": model,
                "messages": reqMessages,
                "max_tokens": 1500,
                "temperature": 0.7
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
            for tc in toolCalls {
                let result = await SystemTools.shared.dispatch(tc.name, arguments: tc.arguments)
                out.append(StoredMessage(role: "tool", content: result,
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
            arr.append(["role": "system", "content": systemPrompt])
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
                ] }
                arr.append(["role": "assistant", "content": m.content, "tool_calls": tca])
            } else if m.role == "tool" {
                arr.append(["role": "tool",
                            "tool_call_id": m.toolCallId ?? "",
                            "name": m.toolName ?? "",
                            "content": m.content])
            } else {
                arr.append(["role": m.role, "content": m.content])
            }
        }
        return arr
    }

    private let systemPrompt = """
    你是一个运行在 iPhone 上的本地 AI 助手 iOSAgent，可以帮助用户操作手机系统功能。
    你具备以下可调用的工具（具体可用哪些由用户在「设置 → 系统能力」中决定）：
    - 创建 / 列出「提醒事项」（EventKit）
    - 创建「日历」事件（EventKit）
    - 设置本地提醒（schedule_alarm，会以本地通知形式在指定时间弹出，**并非**系统「时钟」App 的闹钟）
    - 读取 Apple「健康」数据（步数 / 心率 / 睡眠 / 活动能量 / 体重，HealthKit）
    当用户要求"设置闹钟"时，请使用 schedule_alarm 工具（第三方 App 无法写入系统时钟 App）。
    当用户要求读取健康数据时，使用 read_health 工具，先确认指标与天数。
    请用简洁中文回答，并明确告知用户你已实际执行了什么操作（或为什么做不到）。
    """

    enum AgentError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "请先在「设置」中填写 API Key"
            case .invalidResponse: return "接口返回格式异常"
            case .http(let code, let msg): return "HTTP \(code): \(String(msg.prefix(200)))"
            }
        }
    }
}
