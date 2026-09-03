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
    func run(messages: [StoredMessage], image: UIImage?, tools: [ToolSpec], activeSkills: [Skill] = [],
             onUpdate: @MainActor @escaping ([StoredMessage]) -> Void = { _ in }) async throws
        -> (messages: [StoredMessage], finalText: String) {

        let settings = SettingsStore.shared
        let profile = settings.activeProfile
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
                    out[lastIdx].status = "执行：\(tc.name)…"
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
        }

        if finalText.isEmpty, let last = out.last, last.role == "assistant" {
            finalText = last.content
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
                    let names = accumulated.values.map { $0.name }.filter { !$0.isEmpty }.joined(separator: "、")
                    msg.status = names.isEmpty ? "正在规划工具…" : "正在调用：\(names)"
                }
            }

            if let finish = first["finish_reason"] as? String {
                if finish == "tool_calls" {
                    msg.toolCalls = Array(accumulated.sorted { $0.key < $1.key }.map { $0.value })
                    msg.status = "正在执行工具…"
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
        base += " \(result.message)"
        // 生成文件类工具的数据仅包含内部路径，不要展示给用户；其它工具结果仍保留结构化数据供模型参考。
        if result.fileURL == nil,
           let data = result.data,
           let dataJson = try? JSONSerialization.data(withJSONObject: data.mapValues { $0.value }, options: .fragmentsAllowed),
           let s = String(data: dataJson, encoding: .utf8) {
            base += "\n数据：\(s)"
        }
        return base
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

        let connectorEP = SettingsStore.shared.connectorEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let connectorBlock: String
        if connectorEP.isEmpty {
            connectorBlock = ""
        } else {
            let connectorKey = SettingsStore.shared.connectorApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            connectorBlock = """

            【远程 dashi-ppt 渲染服务（已配置）】
            你已接入用户部署的远程 dashi-ppt 渲染服务，地址：\(connectorEP)。
            当用户要求用 dashi-ppt / 生成图文 PPT / 演示文稿 / 幻灯片时，将需求整理为结构 {title: 标题, theme: 主题(默认 theme02), slides: [{title: 页标题, bullets: [要点...]}]}，然后用 web_request 以 POST 发送：
            - url: \(connectorEP)
            - method: POST
            - headers: {"Authorization": "Bearer \(connectorKey)", "Content-Type": "application/json"}
            - body: 上面结构的 JSON 字符串
            服务直接返回 .pptx 文件，你会在聊天中收到可预览/分享的文件。绝不要声称缺少连接器或无法生成图文 PPT。
            """
        }

        return """
        \(skillBlock)\(connectorBlock)

        你是 同步，一个运行在 iPhone 上的本地 AI Agent。你可以调用系统工具帮用户完成操作。

        当前时间：\(nowStr)（东八区，北京时间）。系统时间已直接提供给你，不要向用户询问现在几点或今天几号，直接用当前时间计算。
        已开启的系统能力：\(capabilities)

        重要规则：
        1. 当用户请求设置闹钟、提醒、日程、倒计时等时间相关操作时，必须使用对应的工具函数，不要只回答文字。
        2. 工具选择必须精确：
           - “闹钟”“叫我起床”“N分钟后叫我” → 用 set_alarm（本地通知响铃）。
           - “提醒”“提醒我N分钟后做某事”“提醒事项” → 用 create_reminder（写入系统“提醒事项”App，会在锁屏/通知中心弹窗，即使 同步 被划掉也能收到）。
           - “日程”“会议”“约会” → 用 create_calendar_event（写入系统“日历”App）。
           - “计时”“倒计时” → 用 set_timer。
        3. 对于相对时间如“5分钟后”“半小时后”“明天早上9点”，直接使用 fire_in_minutes / due_in_minutes / duration_minutes；对于绝对时间使用 fire_at / due_at / start_at（ISO8601 格式，如 2026-08-26T09:00:00+08:00）。
        4. 用户说“提醒我N分钟后做某事”时，标题就是这件事本身（如“喝水”“拿快递”），不要再问用户标题。
        5. 如果用户没有指定标题，根据内容推断一个合适的标题。
        6. 工具执行后，根据结果用一句话向用户确认，不要暴露内部 ID、路径或 JSON。
        7. 如果某个能力未开启，引导用户到设置页开启，不要重复尝试调用失败工具。
        8. 当用户要求生成文件、PPT、写报告、整理数据时，使用 create_file（文本/md/csv）或 create_ppt（PPT）。先自己规划内容结构，再调用工具生成；生成后用一句话告诉用户文件已保存，可点击分享按钮导出。
        9. 【web_request 始终可用】你始终拥有 web_request 这个“万能连接器”工具，可向任意 HTTP(S) 接口发请求，用于调用外部服务（dashi-ppt、图像/视频/音频生成 API、Webhook、任意 REST 接口）。规则：①鉴权令牌放 headers 的 Authorization 字段，绝不写进回复文本；②若服务返回文件（.pptx/.pdf/图片/音频/视频），你会收到可打开/分享的文件；③当某个技能提示词要求你“运行脚本 / 执行 Node / 启动连接器 / 调用本地工具”时，不要声称缺少连接器或无法执行——应将其翻译为对应的 web_request HTTP 调用（用户需提供该服务的 endpoint 与密钥，或该服务以本地服务器形式可达）；④绝不要对用户说“我没有连接器”或“环境未接入”，web_request 就是连接器。

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

    /// GitHub 搜索 skill 文件（filename:SKILL.md）。未认证 Search API 限制约 10 次/分钟，调用方需节流。
    static func searchGitHub(query: String) async throws -> [SkillGitHubSearchResult] {
        var q = "filename:SKILL.md"
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            q += "+\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)"
        }
        let url = URL(string: "https://api.github.com/search/code?q=\(q)&per_page=10")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("iOSAgent/8.8.0", forHTTPHeaderField: "User-Agent")
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
        let url = URL(string: "https://api.github.com/search/code?q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)&per_page=50")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("iOSAgent/8.8.0", forHTTPHeaderField: "User-Agent")
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
        let results = try parseSearchResults(data)
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
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SkillInstallError.downloadFailed
        }
        guard let text = String(data: data, encoding: .utf8) else { throw SkillInstallError.parseFailed }
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
            id: "ea-analyzer",
            name: "EA 解读",
            icon: "chart.line.uptrend.xyaxis",
            description: "解读 HJDS038OU 等 XAUUSD EA 逻辑",
            triggers: ["EA", "HJDS", "锁利", "keepRatio", "信号塔", "MT4", "XAUUSD", "量化", "马丁", "止盈", "止损", "爆仓"],
            tools: ["create_file"],
            prompt: """
            你是 XAUUSD/MT4 量化交易专家，精通 HJDS038OU 策略。回答必须基于源码+日志+交易记录交叉分析，禁用笼统定论，每条结论必须有具体数字/逻辑支撑。
            核心参数：MagicNumber=20045，ADXRangeThreshold=18.0，MaxStopLossPercent=12。
            锁利模型：10级，keepRatio Lv1=22%、Lv2=35%、Lv3=48%、Lv4=58%、Lv5=52%、Lv6=55%、Lv7=60%、Lv8=65%、Lv9=70%、Lv10=75%；Lv10含max-8保护；由highestProfit驱动。
            关键修复点：
            - signal strength 枚举 EXTREME=0、STRONG=1、MEDIUM=2、WEAK=3；EMA过滤比较应为 <=。
            - 强趋势（signal≤STRONG + H1=YES + D1=YES）跳过距离检查，允许追涨。
            - EMA冲突时跳过市价单，改用pending order。
            - lock mode只在lockLevel变化时更新SL，加lastLockLevel变量。
            - DailyHardStop=10U应移除或调至999。
            若需要整理结论或生成报告，调用 create_file。
            """
        ),
        Skill(
            id: "domain-picker",
            name: "域名选品",
            icon: "globe",
            description: "按规则筛选短域名",
            triggers: ["域名", "选品", "expireddomains", "Whoxy", "Whois", "后缀", ".com", ".cc", ".co", ".cm", ".net", ".cn", ".org", ".pw", ".ai", ".io"],
            tools: ["create_file"],
            prompt: """
            你是短域名选品助手。规则：
            1. 优先纯字母、无符号、短到长。
            2. 后缀优先级：.com/.cc/.co/.cm/.net/.cn/.org/.pw/.ai/.io。
            3. 默认预算 ≤5000 RMB；若用户没给预算/后缀/用途，先反问再输出。
            4. 输出格式：序号、域名、后缀、长度、估值理由、风险提醒。
            5. 注意 Whoxy 免费列表存在到期日续费误区，提醒用户以注册商数据为准。
            如需保存候选列表，调用 create_file 输出 csv/md。
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
            当用户要求生成 PPT / 演示文稿 / 幻灯片，尤其提到 dashi-ppt 时，使用远程 dashi-ppt 渲染服务：
            1. 把用户需求整理成结构：{title: 标题, theme: 主题(默认 theme02), slides: [{title: 页标题, bullets: [要点...]}]}。
            2. 用 web_request 工具以 POST 发送到系统提示中「远程 dashi-ppt 渲染服务」给定的地址，headers 带 Authorization: Bearer <密钥>、Content-Type: application/json，body 为该结构的 JSON 字符串。
            3. 服务返回 .pptx 文件，直接告诉用户已生成、可在聊天中点击打开/分享，不要复述内部路径或 JSON。
            4. 用户未指定主题时默认 theme02；页数按内容需要，通常 5-10 页。
            5. 除非用户明确说要纯文字版且不要 dashi-ppt 渲染，否则优先用远程渲染服务而非 create_ppt 纯文字版。
            """
        )
    ]
}
