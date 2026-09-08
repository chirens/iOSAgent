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
    /// 长超时 session：解决真实对话因首 token 延迟或工具链较长导致的 timeout。
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()
    private init() {}

    /// 运行 agent 循环：传入完整消息历史，返回更新后的历史 + 最终文本。
    /// image 仅由 ChatView 在新增的 user 消息上携带，此处不再重写历史。
    /// onUpdate 在流式生成和工具执行过程中被多次调用，用于实时刷新 UI。
    /// 若当前模型失败，会自动按配置顺序尝试其他 profile 一次（模型降级）。
    func run(messages: [StoredMessage], image: UIImage?, tools: [ToolSpec], activeSkills: [Skill] = [],
             onUpdate: @MainActor @escaping ([StoredMessage]) -> Void = { _ in }) async throws
        -> (messages: [StoredMessage], finalText: String) {

        let settings = SettingsStore.shared
        var candidates = [settings.activeProfile]
        candidates.append(contentsOf: settings.profiles.filter { $0.id != settings.activeProfileID })
        // 去重（理论上不会重复，但防御）
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0.id).inserted }

        var lastError: Error?
        for profile in candidates {
            do {
                var result = try await runOnce(messages: messages, image: image, tools: tools,
                                               activeSkills: activeSkills, profile: profile,
                                               onUpdate: onUpdate)
                // 如果发生过降级，在最终文本里轻量提示
                if profile.id != settings.activeProfileID, !result.finalText.isEmpty {
                    let note = "[已自动切换至 \(profile.name) / \(profile.modelName)]\n"
                    result.finalText = note + result.finalText
                    if let idx = result.messages.indices.last, result.messages[idx].role == "assistant" {
                        result.messages[idx].content = note + result.messages[idx].content
                    }
                }
                return result
            } catch {
                lastError = error
                // 继续尝试下一个 profile
            }
        }
        throw lastError ?? AgentError.invalidResponse
    }

    private func runOnce(messages: [StoredMessage], image: UIImage?, tools: [ToolSpec], activeSkills: [Skill],
                         profile: APIProfile,
                         onUpdate: @MainActor @escaping ([StoredMessage]) -> Void) async throws
        -> (messages: [StoredMessage], finalText: String) {

        let base = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = profile.apiKey
        let model = profile.modelName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !key.isEmpty else { throw AgentError.missingAPIKey }
        guard let url = URL(string: base.trimmingCharacters(in: ["/"]) + "/chat/completions") else {
            throw AgentError.invalidResponse
        }

        var out = messages
        if let image, let jpeg = prepareImageData(image),
           let lastUserIdx = out.indices.last(where: { out[$0].role == "user" }) {
            out[lastUserIdx].imageBase64 = jpeg
        }

        let toolSchemas = tools.map { $0.schema }
        var finalText = ""

        for _ in 0..<8 {
            let reqMessages = buildAPIMessages(out, includeSystem: !out.contains { $0.role == "system" }, activeSkills: activeSkills)
            let lowerModel = model.lowercased()
            let isReasoning = lowerModel.contains("kimi-k3") || lowerModel.contains("kimi-k2")
                || lowerModel.contains("deepseek-r1") || lowerModel.contains("deepseek-reasoner")
                || lowerModel.hasPrefix("o1") || lowerModel.hasPrefix("o3") || lowerModel.hasPrefix("o4")
                || lowerModel.contains("qwq") || lowerModel.contains("reasoning") || lowerModel.contains("-thinking")
            var body: [String: Any] = [
                "model": model,
                "messages": reqMessages,
                "stream": true,
                "stream_options": ["include_usage": false]
            ]
            if isReasoning {
                body["max_completion_tokens"] = 8000
            } else {
                body["max_tokens"] = 2000
                body["temperature"] = 0.5
            }
            if !toolSchemas.isEmpty {
                body["tools"] = toolSchemas
                body["tool_choice"] = "auto"
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (stream, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                var data = Data()
                for try await byte in stream { data.append(byte) }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(code)"
                throw AgentError.http(code, msg)
            }

            let skillNames = activeSkills.map(\.name).joined(separator: "、")
            var streamingMsg = StoredMessage(role: "assistant", content: "", isStreaming: true,
                                             status: skillNames.isEmpty ? "模型思考中…" : "使用技能：\(skillNames)")
            out.append(streamingMsg)
            await onUpdate(out)

            let (updatedMsg, toolCalls) = try await consumeStream(stream: stream, msg: &streamingMsg, out: &out, onUpdate: onUpdate)
            streamingMsg = updatedMsg

            if toolCalls.isEmpty {
                streamingMsg.isStreaming = false
                streamingMsg.status = nil
                out[out.count - 1] = streamingMsg
                finalText = streamingMsg.content
                await onUpdate(out)
                break
            }

            // 执行每个工具，并把结果追加为 tool 消息
            streamingMsg.isStreaming = false
            streamingMsg.status = nil
            out[out.count - 1] = streamingMsg
            await onUpdate(out)

            for tc in toolCalls {
                if let lastIdx = out.indices.last {
                    out[lastIdx].status = statusForExecutingTool(tc.name)
                    await onUpdate(out)
                }
                let args = parseArgs(tc.arguments)
                let result = await SystemTools.execute(tool: tc.name, call: args)
                let content = toolResultString(result)
                out.append(StoredMessage(role: "tool", content: content,
                                         toolCallId: tc.id, toolName: tc.name,
                                         fileURL: result.fileURL))
                await onUpdate(out)
            }

            // 工具执行完毕：清除“工具调用指令”类 assistant 消息的 status，避免心跳占位残留到最终结果之后
            for idx in out.indices where out[idx].role == "assistant" && out[idx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out[idx].status = nil
            }
            await onUpdate(out)
        }

        // 最终收尾：清除所有 assistant 消息的流式/心跳状态，避免对话结束后残留「执行：xxx」菊花占位；
        // 并移除纯占位空消息（无内容、无工具调用、无文件），它们只是流式过程中的临时气泡。
        for idx in out.indices where out[idx].role == "assistant" {
            out[idx].isStreaming = false
            out[idx].status = nil
        }
        out.removeAll { m in
            m.role == "assistant"
                && m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (m.toolCalls ?? []).isEmpty
                && m.fileURL == nil
        }

        if finalText.isEmpty, let last = out.last, last.role == "assistant" {
            finalText = last.content
        }

        // 防护：8 轮工具循环跑完仍没有 assistant 最终回复（流中断 / 模型在工具后未继续生成），
        // 但最后一条是 tool 消息且生成了文件（生图/PPT/语音等），自动合成一条"已生成文件"的最终回复，
        // 避免用户看到"已生成文件但没文字说明"的诡异状态。
        if finalText.isEmpty, let last = out.last, last.role == "tool", let url = last.fileURL {
            let synthesized = StoredMessage(role: "assistant", content: "已生成文件：\(url.lastPathComponent)，可点击上方的「打开文件」查看或分享。")
            out.append(synthesized)
            finalText = synthesized.content
        }

        // 终极防护：跑了 8 轮模型仍未输出任何文字（含生图失败 / LLM 直接被掐断 / token 失效 / 解析异常等所有原因）。
        // 给一句人话兜底，让用户至少知道发生了什么，而不是面对空白的对话。
        if finalText.isEmpty {
            // 找出最近一条 tool 消息，把它的成功/失败状态拼成人话，比纯"网络异常"更具体
            let lastTool = out.last(where: { $0.role == "tool" })
            let reason: String
            if let t = lastTool {
                let s = t.content
                if s.contains("执行失败") {
                    // 截一段让人能看懂的
                    let snippet = String(s.prefix(140))
                    reason = "工具未成功：\(snippet)"
                } else if t.fileURL != nil {
                    reason = "已生成文件但模型未能给出文字说明。请尝试再发一条或换种说法。"
                } else {
                    reason = "工具已返回结果，但模型未能继续生成文字回复。请再试一次。"
                }
            } else {
                reason = "模型未返回任何内容。可能原因：API key 失效、网络中断、或服务端临时不可用。"
            }
            let fallback = StoredMessage(role: "assistant", content: "（Velos：\(reason)）")
            out.append(fallback)
            finalText = fallback.content
        }

        return (out, finalText)
    }

    /// 压缩 / 缩放图片，避免 base64 过大导致超时或请求失败。
    private func prepareImageData(_ image: UIImage?) -> String? {
        guard let image = image else { return nil }
        let maxSide: CGFloat = 1024
        let scale = min(1.0, min(maxSide / image.size.width, maxSide / image.size.height))
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        guard let jpeg = (resized ?? image).jpegData(compressionQuality: 0.7) else { return nil }
        return jpeg.base64EncodedString()
    }

    /// 解析 SSE 流，返回（最终 assistant 消息，工具调用列表）。
    private func consumeStream(stream: URLSession.AsyncBytes,
                               msg: inout StoredMessage,
                               out: inout [StoredMessage],
                               onUpdate: @MainActor @escaping ([StoredMessage]) -> Void) async throws -> (StoredMessage, [StoredToolCall]) {
        var accumulated: [Int: StoredToolCall] = [:]

        for try await line in stream.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("event:") || trimmed.hasPrefix(":") { continue }
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first else { continue }

            if let delta = first["delta"] as? [String: Any] {
                if let content = delta["content"] as? String {
                    msg.content += content
                    if msg.status != "正在生成回复" { msg.status = "正在生成回复" }
                }
                if let tcs = delta["tool_calls"] as? [[String: Any]] {
                    for tc in tcs {
                        let idx = tc["index"] as? Int ?? 0
                        var call = accumulated[idx] ?? StoredToolCall(id: "", name: "", arguments: "")
                        if let id = tc["id"] as? String, !id.isEmpty { call.id = id }
                        if let fn = tc["function"] as? [String: Any] {
                            if let name = fn["name"] as? String { call.name += name }
                            if let args = fn["arguments"] as? String { call.arguments += args }
                        }
                        accumulated[idx] = call
                    }
                    let names = accumulated.values.map { $0.name }.filter { !$0.isEmpty }
                    msg.status = statusForToolCalls(names)
                }
            }

            if let finish = first["finish_reason"] as? String {
                if finish == "tool_calls" {
                    msg.toolCalls = Array(accumulated.sorted { $0.key < $1.key }.map { $0.value })
                    msg.status = statusForToolCalls(msg.toolCalls?.map { $0.name } ?? [])
                } else if finish == "stop" || finish == "length" {
                    msg.isStreaming = false
                    msg.status = nil
                }
            }

            if let lastIdx = out.indices.last {
                out[lastIdx] = msg
            }
            await onUpdate(out)

            if msg.toolCalls != nil || !msg.isStreaming { break }
        }

        let calls = Array(accumulated.sorted { $0.key < $1.key }.map { $0.value })
        return (msg, calls)
    }

    /// 根据工具名返回更友好的流式状态文字
    private func statusForToolCalls(_ names: [String]) -> String {
        let clean = names.filter { !$0.isEmpty }
        if clean.isEmpty { return "正在规划工具…" }
        if clean.contains("generate_image") { return "生图API调用中…" }
        if clean.contains("generate_speech") { return "语音API调用中…" }
        if clean.contains("generate_video") { return "视频API调用中…" }
        return "正在调用：\(clean.joined(separator: "、"))…"
    }

    /// 工具实际执行阶段的状态文字（比"执行：xxx"更具体）
    private func statusForExecutingTool(_ name: String) -> String {
        switch name {
        case "generate_image": return "服务器正在生成图片…"
        case "generate_speech": return "服务器正在合成语音…"
        case "generate_video": return "服务器正在渲染视频…"
        case "check_video": return "正在查询视频状态…"
        default: return "执行：\(name)…"
        }
    }

    /// 单轮问答（供 App Intents 使用，不挂工具）
    func ask(_ text: String, image: UIImage? = nil) async throws -> String {
        let (_, final) = try await run(messages: [StoredMessage(role: "user", content: text)],
                                       image: image, tools: [])
        return final
    }

    /// 直接测试一组草稿配置（不改动当前激活配置/已保存列表）
    func testConnection(baseURL: String, apiKey: String, model: String) async throws -> String {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: ["/"])
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.missingAPIKey
        }
        guard let url = URL(string: base + "/chat/completions") else {
            throw AgentError.invalidResponse
        }
        let body: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-4o-mini" : model,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 8
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AgentError.http(http.statusCode, msg)
        }
        return "连接成功 / OK"
    }

    /// 语音转文字：调用 OpenAI 兼容的 /audio/transcriptions
    func transcribe(audioURL: URL) async throws -> String {
        let settings = SettingsStore.shared
        let profile = settings.activeProfile
        let base = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = profile.apiKey
        let model = profile.sttModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AgentError.missingAPIKey }
        guard let url = URL(string: base + "/audio/transcriptions") else {
            throw AgentError.invalidResponse
        }

        let boundary = UUID().uuidString
        var body = Data()
        func append(_ string: String) {
            body.append(string.data(using: .utf8) ?? Data())
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n")
        append("Content-Type: audio/m4a\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AgentError.http(http.statusCode, msg)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            throw AgentError.invalidResponse
        }
        return text
    }

    // MARK: - 消息序列化

    private func buildAPIMessages(_ msgs: [StoredMessage], includeSystem: Bool, activeSkills: [Skill] = []) -> [[String: Any]] {
        var arr: [[String: Any]] = []
        if includeSystem {
            arr.append(["role": "system", "content": systemPrompt(activeSkills: activeSkills)])
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
        base += " \(cleanToolMessage(result.message))"
        // 生成文件类工具的数据仅包含内部路径，不要展示给用户；其它工具结果仍保留结构化数据供模型参考。
        // 【v9.0.7 修复】原用 JSONSerialization 直接序列化 [String: Any]（unwrap AnyCodable.value 后的字典）。
        // 如果 data 内含嵌套数组/字典（list_events / list_reminders 返回 [[String: AnyCodable]]），
        // AnyCodable 是 Swift 结构体，桥到 NSObject 后是 __SwiftValue，JSONSerialization 拒收并抛
        // NSInvalidArgumentException "Invalid type in JSON write (__SwiftValue)" —— 整个 App 闪退。
        // 改用 JSONEncoder：AnyCodable 自己实现了 encode(to:)，会递归把 [String: Any] / [Any]
        // 拆成 [String: AnyCodable] / [AnyCodable] 再编码，彻底避开 __SwiftValue。
        if result.fileURL == nil, let data = result.data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            if let jsonData = try? encoder.encode(data),
               let s = String(data: jsonData, encoding: .utf8) {
                base += "\n数据：\(s)"
            }
        }
        return base
    }

    /// 清洗工具返回的原始错误字符串：去掉 JSON 转义、提取可读的 message/error，避免把未解析编码抛给用户
    private func cleanToolMessage(_ raw: String) -> String {
        // 1. 先做一次反 JSON-escape
        var s = raw
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\r", with: " ")
            .replacingOccurrences(of: "\\t", with: " ")
            .replacingOccurrences(of: "\\/", with: "/")

        // 2. 如果字符串里还残留嵌套 JSON，尝试提取最内层的 message / error
        if let inner = extractInnerErrorMessage(s) {
            s = inner
        }

        // 3. 压平多余空白
        let comp = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        s = comp

        // 4. 截断，防止超长噪声刷屏
        if s.count > 360 {
            s = String(s.prefix(360)) + "…"
        }
        return s
    }

    private func extractInnerErrorMessage(_ text: String) -> String? {
        // 从 "message": "..." 或 "error": "..." 中提取最内层文本
        let pattern = "\"(?:message|error|detail)\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        var best: String?
        for m in matches {
            if let r = Range(m.range(at: 1), in: text) {
                let candidate = String(text[r])
                if candidate.count > (best?.count ?? 0) {
                    best = candidate
                }
            }
        }
        return best
    }

    // MARK: - 系统提示词

    private func systemPrompt(activeSkills: [Skill] = []) -> String {
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
        let skillBlock = buildSkillBlock(activeSkills)
        let memoryBlock = memoryBlock()

        let connectorEP = SettingsStore.shared.connectorEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let connectorBlock: String
        if connectorEP.isEmpty {
            connectorBlock = ""
        } else {
            let loggedIn = !SettingsStore.shared.authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let authNote = loggedIn
                ? "用户已登录，鉴权由 App 自动附加到该服务器的请求，你无需也不会手动添加 Authorization 头。"
                : "若用户尚未登录，提示其在设置→账户里登录；登录后鉴权自动附加，你不必手动加 Authorization。"
            connectorBlock = """

            【远程执行服务（已配置）】
            你已接入用户部署的远程执行服务，地址：\(connectorEP)。\(authNote)
            该服务按用户账户隔离沙箱并限速，可跑任意 shell 命令（dashi-ppt 生成 PPT、图像/视频/音频生成等重算力任务）。
            当用户要求用 dashi-ppt / 生成图文 PPT / 演示文稿 / 幻灯片时：把需求整理为 {title: 标题, theme: 主题(默认 theme02), slides: [{title: 页标题, bullets: [要点...]}]}，用 web_request 以 POST 发到 \(connectorEP)/render。
            需要跑其他命令时，用 web_request POST 到 \(connectorEP)/exec，body 为 {"command":"实际 shell 命令"}；命令需把结果写到沙箱当前目录的文件，服务会自动回传第一个产物文件。
            服务直接返回产物文件（.pptx/.png/.mp3/...），你会在聊天中收到可预览/分享的文件。绝不要声称缺少连接器或无法生成图文 PPT。
            """
        }

        return """
        \(skillBlock)\(connectorBlock)\(memoryBlock)

        你是 Velos，一个运行在 iPhone 上的本地 AI Agent。你可以调用系统工具帮用户完成操作。

        当前时间：\(nowStr)（东八区，北京时间）。系统时间已直接提供给你，不要向用户询问现在几点或今天几号，直接用当前时间计算。
        已开启的系统能力：\(capabilities)

        重要规则：
        1. 当用户请求设置闹钟、提醒、日程、倒计时等时间相关操作时，必须使用对应的工具函数，不要只回答文字。
        2. 工具选择必须精确：
           - “闹钟”“叫我起床”“N分钟后叫我” → 用 set_alarm（本地通知响铃）。
           - “提醒”“提醒我N分钟后做某事”“提醒事项” → 用 create_reminder（写入系统“提醒事项”App，会在锁屏/通知中心弹窗，即使 Velos 被划掉也能收到）。
           - “日程”“会议”“约会” → 用 create_calendar_event（写入系统“日历”App）。
           - “计时”“倒计时” → 用 set_timer。
           - “看我最近/近几天的安排”“今天/明天有什么日程”“待办/提醒事项有哪些”“我有哪些闹钟”等**查询类**请求 → 分别用 list_events、list_reminders、list_alarms 读取后汇总成人话清单（按时间排序），不要只回复“请查看系统 App”。
        3. 对于相对时间如“5分钟后”“半小时后”“明天早上9点”，直接使用 fire_in_minutes / due_in_minutes / duration_minutes；对于绝对时间使用 fire_at / due_at / start_at（ISO8601 格式，如 2026-08-26T09:00:00+08:00）。
        4. 用户说“提醒我N分钟后做某事”时，标题就是这件事本身（如“喝水”“拿快递”），不要再问用户标题。
        5. 如果用户没有指定标题，根据内容推断一个合适的标题。
        6. 工具执行后，根据结果用一句话向用户确认，不要暴露内部 ID、路径或 JSON。
        7. 如果某个能力未开启，引导用户到设置页开启，不要重复尝试调用失败工具。
        8. 当用户要求生成文件、PPT、写报告、整理数据时，使用 create_file / write_file（文本/md/csv）或 create_ppt（PPT）。先自己规划内容结构，再调用工具生成；生成后用一句话告诉用户文件已保存，可点击分享按钮导出。write_file 支持命名空间：workspace（默认工作文件）、memory（跨会话记忆）、skills（用户技能）、attachments（附件）。
        9. 【多模态生成】用户要“画一张图 / 生成图片 / 做张配图” → generate_image；要“朗读 / 生成语音 / 配音 / 音频” → generate_speech；要“生成视频 / 做段短片” → generate_video。规则：①generate_image 默认 1024x1024，调用前先把用户的中文描述改写成简洁具体的英文 Stable Diffusion prompt（主体 + 风格 + 光线 + 色彩 + 构图），必要时通过 negative_prompt 排除低质量元素，这样免费图源出图更贴合描述；②generate_video 较慢（1–5 分钟），调用前先告诉用户需要等待；③若 generate_video 返回“仍在生成 / pending”且给出 request_id，稍后用 check_video 查询结果并告诉用户已保存的文件；④生成成功后用一句话说明已保存、可点击打开/分享，不要复述内部 URL 或 JSON。
        10. 【web_request / 万能连接器】用于调用外部 HTTP 服务（dashi-ppt、图片/视频/音频生成、Webhook、GitHub 等）。规则：①鉴权令牌放 headers 的 Authorization 字段，绝不写进回复文本；②若服务返回文件（.pptx/.pdf/图片/音频/视频），你会收到可打开/分享的文件；③当某个技能提示词要求你“运行脚本 / 执行 Node / 启动连接器 / 调用本地工具”时，不要声称缺少连接器——应翻译为对应的 web_request HTTP 调用；④绝不要对用户说“我没有连接器”或“环境未接入”，web_request 就是连接器；⑤当用户让你“查看一个 GitHub 项目 / 网页 / 链接”时，优先用 web_request 抓取该页面的 raw 文本或 README（如 GitHub 的 raw.githubusercontent.com 或 ?format=raw、render 接口），抓取到 HTML 后请在内部消化，只向用户输出项目的一句话概括、核心定位、主要功能和安装入口，**严禁把原始 HTML、CSS、JS、JSON 或转义字符直接复制到回复里**；⑥如果一次请求失败（TLS/限流/连接断开），立即换 URL 或方式重试，失败过程不要告诉用户，只报告最终结果。
        11. 【输出纯净度】用户只看最终结果。任何工具的失败、重试、中间状态、原始响应体，只允许出现在流式心跳占位里一闪而过，不允许作为独立消息气泡留在对话中；最终回复必须是人话总结，禁止包含 JSON 转义、HTML 标签、CSS 代码、JS 代码、路径字符串、未解析编码或"status":200 之类的技术字段。
        12. 【跨会话记忆】memory/ 中的内容已自动加载到本提示词底部。当用户要求“记住 XXX”、对话变长、或你认为某事实对未来对话有价值时，使用 write_memory 或 write_file(namespace="memory") 保存。记忆标题要简洁，内容用中文要点式。
        13. 【技能安装】当用户分享一个 GitHub 项目链接并询问能否作为 skill 安装，或明确要求安装某个 skill 时：①若对方给出的是 GitHub 仓库链接，直接调用 install_skill(url=链接)；②若用户要求你“写一个 skill”，用 write_file(namespace="skills", path="{id}.md") 写入完整 SKILL.md（必须含 YAML frontmatter：id/name/description/icon/triggers/tools/prompt），写完后调用 install_skill(url=该文件的本地路径或 raw github 链接) 立即加载；③安装成功后用一句话确认技能名称和可用触发词。
        14. 【天气查询】用户问“今天天气怎么样”“明天会下雨吗” → 用 get_weather(location=城市名)，返回结果直接用人话复述，不要只输出原始文本。
        15. 【定时/重复提醒】set_alarm / create_reminder 支持 repeat 参数：none（默认）/ daily（每天）/ weekdays（工作日）/ weekly（每周）/ custom（自定义星期，配合 weekdays=[1..7]）。用户要“每天/工作日/每周提醒我 XXX”时，填对应 repeat 和具体时间。list_scheduled / cancel_scheduled 用于查看和取消已设置的定时通知。

        示例：
        用户：5分钟后提醒我喝水
        → 调用 create_reminder(title="喝水", due_in_minutes=5)

        用户：帮我设个明早7点的闹钟
        → 调用 set_alarm(title="起床闹钟", fire_at="\(formatISODate(now.addingTimeInterval(86400), hour: 7))")

        用户：10分钟后叫我
        → 调用 set_alarm(title="提醒", fire_in_minutes=10)

        \(customBlock)
        """
    }

    private func buildSkillBlock(_ skills: [Skill]) -> String {
        guard !skills.isEmpty else { return "" }
        let header = """
        【已强制激活的专业技能，必须严格遵循】
        以下技能已针对本次对话激活，你必须完全按照对应技能的规则、风格和要求回答。如果用户请求与技能直接相关，禁止忽略技能规则。
        """
        let list = skills.map { "- \($0.name)：\($0.description)" }.joined(separator: "\n")
        let bodies = skills.map { "\n=== [\($0.name)] ===\n\($0.prompt)" }.joined(separator: "\n")
        return header + "\n" + list + bodies
    }

    private func formatISODate(_ date: Date, hour: Int) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        comps.hour = hour
        comps.minute = 0
        return fmt.string(from: Calendar.current.date(from: comps) ?? date)
    }

    /// 自动读取 memory/ 命名空间下的 markdown 文件，注入系统提示词作为跨会话持久记忆。
    private func memoryBlock() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("memory", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return "" }
        let mdFiles = files.filter { !$0.hasDirectoryPath && $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var parts: [String] = []
        for url in mdFiles.prefix(20) {
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            parts.append("### \(url.lastPathComponent)\n\(content)")
        }
        guard !parts.isEmpty else { return "" }
        return """

        【跨会话记忆（已自动加载）】
        以下是从 memory/ 命名空间读取的已保存记忆，你在回答时应作为背景知识参考，不要重复背诵；若记忆与用户当前问题冲突，以当前用户输入为准。
        \(parts.joined(separator: "\n\n"))
        """
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

// MARK: - Skill 框架

/// 技能定义：可插拔的领域知识 + 行为配方。
struct Skill: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let triggers: [String]
    let tools: [String]
    let prompt: String
    var isBuiltIn: Bool = false
}

/// 技能路由：根据用户输入匹配相关技能，并管理用户从沙盒安装的自定义技能。
@MainActor
final class SkillRouter: ObservableObject {
    static let shared = SkillRouter()
    private let builtInSkills: [Skill] = SkillRegistry.allSkills.map { s in
        var c = s
        c.isBuiltIn = true
        return c
    }
    @Published private(set) var userSkills: [Skill] = []

    private let skillsDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Skills", isDirectory: true)
    }()

    private init() {
        loadUserSkills()
    }

    /// 内置技能 + 用户安装技能
    var allSkills: [Skill] { builtInSkills + userSkills }

    func loadUserSkills() {
        userSkills = SkillFileStore.loadSkills(from: skillsDir)
    }

    /// 从 GitHub / 任意 http(s) 链接安装技能到沙盒。
    func install(from urlString: String) async throws -> [Skill] {
        let installed = try await SkillInstaller.install(urlString: urlString, into: skillsDir)
        loadUserSkills()
        return installed
    }

    func remove(userSkillID id: String) throws {
        guard let skill = userSkills.first(where: { $0.id == id }) else { return }
        try SkillFileStore.delete(skill: skill, from: skillsDir)
        loadUserSkills()
    }

    func skill(byID id: String) -> Skill? {
        allSkills.first { $0.id == id }
    }

    func match(input: String) -> [Skill] {
        let lower = input.lowercased()
        let matched = allSkills.filter { skill in
            skill.triggers.contains { lower.contains($0.lowercased()) }
        }
        return Array(matched.prefix(2))
    }

    func match(messages: [StoredMessage]) -> [Skill] {
        guard let lastUser = messages.last(where: { $0.role == "user" })?.content else { return [] }
        return match(input: lastUser)
    }

    /// 解析 `@技能名` 前缀强制加载技能；无前缀返回 nil。
    func matchExplicit(input: String) -> [Skill]? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@") else { return nil }
        let after = String(trimmed.dropFirst())
        let token = after.split(separator: " ", maxSplits: 1).first.map(String.init) ?? after
        let lower = token.lowercased()
        guard !lower.isEmpty else { return nil }
        let hit = allSkills.first { skill in
            let n = skill.name.lowercased()
            let id = skill.id.lowercased()
            return n.contains(lower) || lower.contains(n) || id.contains(lower) || lower.contains(id)
        }
        return hit.map { [$0] }
    }

    /// 去掉 `@技能名 ` 前缀，返回真正要发送的文本内容。
    func stripSkillPrefix(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@") else { return trimmed }
        let after = String(trimmed.dropFirst())
        let parts = after.split(separator: " ", maxSplits: 1)
        if parts.count > 1 {
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }
}

/// 解析带 YAML frontmatter 的 skill markdown；无 frontmatter 时整篇作为提示词。
struct SkillMarkdownParser {
    static func parse(_ text: String, fallbackID: String) -> Skill? {
        let (front, body) = extractFrontmatter(text)
        let name: String
        let icon: String
        let description: String
        let triggers: [String]
        let tools: [String]
        let prompt: String

        if let front = front {
            let dict = parseFrontmatter(front)
            let rawName = (dict["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            name = rawName.isEmpty ? fallbackID.capitalized : rawName
            let rawIcon = (dict["icon"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            icon = rawIcon.isEmpty ? "sparkles" : rawIcon
            description = (dict["description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            triggers = parseList(dict["triggers"])
            tools = parseList(dict["tools"])
            prompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            name = fallbackID.capitalized
            icon = "sparkles"
            description = "用户安装的技能"
            triggers = []
            tools = []
            prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let id = slug(name)
        return Skill(id: id, name: name, icon: icon, description: description,
                     triggers: triggers, tools: tools, prompt: prompt, isBuiltIn: false)
    }

    private static func extractFrontmatter(_ text: String) -> (String?, String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, text)
        }
        if let closeIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            let front = lines[1...closeIdx].joined(separator: "\n")
            let body = lines[(closeIdx + 1)...].joined(separator: "\n")
            return (front, body)
        }
        return (nil, text)
    }

    private static func parseFrontmatter(_ text: String) -> [String: String] {
        var dict: [String: String] = [:]
        var currentKey: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") {
                if let key = currentKey {
                    let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if let existing = dict[key], !existing.isEmpty {
                        dict[key] = existing + "\n" + item
                    } else {
                        dict[key] = item
                    }
                }
                continue
            }
            if let colon = line.range(of: ":") {
                let key = String(line[line.startIndex..<colon.lowerBound]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                if key.isEmpty { continue }
                if value.isEmpty {
                    currentKey = key
                } else {
                    dict[key] = value
                    currentKey = nil
                }
            }
        }
        return dict
    }

    private static func parseList(_ raw: String?) -> [String] {
        guard let raw = raw, !raw.isEmpty else { return [] }
        let sep: Character = raw.contains("\n") ? "\n" : ","
        return raw.split(separator: sep).map {
            String($0).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        }.filter { !$0.isEmpty }
    }

    private static func slug(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) || ch.value >= 0x4E00 {
                out.append(Character(ch))
            } else {
                out.append("-")
            }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "skill" : trimmed
    }
}

/// 用户技能文件读写（沙盒 Documents/Skills/*.md）
struct SkillFileStore {
    static func loadSkills(from dir: URL) -> [Skill] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "md" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return SkillMarkdownParser.parse(text, fallbackID: url.deletingPathExtension().lastPathComponent)
        }
    }

    static func delete(skill: Skill, from dir: URL) throws {
        let file = dir.appendingPathComponent("\(skill.id).md")
        try FileManager.default.removeItem(at: file)
    }
}

enum SkillInstallError: Error, LocalizedError {
    case invalidURL
    case downloadFailed
    case noSkillFound
    case parseFailed
    case githubAPIError(String)
    case rateLimited(seconds: Int)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "链接无效，请输入 http(s) 开头的技能文件地址"
        case .downloadFailed: return "下载失败，请检查链接与网络"
        case .noSkillFound: return "未能从该链接解析出有效技能（需要含 name 的 markdown 或纯文本）"
        case .parseFailed: return "文件内容无法解析"
        case .githubAPIError(let msg): return "GitHub API 错误：\(msg)"
        case .rateLimited(let seconds):
            let s = max(seconds, 10)
            return "GitHub API 请求过于频繁，请于约 \(s) 秒后再试（可在“技能中心”填入 GitHub 令牌提升限额）"
        }
    }
}

/// GitHub 上搜到的 skill 文件结果
struct SkillGitHubSearchResult: Identifiable {
    let id = UUID()
    let fullName: String
    let path: String
    let htmlURL: String
    let rawURL: String
    let fileName: String
}

/// 从 GitHub / 任意 http(s) 链接安装 skill markdown 到沙盒；支持单文件或整个仓库。
struct SkillInstaller {
    /// 从 UserDefaults 读取可选的 GitHub 令牌（设置页配置）；带令牌可显著提升 Search API 限额。
    private static var authToken: String {
        (UserDefaults.standard.string(forKey: "githubToken") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 根据响应头解析限流剩余秒数（Retry-After 优先，其次 X-RateLimit-Reset）；无法解析时返回 60。
    private static func rateLimitSeconds(from resp: URLResponse) -> Int {
        guard let http = resp as? HTTPURLResponse else { return 60 }
        if let retryAfter = http.allHeaderFields["Retry-After"] as? String,
           let sec = Int(retryAfter), sec > 0 {
            return sec
        }
        if let reset = http.allHeaderFields["X-RateLimit-Reset"] as? String,
           let epoch = Double(reset) {
            let wait = Int(epoch - Date().timeIntervalSince1970)
            if wait > 0 { return wait }
        }
        return 60
    }

    static func install(urlString: String, into dir: URL) async throws -> [Skill] {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, scheme.hasPrefix("http") else {
            throw SkillInstallError.invalidURL
        }

        // 整个 GitHub 仓库 -> 自动扫描并安装其下所有 SKILL.md / skill.md
        if let repo = parseGitHubRepo(url), !url.pathExtension.lowercased().hasSuffix("md") {
            return try await installRepo(repo, into: dir)
        }

        // 单个 skill markdown 文件
        let target = normalizeGitHub(url)
        let skill = try await downloadAndSave(target, into: dir)
        return [skill]
    }

    /// GitHub 搜索 skill 文件（filename:SKILL.md）。
    /// - 已配置 GitHub 令牌：直连 GitHub Search API（限额 30 次/分钟）。
    /// - 无令牌：走服务端 /skills/search 代理（服务端自带令牌 + 5 分钟缓存），用户零配置也能搜。
    static func searchGitHub(query: String) async throws -> [SkillGitHubSearchResult] {
        guard !Self.authToken.isEmpty else { return try await searchViaRelay(query: query) }
        return try await searchDirect(query: Self.buildQuery(query), perPage: 10)
    }

    /// 直连 GitHub Search API（需令牌，否则极易 403 限流）
    private static func searchDirect(query: String, perPage: Int) async throws -> [SkillGitHubSearchResult] {
        let url = URL(string: "https://api.github.com/search/code?q=\(query)&per_page=\(perPage)")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("iOSAgent/9.0.7", forHTTPHeaderField: "User-Agent")
        let token = Self.authToken
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 403 || http.statusCode == 429 {
                throw SkillInstallError.rateLimited(seconds: Self.rateLimitSeconds(from: resp))
            }
            if !(200...299).contains(http.statusCode) {
                let msg = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
                throw SkillInstallError.githubAPIError(msg)
            }
        }
        return try parseSearchResults(data)
    }

    // MARK: - Private

    /// 组装 GitHub 代码搜索表达式（始终限定 filename:SKILL.md）
    private static func buildQuery(_ query: String) -> String {
        var q = "filename:SKILL.md"
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            q += "+\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)"
        }
        return q
    }

    /// 无令牌通道：由 Velos 服务端代理 GitHub 搜索（服务端令牌 + 缓存，避免匿名 10 次/分钟限流）
    private static func searchViaRelay(query: String) async throws -> [SkillGitHubSearchResult] {
        let ep = await MainActor.run { SettingsStore.shared.connectorEndpoint.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard var comp = URLComponents(string: ep), !ep.isEmpty else {
            throw SkillInstallError.githubAPIError("服务地址无效")
        }
        comp.path = "/skills/search"
        comp.query = nil
        comp.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comp.url else { throw SkillInstallError.invalidURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let t = await MainActor.run { SettingsStore.shared.authToken.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !t.isEmpty { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 403 || http.statusCode == 429 {
                throw SkillInstallError.rateLimited(seconds: Self.rateLimitSeconds(from: resp))
            }
            if !(200...299).contains(http.statusCode) {
                let msg = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
                throw SkillInstallError.githubAPIError(msg)
            }
        }
        struct ProxyItem: Decodable {
            let name: String?
            let path: String?
            let raw: String?
            let repo: String?
        }
        struct ProxyResp: Decodable { let items: [ProxyItem]? }
        let decoded = try JSONDecoder().decode(ProxyResp.self, from: data)
        return (decoded.items ?? []).compactMap { it in
            guard let raw = it.raw, let full = it.name else { return nil }
            let p = it.path ?? "SKILL.md"
            return SkillGitHubSearchResult(
                fullName: full,
                path: p,
                htmlURL: it.repo ?? "https://github.com/" + full,
                rawURL: raw,
                fileName: (p as NSString).lastPathComponent
            )
        }
    }

    /// 无令牌通道：由 Velos 服务端代理抓取 raw 内容（直连 raw 失败时兜底，也可绕开地区网络问题）
    private static func fetchViaRelay(_ url: URL) async throws -> String {
        let ep = await MainActor.run { SettingsStore.shared.connectorEndpoint.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard var comp = URLComponents(string: ep), !ep.isEmpty,
              let target = comp.url?.appendingPathComponent("/skills/fetch") else {
            throw SkillInstallError.downloadFailed
        }
        var req = URLRequest(url: target)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["url": url.absoluteString])
        req.timeoutInterval = 60
        let t = await MainActor.run { SettingsStore.shared.authToken.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !t.isEmpty { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SkillInstallError.downloadFailed
        }
        struct FetchResp: Decodable { let content: String? }
        if let c = try? JSONDecoder().decode(FetchResp.self, from: data).content { return c }
        throw SkillInstallError.parseFailed
    }

    /// github.com blob 链接转 raw.githubusercontent.com
    private static func normalizeGitHub(_ url: URL) -> URL {
        var s = url.absoluteString
        if s.contains("github.com") && s.contains("/blob/") {
            s = s.replacingOccurrences(of: "github.com", with: "raw.githubusercontent.com")
            s = s.replacingOccurrences(of: "/blob/", with: "/")
        }
        return URL(string: s) ?? url
    }

    /// 解析 GitHub 仓库地址，返回 (owner, repo, branch, subpath)
    private static func parseGitHubRepo(_ url: URL) -> (owner: String, repo: String, branch: String, subpath: String)? {
        guard url.host?.lowercased() == "github.com" else { return nil }
        var comps = url.pathComponents.filter { $0 != "/" }
        guard comps.count >= 2 else { return nil }
        let owner = comps[0]
        var repo = comps[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }

        var branch = "main"
        var subpath = ""
        if comps.count >= 4, comps[2] == "tree" || comps[2] == "blob" {
            branch = comps[3]
            if comps.count > 4 {
                subpath = comps[4...].joined(separator: "/")
            }
        }
        return (owner, repo, branch, subpath)
    }

    private static func installRepo(_ repo: (owner: String, repo: String, branch: String, subpath: String),
                                    into dir: URL) async throws -> [Skill] {
        var q = "repo:\(repo.owner)/\(repo.repo) filename:SKILL.md"
        if !repo.subpath.isEmpty {
            q += " path:\(repo.subpath)"
        }
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let results = Self.authToken.isEmpty
            ? try await searchViaRelay(query: q)
            : try await searchDirect(query: encoded, perPage: 50)
        guard !results.isEmpty else { throw SkillInstallError.noSkillFound }

        var installed: [Skill] = []
        for r in results {
            guard let raw = URL(string: r.rawURL) else { continue }
            do {
                let skill = try await downloadAndSave(raw, into: dir)
                if !installed.contains(where: { $0.id == skill.id }) {
                    installed.append(skill)
                }
            } catch {
                // 单文件失败继续安装其它
                continue
            }
        }
        guard !installed.isEmpty else { throw SkillInstallError.downloadFailed }
        return installed
    }

    private static func downloadAndSave(_ url: URL, into dir: URL) async throws -> Skill {
        let text: String
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw SkillInstallError.downloadFailed
            }
            guard let t = String(data: data, encoding: .utf8) else { throw SkillInstallError.parseFailed }
            text = t
        } catch {
            // 直连失败（网络/地区限制）→ 回落到服务端代理抓取
            text = try await fetchViaRelay(url)
        }
        let fallbackID = url.deletingPathExtension().lastPathComponent
        guard let skill = SkillMarkdownParser.parse(text, fallbackID: fallbackID) else {
            throw SkillInstallError.noSkillFound
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(skill.id).md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return skill
    }

    private static func parseSearchResults(_ data: Data) throws -> [SkillGitHubSearchResult] {
        struct Resp: Decodable {
            struct Item: Decodable {
                let name: String
                let path: String
                let html_url: String
                let repository: Repository
            }
            struct Repository: Decodable {
                let full_name: String
            }
            let items: [Item]
        }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        return resp.items.map { item in
            let raw = normalizeGitHub(URL(string: item.html_url)!).absoluteString
            return SkillGitHubSearchResult(fullName: item.repository.full_name,
                                           path: item.path,
                                           htmlURL: item.html_url,
                                           rawURL: raw,
                                           fileName: item.name)
        }
    }
}

/// v7.5 使用内嵌注册表；v7.6 改为 bundle 内 Skills/*.md 文件便于用户随时添加。
enum SkillRegistry {
    static let allSkills: [Skill] = [
        Skill(
            id: "wxoa-writer",
            name: "公众号写作",
            icon: "pencil.line",
            description: "按「忘仙」调性写公众号随笔",
            triggers: ["公众号", "文章", "写作", "忘仙", "东邪西毒", "随笔", "山丘", "三十到三十五"],
            tools: ["create_file"],
            prompt: """
            你是「忘仙」公众号主笔。当用户要求写公众号文章/随笔/诗歌时，严格遵循：
            1. 调性：洒脱、看淡红尘，可自然化用《东邪西毒》台词与李宗盛《山丘》意象，但禁止生硬堆砌。
            2. 主题聚焦：30-35岁生活感悟。
            3. 格式：随笔/诗歌体，≤300字，句式稍长、句间有衔接、有文学性。
            4. 禁用："一座又一座"等无效叠词。
            5. 必含关键词（自然融入）：初入江湖、翻山、山丘、白了头、醉生梦死、酒、回首、追求。
            6. 只输出文章正文，不加标题，不解释。
            7. 如用户要求保存，调用 create_file 写入 .md。
            """
        ),
Skill(
            id: "image-creator",
            name: "图片创作",
            icon: "photo.fill",
            description: "为写作/PPT/笔记生成配图、插画、海报封面",
            triggers: ["图片", "生成图", "画一张", "画个", "配图", "插图", "插画", "海报", "封面", "壁纸", "illustration", "image", "picture", "photo", "poster"],
            tools: ["generate_image"],
            prompt: """
            你是图片创作助理。规则：
1. 用户说"画一张…"、"配图"、"插画"、"海报"等关键词 → 直接调用 generate_image 工具，prompt 必须写成英文（Stable Diffusion/Flux 风格），参数 size 默认 1024x1024、需要横版时 1024x576、需要竖版 576x1024，需要方形头图 768x768。
2. prompt 写法：[主体] + [风格] + [光线] + [构图] + [画质]，不要写中文。例如：a cyberpunk girl with glowing neon umbrella, standing on a rainy street, cinematic lighting, dramatic angle, ultra-detailed, 8k, masterpiece。
3. 同一段对话内若用户多次要求改图（"再画一张" / "再来个版本" / "换个颜色"），复用上轮 prompt 改对应属性，**不要每次都让用户复述要求**。
4. 每次出图后用一句话描述图里内容（中文，10 字以内），让用户一眼知道结果是否对路。文件名建议用简短英文或拼音（例 cybercat.jpg、lake_mountain.jpg）。
5. 用户要"系列图"（如"再画 3 张类似的"）：循环调用 3 次 generate_image，每次换 prompt 关键属性（颜色/角度/季节）。
6. 角色/场景一致性：用户说"同一个角色再画一张" → 在 prompt 里把上一张的关键描述词原样复用，只改场景。
"""
        ),
        Skill(
            id: "dashi-ppt-remote",
            name: "dashi-ppt(远程)",
            icon: "doc.richtext",
            description: "经服务器 web_request 渲染真实图文 PPT",
            triggers: ["dashi-ppt", "dashi", "ppt", "演示", "幻灯片", "图文ppt", "图文"],
            tools: ["web_request"],
            prompt: """
            当用户要求生成 PPT / 演示文稿 / 幻灯片，尤其提到 dashi-ppt 时，使用远程执行服务：
            1. 把用户需求整理成结构：{title: 标题, theme: 主题(默认 theme02), slides: [{title: 页标题, bullets: [要点...]}]}。
            2. 用 web_request 工具以 POST 发送到系统提示中「远程执行服务」给定的地址 + /render（如 <地址>/render）；headers 只需 {"Content-Type":"application/json"}，不要手动加 Authorization——鉴权由 App 自动附加；body 为该结构的 JSON 字符串。
            3. 服务返回 .pptx 文件，直接告诉用户已生成、可在聊天中点击打开/分享，不要复述内部路径或 JSON。
            4. 用户未指定主题时默认 theme02；页数按内容需要，通常 5-10 页。
            5. 除非用户明确说要纯文字版且不要 dashi-ppt 渲染，否则优先用远程渲染服务而非 create_ppt 纯文字版。
            6. 若用户要求其他重算力任务（图像/视频/音频生成等），用 web_request POST 到 <地址>/exec，body {"command":"..."}；结果文件会自动回传。
            """
        )
    ]
}
